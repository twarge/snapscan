import CoreGraphics
import Foundation
import Testing

@testable import SnapScan

/// An RGB image whose every pixel is distinct: red is the column, green the
/// row, so where a pixel lands after a turn can be read back.
nonisolated private func numberedImage(width: Int, height: Int) -> CGImage {
    var bytes: [UInt8] = []
    for y in 0..<height {
        for x in 0..<width { bytes += [UInt8(x * 10), UInt8(y * 10), 200] }
    }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
        bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
}

/// Red and green of every pixel, rows from the top.
nonisolated private func pixels(_ image: CGImage) -> [[[UInt8]]] {
    let width = image.width
    let height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    buffer.withUnsafeMutableBytes { raw in
        let context = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (0..<height).map { y in
        (0..<width).map { x in
            let at = (y * width + x) * 4
            return [buffer[at], buffer[at + 1]]
        }
    }
}

/// Black where `ink` says, white elsewhere, one bit a pixel.
nonisolated private func lineart(_ ink: [[Bool]]) -> CGImage {
    let height = ink.count
    let width = ink[0].count
    let rowBytes = (width + 7) / 8
    var packed = [UInt8](repeating: 0xFF, count: rowBytes * height)
    for y in 0..<height {
        for x in 0..<width where ink[y][x] {
            packed[y * rowBytes + x / 8] &= ~(0x80 >> UInt8(x % 8))
        }
    }
    return CGImage(
        width: width, height: height, bitsPerComponent: 1, bitsPerPixel: 1,
        bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: CGDataProvider(data: Data(packed) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
}

nonisolated private func ink(_ image: CGImage) -> [[Bool]] {
    pixels(image).map { row in row.map { $0[0] < 128 } }
}

struct PageRotationTests {
    @Test func aRightTurnPutsTheTopLeftCornerTopRight() throws {
        let page = ScannedPage(image: numberedImage(width: 3, height: 2), dpi: 300)
        let turned = try #require(page.rotated(clockwise: true))
        #expect(turned.image.width == 2)
        #expect(turned.image.height == 3)
        let grid = pixels(turned.image)
        // The old top row (green 0) is now the right-hand column, top down.
        #expect(grid.map { $0[1] } == [[0, 0], [10, 0], [20, 0]])
        // The old left column (red 0) is now the top row.
        #expect(grid[0].map { $0[0] } == [0, 0])
    }

    @Test func aLeftTurnPutsTheTopLeftCornerBottomLeft() throws {
        let page = ScannedPage(image: numberedImage(width: 3, height: 2), dpi: 300)
        let turned = try #require(page.rotated(clockwise: false))
        #expect(pixels(turned.image)[2][0] == [0, 0])
    }

    @Test func fourTurnsAndATurnBackChangeNothing() throws {
        let original = ScannedPage(image: numberedImage(width: 4, height: 3), dpi: 300)
        var page = original
        for _ in 0..<4 { page = try #require(page.rotated(clockwise: true)) }
        #expect(pixels(page.image) == pixels(original.image))

        let undone = try #require(original.rotated(clockwise: false)?.rotated(clockwise: true))
        #expect(pixels(undone.image) == pixels(original.image))
    }

    @Test func thePageKeepsItselfButTurnsItsPaperSize() throws {
        var page = ScannedPage(image: numberedImage(width: 3, height: 2), dpi: 200)
        page.snappedSizeName = "Letter"
        page.snappedSizeMM = CGSize(width: 215.9, height: 279.4)
        page.textLines = [TextLayer.Line(text: "hello", box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05))]

        let turned = try #require(page.rotated(clockwise: true))
        #expect(turned.id == page.id)
        #expect(turned.dpi == 200)
        #expect(turned.snappedSizeName == "Letter")
        #expect(turned.snappedSizeMM == CGSize(width: 279.4, height: 215.9))
        // Its lines ran the other way; the page is read again instead.
        #expect(turned.textLines.isEmpty)
    }

    @Test func blackAndWhiteStaysOneBit() throws {
        let marks = [
            [true, false, false],
            [false, false, true],
        ]
        let page = ScannedPage(image: lineart(marks), dpi: 300)
        let turned = try #require(page.rotated(clockwise: true))
        #expect(turned.image.bitsPerPixel == 1)
        #expect(ink(turned.image) == [
            [false, true],
            [false, false],
            [true, false],
        ])
        let back = try #require(turned.rotated(clockwise: false))
        #expect(ink(back.image) == marks)
    }
}
