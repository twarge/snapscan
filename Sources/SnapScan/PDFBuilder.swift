import CoreGraphics
import Foundation

nonisolated enum PDFBuilder {
    enum BuildError: Error, LocalizedError {
        case contextCreationFailed

        var errorDescription: String? { "Could not create the PDF file" }
    }

    /// Writes pages to a PDF, each page sized to its physical dimensions.
    static func write(pages: [ScannedPage], to url: URL) throws {
        var firstMediaBox = CGRect(origin: .zero, size: pages.first?.sizeInPoints ?? CGSize(width: 612, height: 792))
        let metadata: [CFString: Any] = [
            kCGPDFContextCreator: "SnapScan",
            kCGPDFContextTitle: url.deletingPathExtension().lastPathComponent,
        ]
        guard
            let context = CGContext(url as CFURL, mediaBox: &firstMediaBox, metadata as CFDictionary)
        else {
            throw BuildError.contextCreationFailed
        }
        for page in pages {
            var mediaBox = CGRect(origin: .zero, size: page.sizeInPoints)
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
            ]
            context.beginPDFPage(pageInfo as CFDictionary)
            context.interpolationQuality = .high
            // A size-snapped page centers the image at true scale; detection
            // noise disappears into the margins instead of stretching pixels.
            let imageSize = page.naturalSizeInPoints
            let drawRect = CGRect(
                x: (mediaBox.width - imageSize.width) / 2,
                y: (mediaBox.height - imageSize.height) / 2,
                width: imageSize.width,
                height: imageSize.height)
            context.draw(page.image, in: drawRect)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
