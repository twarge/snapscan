import AppKit
import Foundation

enum ScanSource: String, CaseIterable, Identifiable {
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

enum ScanMode: String, CaseIterable, Identifiable {
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

enum PaperSize: String, CaseIterable, Identifiable {
    case letter = "Letter"
    case a4 = "A4"
    case legal = "Legal"

    var id: String { rawValue }

    /// Width and height in millimeters, as expected by scanimage geometry options.
    /// Values are clamped to the iX500's maximum scan width (215.872 mm).
    var millimeters: (width: Double, height: Double) {
        switch self {
        case .letter: (215.872, 279.4)
        case .a4: (210.0, 297.0)
        case .legal: (215.872, 355.6)
        }
    }
}

struct ScanSettings: Codable {
    var source: ScanSource = .duplex
    var mode: ScanMode = .color
    var resolution: Int = 300
    var paperSize: PaperSize = .letter
    var deskew: Bool = true
    var autocrop: Bool = false
    var skipBlankPages: Bool = false
    var autoRotate: Bool = true
    var hardwareButton: Bool = true
    var destinationPath: String = "~/Documents/Scans"
    var appendScans: Bool = true
    var menuBarOnly: Bool = false
    var launchAtLogin: Bool = false

    static let resolutions = [150, 200, 300, 400, 600]

    var destinationURL: URL {
        URL(
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

struct ScannedPage: Identifiable {
    let id = UUID()
    var image: CGImage
    let dpi: Int

    var thumbnail: NSImage {
        NSImage(cgImage: image, size: sizeInPoints)
    }

    /// Physical page size in PDF points (1/72 inch), derived from pixel size and scan DPI.
    var sizeInPoints: CGSize {
        CGSize(
            width: CGFloat(image.width) * 72.0 / CGFloat(dpi),
            height: CGFloat(image.height) * 72.0 / CGFloat(dpi)
        )
    }
}
