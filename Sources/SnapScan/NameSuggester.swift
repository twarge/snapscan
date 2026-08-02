import CoreGraphics
import Foundation
import Vision

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Proposes a filename for a scan from the words on its first pages: Vision
/// recognizes the text, then Apple's on-device language model condenses it to
/// a name.
///
/// Everything runs locally — a scanned document never leaves the machine — and
/// every step is best-effort. Where the model isn't available (an older macOS,
/// hardware without Apple Intelligence, or a Mac where it's switched off) a
/// heading heuristic stands in; where that finds nothing, the document simply
/// keeps its timestamp name.
nonisolated enum NameSuggester {
    /// Pages past the first couple say what a document *contains*, rarely what
    /// it *is* — and each one costs an OCR pass.
    static let pagesRead = 2

    /// Enough text to place the document; past this it's body copy, which
    /// mostly dilutes the summary.
    private static let characterBudget = 1200

    static func suggest(for pages: [CGImage]) async -> String? {
        let lines = await recognizedLines(in: pages)
        // Under this there's nothing to summarize: a blank page, a photograph,
        // or a form so sparse that any guess would be noise.
        guard lines.joined().count >= 40 else { return nil }
        if let name = await modelSuggestion(from: lines) { return name }
        return headingSuggestion(from: lines)
    }

    /// The recognized text of the first pages, in reading order.
    private static func recognizedLines(in pages: [CGImage]) async -> [String] {
        var lines: [String] = []
        for page in pages.prefix(pagesRead) {
            guard let sample = OrientationDetector.downsampled(page, maxDimension: 2200)
            else { continue }
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            // A document is named after its proper nouns — companies, places,
            // account numbers — which language correction likes to "fix".
            request.usesLanguageCorrection = false
            let observations = (try? await request.perform(on: sample)) ?? []
            // Observations come back in no useful order, and Vision's Y axis
            // points up, so descending midY is top-to-bottom.
            lines +=
                observations
                .sorted { $0.boundingBox.cgRect.midY > $1.boundingBox.cgRect.midY }
                .compactMap { $0.topCandidates(1).first?.string }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return lines
    }

    private static func modelSuggestion(from lines: [String]) async -> String? {
        #if canImport(FoundationModels)
            guard #available(macOS 26.0, *) else { return nil }
            guard case .available = SystemLanguageModel.default.availability else { return nil }

            let session = LanguageModelSession(
                instructions: """
                    You name scanned paper documents for a filing system.

                    Reply with the filename only: no explanation, no quotes, \
                    no file extension. Use three to eight words in Title \
                    Case, naming the source and the kind of document. When \
                    the text states the document's own date, write that date \
                    at the end as digits, year first.

                    Good answers look like these:
                    Con Edison Electric Bill 2025-03-14
                    Toyota Camry Service Record
                    Blue Cross Explanation Of Benefits 2024-11-02

                    The text comes from OCR and may contain errors; ignore \
                    fragments you cannot read.
                    """)
            let excerpt = String(lines.joined(separator: "\n").prefix(characterBudget))
            do {
                let response = try await session.respond(
                    to: """
                        Text recognized from the first pages of a scanned document:

                        \(excerpt)
                        """,
                    options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 40))
                return sanitize(response.content)
            } catch {
                // Guardrails, a model that won't load, a context overflow:
                // none are worth surfacing — the heuristic takes over.
                return nil
            }
        #else
            return nil
        #endif
    }

    /// Trims a model's answer down to something usable as a filename, or nil
    /// when what came back doesn't look like one.
    static func sanitize(_ raw: String) -> String? {
        // Answers occasionally arrive wrapped in quotes, bulleted, or — when
        // the text defeats the model — written out as a sentence.
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = String(name.split(separator: "\n").first ?? "")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*-–—.“”‘’ "))
        // Asked for a date, a model will occasionally hand back the format it
        // was shown rather than the date it read.
        name = name.replacing(/[Yy]{4}-[Mm]{2}-[Dd]{2}/, with: "")
        name = ScannerEngine.sanitizeFileName(name)
        // A leading dot would file the scan away as a hidden document.
        name = String(name.drop(while: { $0 == "." }))
        guard (3...80).contains(name.count) else { return nil }
        guard name.split(separator: " ").count <= 12 else { return nil }
        return name
    }

    /// Stand-in for the model: the line that reads most like a title.
    /// Documents announce themselves at the top — letterhead, a subject line,
    /// a form's own name — so the opening lines are filtered down to the
    /// plausible ones and the fullest of those wins.
    static func headingSuggestion(from lines: [String]) -> String? {
        let candidates = lines.prefix(8).filter { line in
            guard (2...10).contains(line.split(separator: " ").count), line.count <= 60
            else { return false }
            // Skip contact lines: phone numbers, account numbers and street
            // addresses identify a party, not the document.
            guard !line.contains("@") else { return false }
            let digits = line.filter(\.isNumber).count
            return Double(digits) / Double(line.count) < 0.3
        }
        guard let best = candidates.max(by: { $0.count < $1.count }) else { return nil }
        return sanitize(best)
    }
}
