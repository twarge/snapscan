// Bring-up check for the native (non-SANE) scanner driver: identifies the
// attached scanner the way Help ▸ Scanner Diagnostics does — USB details,
// TEST UNIT READY, INQUIRY, the vendor capability page, the mode pages read
// back, a sensor read — and prints the same report. `--setup` also sends
// the setup sequence step by step.
//
// The scanner must be free — quit SnapScan first, since a claimed
// interface is exclusive.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Unbuffered, so a hang leaves a usable trail when output is redirected.
setvbuf(stdout, nil, _IONBF, 0)

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

guard NativeScanner.isPresent() else {
    fail("no scanner on USB — is it plugged in with the flap open?")
}

// Detached: top-level code is main-actor isolated, so an inheriting Task
// would deadlock against the semaphore wait below.
let identified = DispatchSemaphore(value: 0)
nonisolated(unsafe) var isScanner = false
Task.detached {
    defer { identified.signal() }
    let recorder = TransferRecorder()
    await NativeScanner.shared.setRecorder(recorder)
    var report = DiagnosticReport.current()
    report.identification = await NativeScanner.shared.identify()
    if CommandLine.arguments.contains("--setup") {
        recorder.begin(step: "setup check")
        var settings = ScanSettings()
        settings.source = .front
        settings.paperSize = .letter
        report.setup = await NativeScanner.shared.checkSetup(
            settings: settings, windows: [.front])
    }
    await NativeScanner.shared.setRecorder(nil)
    report.transcript = recorder.transcript
    print(report.text)
    isScanner = report.identification?.isScanner == true
}
identified.wait()
guard isScanner else { fail("the device did not identify itself as a scanner") }

// Sensor mapping aid: poll the vendor 0xC2 block and print it whenever it
// changes, so physical actions (press Scan, load paper, open the cover)
// can be matched to bits.
if CommandLine.arguments.contains("--watch-sensors") {
    print("watching sensors — press the Scan button, load paper, open the cover…")
    print("(ctrl-C to stop)")
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        defer { semaphore.signal() }
        do {
            _ = try await NativeScanner.shared.open()
            var previous = Data()
            while true {
                let state = await NativeScanner.shared.sensorState()
                let block = state?.raw ?? Data()
                if block != previous {
                    let hex = block.map { String(format: "%02x", $0) }.joined(separator: " ")
                    var decoded: [String] = []
                    if state?.scanButton == true { decoded.append("SCAN BUTTON") }
                    if state?.feederClosed == true { decoded.append("feeder closed") }
                    if state?.coverOpen == true { decoded.append("cover open") }
                    print("\(hex)   \(decoded.isEmpty ? "idle" : decoded.joined(separator: ", "))")
                    previous = block
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            print("sensor watch ended: \(error.localizedDescription)")
        }
    }
    semaphore.wait()
    exit(0)
}

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
