import CoreGraphics
import Vision

/// Determines how a scanned page should be rotated so its text reads upright.
///
/// Two-step strategy, validated empirically against Vision's behavior:
///
/// 1. **Axis** — fast-level recognition scores at `.up` vs `.right`. Fast OCR
///    reads 180°-flipped text as confidently as upright text (as gibberish),
///    so this only distinguishes horizontal from vertical text, which is all
///    it's used for.
/// 2. **Polarity** — one accurate-level pass at the axis orientation. Accurate
///    recognition silently reads flipped text correctly, but its observations
///    stay in the *given* coordinate space, so on an upside-down page the
///    first line in reading order sits near the bottom. If reading order does
///    not descend the page, the page is flipped and 180° is added.
///
/// Pages without enough text (photos, blanks) are left untouched.
enum OrientationDetector {
    static func rotationToUpright(for image: CGImage) -> Int {
        guard let sample = downsampled(image, maxDimension: 1200) else { return 0 }

        let horizontal = fastTextScore(sample, orientation: .up)
        let vertical = fastTextScore(sample, orientation: .right)
        // Below this there is no meaningful text on the page (sideways reads
        // of real text score ~5; real text scores far higher).
        guard max(horizontal, vertical) > 8 else { return 0 }

        if horizontal >= vertical {
            return readingOrderDescends(sample, orientation: .up) ? 0 : 180
        } else {
            return readingOrderDescends(sample, orientation: .right) ? 90 : 270
        }
    }

    private static func fastTextScore(
        _ image: CGImage, orientation: CGImagePropertyOrientation
    ) -> Double {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try? handler.perform([request])
        return (request.results ?? []).reduce(0.0) { sum, observation in
            guard let top = observation.topCandidates(1).first else { return sum }
            return sum + Double(top.confidence) * Double(top.string.count)
        }
    }

    /// True when accurate-level reading order flows top to bottom, i.e. the
    /// page's polarity matches the given orientation. Defaults to true when
    /// there are too few lines to judge.
    private static func readingOrderDescends(
        _ image: CGImage, orientation: CGImagePropertyOrientation
    ) -> Bool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try? handler.perform([request])
        let ys = (request.results ?? []).map { $0.boundingBox.midY }
        guard ys.count >= 2 else { return true }

        // Sign of the regression slope of line position over reading index.
        let n = Double(ys.count)
        let sumX = Double(ys.count * (ys.count - 1)) / 2
        let sumY = ys.reduce(0, +)
        let sumXY = ys.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
        let sumXX = Double((ys.count - 1) * ys.count * (2 * ys.count - 1)) / 6
        let slope = (n * sumXY - sumX * sumY) / (n * sumXX - sumX * sumX)
        return slope <= 0.005
    }

    /// Estimates the page's small-angle skew from the tilt of recognized text
    /// lines. Returns the correction in degrees clockwise, or nil when the
    /// evidence is too weak to act on — sparse pages (few lines, or lines
    /// that disagree about the angle) are deliberately left untouched, since
    /// guessing there does more harm than good.
    static func skewCorrectionDegrees(for image: CGImage) -> Double? {
        guard let sample = downsampled(image, maxDimension: 1600) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: sample, orientation: .up)
        try? handler.perform([request])

        let width = Double(sample.width)
        let height = Double(sample.height)
        // Only reasonably wide lines carry a trustworthy angle.
        let angles = (request.results ?? [])
            .filter { $0.boundingBox.width > 0.15 }
            .map { observation -> Double in
                // Corner points are normalized; convert to pixels so the
                // angle isn't distorted by the page's aspect ratio.
                let dx = (observation.topRight.x - observation.topLeft.x) * width
                let dy = (observation.topRight.y - observation.topLeft.y) * height
                return atan2(dy, dx) * 180 / .pi
            }
        guard angles.count >= 4 else { return nil }

        let sorted = angles.sorted()
        let median = sorted[sorted.count / 2]
        let deviation = angles.map { abs($0 - median) }.sorted()[angles.count / 2]
        // Act only on a clear, consistent, small tilt.
        guard abs(median) >= 0.25, abs(median) <= 6, deviation <= 1.0 else { return nil }
        // Vision's Y axis points up: a positive line angle means the text
        // rises to the right, i.e. the page is tilted counterclockwise, so
        // the correction is that many degrees clockwise... verified by the
        // round-trip unit test rather than trusted from this comment.
        return median
    }

    private static func downsampled(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let largest = max(image.width, image.height)
        guard largest > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(largest)
        let width = Int(Double(image.width) * scale)
        let height = Int(Double(image.height) * scale)
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

extension CGImage {
    /// Returns the image rotated by a small angle (for deskewing), keeping
    /// the canvas size and filling revealed corners with white.
    func rotatedBySmallAngle(degreesClockwise degrees: Double) -> CGImage? {
        let isGray = colorSpace?.model == .monochrome
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: isGray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: isGray
                    ? CGImageAlphaInfo.none.rawValue
                    : CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(
            isGray
                ? CGColor(gray: 1, alpha: 1)
                : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        // Context rotation is counterclockwise-positive; negate for clockwise.
        context.rotate(by: -CGFloat(degrees) * .pi / 180)
        context.draw(
            self,
            in: CGRect(
                x: -CGFloat(width) / 2, y: -CGFloat(height) / 2,
                width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }

    /// Returns the image rotated clockwise by 0/90/180/270 degrees.
    ///
    /// Implemented as an exact per-pixel permutation: rasterizing a rotation
    /// through CGContext samples texels on exact boundaries and corrupts
    /// edges, so the pixels are moved directly instead.
    func rotated(byDegreesClockwise degrees: Int) -> CGImage? {
        let normalized = ((degrees % 360) + 360) % 360
        guard normalized != 0 else { return self }

        let isGray = colorSpace?.model == .monochrome
        let channels = isGray ? 1 : 4
        let w = width
        let h = height

        // Render into a known 8-bit layout (gray or RGBA) without transforms.
        var source = [UInt8](repeating: 0, count: w * h * channels)
        let rendered = source.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * channels,
                    space: isGray
                        ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: isGray
                        ? CGImageAlphaInfo.none.rawValue
                        : CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered else { return nil }

        let newW = normalized % 180 == 0 ? w : h
        let newH = normalized % 180 == 0 ? h : w
        var destination = [UInt8](repeating: 0, count: source.count)

        source.withUnsafeBufferPointer { src in
            destination.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    for x in 0..<w {
                        let dx: Int
                        let dy: Int
                        switch normalized {
                        case 90: (dx, dy) = (h - 1 - y, x)
                        case 180: (dx, dy) = (w - 1 - x, h - 1 - y)
                        default: (dx, dy) = (y, w - 1 - x)  // 270
                        }
                        let from = (y * w + x) * channels
                        let to = (dy * newW + dx) * channels
                        for c in 0..<channels {
                            dst[to + c] = src[from + c]
                        }
                    }
                }
            }
        }

        guard
            let provider = CGDataProvider(
                data: Data(destination) as CFData)
        else { return nil }
        return CGImage(
            width: newW, height: newH,
            bitsPerComponent: 8, bitsPerPixel: 8 * channels,
            bytesPerRow: newW * channels,
            space: isGray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: isGray
                    ? CGImageAlphaInfo.none.rawValue
                    : CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent)
    }
}
