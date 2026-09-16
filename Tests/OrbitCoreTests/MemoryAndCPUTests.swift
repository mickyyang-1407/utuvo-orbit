import XCTest
@testable import OrbitCore

final class MemoryAndCPUTests: XCTestCase {
    func testMemoryFractionHappyPath() {
        let value = MemoryMath.fraction(used: 4_000_000, total: 16_000_000)
        XCTAssertNotNil(value)
        XCTAssertEqual(value ?? 0, 0.25, accuracy: 0.0001)
    }

    func testMemoryFractionZeroTotalReturnsNil() {
        XCTAssertNil(MemoryMath.fraction(used: 1_000, total: 0))
        XCTAssertNil(MemoryMath.fraction(used: nil, total: nil))
        XCTAssertNil(MemoryMath.fraction(used: 1_000, total: nil))
        XCTAssertNil(MemoryMath.fraction(used: nil, total: 16_000_000))
    }

    func testMemoryFractionClampsTinyRoundingOverflow() {
        XCTAssertEqual(MemoryMath.fraction(used: 8_001_000, total: 8_000_000), 1.0)
    }

    func testMemoryLabelFormats() {
        XCTAssertEqual(MemoryMath.label(bytes: 512), "512 B")
        XCTAssertEqual(MemoryMath.label(bytes: 1024), "1.0 KB")
        XCTAssertEqual(MemoryMath.label(bytes: 1024 * 1024), "1.0 MB")
        XCTAssertEqual(MemoryMath.label(bytes: nil), "—")
    }

    func testCPUHistoryBounded() {
        var history: [Double] = []
        for value in stride(from: 0.0, to: 1.0, by: 0.1) {
            history = CPUHistory.append(history, sample: value, capacity: 5)
        }
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history.first ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(history.last ?? 0, 0.9, accuracy: 0.0001)
    }

    func testCPUHistoryIgnoresInvalidSamples() {
        let history = CPUHistory.append([0.5], sample: .nan, capacity: 5)
        XCTAssertEqual(history, [0.5])
        // Negative samples (host counter rollback) clamp to 0 but the call
        // site should already filter them — verify we at least clamp, not crash.
        let history2 = CPUHistory.append([0.5], sample: -0.1, capacity: 5)
        XCTAssertEqual(history2.last ?? 0, 0, accuracy: 0.0001)
    }

    func testCPUHistoryMeanEmptyIsNil() {
        XCTAssertNil(CPUHistory.mean([]))
        XCTAssertEqual(CPUHistory.mean([0.1, 0.3, 0.5]) ?? 0, 0.3, accuracy: 0.0001)
    }

    func testFakeSystemBackendBoundsHistory() {
        let metrics = SystemMetrics(cpuUsage: 0.5, cpuHistory: (0..<50).map { Double($0) / 100 },
                                    usedBytes: 1_000, totalBytes: 10_000,
                                    battery: nil, machine: .desktop, model: "Mac15,14")
        let backend = FakeSystemBackend(metrics: metrics,
                                        evidence: HardwareEvidence(model: "Mac15,14",
                                                                  hasInternalBattery: false,
                                                                  hasLid: false))
        let result = backend.metrics(historyCapacity: 20)
        XCTAssertEqual(result.cpuHistory.count, 20)
        XCTAssertEqual(result.machine, .desktop)
    }
}
