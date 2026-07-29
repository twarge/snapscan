import AppKit
import Foundation

nonisolated enum ScanSource: String, CaseIterable, Identifiable {
    case duplex = "ADF Duplex"
    case front = "ADF Front"
    case back = "ADF Back"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .duplex: "Both sides"
        case .front: "Front side"
        case .back: "Back side"
        }
    }
}

nonisolated enum ScanMode: String, CaseIterable, Identifiable {
    case color = "Color"
    case gray = "Gray"
    case lineart = "Lineart"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .color: "Color"
        case .gray: "Grayscale"
        case .lineart: "Black & White"
        }
    }
}

nonisolated enum PaperSize: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case letter = "Letter"
    case a4 = "A4"
    case legal = "Legal"

    var id: String { rawValue }

    /// Scan-area width and height in millimeters. Values are clamped to the
    /// iX500's maximum scan width (215.872 mm). Auto acquires oversized —
    /// full width, generous length — and relies on hardware length detection
    /// plus content-bounds cropping to find the real page.
    var millimeters: (width: Double, height: Double) {
        switch self {
        // Auto: the backend's maximum length — hardware length detection
        // ends the frame at the paper's real edge, so requesting the
        // maximum costs nothing and long receipts fit.
        case .auto: (215.872, 876.0)
        case .letter: (215.872, 279.4)
        case .a4: (210.0, 297.0)
        case .legal: (215.872, 355.6)
        }
    }

    /// Exact dimensions in the scanner's 1/1200-inch geometry units. Derived
    /// from the nominal paper size rather than the millimetre values above,
    /// which SANE clamps to the scanner's maximum width (215.872 mm) and so
    /// land a unit short of a true 8.5 inches.
    var geometryUnits: (width: Int, length: Int) {
        switch self {
        case .auto: (10200, 41400)  // 8.5 in wide, 34.5 in max length
        case .letter: (10200, 13200)  // 8.5 x 11 in
        case .a4: (9921, 14031)  // 210 x 297 mm
        case .legal: (10200, 16800)  // 8.5 x 14 in
        }
    }
}

nonisolated struct ScanSettings: Codable {
    var source: ScanSource = .duplex
    var mode: ScanMode = .color
    var resolution: Int = 300
    var paperSize: PaperSize = .letter
    var deskew: Bool = true
    var autocrop: Bool = false
    var skipBlankPages: Bool = false
    var autoRotate: Bool = true
    var hardwareButton: Bool = true
    /// Downloads works sandboxed without a grant (downloads entitlement),
    /// so it's a safe default even if the first-run prompt is dismissed.
    var destinationPath: String = "~/Downloads"
    /// Security-scoped bookmark for a user-chosen folder outside the sandbox
    /// container. Typed paths can't confer sandbox access; the picker can.
    var destinationBookmark: Data?
    /// The first-run folder prompt has been shown.
    var promptedForFolder: Bool = false
    var appendScans: Bool = true
    var menuBarOnly: Bool = false
    var launchAtLogin: Bool = false

    static let resolutions = [150, 200, 300, 400, 600]

    var destinationURL: URL {
        if let destinationBookmark,
            let url = DestinationAccess.shared.resolve(bookmark: destinationBookmark) {
            return url
        }
        return URL(
            fileURLWithPath: (destinationPath as NSString).expandingTildeInPath,
            isDirectory: true)
    }

    init() {}

    // Tolerate missing keys so adding fields never resets stored settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ScanSettings()
        source = try c.decodeIfPresent(ScanSource.self, forKey: .source) ?? defaults.source
        mode = try c.decodeIfPresent(ScanMode.self, forKey: .mode) ?? defaults.mode
        resolution = try c.decodeIfPresent(Int.self, forKey: .resolution) ?? defaults.resolution
        paperSize = try c.decodeIfPresent(PaperSize.self, forKey: .paperSize) ?? defaults.paperSize
        deskew = try c.decodeIfPresent(Bool.self, forKey: .deskew) ?? defaults.deskew
        autocrop = try c.decodeIfPresent(Bool.self, forKey: .autocrop) ?? defaults.autocrop
        skipBlankPages =
            try c.decodeIfPresent(Bool.self, forKey: .skipBlankPages) ?? defaults.skipBlankPages
        autoRotate = try c.decodeIfPresent(Bool.self, forKey: .autoRotate) ?? defaults.autoRotate
        hardwareButton =
            try c.decodeIfPresent(Bool.self, forKey: .hardwareButton) ?? defaults.hardwareButton
        destinationPath =
            try c.decodeIfPresent(String.self, forKey: .destinationPath)
            ?? defaults.destinationPath
        appendScans =
            try c.decodeIfPresent(Bool.self, forKey: .appendScans) ?? defaults.appendScans
        menuBarOnly =
            try c.decodeIfPresent(Bool.self, forKey: .menuBarOnly) ?? defaults.menuBarOnly
        launchAtLogin =
            try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        destinationBookmark =
            try c.decodeIfPresent(Data.self, forKey: .destinationBookmark)
        promptedForFolder =
            try c.decodeIfPresent(Bool.self, forKey: .promptedForFolder)
            ?? defaults.promptedForFolder
    }

    private static let defaultsKey = "scanSettings"

    static func load() -> ScanSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let settings = try? JSONDecoder().decode(ScanSettings.self, from: data)
        else { return ScanSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension ScanSource: Codable {}
extension ScanMode: Codable {}
extension PaperSize: Codable {}

/// Resolves and caches security-scoped destination folders. Each distinct
/// bookmark starts access once for the app's lifetime (the matching stop is
/// intentionally omitted — the grant must outlive every save).
nonisolated final class DestinationAccess: @unchecked Sendable {
    static let shared = DestinationAccess()
    private let lock = NSLock()
    private var cache: [Data: URL] = [:]

    func resolve(bookmark: Data) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[bookmark] { return cached }
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale)
        else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        cache[bookmark] = url
        return url
    }
}

/// A document being produced: pages accumulate while scanning, straighten in
/// the background, and the PDF (re)saves as work completes. Lives as the
/// engine's `current` document while visible in the grid, then — if work is
/// still pending when a new scan starts — as a background "in process" row
/// until its last page is straightened and the final PDF is written.
@MainActor
@Observable
final class ActiveDocument: Identifiable {
    /// Also the document's identity in the scan library.
    let id = UUID()
    var pages: [ScannedPage] = []
    var url: URL?
    var pendingName: String?
    /// Accepts more batches (combine mode, not yet finalized).
    var isOpen = true
    /// No longer the current document; discard once work drains.
    var isRetired = false
    /// Pages still being straightened.
    var processingRemaining = 0
    /// A save should run when processing drains.
    var needsFinalSave = false

    var displayName: String {
        url?.deletingPathExtension().lastPathComponent ?? pendingName ?? ""
    }

    init(pendingName: String? = nil) {
        self.pendingName = pendingName
    }
}

nonisolated struct ScannedPage: Identifiable {
    let id = UUID()
    var image: CGImage
    let dpi: Int
    /// True while the page is being auto-rotated/straightened in the background.
    var isProcessing = false
    /// Set when auto size detection snapped this page to a standard size:
    /// the PDF page takes this size and the image is centered on it.
    var snappedSizeName: String?
    var snappedSizeMM: CGSize?

    var thumbnail: NSImage {
        NSImage(cgImage: image, size: naturalSizeInPoints)
    }

    /// The image's physical size in PDF points, from pixel size and scan DPI.
    var naturalSizeInPoints: CGSize {
        CGSize(
            width: CGFloat(image.width) * 72.0 / CGFloat(dpi),
            height: CGFloat(image.height) * 72.0 / CGFloat(dpi)
        )
    }

    /// The PDF page size: the snapped standard size when there is one,
    /// otherwise the image's natural size.
    var sizeInPoints: CGSize {
        if let snappedSizeMM {
            return CGSize(
                width: snappedSizeMM.width / 25.4 * 72.0,
                height: snappedSizeMM.height / 25.4 * 72.0)
        }
        return naturalSizeInPoints
    }
}
