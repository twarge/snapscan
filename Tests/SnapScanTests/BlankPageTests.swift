import AppKit
import CoreImage
import Testing

@testable import SnapScan

/// Synthetic pages at 150 dpi: paper with sensor noise, plus whatever each
/// case needs to put on (or show through) it.
@Suite struct BlankPageTests {
    private static let width = 1275
    private static let height = 1650
    private static let dpi = 150

    /// Deterministic noise, so a failure reproduces.
    private struct Noise {
        var state: UInt64 = 42
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) - 0.5
        }
    }

    private func paper(level: Double = 238, noise amount: Double = 10) -> CGContext {
        let context = CGContext(
            data: nil, width: Self.width, height: Self.height, bitsPerComponent: 8,
            bytesPerRow: Self.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var noise = Noise()
        for i in 0..<(Self.width * Self.height) {
            let value = UInt8(max(0, min(255, level + amount * noise.next())))
            pixels[4 * i] = value
            pixels[4 * i + 1] = value
            pixels[4 * i + 2] = value
        }
        return context
    }

    private func draw(
        _ text: String, on context: CGContext, at point: CGPoint, points: CGFloat,
        color: NSColor = .black, mirrored: Bool = false
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.saveGState()
        if mirrored {
            context.translateBy(x: CGFloat(Self.width), y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        let font = NSFont(name: "Helvetica", size: points * CGFloat(Self.dpi) / 72)!
        NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color]
        ).draw(at: point)
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func isBlank(_ context: CGContext) -> Bool {
        BlankPageDetector.isBlank(context.makeImage()!, dpi: Self.dpi)
    }

    // MARK: Blank, despite what scanning puts on an empty sheet

    @Test func plainPaperIsBlank() {
        #expect(isBlank(paper()))
    }

    @Test func showThroughIsBlank() {
        // The far side's print: mirrored, softened by the paper, faint.
        let page = paper()
        let printed = paper(level: 255, noise: 0)
        for line in 0..<30 {
            draw(
                "Statement of account for the period ending in September", on: printed,
                at: CGPoint(x: 150, y: 1450 - line * 40), points: 11, mirrored: true)
        }
        let blurred = CIImage(cgImage: printed.makeImage()!)
            .clampedToExtent().applyingGaussianBlur(sigma: 1.5)
            .cropped(to: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        let farSide = CIContext().createCGImage(blurred, from: blurred.extent)!
        page.saveGState()
        page.setAlpha(0.15)
        page.setBlendMode(.multiply)
        page.draw(farSide, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        page.restoreGState()
        #expect(isBlank(page))
    }

    @Test func dustIsBlank() {
        let page = paper()
        page.setFillColor(gray: 0.2, alpha: 1)
        var noise = Noise(state: 7)
        for _ in 0..<25 {
            let x = 100 + (noise.next() + 0.5) * Double(Self.width - 200)
            let y = 100 + (noise.next() + 0.5) * Double(Self.height - 200)
            page.fillEllipse(in: CGRect(x: x, y: y, width: 2, height: 2))
        }
        #expect(isBlank(page))
    }

    @Test func edgeShadowsAndStreaksAreBlank() {
        let page = paper()
        // The sheet's shadow along its edges, and a dark fringe of background.
        page.setFillColor(gray: 0.5, alpha: 1)
        page.fill(CGRect(x: 0, y: Self.height - 6, width: Self.width, height: 6))
        page.setFillColor(gray: 0.1, alpha: 1)
        page.fill(CGRect(x: 0, y: 0, width: 4, height: Self.height))
        // A speck on the sensor draws a line down the whole sheet; a fold
        // leaves one across it.
        page.setFillColor(gray: 0.4, alpha: 1)
        page.fill(CGRect(x: 640, y: 0, width: 2, height: Self.height))
        page.setFillColor(gray: 0.7, alpha: 1)
        page.fill(CGRect(x: 0, y: 550, width: Self.width, height: 2))
        #expect(isBlank(page))
    }

    @Test func aDashedSensorStreakIsBlank() {
        // Dust that touches the back sensor now and then: short hairline
        // dashes, one column, down an otherwise empty back. Shaped after a
        // real scan, where it was the only thing on four blank backs.
        let page = paper()
        page.setFillColor(gray: 0.35, alpha: 1)
        for (top, length) in [(160, 15), (640, 36), (990, 18), (1013, 46), (1290, 104)] {
            page.fill(CGRect(x: 1207, y: Self.height - top - length, width: 2, height: length))
        }
        #expect(isBlank(page))
    }

    @Test func aSlantedFoldIsBlank() {
        let page = paper()
        page.setStrokeColor(gray: 0.65, alpha: 1)
        page.setLineWidth(2)
        page.move(to: CGPoint(x: 0, y: 500))
        page.addLine(to: CGPoint(x: Self.width, y: 580))
        page.strokePath()
        #expect(isBlank(page))
    }

    @Test func tintedPaperIsBlank() {
        let context = paper()
        context.setFillColor(red: 0.98, green: 0.84, blue: 0.86, alpha: 1)
        context.setBlendMode(.multiply)
        context.fill(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        #expect(isBlank(context))
    }

    // MARK: Kept, however little is on them

    @Test func aSingleShortWordIsKept() {
        let page = paper()
        draw("Page 2", on: page, at: CGPoint(x: 600, y: 200), points: 10)
        #expect(!isBlank(page))
    }

    @Test func faintPencilIsKept() {
        let page = paper()
        page.setStrokeColor(gray: 0.6, alpha: 1)
        page.setLineWidth(1)
        page.move(to: CGPoint(x: 400, y: 1000))
        for step in 0..<60 {
            page.addLine(
                to: CGPoint(x: 400 + Double(step) * 4, y: 1000 + 12 * sin(Double(step))))
        }
        page.strokePath()
        #expect(!isBlank(page))
    }

    @Test func aLongSignatureIsKept() {
        // As long as a fold, but a pen doubles back on itself where a fold
        // runs straight.
        let page = paper()
        page.setStrokeColor(gray: 0.15, alpha: 1)
        page.setLineWidth(2)
        page.move(to: CGPoint(x: 300, y: 700))
        for step in 0..<110 {
            page.addLine(
                to: CGPoint(x: 300 + Double(step) * 7, y: 700 + 25 * sin(Double(step) * 1.3)))
        }
        page.strokePath()
        #expect(!isBlank(page))
    }

    @Test func highlighterIsKept() {
        // Barely darker than the paper, but it takes most of the blue out.
        let page = paper()
        page.setStrokeColor(red: 1, green: 0.95, blue: 0.35, alpha: 1)
        page.setLineWidth(20)
        page.move(to: CGPoint(x: 300, y: 900))
        page.addLine(to: CGPoint(x: 800, y: 900))
        page.strokePath()
        #expect(!isBlank(page))
    }

    @Test func aSoftPhotographIsKept() {
        let page = paper()
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: [CGColor(gray: 0.2, alpha: 1), CGColor(gray: 0.93, alpha: 1)] as CFArray,
            locations: [0, 1])!
        page.drawRadialGradient(
            gradient, startCenter: CGPoint(x: 640, y: 820), startRadius: 0,
            endCenter: CGPoint(x: 640, y: 820), endRadius: 300, options: [])
        #expect(!isBlank(page))
    }

    @Test func aDarkSheetIsNotCalledBlank() {
        #expect(!isBlank(paper(level: 30)))
    }

    @Test func aPageOfTextIsKept() {
        let page = paper()
        for line in 0..<30 {
            draw(
                "The quick brown fox jumps over the lazy dog.", on: page,
                at: CGPoint(x: 150, y: 1450 - line * 40), points: 11)
        }
        #expect(!isBlank(page))
    }
}
