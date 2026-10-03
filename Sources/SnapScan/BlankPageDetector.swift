import Accelerate
import CoreGraphics
import Foundation

/// Decides whether a scanned page is blank, so it can be left out of the PDF.
///
/// An empty sheet never scans as empty. The other side's print shows
/// through, the paper has texture, the sensor has noise, dust lands on the
/// glass, the sheet's edges cast a shadow, and a speck on the sensor draws a
/// streak down every page. What separates all of that from writing is that
/// ink is both sharp and dark: a stroke drops well below the paper right next
/// to it, while show-through is a faint blur. So the test looks for marks
/// that are sharp, dark and bigger than any speck, ignoring the band along
/// the sheet's edges and anything shaped like a streak or a fold.
///
/// It leans toward keeping pages. A blank page left in costs a keystroke to
/// delete; a page of writing taken out might never be missed until it's
/// needed.
nonisolated enum BlankPageDetector {
    struct Analysis: Equatable {
        /// Pixels of real marks at `analysisDPI`, once specks, streaks and
        /// folds are discounted. Zero when the page was settled before
        /// marks were counted — by its dark area, or by too little ink to
        /// matter.
        var inkPixels: Int
        /// The share of the page well darker than the paper — what a soft
        /// photograph has instead of hard edges.
        var darkFraction: Double
        /// Brightness of the paper itself, 0–255.
        var paperLevel: Int

        var isBlank: Bool {
            // A dark page — black paper, or a frame with no sheet in it — is
            // something other than an empty sheet, so it's never called blank.
            paperLevel >= BlankPageDetector.minimumPaperLevel
                && inkPixels < BlankPageDetector.minimumInkPixels
                && darkFraction < BlankPageDetector.maximumDarkFraction
        }
    }

    /// Small type survives at this resolution with its contrast intact,
    /// while a page stays small enough to examine in a few milliseconds.
    static let analysisDPI = 150.0

    /// The band along each edge that is ignored, as a share of the page:
    /// it holds the sheet's edge shadow and any fringe of the background.
    static let edgeBand = 0.04
    /// How far a mark must fall below the brightest paper within
    /// `neighborhood` pixels to count as ink. Show-through rarely reaches
    /// half of this; printed or written strokes go well past it.
    static let inkContrast = 48
    static let neighborhood = 3
    /// Marks smaller than this are dust, toner specks or noise (about
    /// 0.3 mm² at `analysisDPI`).
    static let speckPixels = 12
    /// Below this much ink a page counts as blank — about what three printed
    /// characters leave, so a page carrying only a word or two is kept.
    static let minimumInkPixels = 120
    /// The share of the page that may be well darker than the paper before
    /// it counts as a picture rather than a blank.
    static let maximumDarkFraction = 0.01
    static let minimumPaperLevel = 128

    static func isBlank(_ image: CGImage, dpi: Int) -> Bool {
        analyze(image, dpi: dpi)?.isBlank ?? false
    }

    /// nil when the image can't be read, which callers treat as not blank.
    static func analyze(_ image: CGImage, dpi: Int) -> Analysis? {
        let scale = min(1, analysisDPI / Double(max(dpi, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var color = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = color.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            // Averaging (rather than picking) source pixels keeps a thin
            // stroke as a lighter line instead of losing it between samples.
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        // Each pixel's darkest channel, not its brightness: yellow highlighter
        // or a pastel stamp barely darkens a page, but it takes a deep bite
        // out of one channel. Show-through and plain or tinted paper stay
        // even across all three, so they're no more visible here than before.
        var pixels = [UInt8](repeating: 0, count: width * height)
        color.withUnsafeBufferPointer { rgbx in
            pixels.withUnsafeMutableBufferPointer { gray in
                for i in 0..<gray.count {
                    gray[i] = min(rgbx[4 * i], rgbx[4 * i + 1], rgbx[4 * i + 2])
                }
            }
        }

        let insetX = Int(Double(width) * edgeBand)
        let insetY = Int(Double(height) * edgeBand)
        let region = (
            x: insetX, y: insetY, width: width - 2 * insetX, height: height - 2 * insetY)
        guard region.width > 2 * neighborhood, region.height > 2 * neighborhood else {
            return nil
        }

        return pixels.withUnsafeMutableBytes { raw in
            analyze(raw.baseAddress!, stride: width, region: region)
        }
    }

    private static func analyze(
        _ page: UnsafeMutableRawPointer, stride: Int,
        region: (x: Int, y: Int, width: Int, height: Int)
    ) -> Analysis? {
        let w = region.width
        let h = region.height
        let total = w * h
        var inner = vImage_Buffer(
            data: page + region.y * stride + region.x,
            height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: stride)

        // The paper is what most of the page is; the 90th percentile stays
        // on it even when text covers much of the sheet.
        var histogram = [vImagePixelCount](repeating: 0, count: 256)
        let counted = histogram.withUnsafeMutableBufferPointer {
            vImageHistogramCalculation_Planar8(&inner, $0.baseAddress!, 0)
        }
        guard counted == kvImageNoError else { return nil }
        var paperLevel = 255
        var running = 0
        for level in 0..<256 {
            running += Int(histogram[level])
            if running >= total * 9 / 10 {
                paperLevel = level
                break
            }
        }
        let darkCutoff = max(0, paperLevel - 64)
        let darkPixels = histogram[0..<darkCutoff].reduce(0) { $0 + Int($1) }
        var analysis = Analysis(
            inkPixels: 0, darkFraction: Double(darkPixels) / Double(total),
            paperLevel: paperLevel)
        guard analysis.paperLevel >= minimumPaperLevel,
            analysis.darkFraction < maximumDarkFraction
        else { return analysis }

        // The brightest value within `neighborhood` of each pixel: the paper
        // a mark sits on.
        let side = 2 * neighborhood + 1
        var surroundings = [UInt8](repeating: 0, count: total)
        let filtered = surroundings.withUnsafeMutableBytes { raw -> vImage_Error in
            var output = vImage_Buffer(
                data: raw.baseAddress, height: vImagePixelCount(h),
                width: vImagePixelCount(w), rowBytes: w)
            return vImageMax_Planar8(
                &inner, &output, nil, 0, 0, vImagePixelCount(side), vImagePixelCount(side),
                vImage_Flags(kvImageEdgeExtend))
        }
        guard filtered == kvImageNoError else { return nil }

        // Ink: well below the paper around it.
        var ink = [Bool](repeating: false, count: total)
        var inkCount = 0
        let source = page.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = source + (region.y + y) * stride + region.x
            for x in 0..<w where Int(surroundings[y * w + x]) - Int(row[x]) >= inkContrast {
                ink[y * w + x] = true
                inkCount += 1
            }
        }
        guard inkCount >= minimumInkPixels else { return analysis }

        // Group ink into marks.
        struct Mark {
            var area = 0
            var minX: Int, maxX: Int, minY: Int, maxY: Int
            var width: Int { maxX - minX + 1 }
            var height: Int { maxY - minY + 1 }
        }
        var marks: [Mark] = []
        var stack: [Int] = []
        for start in 0..<total where ink[start] {
            ink[start] = false
            stack.append(start)
            var mark = Mark(minX: w, maxX: 0, minY: h, maxY: 0)
            while let index = stack.popLast() {
                mark.area += 1
                let x = index % w
                let y = index / w
                mark.minX = min(mark.minX, x)
                mark.maxX = max(mark.maxX, x)
                mark.minY = min(mark.minY, y)
                mark.maxY = max(mark.maxY, y)
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < h else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < w else { continue }
                        let neighbor = ny * w + nx
                        if ink[neighbor] {
                            ink[neighbor] = false
                            stack.append(neighbor)
                        }
                    }
                }
            }
            if mark.area >= speckPixels { marks.append(mark) }
        }

        // A sensor streak runs the length of the sheet and a fold runs
        // across it: long, and no thicker than a line along all of that
        // length — even where they cross, or run askew. Writing that spans
        // as far loops and doubles back, so it covers far more.
        let longLine = 0.4 * Double(min(w, h))
        let lineThickness = 4.0  // under 1 mm
        func isLine(_ mark: Mark) -> Bool {
            let length = Double(mark.width * mark.width + mark.height * mark.height)
                .squareRoot()
            return length >= longLine && Double(mark.area) / length <= lineThickness
        }
        // Dust that only touches the sensor now and then draws its streak in
        // dashes: hairline upright marks, one above another in the same
        // column. Found on real scans as the only marks on otherwise empty
        // backs.
        func isDash(_ mark: Mark) -> Bool {
            mark.width <= 3 && mark.height >= 3 * mark.width
        }
        let dashColumns = marks.filter(isDash).map { ($0.minX + $0.maxX) / 2 }
        func isStreakDash(_ mark: Mark) -> Bool {
            guard isDash(mark) else { return false }
            let column = (mark.minX + mark.maxX) / 2
            return dashColumns.filter { abs($0 - column) <= 2 }.count >= 2
        }

        for mark in marks where !isLine(mark) && !isStreakDash(mark) {
            analysis.inkPixels += mark.area
        }
        return analysis
    }
}
