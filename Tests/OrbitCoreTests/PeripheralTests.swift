import XCTest
@testable import OrbitCore

final class PeripheralTests: XCTestCase {
    private func p(_ id: String, _ fraction: Double?, kind: PeripheralKind = .other,
                   charging: ChargingState = .unknown) -> Peripheral {
        Peripheral(id: id, name: id, kind: kind, fraction: fraction, charging: charging, source: "test")
    }

    // MARK: Peripheral init validity

    func testRejectsOutOfRangeAndNonFiniteFractions() {
        XCTAssertNil(p("a", -0.1).fraction)
        XCTAssertNil(p("a", 1.1).fraction)
        XCTAssertNil(p("a", .nan).fraction)
        XCTAssertNil(p("a", .infinity).fraction)
        XCTAssertNil(p("a", nil).fraction)
        XCTAssertEqual(p("a", 0).fraction, 0)
        XCTAssertEqual(p("a", 1).fraction, 1)
        XCTAssertEqual(p("a", 0.62).fraction, 0.62)
    }

    // MARK: dedup/sort

    func testDedupTiesAmongEquallyKnownEntriesKeepFirstOccurrence() {
        let items = [p("x", 0.5), p("x", 0.9)]
        let result = PeripheralList.dedupedSorted(items)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].fraction, 0.5)
    }

    // MARK: Repair1 section C regression — a conflict must prefer known
    // valid data over unknown for the SAME id, not just whichever read
    // happened first (root: "first-ID wins regardless of order... is false
    // for conflicts").

    func testDedupConflictPrefersKnownOverUnknownWhenUnknownReadFirst() {
        let items = [p("x", nil), p("x", 0.42)]
        let result = PeripheralList.dedupedSorted(items)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].fraction, 0.42, "a later known reading must win over an earlier unknown one for the same device")
    }

    func testDedupConflictPrefersKnownOverUnknownWhenKnownReadFirst() {
        let items = [p("x", 0.42), p("x", nil)]
        let result = PeripheralList.dedupedSorted(items)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].fraction, 0.42, "an already-known reading must not be discarded by a later unknown one")
    }

    func testKnownFractionsAscendingUnknownLast() {
        let items = [p("c", nil), p("a", 0.88), p("b", 0.15)]
        let result = PeripheralList.dedupedSorted(items)
        XCTAssertEqual(result.map(\.id), ["b", "a", "c"])
    }

    func testEqualFractionsBrokenByID() {
        let items = [p("b", 0.5), p("a", 0.5)]
        let result = PeripheralList.dedupedSorted(items)
        XCTAssertEqual(result.map(\.id), ["a", "b"])
    }

    func testValidZeroSortsLowest() {
        let items = [p("a", 0.5), p("b", 0)]
        let result = PeripheralList.dedupedSorted(items)
        XCTAssertEqual(result.map(\.id), ["b", "a"])
    }

    func testLimitFourPrefersKnownOverUnknown() {
        let items = [p("u1", nil), p("u2", nil), p("k1", 0.9), p("k2", 0.1), p("k3", 0.5)]
        let result = PeripheralList.dedupedSorted(items, limit: 4)
        XCTAssertEqual(result.count, 4)
        // All 3 known entries must survive the cap before either unknown does.
        XCTAssertTrue(["k1", "k2", "k3"].allSatisfy { id in result.contains { $0.id == id } })
        XCTAssertEqual(result.filter { $0.fraction == nil }.count, 1, "exactly one unknown fills the remaining slot")
    }

    func testAllUnknownStillReturnsEntriesNotEmpty() {
        let items = [p("a", nil), p("b", nil)]
        let result = PeripheralList.dedupedSorted(items)
        XCTAssertEqual(result.count, 2)
    }

    func testEmptyInputGivesEmptyNotError() {
        XCTAssertTrue(PeripheralList.dedupedSorted([]).isEmpty)
    }

    func testFakePeripheralBackendReflectsUpdates() {
        let backend = FakePeripheralBackend(peripherals: [p("a", 0.5)])
        XCTAssertEqual(backend.currentPeripherals().count, 1)
        backend.update([p("a", 0.5), p("b", 0.2)])
        XCTAssertEqual(backend.currentPeripherals().count, 2)
    }
}
