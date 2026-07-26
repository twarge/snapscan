import CSane
import CoreGraphics
import Foundation

/// In-process interface to the SANE library. All blocking C calls run inside
/// this actor; `sane_cancel` is the documented exception (async-safe from any
/// thread) and goes through `CancelBox` so a running scan can be interrupted.
actor SaneSession {
    static let shared = SaneSession()

    struct DeviceInfo: Sendable {
        let name: String
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

    enum SaneError: Error, LocalizedError {
        case status(SANE_Status, context: String)
        case notOpen
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .status(let status, let context):
                "\(context): \(SaneSession.describe(status))"
            case .notOpen:
                "No scanner connection"
            case .unsupportedFormat(let detail):
                "Unsupported scan format: \(detail)"
            }
        }
    }

    /// Holds the open handle for async-safe cancellation from outside the actor.
    final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: SANE_Handle?

        fileprivate func set(_ newHandle: SANE_Handle?) {
            lock.lock()
            handle = newHandle
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            if let handle { sane_cancel(handle) }
            lock.unlock()
        }
    }

    nonisolated let cancelBox = CancelBox()

    private var initialized = false
    private var handle: SANE_Handle?
    private var openedDeviceName: String?
    private var optionIndex: [String: SANE_Int] = [:]

    // MARK: - Lifecycle

    private func ensureInitialized(prefix: URL) throws {
        guard !initialized else { return }
        // The dll loader reads these at backend-load time: config directory
        // and (even on macOS) LD_LIBRARY_PATH for locating backend modules.
        setenv("SANE_CONFIG_DIR", prefix.appendingPathComponent("etc/sane.d").path, 1)
        setenv("LD_LIBRARY_PATH", prefix.appendingPathComponent("lib/sane").path, 1)
        var version: SANE_Int = 0
        let status = sane_init(&version, nil)
        guard status == SANE_STATUS_GOOD else {
            throw SaneError.status(status, context: "Couldn't start the scanner library")
        }
        initialized = true
    }

    func listDevices(prefix: URL) throws -> [DeviceInfo] {
        try ensureInitialized(prefix: prefix)
        var list: UnsafeMutablePointer<UnsafePointer<SANE_Device>?>? = nil
        let status = sane_get_devices(&list, SANE_Bool(1))
        guard status == SANE_STATUS_GOOD, let list else {
            throw SaneError.status(status, context: "Couldn't look for scanners")
        }
        var devices: [DeviceInfo] = []
        var index = 0
        while let entry = list[index] {
            devices.append(
                DeviceInfo(
                    name: String(cString: entry.pointee.name),
                    vendor: String(cString: entry.pointee.vendor),
                    model: String(cString: entry.pointee.model)))
            index += 1
        }
        return devices
    }

    func open(device name: String, prefix: URL) throws {
        try ensureInitialized(prefix: prefix)
        guard openedDeviceName != name || handle == nil else { return }
        closeDevice()
        var newHandle: SANE_Handle? = nil
        let status = sane_open(name, &newHandle)
        guard status == SANE_STATUS_GOOD, let newHandle else {
            throw SaneError.status(status, context: "Couldn't open the scanner")
        }
        handle = newHandle
        openedDeviceName = name
        cancelBox.set(newHandle)
        buildOptionIndex()
    }

    func closeDevice() {
        if let handle {
            sane_close(handle)
        }
        cancelBox.set(nil)
        handle = nil
        openedDeviceName = nil
        optionIndex = [:]
    }

    var isOpen: Bool { handle != nil }

    private func buildOptionIndex() {
        optionIndex = [:]
        guard let handle else { return }
        var count: SANE_Int = 0
        guard
            sane_control_option(handle, 0, SANE_ACTION_GET_VALUE, &count, nil)
                == SANE_STATUS_GOOD
        else { return }
        for option in 1..<count {
            guard let descriptor = sane_get_option_descriptor(handle, option),
                let namePointer = descriptor.pointee.name
            else { continue }
            let name = String(cString: namePointer)
            if !name.isEmpty {
                optionIndex[name] = option
            }
        }
    }

    // MARK: - Options

    private func setOption(_ name: String, int value: SANE_Int) {
        guard let handle, let index = optionIndex[name] else { return }
        var mutable = value
        _ = sane_control_option(handle, index, SANE_ACTION_SET_VALUE, &mutable, nil)
    }

    private func setOption(_ name: String, fixedMillimeters value: Double) {
        // SANE_Fixed is a 16.16 fixed-point number.
        setOption(name, int: SANE_Int(value * 65536))
    }

    private func setOption(_ name: String, bool value: Bool) {
        setOption(name, int: SANE_Int(value ? 1 : 0))
    }

    private func setOption(_ name: String, string value: String) {
        guard let handle, let index = optionIndex[name],
            let descriptor = sane_get_option_descriptor(handle, index)
        else { return }
        // The API takes a mutable buffer sized to the option's size field.
        var buffer = [CChar](repeating: 0, count: Int(descriptor.pointee.size) + 1)
        value.utf8CString.prefix(buffer.count - 1).enumerated().forEach {
            buffer[$0.offset] = $0.element
        }
        _ = sane_control_option(handle, index, SANE_ACTION_SET_VALUE, &buffer, nil)
    }

    func configure(settings: ScanSettings) throws {
        guard handle != nil else { throw SaneError.notOpen }
        let paper = settings.paperSize.millimeters
        setOption(SANE_NAME_SCAN_SOURCE, string: settings.source.rawValue)
        setOption(SANE_NAME_SCAN_MODE, string: settings.mode.rawValue)
        setOption(SANE_NAME_SCAN_RESOLUTION, int: SANE_Int(settings.resolution))
        setOption("page-width", fixedMillimeters: paper.width)
        setOption("page-height", fixedMillimeters: paper.height)
        setOption(SANE_NAME_SCAN_TL_X, fixedMillimeters: 0)
        setOption(SANE_NAME_SCAN_TL_Y, fixedMillimeters: 0)
        setOption(SANE_NAME_SCAN_BR_X, fixedMillimeters: paper.width)
        setOption(SANE_NAME_SCAN_BR_Y, fixedMillimeters: paper.height)
        setOption("swcrop", bool: settings.autocrop)
        // Percentage of dark pixels below which a page is discarded as blank.
        setOption("swskip", fixedMillimeters: settings.skipBlankPages ? 1.0 : 0.0)
    }

    /// Reads a hardware sensor (e.g. the Scan button) as a boolean.
    func readSensor(_ name: String) -> Bool? {
        guard let handle, let index = optionIndex[name] else { return nil }
        var value: SANE_Int = 0
        guard
            sane_control_option(handle, index, SANE_ACTION_GET_VALUE, &value, nil)
                == SANE_STATUS_GOOD
        else { return nil }
        return value != 0
    }

    // MARK: - Scanning

    func scanBatch(
        settings: ScanSettings,
        startingAtPage firstPageIndex: Int,
        onEvent: @escaping @Sendable (BatchEvent) -> Void
    ) throws -> BatchResult {
        guard let handle else { throw SaneError.notOpen }
        try configure(settings: settings)

        var pageIndex = firstPageIndex
        var pagesScanned = 0

        while true {
            let startStatus = sane_start(handle)
            if startStatus == SANE_STATUS_NO_DOCS {
                sane_cancel(handle)
                return BatchResult(
                    pagesScanned: pagesScanned, feederWasEmpty: pagesScanned == 0)
            }
            if startStatus == SANE_STATUS_CANCELLED {
                return BatchResult(pagesScanned: pagesScanned, feederWasEmpty: false)
            }
            guard startStatus == SANE_STATUS_GOOD else {
                sane_cancel(handle)
                throw SaneError.status(startStatus, context: "Scan failed")
            }

            var parameters = SANE_Parameters()
            guard sane_get_parameters(handle, &parameters) == SANE_STATUS_GOOD else {
                sane_cancel(handle)
                throw SaneError.status(SANE_STATUS_INVAL, context: "Scan failed")
            }
            let format = try pixelFormat(for: parameters)
            let bytesPerRow = Int(parameters.bytes_per_line)
            let width = Int(parameters.pixels_per_line)
            let expectedLines = parameters.lines > 0 ? Int(parameters.lines) : nil

            onEvent(.pageStarted(index: pageIndex))

            var buffer = Data()
            if let expectedLines {
                buffer.reserveCapacity(bytesPerRow * expectedLines)
            }
            var chunk = [UInt8](repeating: 0, count: 256 * 1024)
            var lastPartialEmit = ContinuousClock.now
            var readStatus = SANE_STATUS_GOOD

            readLoop: while true {
                var length: SANE_Int = 0
                readStatus = chunk.withUnsafeMutableBufferPointer { pointer in
                    sane_read(handle, pointer.baseAddress, SANE_Int(pointer.count), &length)
                }
                switch readStatus {
                case SANE_STATUS_GOOD:
                    buffer.append(contentsOf: chunk[0..<Int(length)])
                    let now = ContinuousClock.now
                    if now - lastPartialEmit > .milliseconds(250) {
                        lastPartialEmit = now
                        let rows = buffer.count / bytesPerRow
                        if rows > 8,
                            let partial = FrameImage.make(
                                pixels: buffer, width: width, height: rows,
                                bytesPerRow: bytesPerRow, format: format) {
                            let fraction = expectedLines.map {
                                min(1, Double(rows) / Double($0))
                            }
                            onEvent(
                                .pagePartial(
                                    index: pageIndex, image: partial, fraction: fraction))
                        }
                    }
                case SANE_STATUS_EOF:
                    break readLoop
                case SANE_STATUS_CANCELLED:
                    break readLoop
                default:
                    sane_cancel(handle)
                    throw SaneError.status(readStatus, context: "Scan failed")
                }
            }

            if readStatus == SANE_STATUS_CANCELLED {
                return BatchResult(pagesScanned: pagesScanned, feederWasEmpty: false)
            }

            let rows = buffer.count / bytesPerRow
            if rows > 0,
                let image = FrameImage.make(
                    pixels: buffer, width: width, height: rows,
                    bytesPerRow: bytesPerRow, format: format) {
                onEvent(.pageComplete(index: pageIndex, image: image))
                pagesScanned += 1
                pageIndex += 1
            }
        }
    }

    private func pixelFormat(for parameters: SANE_Parameters) throws -> FrameImage.PixelFormat {
        switch (parameters.format, parameters.depth) {
        case (SANE_FRAME_RGB, 8): return .rgb24
        case (SANE_FRAME_GRAY, 8): return .gray8
        case (SANE_FRAME_GRAY, 1): return .mono1
        default:
            throw SaneError.unsupportedFormat(
                "frame \(parameters.format) depth \(parameters.depth)")
        }
    }

    // MARK: - Status descriptions

    static func describe(_ status: SANE_Status) -> String {
        switch status {
        case SANE_STATUS_GOOD: "OK"
        case SANE_STATUS_UNSUPPORTED: "the operation isn't supported"
        case SANE_STATUS_CANCELLED: "the scan was cancelled"
        case SANE_STATUS_DEVICE_BUSY: "the scanner is busy — is another app using it?"
        case SANE_STATUS_INVAL: "invalid scan settings"
        case SANE_STATUS_EOF: "end of data"
        case SANE_STATUS_JAMMED: "paper jam — clear the feeder and try again"
        case SANE_STATUS_NO_DOCS: "the feeder is empty"
        case SANE_STATUS_COVER_OPEN: "the scanner cover is open"
        case SANE_STATUS_IO_ERROR: "couldn't talk to the scanner"
        case SANE_STATUS_NO_MEM: "out of memory"
        case SANE_STATUS_ACCESS_DENIED: "access to the scanner was denied"
        default: "scanner error (\(status.rawValue))"
        }
    }
}
