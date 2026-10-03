import AppKit
import Testing

@testable import SnapScan

@Suite struct PageToneTests {
    private static let width = 600
    private static let height = 800
    private static let dpi = 150

    /// Paper that darkens toward the right, as along a fold or the edge of
    /// the lamp, with lines of print across it and a solid black block.
    private func page() -> CGImage {
        let context = CGContext(
            data: nil, width: Self.width, height: Self.height, bitsPerComponent: 8,
            bytesPerRow: Self.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                // CG memory rows run top to bottom.
                let shade = 250 - 70 * x / Self.width
                let printed = y >= 100 && y < 400 && y % 30 < 3 && x > 40
                let block = (500..<650).contains(y) && (200..<350).contains(x)
                let value = UInt8(block ? 20 : printed ? 45 : shade)
                for channel in 0..<3 { pixels[4 * (y * Self.width + x) + channel] = value }
            }
        }
        return context.makeImage()!
    }

    /// Black pixels in a region, top-left origin, read from a 1-bit image.
    private func blackShare(
        of image: CGImage, rows: Range<Int>, columns: Range<Int>,
        where include: (Int, Int) -> Bool = { _, _ in true }
    ) -> Double {
        let bytes = CFDataGetBytePtr(image.dataProvider!.data)!
        var black = 0
        var total = 0
        for y in rows {
            for x in columns where include(x, y) {
                total += 1
                if bytes[y * image.bytesPerRow + x / 8] & (0x80 >> UInt8(x % 8)) == 0 {
                    black += 1
                }
            }
        }
        return Double(black) / Double(max(total, 1))
    }

    @Test func colorIsLeftAsItIs() throws {
        let image = page()
        #expect(PageTone.render(image, as: .color, dpi: Self.dpi) === image)
    }

    @Test func grayscaleIsOneChannel() throws {
        let gray = try #require(PageTone.render(page(), as: .gray, dpi: Self.dpi))
        #expect(gray.colorSpace?.model == .monochrome)
        #expect(gray.bitsPerPixel == 8)
        #expect(gray.width == Self.width && gray.height == Self.height)
    }

    @Test func blackAndWhiteKeepsPrintAndClearsShadedPaper() throws {
        let lineart = try #require(PageTone.render(page(), as: .lineart, dpi: Self.dpi))
        #expect(lineart.bitsPerPixel == 1)
        #expect(lineart.colorSpace?.model == .monochrome)

        // Paper, light and shaded alike, stays white…
        let paper = blackShare(of: lineart, rows: 420..<480, columns: 0..<Self.width)
        #expect(paper < 0.005)
        // …the print on it comes out black, shaded end included…
        let print = blackShare(
            of: lineart, rows: 100..<400, columns: 41..<Self.width,
            where: { _, y in y % 30 < 3 })
        #expect(print > 0.95)
        // …and so does a solid block, right through its middle.
        let block = blackShare(of: lineart, rows: 520..<630, columns: 220..<330)
        #expect(block > 0.99)
    }
}
