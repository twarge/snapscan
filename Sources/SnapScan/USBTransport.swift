import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

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
        case pipeNotFound(UInt8)
        case shortStatus(Int)
        case badStatusTag(UInt8)
        case io(String)

        var errorDescription: String? {
            switch self {
            case .deviceNotFound: "Scanner not found on USB"
            case .interfaceNotFound: "Scanner interface not available"
            case .openFailed(let detail): detail
            case .pipeNotFound(let address):
                String(format: "Scanner endpoint 0x%02x not found", address)
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

    // MARK: - Discovery

    init(vendorID: Int, productID: Int) throws {
        guard let service = Self.findInterfaceService(vendorID: vendorID, productID: productID)
        else { throw TransportError.deviceNotFound }
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
    private func findPipes() throws {
        var endpointCount: UInt8 = 0
        guard
            interface.pointee?.pointee.GetNumEndpoints(interface, &endpointCount)
                == kIOReturnSuccess
        else { throw TransportError.interfaceNotFound }

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
            if address == Self.bulkOutAddress { outPipe = pipe }
            if address == Self.bulkInAddress { inPipe = pipe }
        }
        guard outPipe != 0 else { throw TransportError.pipeNotFound(Self.bulkOutAddress) }
        guard inPipe != 0 else { throw TransportError.pipeNotFound(Self.bulkInAddress) }
    }

    /// Finds the scanner's USB interface service. Only device services are
    /// matchable by vendor/product, so match the device and walk to its
    /// interface child.
    private static func findInterfaceService(vendorID: Int, productID: Int) -> io_service_t? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary?
        else { return nil }
        matching["idVendor"] = vendorID
        matching["idProduct"] = productID

        var deviceIterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, matching, &deviceIterator)
                == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(deviceIterator) }

        while case let device = IOIteratorNext(deviceIterator), device != 0 {
            defer { IOObjectRelease(device) }
            var childIterator: io_iterator_t = 0
            guard
                IORegistryEntryGetChildIterator(device, kIOServicePlane, &childIterator)
                    == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(childIterator) }

            while case let child = IOIteratorNext(childIterator), child != 0 {
                if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                    return child  // caller releases
                }
                IOObjectRelease(child)
            }
        }
        return nil
    }

    static func isPresent(vendorID: Int, productID: Int) -> Bool {
        guard let service = findInterfaceService(vendorID: vendorID, productID: productID)
        else { return false }
        IOObjectRelease(service)
        return true
    }

    // MARK: - Framing

    /// Sends a command and returns its status, transferring `dataOut` or
    /// filling `dataIn` in between when the command has a data phase.
    @discardableResult
    func send(cdb: [UInt8], dataOut: Data? = nil, dataIn: Int = 0) throws -> (
        status: CommandStatus, data: Data
    ) {
        try writeCommandPacket(cdb: cdb)

        if let dataOut, !dataOut.isEmpty {
            try write(dataOut)
        }

        var received = Data()
        if dataIn > 0 {
            received = try read(maxLength: dataIn)
        }

        let status = try readStatusPacket()
        return (status, received)
    }

    private func writeCommandPacket(cdb: [UInt8]) throws {
        precondition(cdb.count <= Self.commandPacketLength - Self.cdbOffset)
        var packet = [UInt8](repeating: 0, count: Self.commandPacketLength)
        packet[0] = Self.commandTag
        packet.replaceSubrange(Self.cdbOffset..<(Self.cdbOffset + cdb.count), with: cdb)
        try write(Data(packet))
    }

    private func readStatusPacket() throws -> CommandStatus {
        let status = try read(maxLength: Self.statusPacketLength)
        guard status.count >= Self.statusFlagOffset + 1 else {
            throw TransportError.shortStatus(status.count)
        }
        guard status[status.startIndex] == Self.statusTag else {
            throw TransportError.badStatusTag(status[status.startIndex])
        }
        return CommandStatus(byte: status[status.startIndex + Self.statusFlagOffset])
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
