// Renders the SnapScan app icon into an .iconset directory.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let outputURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

func drawIcon(canvas: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    defer { image.unlockFocus() }

    // macOS-style squircle occupying ~80% of the canvas.
    let inset = canvas * 0.098
    let rect = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGradient(
        starting: NSColor(calibratedRed: 0.13, green: 0.42, blue: 0.81, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.23, blue: 0.52, alpha: 1)
    )?.draw(in: squircle, angle: -90)

    // White page with a subtle shadow, plus a scan beam across it.
    let pageWidth = rect.width * 0.46
    let pageHeight = rect.height * 0.60
    let pageRect = NSRect(
        x: rect.midX - pageWidth / 2,
        y: rect.midY - pageHeight / 2,
        width: pageWidth,
        height: pageHeight)
    let page = NSBezierPath(
        roundedRect: pageRect, xRadius: rect.width * 0.02, yRadius: rect.width * 0.02)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = canvas * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.01)
    shadow.set()
    NSColor.white.setFill()
    page.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // The beam is the dividing line: paper above it, data below.
    let splitY = rect.midY
    let textInset = pageWidth * 0.14
    let textWidth = pageWidth * 0.72

    // Text lines on the paper half.
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(
        rect: NSRect(
            x: pageRect.minX, y: splitY,
            width: pageRect.width, height: pageRect.maxY - splitY)
    ).setClip()
    NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
    let lineHeight = pageHeight * 0.045
    for i in 0..<6 {
        let width = pageWidth * (i == 5 ? 0.45 : 0.72)
        let lineRect = NSRect(
            x: pageRect.minX + textInset,
            y: pageRect.maxY - pageHeight * (0.18 + CGFloat(i) * 0.13),
            width: width,
            height: lineHeight)
        NSBezierPath(
            roundedRect: lineRect, xRadius: lineHeight / 2, yRadius: lineHeight / 2
        ).fill()
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    // Below the beam the page has already been read: the paper backing goes
    // dark and its contents come back as glowing hex, brightest just under
    // the beam where the scan is freshest.
    NSGraphicsContext.current?.saveGraphicsState()
    page.setClip()
    NSBezierPath(
        rect: NSRect(
            x: pageRect.minX, y: pageRect.minY,
            width: pageRect.width, height: splitY - pageRect.minY)
    ).addClip()
    NSColor(calibratedRed: 0.02, green: 0.07, blue: 0.04, alpha: 1).setFill()
    NSBezierPath(rect: pageRect).fill()

    // A fixed seed, so regenerating the iconset reproduces this exact icon
    // rather than a new scatter of digits every time.
    var seed: UInt64 = 0x5CA1_AB1E
    func random() -> CGFloat {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(seed >> 40) / CGFloat(1 << 24)
    }

    let glyphs = Array("0123456789ABCDEF·×≡§¥")
    let columns = 6
    let rows = 5
    let cellWidth = textWidth / CGFloat(columns)
    let cellHeight = (splitY - pageRect.minY - pageHeight * 0.06) / CGFloat(rows)
    let fontSize = min(cellWidth, cellHeight) * 0.86
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let glyphGlow = NSShadow()
    glyphGlow.shadowColor = NSColor(calibratedRed: 0.2, green: 1.0, blue: 0.35, alpha: 0.95)
    glyphGlow.shadowBlurRadius = canvas * 0.012
    glyphGlow.set()

    // Each column sits at its own height, so the digits fall in streaks
    // instead of lining up into a table.
    let columnOffsets = (0..<columns).map { _ in (random() - 0.5) * cellHeight * 0.55 }

    for row in 0..<rows {
        // Fade with distance below the beam, like the tail of a rain column.
        let depth = CGFloat(row) / CGFloat(rows - 1)
        for column in 0..<columns {
            // Gaps keep it reading as falling code rather than a filled grid.
            if random() < 0.18 { continue }
            let glyph = String(glyphs[Int(random() * CGFloat(glyphs.count - 1))])
            // A few glyphs burn white-green: the head of a trail.
            let isHead = random() < 0.16
            let color =
                isHead
                ? NSColor(calibratedRed: 0.82, green: 1.0, blue: 0.86, alpha: 1)
                : NSColor(
                    calibratedRed: 0.15, green: 1.0, blue: 0.38,
                    alpha: 0.95 - depth * 0.45 - random() * 0.2)
            let text = NSAttributedString(
                string: glyph, attributes: [.font: font, .foregroundColor: color])
            let size = text.size()
            text.draw(
                at: NSPoint(
                    x: pageRect.minX + textInset + CGFloat(column) * cellWidth
                        + (cellWidth - size.width) / 2,
                    y: splitY - pageHeight * 0.03 - CGFloat(row + 1) * cellHeight
                        + (cellHeight - size.height) / 2 + columnOffsets[column]))
        }
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    // Scan beam.
    let beamHeight = rect.height * 0.055
    let beamRect = NSRect(
        x: rect.minX + rect.width * 0.12,
        y: rect.midY - beamHeight / 2,
        width: rect.width * 0.76,
        height: beamHeight)
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.setClip()
    let beamColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 1.0, alpha: 1)
    let glow = NSShadow()
    glow.shadowColor = beamColor.withAlphaComponent(0.9)
    glow.shadowBlurRadius = canvas * 0.035
    glow.set()
    beamColor.setFill()
    NSBezierPath(
        roundedRect: beamRect, xRadius: beamHeight / 2, yRadius: beamHeight / 2
    ).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    guard let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff)
    else { fatalError("could not rasterize icon") }
    rep.size = NSSize(width: pixels, height: pixels)
    guard
        let resized = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("could not allocate bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = resized.representation(using: .png, properties: [:]) else {
        fatalError("could not encode PNG")
    }
    try! png.write(to: url)
}

let master = drawIcon(canvas: 1024)
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in entries {
    writePNG(master, pixels: pixels, to: outputURL.appendingPathComponent("\(name).png"))
}
print("Wrote iconset to \(outputURL.path)")
