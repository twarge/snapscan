import Foundation
import Testing

@testable import SnapScan

nonisolated private struct Item: Identifiable, Equatable {
    let id: String
}

nonisolated private func items(_ names: String) -> [Item] {
    names.map { Item(id: String($0)) }
}

nonisolated private func names(_ items: [Item]) -> String {
    items.map(\.id).joined()
}

struct PageOrderTests {
    @Test func aPageMovesForwardAndBack() {
        // Offsets count in the order as it stands, as move(fromOffsets:) does.
        #expect(names(items("ABCDE").moving(["B"], toOffset: 4)) == "ACDBE")
        #expect(names(items("ABCDE").moving(["D"], toOffset: 1)) == "ADBCE")
    }

    @Test func theEndsAreReachableAndOffsetsClamp() {
        #expect(names(items("ABCD").moving(["C"], toOffset: 0)) == "CABD")
        #expect(names(items("ABCD").moving(["B"], toOffset: 4)) == "ACDB")
        #expect(names(items("ABCD").moving(["B"], toOffset: -3)) == "BACD")
        #expect(names(items("ABCD").moving(["B"], toOffset: 99)) == "ACDB")
    }

    @Test func aSpreadSelectionMovesAsOneRunInItsOrder() {
        #expect(names(items("ABCDEF").moving(["E", "B"], toOffset: 0)) == "BEACDF")
        #expect(names(items("ABCDEF").moving(["A", "C"], toOffset: 5)) == "BDEACF")
    }

    @Test func droppingBesideItselfChangesNothing() {
        #expect(names(items("ABCD").moving(["B"], toOffset: 1)) == "ABCD")
        #expect(names(items("ABCD").moving(["B"], toOffset: 2)) == "ABCD")
        #expect(names(items("ABCD").moving(["B", "C"], toOffset: 3)) == "ABCD")
    }

    @Test func anOrderIsPutBack() {
        let before = items("ABCD").map(\.id)
        let moved = items("ABCD").moving(["A"], toOffset: 4)
        #expect(names(moved.ordered(like: before)) == "ABCD")
    }

    @Test func pagesAddedSinceStayAtTheEnd() {
        // A page deleted since is simply absent; one scanned since follows.
        let current = items("CBAX")
        #expect(names(current.ordered(like: ["A", "B", "Z", "C"])) == "ABCX")
    }
}
