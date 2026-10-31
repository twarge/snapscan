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
        /// Setup steps the scanner refused and a lenient batch went on
        /// without; always empty otherwise.
        var skippedSetupSteps: [String] = []
    }

    enum ScanError: Error, LocalizedError {
        case notOpen
        case notAScanner
        case unexpectedStatus(String)
        case scannerError(key: UInt8, asc: UInt8, ascq: UInt8)
        /// The scanner rejected a command of the setup sequence as one it
        /// doesn't accept — the sign of a model that differs from the one the
        /// sequence was captured from.
        case setupRefused(step: String, key: UInt8, asc: UInt8, ascq: UInt8)

        var errorDescription: String? {
            switch self {
            case .notOpen: "No scanner connection"
            case .notAScanner:
                "That USB device isn't a scanner this app can drive"
            case .unexpectedStatus(let detail): detail
            case .scannerError(let key, let asc, let ascq):
                Self.describe(key: key, asc: asc, ascq: ascq)
            case .setupRefused(let step, let key, let asc, let ascq):
                String(
                    format: "The scanner didn't accept the setup step “%@” "
                        + "(sense %02x/%02x/%02x). Help ▸ Scanner Diagnostics "
                        + "can make a report of how it responds.",
                    step, key, asc, ascq)
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
    /// Handed to every transport this actor opens, while diagnostics run.
    private(set) var recorder: TransferRecorder?

    // MARK: - Connection

    nonisolated static func isPresent() -> Bool {
        USBTransport.present(vendorID: vendorID, preferredProductID: verifiedProductID) != nil
    }

    /// The open connection, claiming the scanner's interface if it isn't
    /// already held.
    func claim() throws -> USBTransport {
        if let transport { return transport }
        let opened = try USBTransport(
            vendorID: Self.vendorID, preferredProductID: Self.verifiedProductID)
        opened.recorder = recorder
        transport = opened
        return opened
    }

    /// Starts or stops recording every exchange with the scanner.
    func setRecorder(_ recorder: TransferRecorder?) {
        self.recorder = recorder
        transport?.recorder = recorder
    }

    func open() throws -> DeviceInfo {
        let transport = try claim()

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

    /// Scans sheets until the feeder is empty. A `lenientSetup` batch goes on
    /// past setup steps the scanner refuses rather than stopping at the
    /// first — how diagnostics find out whether an unfamiliar model can scan
    /// without them.
    func scanBatch(
        settings: ScanSettings,
        startingAtPage firstPageIndex: Int,
        lenientSetup: Bool = false,
        onEvent: @escaping @Sendable (BatchEvent) -> Void
    ) throws -> BatchResult {
        guard let transport else { throw ScanError.notOpen }
        cancelFlag.reset()

        // The back alone is scanned as duplex with the fronts dropped: one pass
        // images both sides anyway, and asking for the back window by itself
        // isn't in any capture (docs/PROTOCOL.md §4.4).
        let windows: [ScannerCommands.Window] =
            settings.source == .front ? [.front] : [.front, .back]
        let kept: Set<ScannerCommands.Window> =
            settings.source == .back ? [.back] : Set(windows)
        var pageIndex = firstPageIndex
        var pagesScanned = 0

        // The device needs its full setup sequence before it will scan.
        let skipped = try prepare(
            transport: transport, settings: settings, windows: windows,
            lenient: lenientSetup)

        while true {
            if cancelFlag.isCancelled {
                return BatchResult(
                    pagesScanned: pagesScanned, feederWasEmpty: false,
                    skippedSetupSteps: skipped)
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
                            pagesScanned: pagesScanned, feederWasEmpty: pagesScanned == 0,
                            skippedSetupSteps: skipped)
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
                transport: transport, windows: windows, keeping: kept,
                firstPageIndex: pageIndex, onEvent: onEvent)
            pagesScanned += pages
            pageIndex += pages
            Self.trace(
                "sheet: fed in \(Self.milliseconds(readStarted - feedStarted)), "
                    + "read in \(Self.milliseconds(ContinuousClock.now - readStarted))")
        }
    }

    /// One command of the setup sequence.
    struct SetupStep: Sendable {
        let label: String
        let cdb: [UInt8]
        var dataOut: Data?
        var dataIn = 0
        /// Its answer only informs the host: whatever happens to it, setup
        /// carries on.
        var optional = false
    }

    /// The initialization the device requires before it will scan
    /// (docs/PROTOCOL.md §7): identity diagnostic, pre-read mode, mode
    /// pages, window descriptors, the table download, and scanner control.
    nonisolated static func setupSteps(
        for settings: ScanSettings, windows: [ScannerCommands.Window]
    ) -> [SetupStep] {
        let descriptor = windowSettings(for: settings, window: .front)
        let sensorRead = SetupStep(
            label: "sensor read", cdb: ScannerCommands.hardwareStatus(), dataIn: 12,
            optional: true)

        // Identity handshake.
        let deviceID = ScannerCommands.diagnosticCommand("GET DEVICE ID")
        var steps = [
            SetupStep(
                label: "GET DEVICE ID",
                cdb: ScannerCommands.sendDiagnostic(parameterLength: deviceID.count),
                dataOut: deviceID),
            SetupStep(
                label: "read diagnostic",
                cdb: ScannerCommands.readDiagnostic(allocationLength: 10), dataIn: 10),
            SetupStep(label: "test unit ready", cdb: ScannerCommands.testUnitReady()),
            sensorRead,
        ]

        // Pre-read mode carries the geometry the scan will use.
        let preRead = ScannerCommands.preReadModePayload(descriptor)
        steps.append(
            SetupStep(
                label: "SET PRE READMODE",
                cdb: ScannerCommands.sendDiagnostic(parameterLength: preRead.count),
                dataOut: preRead))

        // Auto paper size relies on the scanner ending the frame at the
        // sheet's trailing edge; that is a mode page, not a window field.
        let autoLength = settings.paperSize == .auto
        for page in ScannerCommands.setupModePages(autoLength: autoLength) {
            let payload = ScannerCommands.modePage(code: page.code, data: page.data)
            steps.append(
                SetupStep(
                    label: String(format: "mode page %02x", page.code),
                    cdb: ScannerCommands.modeSelect(parameterLength: payload.count),
                    dataOut: payload))
        }

        // One SET WINDOW carrying every window's descriptor.
        let windowPayload = ScannerCommands.windowParameterList(descriptor, windows: windows)
        steps.append(
            SetupStep(
                label: "set window (\(windows.count))",
                cdb: ScannerCommands.setWindow(parameterLength: windowPayload.count),
                dataOut: windowPayload))

        let table = ScannerCommands.quantizationTablePayload
        steps.append(
            SetupStep(
                label: "table download",
                cdb: ScannerCommands.send(dataType: 0x88, length: table.count),
                dataOut: table))
        steps.append(
            SetupStep(
                label: "scanner control",
                cdb: ScannerCommands.scannerControl(subcommand: 0x05)))
        steps.append(sensorRead)
        return steps
    }

    /// How the scanner answered one setup step.
    enum StepOutcome: Sendable, Equatable {
        case accepted
        /// A check condition whose sense is worse than "recovered".
        case refused(key: UInt8, asc: UInt8, ascq: UInt8)
    }

    /// Sends one setup step. Throws only when the connection itself fails.
    static func run(_ step: SetupStep, on transport: some ScannerLink) throws -> StepOutcome {
        let (status, _) = try transport.send(
            cdb: step.cdb, dataOut: step.dataOut, dataIn: step.dataIn)
        guard status == .checkCondition else { return .accepted }
        if case .other(let key, let asc, let ascq) = try sense(transport), key > 0x01 {
            return .refused(key: key, asc: asc, ascq: ascq)
        }
        return .accepted
    }

    /// Runs the setup sequence. Strictly, the first refusal stops it; a
    /// lenient run goes on and returns the steps it had to leave out.
    private func prepare(
        transport: USBTransport, settings: ScanSettings,
        windows: [ScannerCommands.Window], lenient: Bool
    ) throws -> [String] {
        var skipped: [String] = []
        for step in Self.setupSteps(for: settings, windows: windows) {
            guard !step.optional else {
                _ = try? Self.run(step, on: transport)
                continue
            }
            Self.trace("\(step.label)…")
            guard case .refused(let key, let asc, let ascq) = try Self.run(step, on: transport)
            else { continue }
            if lenient {
                skipped.append(step.label)
            } else if key == 0x05 {
                // Illegal request: the command itself, not the paper path.
                throw ScanError.setupRefused(step: step.label, key: key, asc: asc, ascq: ascq)
            } else {
                throw ScanError.scannerError(key: key, asc: asc, ascq: ascq)
            }
        }
        return skipped
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
        keeping kept: Set<ScannerCommands.Window>? = nil,
        firstPageIndex: Int, onEvent: @escaping @Sendable (BatchEvent) -> Void
    ) throws -> Int {
        var sides = try windows.map { try beginSide(transport: transport, window: $0) }
        // A side that isn't kept is still read — the scanner holds it until
        // it is — but never becomes a page.
        let keeps = windows.map { kept?.contains($0) ?? true }
        var pageIndex = firstPageIndex
        // Sides are handed over in sheet order, even when the back finishes
        // first; `handed` is the first not yet handed over.
        var handed = 0
        // The kept side on screen: the first kept one not yet handed over.
        var previewed: Int?
        func announceNext() {
            let next = sides.indices.first { $0 >= handed && keeps[$0] }
            guard let next, next != previewed else { return }
            previewed = next
            onEvent(.pageStarted(index: pageIndex))
        }
        var lastPartial = ContinuousClock.now
        announceNext()

        while handed < sides.count {
            if cancelFlag.isCancelled {
                // Keep what has arrived of the page on screen, as stopping
                // always has; the sides after it are dropped.
                for index in sides.indices where index >= handed && index != previewed {
                    sides[index].buffer = Data()
                }
                for index in sides.indices { sides[index].finished = true }
            }

            var progressed = false
            for index in sides.indices where !sides[index].finished {
                if try readChunk(into: &sides[index], transport: transport) {
                    progressed = true
                }
            }

            while handed < sides.count, sides[handed].finished {
                let side = sides[handed]
                Self.trace(
                    "  side \(String(format: "%02x", side.window.rawValue)): "
                        + "\(side.rows) lines, \(side.waits) not-ready reads")
                if keeps[handed], let image = side.image() {
                    onEvent(.pageComplete(index: pageIndex, image: image))
                    pageIndex += 1
                }
                sides[handed].buffer = Data()
                handed += 1
                announceNext()
            }
            guard handed < sides.count else { break }

            if !progressed {
                // Every side is waiting on the paper. Reading again at once
                // would only fetch another full buffer of nothing.
                Thread.sleep(forTimeInterval: 0.002)
            }

            let now = ContinuousClock.now
            if let previewed, now - lastPartial > .milliseconds(250) {
                lastPartial = now
                let side = sides[previewed]
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
    static func sense(_ transport: some ScannerLink) throws
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
    nonisolated private static func windowSettings(
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
