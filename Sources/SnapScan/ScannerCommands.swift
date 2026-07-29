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
        case send = 0x2A
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

    static func sendDiagnostic(parameterLength: Int) -> [UInt8] {
        [0x1D, 0, 0, 0, UInt8(parameterLength), 0]
    }

    static func readDiagnostic(allocationLength: Int) -> [UInt8] {
        [0x1C, 0, 0, 0, UInt8(allocationLength), 0]
    }

    static func modeSelect(parameterLength: Int) -> [UInt8] {
        // PF bit set (byte 1 = 0x10), parameter list length in byte 4.
        [Opcode.modeSelect.rawValue, 0x10, 0, 0, UInt8(parameterLength), 0]
    }

    /// SEND with a vendor data type (byte 2), used for the table download.
    static func send(dataType: UInt8, length: Int) -> [UInt8] {
        [
            Opcode.send.rawValue, 0, dataType, 0, 0, 0,
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
            0,
        ]
    }

    static func scannerControl(subcommand: UInt8) -> [UInt8] {
        [Opcode.scannerControl.rawValue, subcommand, 0, 0, 0, 0]
    }

    // MARK: - Setup payloads
    //
    // The initialization sequence observed in every capture. Values whose
    // meaning is established are built from settings; the rest are replayed
    // as recorded and marked accordingly (docs/PROTOCOL.md §7).

    /// SEND DIAGNOSTIC carries 16-byte ASCII command names, optionally
    /// followed by binary parameters.
    static func diagnosticCommand(_ name: String, parameters: [UInt8] = []) -> Data {
        var payload = [UInt8](repeating: 0x20, count: 16)  // space-padded
        for (offset, byte) in name.utf8.prefix(16).enumerated() {
            payload[offset] = byte
        }
        return Data(payload + parameters)
    }

    /// "SET PRE READMODE" — the pre-read the device requires before scanning.
    /// Parameters mirror the window: X/Y resolution, then scan width and
    /// length in 1/1200 inch, composition, and a constant tail.
    static func preReadModePayload(_ settings: WindowSettings) -> Data {
        var parameters: [UInt8] = []
        func putUInt16(_ value: Int) {
            parameters.append(UInt8((value >> 8) & 0xFF))
            parameters.append(UInt8(value & 0xFF))
        }
        func putUInt32(_ value: Int) {
            parameters.append(UInt8((value >> 24) & 0xFF))
            parameters.append(UInt8((value >> 16) & 0xFF))
            parameters.append(UInt8((value >> 8) & 0xFF))
            parameters.append(UInt8(value & 0xFF))
        }
        putUInt16(settings.resolutionDPI)
        putUInt16(settings.resolutionDPI)
        putUInt32(settings.scanWidthUnits)
        putUInt32(settings.scanLengthUnits)
        parameters.append(0x05)  // composition: RGB
        parameters.append(contentsOf: [0x00, 0x00, 0xE4])  // constant tail
        return diagnosticCommand("SET PRE READMODE", parameters: parameters)
    }

    /// A MODE SELECT parameter list: 4-byte header, page code, page length,
    /// then page data.
    static func modePage(code: UInt8, data: [UInt8]) -> Data {
        // Observed page lengths count the bytes after the length field,
        // padded so the list is 12 bytes (or 14 for the longer page).
        // Length byte counts the page body: 6 for the standard pages,
        // 8 for the longer 0x39 page (captured values).
        var payload: [UInt8] = [0, 0, 0, 0, code, UInt8(max(6, data.count))]
        payload.append(contentsOf: data)
        while payload.count < 12 { payload.append(0) }
        return Data(payload)
    }

    /// The pages written before every scan, in order.
    ///
    /// Page `0x3C` byte 1 = `0x80` enables **auto length detection**: the
    /// scanner then ends the frame at the paper's trailing edge instead of
    /// filling the requested window. Established by diffing an ALD capture
    /// against a fixed-size one — it was the only page that changed.
    /// Page `0x3A`'s `80 c0` is constant in every capture; the rest are
    /// written with a zero body.
    static func setupModePages(autoLength: Bool) -> [(code: UInt8, data: [UInt8])] {
        [
            (0x3C, autoLength ? [0x00, 0x80] : []),
            (0x38, []),
            (0x37, []),
            (0x39, [0, 0, 0, 0, 0, 0, 0, 0]),
            (0x3A, [0x80, 0xC0]),
            (0x33, []),
        ]
    }

    /// The 138-byte table downloaded with SEND type 0x88 before scanning —
    /// an 8-byte header plus two 64-byte quantization tables. Replayed
    /// verbatim: the device requires it, and its contents never vary.
    static let quantizationTablePayload: Data = {
        let header: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x40]
        let luma: [UInt8] = [
            0x00, 0x04, 0x03, 0x03, 0x04, 0x03, 0x03, 0x04,
            0x04, 0x03, 0x04, 0x05, 0x05, 0x04, 0x05, 0x07,
            0x0c, 0x07, 0x07, 0x06, 0x06, 0x07, 0x0e, 0x0a,
            0x0b, 0x08, 0x0c, 0x11, 0x0f, 0x12, 0x12, 0x11,
            0x0f, 0x10, 0x10, 0x13, 0x15, 0x1b, 0x17, 0x13,
            0x14, 0x1a, 0x14, 0x10, 0x10, 0x18, 0x20, 0x18,
            0x1a, 0x1c, 0x1d, 0x1e, 0x1f, 0x1e, 0x12, 0x17,
            0x21, 0x24, 0x21, 0x1e, 0x24, 0x1b, 0x1e, 0x1e,
        ]
        let chroma: [UInt8] =
            [0x1d, 0x05, 0x05, 0x05, 0x07, 0x06, 0x07, 0x0e, 0x07, 0x07, 0x0e]
            + [UInt8](repeating: 0x1d, count: 53)
        return Data(header + luma + chroma)
    }()

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
    /// Builds the parameter list for one or more windows. Duplex sends a
    /// single SET WINDOW carrying both descriptors (8-byte header + 64 bytes
    /// each); sending two separate commands earns sense 05/2C/02, command
    /// sequence error. Only the leading descriptor carries the trailing
    /// vendor flag and paper size (docs/PROTOCOL.md §5.1).
    static func windowParameterList(
        _ settings: WindowSettings, windows: [Window]
    ) -> Data {
        var payload = [UInt8](repeating: 0, count: 8 + 64 * windows.count)
        payload[6] = 0
        payload[7] = 64  // per-descriptor length

        for (index, window) in windows.enumerated() {
            let base = 8 + 64 * index
            func putUInt16(_ value: Int, at offset: Int) {
                payload[base + offset] = UInt8((value >> 8) & 0xFF)
                payload[base + offset + 1] = UInt8(value & 0xFF)
            }
            func putUInt32(_ value: Int, at offset: Int) {
                payload[base + offset] = UInt8((value >> 24) & 0xFF)
                payload[base + offset + 1] = UInt8((value >> 16) & 0xFF)
                payload[base + offset + 2] = UInt8((value >> 8) & 0xFF)
                payload[base + offset + 3] = UInt8(value & 0xFF)
            }
            payload[base] = window.rawValue
            putUInt16(settings.resolutionDPI, at: 2)
            putUInt16(settings.resolutionDPI, at: 4)
            putUInt32(0, at: 6)  // upper-left X
            putUInt32(0, at: 10)  // upper-left Y
            putUInt32(settings.scanWidthUnits, at: 14)
            putUInt32(settings.scanLengthUnits, at: 18)
            payload[base + 25] = 0x05  // image composition: RGB
            payload[base + 26] = 8  // bits per pixel
            payload[base + 40] = 0xC1
            payload[base + 42] = 0x01
            if index == 0 {
                payload[base + 53] = 0xC0
                putUInt16(settings.paperWidthUnits, at: 56)
                putUInt16(settings.paperLengthUnits, at: 60)
            }
        }
        return Data(payload)
    }

    /// Single-window convenience.
    static func windowParameterList(_ settings: WindowSettings) -> Data {
        windowParameterList(settings, windows: [settings.window])
    }

    private static func legacyWindowParameterList(_ settings: WindowSettings) -> Data {
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
        // Paper size is 16-bit here (each followed by two zero bytes),
        // unlike the 32-bit scan area above.
        putUInt16(settings.paperWidthUnits, at: 64)
        putUInt16(settings.paperLengthUnits, at: 68)
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
