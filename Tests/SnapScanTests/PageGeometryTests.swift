import CoreGraphics
import Foundation
import Testing

@testable import SnapScan

@Suite struct PageGeometryTests {
    // MARK: Snapping

    @Test func snapsNearLetter() throws {
        let snapped = try #require(PageGeometry.snappedSize(widthMM: 214.2, heightMM: 277.9))
        #expect(snapped.name == "Letter")
        #expect(snapped.widthMM == 215.9)
        #expect(snapped.heightMM == 279.4)
    }

    @Test func disambiguatesA4FromLetterByHeight() throws {
        // 213mm width is within tolerance of both A4 (210) and Letter (215.9);
        // the height decides.
        let a4ish = try #require(PageGeometry.snappedSize(widthMM: 213.0, heightMM: 295.5))
        #expect(a4ish.name == "A4")
        let letterish = try #require(
            PageGeometry.snappedSize(widthMM: 213.0, heightMM: 280.9))
        #expect(letterish.name == "Letter")
    }

    @Test func keepsMeasuredOrientation() throws {
        // A 4×6 photo fed sideways stays landscape after snapping.
        let snapped = try #require(PageGeometry.snappedSize(widthMM: 153.0, heightMM: 100.9))
        #expect(snapped.name == "4×6")
        #expect(snapped.widthMM == 152.4)
        #expect(snapped.heightMM == 101.6)
    }

    @Test func weirdSizesDoNotSnap() {
        // A receipt: standard-ish width, wildly nonstandard length.
        #expect(PageGeometry.snappedSize(widthMM: 80.0, heightMM: 292.0) == nil)
        // A label.
        #expect(PageGeometry.snappedSize(widthMM: 62.0, heightMM: 62.0) == nil)
    }

    // MARK: Content bounds

    /// Gray test frame: black background with a bright rectangle at the
    /// given rect (in pixels).
    private func makeFrame(
        width: Int, height: Int, paper: CGRect
    ) throws -> CGImage {
        var pixels = [UInt8](repeating: 10, count: width * height)
        for y in Int(paper.minY)..<Int(paper.maxY) {
            for x in Int(paper.minX)..<Int(paper.maxX) {
                pixels[y * width + x] = 235
            }
        }
        return try #require(
            FrameImage.make(
                pixels: Data(pixels), width: width, height: height,
                bytesPerRow: width, format: .gray8))
    }

    @Test func darkSurroundingsAreLeftAlone() throws {
        // This scanner's backing is light gray; black around the paper can
        // only be a border printed on it, and that's part of the page.
        let frame = try makeFrame(
            width: 850, height: 1100,
            paper: CGRect(x: 200, y: 50, width: 400, height: 900))
        #expect(PageGeometry.contentBounds(of: frame) == nil)
    }

    @Test func fullFrameHasNothingToCrop() throws {
        let frame = try makeFrame(
            width: 400, height: 600,
            paper: CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(PageGeometry.contentBounds(of: frame) == nil)
    }

    /// The scanner's own backing: light gray, a few levels of noise, only
    /// about twenty levels below white paper — as measured on a real scan
    /// of a card at Letter size. `paper` is drawn at 252, with lines of
    /// print on it.
    private func makeGrayBackedFrame(
        width: Int, height: Int, paper: CGRect, stripe: CGRect? = nil
    ) throws -> CGImage {
        var noise: UInt64 = 7
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                noise = noise &* 6364136223846793005 &+ 1442695040888963407
                let jitter = Int(noise >> 61) - 3  // -3…4
                let onPaper = paper.contains(CGPoint(x: x, y: y))
                let printed = onPaper && (y - Int(paper.minY)) % 40 < 6
                    && x > Int(paper.minX) + 30 && x < Int(paper.maxX) - 30
                var level = onPaper ? (printed ? 40 : 252) : 234
                if let stripe, stripe.contains(CGPoint(x: x, y: y)) { level = 60 }
                pixels[y * width + x] = UInt8(max(0, min(255, level + jitter)))
            }
        }
        return try #require(
            FrameImage.make(
                pixels: Data(pixels), width: width, height: height,
                bytesPerRow: width, format: .gray8))
    }

    @Test func findsACardAgainstTheGrayBacking() throws {
        // A card fed at Letter size: centred by the guides, leading edge at
        // the top of the frame, backing on three sides.
        let frame = try makeGrayBackedFrame(
            width: 850, height: 1100,
            paper: CGRect(x: 225, y: 0, width: 400, height: 600))
        let bounds = try #require(PageGeometry.contentBounds(of: frame))
        #expect(abs(bounds.minX - 225) < 12)
        #expect(abs(bounds.maxX - 625) < 12)
        #expect(bounds.minY == 0, "the side the sheet reaches is left alone")
        #expect(abs(bounds.maxY - 600) < 15)
    }

    @Test func trimsOnlyTheSidesOfANarrowFullLengthSheet() throws {
        // What auto size hands over: length already cut by the scanner,
        // backing showing either side.
        let frame = try makeGrayBackedFrame(
            width: 850, height: 1100,
            paper: CGRect(x: 120, y: 0, width: 610, height: 1100))
        let bounds = try #require(PageGeometry.contentBounds(of: frame))
        #expect(abs(bounds.minX - 120) < 12)
        #expect(abs(bounds.maxX - 730) < 12)
        #expect(bounds.minY == 0)
        #expect(bounds.maxY == 1100)
    }

    @Test func aPageThatFillsTheFrameIsLeftAloneDespiteADarkEdgeStripe() throws {
        // A full-bleed stripe printed down one edge is plain and dark like
        // background, but it's on one side only.
        let frame = try makeGrayBackedFrame(
            width: 850, height: 1100,
            paper: CGRect(x: 0, y: 0, width: 850, height: 1100),
            stripe: CGRect(x: 0, y: 0, width: 45, height: 1100))
        #expect(PageGeometry.contentBounds(of: frame) == nil)
    }

    /// Colour frames: the gray backing, a sheet of the given colour, and a
    /// white label on it.
    private func makeColorFrame(
        width: Int, height: Int, sheet: CGRect, color: (UInt8, UInt8, UInt8),
        label: CGRect
    ) throws -> CGImage {
        var noise: UInt64 = 11
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                noise = noise &* 6364136223846793005 &+ 1442695040888963407
                let jitter = Int(noise >> 61) - 3
                let point = CGPoint(x: x, y: y)
                let rgb: (UInt8, UInt8, UInt8) =
                    label.contains(point) ? (253, 253, 253)
                    : sheet.contains(point) ? color : (234, 234, 234)
                for (channel, value) in [rgb.0, rgb.1, rgb.2].enumerated() {
                    pixels[3 * (y * width + x) + channel] =
                        UInt8(max(0, min(255, Int(value) + jitter)))
                }
            }
        }
        return try #require(
            FrameImage.make(
                pixels: Data(pixels), width: width, height: height,
                bytesPerRow: width * 3, format: .rgb24))
    }

    @Test func colouredPaperFillingTheFrameIsLeftWholeDespiteAWhiteLabel() throws {
        // The label is the brightest thing in the frame, and the coloured
        // margins are plain and darker than it — but they aren't backing.
        let frame = try makeColorFrame(
            width: 850, height: 1100,
            sheet: CGRect(x: 0, y: 0, width: 850, height: 1100), color: (245, 205, 120),
            label: CGRect(x: 300, y: 400, width: 300, height: 150))
        #expect(PageGeometry.contentBounds(of: frame) == nil)
    }

    @Test func findsColouredPaperNotItsWhiteLabel() throws {
        // A coloured sheet narrower than the frame, about as light as the
        // backing, with a white label on it: the crop is the sheet.
        let frame = try makeColorFrame(
            width: 850, height: 1100,
            sheet: CGRect(x: 150, y: 0, width: 550, height: 1100), color: (200, 225, 250),
            label: CGRect(x: 300, y: 400, width: 250, height: 120))
        let bounds = try #require(PageGeometry.contentBounds(of: frame))
        #expect(abs(bounds.minX - 150) < 12)
        #expect(abs(bounds.maxX - 700) < 12)
        #expect(bounds.minY == 0 && bounds.maxY == 1100)
    }

    @Test func findsDarkColouredPaper() throws {
        // Darker than the backing and with nothing white on it.
        let frame = try makeColorFrame(
            width: 850, height: 1100,
            sheet: CGRect(x: 225, y: 0, width: 400, height: 600), color: (40, 60, 140),
            label: .zero)
        let bounds = try #require(PageGeometry.contentBounds(of: frame))
        #expect(abs(bounds.minX - 225) < 12)
        #expect(abs(bounds.maxX - 625) < 12)
        #expect(abs(bounds.maxY - 600) < 15)
    }

    @Test func whiteBackgroundFrameIsLeftAlone() throws {
        // No black margins at all (background wasn't black): keep as scanned.
        var pixels = [UInt8](repeating: 240, count: 400 * 600)
        pixels[0] = 240
        let frame = try #require(
            FrameImage.make(
                pixels: Data(pixels), width: 400, height: 600,
                bytesPerRow: 400, format: .gray8))
        #expect(PageGeometry.contentBounds(of: frame) == nil)
    }
}
