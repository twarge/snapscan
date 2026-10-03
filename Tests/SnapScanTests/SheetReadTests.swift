import Foundation
import Testing

@testable import SnapScan

/// A scanner in miniature, speaking just enough of docs/PROTOCOL.md to read
/// sheets: each side fills line by line as the paper moves; reading a side
/// with less than a full chunk ready gets "not ready" (a full buffer of junk
/// and a check condition, §4.5); a side's last read comes back with its
/// unfilled residual in the sense data (§4.2).
///
/// Time is counted in image reads, so a test plays out the same way however
/// fast the machine running it is.
nonisolated private final class SimulatedScanner: ScannerLink, @unchecked Sendable {
    struct Side {
        let lines: Int
        /// Reads before the side's first line exists.
        let delay: Int
        /// Lines the side gains per read.
        let rate: Int
        var delivered = 0
    }

    enum Outcome: Equatable { case data, wait, end }

    let width: Int
    private var sides: [UInt8: Side]
    private var clock = 0
    private var pendingSense: [UInt8]?
    private let lock = NSLock()
    /// Every image read, in order: the window asked, and what it got.
    private(set) var imageReads: [(window: UInt8, outcome: Outcome)] = []

    init(width: Int = 4000, front: Side, back: Side? = nil) {
        self.width = width
        var sides = [ScannerCommands.Window.front.rawValue: front]
        if let back { sides[ScannerCommands.Window.back.rawValue] = back }
        self.sides = sides
    }

    /// Each line's bytes are the line number, so junk or a lost line shows.
    static let junk: UInt8 = 0xEE

    func send(cdb: [UInt8], dataOut: Data?, dataIn: Int) throws -> (
        status: USBTransport.CommandStatus, data: Data
    ) {
        lock.lock()
        defer { lock.unlock() }
        let read = ScannerCommands.Opcode.read.rawValue
        switch cdb[0] {
        case ScannerCommands.Opcode.requestSense.rawValue:
            defer { pendingSense = nil }
            return (.good, Data(pendingSense ?? [UInt8](repeating: 0, count: 18)))
        case read where cdb[2] == ScannerCommands.ReadType.pixelSize.rawValue:
            // Like auto length detection: the line count is only a ceiling.
            let ceiling = 4 * (sides.values.map(\.lines).max() ?? 0)
            var reply = [UInt8](repeating: 0, count: 32)
            for (offset, value) in [(0, width), (4, ceiling)] {
                for byte in 0..<4 {
                    reply[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * (3 - byte)))
                }
            }
            return (.good, Data(reply))
        case read:
            return readImage(window: cdb[5], length: dataIn)
        default:
            return (.good, Data())
        }
    }

    private func readImage(window: UInt8, length: Int) -> (
        status: USBTransport.CommandStatus, data: Data
    ) {
        clock += 1
        var side = sides[window]!
        defer { sides[window] = side }
        let bytesPerLine = width * 3
        let chunkLines = length / bytesPerLine
        let produced = min(side.lines, max(0, (clock - side.delay) * side.rate))
        let remaining = side.lines - side.delivered

        func lines(_ count: Int) -> Data {
            var data = Data(capacity: length)
            for line in side.delivered..<(side.delivered + count) {
                data.append(contentsOf: repeatElement(UInt8(line % 200), count: bytesPerLine))
            }
            side.delivered += count
            return data
        }

        if produced == side.lines, remaining <= chunkLines {
            var data = lines(remaining)
            let residual = length - data.count
            data.append(contentsOf: repeatElement(Self.junk, count: residual))
            pendingSense = [
                0xF0, 0, 0x60,
                UInt8(truncatingIfNeeded: residual >> 24),
                UInt8(truncatingIfNeeded: residual >> 16),
                UInt8(truncatingIfNeeded: residual >> 8),
                UInt8(truncatingIfNeeded: residual), 0x0A,
            ] + [UInt8](repeating: 0, count: 10)
            imageReads.append((window, .end))
            return (.checkCondition, data)
        }
        if produced - side.delivered >= chunkLines {
            imageReads.append((window, .data))
            return (.good, lines(chunkLines))
        }
        var notReady = [UInt8](repeating: 0, count: 18)
        notReady[2] = 0x03
        notReady[12] = 0x80
        notReady[13] = 0x13
        pendingSense = notReady
        imageReads.append((window, .wait))
        return (.checkCondition, Data(repeating: Self.junk, count: length))
    }
}

nonisolated private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NativeScanner.BatchEvent] = []

    func append(_ event: NativeScanner.BatchEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    /// Completed pages as (index, height), in the order they were reported.
    var completed: [(index: Int, height: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return stored.compactMap {
            if case .pageComplete(let index, let image) = $0 { (index, image.height) } else { nil }
        }
    }
}

@Suite struct SheetReadTests {
    private func read(
        _ scanner: SimulatedScanner, windows: [ScannerCommands.Window],
        keeping kept: Set<ScannerCommands.Window>? = nil, firstPageIndex: Int = 0
    ) async throws -> (pages: Int, log: EventLog) {
        let log = EventLog()
        let pages = try await NativeScanner().readSheet(
            transport: scanner, windows: windows, keeping: kept,
            firstPageIndex: firstPageIndex
        ) { log.append($0) }
        return (pages, log)
    }

    @Test func duplexReadsBothSidesAsTheSheetMoves() async throws {
        // The back's sensor sits a little further along the paper path.
        let scanner = SimulatedScanner(
            front: .init(lines: 300, delay: 0, rate: 4),
            back: .init(lines: 300, delay: 6, rate: 4))
        let (pages, log) = try await read(scanner, windows: [.front, .back], firstPageIndex: 4)

        #expect(pages == 2)
        #expect(log.completed.map(\.index) == [4, 5])
        #expect(log.completed.map(\.height) == [300, 300], "junk from not-ready reads kept out")

        let reads = scanner.imageReads
        let firstBack = try #require(reads.firstIndex { $0.window == 0x80 && $0.outcome != .wait })
        let frontEnd = try #require(reads.firstIndex { $0.window == 0x00 && $0.outcome == .end })
        #expect(firstBack < frontEnd, "the back is read while the front is still arriving")
    }

    @Test func pagesComeOutInSheetOrderWhenTheBackFinishesFirst() async throws {
        let scanner = SimulatedScanner(
            front: .init(lines: 240, delay: 0, rate: 2),
            back: .init(lines: 60, delay: 0, rate: 30))
        let (_, log) = try await read(scanner, windows: [.front, .back])

        #expect(log.completed.map(\.index) == [0, 1])
        #expect(log.completed.map(\.height) == [240, 60])
        let reads = scanner.imageReads
        let backEnd = try #require(reads.firstIndex { $0.window == 0x80 && $0.outcome == .end })
        let frontEnd = try #require(reads.firstIndex { $0.window == 0x00 && $0.outcome == .end })
        #expect(backEnd < frontEnd)
    }

    @Test func backSideAloneKeepsOnlyTheBacks() async throws {
        // The front is still read — the scanner holds it until it is — but
        // only the back becomes a page, with the sheet's first page number.
        let scanner = SimulatedScanner(
            front: .init(lines: 200, delay: 0, rate: 5),
            back: .init(lines: 180, delay: 4, rate: 5))
        let (pages, log) = try await read(
            scanner, windows: [.front, .back], keeping: [.back], firstPageIndex: 6)

        #expect(pages == 1)
        #expect(log.completed.map(\.index) == [6])
        #expect(log.completed.map(\.height) == [180])
        #expect(scanner.imageReads.contains { $0.window == 0x00 && $0.outcome == .end })
    }

    @Test func simplexReadsOnlyTheFront() async throws {
        let scanner = SimulatedScanner(front: .init(lines: 130, delay: 3, rate: 5))
        let (pages, log) = try await read(scanner, windows: [.front])

        #expect(pages == 1)
        #expect(log.completed.map(\.height) == [130])
        #expect(scanner.imageReads.allSatisfy { $0.window == 0x00 })
    }
}
