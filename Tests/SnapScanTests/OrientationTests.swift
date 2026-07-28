import AppKit
import Testing

@testable import SnapScan

@Suite struct OrientationTests {
    // MARK: Rotation primitive

    /// 2x1 image, black pixel left, white pixel right.
    private func makeTwoPixelImage() -> CGImage {
        let data = Data([0, 255])
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 2,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
    }

    private func grayPixels(of image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.interpolationQuality = .none
            context.draw(
                image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return buffer
    }

    @Test func rotate90ClockwiseMovesLeftPixelToTop() throws {
        // [black | white] rotated 90° CW should become [black] on top of [white]
        // (the left edge becomes the top edge).
        let rotated = try #require(makeTwoPixelImage().rotated(byDegreesClockwise: 90))
        #expect(rotated.width == 1)
        #expect(rotated.height == 2)
        let pixels = grayPixels(of: rotated)
        #expect(pixels[0] < 64, "top pixel should be black")
        #expect(pixels[1] > 192, "bottom pixel should be white")
    }

    @Test func rotate180Reverses() throws {
        let rotated = try #require(makeTwoPixelImage().rotated(byDegreesClockwise: 180))
        let pixels = grayPixels(of: rotated)
        #expect(pixels[0] > 192, "left pixel should now be white")
        #expect(pixels[1] < 64, "right pixel should now be black")
    }

    @Test func rotateZeroReturnsSameImage() {
        let image = makeTwoPixelImage()
        #expect(image.rotated(byDegreesClockwise: 0) === image)
        #expect(image.rotated(byDegreesClockwise: 360) === image)
    }

    // MARK: Orientation detection on rendered text

    /// Renders a paragraph of text into an upright grayscale page image.
    private func renderTextPage() -> CGImage {
        let width = 600
        let height = 800
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let paragraph =
            """
            The quick brown fox jumps over the lazy dog.
            Pack my box with five dozen liquor jugs.
            How vexingly quick daft zebras jump!
            Sphinx of black quartz, judge my vow.
            The five boxing wizards jump quickly.
            Jackdaws love my big sphinx of quartz.
            """
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22),
            .foregroundColor: NSColor.black,
        ]
        NSAttributedString(string: paragraph, attributes: attributes)
            .draw(in: NSRect(x: 40, y: 100, width: 520, height: 600))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    @Test func uprightTextNeedsNoRotation() async {
        let rotation = await OrientationDetector.rotationToUpright(for: renderTextPage())
        #expect(rotation == 0)
    }

    @Test(arguments: [90, 180, 270])
    func detectsRotation(applied: Int) async throws {
        let rotated = try #require(renderTextPage().rotated(byDegreesClockwise: applied))
        let correction = await OrientationDetector.rotationToUpright(for: rotated)
        #expect(
            (applied + correction) % 360 == 0,
            "page rotated \(applied)° should need \(360 - applied)° correction, got \(correction)"
        )
    }

    @Test func blankPageIsLeftAlone() async {
        let width = 400
        let height = 400
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let blank = context.makeImage()!
        let rotation = await OrientationDetector.rotationToUpright(for: blank)
        #expect(rotation == 0)
    }

    // MARK: Deskew

    @Test func skewEstimateAndCorrectionRoundTrip() async throws {
        let upright = renderTextPage()
        let skewed = try #require(upright.rotatedBySmallAngle(degreesClockwise: 2.0))
        let correction = try #require(
            await OrientationDetector.skewCorrectionDegrees(for: skewed),
            "a clearly skewed text page should produce an estimate")
        #expect(abs(abs(correction) - 2.0) < 0.7)

        let fixed = try #require(skewed.rotatedBySmallAngle(degreesClockwise: correction))
        let residual = await OrientationDetector.skewCorrectionDegrees(for: fixed)
        #expect(
            residual == nil || abs(residual!) < 0.5,
            "applying the correction should leave the page straight, got \(String(describing: residual))"
        )
    }

    @Test func straightPageNotDeskewed() async {
        let estimate = await OrientationDetector.skewCorrectionDegrees(for: renderTextPage())
        #expect(estimate == nil)
    }

    @Test func sparsePageNotDeskewed() async throws {
        // A mostly blank page with one short line: too little evidence to act.
        let width = 600
        let height = 800
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(
            string: "Total: $412.86",
            attributes: [
                .font: NSFont.systemFont(ofSize: 20),
                .foregroundColor: NSColor.black,
            ]
        ).draw(at: NSPoint(x: 60, y: 700))
        NSGraphicsContext.restoreGraphicsState()
        let sparse = context.makeImage()!
        let skewedSparse = try #require(sparse.rotatedBySmallAngle(degreesClockwise: 2.5))
        let estimate = await OrientationDetector.skewCorrectionDegrees(for: skewedSparse)
        #expect(estimate == nil, "sparse pages must be left alone even when actually skewed")
    }
}
