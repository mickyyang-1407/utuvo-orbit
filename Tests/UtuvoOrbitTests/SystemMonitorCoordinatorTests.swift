import XCTest
@testable import UtuvoOrbit
import OrbitCore

// MARK: - Single-producer coordinator tests
//
// These exercise the ACTUAL production `SystemMonitor`/`OrbitPanelModel`
// (not a helper/mirror of their logic) via injected fake/spy backends —
// fully isolated: every construction below disables the periodic `Timer`,
// the IOPS power-source notification and the `NSWorkspace` wake observer
// (`enableLiveObservers: false`) and the panel's countdown timer
// (`enableAwakeTimer: false`). No real IOPM/CoreAudio/UserDefaults access,
// no OS notification posted to the global center, no timer left running
// after a test returns.

@MainActor
final class SystemMonitorCoordinatorTests: XCTestCase {
    private final class SpySystemBackend: SystemBackend, @unchecked Sendable {
        let inner: FakeSystemBackend
        private(set) var metricsCallCount = 0
        private(set) var resetCallCount = 0
        init(inner: FakeSystemBackend) { self.inner = inner }
        func metrics(historyCapacity: Int) -> SystemMetrics { metricsCallCount += 1; return inner.metrics(historyCapacity: historyCapacity) }
        func modelIdentifier() -> String { inner.modelIdentifier() }
        func hardwareEvidence() -> HardwareEvidence { inner.hardwareEvidence() }
        func reset() { resetCallCount += 1 }
    }

    private final class SpyNetworkBackend: NetworkBackend, @unchecked Sendable {
        let inner: NetworkBackend
        private(set) var readCallCount = 0
        init(inner: NetworkBackend) { self.inner = inner }
        func currentReading() -> NetworkReading { readCallCount += 1; return inner.currentReading() }
    }

    private func makeSystemSpy(machine: MachineKind = .desktop) -> SpySystemBackend {
        let metrics = SystemMetrics(cpuUsage: 0.2, cpuHistory: [], usedBytes: nil, totalBytes: nil, battery: nil, machine: machine, model: "Mac15,14")
        let evidence = HardwareEvidence(model: "Mac15,14", hasInternalBattery: machine == .laptop, hasLid: machine == .laptop)
        return SpySystemBackend(inner: FakeSystemBackend(metrics: metrics, evidence: evidence))
    }

    // MARK: Single producer

    func testConstructionPollsEachBackendExactlyOnce() {
        let systemSpy = makeSystemSpy()
        let networkSpy = SpyNetworkBackend(inner: FakeNetworkBackend(readings: []))
        let monitor = SystemMonitor(fixture: nil, systemBackend: systemSpy, networkBackend: networkSpy,
                                    audioBackend: FakeAudioBackend(state: .unknown), enableLiveObservers: false)
        XCTAssertEqual(systemSpy.metricsCallCount, 1, "constructing the coordinator must read system metrics exactly once")
        XCTAssertEqual(networkSpy.readCallCount, 1, "constructing the coordinator must read the network exactly once")
        monitor.stop()
    }

    func testPanelModelConstructionAndSubscriptionNeverPollsDirectly() {
        let systemSpy = makeSystemSpy()
        let networkSpy = SpyNetworkBackend(inner: FakeNetworkBackend(readings: []))
        let audio = FakeAudioBackend(state: .unknown)
        let monitor = SystemMonitor(fixture: nil, systemBackend: systemSpy, networkBackend: networkSpy,
                                    audioBackend: audio, enableLiveObservers: false)
        XCTAssertEqual(systemSpy.metricsCallCount, 1)
        XCTAssertEqual(networkSpy.readCallCount, 1)

        let preferences = OrbitPreferencesModel(backend: FakePreferencesBackend(initial: .init(), legacy: nil))
        let model = OrbitPanelModel(monitor: monitor, preferences: preferences,
                                    audioBackend: audio, networkBackend: networkSpy,
                                    systemBackend: systemSpy, awakeBackend: FakeAwakeBackend(), preview: true,
                                    enableAwakeTimer: false)
        // Construction (which used to call `.metrics()`/`.currentReading()`
        // itself) and its Combine subscription must not add a second call —
        // the model only ever mirrors what the coordinator already read.
        XCTAssertEqual(systemSpy.metricsCallCount, 1, "OrbitPanelModel construction must not poll system metrics again")
        XCTAssertEqual(networkSpy.readCallCount, 1, "OrbitPanelModel construction must not poll the network again")
        XCTAssertEqual(model.systemMetrics.cpuUsage, monitor.systemMetrics.cpuUsage, "model must mirror the coordinator's value")
        model.stop(); monitor.stop()
    }

    // MARK: Fixture mode is the same producer

    func testFixtureModeRunsSameProducerAudioActionReachesSnapshot() {
        let driver = FakeAudioHALDriver(snapshot: .init(defaultID: 100, devices: [
            100: .init(name: "Speaker", hasSettableVolume: true, currentScalar: 0.3, currentMuted: false)
        ]))
        let audio = AudioBackendImpl(driver: driver)
        let fixture = StatusSnapshot.fixture("laptop")
        let systemBackend = FakeSystemBackend(metrics: FixtureFactory.systemMetrics(for: fixture),
                                              evidence: FixtureFactory.hardwareEvidence(for: fixture))
        let networkBackend = FakeNetworkBackend(readings: FixtureFactory.networkReadings(for: fixture))
        let monitor = SystemMonitor(fixture: fixture, systemBackend: systemBackend,
                                    networkBackend: networkBackend, audioBackend: audio, enableLiveObservers: false)
        XCTAssertEqual(monitor.snapshot.volume ?? -1, 0.3, accuracy: 0.001,
                       "fixture mode must run the same producer, not just re-assign the static fixture forever")
        driver.externallySetScalar(0.9, on: 100)
        monitor.refresh()
        XCTAssertEqual(monitor.snapshot.volume ?? -1, 0.9, accuracy: 0.001,
                       "a fake audio action must reach the coordinator's published snapshot")
        monitor.stop()
    }

    // MARK: Real audio actions through the actual panel model

    func testSetVolumeUpdatesSharedSnapshotImmediatelyWithNoSystemNetworkPoll() {
        let driver = FakeAudioHALDriver(snapshot: .init(defaultID: 100, devices: [
            100: .init(name: "Speaker", hasSettableVolume: true, currentScalar: 0.3, currentMuted: false)
        ]))
        let audio = AudioBackendImpl(driver: driver)
        let systemSpy = makeSystemSpy()
        let networkSpy = SpyNetworkBackend(inner: FakeNetworkBackend(readings: []))
        let monitor = SystemMonitor(fixture: nil, systemBackend: systemSpy, networkBackend: networkSpy,
                                    audioBackend: audio, enableLiveObservers: false)
        let preferences = OrbitPreferencesModel(backend: FakePreferencesBackend(initial: .init(), legacy: nil))
        let model = OrbitPanelModel(monitor: monitor, preferences: preferences,
                                    audioBackend: audio, networkBackend: networkSpy,
                                    systemBackend: systemSpy, awakeBackend: FakeAwakeBackend(), preview: true,
                                    enableAwakeTimer: false)
        let systemCallsBefore = systemSpy.metricsCallCount
        let networkCallsBefore = networkSpy.readCallCount

        model.setVolume(0.77)

        XCTAssertEqual(model.audio.masterVolume ?? -1, 0.77, accuracy: 0.001,
                       "the model's own published audio must reflect the write immediately")
        XCTAssertEqual(monitor.audio.masterVolume ?? -1, 0.77, accuracy: 0.001,
                       "the SAME write must be visible on the shared coordinator, not just locally")
        XCTAssertEqual(monitor.snapshot.volume ?? -1, 0.77, accuracy: 0.001)
        XCTAssertEqual(systemSpy.metricsCallCount, systemCallsBefore, "a volume write must never poll system metrics")
        XCTAssertEqual(networkSpy.readCallCount, networkCallsBefore, "a volume write must never poll the network")
        model.stop(); monitor.stop()
    }

    func testToggleMuteAndSelectOutputUpdateSharedSnapshotWithNoPoll() {
        let speakerID: UInt32 = 100
        let digitalID: UInt32 = 101
        let driver = FakeAudioHALDriver(snapshot: .init(defaultID: speakerID, devices: [
            speakerID: .init(name: "Speaker", hasSettableVolume: true, currentScalar: 0.5, currentMuted: false),
            digitalID: .init(name: "Digital", hasSettableVolume: false, currentScalar: nil, currentMuted: nil)
        ]))
        let audio = AudioBackendImpl(driver: driver)
        let systemSpy = makeSystemSpy()
        let networkSpy = SpyNetworkBackend(inner: FakeNetworkBackend(readings: []))
        let monitor = SystemMonitor(fixture: nil, systemBackend: systemSpy, networkBackend: networkSpy,
                                    audioBackend: audio, enableLiveObservers: false)
        let preferences = OrbitPreferencesModel(backend: FakePreferencesBackend(initial: .init(), legacy: nil))
        let model = OrbitPanelModel(monitor: monitor, preferences: preferences,
                                    audioBackend: audio, networkBackend: networkSpy,
                                    systemBackend: systemSpy, awakeBackend: FakeAwakeBackend(), preview: true,
                                    enableAwakeTimer: false)
        let systemCallsBefore = systemSpy.metricsCallCount
        let networkCallsBefore = networkSpy.readCallCount

        model.toggleMute()
        XCTAssertTrue(model.audio.muted)
        XCTAssertTrue(monitor.audio.muted, "mute toggle must reach the shared coordinator")

        model.selectOutput(digitalID)
        XCTAssertEqual(model.audio.device?.id, digitalID)
        XCTAssertEqual(monitor.audio.device?.id, digitalID, "output switch must reach the shared coordinator")
        XCTAssertEqual(monitor.snapshot.audioDevice, "Digital")

        XCTAssertEqual(systemSpy.metricsCallCount, systemCallsBefore, "audio actions must never poll system metrics")
        XCTAssertEqual(networkSpy.readCallCount, networkCallsBefore, "audio actions must never poll the network")
        model.stop(); monitor.stop()
    }

    // MARK: Wake, via the exposed method — no real OS notification

    func testHandleWakeClearsNetworkBaselineAndHistory() {
        var readings: [NetworkReading] = []
        for i in 0..<4 {
            let received: UInt64 = 1_000_000 + UInt64(i) * 12_000
            let sent: UInt64 = 300_000 + UInt64(i) * 3_000
            let reading = NetworkReading(interfaceName: "en0", interfaceType: .ethernet, localIPv4: nil,
                                         isReachable: true, receivedBytes: received,
                                         sentBytes: sent, timestamp: Date(), monotonicSeconds: Double(i))
            readings.append(reading)
        }
        let networkBackend = FakeNetworkBackend(readings: readings)
        let systemSpy = makeSystemSpy()
        let monitor = SystemMonitor(fixture: nil, systemBackend: systemSpy, networkBackend: networkBackend,
                                    audioBackend: FakeAudioBackend(state: .unknown), enableLiveObservers: false)
        monitor.refresh(); monitor.refresh(); monitor.refresh()
        XCTAssertFalse(monitor.networkHistory.isEmpty, "history should have accumulated real samples before wake")

        // Call the exposed method directly — no real NSWorkspace notification.
        monitor.handleWake()

        XCTAssertTrue(monitor.networkHistory.isEmpty, "wake must clear network history, not just the CPU baseline")
        XCTAssertEqual(systemSpy.resetCallCount, 1, "wake must call the system backend's CPU-baseline reset")
        monitor.stop()
    }

    func testDisabledLiveObserversRegisterNoTimerOrRealObservers() {
        // Best-effort proof of isolation: with observers disabled, a manual
        // `refresh()`/`handleWake()` call is the ONLY way state changes —
        // waiting past the real 2s tick interval must show no extra poll.
        let systemSpy = makeSystemSpy()
        let networkSpy = SpyNetworkBackend(inner: FakeNetworkBackend(readings: []))
        let monitor = SystemMonitor(fixture: nil, systemBackend: systemSpy, networkBackend: networkSpy,
                                    audioBackend: FakeAudioBackend(state: .unknown), enableLiveObservers: false)
        let callsAfterInit = systemSpy.metricsCallCount
        let expectation = expectation(description: "no timer fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 3)
        XCTAssertEqual(systemSpy.metricsCallCount, callsAfterInit, "no Timer should have fired with enableLiveObservers: false")
        monitor.stop()
    }
}
