import XCTest
@testable import OrbitCore

final class NetworkBackendTests: XCTestCase {
    private let reference = Date(timeIntervalSinceReferenceDate: 0)

    private func reading(interface: String = "en0",
                         type: Connection = .wifi,
                         reachable: Bool = true,
                         ip: String? = nil,
                         received: UInt64,
                         sent: UInt64,
                         mono: Double) -> NetworkReading {
        NetworkReading(interfaceName: interface, interfaceType: type, localIPv4: ip,
                       isReachable: reachable, receivedBytes: received, sentBytes: sent,
                       timestamp: reference, monotonicSeconds: mono)
    }

    func testDeltaFromNilIsReset() {
        let current = reading(received: 1_000_000, sent: 500_000, mono: 1)
        let delta = NetworkMath.delta(previous: nil, current: current)
        XCTAssertTrue(delta.reset)
        XCTAssertNil(delta.downloadBytesPerSecond)
        XCTAssertNil(delta.uploadBytesPerSecond)
    }

    func testDeltaComputesBytesPerSecond() {
        let previous = reading(received: 1_000_000, sent: 500_000, mono: 0)
        let current = reading(received: 1_500_000, sent: 700_000, mono: 1)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertEqual(delta.downloadBytesPerSecond ?? 0, 500_000, accuracy: 0.5)
        XCTAssertEqual(delta.uploadBytesPerSecond ?? 0, 200_000, accuracy: 0.5)
        XCTAssertFalse(delta.reset)
    }

    func testDeltaOnInterfaceChangeResets() {
        let previous = reading(interface: "en0", received: 1_000_000, sent: 500_000, mono: 0)
        let current = reading(interface: "en1", type: .ethernet, received: 1_500_000, sent: 700_000, mono: 1)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertTrue(delta.reset)
        XCTAssertTrue(delta.interfaceChanged)
    }

    func testDeltaOnInterfaceTypeChangeResets() {
        // Same name but type changed (Ethernet <-> Wi-Fi); this is what the
        // old `availableInterfaces.first` heuristic could not detect.
        let previous = reading(interface: "en0", type: .wifi, received: 1_000_000, sent: 500_000, mono: 0)
        let current = reading(interface: "en0", type: .ethernet, received: 1_500_000, sent: 700_000, mono: 1)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertTrue(delta.reset)
    }

    func testDeltaRollbackResets() {
        let previous = reading(received: 1_000_000, sent: 500_000, mono: 0)
        let current = reading(received: 999_000, sent: 700_000, mono: 1)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertTrue(delta.reset)
        XCTAssertNil(delta.downloadBytesPerSecond)
    }

    func testDeltaZeroIntervalIsReset() {
        let previous = reading(received: 1_000_000, sent: 500_000, mono: 0)
        let current = reading(received: 1_500_000, sent: 700_000, mono: 0)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertTrue(delta.reset)
    }

    func testDeltaShortIntervalIsReset() {
        // 100 ms is below our 0.5 s floor.
        let previous = reading(received: 1_000_000, sent: 500_000, mono: 0)
        let current = reading(received: 1_500_000, sent: 700_000, mono: 0.1)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertTrue(delta.reset)
    }

    func testDeltaOfflineResets() {
        let previous = reading(received: 1_000_000, sent: 500_000, mono: 0)
        let current = reading(type: .offline, reachable: false, received: 1_500_000, sent: 700_000, mono: 1)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertTrue(delta.reset)
    }

    func testDeltaMissingInterfaceOnBothSidesResetsNotZero() {
        // `nil == nil` must NOT be read as "same interface, proceed" — two
        // readings that both lack a known interface name are "we don't
        // know," not "confirmed unchanged," even if their other fields
        // (type, reachability, counters) line up.
        let previous = NetworkReading(interfaceName: nil, interfaceType: .checking, localIPv4: nil,
                                      isReachable: true, receivedBytes: 100, sentBytes: 50,
                                      timestamp: reference, monotonicSeconds: 0)
        let current = NetworkReading(interfaceName: nil, interfaceType: .checking, localIPv4: nil,
                                     isReachable: true, receivedBytes: 100, sentBytes: 50,
                                     timestamp: reference, monotonicSeconds: 1)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertTrue(delta.reset)
        XCTAssertNil(delta.downloadBytesPerSecond)
    }

    func testDeltaEmptyInterfaceNameResetsNotZero() {
        let previous = reading(interface: "", received: 100, sent: 50, mono: 0)
        let current = reading(interface: "", received: 200, sent: 100, mono: 1)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertTrue(delta.reset)
    }

    func testDeltaInvalidCountersOnEitherSideResetsNotZero() {
        let valid = reading(received: 1_000_000, sent: 500_000, mono: 0)
        let invalidCurrent = NetworkReading(interfaceName: "en0", interfaceType: .wifi, localIPv4: nil,
                                            isReachable: true, receivedBytes: 1_500_000, sentBytes: 700_000,
                                            timestamp: reference, monotonicSeconds: 1, countersValid: false)
        // A read failure on the CURRENT sample must reset, not report 0 B/s.
        let deltaCurrentInvalid = NetworkMath.delta(previous: valid, current: invalidCurrent)
        XCTAssertTrue(deltaCurrentInvalid.reset)
        XCTAssertNil(deltaCurrentInvalid.downloadBytesPerSecond)

        // Recovery needs a NEW baseline: comparing a fresh valid sample
        // against the invalid one as `previous` must still reset — a stale
        // invalid previous cannot be masked by an otherwise-good current
        // sample.
        let recovered = reading(received: 1_512_000, sent: 703_000, mono: 2)
        let deltaPreviousInvalid = NetworkMath.delta(previous: invalidCurrent, current: recovered)
        XCTAssertTrue(deltaPreviousInvalid.reset)

        // Once TWO consecutive valid samples exist again, throughput resumes.
        let nextValid = reading(received: 1_524_000, sent: 706_000, mono: 3)
        let deltaAfterRecovery = NetworkMath.delta(previous: recovered, current: nextValid)
        XCTAssertFalse(deltaAfterRecovery.reset)
        XCTAssertEqual(deltaAfterRecovery.downloadBytesPerSecond ?? 0, 12_000, accuracy: 0.5)
    }

    func testDeltaValidZeroCountersIsIdleNotReset() {
        // Distinct from the invalid case above: two consecutive VALID
        // readings with genuinely unchanged (zero-delta) counters must
        // report 0 B/s, not a reset — "no traffic" and "couldn't read" are
        // different states.
        let previous = reading(received: 500, sent: 200, mono: 0)
        let current = reading(received: 500, sent: 200, mono: 1)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertFalse(delta.reset)
        XCTAssertEqual(delta.downloadBytesPerSecond, 0)
        XCTAssertEqual(delta.uploadBytesPerSecond, 0)
    }

    func testDeltaDoesNotCapAt1GB() {
        // 2.5 GB/s (a Thunderbolt link saturated)
        let previous = reading(received: 0, sent: 0, mono: 0)
        let current = reading(received: 5_000_000_000, sent: 2_500_000_000, mono: 2)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertEqual(delta.downloadBytesPerSecond ?? 0, 2_500_000_000, accuracy: 1)
    }

    func testDeltaHasNoUpperCapEvenAboveTenGB() {
        // A hypothetical >10 GB/s link must not be silently clamped down.
        let previous = reading(received: 0, sent: 0, mono: 0)
        let current = reading(received: 20_000_000_000, sent: 1_000_000_000, mono: 1)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertEqual(delta.downloadBytesPerSecond ?? 0, 20_000_000_000, accuracy: 1)
    }

    func testDeltaLongGapResets() {
        // A >10s gap (missed poll tick, suspended app, or sleep now that the
        // monotonic clock keeps advancing through it) must reset rather than
        // silently averaging a burst across the whole gap.
        let previous = reading(received: 0, sent: 0, mono: 0)
        let current = reading(received: 50_000_000, sent: 10_000_000, mono: 30)
        let delta = NetworkMath.delta(previous: previous, current: current)
        XCTAssertTrue(delta.reset)
        XCTAssertNil(delta.downloadBytesPerSecond)
    }

    func testSharedRouteChangeResetsAcrossConsecutiveSamples() {
        // Simulates the shared coordinator observing a real route change
        // (Wi-Fi -> Ethernet) mid-session: the sample right after the switch
        // must reset instead of computing a delta against the old route's
        // counters, and the reading immediately after that must reflect ONLY
        // the new interface's own counters (never mixed with the old one's).
        let onWifi = reading(interface: "en1", type: .wifi, received: 900_000, sent: 400_000, mono: 0)
        let justSwitched = reading(interface: "en0", type: .ethernet, received: 200, sent: 100, mono: 1)
        let switchDelta = NetworkMath.delta(previous: onWifi, current: justSwitched)
        XCTAssertTrue(switchDelta.reset)
        XCTAssertTrue(switchDelta.interfaceChanged)

        let nextOnEthernet = reading(interface: "en0", type: .ethernet, received: 12_200, sent: 3_100, mono: 2)
        let steadyDelta = NetworkMath.delta(previous: justSwitched, current: nextOnEthernet)
        XCTAssertFalse(steadyDelta.reset)
        XCTAssertEqual(steadyDelta.downloadBytesPerSecond ?? 0, 12_000, accuracy: 0.5)
    }

    func testFormatBytesPerSecond() {
        XCTAssertEqual(NetworkMath.format(bytesPerSecond: 0), "0 B/s")
        XCTAssertEqual(NetworkMath.format(bytesPerSecond: 512), "512 B/s")
        XCTAssertEqual(NetworkMath.format(bytesPerSecond: 1024), "1.0 KB/s")
        XCTAssertEqual(NetworkMath.format(bytesPerSecond: 5_242_880), "5.0 MB/s")
        XCTAssertEqual(NetworkMath.format(bytesPerSecond: nil), "—")
    }

    func testFakeNetworkBackendPlaysScriptInOrderThenAdvancesFromLast() {
        let backend = FakeNetworkBackend(readings: [
            reading(received: 100, sent: 50, mono: 0),
            reading(received: 200, sent: 100, mono: 1)
        ])
        // The scripted sequence must play back IN ORDER, not jump straight
        // to "last scripted value + one tick" on the first call.
        let first = backend.currentReading()
        XCTAssertEqual(first.receivedBytes, 100)
        let second = backend.currentReading()
        XCTAssertEqual(second.receivedBytes, 200)
        // Script exhausted: subsequent calls advance from the single last
        // reading, not from a growing backing array.
        let third = backend.currentReading()
        XCTAssertEqual(third.receivedBytes, 200 + 12_000)
        let fourth = backend.currentReading()
        XCTAssertEqual(fourth.receivedBytes - third.receivedBytes, 12_000)
    }

    func testFakeNetworkBackendPreservesInvalidStateAfterScriptExhausted() {
        // An offline/invalid last reading must not start manufacturing
        // valid traffic once the script runs out.
        let backend = FakeNetworkBackend(readings: [.offline])
        let first = backend.currentReading()
        XCTAssertFalse(first.countersValid)
        let second = backend.currentReading()
        XCTAssertFalse(second.countersValid)
        XCTAssertEqual(second.receivedBytes, 0)
    }

    func testFakeNetworkBackendOffline() {
        let backend = FakeNetworkBackend(readings: [
            NetworkReading(interfaceName: nil, interfaceType: .offline, localIPv4: nil,
                           isReachable: false, receivedBytes: 0, sentBytes: 0,
                           timestamp: reference, monotonicSeconds: 0)
        ])
        let current = backend.currentReading()
        XCTAssertEqual(current.interfaceType, .offline)
        XCTAssertFalse(current.isReachable)
    }
}