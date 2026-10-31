import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

/// What reading a sheet asks of the connection: one command, its data, its
/// status. `USBTransport` is the real one; tests stand a simulated scanner in
/// its place.
nonisolated protocol ScannerLink {
    func send(cdb: [UInt8], dataOut: Data?, dataIn: Int) throws -> (
        status: USBTransport.CommandStatus, data: Data
    )
}

nonisolated extension USBTransport: ScannerLink {}

/// Native USB transport for the scanner, implementing the framing recorded
/// in docs/PROTOCOL.md: a 31-byte command packet tagged 0x43 carrying a SCSI
/// CDB, an optional data phase, and a 13-byte status packet tagged 0x53.
///
/// Built on **IOUSBLib** rather than IOUSBHost: IOUSBHost's user client
/// cannot be opened from inside the App Sandbox (`IOServiceOpen failed`,
/// and the iokit-user-client-class exception does not lift it), while
/// IOUSBLib works with only `com.apple.security.device.usb`. Sandbox
/// compatibility is what keeps Mac App Store distribution possible.
nonisolated final class USBTransport {
    enum TransportError: Error, LocalizedError {
        case deviceNotFound
        case interfaceNotFound
        case openFailed(String)
        case pipeNotFound(UInt8, found: [UInt8])
        case shortStatus(Int)
        case badStatusTag(UInt8)
        case io(String)

        var errorDescription: String? {
            switch self {
            case .deviceNotFound: "Scanner not found on USB"
            case .interfaceNotFound: "Scanner interface not available"
            case .openFailed(let detail): detail
            case .pipeNotFound(let address, let found):
                String(format: "Scanner endpoint 0x%02x not found", address)
                    + " (it has "
                    + (found.isEmpty
                        ? "none"
                        : found.map { String(format: "0x%02x", $0) }.joined(separator: ", "))
                    + ")"
            case .shortStatus(let count): "Truncated status packet (\(count) bytes)"
            case .badStatusTag(let tag):
                String(format: "Unexpected status tag 0x%02x", tag)
            case .io(let detail): detail
            }
        }
    }

    /// The scanner's reply to a command.
    enum CommandStatus: Equatable {
        /// Status byte 9 == 0x00 — the command completed.
        case good
        /// Status byte 9 == 0x02 — check condition; issue REQUEST SENSE.
        case checkCondition
        case other(UInt8)

        init(byte: UInt8) {
            switch byte {
            case 0x00: self = .good
            case 0x02: self = .checkCondition
            default: self = .other(byte)
            }
        }
    }

    // Framing constants (docs/PROTOCOL.md §2).
    private static let commandTag: UInt8 = 0x43
    private static let statusTag: UInt8 = 0x53
    private static let commandPacketLength = 31
    private static let cdbOffset = 19
    private static let statusPacketLength = 13
    private static let statusFlagOffset = 9

    private static let bulkOutAddress: UInt8 = 0x02
    private static let bulkInAddress: UInt8 = 0x81

    private typealias InterfaceRef =
        UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>

    private let interface: InterfaceRef
    private var outPipe: UInt8 = 0
    private var inPipe: UInt8 = 0
    private let timeoutMilliseconds: UInt32 = 30_000

    /// One endpoint of the claimed interface, as the device describes it.
    struct Pipe: Sendable {
        let address: UInt8
        /// USB transfer type: 0 control, 1 isochronous, 2 bulk, 3 interrupt.
        let transferType: UInt8
        let maxPacketSize: Int
    }

    /// Every endpoint the interface offers, found when it is claimed.
    private(set) var pipes: [Pipe] = []

    /// When set, every exchange is reported to it — the diagnostics report's
    /// transcript.
    var recorder: TransferRecorder?

    // MARK: - Discovery

    /// The product ID of the device this transport opened.
    private(set) var productID = 0

    init(vendorID: Int, preferredProductID: Int?) throws {
        guard
            let found = Self.findInterfaceService(
                vendorID: vendorID, preferredProductID: preferredProductID)
        else { throw TransportError.deviceNotFound }
        let service = found.service
        productID = found.productID
        defer { IOObjectRelease(service) }

        // IOUSBLib is a CFPlugIn: get the plug-in, then query it for the
        // interface-interface.
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let plugInResult = IOCreatePlugInInterfaceForService(
            service,
            CFUUIDGetConstantUUIDWithBytes(
                nil, 0x2D, 0x97, 0x86, 0xC6, 0x9E, 0xF3, 0x11, 0xD4,
                0xAD, 0x51, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61),  // interface user client
            CFUUIDGetConstantUUIDWithBytes(
                nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
                0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F),  // kIOCFPlugInInterfaceID
            &plugIn, &score)
        guard plugInResult == KERN_SUCCESS, let plugIn else {
            throw TransportError.openFailed(
                String(format: "USB plug-in unavailable (0x%08x)", plugInResult))
        }
        defer { _ = plugIn.pointee?.pointee.Release(plugIn) }

        var rawInterface: LPVOID?
        let queryResult = withUnsafeMutablePointer(to: &rawInterface) { pointer in
            plugIn.pointee?.pointee.QueryInterface(
                plugIn,
                CFUUIDGetUUIDBytes(
                    CFUUIDGetConstantUUIDWithBytes(
                        nil, 0x87, 0x52, 0x66, 0x3B, 0xC0, 0x7B, 0x4B, 0xAE,
                        0x95, 0x84, 0x22, 0x03, 0x2F, 0xAB, 0x9C, 0x5A)),  // ID942
                pointer) ?? KERN_FAILURE
        }
        guard queryResult == S_OK, let rawInterface else {
            throw TransportError.interfaceNotFound
        }
        interface = InterfaceRef(OpaquePointer(rawInterface))

        // Claim the interface. This is the call the sandbox blocks under
        // IOUSBHost but permits here.
        let openResult = interface.pointee?.pointee.USBInterfaceOpen(interface) ?? KERN_FAILURE
        guard openResult == kIOReturnSuccess else {
            _ = interface.pointee?.pointee.Release(interface)
            throw TransportError.openFailed(
                openResult == kIOReturnExclusiveAccess
                    ? "The scanner is in use by another app"
                    : String(format: "Couldn't claim the scanner (0x%08x)", openResult))
        }

        try findPipes()
    }

    deinit {
        _ = interface.pointee?.pointee.USBInterfaceClose(interface)
        _ = interface.pointee?.pointee.Release(interface)
    }

    /// Maps endpoint addresses to IOUSBLib's 1-based pipe references.
    ///
    /// The addresses in docs/PROTOCOL.md §2 are preferred. A model that puts
    /// its bulk pair elsewhere gets the first bulk endpoint each way instead:
    /// the framing needs exactly one of each, and nothing else on the
    /// interface could carry it.
    private func findPipes() throws {
        var endpointCount: UInt8 = 0
        guard
            interface.pointee?.pointee.GetNumEndpoints(interface, &endpointCount)
                == kIOReturnSuccess
        else { throw TransportError.interfaceNotFound }

        var firstBulkOut: UInt8 = 0
        var firstBulkIn: UInt8 = 0
        for pipe in 1...max(endpointCount, 1) {
            var direction: UInt8 = 0
            var number: UInt8 = 0
            var transferType: UInt8 = 0
            var maxPacketSize: UInt16 = 0
            var interval: UInt8 = 0
            guard
                interface.pointee?.pointee.GetPipeProperties(
                    interface, pipe, &direction, &number, &transferType,
                    &maxPacketSize, &interval) == kIOReturnSuccess
            else { continue }
            // direction: 0 = out, 1 = in (kUSBOut / kUSBIn)
            let address = UInt8(number) | (direction == 1 ? 0x80 : 0x00)
            pipes.append(
                Pipe(
                    address: address, transferType: transferType,
                    maxPacketSize: Int(maxPacketSize)))
            if address == Self.bulkOutAddress { outPipe = pipe }
            if address == Self.bulkInAddress { inPipe = pipe }
            if transferType == Self.bulkTransferType {
                if direction == 1, firstBulkIn == 0 { firstBulkIn = pipe }
                if direction == 0, firstBulkOut == 0 { firstBulkOut = pipe }
            }
        }
        if outPipe == 0 { outPipe = firstBulkOut }
        if inPipe == 0 { inPipe = firstBulkIn }
        let found = pipes.map(\.address)
        guard outPipe != 0 else {
            throw TransportError.pipeNotFound(Self.bulkOutAddress, found: found)
        }
        guard inPipe != 0 else {
            throw TransportError.pipeNotFound(Self.bulkInAddress, found: found)
        }
    }

    private static let bulkTransferType: UInt8 = 2

    /// Finds a candidate scanner interface from this vendor, along with the
    /// product ID of the device it belongs to.
    ///
    /// Matching is on vendor alone: the family speaks one protocol, so a
    /// model this driver has never seen is worth trying rather than refusing.
    /// `preferredProductID` wins when several devices are attached, so the
    /// known-good one is never passed over for an untried sibling. Whether a
    /// candidate is really a scanner is settled by INQUIRY, not here.
    ///
    /// Only device services are matchable by vendor/product, so match the
    /// device and walk to its interface child.
    private static func findInterfaceService(
        vendorID: Int, preferredProductID: Int?
    ) -> (service: io_service_t, productID: Int)? {
        guard let found = findDevice(vendorID: vendorID, preferredProductID: preferredProductID)
        else { return nil }
        IOObjectRelease(found.device)
        return (found.interface, found.productID)  // caller releases
    }

    /// The device `findInterfaceService` settles on, with its interface. The
    /// caller releases both.
    private static func findDevice(
        vendorID: Int, preferredProductID: Int?
    ) -> (device: io_service_t, interface: io_service_t, productID: Int)? {
        // Deliberately unfiltered. IOUSBHostDevice honours only particular
        // *combinations* of matching properties, and vendor on its own is not
        // one of them: a dictionary carrying just idVendor matches nothing at
        // all, even with the device sitting on the bus. So enumerate USB and
        // pick the vendor out here.
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }

        var deviceIterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, matching, &deviceIterator)
                == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(deviceIterator) }

        var fallback: (device: io_service_t, interface: io_service_t, productID: Int)?
        while case let device = IOIteratorNext(deviceIterator), device != 0 {
            guard numberProperty(device, "idVendor") == vendorID,
                let interface = firstInterface(of: device)
            else {
                IOObjectRelease(device)
                continue
            }
            let productID = numberProperty(device, "idProduct") ?? 0
            if productID == preferredProductID {
                if let fallback {
                    IOObjectRelease(fallback.device)
                    IOObjectRelease(fallback.interface)
                }
                return (device, interface, productID)
            }
            if fallback == nil {
                fallback = (device, interface, productID)
            } else {
                IOObjectRelease(device)
                IOObjectRelease(interface)
            }
        }
        return fallback
    }

    private static func firstInterface(of device: io_service_t) -> io_service_t? {
        var childIterator: io_iterator_t = 0
        guard
            IORegistryEntryGetChildIterator(device, kIOServicePlane, &childIterator)
                == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(childIterator) }

        while case let child = IOIteratorNext(childIterator), child != 0 {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                return child
            }
            IOObjectRelease(child)
        }
        return nil
    }

    private static func numberProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard
            let value = IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        return (value as? NSNumber)?.intValue
    }

    /// The product ID of an attached candidate, or nil if there is none.
    static func present(vendorID: Int, preferredProductID: Int?) -> Int? {
        guard
            let found = findInterfaceService(
                vendorID: vendorID, preferredProductID: preferredProductID)
        else { return nil }
        IOObjectRelease(found.service)
        return found.productID
    }

    /// What the USB registry says about an attached candidate, without
    /// claiming it — for the diagnostics report. The serial number is
    /// deliberately not read.
    struct DeviceDescription: Sendable {
        let vendorID: Int
        let productID: Int
        /// `bcdDevice`: the device's release number, often its firmware.
        let release: Int?
        let vendorName: String?
        let productName: String?
        /// 0 low, 1 full, 2 high, 3 super, 4 super+ (IOKit's numbering).
        let speed: Int?
        let interfaceClass: Int?
        let interfaceSubclass: Int?
        let interfaceProtocol: Int?
    }

    static func describe(vendorID: Int, preferredProductID: Int?) -> DeviceDescription? {
        guard
            let found = findDevice(vendorID: vendorID, preferredProductID: preferredProductID)
        else { return nil }
        defer {
            IOObjectRelease(found.device)
            IOObjectRelease(found.interface)
        }
        func string(_ key: String) -> String? {
            IORegistryEntryCreateCFProperty(
                found.device, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
        }
        return DeviceDescription(
            vendorID: vendorID,
            productID: found.productID,
            release: numberProperty(found.device, "bcdDevice"),
            vendorName: string("USB Vendor Name") ?? string("kUSBVendorString"),
            productName: string("USB Product Name") ?? string("kUSBProductString"),
            speed: numberProperty(found.device, "Device Speed")
                ?? numberProperty(found.device, "USBSpeed"),
            interfaceClass: numberProperty(found.interface, "bInterfaceClass"),
            interfaceSubclass: numberProperty(found.interface, "bInterfaceSubClass"),
            interfaceProtocol: numberProperty(found.interface, "bInterfaceProtocol"))
    }

    // MARK: - Framing

    /// Sends a command and returns its status, transferring `dataOut` or
    /// filling `dataIn` in between when the command has a data phase.
    @discardableResult
    func send(cdb: [UInt8], dataOut: Data? = nil, dataIn: Int = 0) throws -> (
        status: CommandStatus, data: Data
    ) {
        let started = ContinuousClock.now
        var received = Data()
        var statusPacket = Data()
        do {
            try writeCommandPacket(cdb: cdb)

            if let dataOut, !dataOut.isEmpty {
                try write(dataOut)
            }

            if dataIn > 0 {
                received = try read(maxLength: dataIn)
            }

            if Self.isStatusPacket(received, inPlaceOf: dataIn) {
                // The device answered with its status where the data belonged:
                // it had no data to send. Reading on for a status would wait
                // out the timeout and leave the next command out of step.
                statusPacket = received
                received = Data()
            } else {
                statusPacket = try read(maxLength: Self.statusPacketLength)
            }
            let status = try Self.commandStatus(from: statusPacket)
            recorder?.record(
                cdb: cdb, dataOut: dataOut, requested: dataIn, received: received,
                statusPacket: statusPacket, error: nil,
                elapsed: ContinuousClock.now - started)
            return (status, received)
        } catch {
            recorder?.record(
                cdb: cdb, dataOut: dataOut, requested: dataIn, received: received,
                statusPacket: statusPacket, error: error,
                elapsed: ContinuousClock.now - started)
            throw error
        }
    }

    /// True when a data-in read caught a status packet instead. No command
    /// this driver sends asks for exactly a status packet's length, so a
    /// 13-byte reply tagged `S` to a longer request can only be that.
    static func isStatusPacket(_ data: Data, inPlaceOf requested: Int) -> Bool {
        requested != statusPacketLength && data.count == statusPacketLength
            && data.first == statusTag
    }

    private func writeCommandPacket(cdb: [UInt8]) throws {
        precondition(cdb.count <= Self.commandPacketLength - Self.cdbOffset)
        var packet = [UInt8](repeating: 0, count: Self.commandPacketLength)
        packet[0] = Self.commandTag
        packet.replaceSubrange(Self.cdbOffset..<(Self.cdbOffset + cdb.count), with: cdb)
        try write(Data(packet))
    }

    private static func commandStatus(from status: Data) throws -> CommandStatus {
        guard status.count >= statusFlagOffset + 1 else {
            throw TransportError.shortStatus(status.count)
        }
        guard status[status.startIndex] == statusTag else {
            throw TransportError.badStatusTag(status[status.startIndex])
        }
        return CommandStatus(byte: status[status.startIndex + statusFlagOffset])
    }

    // MARK: - Raw pipe access

    func write(_ data: Data) throws {
        var bytes = [UInt8](data)
        let result = bytes.withUnsafeMutableBytes { buffer -> IOReturn in
            interface.pointee?.pointee.WritePipeTO(
                interface, outPipe, buffer.baseAddress, UInt32(buffer.count),
                timeoutMilliseconds, timeoutMilliseconds) ?? KERN_FAILURE
        }
        guard result == kIOReturnSuccess else {
            throw TransportError.io(String(format: "USB write failed (0x%08x)", result))
        }
    }

    func read(maxLength: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        var size = UInt32(maxLength)
        let result = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            interface.pointee?.pointee.ReadPipeTO(
                interface, inPipe, raw.baseAddress, &size,
                timeoutMilliseconds, timeoutMilliseconds) ?? KERN_FAILURE
        }
        guard result == kIOReturnSuccess else {
            throw TransportError.io(String(format: "USB read failed (0x%08x)", result))
        }
        return Data(buffer.prefix(Int(size)))
    }
}
