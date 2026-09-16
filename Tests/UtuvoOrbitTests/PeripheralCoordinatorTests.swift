import XCTest
@testable import UtuvoOrbit
import OrbitCore

// MARK: - Peripheral throttling/wake tests
//
// Isolated: `enableLiveObservers: false` (no real Timer/OS observer), an
// injected monotonic clock closure (no real sleep/wait), and a
// `FakePeripheralBackend`/`SpyPeripheralBackend` (no live IOKit reads).
//
// ORBIT-004 C native QA correction: the actual peripheral read now runs on
// a detached (off-main-actor) `Task` — see `SystemMonitor
// .refreshPeripheralsIfDue` — so every test that triggers a refresh must
// `await monitor.peripheralRefreshTask?.value` before asserting on
// `monitor.peripherals`/`peripheralReadStatus`. Awaiting an already-settled
// task (e.g. when the throttle skipped a NEW fetch) is a harmless no-op.

@MainActor
final class PeripheralCoordinatorTests: XCTestCase {
    private final class SpyPeripheralBackend: PeripheralBackend, @unchecked Sendable {
        private(set) var callCount = 0
        var peripherals: [Peripheral] = []
        var status = PeripheralReadStatus(available: true)
        func currentPeripherals() -> [Peripheral] { callCount += 1; return peripherals }
        func readStatus() -> PeripheralReadStatus { status }
    }

    private func makeMonitor(peripheralBackend: PeripheralBackend, clock: @escaping () -> Double) -> SystemMonitor {
        let metrics = SystemMetrics(cpuUsage: 0.1, cpuHistory: [], usedBytes: nil, totalBytes: nil, battery: nil, machine: .desktop, model: "Mac15,14")
        let evidence = HardwareEvidence(model: "Mac15,14", hasInternalBattery: false, hasLid: false)
        return SystemMonitor(fixture: nil,
                            systemBackend: FakeSystemBackend(metrics: metrics, evidence: evidence),
                            networkBackend: FakeNetworkBackend(readings: []),
                            audioBackend: FakeAudioBackend(state: .unknown),
                            peripheralBackend: peripheralBackend,
                            enableLiveObservers: false,
                            monotonicNow: clock)
    }

    func testPollsOnceOnConstructionThenThrottles() async {
        let spy = SpyPeripheralBackend()
        var now: Double = 0
        let monitor = makeMonitor(peripheralBackend: spy, clock: { now })
        await monitor.peripheralRefreshTask?.value
        XCTAssertEqual(spy.callCount, 1, "construction must poll once")
        now += 5 // well under the 30s default interval
        monitor.refresh()
        await monitor.peripheralRefreshTask?.value
        XCTAssertEqual(spy.callCount, 1, "a refresh before the interval elapses must not re-poll peripherals")
        monitor.stop()
    }

    func testPollsAgainOnceIntervalElapses() async {
        let spy = SpyPeripheralBackend()
        var now: Double = 0
        let monitor = makeMonitor(peripheralBackend: spy, clock: { now })
        await monitor.peripheralRefreshTask?.value
        XCTAssertEqual(spy.callCount, 1)
        now += 31
        monitor.refresh()
        await monitor.peripheralRefreshTask?.value
        XCTAssertEqual(spy.callCount, 2, "a refresh after the interval elapses must re-poll")
        monitor.stop()
    }

    func testWakeForcesImmediateRefreshRegardlessOfThrottle() async {
        let spy = SpyPeripheralBackend()
        var now: Double = 0
        let monitor = makeMonitor(peripheralBackend: spy, clock: { now })
        await monitor.peripheralRefreshTask?.value
        XCTAssertEqual(spy.callCount, 1)
        now += 1 // nowhere near the interval
        monitor.handleWake()
        await monitor.peripheralRefreshTask?.value
        XCTAssertEqual(spy.callCount, 2, "wake must force a peripheral refresh even inside the throttle window")
        monitor.stop()
    }

    func testPublishedListIsDedupedAndSorted() async {
        let spy = SpyPeripheralBackend()
        spy.peripherals = [
            Peripheral(id: "b", name: "Trackpad", kind: .trackpad, fraction: 0.88, charging: .unknown, source: "test"),
            Peripheral(id: "a", name: "Keyboard", kind: .keyboard, fraction: 0.15, charging: .unknown, source: "test")
        ]
        let monitor = makeMonitor(peripheralBackend: spy, clock: { 0 })
        await monitor.peripheralRefreshTask?.value
        XCTAssertEqual(monitor.peripherals.map(\.id), ["a", "b"], "ascending by fraction, matching PeripheralList.dedupedSorted")
        monitor.stop()
    }

    // MARK: Repair2 verification gap — loss/recovery must clear the old
    // list AND propagate `readStatus`, without any real IOKit failure or
    // environment manipulation (the ticket explicitly says this isn't
    // required — a fake backend reporting `available: false` is enough).

    func testPeripheralLossClearsListAndPropagatesErrorStatus() async {
        let spy = SpyPeripheralBackend()
        spy.peripherals = [Peripheral(id: "a", name: "Trackpad", kind: .trackpad, fraction: 0.5, charging: .unknown, source: "test")]
        var now: Double = 0
        let monitor = makeMonitor(peripheralBackend: spy, clock: { now })
        await monitor.peripheralRefreshTask?.value
        XCTAssertEqual(monitor.peripherals.count, 1)
        XCTAssertTrue(monitor.peripheralReadStatus.available)
        now += 31
        spy.peripherals = []
        spy.status = PeripheralReadStatus(available: false, errorNote: "source failed")
        monitor.refresh()
        await monitor.peripheralRefreshTask?.value
        XCTAssertTrue(monitor.peripherals.isEmpty, "a stale list must not survive a failed re-read")
        XCTAssertFalse(monitor.peripheralReadStatus.available)
        XCTAssertEqual(monitor.peripheralReadStatus.errorNote, "source failed")
        monitor.stop()
    }

    func testPeripheralRecoveryRestoresListAndAvailableStatus() async {
        let spy = SpyPeripheralBackend()
        spy.status = PeripheralReadStatus(available: false, errorNote: "source failed")
        var now: Double = 0
        let monitor = makeMonitor(peripheralBackend: spy, clock: { now })
        await monitor.peripheralRefreshTask?.value
        XCTAssertTrue(monitor.peripherals.isEmpty)
        XCTAssertFalse(monitor.peripheralReadStatus.available)
        now += 31
        spy.peripherals = [Peripheral(id: "a", name: "Trackpad", kind: .trackpad, fraction: 0.5, charging: .unknown, source: "test")]
        spy.status = PeripheralReadStatus(available: true)
        monitor.refresh()
        await monitor.peripheralRefreshTask?.value
        XCTAssertEqual(monitor.peripherals.count, 1, "recovery must repopulate the list")
        XCTAssertTrue(monitor.peripheralReadStatus.available)
        XCTAssertNil(monitor.peripheralReadStatus.errorNote)
        monitor.stop()
    }

    func testEmptyButAvailableIsATruthfulDisconnectNotAnError() async {
        let spy = SpyPeripheralBackend()
        spy.peripherals = [Peripheral(id: "a", name: "Trackpad", kind: .trackpad, fraction: 0.5, charging: .unknown, source: "test")]
        var now: Double = 0
        let monitor = makeMonitor(peripheralBackend: spy, clock: { now })
        await monitor.peripheralRefreshTask?.value
        XCTAssertEqual(monitor.peripherals.count, 1)
        now += 31
        spy.peripherals = [] // genuinely unplugged, not a source failure
        monitor.refresh()
        await monitor.peripheralRefreshTask?.value
        XCTAssertTrue(monitor.peripherals.isEmpty)
        XCTAssertTrue(monitor.peripheralReadStatus.available, "an empty list with available==true must read as 'nothing connected', not a failure")
        XCTAssertNil(monitor.peripheralReadStatus.errorNote)
        monitor.stop()
    }

    // MARK: Overlapping reads — ordering, not timing. The gate makes the
    // FIRST read finish last deterministically; no sleeps, no real clock,
    // no IOKit.

    private final class LatchedPeripheralBackend: PeripheralBackend, @unchecked Sendable {
        private let lock = NSLock()
        private let responses: [[Peripheral]]
        private var started = 0
        /// Called (off the main actor) the moment the first read begins, so
        /// a test can resume exactly there instead of waiting on time.
        var onFirstReadEntered: (@Sendable () -> Void)?
        let releaseFirstRead = DispatchSemaphore(value: 0)
        init(responses: [[Peripheral]]) { self.responses = responses }
        var startedReads: Int { lock.lock(); defer { lock.unlock() }; return started }
        func currentPeripherals() -> [Peripheral] {
            lock.lock(); let index = started; started += 1; lock.unlock()
            if index == 0 {
                onFirstReadEntered?()
                _ = releaseFirstRead.wait(timeout: .now() + 5)
            }
            return responses[min(index, responses.count - 1)]
        }
        func readStatus() -> PeripheralReadStatus { PeripheralReadStatus(available: true) }
    }

    private func peripheral(_ id: String) -> Peripheral {
        Peripheral(id: id, name: id, kind: .keyboard, fraction: 0.5, charging: .unknown, source: "test")
    }

    /// Builds a monitor and returns once its first (latched) read is
    /// actually running — construction has to happen inside, so the
    /// callback is installed before the read can start.
    private func makeMonitorWithFirstReadRunning(_ backend: LatchedPeripheralBackend,
                                                 clock: @escaping () -> Double) async -> SystemMonitor {
        var monitor: SystemMonitor!
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            backend.onFirstReadEntered = { continuation.resume() }
            monitor = makeMonitor(peripheralBackend: backend, clock: clock)
        }
        return monitor
    }

    func testOlderSlowReadCannotOverwriteANewerResult() async {
        let backend = LatchedPeripheralBackend(responses: [[peripheral("old")], [peripheral("new")]])
        let monitor = await makeMonitorWithFirstReadRunning(backend, clock: { 0 })
        let firstTask = monitor.peripheralRefreshTask
        monitor.handleWake() // forced second read while the first is still running
        await monitor.peripheralRefreshTask?.value
        XCTAssertEqual(monitor.peripherals.map(\.id), ["new"])
        backend.releaseFirstRead.signal()
        await firstTask?.value
        XCTAssertEqual(monitor.peripherals.map(\.id), ["new"],
                       "the earlier read finishing later must not overwrite the newer result")
        monitor.stop()
    }

    func testScheduledTickDoesNotStartASecondConcurrentRead() async {
        let backend = LatchedPeripheralBackend(responses: [[peripheral("a")], [peripheral("b")]])
        var now: Double = 0
        let monitor = await makeMonitorWithFirstReadRunning(backend, clock: { now })
        let firstTask = monitor.peripheralRefreshTask
        now += 31 // interval elapsed, but the first read is still running
        monitor.refresh()
        XCTAssertEqual(backend.startedReads, 1, "a scheduled tick must not stack a second read on an in-flight one")
        backend.releaseFirstRead.signal()
        await firstTask?.value
        XCTAssertEqual(monitor.peripherals.map(\.id), ["a"])
        monitor.stop()
    }

    func testStopDiscardsAnInFlightRead() async {
        let backend = LatchedPeripheralBackend(responses: [[peripheral("a")]])
        let monitor = await makeMonitorWithFirstReadRunning(backend, clock: { 0 })
        let firstTask = monitor.peripheralRefreshTask
        monitor.stop()
        backend.releaseFirstRead.signal()
        await firstTask?.value
        XCTAssertTrue(monitor.peripherals.isEmpty, "a read still running at stop() must not publish afterwards")
    }

    func testNoPeripheralBackendPublishesEmptyNeverCrashes() {
        let metrics = SystemMetrics(cpuUsage: 0.1, cpuHistory: [], usedBytes: nil, totalBytes: nil, battery: nil, machine: .desktop, model: "Mac15,14")
        let evidence = HardwareEvidence(model: "Mac15,14", hasInternalBattery: false, hasLid: false)
        let monitor = SystemMonitor(fixture: nil,
                                    systemBackend: FakeSystemBackend(metrics: metrics, evidence: evidence),
                                    networkBackend: FakeNetworkBackend(readings: []),
                                    audioBackend: FakeAudioBackend(state: .unknown),
                                    enableLiveObservers: false)
        XCTAssertTrue(monitor.peripherals.isEmpty)
        monitor.stop()
    }
}
