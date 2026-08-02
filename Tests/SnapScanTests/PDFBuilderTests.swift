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

    /// A page of real tones, so compression has something to work on — a flat
    /// fill would compress to nothing at every setting and prove nothing.
    private func makeTexturedPage(width: Int, height: Int) throws -> ScannedPage {
        var pixels = Data(count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let wave = 128 + 100 * sin(Double(x) / 7) * cos(Double(y) / 11)
                pixels[y * width + x] = UInt8(max(0, min(255, wave)))
            }
        }
        let image = try #require(
            FrameImage.make(
                pixels: pixels, width: width, height: height,
                bytesPerRow: width, format: .gray8))
        return ScannedPage(image: image, dpi: 300)
    }

    private func size(of pages: [ScannedPage], _ compression: PDFCompression) throws -> Int {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapscan-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try PDFBuilder.write(pages: pages, to: url, compression: compression)
        // Every level must still produce a readable PDF.
        #expect(PDFDocument(url: url)?.pageCount == pages.count)
        return try #require(try? Data(contentsOf: url).count)
    }

    @Test func compressionLevelsShrinkThePDFInOrder() throws {
        let pages = [try makeTexturedPage(width: 1200, height: 1600)]
        let lossless = try size(of: pages, .none)
        let light = try size(of: pages, .light)
        let medium = try size(of: pages, .medium)
        let maximum = try size(of: pages, .maximum)

        #expect(light < lossless)
        #expect(medium < light)
        #expect(maximum < medium)
        // The point of the feature: the default is far smaller than lossless.
        #expect(medium < lossless / 2)
    }

    /// Lineart is 1 bit a pixel. JPEG would enlarge it and blur the edges, so
    /// it stays lossless no matter what the setting says.
    @Test func lineartIgnoresCompression() throws {
        let width = 1200
        let height = 1600
        var pixels = Data(count: width / 8 * height)
        for i in 0..<pixels.count { pixels[i] = i % 3 == 0 ? 0xF0 : 0x0F }
        let image = try #require(
            FrameImage.make(
                pixels: pixels, width: width, height: height,
                bytesPerRow: width / 8, format: .mono1))
        let pages = [ScannedPage(image: image, dpi: 300)]
        #expect(try size(of: pages, .maximum) == (try size(of: pages, .none)))
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
