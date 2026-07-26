import CoreGraphics
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

    /// The page currently coming out of the scanner, updated as rows arrive.
    var livePageImage: CGImage?
    var livePageFraction: Double?

    /// The PDF the current pages are saved to (nil until the first batch lands).
    var documentURL: URL?
    /// True while the document accepts more batches; false once finalized via Done.
    var documentOpen = false
    /// Name (without extension) chosen for a document that hasn't been saved yet.
    var pendingDocumentName: String?
    /// Library identity of the current document.
    private var currentDocumentID: UUID?

    /// Fired around scans triggered by the scanner's physical button.
    var onHardwareScanStarted: (() -> Void)?
    var onHardwareScanFinished: (() -> Void)?

    /// The current document's name (without extension) for display and editing.
    var documentDisplayName: String {
        documentURL?.deletingPathExtension().lastPathComponent
            ?? pendingDocumentName ?? ""
    }

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
    private var watchTask: Task<Void, Never>?
    private var usbWatcher: USBWatcher?
    private let sessionDirectory: URL

    private static let ix500VendorID = 0x04C5
    private static let ix500ProductID = 0x132B

    /// Root of the SANE installation: contains lib/, etc/sane.d/.
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
            FileManager.default.isReadableFile(
                atPath: $0.appendingPathComponent("lib/sane/libsane-fujitsu.1.so").path)
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
            Task { await SaneSession.shared.closeDevice() }
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
        guard let prefix = Self.sanePrefix() else {
            lastError = "Bundled scanner library not found"
            status = .noScanner
            return
        }
        status = .detecting
        lastError = nil
        defer { status = deviceID == nil ? .noScanner : .idle }

        do {
            let devices = try await SaneSession.shared.listDevices(prefix: prefix)
            guard let device = devices.first else {
                deviceID = nil
                scannerName = nil
                return
            }
            try await SaneSession.shared.open(device: device.name, prefix: prefix)
            deviceID = device.name
            scannerName = "\(device.vendor) \(device.model)"
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

        let firstPageIndex = pages.count
        status = .scanning(page: firstPageIndex + 1)
        let currentSettings = settings

        do {
            let result = try await SaneSession.shared.scanBatch(
                settings: currentSettings,
                startingAtPage: firstPageIndex
            ) { [weak self] event in
                Task { @MainActor in self?.handleBatchEvent(event) }
            }
            livePageImage = nil
            livePageFraction = nil
            if result.feederWasEmpty {
                feederWasEmpty = true
            }
        } catch {
            livePageImage = nil
            livePageFraction = nil
            lastError = error.localizedDescription
        }

        await postProcessPages(startingAt: firstPageIndex)

        if pages.count > firstPageIndex {
            saveDocument()
            documentOpen = settings.appendScans
        }
        status = .idle
    }

    private func handleBatchEvent(_ event: SaneSession.BatchEvent) {
        switch event {
        case .pageStarted(let index):
            status = .scanning(page: index + 1)
            livePageImage = nil
            livePageFraction = nil
        case .pagePartial(_, let image, let fraction):
            livePageImage = image
            livePageFraction = fraction
        case .pageComplete(_, let image):
            pages.append(ScannedPage(image: image, dpi: settings.resolution))
            livePageImage = nil
            livePageFraction = nil
        }
    }

    /// Straightens/rotates freshly scanned pages in place. The raw pages are
    /// already visible in the grid; corrections swap in as they finish.
    private func postProcessPages(startingAt firstIndex: Int) async {
        guard settings.autoRotate || settings.deskew else { return }
        let autoRotate = settings.autoRotate
        let deskew = settings.deskew
        var index = firstIndex
        while index < pages.count {
            status = .processing(page: index + 1)
            let original = pages[index].image
            let corrected = await Task.detached(priority: .userInitiated) {
                var image = original
                if autoRotate {
                    let rotation = OrientationDetector.rotationToUpright(for: image)
                    if rotation != 0,
                        let rotated = image.rotated(byDegreesClockwise: rotation) {
                        image = rotated
                    }
                }
                if deskew,
                    let angle = OrientationDetector.skewCorrectionDegrees(for: image),
                    let straightened = image.rotatedBySmallAngle(degreesClockwise: angle) {
                    image = straightened
                }
                return image
            }.value
            if index < pages.count {
                pages[index].image = corrected
            }
            index += 1
        }
    }

    func cancelScan() {
        SaneSession.shared.cancelBox.cancel()
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
        guard !isBusy else { return }
        let countBefore = pages.count
        pages.removeAll { ids.contains($0.id) }
        guard pages.count != countBefore else { return }
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
                guard self.status == .idle, self.scannerPresent, self.deviceID != nil
                else { continue }

                guard let pressed = await SaneSession.shared.readSensor("scan") else {
                    continue
                }
                if pressed, !previouslyPressed {
                    self.onHardwareScanStarted?()
                    await self.scan()
                    self.onHardwareScanFinished?()
                }
                previouslyPressed = pressed
            }
        }
    }
}
