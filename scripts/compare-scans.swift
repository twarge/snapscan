// Compares a native-driver scan against a SANE scan of the same page.
//
//   swift scripts/compare-scans.swift <native.png> <sane.png>
//
// An ADF feeds each sheet slightly differently, so the two passes are never
// pixel-identical. What must match is the *character* of the image:
// dimensions, tone, and contrast. Large divergence there means the native
// driver is interpreting the data differently — a wrong inversion, gamma,
// or channel order.
import AppKit

func load(_ path: String) -> (width: Int, height: Int, gray: [UInt8])? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    pixels.withUnsafeMutableBytes { raw in
        guard
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (width, height, pixels)
}

func stats(_ pixels: [UInt8]) -> (mean: Double, dark: Double, light: Double) {
    let total = Double(pixels.count)
    let sum = pixels.reduce(0.0) { $0 + Double($1) }
    let dark = Double(pixels.filter { $0 < 96 }.count) / total
    let light = Double(pixels.filter { $0 > 192 }.count) / total
    return (sum / total, dark, light)
}

guard CommandLine.arguments.count == 3,
    let native = load(CommandLine.arguments[1]),
    let sane = load(CommandLine.arguments[2])
else {
    print("usage: compare-scans.swift <native.png> <sane.png>")
    exit(2)
}

print("             native            sane")
print("size         \(native.width)x\(native.height)".padding(toLength: 30, withPad: " ", startingAt: 0)
    + "\(sane.width)x\(sane.height)")

let n = stats(native.gray)
let s = stats(sane.gray)
func row(_ label: String, _ a: Double, _ b: Double, _ tolerance: Double) -> String {
    let verdict = abs(a - b) <= tolerance ? "ok" : "DIFFERS"
    return label.padding(toLength: 13, withPad: " ", startingAt: 0)
        + String(format: "%-18.1f%-16.1f%@", a, b, verdict)
}
print(row("mean tone", n.mean, s.mean, 12))
print(row("dark %", n.dark * 100, s.dark * 100, 5))
print(row("light %", n.light * 100, s.light * 100, 5))

let sizeMatches = native.width == sane.width && abs(native.height - sane.height) <= 8
let toneMatches = abs(n.mean - s.mean) <= 12
print()
print(sizeMatches && toneMatches
    ? "PASS — the native driver reproduces SANE's output"
    : "REVIEW — the two drivers differ; inspect both images")
