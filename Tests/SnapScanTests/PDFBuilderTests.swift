import PDFKit
import XCTest

@testable import SnapScan

final class PDFBuilderTests: XCTestCase {
    private func makePage(width: Int, height: Int, dpi: Int) throws -> ScannedPage {
        let pixels = Data(repeating: 200, count: width * height)
        let image = try XCTUnwrap(
            FrameImage.make(
                pixels: pixels, width: width, height: height,
                bytesPerRow: width, format: .gray8))
        return ScannedPage(image: image, dpi: dpi)
    }

    func testWritesMultiPagePDFWithPhysicalSize() throws {
        let pages = [
            try makePage(width: 300, height: 600, dpi: 300),
            try makePage(width: 150, height: 150, dpi: 150),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapscan-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try PDFBuilder.write(pages: pages, to: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 2)
        // 300 px at 300 dpi = 1 inch = 72 points.
        let first = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(first.bounds(for: .mediaBox).width, 72, accuracy: 0.5)
        XCTAssertEqual(first.bounds(for: .mediaBox).height, 144, accuracy: 0.5)
        // 150 px at 150 dpi = 1 inch.
        let second = try XCTUnwrap(document.page(at: 1))
        XCTAssertEqual(second.bounds(for: .mediaBox).width, 72, accuracy: 0.5)
    }
}
