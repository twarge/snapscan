import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import SnapScan

/// A page of grainy text, like a scan: lines of type on off-white with a
/// little noise in every pixel, which is what makes compression work.
nonisolated private func textPage(width: Int = 900, height: Int = 1200, seed: UInt32 = 1) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let attributes: [NSAttributedString.Key: Any] = [
        .font: CTFontCreateWithName("Times" as CFString, 18, nil),
        .foregroundColor: CGColor(gray: 0.1, alpha: 1),
    ]
    for line in 0..<50 {
        let text = NSAttributedString(
            string: "Line \(line) of a statement, amount due $\(line * 37).50, ref \(seed)",
            attributes: attributes)
        context.textPosition = CGPoint(x: 60, y: height - 80 - line * 22)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    var state = seed
    for offset in stride(from: 0, to: width * height * 4, by: 4) {
        state = state &* 1_664_525 &+ 1_013_904_223
        let grain = Int(state >> 29) - 3
        for channel in 0..<3 {
            pixels[offset + channel] = UInt8(clamping: Int(pixels[offset + channel]) + grain)
        }
    }
    return context.makeImage()!
}

nonisolated private func writtenSize(_ pages: [ScannedPage], _ level: PDFCompression) throws -> Int {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("size-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try PDFBuilder.write(pages: pages, to: url, compression: level)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.intValue ?? 0
}

struct PDFSizeTests {
    @Test func theFileIsItsPagesPlusStructureAndText() {
        let bytes = PDFSize.documentBytes(imageBytes: [1_000, 2_000], textLines: [3, 0])
        #expect(
            bytes == PDFSize.bytesPerDocument + 3_000 + 2 * PDFSize.bytesPerPage
                + 3 * PDFSize.bytesPerTextLine)
    }

    @Test func moreCompressionMakesASmallerPage() throws {
        let bytes = PDFSize.imageBytes(of: textPage())
        let sizes = PDFCompression.allCases.map { bytes[$0] ?? 0 }
        #expect(sizes.allSatisfy { $0 > 0 })
        #expect(sizes == sizes.sorted(by: >))
    }

    @Test func blackAndWhiteWeighsTheSameAtEveryLevel() throws {
        let lineart = try #require(PageTone.render(textPage(), as: .lineart, dpi: 300))
        let bytes = PDFSize.imageBytes(of: lineart)
        #expect(Set(PDFCompression.allCases.compactMap { bytes[$0] }).count == 1)
    }

    /// Against what PDFBuilder really writes, text layer included.
    @Test(arguments: PDFCompression.allCases)
    func theEstimateMatchesTheWrittenFile(level: PDFCompression) throws {
        var pages = (1...3).map { ScannedPage(image: textPage(seed: UInt32($0)), dpi: 300) }
        pages[1].textLines = (0..<40).map {
            TextLayer.Line(
                text: "Line \($0) of a statement, amount due",
                box: CGRect(x: 0.07, y: 0.9 - Double($0) * 0.02, width: 0.6, height: 0.015))
        }
        let estimate = PDFSize.documentBytes(
            imageBytes: pages.map { PDFSize.imageBytes(of: $0.image)[level] ?? 0 },
            textLines: pages.map(\.textLines.count))
        let actual = try writtenSize(pages, level)
        #expect(abs(Double(estimate - actual)) / Double(actual) < 0.02)
    }

    @Test @MainActor func pagesAreSizedInTheBackgroundOnceProcessed() async throws {
        let estimator = PDFSizeEstimator()
        var pages = [
            ScannedPage(image: textPage(seed: 1), dpi: 300),
            ScannedPage(image: textPage(seed: 2), dpi: 300),
        ]
        pages[1].isProcessing = true
        estimator.track(pages)
        var estimate: PDFSizeEstimator.Estimate?
        for _ in 0..<200 where estimate == nil {
            try await Task.sleep(for: .milliseconds(25))
            estimate = estimator.estimate(for: pages, at: .medium)
        }
        // The page still processing is left until it's done, and counted
        // meanwhile at the average of those sized.
        let partial = try #require(estimate)
        #expect(partial.pagesPending == 1)

        pages[1].isProcessing = false
        estimator.track(pages)
        var complete = partial
        for _ in 0..<200 where complete.pagesPending > 0 {
            try await Task.sleep(for: .milliseconds(25))
            complete = try #require(estimator.estimate(for: pages, at: .medium))
        }
        #expect(complete.pagesPending == 0)

        // A turned page has a new image: sized again, not taken from before.
        pages[0] = try #require(pages[0].rotated(clockwise: true))
        #expect(estimator.estimate(for: pages, at: .medium)?.pagesPending == 1)
    }
}
