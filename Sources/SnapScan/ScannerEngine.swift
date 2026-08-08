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
        case noScanner
    }

    var status: Status = .idle
    var scannerName: String?
    /// Live USB presence of the iX500 (event-driven via IOKit; the scanner
    /// powers its USB interface off when the feeder flap is closed).
    var scannerPresent = false
    var lastError: String?
    var feederWasEmpty = false
    /// True while a PDF is being written. The write runs off the main
    /// actor, so the UI stays live and can show it.
    var isSaving = false

    /// True while the on-device model is reading the scan to propose a name.
    var isNaming = false

    /// The page currently coming out of the scanner, updated as rows arrive.
    var livePageImage: CGImage?
    var livePageFraction: Double?

    /// The document shown in the grid and named in the header.
    var current: ActiveDocument?
    /// Finalized documents whose straightening/saving is still draining.
    var backgroundDocuments: [ActiveDocument] = []

    /// Fired around scans triggered by the scanner's physical button.
    var onHardwareScanStarted: (() -> Void)?
    var onHardwareScanFinished: (() -> Void)?

    // Bridges for views that talk about "the" document.
    var pages: [ScannedPage] { current?.pages ?? [] }
    var documentURL: URL? { current?.url }
    var documentOpen: Bool { current.map { $0.isOpen && !$0.pages.isEmpty } ?? false }
    var documentDisplayName: String { current?.displayName ?? "" }
    /// URLs that belong to in-flight documents (hidden from the saved list).
    var inFlightURLs: Set<URL> {
        var documents = backgroundDocuments
        if let current { documents.append(current) }
        return Set(documents.compactMap(\.url))
    }

    var settings = ScanSettings.load() {
        didSet {
            settings.save()
            if oldValue.hardwareButton != settings.hardwareButton {
                configureButtonWatch()
            }
            if oldValue.appendScans, !settings.appendScans {
                current?.isOpen = false
            }
        }
    }

    private var deviceID: String?
    private var watchTask: Task<Void, Never>?
    private var usbWatcher: USBWatcher?
    private let sessionDirectory: URL

    private static let ix500VendorID = 0x04C5
    private static let ix500ProductID = 0x132B

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
            Task { await NativeScanner.shared.close() }
            if !isBusy { status = .noScanner }
        }
    }

    /// True while the scanner hardware is in use (background straightening
    /// does not count — new scans may start over it).
    var isBusy: Bool {
        switch status {
        case .detecting, .scanning: true
        default: false
        }
    }

    /// True while any document still has pages being straightened.
    var isProcessingAnywhere: Bool {
        (current?.processingRemaining ?? 0) > 0
            || backgroundDocuments.contains { $0.processingRemaining > 0 }
    }

    /// What is happening to the current document right now, for the status
    /// line under its name. nil when nothing is in flight.
    var activity: String? {
        var scanningPage: Int?
        if case .scanning(let page) = status { scanningPage = page }
        return Self.activityDescription(
            scanningPage: scanningPage,
            isSaving: isSaving,
            isNaming: isNaming,
            pagesProcessing: current?.processingRemaining ?? 0)
    }

    /// The phases overlap — pages straighten while the next sheet feeds, and
    /// naming runs alongside straightening — so they're reported in the order
    /// that matters to someone waiting: what holds the paper, then what holds
    /// the controls, then the background work.
    nonisolated static func activityDescription(
        scanningPage: Int?, isSaving: Bool, isNaming: Bool, pagesProcessing: Int
    ) -> String? {
        if let scanningPage { return "Scanning page \(scanningPage)…" }
        if isSaving { return "Saving the PDF…" }
        if isNaming { return "Reading the scan to suggest a name…" }
        if pagesProcessing > 0 {
            return "Straightening \(pagesProcessing) page"
                + (pagesProcessing == 1 ? "…" : "s…")
        }
        return nil
    }

    // MARK: - Detection

    func detectScanner() async {
        guard !isBusy else { return }
        guard NativeScanner.isPresent() else {
            deviceID = nil
            scannerName = nil
            status = .noScanner
            return
        }
        status = .detecting
        lastError = nil
        defer { status = deviceID == nil ? .noScanner : .idle }

        do {
            let device = try await NativeScanner.shared.open()
            deviceID = "\(device.vendor) \(device.model)"
            scannerName = deviceID
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

        // A finalized document makes way for a new one; if it still has
        // work draining it becomes a background "in process" row.
        if let document = current, !document.isOpen {
            retireCurrentDocument()
        }
        let document: ActiveDocument
        if let existing = current {
            document = existing
        } else {
            document = ActiveDocument(pendingName: Self.defaultDocumentName())
            current = document
        }

        if deviceID == nil {
            await detectScanner()
            guard deviceID != nil else { return }
        }

        status = .scanning(page: document.pages.count + 1)
        let currentSettings = settings

        do {
            let result = try await NativeScanner.shared.scanBatch(
                settings: currentSettings,
                startingAtPage: document.pages.count
            ) { [weak self] event in
                Task { @MainActor in self?.handleBatchEvent(event, for: document) }
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

        if !document.pages.isEmpty {
            // Save now with whatever images exist (crash-safe); straightened
            // pages trigger a rewrite as they drain.
            await save(document)
            if document.processingRemaining > 0 {
                document.needsFinalSave = true
            }
            // Reading the page and asking the model for a name takes a couple
            // of seconds — unattached, so the next sheet can go in meanwhile.
            Task { await self.suggestName(for: document) }
            if !settings.appendScans {
                document.isOpen = false
            }
        }
        status = .idle
    }

    private func handleBatchEvent(
        _ event: NativeScanner.BatchEvent, for document: ActiveDocument
    ) {
        switch event {
        case .pageStarted(let index):
            status = .scanning(page: index + 1)
            livePageImage = nil
            livePageFraction = nil
        case .pagePartial(_, let image, let fraction):
            livePageImage = image
            livePageFraction = fraction
        case .pageComplete(_, let image):
            var page = ScannedPage(image: image, dpi: settings.resolution)
            let wantsProcessing =
                settings.autoRotate || settings.deskew || settings.paperSize == .auto
                || settings.searchableText
            page.isProcessing = wantsProcessing
            document.pages.append(page)
            livePageImage = nil
            livePageFraction = nil
            if wantsProcessing {
                startProcessing(pageID: page.id, in: document)
            }
        }
    }

    /// Straightens (and in auto size mode, crops and size-snaps) one page
    /// concurrently; the grid shows a spinner on the page's cell meanwhile.
    /// Scanning (even of the next document) continues.
    private func startProcessing(pageID: UUID, in document: ActiveDocument) {
        document.processingRemaining += 1
        let autoRotate = settings.autoRotate
        let deskew = settings.deskew
        let autoSize = settings.paperSize == .auto
        let searchable = settings.searchableText
        let dpi = settings.resolution
        guard let original = document.pages.first(where: { $0.id == pageID })?.image
        else {
            document.processingRemaining -= 1
            return
        }
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                var image = original
                if autoSize, let bounds = PageGeometry.contentBounds(of: image),
                    let cropped = image.cropping(to: bounds) {
                    image = cropped
                }
                if autoRotate {
                    let rotation = await OrientationDetector.rotationToUpright(for: image)
                    if rotation != 0,
                        let rotated = image.rotated(byDegreesClockwise: rotation) {
                        image = rotated
                    }
                }
                if deskew,
                    let angle = await OrientationDetector.skewCorrectionDegrees(for: image),
                    let straightened = image.rotatedBySmallAngle(degreesClockwise: angle) {
                    image = straightened
                }
                // Snap after all rotations so the measured orientation is final.
                var snapped: (name: String, widthMM: Double, heightMM: Double)? = nil
                if autoSize {
                    snapped = PageGeometry.snappedSize(
                        widthMM: Double(image.width) / Double(dpi) * 25.4,
                        heightMM: Double(image.height) / Double(dpi) * 25.4)
                }
                // Read the page last: the text layer's coordinates have to
                // describe the image as it will finally be drawn, after every
                // crop and rotation.
                let textLines = searchable ? await TextLayer.recognize(in: image) : []
                return (image: image, snapped: snapped, textLines: textLines)
            }.value

            if let index = document.pages.firstIndex(where: { $0.id == pageID }) {
                document.pages[index].image = result.image
                document.pages[index].isProcessing = false
                document.pages[index].snappedSizeName = result.snapped?.name
                document.pages[index].snappedSizeMM = result.snapped.map {
                    CGSize(width: $0.widthMM, height: $0.heightMM)
                }
                document.pages[index].textLines = result.textLines
            }
            document.processingRemaining -= 1
            await self.processingDrained(for: document)
        }
    }

    private func processingDrained(for document: ActiveDocument) async {
        guard document.processingRemaining == 0 else { return }
        if document.needsFinalSave {
            document.needsFinalSave = false
            await save(document)
        }
        if document.isRetired {
            backgroundDocuments.removeAll { $0.id == document.id }
            ScanLibrary.shared.refresh()
        }
    }

    /// Moves the current document out of the way; it lingers as a background
    /// row while straightening or saving is still pending.
    private func retireCurrentDocument() {
        guard let document = current else { return }
        document.isOpen = false
        document.isRetired = true
        if document.processingRemaining > 0 || document.needsFinalSave {
            backgroundDocuments.append(document)
        }
        current = nil
        ScanLibrary.shared.refresh()
    }

    func cancelScan() {
        NativeScanner.shared.cancelFlag.cancel()
    }

    /// Waits until everything queued for the current document has finished:
    /// straightening, the text layer, the suggested name and the final save.
    ///
    /// The paper stops moving well before the PDF is final, so anything that
    /// hands the file to someone else — an intent returning it to Shortcuts —
    /// has to wait here first. Gives up rather than hanging if work stalls.
    func settle(timeout: Duration = .seconds(180)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let pending =
                (current?.processingRemaining ?? 0) > 0
                || current?.needsFinalSave == true
                || isSaving || isNaming
            if !pending { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A discarded scan, kept whole so undo can bring it back.
    struct DiscardedScan {
        let document: ActiveDocument
        let from: URL?
        let inTrash: URL?
    }

    /// Abandons the scan in progress: its pages are dropped and the PDF
    /// written so far goes to the Trash, where it can still be recovered.
    @discardableResult
    func discardCurrent() -> DiscardedScan? {
        guard let document = current else { return nil }
        var trashed: NSURL?
        if let url = document.url {
            try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        }
        current = nil
        feederWasEmpty = false
        lastError = nil
        ScanLibrary.shared.refresh()
        return DiscardedScan(
            document: document, from: document.url, inTrash: trashed as URL?)
    }

    /// Reinstates a discarded scan, taking its PDF back out of the Trash.
    func restore(_ discarded: DiscardedScan) {
        current = discarded.document
        if let inTrash = discarded.inTrash, let from = discarded.from,
            (try? FileManager.default.moveItem(at: inTrash, to: from)) != nil {
            ScanLibrary.shared.noteSaved(id: discarded.document.id, url: from)
        } else {
            // Emptied Trash, or a file moved since: the pages are still in
            // memory, so write it out again.
            Task { await save(discarded.document) }
        }
        ScanLibrary.shared.refresh()
    }

    /// Finalizes the current document: the next scan starts a new PDF.
    func done() {
        retireCurrentDocument()
        feederWasEmpty = false
        lastError = nil
    }

    /// Adopts a user-chosen scans folder: the security-scoped bookmark from
    /// the open panel's selection is what carries sandbox access to it.
    func setDestination(_ url: URL) {
        settings.destinationBookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        settings.destinationPath = (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Renames the current document (on disk once it exists).
    func renameDocument(to rawName: String) {
        guard let document = current else { return }
        let cleaned = Self.sanitizeFileName(rawName)
        guard !cleaned.isEmpty else { return }
        guard let currentURL = document.url else {
            document.pendingName = cleaned
            return
        }
        guard cleaned != currentURL.deletingPathExtension().lastPathComponent else { return }
        let destination = uniqueDocumentURL(
            in: currentURL.deletingLastPathComponent(), base: cleaned)
        do {
            try FileManager.default.moveItem(at: currentURL, to: destination)
            document.url = destination
            ScanLibrary.shared.noteSaved(id: document.id, url: destination)
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

    /// Writes/rewrites a document's PDF in the destination folder.
    private func save(_ document: ActiveDocument) async {
        guard !document.pages.isEmpty else { return }
        do {
            let directory = settings.destinationURL
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            if document.url == nil {
                let base = document.pendingName ?? Self.defaultDocumentName()
                document.url = uniqueDocumentURL(in: directory, base: base)
                document.pendingName = nil
            }
            guard let url = document.url else { return }
            let staging = sessionDirectory.appendingPathComponent("staging-\(document.id).pdf")
            // Rendering pages into a PDF is the slow part — tens of
            // megabytes per page — so it runs off the main actor.
            isSaving = true
            defer { isSaving = false }
            let pages = document.pages
            let compression = settings.compression
            try await Task.detached(priority: .userInitiated) {
                try PDFBuilder.write(pages: pages, to: staging, compression: compression)
            }.value
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: url)
            }
            ScanLibrary.shared.noteSaved(id: document.id, url: url)
        } catch {
            lastError = "Couldn't save PDF: \(error.localizedDescription)"
        }
    }

    nonisolated private static func defaultDocumentName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Scan \(formatter.string(from: Date()))"
    }

    /// Whether a name is one this app made up rather than one someone chose —
    /// including the " (2)" a collision adds. Only such a name gets replaced
    /// by a suggestion.
    nonisolated static func isDefaultDocumentName(_ name: String) -> Bool {
        name.wholeMatch(
            of: /Scan \d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}( \(\d+\))?/) != nil
    }

    // MARK: - Suggested names

    /// Names a new document after what's written on it, when the on-device
    /// model can read enough to say. Silent on failure: an unnamed scan keeps
    /// its timestamp, which is no worse than before.
    private func suggestName(for document: ActiveDocument) async {
        guard settings.suggestNames, !document.didSuggestName else { return }
        // Anything but the timestamp name was chosen deliberately.
        guard Self.isDefaultDocumentName(document.displayName) else { return }
        document.didSuggestName = true

        let images = document.pages.prefix(NameSuggester.pagesRead).map(\.image)
        isNaming = true
        let suggestion = await NameSuggester.suggest(for: Array(images))
        isNaming = false

        guard let suggestion else { return }
        // The document may have been finished, discarded, or named by hand
        // while the model was reading it.
        guard current === document,
            Self.isDefaultDocumentName(document.displayName)
        else { return }
        renameDocument(to: suggestion)
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
        guard let document = current, document.url == url else { return }
        current = nil
    }

    // MARK: - Page management

    func deletePage(_ page: ScannedPage) {
        deletePages(withIDs: [page.id])
    }

    /// What a deletion took away, so it can be put back.
    struct PageDeletion {
        let document: ActiveDocument
        let entries: [(index: Int, page: ScannedPage)]
    }

    @discardableResult
    func deletePages(withIDs ids: Set<UUID>) -> PageDeletion? {
        guard !isBusy, let document = current else { return nil }
        let removed = document.pages.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { (index: $0.offset, page: $0.element) }
        guard !removed.isEmpty else { return nil }
        document.pages.removeAll { ids.contains($0.id) }
        if document.pages.isEmpty {
            // All content removed: the document no longer has meaning.
            if let url = document.url {
                try? FileManager.default.removeItem(at: url)
            }
            current = nil
            ScanLibrary.shared.refresh()
        } else {
            Task { await save(document) }
        }
        return PageDeletion(document: document, entries: removed)
    }

    /// Puts deleted pages back where they were and rewrites the PDF.
    func restore(_ deletion: PageDeletion) {
        let document = deletion.document
        // Ascending, so each insertion index still means what it did when the
        // pages were taken out.
        for entry in deletion.entries.sorted(by: { $0.index < $1.index }) {
            document.pages.insert(entry.page, at: min(entry.index, document.pages.count))
        }
        // Deleting the last page retires the document; bringing a page back
        // brings the document with it.
        if current == nil { current = document }
        Task { await save(document) }
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

                guard let pressed = await NativeScanner.shared.scanButtonPressed() else {
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
