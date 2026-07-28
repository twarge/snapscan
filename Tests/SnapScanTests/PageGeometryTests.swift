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

    @Test func findsPaperAgainstBlackBackground() throws {
        let frame = try makeFrame(
            width: 850, height: 1100,
            paper: CGRect(x: 200, y: 50, width: 400, height: 900))
        let bounds = try #require(PageGeometry.contentBounds(of: frame))
        // Within ~1% of the true edges (downsampling + fringe shaving).
        #expect(abs(bounds.minX - 200) < 12)
        #expect(abs(bounds.maxX - 600) < 12)
        #expect(abs(bounds.minY - 50) < 15)
        #expect(abs(bounds.maxY - 950) < 15)
    }

    @Test func fullFrameHasNothingToCrop() throws {
        let frame = try makeFrame(
            width: 400, height: 600,
            paper: CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(PageGeometry.contentBounds(of: frame) == nil)
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
