import AppKit
import Testing

@testable import SnapScan

@Suite struct NameSuggesterTests {
    /// End to end over a rendered page: OCR, then whichever namer this Mac
    /// has. The assertion is deliberately loose — the on-device model isn't
    /// present everywhere (CI included), where the heading heuristic answers
    /// instead — but both paths have to produce a usable filename.
    @Test func namesARenderedBill() async throws {
        let suggestion = await NameSuggester.suggest(for: [renderBillPage()])
        print("suggested name: \(suggestion ?? "<none>")")
        let name = try #require(suggestion)
        #expect(!name.isEmpty)
        #expect(ScannerEngine.sanitizeFileName(name) == name)
        #expect(!ScannerEngine.isDefaultDocumentName(name))
    }

    /// A page with nothing to read must not be named — better a timestamp
    /// than a confident guess drawn from noise.
    @Test func declinesToNameABlankPage() async {
        let context = CGContext(
            data: nil, width: 600, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(await NameSuggester.suggest(for: [context.makeImage()!]) == nil)
    }

    private func renderBillPage() -> CGImage {
        let width = 1200
        let height = 1600
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let heading = "Riverside Water Authority"
        NSAttributedString(
            string: heading,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 44), .foregroundColor: NSColor.black,
            ]
        ).draw(in: NSRect(x: 80, y: 1420, width: 1040, height: 120))
        let body = """
            Quarterly Water and Sewer Statement

            Service address: 69 Shore Road
            Billing period: January 1 to March 31, 2025
            Statement date: April 8, 2025

            Water usage this quarter: 14,200 gallons
            Water charges: $118.40
            Sewer charges: $76.15
            Amount due: $194.55
            Please pay by May 9, 2025 to avoid a late fee.
            """
        NSAttributedString(
            string: body,
            attributes: [
                .font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black,
            ]
        ).draw(in: NSRect(x: 80, y: 500, width: 1040, height: 900))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    @Test func sanitizeUnwrapsModelAnswers() {
        #expect(NameSuggester.sanitize("\"Con Edison Electric Bill\"") == "Con Edison Electric Bill")
        #expect(NameSuggester.sanitize("- Toyota Camry Service Record") == "Toyota Camry Service Record")
        #expect(NameSuggester.sanitize("Blue Cross Statement.pdf") == "Blue Cross Statement")
        #expect(
            NameSuggester.sanitize("Water Bill 2025-03-14\nThat is my suggestion.")
                == "Water Bill 2025-03-14")
    }

    @Test func sanitizeRejectsNonNames() {
        // A sentence, not a filename — the model gave up rather than answered.
        #expect(
            NameSuggester.sanitize(
                "I'm sorry, but the text provided is too garbled for me to name it")
                == nil)
        #expect(NameSuggester.sanitize("") == nil)
        #expect(NameSuggester.sanitize("ok") == nil)
        #expect(NameSuggester.sanitize(String(repeating: "x", count: 200)) == nil)
    }

    @Test func sanitizeDropsAnEchoedDatePlaceholder() {
        #expect(NameSuggester.sanitize("Water Bill YYYY-MM-DD") == "Water Bill")
        #expect(NameSuggester.sanitize("Water Bill 2025-03-14") == "Water Bill 2025-03-14")
    }

    @Test func sanitizeNeverProducesAHiddenOrNestedFile() {
        #expect(NameSuggester.sanitize(".hidden receipt") == "hidden receipt")
        #expect(NameSuggester.sanitize("2025/04 Rent Invoice") == "2025-04 Rent Invoice")
    }

    @Test func headingPicksTheTitleLine() {
        let lines = [
            "ACME",
            "Annual Property Tax Statement",
            "123 Shore Road, Apt 4B",
            "Account 8871-2290-1120",
        ]
        #expect(NameSuggester.headingSuggestion(from: lines) == "Annual Property Tax Statement")
    }

    @Test func headingDeclinesWhenNothingReadsLikeATitle() {
        #expect(NameSuggester.headingSuggestion(from: ["8871 2290 1120 0041"]) == nil)
        #expect(NameSuggester.headingSuggestion(from: ["billing@example.com"]) == nil)
        #expect(NameSuggester.headingSuggestion(from: []) == nil)
    }

    /// The phases overlap, so the status line has to pick one. Scanning wins
    /// over everything (it's what holds the paper), then saving (it holds the
    /// controls), then naming, then background straightening.
    @Test func activityReportsThePhaseThatMatters() {
        func describe(page: Int? = nil, saving: Bool = false, naming: Bool = false, processing: Int = 0)
            -> String?
        {
            ScannerEngine.activityDescription(
                scanningPage: page, isSaving: saving, isNaming: naming,
                pagesProcessing: processing)
        }
        #expect(describe() == nil)
        #expect(describe(page: 3) == "Scanning page 3…")
        #expect(describe(page: 3, saving: true, processing: 2) == "Scanning page 3…")
        #expect(describe(saving: true, naming: true, processing: 2) == "Saving the PDF…")
        #expect(describe(naming: true, processing: 2) == "Reading the scan to suggest a name…")
        #expect(describe(processing: 2) == "Straightening 2 pages…")
        #expect(describe(processing: 1) == "Straightening 1 page…")
    }

    /// Only app-generated names get replaced by a suggestion; anything the
    /// user typed has to survive.
    @Test func defaultNameRecognition() {
        #expect(ScannerEngine.isDefaultDocumentName("Scan 2026-08-02 at 09.35.23"))
        #expect(ScannerEngine.isDefaultDocumentName("Scan 2026-08-02 at 09.35.23 (2)"))
        #expect(!ScannerEngine.isDefaultDocumentName("Scan of my lease"))
        #expect(!ScannerEngine.isDefaultDocumentName("Con Edison Electric Bill"))
        #expect(!ScannerEngine.isDefaultDocumentName(""))
    }
}
