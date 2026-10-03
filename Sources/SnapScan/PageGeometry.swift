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

    /// Finds the sheet within the scanned frame, against this scanner's
    /// light gray backing — only ten or twenty levels darker than white
    /// paper. Returns a crop rect in full-resolution pixels, or nil when the
    /// sheet fills the frame and there's nothing to take off.
    ///
    /// Decided side by side. A side is cropped only when its outermost band
    /// is plain, neutral, light gray, and set apart from the sheet — and at
    /// least two sides must agree on it. A sheet that reaches an edge leaves
    /// paper there, so that side is never touched, whatever is printed near
    /// it. Coloured paper can't pass for backing, nor can a dark border
    /// printed down a page's edges.
    ///
    /// The sheet is then whatever isn't backing: brighter than it, or a
    /// different colour. Not merely the brightest thing in the frame — a
    /// white label on coloured paper would otherwise be taken for the page.
    static func contentBounds(of image: CGImage) -> CGRect? {
        let maxDimension = 600
        let scale = Double(maxDimension) / Double(max(image.width, image.height))
        let w = max(1, Int(Double(image.width) * min(1, scale)))
        let h = max(1, Int(Double(image.height) * min(1, scale)))
        guard w >= 40, h >= 40 else { return nil }

        var rgbx = [UInt8](repeating: 0, count: w * h * 4)
        let rendered = rgbx.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered else { return nil }
        // Brightness, and how far each pixel leans red or blue of green —
        // zero for anything gray. Row 0 is the top of the frame, the
        // sheet's leading edge.
        var luma = [UInt8](repeating: 0, count: w * h)
        var redLean = [Int16](repeating: 0, count: w * h)
        var blueLean = [Int16](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Int(rgbx[4 * i]), g = Int(rgbx[4 * i + 1]), b = Int(rgbx[4 * i + 2])
            luma[i] = UInt8((299 * r + 587 * g + 114 * b) / 1000)
            redLean[i] = Int16(r - g)
            blueLean[i] = Int16(b - g)
        }

        struct Tone {
            var level: Int
            var red: Int
            var blue: Int
            func differs(from other: Tone, by margin: Int) -> Bool {
                abs(level - other.level) > margin || abs(red - other.red) > margin
                    || abs(blue - other.blue) > margin
            }
        }
        /// The middle brightness and lean of a set of pixels, by histogram.
        func tone(of indices: [Int]) -> Tone {
            var levels = [Int](repeating: 0, count: 256)
            var reds = [Int](repeating: 0, count: 511)
            var blues = [Int](repeating: 0, count: 511)
            for i in indices {
                levels[Int(luma[i])] += 1
                reds[Int(redLean[i]) + 255] += 1
                blues[Int(blueLean[i]) + 255] += 1
            }
            func middle(_ histogram: [Int]) -> Int {
                var running = 0
                for (bin, count) in histogram.enumerated() {
                    running += count
                    if running * 2 > indices.count { return bin }
                }
                return histogram.count - 1
            }
            return Tone(level: middle(levels), red: middle(reds) - 255, blue: middle(blues) - 255)
        }

        // The brightest paper in the frame — a card fed at Letter size still
        // covers far more than the top 1% — and the middle of the frame,
        // which a sheet of any size or colour mostly covers.
        let paper = percentile(luma, 0.99)
        let middle = tone(
            of: (h / 4..<(3 * h / 4)).flatMap { y in (w / 4..<(3 * w / 4)).map { y * w + $0 } })

        // Each side's outermost band, and whether it's backing.
        enum Side: CaseIterable { case left, right, top, bottom }
        let band = max(3, maxDimension / 40)
        func bandIndices(_ side: Side) -> [Int] {
            switch side {
            case .left: (0..<h).flatMap { y in (0..<band).map { y * w + $0 } }
            case .right: (0..<h).flatMap { y in ((w - band)..<w).map { y * w + $0 } }
            case .top: Array(0..<(band * w))
            case .bottom: Array(((h - band) * w)..<(h * w))
            }
        }
        var background: [Side: Tone] = [:]
        for side in Side.allCases {
            let indices = bandIndices(side)
            let band = tone(of: indices)
            // Plain: nearly all of it within a few levels of its middle —
            // which a band crossing the sheet's edge, or print, is not.
            let plain = indices.filter { abs(Int(luma[$0]) - band.level) <= 8 }.count
            // The backing is a light, neutral gray.
            let looksLikeBacking = band.level >= 160 && abs(band.red) <= 8 && abs(band.blue) <= 8
            // And it isn't the sheet: either darker than the paper, or unlike
            // what fills the middle of the frame.
            let apart = paper - band.level >= 10 || band.differs(from: middle, by: 10)
            if looksLikeBacking, apart, plain * 100 >= indices.count * 85 {
                background[side] = band
            }
        }
        // At least two sides showing the same backing.
        let candidates = background.values.map(\.level).sorted()
        guard candidates.count >= 2, let level = candidates.first(where: { level in
            candidates.filter { abs($0 - level) <= 8 }.count >= 2
        }) else { return nil }
        background = background.filter { abs($0.value.level - level) <= 8 }
        let sides = Array(background.values)
        let backing = Tone(
            level: level,
            red: sides.map(\.red).reduce(0, +) / sides.count,
            blue: sides.map(\.blue).reduce(0, +) / sides.count)

        // The sheet: brighter than the backing, or another colour. Darker
        // gray is the sheet's shadow (or print, which paper around it
        // already counts for), so extents go by the share of sheet in each
        // column and row rather than by any single pixel.
        func isSheet(_ x: Int, _ y: Int) -> Bool {
            let i = y * w + x
            return Int(luma[i]) - backing.level > 10
                || abs(Int(redLean[i]) - backing.red) > 10
                || abs(Int(blueLean[i]) - backing.blue) > 10
        }
        func columnShare(_ x: Int, _ rows: Range<Int>) -> Double {
            Double(rows.filter { isSheet(x, $0) }.count) / Double(rows.count)
        }
        func rowShare(_ y: Int, _ columns: Range<Int>) -> Double {
            Double(columns.filter { isSheet($0, y) }.count) / Double(columns.count)
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
