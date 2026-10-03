import Accelerate
import CoreGraphics
import Foundation

/// Makes a page what the Color setting asks for. The scanner only ever sends
/// colour (docs/PROTOCOL.md §4.3), so grayscale and black & white are made
/// here — last in a page's processing, after it has been straightened and
/// read, which both go better with more to go on.
nonisolated enum PageTone {
    static func render(_ image: CGImage, as mode: ScanMode, dpi: Int) -> CGImage? {
        switch mode {
        case .color: image
        case .gray: grayscale(image)
        case .lineart: grayscale(image).flatMap { blackAndWhite($0, dpi: dpi) }
        }
    }

    private static func grayscale(_ image: CGImage) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// One bit a pixel. Each pixel is judged against the paper around it
    /// rather than one level for the whole page, so a shadow along a fold,
    /// a tinted form or uneven lighting stays white while the print on it
    /// stays black.
    private static func blackAndWhite(_ gray: CGImage, dpi: Int) -> CGImage? {
        let width = gray.width
        let height = gray.height
        guard let source = gray.dataProvider?.data, gray.bitsPerPixel == 8,
            let bytes = CFDataGetBytePtr(source)
        else { return nil }

        // The surroundings: the average over about an eighth of an inch.
        let side = max(3, (dpi / 8) | 1)
        var average = [UInt8](repeating: 0, count: width * height)
        let averaged = average.withUnsafeMutableBytes { raw -> vImage_Error in
            var input = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: bytes),
                height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: gray.bytesPerRow)
            var output = vImage_Buffer(
                data: raw.baseAddress, height: vImagePixelCount(height),
                width: vImagePixelCount(width), rowBytes: width)
            return vImageBoxConvolve_Planar8(
                &input, &output, nil, 0, 0, UInt32(side), UInt32(side), 0,
                vImage_Flags(kvImageEdgeExtend))
        }
        guard averaged == kvImageNoError else { return nil }

        // Ink: clearly darker than its surroundings, or dark outright — the
        // second keeps the middle of a large black area from washing out to
        // its own average. 1 is white, as DeviceGray reads one bit.
        let rowBytes = (width + 7) / 8
        var packed = [UInt8](repeating: 0xFF, count: rowBytes * height)
        average.withUnsafeBufferPointer { average in
            packed.withUnsafeMutableBufferPointer { packed in
                for y in 0..<height {
                    let row = bytes + y * gray.bytesPerRow
                    let surroundings = average.baseAddress! + y * width
                    let out = packed.baseAddress! + y * rowBytes
                    for x in 0..<width {
                        let value = Int(row[x])
                        if value * 100 < Int(surroundings[x]) * 85 || value < 96 {
                            out[x >> 3] &= ~(0x80 >> UInt8(x & 7))
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(packed) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1,
            bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }
}
