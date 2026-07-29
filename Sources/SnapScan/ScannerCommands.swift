import Foundation

/// SCSI command builders and response parsers for the scanner, per
/// docs/PROTOCOL.md. Opcodes and data layouts are the SCSI-2 scanner
/// device class except where marked vendor.
nonisolated enum ScannerCommands {
    // MARK: - Opcodes

    enum Opcode: UInt8 {
        case testUnitReady = 0x00
        case requestSense = 0x03
        case inquiry = 0x12
        case modeSelect = 0x15
        case modeSense = 0x1A
        case scan = 0x1B
        case setWindow = 0x24
        case read = 0x28
        case objectPosition = 0x31
        case hardwareStatus = 0xC2  // vendor
        case scannerControl = 0xF1  // vendor
    }

    /// READ data type codes (CDB byte 2).
    enum ReadType: UInt8 {
        case image = 0x00
        case pixelSize = 0x80
    }

    /// Window identifiers (docs/PROTOCOL.md §4.4).
    enum Window: UInt8 {
        case front = 0x00
        case back = 0x80
    }

    // MARK: - Command builders

    static func testUnitReady() -> [UInt8] {
        [Opcode.testUnitReady.rawValue, 0, 0, 0, 0, 0]
    }

    static func inquiry(allocationLength: Int = 96) -> [UInt8] {
        [Opcode.inquiry.rawValue, 0, 0, 0, UInt8(allocationLength), 0]
    }

    static func inquiryVendorPage(_ page: UInt8 = 0xF0, allocationLength: Int = 204) -> [UInt8] {
        // EVPD bit set, page code in byte 2.
        [Opcode.inquiry.rawValue, 0x01, page, 0, UInt8(allocationLength), 0]
    }

    static func requestSense(allocationLength: Int = 18) -> [UInt8] {
        [Opcode.requestSense.rawValue, 0, 0, 0, UInt8(allocationLength), 0]
    }

    static func hardwareStatus(allocationLength: Int = 12) -> [UInt8] {
        [Opcode.hardwareStatus.rawValue, 0, 0, 0, 0, 0, 0, 0, UInt8(allocationLength), 0]
    }

    /// Feed a sheet from the hopper (byte 1 = 0x01).
    static func objectPositionLoad() -> [UInt8] {
        [Opcode.objectPosition.rawValue, 0x01, 0, 0, 0, 0, 0, 0, 0, 0]
    }

    /// Start scanning the listed windows; the window IDs are the data-out
    /// phase, and byte 4 is their count.
    static func scan(windowCount: Int) -> [UInt8] {
        [Opcode.scan.rawValue, 0, 0, 0, UInt8(windowCount), 0]
    }

    static func read(type: ReadType, window: Window, length: Int) -> [UInt8] {
        [
            Opcode.read.rawValue,
            0,
            type.rawValue,
            0,
            0,
            window.rawValue,
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
            0,
        ]
    }

    static func setWindow(parameterLength: Int) -> [UInt8] {
        [
            Opcode.setWindow.rawValue, 0, 0, 0, 0, 0,
            UInt8((parameterLength >> 16) & 0xFF),
            UInt8((parameterLength >> 8) & 0xFF),
            UInt8(parameterLength & 0xFF),
            0,
        ]
    }

    // MARK: - Window descriptor

    /// Geometry is expressed in 1/1200 inch, independent of resolution
    /// (docs/PROTOCOL.md §5).
    static let geometryUnitsPerInch = 1200.0

    struct WindowSettings {
        var window: Window = .front
        var resolutionDPI: Int = 300
        var scanWidthUnits: Int = 10200  // 8.5 in
        var scanLengthUnits: Int = 13200  // 11 in
        var paperWidthUnits: Int = 10200
        var paperLengthUnits: Int = 13200

        static func units(millimeters: Double) -> Int {
            Int((millimeters / 25.4 * geometryUnitsPerInch).rounded())
        }

        /// Pixels across, as the device computes them.
        var pixelsWide: Int {
            scanWidthUnits * resolutionDPI / Int(geometryUnitsPerInch)
        }
    }

    /// Builds the 72-byte SET WINDOW parameter list (8-byte header plus a
    /// 64-byte descriptor). Composition is always RGB/8-bit: this scanner
    /// digitises in colour only, and gray/lineart are produced on the host.
    static func windowParameterList(_ settings: WindowSettings) -> Data {
        var payload = [UInt8](repeating: 0, count: 72)

        func putUInt16(_ value: Int, at offset: Int) {
            payload[offset] = UInt8((value >> 8) & 0xFF)
            payload[offset + 1] = UInt8(value & 0xFF)
        }
        func putUInt32(_ value: Int, at offset: Int) {
            payload[offset] = UInt8((value >> 24) & 0xFF)
            payload[offset + 1] = UInt8((value >> 16) & 0xFF)
            payload[offset + 2] = UInt8((value >> 8) & 0xFF)
            payload[offset + 3] = UInt8(value & 0xFF)
        }

        putUInt16(64, at: 6)  // window descriptor length
        payload[8] = settings.window.rawValue
        putUInt16(settings.resolutionDPI, at: 10)  // X resolution
        putUInt16(settings.resolutionDPI, at: 12)  // Y resolution
        putUInt32(0, at: 14)  // upper-left X
        putUInt32(0, at: 18)  // upper-left Y
        putUInt32(settings.scanWidthUnits, at: 22)
        putUInt32(settings.scanLengthUnits, at: 26)
        payload[30] = 0  // brightness
        payload[31] = 0  // threshold
        payload[32] = 0  // contrast
        payload[33] = 0x05  // image composition: RGB colour
        payload[34] = 8  // bits per pixel
        // Vendor block, constant in every capture; replayed verbatim.
        payload[48] = 0xC1
        payload[50] = 0x01
        payload[61] = 0xC0
        putUInt32(settings.paperWidthUnits, at: 64)
        putUInt32(settings.paperLengthUnits, at: 68)
        return Data(payload)
    }

    // MARK: - Response parsing

    struct Identity {
        let vendor: String
        let model: String
        /// SCSI peripheral device type; 0x06 is a scanner.
        let deviceType: UInt8
    }

    static func parseInquiry(_ data: Data) -> Identity? {
        guard data.count >= 32 else { return nil }
        let bytes = [UInt8](data)
        func text(_ range: Range<Int>) -> String {
            String(bytes: bytes[range], encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }
        return Identity(
            vendor: text(8..<16), model: text(16..<32), deviceType: bytes[0] & 0x1F)
    }

    /// The pixel-size read (type 0x80) reports width and line count as
    /// big-endian 32-bit pairs. With auto length detection the line count is
    /// an upper bound, not the true page length (docs/PROTOCOL.md §6).
    static func parsePixelSize(_ data: Data) -> (width: Int, lines: Int)? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        func uint32(_ offset: Int) -> Int {
            (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
        }
        return (uint32(0), uint32(4))
    }

    /// Meaning of a check-condition, from SCSI-2 fixed-format sense data.
    enum SenseVerdict: Equatable {
        /// End of page: the information field carries the unfilled residual.
        case endOfPage(residual: Int)
        /// That window has no data ready yet — retry the read.
        case notReadyRetry
        case other(key: UInt8, asc: UInt8, ascq: UInt8)
    }

    static func parseSense(_ data: Data) -> SenseVerdict? {
        guard data.count >= 14 else { return nil }
        let bytes = [UInt8](data)
        let key = bytes[2] & 0x0F
        let endOfMedium = (bytes[2] & 0x40) != 0
        let incorrectLength = (bytes[2] & 0x20) != 0
        let information =
            (Int(bytes[3]) << 24) | (Int(bytes[4]) << 16) | (Int(bytes[5]) << 8)
            | Int(bytes[6])
        let asc = bytes[12]
        let ascq = bytes[13]

        if key == 0x00, endOfMedium || incorrectLength {
            return .endOfPage(residual: information)
        }
        // Observed throughout duplex scans while the far side fills.
        if key == 0x03, asc == 0x80, ascq == 0x13 {
            return .notReadyRetry
        }
        return .other(key: key, asc: asc, ascq: ascq)
    }
}
