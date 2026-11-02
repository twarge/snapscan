import Accelerate
import CoreGraphics
import Foundation
import Observation

/// What a document's PDF will weigh at each compression level, worked out
/// the way PDFBuilder writes it: a compressed page *is* its JPEG stream, so
/// those are encoded for real and come out exact; a lossless page is
/// estimated by having PDF compress a sample of it. The rest — page
/// structure, the invisible text — is small and was measured against
/// PDFBuilder's own output.
nonisolated enum PDFSize {
    /// The file's own structure, whatever it holds.
    static let bytesPerDocument = 3_400
    /// Each page's structure beyond its image stream.
    static let bytesPerPage = 620
    /// Each line of the searchable text layer, at every level alike.
    static let bytesPerTextLine = 210

    /// The image's bytes in the PDF at every level.
    static func imageBytes(of image: CGImage) -> [PDFCompression: Int] {
        let lossless = losslessBytes(of: image)
        var bytes: [PDFCompression: Int] = [:]
        for level in PDFCompression.allCases {
            // As PDFBuilder: a page with no JPEG form — lineart, or one the
            // encoder refuses — goes in losslessly at every level.
            bytes[level] = level.jpegQuality
                .flatMap { PDFBuilder.jpegData(image, quality: $0)?.count } ?? lossless
        }
        return bytes
    }

    /// The whole file, from its pages' image bytes and text line counts.
    static func documentBytes(imageBytes: [Int], textLines: [Int]) -> Int {
        bytesPerDocument + imageBytes.reduce(0, +) + bytesPerPage * imageBytes.count
            + bytesPerTextLine * textLines.reduce(0, +)
    }

    /// What the image weighs stored losslessly. PDF's own compression is
    /// left to do it — plain zlib missed it by a third for black and white.
    /// A page of colour or gray is sampled: Flate only looks back 32 KB, so
    /// a quarter of the rows, taken in bands down the page, compresses like
    /// the whole and costs a quarter as much. Black and white, a megabyte at
    /// most, goes whole — it leans on each row repeating the one above, and
    /// the bands' edges cost it nearly a tenth.
    static func losslessBytes(of image: CGImage) -> Int {
        guard let stored = storedRows(of: image) else { return 0 }
        let band = 32
        let stride = 4 * band
        var sample = Data()
        var sampled = 0
        if stored.bitsPerPixel > 1, stored.count > 2 * stride {
            // Each band centred in its stretch of the page: bands starting at
            // the top edge sampled the blank margin twice over, and read
            // short pages up to 3% light.
            for start in Swift.stride(from: (stride - band) / 2, to: stored.count, by: stride) {
                let end = min(start + band, stored.count)
                sample.append(stored.bytes[(start * stored.rowBytes)..<(end * stored.rowBytes)])
                sampled += end - start
            }
        } else {
            sample = stored.bytes
            sampled = stored.count
        }
        guard
            let provider = CGDataProvider(data: sample as CFData),
            let piece = CGImage(
                width: image.width, height: sampled, bitsPerComponent: stored.bitsPerComponent,
                bitsPerPixel: stored.bitsPerPixel, bytesPerRow: stored.rowBytes,
                space: stored.space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { return 0 }
        let pieceBytes = max(0, pdfBytes(of: piece) - bytesPerDocument - bytesPerPage)
        return Int((Double(pieceBytes) * Double(stored.count) / Double(sampled)).rounded())
    }

    /// A one-page PDF holding just the image, written to memory.
    private static func pdfBytes(of image: CGImage) -> Int {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return 0 }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return data.length
    }

    /// The image's rows in the layout the PDF stores, tightly packed.
    private typealias StoredRows = (
        bytes: Data, rowBytes: Int, count: Int, bitsPerComponent: Int, bitsPerPixel: Int,
        space: CGColorSpace
    )

    private static func storedRows(of image: CGImage) -> StoredRows? {
        let width = image.width
        let height = image.height
        if image.bitsPerPixel == 1 {
            let rowBytes = (width + 7) / 8
            guard let data = image.dataProvider?.data as Data?,
                image.bytesPerRow >= rowBytes, data.count >= image.bytesPerRow * height
            else { return nil }
            let gray = CGColorSpaceCreateDeviceGray()
            guard image.bytesPerRow != rowBytes else { return (data, rowBytes, height, 1, 1, gray) }
            var packed = Data(capacity: rowBytes * height)
            for row in 0..<height {
                let start = row * image.bytesPerRow
                packed.append(data[start..<(start + rowBytes)])
            }
            return (packed, rowBytes, height, 1, 1, gray)
        }

        if image.colorSpace?.model == .monochrome {
            var gray = Data(count: width * height)
            let drawn = gray.withUnsafeMutableBytes { raw -> Bool in
                guard
                    let context = CGContext(
                        data: raw.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width,
                        space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return drawn ? (gray, width, height, 8, 8, CGColorSpaceCreateDeviceGray()) : nil
        }

        var rgbx = [UInt8](repeating: 0, count: width * height * 4)
        var rgb = Data(count: width * height * 3)
        let converted = rgbx.withUnsafeMutableBytes { rgbxRaw -> Bool in
            guard
                let context = CGContext(
                    data: rgbxRaw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return rgb.withUnsafeMutableBytes { rgbRaw -> Bool in
                var source = vImage_Buffer(
                    data: rgbxRaw.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * 4)
                var destination = vImage_Buffer(
                    data: rgbRaw.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * 3)
                return vImageConvert_RGBA8888toRGB888(
                    &source, &destination, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
        }
        return converted ? (rgb, width * 3, height, 8, 24, CGColorSpaceCreateDeviceRGB()) : nil
    }
}

/// Sizes a document's pages in the background, one at a time, and keeps
/// what each costs so switching levels shows the new size at once.
///
/// A page is sized once its processing is done — before that its image is
/// about to change — and again whenever its image changes (a turn, say).
@MainActor
@Observable
final class PDFSizeEstimator {
    struct Estimate: Equatable {
        let bytes: Int
        /// Pages not yet sized; their share is the average of the rest.
        let pagesPending: Int
    }

    private struct Entry {
        let image: CGImage
        let bytes: [PDFCompression: Int]
    }

    private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var queue: [(id: UUID, image: CGImage)] = []
    @ObservationIgnored private var inFlight: (id: UUID, image: CGImage)?
    @ObservationIgnored private var worker: Task<Void, Never>?

    /// Follows the pages now in the document: forgets pages that left it,
    /// and sizes the ones whose image it hasn't seen.
    func track(_ pages: [ScannedPage]) {
        let current = Dictionary(pages.map { ($0.id, $0.image) }, uniquingKeysWith: { first, _ in first })
        entries = entries.filter { id, entry in current[id] === entry.image }
        queue = pages.filter { page in
            !page.isProcessing && entries[page.id] == nil
                && !(inFlight?.id == page.id && inFlight?.image === page.image)
        }.map { ($0.id, $0.image) }
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            inFlight = next
            let image = next.image
            let bytes = await Task.detached(priority: .utility) {
                PDFSize.imageBytes(of: image)
            }.value
            inFlight = nil
            entries[next.id] = Entry(image: image, bytes: bytes)
        }
        worker = nil
    }

    /// The document's size at `level`, or nil while no page has been sized.
    func estimate(for pages: [ScannedPage], at level: PDFCompression) -> Estimate? {
        var known: [Int] = []
        for page in pages {
            if let entry = entries[page.id], entry.image === page.image,
                let bytes = entry.bytes[level] {
                known.append(bytes)
            }
        }
        guard !known.isEmpty else { return nil }
        let pending = pages.count - known.count
        let average = known.reduce(0, +) / known.count
        return Estimate(
            bytes: PDFSize.documentBytes(
                imageBytes: known + Array(repeating: average, count: pending),
                textLines: pages.map(\.textLines.count)),
            pagesPending: pending)
    }
}
