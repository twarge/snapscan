// Headless hardware smoke test for the in-process SANE stack.
// Exercises init → device list → open → option index → Scan-button sensor →
// empty-feeder sane_start (expects NO_DOCS unless paper is loaded).
// Usage: swift run SaneSmokeTest [--scan]   (--scan reads pages if paper is in)
import CSane
import Foundation

let repoVendor = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // main.swift
    .deletingLastPathComponent()  // SaneSmokeTest
    .deletingLastPathComponent()  // Sources
    .appendingPathComponent("vendor")

setenv("SANE_CONFIG_DIR", repoVendor.appendingPathComponent("etc/sane.d").path, 1)
setenv("LD_LIBRARY_PATH", repoVendor.appendingPathComponent("lib/sane").path, 1)

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

var version: SANE_Int = 0
guard sane_init(&version, nil) == SANE_STATUS_GOOD else { fail("sane_init") }
print(
    "sane_init ok, version \(version >> 24).\((version >> 16) & 0xFF).\(version & 0xFFFF)")

var list: UnsafeMutablePointer<UnsafePointer<SANE_Device>?>? = nil
guard sane_get_devices(&list, SANE_Bool(1)) == SANE_STATUS_GOOD, let list else {
    fail("sane_get_devices")
}
var deviceName: String? = nil
var index = 0
while let entry = list[index] {
    let name = String(cString: entry.pointee.name)
    print("device: \(name) (\(String(cString: entry.pointee.vendor)) \(String(cString: entry.pointee.model)))")
    if deviceName == nil { deviceName = name }
    index += 1
}
guard let deviceName else { fail("no devices found — is the iX500 plugged in with the flap open?") }

var handle: SANE_Handle? = nil
guard sane_open(deviceName, &handle) == SANE_STATUS_GOOD, let handle else {
    fail("sane_open")
}
print("sane_open ok")

var optionCount: SANE_Int = 0
guard sane_control_option(handle, 0, SANE_ACTION_GET_VALUE, &optionCount, nil)
    == SANE_STATUS_GOOD
else { fail("option count") }
var scanButtonIndex: SANE_Int? = nil
var pageLoadedIndex: SANE_Int? = nil
for option in 1..<optionCount {
    guard let descriptor = sane_get_option_descriptor(handle, option),
        let namePointer = descriptor.pointee.name
    else { continue }
    switch String(cString: namePointer) {
    case "scan": scanButtonIndex = option
    case "page-loaded": pageLoadedIndex = option
    default: break
    }
}
print("options: \(optionCount) total, scan sensor at \(scanButtonIndex.map(String.init) ?? "MISSING")")
guard let scanButtonIndex else { fail("scan button sensor not found") }

var pressed: SANE_Int = -1
guard sane_control_option(handle, scanButtonIndex, SANE_ACTION_GET_VALUE, &pressed, nil)
    == SANE_STATUS_GOOD
else { fail("read scan sensor") }
print("scan button pressed: \(pressed != 0)")

if let pageLoadedIndex {
    var loaded: SANE_Int = -1
    if sane_control_option(handle, pageLoadedIndex, SANE_ACTION_GET_VALUE, &loaded, nil)
        == SANE_STATUS_GOOD {
        print("page loaded: \(loaded != 0)")
    }
}

// Optional scan settings, so captures can exercise duplex, color modes,
// and resolutions rather than only the backend's defaults:
//   --source "ADF Duplex"  --mode Color  --resolution 300
func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func optionIndex(named wanted: String) -> SANE_Int? {
    for option in 1..<optionCount {
        guard let descriptor = sane_get_option_descriptor(handle, option),
            let namePointer = descriptor.pointee.name
        else { continue }
        if String(cString: namePointer) == wanted { return option }
    }
    return nil
}

func setStringOption(_ name: String, _ value: String) {
    guard let index = optionIndex(named: name),
        let descriptor = sane_get_option_descriptor(handle, index)
    else {
        print("option \(name) not found")
        return
    }
    var buffer = [CChar](repeating: 0, count: Int(descriptor.pointee.size) + 1)
    for (offset, byte) in value.utf8CString.prefix(buffer.count - 1).enumerated() {
        buffer[offset] = byte
    }
    let status = sane_control_option(handle, index, SANE_ACTION_SET_VALUE, &buffer, nil)
    print("set \(name)=\(value): \(status == SANE_STATUS_GOOD ? "ok" : "failed \(status.rawValue)")")
}

func setIntOption(_ name: String, _ value: Int) {
    guard let index = optionIndex(named: name) else {
        print("option \(name) not found")
        return
    }
    var mutable = SANE_Int(value)
    let status = sane_control_option(handle, index, SANE_ACTION_SET_VALUE, &mutable, nil)
    print("set \(name)=\(value): \(status == SANE_STATUS_GOOD ? "ok" : "failed \(status.rawValue)")")
}

// Order matters: source/mode/resolution reload the option table and reset
// geometry, so set them before anything positional.
if let source = argument("--source") { setStringOption("source", source) }
if let mode = argument("--mode") { setStringOption("mode", mode) }
if let resolution = argument("--resolution").flatMap(Int.init) {
    setIntOption("resolution", resolution)
}
// Auto length detection: the scanner ends the frame at the paper's real
// trailing edge, so a short sheet reports its true length.
if CommandLine.arguments.contains("--ald") {
    setIntOption("ald", 1)
    // Give it room to detect a shorter page than the window allows.
    setIntOption("page-height", Int(876.0 * 65536))
    setIntOption("br-y", Int(876.0 * 65536))
}

let wantScan = CommandLine.arguments.contains("--scan")

// Each sane_start yields one image. In duplex that means two per sheet
// (front then back), so loop until the feeder reports no more documents —
// otherwise a "duplex" capture only ever records one side.
var page = 0
scanLoop: while true {
    let startStatus = sane_start(handle)
    switch startStatus {
    case SANE_STATUS_NO_DOCS:
        print(page == 0 ? "sane_start: feeder empty" : "sane_start: no more pages")
        sane_cancel(handle)
        break scanLoop
    case SANE_STATUS_GOOD:
        page += 1
        var parameters = SANE_Parameters()
        _ = sane_get_parameters(handle, &parameters)
        print(
            "page \(page): \(parameters.pixels_per_line)x\(parameters.lines) "
                + "depth \(parameters.depth) bytesPerLine \(parameters.bytes_per_line)")
        guard wantScan else {
            sane_cancel(handle)
            break scanLoop
        }
        var total = 0
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            var length: SANE_Int = 0
            let status = chunk.withUnsafeMutableBufferPointer {
                sane_read(handle, $0.baseAddress, SANE_Int($0.count), &length)
            }
            if status == SANE_STATUS_GOOD {
                total += Int(length)
            } else {
                print("  page \(page) read ended with \(status.rawValue), \(total) bytes")
                break
            }
        }
    default:
        print("sane_start: status \(startStatus.rawValue)")
        sane_cancel(handle)
        break scanLoop
    }
}

sane_close(handle)
sane_exit()
print("PASS")
