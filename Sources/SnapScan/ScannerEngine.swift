import Foundation
import Observation

@MainActor
@Observable
final class ScannerEngine {
    static let shared = ScannerEngine()

    enum Status: Equatable {
        case idle
        case detecting
        case scanning(page: Int)
        case processing(page: Int)
        case noScanner
    }

    var status: Status = .idle
    var scannerName: String?
    /// Live USB presence of the iX500 (event-driven via IOKit; the scanner
    /// powers its USB interface off when the feeder flap is closed).
    var scannerPresent = false
    var pages: [ScannedPage] = []
    var lastError: String?
    var feederWasEmpty = false

    /// The PDF the current pages are saved to (nil until the first batch lands).
    var documentURL: URL?
    /// True while the document accepts more batches; false once finalized via Done.
    var documentOpen = false
    /// Name (without extension) chosen for a document that hasn't been saved yet.
    var pendingDocumentName: String?
    /// Library identity of the current document.
    private var currentDocumentID: UUID?

    /// The current document's name (without extension) for display and editing.
    var documentDisplayName: String {
        documentURL?.deletingPathExtension().lastPathComponent
            ?? pendingDocumentName ?? ""
    }

    /// Fired around scans triggered by the scanner's physical button.
    var onHardwareScanStarted: (() -> Void)?
    var onHardwareScanFinished: (() -> Void)?

    var settings = ScanSettings.load() {
        didSet {
            settings.save()
            if oldValue.hardwareButton != settings.hardwareButton {
                configureButtonWatch()
            }
            if oldValue.appendScans, !settings.appendScans {
                documentOpen = false
            }
        }
    }

    private var deviceID: String?
    private var currentProcess: Process?
    private var pollInFlight = false
    private var watchTask: Task<Void, Never>?
    private var usbWatcher: USBWatcher?
    private let sessionDirectory: URL

    private static let ix500VendorID = 0x04C5
    private static let ix500ProductID = 0x132B

    /// Root of the SANE installation: contains bin/scanimage, lib/, etc/sane.d/.
    /// Resolution order: explicit env override, the app bundle, then the dev checkout.
    nonisolated static func sanePrefix() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SNAPSCAN_SANE_PREFIX"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("sane"))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("vendor"))
        return candidates.first {
            FileManager.default.isExecutableFile(
                atPath: $0.appendingPathComponent("bin/scanimage").path)
        }
    }

    init() {
        sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapScan", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: sessionDirectory, withIntermediateDirectories: true)
        configureButtonWatch()

        usbWatcher = USBWatcher(
            vendorID: Self.ix500VendorID, productID: Self.ix500ProductID
        ) { [weak self] present in
            Task { @MainActor in self?.scannerPresenceChanged(present) }
        }
        if let usbWatcher {
            scannerPresent = usbWatcher.present
        } else {
            // IOKit unavailable: assume present rather than blocking scans.
            scannerPresent = true
        }
        if scannerPresent {
            Task { await self.detectScanner() }
        } else {
            status = .noScanner
        }
    }

    private func scannerPresenceChanged(_ present: Bool) {
        scannerPresent = present
        if present {
            Task { await detectScanner() }
        } else {
            deviceID = nil
            if !isBusy { status = .noScanner }
        }
    }

    var isBusy: Bool {
        switch status {
        case .detecting, .scanning, .processing: true
        default: false
        }
    }

    // MARK: - Detection

    func detectScanner() async {
        guard !isBusy else { return }
        status = .detecting
        await drainPoll()
        lastError = nil
        defer { status = deviceID == nil ? .noScanner : .idle }

        guard let prefix = Self.sanePrefix() else {
            lastError = "Bundled scanner tools not found"
            deviceID = nil
            return
        }
        do {
            let result = try await Self.run(
                prefix: prefix,
                arguments: ["-f", "%d|%v %m%n"])
            let line = result.stdout
                .split(separator: "\n")
                .first { $0.contains("|") }
            if let line, let separator = line.firstIndex(of: "|") {
                deviceID = String(line[..<separator])
                scannerName = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                deviceID = nil
                scannerName = nil
            }
        } catch {
            deviceID = nil
            scannerName = nil
            lastError = error.localizedDescription
        }
    }

    // MARK: - Scanning

    func scan() async {
        guard !isBusy else { return }
        feederWasEmpty = false
        lastError = nil

        // The previous document was finalized; a new scan starts a new one.
        if !documentOpen, !pages.isEmpty {
            discardSessionPages()
            documentURL = nil
            pendingDocumentName = nil
        }
        // Propose a name up front so the UI can offer it for editing while
        // the scan runs. A name typed before a failed attempt is kept.
        if documentURL == nil, pendingDocumentName == nil {
            pendingDocumentName = Self.defaultDocumentName()
        }

        if deviceID == nil {
            await detectScanner()
            guard deviceID != nil else { return }
        }
        guard let device = deviceID, let prefix = Self.sanePrefix() else { return }

        status = .scanning(page: pages.count + 1)
        await drainPoll()

        let batchDirectory = sessionDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: batchDirectory, withIntermediateDirectories: true)

        let paper = settings.paperSize.millimeters
        var arguments = [
            "-d", device,
            "--source", settings.source.rawValue,
            "--mode", settings.mode.rawValue,
            "--resolution", String(settings.resolution),
            "--page-width", String(paper.width),
            "--page-height", String(paper.height),
            "-x", String(paper.width),
            "-y", String(paper.height),
            "--format=pnm",
            "--batch=\(batchDirectory.path)/page%04d.pnm",
        ]
        // Deskew is done in-app (Vision-based, confidence-gated) rather than
        // with --swdeskew: the backend's estimator guesses badly on sparse
        // pages and visibly tilts straight ones.
        if settings.autocrop { arguments.append("--swcrop=yes") }
        if settings.skipBlankPages { arguments += ["--swskip", "1.0"] }

        let alreadyScanned = pages.count
        var runError: String?
        var exitCode: Int32 = 0
        var stderr = ""
        do {
            let result = try await Self.run(
                prefix: prefix,
                arguments: arguments,
                onProcessStart: { [weak self] process in
                    Task { @MainActor in self?.currentProcess = process }
                },
                onStderrLine: { [weak self] line in
                    guard line.hasPrefix("Scanning page ") else { return }
                    let number = Int(line.dropFirst("Scanning page ".count)) ?? 1
                    Task { @MainActor in
                        self?.status = .scanning(page: alreadyScanned + number)
                    }
                })
            exitCode = result.exitCode
            stderr = result.stderr
        } catch {
            runError = error.localizedDescription
        }
        currentProcess = nil

        await collectPages(from: batchDirectory, dpi: settings.resolution)

        if pages.count > alreadyScanned {
            saveDocument()
            documentOpen = settings.appendScans
        } else if let runError {
            lastError = runError
        } else if exitCode == 7 {
            // SANE_STATUS_NO_DOCS: the feeder is empty.
            feederWasEmpty = true
        } else if exitCode != 0 {
            lastError = Self.friendlyError(from: stderr, exitCode: exitCode)
        }
        status = .idle
    }

    func cancelScan() {
        currentProcess?.terminate()
    }

    /// Finalizes the current document: the next scan starts a new PDF.
    func done() {
        discardSessionPages()
        documentURL = nil
        documentOpen = false
        pendingDocumentName = nil
        currentDocumentID = nil
        feederWasEmpty = false
        lastError = nil
    }

    /// Renames the current document (on disk once it exists).
    func renameDocument(to rawName: String) {
        let cleaned = Self.sanitizeFileName(rawName)
        guard !cleaned.isEmpty else { return }
        guard let current = documentURL else {
            pendingDocumentName = cleaned
            return
        }
        guard cleaned != current.deletingPathExtension().lastPathComponent else { return }
        let destination = uniqueDocumentURL(
            in: current.deletingLastPathComponent(), base: cleaned)
        do {
            try FileManager.default.moveItem(at: current, to: destination)
            documentURL = destination
            if let currentDocumentID {
                ScanLibrary.shared.noteSaved(id: currentDocumentID, url: destination)
            }
        } catch {
            lastError = "Couldn't rename: \(error.localizedDescription)"
        }
    }

    nonisolated static func sanitizeFileName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
        name = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func collectPages(from directory: URL, dpi: Int) async {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "pnm" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        for file in files {
            guard var image = try? PNM.decode(contentsOf: file) else { continue }
            if settings.autoRotate || settings.deskew {
                status = .processing(page: pages.count + 1)
                let original = image
                let autoRotate = settings.autoRotate
                let deskew = settings.deskew
                image = await Task.detached(priority: .userInitiated) {
                    var corrected = original
                    if autoRotate {
                        let rotation = OrientationDetector.rotationToUpright(for: corrected)
                        if rotation != 0,
                            let rotated = corrected.rotated(byDegreesClockwise: rotation) {
                            corrected = rotated
                        }
                    }
                    if deskew,
                        let angle = OrientationDetector.skewCorrectionDegrees(for: corrected),
                        let straightened = corrected.rotatedBySmallAngle(
                            degreesClockwise: angle) {
                        corrected = straightened
                    }
                    return corrected
                }.value
            }
            pages.append(ScannedPage(fileURL: file, image: image, dpi: dpi))
        }
    }

    private nonisolated static func friendlyError(from stderr: String, exitCode: Int32) -> String {
        if stderr.contains("Device busy") {
            return "The scanner is busy — is another scanning app using it?"
        }
        if stderr.contains("jammed") {
            return "Paper jam — clear the feeder and try again."
        }
        if stderr.contains("cover open") {
            return "The scanner cover is open."
        }
        let lines = stderr.split(separator: "\n").map(String.init)
        let detail = lines.first { $0.contains("scanimage:") } ?? lines.last ?? ""
        return detail.isEmpty ? "Scan failed (exit code \(exitCode))" : detail
    }

    // MARK: - Document persistence

    /// Writes/rewrites the current document PDF in the destination folder.
    private func saveDocument() {
        guard !pages.isEmpty else { return }
        do {
            let directory = settings.destinationURL
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            if documentURL == nil {
                let base = pendingDocumentName ?? Self.defaultDocumentName()
                documentURL = uniqueDocumentURL(in: directory, base: base)
                pendingDocumentName = nil
            }
            guard let documentURL else { return }
            let staging = sessionDirectory.appendingPathComponent("staging.pdf")
            try PDFBuilder.write(pages: pages, to: staging)
            if FileManager.default.fileExists(atPath: documentURL.path) {
                _ = try FileManager.default.replaceItemAt(documentURL, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: documentURL)
            }
            if let currentDocumentID {
                ScanLibrary.shared.noteSaved(id: currentDocumentID, url: documentURL)
            } else {
                let id = UUID()
                currentDocumentID = id
                ScanLibrary.shared.add(id: id, url: documentURL)
            }
        } catch {
            lastError = "Couldn't save PDF: \(error.localizedDescription)"
        }
    }

    nonisolated private static func defaultDocumentName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Scan \(formatter.string(from: Date()))"
    }

    private func uniqueDocumentURL(in directory: URL, base: String) -> URL {
        var url = directory.appendingPathComponent("\(base).pdf")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(counter)).pdf")
            counter += 1
        }
        return url
    }

    /// Called when the user drags the current document's file out of the folder.
    func documentWasMoved(_ url: URL) {
        guard url == documentURL else { return }
        discardSessionPages()
        documentURL = nil
        documentOpen = false
        pendingDocumentName = nil
        currentDocumentID = nil
    }

    // MARK: - Page management

    func deletePage(_ page: ScannedPage) {
        deletePages(withIDs: [page.id])
    }

    func deletePages(withIDs ids: Set<UUID>) {
        let doomed = pages.filter { ids.contains($0.id) }
        guard !doomed.isEmpty else { return }
        for page in doomed {
            try? FileManager.default.removeItem(at: page.fileURL)
        }
        pages.removeAll { ids.contains($0.id) }
        if pages.isEmpty {
            // All content removed: the document no longer has meaning.
            if let documentURL {
                try? FileManager.default.removeItem(at: documentURL)
            }
            documentURL = nil
            documentOpen = false
            pendingDocumentName = nil
            currentDocumentID = nil
            ScanLibrary.shared.refresh()
        } else {
            saveDocument()
        }
    }

    private func discardSessionPages() {
        for page in pages {
            try? FileManager.default.removeItem(at: page.fileURL)
        }
        pages.removeAll()
    }

    // MARK: - Hardware button watch

    private func configureButtonWatch() {
        watchTask?.cancel()
        watchTask = nil
        guard settings.hardwareButton else { return }
        watchTask = Task { [weak self] in
            // Require seeing "released" once before triggering, so a latched or
            // held button can't fire a scan the moment the watcher starts.
            var previouslyPressed = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard self.status == .idle, !self.pollInFlight,
                    let device = self.deviceID,
                    let prefix = Self.sanePrefix()
                else { continue }

                self.pollInFlight = true
                let result = try? await Self.run(
                    prefix: prefix, arguments: ["-d", device, "-A"])
                self.pollInFlight = false

                guard let result, result.exitCode == 0,
                    let pressed = Self.parseSensor(named: "scan", in: result.stdout)
                else { continue }
                if pressed, !previouslyPressed {
                    self.onHardwareScanStarted?()
                    await self.scan()
                    self.onHardwareScanFinished?()
                }
                previouslyPressed = pressed
            }
        }
    }

    /// Waits for an in-flight button poll to release the device before scanning.
    private func drainPoll() async {
        while pollInFlight {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Parses a sensor's current value from `scanimage -A` output.
    /// Lines look like: `    --scan[=(yes|no)] [no] [hardware]`
    nonisolated static func parseSensor(named name: String, in output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            guard let optionRange = line.range(of: "--\(name)[") else { continue }
            let rest = line[optionRange.upperBound...]
            guard let closing = rest.range(of: "] [") else { continue }
            let value = rest[closing.upperBound...]
            if value.hasPrefix("yes]") { return true }
            if value.hasPrefix("no]") { return false }
        }
        return nil
    }

    // MARK: - Process plumbing

    struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private nonisolated static func run(
        prefix: URL,
        arguments: [String],
        onProcessStart: (@Sendable (Process) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = prefix.appendingPathComponent("bin/scanimage")
        process.arguments = arguments

        // Point the SANE dll loader at the bundled config and backend directories
        // (dll.c prepends LD_LIBRARY_PATH to its backend search path, on macOS too).
        var environment = ProcessInfo.processInfo.environment
        environment["SANE_CONFIG_DIR"] = prefix.appendingPathComponent("etc/sane.d").path
        environment["LD_LIBRARY_PATH"] = prefix.appendingPathComponent("lib/sane").path
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Register for termination before launching so the signal can never be missed.
        let (terminated, terminationSignal) = AsyncStream.makeStream(of: Void.self)
        process.terminationHandler = { _ in terminationSignal.finish() }

        try process.run()
        onProcessStart?(process)

        async let stdoutData = stdoutPipe.fileHandleForReading.readToEndAsync()
        var stderrText = ""
        for try await line in stderrPipe.fileHandleForReading.bytes.lines {
            stderrText += line + "\n"
            onStderrLine?(line)
        }
        let stdout = String(data: (try? await stdoutData) ?? Data(), encoding: .utf8) ?? ""

        for await _ in terminated {}
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderrText)
    }
}

extension FileHandle {
    fileprivate func readToEndAsync() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    continuation.resume(returning: try self.readToEnd() ?? Data())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
