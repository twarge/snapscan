import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum PDFBuilder {
    enum BuildError: Error, LocalizedError {
        case contextCreationFailed

        var errorDescription: String? { "Could not create the PDF file" }
    }

    /// Writes pages to a PDF, each page sized to its physical dimensions.
    static func write(
        pages: [ScannedPage], to url: URL, compression: PDFCompression = .medium
    ) throws {
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
            let image =
                compression.jpegQuality
                .flatMap { jpegBacked(page.image, quality: $0) } ?? page.image
            context.draw(image, in: drawRect)
            TextLayer.draw(page.textLines, in: drawRect, into: context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Re-encodes a page as JPEG and hands back an image backed by that data.
    ///
    /// Drawing it stores the JPEG stream in the PDF as-is (a `/DCTDecode`
    /// image) rather than recompressing the pixels — which is the whole point:
    /// a 300 dpi colour page costs about 12.6 MB stored losslessly and about
    /// 1.1 MB at medium quality. Returns nil if encoding fails, and the
    /// uncompressed image is used instead.
    private static func jpegBacked(_ image: CGImage, quality: Double) -> CGImage? {
        // Lineart is 1 bit per pixel: JPEG would *grow* it and smear exactly
        // the hard edges it exists to keep crisp. Flate handles it far better.
        guard image.bitsPerPixel > 1 else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
