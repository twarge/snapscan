import CoreGraphics
import Foundation

/// Builds CGImages from raw scanner frame data (as delivered by sane_read).
/// Also used to assemble partial pages from however many rows have arrived.
enum FrameImage {
    enum PixelFormat {
        /// 8-bit grayscale, one byte per pixel.
        case gray8
        /// 24-bit RGB, three bytes per pixel.
        case rgb24
        /// 1-bit packed, SANE/PNM convention: 1 = black.
        case mono1
    }

    static func make(
        pixels: Data, width: Int, height: Int, bytesPerRow: Int, format: PixelFormat
    ) -> CGImage? {
        guard width > 0, height > 0, pixels.count >= bytesPerRow * height else { return nil }
        let data = pixels.count == bytesPerRow * height
            ? pixels
            : pixels.prefix(bytesPerRow * height)

        let bitsPerComponent: Int
        let bitsPerPixel: Int
        let colorSpace: CGColorSpace
        var decodeArray: [CGFloat]? = nil
        switch format {
        case .gray8:
            bitsPerComponent = 8
            bitsPerPixel = 8
            colorSpace = CGColorSpaceCreateDeviceGray()
        case .rgb24:
            bitsPerComponent = 8
            bitsPerPixel = 24
            colorSpace = CGColorSpaceCreateDeviceRGB()
        case .mono1:
            bitsPerComponent = 1
            bitsPerPixel = 1
            colorSpace = CGColorSpaceCreateDeviceGray()
            decodeArray = [1, 0]  // scanner packs 1 = black; CG gray is 0 = black
        }

        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: decodeArray,
            shouldInterpolate: true,
            intent: .defaultIntent)
    }
}
