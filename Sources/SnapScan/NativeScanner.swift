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
    /// The one model this driver has actually been exercised against on real
    /// hardware. Others from the same vendor are attempted on the assumption
    /// that the family shares this protocol — see `DeviceInfo.isVerified`.
    static let verifiedProductID = 0x132B
    /// SCSI peripheral device type 6: a scanner. Matching on vendor alone
    /// means anything that vendor makes can turn up, so this is what stops a
    /// printer or a hub from being driven as one.
    private static let scannerDeviceType: UInt8 = 6

    struct DeviceInfo: Sendable {
        let vendor: String
        let model: String
        let productID: Int
        /// False for a model this driver has never been tested against. It
        /// answered the protocol, so scanning is attempted, but nothing about
        /// how well it works is known.
        var isVerified: Bool { productID == NativeScanner.verifiedProductID }
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
        case notAScanner
        case unexpectedStatus(String)
        case scannerError(key: UInt8, asc: UInt8, ascq: UInt8)

        var errorDescription: String? {
            switch self {
            case .notOpen: "No scanner connection"
            case .notAScanner:
                "That USB device isn't a scanner this app can drive"
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
        USBTransport.present(vendorID: vendorID, preferredProductID: verifiedProductID) != nil
    }

    func open() throws -> DeviceInfo {
        if transport == nil {
            transport = try USBTransport(
                vendorID: Self.vendorID, preferredProductID: Self.verifiedProductID)
        }
        guard let transport else { throw ScanError.notOpen }

        _ = try transport.send(cdb: ScannerCommands.testUnitReady())
        let (_, data) = try transport.send(cdb: ScannerCommands.inquiry(), dataIn: 96)
        guard let identity = ScannerCommands.parseInquiry(data) else {
            throw ScanError.unexpectedStatus("INQUIRY returned unusable data")
        }
        guard identity.deviceType == Self.scannerDeviceType else {
            // Not a scanner: let go of it rather than sending scan commands
            // to whatever it actually is.
            self.transport = nil
            throw ScanError.notAScanner
        }
        return DeviceInfo(
            vendor: identity.vendor, model: identity.model, productID: transport.productID)
    }

    func close() {
        transport = nil
    }

    var isOpen: Bool { transport != nil }

    /// True when the scanner's Scan button is pressed; nil when the sensor
    /// block can't be read. Bits confirmed on hardware by isolating each
    /// action (docs/PROTOCOL.md §3.3).
    func scanButtonPressed() -> Bool? {
        sensorState()?.scanButton
    }

    struct SensorState: Sendable {
        let scanButton: Bool
        let feederClosed: Bool
        let coverOpen: Bool
        let raw: Data
    }

    func sensorState() -> SensorState? {
        guard let block = try? readSensors(), block.count >= 6 else { return nil }
        let byte3 = block[block.startIndex + 3]
        let byte4 = block[block.startIndex + 4]
        return SensorState(
            scanButton: byte4 & 0x01 != 0,
            feederClosed: byte3 & 0x80 != 0,
            coverOpen: byte3 & 0x20 != 0,
            raw: block)
    }

    /// Reads the raw hardware sensor block (vendor 0xC2).
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
            let feedStarted = ContinuousClock.now
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
            let readStarted = ContinuousClock.now
            let pages = try readSheet(
                transport: transport, windows: windows, firstPageIndex: pageIndex,
                onEvent: onEvent)
            pagesScanned += pages
            pageIndex += pages
            Self.trace(
                "sheet: fed in \(Self.milliseconds(readStarted - feedStarted)), "
                    + "read in \(Self.milliseconds(ContinuousClock.now - readStarted))")
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
            Self.trace("\(label)…")
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

        // Auto paper size relies on the scanner ending the frame at the
        // sheet's trailing edge; that is a mode page, not a window field.
        let autoLength = settings.paperSize == .auto
        for page in ScannerCommands.setupModePages(autoLength: autoLength) {
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

    /// One side of a sheet as it streams in.
    private struct SideRead {
        let window: ScannerCommands.Window
        let width: Int
        /// An upper bound when auto length detection is on
        /// (docs/PROTOCOL.md §6).
        let lines: Int
        let chunkLength: Int
        var buffer = Data()
        var finished = false
        /// Reads the scanner answered with "nothing for this side yet".
        var waits = 0

        var bytesPerLine: Int { width * 3 }  // always 24-bit RGB
        var rows: Int { buffer.count / bytesPerLine }

        func image() -> CGImage? {
            guard rows > 0 else { return nil }
            // The device returns inverted reflectance (docs/PROTOCOL.md §4.3).
            return FrameImage.make(
                pixels: buffer, width: width, height: rows,
                bytesPerRow: bytesPerLine, format: .rgb24, inverted: true)
        }
    }

    /// Streams one sheet — both of its sides in duplex — emitting partial
    /// previews as rows arrive and its pages in order. Returns how many pages
    /// it produced.
    ///
    /// The two sides are read in turn, each as it has data, as the reference
    /// stack was captured doing (docs/PROTOCOL.md §4.4). The scanner images
    /// both in a single pass, so draining the front before touching the back
    /// left the link half idle while the paper moved, then held the next
    /// sheet until the whole back side had crossed the wire.
    func readSheet(
        transport: some ScannerLink, windows: [ScannerCommands.Window],
        firstPageIndex: Int, onEvent: @escaping @Sendable (BatchEvent) -> Void
    ) throws -> Int {
        var sides = try windows.map { try beginSide(transport: transport, window: $0) }
        var pageIndex = firstPageIndex
        // The side being previewed: the first not yet handed over. Pages go
        // out in sheet order even when the back finishes first.
        var shown = 0
        var lastPartial = ContinuousClock.now
        onEvent(.pageStarted(index: pageIndex))

        while shown < sides.count {
            if cancelFlag.isCancelled {
                // Keep what has arrived of the page on screen, as stopping
                // always has; the sides after it are dropped.
                for index in sides.indices where index > shown { sides[index].buffer = Data() }
                for index in sides.indices { sides[index].finished = true }
            }

            var progressed = false
            for index in sides.indices where !sides[index].finished {
                if try readChunk(into: &sides[index], transport: transport) {
                    progressed = true
                }
            }

            while shown < sides.count, sides[shown].finished {
                let side = sides[shown]
                Self.trace(
                    "  side \(String(format: "%02x", side.window.rawValue)): "
                        + "\(side.rows) lines, \(side.waits) not-ready reads")
                if let image = side.image() {
                    onEvent(.pageComplete(index: pageIndex, image: image))
                    pageIndex += 1
                }
                sides[shown].buffer = Data()
                shown += 1
                if shown < sides.count { onEvent(.pageStarted(index: pageIndex)) }
            }
            guard shown < sides.count else { break }

            if !progressed {
                // Every side is waiting on the paper. Reading again at once
                // would only fetch another full buffer of nothing.
                Thread.sleep(forTimeInterval: 0.002)
            }

            let now = ContinuousClock.now
            if now - lastPartial > .milliseconds(250) {
                lastPartial = now
                let side = sides[shown]
                if side.rows > 8, let partial = side.image() {
                    let fraction = side.lines > 0
                        ? min(1, Double(side.rows) / Double(side.lines)) : nil
                    onEvent(.pagePartial(index: pageIndex, image: partial, fraction: fraction))
                }
            }
        }
        return pageIndex - firstPageIndex
    }

    /// Asks one side's size and arms its read-ahead, before any of the
    /// sheet's image data is read.
    private func beginSide(
        transport: some ScannerLink, window: ScannerCommands.Window
    ) throws -> SideRead {
        // Pixel size: width is exact; the line count is an upper bound when
        // auto length detection is on (docs/PROTOCOL.md §6).
        let (sizeStatus, sizeData) = try transport.send(
            cdb: ScannerCommands.read(type: .pixelSize, window: window, length: 32),
            dataOut: nil, dataIn: 32)
        if sizeStatus == .checkCondition { _ = try Self.sense(transport) }
        guard let size = ScannerCommands.parsePixelSize(sizeData), size.width > 0 else {
            throw ScanError.unexpectedStatus("scanner did not report a page size")
        }

        let bytesPerLine = size.width * 3  // always 24-bit RGB
        // Read whole lines, in chunks near 256 KiB like the reference stack.
        let linesPerRead = max(1, (256 * 1024) / bytesPerLine)
        let chunkLength = linesPerRead * bytesPerLine

        // Tell the scanner the read size about to be used for this window so
        // it can keep that buffer filled while the sheet moves — the
        // reference stack sends this between the pixel-size read and the
        // image reads. Refusal is not fatal; the scan works either way.
        let (armStatus, _) = try transport.send(
            cdb: ScannerCommands.armReadAhead(window: window, length: chunkLength),
            dataOut: nil, dataIn: 0)
        if armStatus == .checkCondition { _ = try? Self.sense(transport) }

        var side = SideRead(
            window: window, width: size.width, lines: size.lines, chunkLength: chunkLength)
        // Reserve the whole page up front: growing a 25–100 MB buffer by
        // repeated reallocation copies it many times over.
        side.buffer.reserveCapacity(
            size.lines > 0 ? bytesPerLine * size.lines : chunkLength * 8)
        return side
    }

    /// Reads the next chunk of one side. True when that moved the side on —
    /// image data, or its end — and false when the scanner had nothing for
    /// it yet.
    private func readChunk(
        into side: inout SideRead, transport: some ScannerLink
    ) throws -> Bool {
        let lengthBeforeRead = side.buffer.count
        let (status, data) = try transport.send(
            cdb: ScannerCommands.read(
                type: .image, window: side.window, length: side.chunkLength),
            dataOut: nil, dataIn: side.chunkLength)
        side.buffer.append(data)
        guard status == .checkCondition else { return true }

        switch try Self.sense(transport) {
        case .endOfPage(let residual):
            // The tail of this read was not filled.
            if residual > 0, residual <= side.buffer.count {
                side.buffer.removeLast(residual)
            }
            side.finished = true
            return true
        case .notReadyRetry:
            // The device still returns a full buffer here, but its contents
            // are not image data — drop it and ask again, or the page grows
            // without bound.
            side.buffer.removeLast(side.buffer.count - lengthBeforeRead)
            side.waits += 1
            return false
        case .other(let key, let asc, let ascq):
            throw ScanError.scannerError(key: key, asc: asc, ascq: ascq)
        }
    }

    /// Step tracing, for bring-up and for timing the paper path.
    private nonisolated static func trace(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data("  \(message())\n".utf8))
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return "\(seconds * 1000 + attoseconds / 1_000_000_000_000_000) ms"
    }

    /// Issues REQUEST SENSE and interprets the reply.
    private static func sense(_ transport: some ScannerLink) throws
        -> ScannerCommands.SenseVerdict
    {
        let (_, data) = try transport.send(
            cdb: ScannerCommands.requestSense(), dataOut: nil, dataIn: 18)
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
