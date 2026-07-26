import CoreGraphics
import Foundation

enum PDFBuilder {
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
            context.draw(page.image, in: mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
