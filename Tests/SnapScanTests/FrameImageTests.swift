import XCTest

@testable import SnapScan

final class FrameImageTests: XCTestCase {
    func testRGBFrame() throws {
        let pixels = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
        let image = try XCTUnwrap(
            FrameImage.make(pixels: pixels, width: 2, height: 2, bytesPerRow: 6, format: .rgb24))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.bitsPerPixel, 24)
    }

    func testGrayFrame() throws {
        let image = try XCTUnwrap(
            FrameImage.make(
                pixels: Data([0, 128, 255]), width: 3, height: 1, bytesPerRow: 3,
                format: .gray8))
        XCTAssertEqual(image.bitsPerPixel, 8)
    }

    func testMonoFrameRowPadding() throws {
        // 10 pixels/row packs into 2 bytes per row.
        let image = try XCTUnwrap(
            FrameImage.make(
                pixels: Data([0b10101010, 0b11000000, 0b01010101, 0b01000000]),
                width: 10, height: 2, bytesPerRow: 2, format: .mono1))
        XCTAssertEqual(image.width, 10)
        XCTAssertEqual(image.bitsPerPixel, 1)
    }

    func testPartialRowsUsePrefix() throws {
        // 4 rows of data offered, only 3 requested (a partial page).
        let image = try XCTUnwrap(
            FrameImage.make(
                pixels: Data(repeating: 9, count: 4 * 5), width: 5, height: 3,
                bytesPerRow: 5, format: .gray8))
        XCTAssertEqual(image.height, 3)
    }

    func testTruncatedDataFails() {
        XCTAssertNil(
            FrameImage.make(
                pixels: Data([1, 2, 3]), width: 2, height: 2, bytesPerRow: 2,
                format: .gray8))
    }
}
