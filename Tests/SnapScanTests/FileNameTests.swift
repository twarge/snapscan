import Testing

@testable import SnapScan

@Suite struct FileNameTests {
    @Test func sanitizeStripsExtensionAndSeparators() {
        #expect(ScannerEngine.sanitizeFileName("Tax Return 2025.pdf") == "Tax Return 2025")
        #expect(ScannerEngine.sanitizeFileName("a/b:c") == "a-b-c")
        #expect(ScannerEngine.sanitizeFileName("  padded  ") == "padded")
        #expect(ScannerEngine.sanitizeFileName("Receipts.PDF") == "Receipts")
    }

    @Test func sanitizeEmptyInputs() {
        #expect(ScannerEngine.sanitizeFileName("") == "")
        #expect(ScannerEngine.sanitizeFileName("   ") == "")
        #expect(ScannerEngine.sanitizeFileName(".pdf") == "")
    }
}
