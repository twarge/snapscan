// Bring-up check for the native (non-SANE) scanner driver: opens the
// scanner over IOUSBHost, runs TEST UNIT READY, INQUIRY, the vendor
// capability page, and a sensor read, printing what comes back.
//
// The scanner must be free — quit SnapScan first, since a claimed
// interface is exclusive.
import Foundation

let vendorID = 0x04C5
let productID = 0x132B

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

guard USBTransport.isPresent(vendorID: vendorID, productID: productID) else {
    fail("scanner not on USB — is it plugged in with the flap open?")
}
print("device present on USB")

let transport: USBTransport
do {
    transport = try USBTransport(vendorID: vendorID, productID: productID)
} catch {
    fail("open: \(error.localizedDescription)")
}
print("interface claimed, bulk pipes open")

// TEST UNIT READY — no data phase.
do {
    let (status, _) = try transport.send(cdb: ScannerCommands.testUnitReady())
    print("TEST UNIT READY: \(status)")
} catch {
    fail("TEST UNIT READY: \(error.localizedDescription)")
}

// INQUIRY — the identity check.
do {
    let (status, data) = try transport.send(
        cdb: ScannerCommands.inquiry(), dataIn: 96)
    guard let identity = ScannerCommands.parseInquiry(data) else {
        fail("INQUIRY returned \(data.count) bytes, could not parse")
    }
    print(
        "INQUIRY: \(status) — \(identity.vendor) \(identity.model) "
            + "(device type 0x\(String(identity.deviceType, radix: 16)))")
    guard identity.deviceType == 0x06 else {
        fail("expected SCSI device type 0x06 (scanner)")
    }
} catch {
    fail("INQUIRY: \(error.localizedDescription)")
}

// Vendor capability page.
do {
    let (status, data) = try transport.send(
        cdb: ScannerCommands.inquiryVendorPage(), dataIn: 204)
    print("INQUIRY page 0xF0: \(status), \(data.count) bytes")
    print("  first 16: \(data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))")
} catch {
    fail("vendor INQUIRY: \(error.localizedDescription)")
}

// Sensors (vendor 0xC2) — the Scan button lives in here.
do {
    let (status, data) = try transport.send(
        cdb: ScannerCommands.hardwareStatus(), dataIn: 12)
    print("hardware status: \(status)")
    print("  bytes: \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
} catch {
    fail("hardware status: \(error.localizedDescription)")
}

print("PASS — native transport works end to end")
