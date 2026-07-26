import XCTest

@testable import SnapScan

final class SensorParseTests: XCTestCase {
    let sample = """
          Sensors:
            --page-loaded[=(yes|no)] [no] [hardware]
                Page loaded
            --scan[=(yes|no)] [yes] [hardware]
                Scan button
            --email[=(yes|no)] [no] [hardware]
                Email button
            --function <int> [1] [hardware]
                Function character on screen
        """

    func testParsesPressedButton() {
        XCTAssertEqual(ScannerEngine.parseSensor(named: "scan", in: sample), true)
    }

    func testParsesReleasedButton() {
        XCTAssertEqual(ScannerEngine.parseSensor(named: "email", in: sample), false)
        XCTAssertEqual(ScannerEngine.parseSensor(named: "page-loaded", in: sample), false)
    }

    func testMissingSensorReturnsNil() {
        XCTAssertNil(ScannerEngine.parseSensor(named: "cover-open", in: sample))
        XCTAssertNil(ScannerEngine.parseSensor(named: "scan", in: "no sensors here"))
    }
}
