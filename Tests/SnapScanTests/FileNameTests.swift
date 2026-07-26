import XCTest

@testable import SnapScan

final class FileNameTests: XCTestCase {
    func testSanitizeStripsExtensionAndSeparators() {
        XCTAssertEqual(ScannerEngine.sanitizeFileName("Tax Return 2025.pdf"), "Tax Return 2025")
        XCTAssertEqual(ScannerEngine.sanitizeFileName("a/b:c"), "a-b-c")
        XCTAssertEqual(ScannerEngine.sanitizeFileName("  padded  "), "padded")
        XCTAssertEqual(ScannerEngine.sanitizeFileName("Receipts.PDF"), "Receipts")
    }

    func testSanitizeEmptyInputs() {
        XCTAssertEqual(ScannerEngine.sanitizeFileName(""), "")
        XCTAssertEqual(ScannerEngine.sanitizeFileName("   "), "")
        XCTAssertEqual(ScannerEngine.sanitizeFileName(".pdf"), "")
    }
}
