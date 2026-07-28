import CoreGraphics
import Foundation

/// Content-bounds detection and standard-size snapping for auto paper size.
///
/// Auto scans acquire at full width with the scanner's black background;
/// the paper then stands out as a bright region against near-black margins.
/// The measured size snaps to a standard paper size when it's clearly one,
/// and stays exact otherwise (receipts, labels, photos).
nonisolated enum PageGeometry {
    struct StandardSize {
        let name: String
        let widthMM: Double
        let heightMM: Double
    }

    /// Candidates for snapping, in portrait orientation.
    static let standardSizes: [StandardSize] = [
        StandardSize(name: "Letter", widthMM: 215.9, heightMM: 279.4),
        StandardSize(name: "A4", widthMM: 210.0, heightMM: 297.0),
        StandardSize(name: "Legal", widthMM: 215.9, heightMM: 355.6),
        StandardSize(name: "A5", widthMM: 148.0, heightMM: 210.0),
        StandardSize(name: "Half Letter", widthMM: 139.7, heightMM: 215.9),
        StandardSize(name: "5×7", widthMM: 127.0, heightMM: 177.8),
        StandardSize(name: "4×6", widthMM: 101.6, heightMM: 152.4),
        StandardSize(name: "3×5", widthMM: 76.2, heightMM: 127.0),
        StandardSize(name: "Business Card", widthMM: 50.8, heightMM: 88.9),
    ]

    /// A measured dimension may deviate this much per axis and still snap.
    static let snapToleranceMM = 5.0

    /// Snaps a measured page size to a standard size, orientation-agnostic;
    /// the result keeps the measured orientation. Returns nil when the size
    /// isn't close to any standard — the page should keep its exact size.
    static func snappedSize(widthMM: Double, heightMM: Double)
        -> (name: String, widthMM: Double, heightMM: Double)?
    {
        let measuredShort = min(widthMM, heightMM)
        let measuredLong = max(widthMM, heightMM)

        var best: (size: StandardSize, distance: Double)? = nil
        for candidate in standardSizes {
            let dShort = abs(measuredShort - candidate.widthMM)
            let dLong = abs(measuredLong - candidate.heightMM)
            guard dShort <= snapToleranceMM, dLong <= snapToleranceMM else { continue }
            let distance = (dShort * dShort + dLong * dLong).squareRoot()
            if best == nil || distance < best!.distance {
                best = (candidate, distance)
            }
        }
        guard let best else { return nil }
        // Restore the measured orientation.
        if widthMM <= heightMM {
            return (best.size.name, best.size.widthMM, best.size.heightMM)
        } else {
            return (best.size.name, best.size.heightMM, best.size.widthMM)
        }
    }

    /// Finds the bright (paper) region against the scanner's black background.
    /// Returns a crop rect in full-resolution pixels, or nil when no black
    /// margins are present (background wasn't black, or paper fills the frame)
    /// — in that case the frame should be kept as scanned.
    static func contentBounds(of image: CGImage) -> CGRect? {
        let maxDimension = 800
        let scale = Double(maxDimension) / Double(max(image.width, image.height))
        let sampleWidth = max(1, Int(Double(image.width) * min(1, scale)))
        let sampleHeight = max(1, Int(Double(image.height) * min(1, scale)))

        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: sampleWidth, height: sampleHeight,
                    bitsPerComponent: 8, bytesPerRow: sampleWidth,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard rendered else { return nil }

        // A row/column counts as "paper" when enough of it is brighter than
        // the black background.
        let brightThreshold: UInt8 = 96
        let paperFraction = 0.02

        func columnIsPaper(_ x: Int) -> Bool {
            var bright = 0
            for y in 0..<sampleHeight where pixels[y * sampleWidth + x] > brightThreshold {
                bright += 1
            }
            return Double(bright) / Double(sampleHeight) > paperFraction
        }
        func rowIsPaper(_ y: Int) -> Bool {
            var bright = 0
            for x in 0..<sampleWidth where pixels[y * sampleWidth + x] > brightThreshold {
                bright += 1
            }
            return Double(bright) / Double(sampleWidth) > paperFraction
        }

        guard let left = (0..<sampleWidth).first(where: columnIsPaper),
            let right = (0..<sampleWidth).reversed().first(where: columnIsPaper),
            let top = (0..<sampleHeight).first(where: rowIsPaper),
            let bottom = (0..<sampleHeight).reversed().first(where: rowIsPaper),
            left < right, top < bottom
        else { return nil }

        // No meaningful margins found: nothing to crop (and possibly no
        // black background at all).
        let marginX = left + (sampleWidth - 1 - right)
        let marginY = top + (sampleHeight - 1 - bottom)
        if marginX < 2 && marginY < 2 { return nil }

        // Scale back to full resolution, shaving a hair off each edge so no
        // black fringe survives the crop.
        let inverse = Double(image.width) / Double(sampleWidth)
        let fringe = 2.0 * inverse
        let rect = CGRect(
            x: (Double(left) * inverse + fringe).rounded(),
            y: (Double(top) * inverse + fringe).rounded(),
            width: (Double(right - left + 1) * inverse - 2 * fringe).rounded(),
            height: (Double(bottom - top + 1) * inverse - 2 * fringe).rounded())
        guard rect.width > 16, rect.height > 16 else { return nil }
        return rect.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}
