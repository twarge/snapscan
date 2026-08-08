import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Shortcuts, Spotlight and Siri surface for the app.
///
/// The driver talks to the scanner over USB from inside this process, so every
/// intent that touches hardware opens the app first — there's no daemon to
/// hand the work to.

// MARK: - Errors

nonisolated enum ScanIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noScanner
    case busy
    case feederEmpty
    case unsupportedResolution(Int)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noScanner:
            "No scanner is connected."
        case .busy:
            "SnapScan is already scanning."
        case .feederEmpty:
            "The feeder is empty — load paper and try again."
        case .unsupportedResolution(let dpi):
            "\(dpi) dpi isn't supported. Choose 150, 200, 300, 400 or 600."
        case .failed(let message):
            "The scan failed: \(message)"
        }
    }
}

// MARK: - Scanning

struct ScanDocumentIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Scan a Document"
    nonisolated static let description = IntentDescription(
        "Scans whatever is in the feeder and returns the finished PDF.",
        categoryName: "Scanning",
        searchKeywords: ["scan", "document", "pdf", "paper"])
    /// The scanner is driven from inside the app, so it has to be running.
    nonisolated static let openAppWhenRun = true

    @Parameter(title: "Sides")
    var sides: ScanSource?

    @Parameter(title: "Colour mode")
    var mode: ScanMode?

    @Parameter(title: "Resolution (dpi)")
    var resolution: Int?

    @Parameter(
        title: "Name",
        description: "Names the PDF. Left empty, SnapScan names it after the document.")
    var name: String?

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Scan a document") {
            \.$sides
            \.$mode
            \.$resolution
            \.$name
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let engine = ScannerEngine.shared
        guard !engine.isBusy else { throw ScanIntentError.busy }
        if let resolution, !ScanSettings.resolutions.contains(resolution) {
            throw ScanIntentError.unsupportedResolution(resolution)
        }

        // A scan in the window is the user's; don't fold shortcut pages into
        // it. Finish it first so this intent starts a document of its own.
        if engine.current != nil { engine.done() }

        // Overrides last for this scan only — the settings the user chose in
        // the window are put back before returning.
        let saved = engine.settings
        defer { engine.settings = saved }
        if let sides { engine.settings.source = sides }
        if let mode { engine.settings.mode = mode }
        if let resolution { engine.settings.resolution = resolution }
        // A caller-supplied name is a deliberate choice; don't let the model
        // rename the document out from under it.
        if name != nil { engine.settings.suggestNames = false }

        await engine.scan()

        if let error = engine.lastError { throw ScanIntentError.failed(error) }
        guard engine.pages.isEmpty == false else {
            throw engine.scannerName == nil
                ? ScanIntentError.noScanner : ScanIntentError.feederEmpty
        }
        if let name { engine.renameDocument(to: name) }

        // Straightening, the text layer and the final save all run after the
        // paper stops moving; the file isn't final until they drain.
        try await engine.settle()

        guard let url = engine.documentURL else {
            throw ScanIntentError.failed("the PDF was not written")
        }
        engine.done()
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent, type: .pdf))
    }
}

// MARK: - The scans already made

struct ScanEntity: AppEntity {
    nonisolated static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scan"
    nonisolated static let defaultQuery = ScanEntityQuery()

    let id: UUID
    @Property(title: "Name")
    var name: String
    @Property(title: "Scanned")
    var modified: Date
    let url: URL

    init(_ document: ScanDocument) {
        id = document.id
        url = document.url
        name = document.name
        modified = document.modified
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(modified.formatted(date: .abbreviated, time: .shortened))")
    }
}

struct ScanEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [ScanEntity.ID]) async throws -> [ScanEntity] {
        ScanLibrary.shared.documents
            .filter { identifiers.contains($0.id) }
            .map(ScanEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ScanEntity] {
        ScanLibrary.shared.documents.prefix(10).map(ScanEntity.init)
    }
}

struct LatestScanIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Get Latest Scan"
    nonisolated static let description = IntentDescription(
        "Returns the most recently saved PDF without scanning anything new.",
        categoryName: "Scanning")
    /// Only reads the library, but that library lives in the app.
    nonisolated static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        ScanLibrary.shared.refresh()
        guard let latest = ScanLibrary.shared.documents.first else {
            throw ScanIntentError.failed("there are no scans yet")
        }
        return .result(
            value: IntentFile(
                fileURL: latest.url, filename: latest.url.lastPathComponent, type: .pdf))
    }
}

// MARK: - Phrases

struct SnapScanShortcuts: AppShortcutsProvider {
    nonisolated static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanDocumentIntent(),
            phrases: [
                "Scan a document with \(.applicationName)",
                "Scan with \(.applicationName)",
                "Start a scan in \(.applicationName)",
            ],
            shortTitle: "Scan a Document",
            systemImageName: "doc.viewfinder")
        AppShortcut(
            intent: LatestScanIntent(),
            phrases: [
                "Get my latest \(.applicationName)",
                "Show my last scan in \(.applicationName)",
            ],
            shortTitle: "Latest Scan",
            systemImageName: "doc.text")
    }
}
