import CoreGraphics
import Foundation

/// Sheet detection and standard-size snapping, for auto paper size and for
/// cropping fixed-size scans to the sheet.
///
/// A scan takes in the whole width the scanner can see, so paper narrower
/// than that is framed by the scanner's backing — light gray, a little
/// darker than white paper. Cropping finds the sheet against it. In auto
/// size the measured size then snaps to a standard paper size when it's
/// clearly one, and stays exact otherwise (receipts, labels, photos).
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

    /// Finds the sheet within the scanned frame, against whatever surrounds
    /// it: this scanner's light gray backing — only ten or twenty levels
    /// darker than white paper — or a black background. Returns a crop
    /// rect in full-resolution pixels, or nil when the sheet fills the frame
    /// and there's nothing to take off.
    ///
    /// Decided side by side. A side is cropped only when its outermost band
    /// is plain, even background, well below the paper — and at least two
    /// sides must agree on what that background is. A sheet that reaches an
    /// edge leaves paper there, so that side is never touched, whatever is
    /// printed near it; and a dark stripe printed down one edge of a page
    /// can't pass for background on its own.
    static func contentBounds(of image: CGImage) -> CGRect? {
        let maxDimension = 600
        let scale = Double(maxDimension) / Double(max(image.width, image.height))
        let w = max(1, Int(Double(image.width) * min(1, scale)))
        let h = max(1, Int(Double(image.height) * min(1, scale)))
        guard w >= 40, h >= 40 else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered else { return nil }
        // Row 0 is the top of the frame — the sheet's leading edge.
        func value(_ x: Int, _ y: Int) -> Int { Int(pixels[y * w + x]) }

        // The paper is the brightest thing in the frame. Even a business card
        // fed at Letter size covers far more than the top 1%.
        let paper = percentile(pixels, 0.99)

        // Each side's outermost band, and whether it's background.
        enum Side: CaseIterable { case left, right, top, bottom }
        let band = max(3, maxDimension / 40)
        func bandValues(_ side: Side) -> [UInt8] {
            switch side {
            case .left: (0..<h).flatMap { y in (0..<band).map { pixels[y * w + $0] } }
            case .right: (0..<h).flatMap { y in ((w - band)..<w).map { pixels[y * w + $0] } }
            case .top: Array(pixels[0..<(band * w)])
            case .bottom: Array(pixels[((h - band) * w)...])
            }
        }
        var background: [Side: Int] = [:]
        for side in Side.allCases {
            let values = bandValues(side)
            let level = percentile(values, 0.5)
            // Plain: nearly all of it within a few levels of its middle —
            // which a band crossing the sheet's edge, or print, is not.
            let plain = values.filter { abs(Int($0) - level) <= 8 }.count
            if paper - level >= 10, plain * 100 >= values.count * 85 {
                background[side] = level
            }
        }
        // At least two sides showing the same backing.
        let levels = background.values.sorted()
        guard levels.count >= 2, let backing = levels.first(where: { level in
            levels.filter { abs($0 - level) <= 8 }.count >= 2
        }) else { return nil }
        background = background.filter { abs($0.value - backing) <= 8 }

        // Paper is whatever is brighter than halfway from backing to paper;
        // print on it isn't, so extents go by the share of paper in each
        // column and row rather than by any single pixel.
        let threshold = (backing + paper) / 2
        func columnShare(_ x: Int, _ rows: Range<Int>) -> Double {
            Double(rows.filter { value(x, $0) > threshold }.count) / Double(rows.count)
        }
        func rowShare(_ y: Int, _ columns: Range<Int>) -> Double {
            Double(columns.filter { value($0, y) > threshold }.count) / Double(columns.count)
        }
        func extent(
            _ count: Int, low: Side, high: Side, minimumShare: Double,
            share: (Int) -> Double
        ) -> Range<Int>? {
            let first = background[low] == nil ? 0 : (0..<count).first { share($0) >= minimumShare }
            let last = background[high] == nil
                ? count - 1 : (0..<count).reversed().first { share($0) >= minimumShare }
            guard let first, let last, first < last else { return nil }
            return first..<(last + 1)
        }
        // Columns over the whole height first — a small card is still a
        // tenth of its columns — then rows within those columns, then the
        // columns again within those rows.
        guard
            let roughColumns = extent(
                w, low: .left, high: .right, minimumShare: 0.08,
                share: { columnShare($0, 0..<h) }),
            let rows = extent(
                h, low: .top, high: .bottom, minimumShare: 0.3,
                share: { rowShare($0, roughColumns) }),
            let columns = extent(
                w, low: .left, high: .right, minimumShare: 0.3,
                share: { columnShare($0, rows) })
        else { return nil }
        guard columns.count < w || rows.count < h else { return nil }

        // Back to full resolution, shaving one sample off each cropped side
        // so the soft edge and its shadow go with the backing.
        let inverse = Double(image.width) / Double(w)
        func edge(_ sample: Int, _ side: Side, inward: Int) -> Double {
            Double(sample + (background[side] == nil ? 0 : inward)) * inverse
        }
        let minX = edge(columns.lowerBound, .left, inward: 1)
        let maxX = edge(columns.upperBound, .right, inward: -1)
        let minY = edge(rows.lowerBound, .top, inward: 1)
        let maxY = edge(rows.upperBound, .bottom, inward: -1)
        let rect = CGRect(
            x: minX.rounded(), y: minY.rounded(),
            width: (maxX - minX).rounded(), height: (maxY - minY).rounded())
        guard rect.width > 16, rect.height > 16 else { return nil }
        return rect.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    private static func percentile(_ values: [UInt8], _ fraction: Double) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        for value in values { histogram[Int(value)] += 1 }
        let target = Int(Double(values.count) * fraction)
        var running = 0
        for level in 0..<256 {
            running += histogram[level]
            if running > target { return level }
        }
        return 255
    }
}
