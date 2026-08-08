import CoreGraphics
import CoreText
import Foundation
import Vision

/// The words on a page and where they sit, so they can be written into the
/// PDF as invisible text over the picture of the page.
///
/// That layer is what makes a scan behave like a document: ⌘F finds it in
/// Preview, text can be selected and copied, and Spotlight indexes the
/// contents — macOS's built-in PDF importer reads embedded text, so no
/// importer of our own is needed.
nonisolated enum TextLayer {
    struct Line: Sendable {
        let text: String
        /// Normalized to the page, origin bottom-left — the convention Vision
        /// reports in and, conveniently, the one PDF draws in.
        let box: CGRect
    }

    static func recognize(in image: CGImage) async -> [Line] {
        // Full scanner resolution buys nothing here and costs seconds; this is
        // ample for body text and keeps the pass near a second.
        guard let sample = OrientationDetector.downsampled(image, maxDimension: 2200)
        else { return [] }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // On by default, and worth it here: unlike the naming pass, this text
        // is read by people, so a corrected word beats a faithful mis-scan.
        request.usesLanguageCorrection = true
        let observations = (try? await request.perform(on: sample)) ?? []
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string,
                !text.isEmpty
            else { return nil }
            return Line(text: text, box: observation.boundingBox.cgRect)
        }
    }

    /// Draws the words over the page image in PDF text rendering mode 3 —
    /// marks that are searchable and selectable but never painted.
    ///
    /// `rect` is where the page image was drawn, not the media box: a
    /// size-snapped page centers a smaller image on a standard sheet, and the
    /// text has to follow the image rather than the paper.
    static func draw(_ lines: [Line], in rect: CGRect, into context: CGContext) {
        guard !lines.isEmpty else { return }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let box = CGRect(
                x: rect.minX + line.box.minX * rect.width,
                y: rect.minY + line.box.minY * rect.height,
                width: line.box.width * rect.width,
                height: line.box.height * rect.height)
            // Degenerate boxes would divide by zero below and can't be
            // selected anyway.
            guard box.height > 0.5, box.width > 0.5 else { continue }
            let font = CTFontCreateWithName(
                "Helvetica" as CFString, box.height * 0.85, nil)
            let typeset = CTLineCreateWithAttributedString(
                NSAttributedString(string: line.text, attributes: [.font: font]))
            let natural = CTLineGetTypographicBounds(typeset, nil, nil, nil)
            // Stretch each line to the width Vision measured, so a selection
            // lands on the pixels it appears to cover instead of drifting.
            context.textMatrix = CGAffineTransform(
                scaleX: natural > 0 ? box.width / natural : 1, y: 1)
            context.textPosition = CGPoint(x: box.minX, y: box.minY)
            CTLineDraw(typeset, context)
        }
        context.restoreGState()
    }
}
