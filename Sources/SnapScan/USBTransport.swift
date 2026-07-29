import Foundation
import IOKit
import IOUSBHost

/// Native USB transport for the scanner, implementing the framing recorded
/// in docs/PROTOCOL.md: a 31-byte command packet tagged 0x43 carrying a SCSI
/// CDB, an optional data phase, and a 13-byte status packet tagged 0x53.
///
/// This is the replacement for libusb + sane-backends; it uses only
/// IOUSBHost.framework, so nothing GPL-licensed is involved.
nonisolated final class USBTransport {
    enum TransportError: Error, LocalizedError {
        case deviceNotFound
        case interfaceNotFound
        case pipeNotFound(UInt8)
        case shortStatus(Int)
        case badStatusTag(UInt8)
        case io(String)

        var errorDescription: String? {
            switch self {
            case .deviceNotFound: "Scanner not found on USB"
            case .interfaceNotFound: "Scanner interface not available"
            case .pipeNotFound(let address):
                String(format: "Scanner endpoint 0x%02x not found", address)
            case .shortStatus(let count): "Truncated status packet (\(count) bytes)"
            case .badStatusTag(let tag):
                String(format: "Unexpected status tag 0x%02x", tag)
            case .io(let detail): detail
            }
        }
    }

    /// The scanner's reply to a command: the status packet's meaning.
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

    private let interface: IOUSBHostInterface
    private let outPipe: IOUSBHostPipe
    private let inPipe: IOUSBHostPipe
    private let timeout: TimeInterval = 30

    // MARK: - Discovery

    /// Opens the first matching scanner. The interface is claimed for the
    /// lifetime of this object, so only one instance may exist at a time.
    init(vendorID: Int, productID: Int) throws {
        guard let service = Self.findInterfaceService(vendorID: vendorID, productID: productID)
        else {
            throw TransportError.deviceNotFound
        }
        defer { IOObjectRelease(service) }

        // IOUSBHost's initializers and IO methods are NS_REFINED_FOR_SWIFT
        // with no overlay shipped, so they appear under `__` names.
        let interface = try IOUSBHostInterface(
            __ioService: service, options: [], queue: nil, interestHandler: nil)
        self.interface = interface

        guard let outPipe = try? interface.copyPipe(withAddress: Int(Self.bulkOutAddress))
        else { throw TransportError.pipeNotFound(Self.bulkOutAddress) }
        guard let inPipe = try? interface.copyPipe(withAddress: Int(Self.bulkInAddress))
        else { throw TransportError.pipeNotFound(Self.bulkInAddress) }
        self.outPipe = outPipe
        self.inPipe = inPipe
    }

    deinit {
        interface.destroy()
    }

    /// Finds the scanner's USB *interface* service — the object that owns the
    /// bulk pipes. Only device services are matchable by vendor/product, so
    /// this matches the device and then walks to its interface child.
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
        let buffer = NSMutableData(data: data)
        var transferred = 0
        do {
            try outPipe.__sendIORequest(
                with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            throw TransportError.io("USB write failed: \(error.localizedDescription)")
        }
    }

    func read(maxLength: Int) throws -> Data {
        guard let buffer = NSMutableData(length: maxLength) else {
            throw TransportError.io("could not allocate \(maxLength) bytes")
        }
        var transferred = 0
        do {
            try inPipe.__sendIORequest(
                with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            throw TransportError.io("USB read failed: \(error.localizedDescription)")
        }
        return Data(bytes: buffer.bytes, count: min(transferred, maxLength))
    }
}
