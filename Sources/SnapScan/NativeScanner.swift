import CoreGraphics
import Foundation

/// The scan pipeline built directly on `USBTransport` — the SANE-free
/// replacement for `SaneSession`, implementing docs/PROTOCOL.md.
///
/// All blocking USB calls happen inside this actor. Its surface mirrors
/// `SaneSession` so `ScannerEngine` can switch over with minimal change.
actor NativeScanner {
    static let shared = NativeScanner()

    static let vendorID = 0x04C5
    static let productID = 0x132B

    struct DeviceInfo: Sendable {
        let vendor: String
        let model: String
    }

    enum BatchEvent: Sendable {
        case pageStarted(index: Int)
        case pagePartial(index: Int, image: CGImage, fraction: Double?)
        case pageComplete(index: Int, image: CGImage)
    }

    struct BatchResult: Sendable {
        let pagesScanned: Int
        let feederWasEmpty: Bool
    }

    enum ScanError: Error, LocalizedError {
        case notOpen
        case unexpectedStatus(String)
        case scannerError(key: UInt8, asc: UInt8, ascq: UInt8)

        var errorDescription: String? {
            switch self {
            case .notOpen: "No scanner connection"
            case .unexpectedStatus(let detail): detail
            case .scannerError(let key, let asc, let ascq):
                Self.describe(key: key, asc: asc, ascq: ascq)
            }
        }

        /// SCSI-2 sense keys, plus the vendor conditions we have observed.
        private static func describe(key: UInt8, asc: UInt8, ascq: UInt8) -> String {
            switch (key, asc, ascq) {
            case (0x02, _, _): "The scanner is not ready"
            case (0x03, 0x80, 0x01): "Paper jam — clear the feeder and try again"
            case (0x03, 0x80, 0x02): "The scanner cover is open"
            case (0x03, 0x80, 0x04): "The feeder is empty"
            case (0x06, _, _): "The scanner was reset"
            default:
                String(
                    format: "Scanner error (sense %02x/%02x/%02x)", key, asc, ascq)
            }
        }
    }

    /// Set from outside the actor so a running scan can be interrupted.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func reset() {
            lock.lock()
            cancelled = false
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    nonisolated let cancelFlag = CancelFlag()

    /// Step tracing to stderr, for bring-up.
    nonisolated static let verbose =
        ProcessInfo.processInfo.environment["SNAPSCAN_DRIVER_TRACE"] != nil

    private var transport: USBTransport?

    // MARK: - Connection

    nonisolated static func isPresent() -> Bool {
        USBTransport.isPresent(vendorID: vendorID, productID: productID)
    }

    func open() throws -> DeviceInfo {
        if transport == nil {
            transport = try USBTransport(vendorID: Self.vendorID, productID: Self.productID)
        }
        guard let transport else { throw ScanError.notOpen }

        _ = try transport.send(cdb: ScannerCommands.testUnitReady())
        let (_, data) = try transport.send(cdb: ScannerCommands.inquiry(), dataIn: 96)
        guard let identity = ScannerCommands.parseInquiry(data) else {
            throw ScanError.unexpectedStatus("INQUIRY returned unusable data")
        }
        return DeviceInfo(vendor: identity.vendor, model: identity.model)
    }

    func close() {
        transport = nil
    }

    var isOpen: Bool { transport != nil }

    /// Reads a hardware sensor byte block (vendor 0xC2). Bit assignments are
    /// still being mapped; callers ask for a specific bit.
    func readSensors() throws -> Data {
        guard let transport else { throw ScanError.notOpen }
        let (_, data) = try transport.send(
            cdb: ScannerCommands.hardwareStatus(), dataIn: 12)
        return data
    }

    // MARK: - Scanning

    func scanBatch(
        settings: ScanSettings,
        startingAtPage firstPageIndex: Int,
        onEvent: @escaping @Sendable (BatchEvent) -> Void
    ) throws -> BatchResult {
        guard let transport else { throw ScanError.notOpen }
        cancelFlag.reset()

        let windows: [ScannerCommands.Window] =
            settings.source == .duplex ? [.front, .back] : [.front]
        var pageIndex = firstPageIndex
        var pagesScanned = 0

        // The device needs its full setup sequence before it will scan.
        try prepare(transport: transport, settings: settings, windows: windows)

        while true {
            if cancelFlag.isCancelled {
                return BatchResult(pagesScanned: pagesScanned, feederWasEmpty: false)
            }

            // Feed a sheet. An empty hopper reports itself here.
            let (feedStatus, _) = try transport.send(cdb: ScannerCommands.objectPositionLoad())
            if feedStatus == .checkCondition {
                let verdict = try Self.sense(transport)
                if case .other(let key, let asc, let ascq) = verdict {
                    // Feeder empty is the expected end of a batch.
                    if key == 0x03 || key == 0x02 {
                        return BatchResult(
                            pagesScanned: pagesScanned, feederWasEmpty: pagesScanned == 0)
                    }
                    throw ScanError.scannerError(key: key, asc: asc, ascq: ascq)
                }
            }

            // Start the scan, listing the windows to digitise.
            let windowIDs = Data(windows.map(\.rawValue))
            let (scanStatus, _) = try transport.send(
                cdb: ScannerCommands.scan(windowCount: windows.count),
                dataOut: windowIDs)
            if scanStatus == .checkCondition {
                let verdict = try Self.sense(transport)
                if case .other(let key, let asc, let ascq) = verdict {
                    throw ScanError.scannerError(key: key, asc: asc, ascq: ascq)
                }
            }

            // Each window yields one page image.
            for window in windows {
                if cancelFlag.isCancelled { break }
                onEvent(.pageStarted(index: pageIndex))
                let image = try readPage(
                    transport: transport, window: window, settings: settings,
                    pageIndex: pageIndex, onEvent: onEvent)
                if let image {
                    onEvent(.pageComplete(index: pageIndex, image: image))
                    pagesScanned += 1
                    pageIndex += 1
                }
            }
        }
    }

    /// Replays the initialization the device requires before it will scan
    /// (docs/PROTOCOL.md §7): identity diagnostic, pre-read mode, mode
    /// pages, window descriptors, the table download, and scanner control.
    private func prepare(
        transport: USBTransport, settings: ScanSettings,
        windows: [ScannerCommands.Window]
    ) throws {
        func run(
            _ label: String, _ cdb: [UInt8], dataOut: Data? = nil, dataIn: Int = 0
        ) throws {
            if Self.verbose { FileHandle.standardError.write(Data("  \(label)…\n".utf8)) }
            let (status, _) = try transport.send(
                cdb: cdb, dataOut: dataOut, dataIn: dataIn)
            if status == .checkCondition {
                let verdict = try Self.sense(transport)
                if case .other(let key, let asc, let ascq) = verdict, key > 0x01 {
                    throw ScanError.scannerError(key: key, asc: asc, ascq: ascq)
                }
            }
        }

        let descriptor = Self.windowSettings(for: settings, window: .front)

        // Identity handshake.
        let deviceID = ScannerCommands.diagnosticCommand("GET DEVICE ID")
        try run(
            "GET DEVICE ID",
            ScannerCommands.sendDiagnostic(parameterLength: deviceID.count),
            dataOut: deviceID)
        try run("read diagnostic", ScannerCommands.readDiagnostic(allocationLength: 10), dataIn: 10)
        try run("test unit ready", ScannerCommands.testUnitReady())
        _ = try? readSensors()

        // Pre-read mode carries the geometry the scan will use.
        let preRead = ScannerCommands.preReadModePayload(descriptor)
        try run(
            "SET PRE READMODE",
            ScannerCommands.sendDiagnostic(parameterLength: preRead.count),
            dataOut: preRead)

        for page in ScannerCommands.setupModePages {
            let payload = ScannerCommands.modePage(code: page.code, data: page.data)
            try run(
                String(format: "mode page %02x", page.code),
                ScannerCommands.modeSelect(parameterLength: payload.count),
                dataOut: payload)
        }

        // One SET WINDOW carrying every window's descriptor.
        let windowPayload = ScannerCommands.windowParameterList(
            descriptor, windows: windows)
        try run(
            "set window (\(windows.count))",
            ScannerCommands.setWindow(parameterLength: windowPayload.count),
            dataOut: windowPayload)

        let table = ScannerCommands.quantizationTablePayload
        try run(
            "table download",
            ScannerCommands.send(dataType: 0x88, length: table.count), dataOut: table)
        try run("scanner control", ScannerCommands.scannerControl(subcommand: 0x05))
        _ = try? readSensors()
    }

    /// Streams one window's image, emitting partial previews as rows arrive.
    private func readPage(
        transport: USBTransport,
        window: ScannerCommands.Window,
        settings: ScanSettings,
        pageIndex: Int,
        onEvent: @escaping @Sendable (BatchEvent) -> Void
    ) throws -> CGImage? {
        // Pixel size: width is exact; the line count is an upper bound when
        // auto length detection is on (docs/PROTOCOL.md §6).
        let (sizeStatus, sizeData) = try transport.send(
            cdb: ScannerCommands.read(type: .pixelSize, window: window, length: 32),
            dataIn: 32)
        if sizeStatus == .checkCondition { _ = try Self.sense(transport) }
        guard let size = ScannerCommands.parsePixelSize(sizeData), size.width > 0 else {
            throw ScanError.unexpectedStatus("scanner did not report a page size")
        }

        let bytesPerLine = size.width * 3  // always 24-bit RGB
        // Read whole lines, in chunks near 256 KiB like the reference stack.
        let linesPerRead = max(1, (256 * 1024) / bytesPerLine)
        let chunkLength = linesPerRead * bytesPerLine

        var buffer = Data()
        buffer.reserveCapacity(chunkLength * 8)
        var lastPartial = ContinuousClock.now

        readLoop: while true {
            if cancelFlag.isCancelled { break }

            let lengthBeforeRead = buffer.count
            let (status, data) = try transport.send(
                cdb: ScannerCommands.read(
                    type: .image, window: window, length: chunkLength),
                dataIn: chunkLength)
            buffer.append(data)

            if status == .checkCondition {
                switch try Self.sense(transport) {
                case .endOfPage(let residual):
                    // The tail of this read was not filled.
                    if residual > 0, residual <= buffer.count {
                        buffer.removeLast(residual)
                    }
                    break readLoop
                case .notReadyRetry:
                    // The device still returns a full buffer here, but its
                    // contents are not image data — drop it and ask again,
                    // or the page grows without bound.
                    buffer.removeLast(buffer.count - lengthBeforeRead)
                    continue readLoop
                case .other(let key, let asc, let ascq):
                    throw ScanError.scannerError(key: key, asc: asc, ascq: ascq)
                }
            }

            let now = ContinuousClock.now
            if now - lastPartial > .milliseconds(250) {
                lastPartial = now
                let rows = buffer.count / bytesPerLine
                if rows > 8,
                    let partial = FrameImage.make(
                        pixels: buffer, width: size.width, height: rows,
                        bytesPerRow: bytesPerLine, format: .rgb24, inverted: true) {
                    let fraction = size.lines > 0
                        ? min(1, Double(rows) / Double(size.lines)) : nil
                    onEvent(
                        .pagePartial(index: pageIndex, image: partial, fraction: fraction))
                }
            }
        }

        let rows = buffer.count / bytesPerLine
        guard rows > 0 else { return nil }
        // The device returns inverted reflectance (docs/PROTOCOL.md §4.3).
        return FrameImage.make(
            pixels: buffer, width: size.width, height: rows,
            bytesPerRow: bytesPerLine, format: .rgb24, inverted: true)
    }

    /// Issues REQUEST SENSE and interprets the reply.
    private static func sense(_ transport: USBTransport) throws
        -> ScannerCommands.SenseVerdict
    {
        let (_, data) = try transport.send(
            cdb: ScannerCommands.requestSense(), dataIn: 18)
        guard let verdict = ScannerCommands.parseSense(data) else {
            throw ScanError.unexpectedStatus("could not read scanner status")
        }
        return verdict
    }

    /// Translates app settings into a window descriptor.
    private static func windowSettings(
        for settings: ScanSettings, window: ScannerCommands.Window
    ) -> ScannerCommands.WindowSettings {
        let paper = settings.paperSize.geometryUnits
        var descriptor = ScannerCommands.WindowSettings()
        descriptor.window = window
        descriptor.resolutionDPI = settings.resolution
        descriptor.paperWidthUnits = paper.width
        descriptor.paperLengthUnits = paper.length
        descriptor.scanWidthUnits = paper.width
        descriptor.scanLengthUnits = paper.length
        return descriptor
    }
}
