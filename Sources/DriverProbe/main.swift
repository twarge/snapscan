// Bring-up check for the native (non-SANE) scanner driver: opens the
// scanner over IOUSBHost, runs TEST UNIT READY, INQUIRY, the vendor
// capability page, and a sensor read, printing what comes back.
//
// The scanner must be free — quit SnapScan first, since a claimed
// interface is exclusive.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Unbuffered, so a hang leaves a usable trail when output is redirected.
setvbuf(stdout, nil, _IONBF, 0)

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

// Scoped so the interface is released before the scan section claims it —
// only one claim on the interface can exist at a time.
func runDiagnostics() {
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
}

runDiagnostics()

// Optional: run a real scan through the native pipeline.
//   DriverProbe --scan [--duplex] [--resolution N] [--out DIR]
if CommandLine.arguments.contains("--scan") {
    func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    // The transport above holds the interface; hand the scan its own.
    var settings = ScanSettings()
    settings.source = CommandLine.arguments.contains("--duplex") ? .duplex : .front
    settings.resolution = argument("--resolution").flatMap(Int.init) ?? 300
    settings.paperSize = .letter

    let outputDirectory = URL(
        fileURLWithPath: argument("--out") ?? FileManager.default.currentDirectoryPath)

    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var scanError: Error?

    // Detached: top-level code is main-actor isolated, so an inheriting
    // Task would deadlock against the semaphore wait below.
    Task.detached {
        defer { semaphore.signal() }
        do {
            let info = try await NativeScanner.shared.open()
            print("native scan on \(info.vendor) \(info.model), "
                + "\(settings.source.rawValue), \(settings.resolution) dpi")
            let result = try await NativeScanner.shared.scanBatch(
                settings: settings, startingAtPage: 0
            ) { event in
                switch event {
                case .pageStarted(let index):
                    print("  page \(index + 1): started")
                case .pagePartial(let index, let image, let fraction):
                    let percent = fraction.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""
                    print("  page \(index + 1): \(image.height) rows\(percent)")
                case .pageComplete(let index, let image):
                    print("  page \(index + 1): complete, \(image.width)x\(image.height)")
                    let url = outputDirectory.appendingPathComponent(
                        "native-page-\(index + 1).png")
                    if let destination = CGImageDestinationCreateWithURL(
                        url as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, image, nil)
                        if CGImageDestinationFinalize(destination) {
                            print("    wrote \(url.path)")
                        }
                    }
                }
            }
            print(
                "scan finished: \(result.pagesScanned) page(s)"
                    + (result.feederWasEmpty ? " — feeder was empty" : ""))
        } catch {
            scanError = error
        }
    }
    semaphore.wait()
    if let scanError {
        fail("scan: \(scanError.localizedDescription)")
    }
}

print("PASS — native transport works end to end")
