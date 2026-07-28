import Foundation
import PDFKit
import Testing

@testable import SnapScan

@Suite struct PDFBuilderTests {
    private func makePage(width: Int, height: Int, dpi: Int) throws -> ScannedPage {
        let pixels = Data(repeating: 200, count: width * height)
        let image = try #require(
            FrameImage.make(
                pixels: pixels, width: width, height: height,
                bytesPerRow: width, format: .gray8))
        return ScannedPage(image: image, dpi: dpi)
    }

    @Test func writesMultiPagePDFWithPhysicalSize() throws {
        let pages = [
            try makePage(width: 300, height: 600, dpi: 300),
            try makePage(width: 150, height: 150, dpi: 150),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapscan-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try PDFBuilder.write(pages: pages, to: url)

        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 2)
        // 300 px at 300 dpi = 1 inch = 72 points.
        let first = try #require(document.page(at: 0))
        #expect(abs(first.bounds(for: .mediaBox).width - 72) < 0.5)
        #expect(abs(first.bounds(for: .mediaBox).height - 144) < 0.5)
        // 150 px at 150 dpi = 1 inch.
        let second = try #require(document.page(at: 1))
        #expect(abs(second.bounds(for: .mediaBox).width - 72) < 0.5)
    }

    @Test func snappedPageUsesStandardSizeWithCenteredImage() throws {
        var page = try makePage(width: 2500, height: 3250, dpi: 300)
        page.snappedSizeMM = CGSize(width: 215.9, height: 279.4)
        page.snappedSizeName = "Letter"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapscan-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try PDFBuilder.write(pages: [page], to: url)

        let document = try #require(PDFDocument(url: url))
        let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        // Letter is 612 × 792 points regardless of the measured image size.
        #expect(abs(bounds.width - 612) < 0.5)
        #expect(abs(bounds.height - 792) < 0.5)
    }
}
