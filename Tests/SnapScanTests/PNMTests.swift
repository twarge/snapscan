import XCTest

@testable import SnapScan

final class PNMTests: XCTestCase {
    func testDecodeP6Color() throws {
        // 2x2 RGB: red, green / blue, white
        var data = Data("P6\n# SANE data follows\n2 2\n255\n".utf8)
        data.append(contentsOf: [
            255, 0, 0, 0, 255, 0,
            0, 0, 255, 255, 255, 255,
        ])
        let image = try PNM.decode(data)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.bitsPerPixel, 24)
    }

    func testDecodeP5Gray() throws {
        var data = Data("P5\n3 2\n255\n".utf8)
        data.append(contentsOf: [0, 128, 255, 10, 20, 30])
        let image = try PNM.decode(data)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.bitsPerPixel, 8)
    }

    func testDecodeP4Lineart() throws {
        // 10x2 1-bit: rows are 2 bytes each (padded to byte boundary)
        var data = Data("P4\n10 2\n".utf8)
        data.append(contentsOf: [0b10101010, 0b11000000, 0b01010101, 0b01000000])
        let image = try PNM.decode(data)
        XCTAssertEqual(image.width, 10)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.bitsPerPixel, 1)
    }

    func testCommentInHeader() throws {
        var data = Data("P5\n# a comment\n# another 123\n2 1\n255\n".utf8)
        data.append(contentsOf: [7, 9])
        let image = try PNM.decode(data)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
    }

    func testTruncatedPixelDataThrows() {
        var data = Data("P6\n2 2\n255\n".utf8)
        data.append(contentsOf: [255, 0, 0])
        XCTAssertThrowsError(try PNM.decode(data))
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try PNM.decode(Data("not an image".utf8)))
        XCTAssertThrowsError(try PNM.decode(Data("P3\n1 1\n255\n1 2 3\n".utf8)))
    }
}
