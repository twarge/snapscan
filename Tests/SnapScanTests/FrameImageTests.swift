import Foundation
import Testing

@testable import SnapScan

@Suite struct FrameImageTests {
    @Test func rgbFrame() throws {
        let pixels = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
        let image = try #require(
            FrameImage.make(pixels: pixels, width: 2, height: 2, bytesPerRow: 6, format: .rgb24))
        #expect(image.width == 2)
        #expect(image.height == 2)
        #expect(image.bitsPerPixel == 24)
    }

    @Test func grayFrame() throws {
        let image = try #require(
            FrameImage.make(
                pixels: Data([0, 128, 255]), width: 3, height: 1, bytesPerRow: 3,
                format: .gray8))
        #expect(image.bitsPerPixel == 8)
    }

    @Test func monoFrameRowPadding() throws {
        // 10 pixels/row packs into 2 bytes per row.
        let image = try #require(
            FrameImage.make(
                pixels: Data([0b1010_1010, 0b1100_0000, 0b0101_0101, 0b0100_0000]),
                width: 10, height: 2, bytesPerRow: 2, format: .mono1))
        #expect(image.width == 10)
        #expect(image.bitsPerPixel == 1)
    }

    @Test func partialRowsUsePrefix() throws {
        // 4 rows of data offered, only 3 requested (a partial page).
        let image = try #require(
            FrameImage.make(
                pixels: Data(repeating: 9, count: 4 * 5), width: 5, height: 3,
                bytesPerRow: 5, format: .gray8))
        #expect(image.height == 3)
    }

    @Test func truncatedDataFails() {
        #expect(
            FrameImage.make(
                pixels: Data([1, 2, 3]), width: 2, height: 2, bytesPerRow: 2,
                format: .gray8) == nil)
    }
}
