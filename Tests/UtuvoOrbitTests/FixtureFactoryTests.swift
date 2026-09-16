import XCTest
@testable import UtuvoOrbit
import OrbitCore

// MARK: - FixtureFactory honesty tests
//
// Fixtures must not fabricate data the real backends couldn't have
// produced: `.checking`/offline must not claim a reachable interface/IP,
// `unknown` machines must not invent memory/CPU history, and audio must
// expose real per-device capabilities (not the single-device convenience
// path) so output switching is actually exercisable.

@MainActor
final class FixtureFactoryTests: XCTestCase {
    func testCheckingConnectionHasNoReachableInterfaceOrIP() {
        var snapshot = StatusSnapshot.fixture("desktop")
        snapshot.connection = .checking
        let readings = FixtureFactory.networkReadings(for: snapshot)
        XCTAssertEqual(readings.count, 1)
        let reading = readings[0]
        XCTAssertFalse(reading.isReachable)
        XCTAssertNil(reading.interfaceName)
        XCTAssertNil(reading.localIPv4)
        XCTAssertFalse(reading.countersValid)
        XCTAssertEqual(reading.interfaceType, .checking)
    }

    func testOfflineConnectionHasNoReachableInterfaceOrIP() {
        let snapshot = StatusSnapshot.fixture("low") // low battery fixture sets connection = .offline
        let readings = FixtureFactory.networkReadings(for: snapshot)
        XCTAssertEqual(readings.count, 1)
        XCTAssertFalse(readings[0].isReachable)
        XCTAssertNil(readings[0].localIPv4)
        XCTAssertFalse(readings[0].countersValid)
    }

    func testReachableFixtureCountersAreValid() {
        let snapshot = StatusSnapshot.fixture("desktop")
        let readings = FixtureFactory.networkReadings(for: snapshot)
        XCTAssertEqual(readings.count, 12)
        XCTAssertTrue(readings.allSatisfy { $0.countersValid })
        XCTAssertTrue(readings.allSatisfy { $0.localIPv4?.hasPrefix("192.0.2.") == true })
    }

    func testUnknownMachineHasNoInventedSystemMetrics() {
        let snapshot = StatusSnapshot.fixture("unknown")
        let metrics = FixtureFactory.systemMetrics(for: snapshot)
        XCTAssertNil(metrics.cpuUsage)
        XCTAssertNil(metrics.usedBytes)
        XCTAssertNil(metrics.totalBytes)
        XCTAssertTrue(metrics.cpuHistory.isEmpty)
        XCTAssertEqual(metrics.machine, .unknown)
    }

    func testKnownMachineStillGetsSystemMetrics() {
        let snapshot = StatusSnapshot.fixture("desktop")
        let metrics = FixtureFactory.systemMetrics(for: snapshot)
        XCTAssertNotNil(metrics.cpuUsage)
        XCTAssertEqual(metrics.usedBytes, 8 * 1024 * 1024 * 1024)
        XCTAssertFalse(metrics.cpuHistory.isEmpty)
    }

    func testUnknownFixtureHasNoUsableAudioOutput() {
        let snapshot = StatusSnapshot.fixture("unknown")
        let audio = FixtureFactory.makeAudioBackend(for: snapshot)
        let state = audio.current()
        XCTAssertFalse(state.available)
        XCTAssertTrue(state.outputs.isEmpty)
    }

    func testExternalFixtureDefaultsToReadOnlyDigitalOutput() {
        let snapshot = StatusSnapshot.fixture("external")
        let audio = FixtureFactory.makeAudioBackend(for: snapshot)
        let state = audio.current()
        XCTAssertEqual(state.outputs.count, 2, "must expose two real devices, not the single-device convenience path")
        XCTAssertEqual(state.device?.name, snapshot.audioDevice)
        XCTAssertFalse(state.device?.hasWritableVolume ?? true, "the default (digital) output must be read-only")
        // The OTHER device must be a controllable speaker, switchable to.
        guard let speaker = state.outputs.first(where: { $0.id != state.device?.id }) else {
            return XCTFail("expected a second, controllable speaker output")
        }
        XCTAssertTrue(speaker.hasWritableVolume)
        XCTAssertTrue(speaker.hasWritableMute)
    }

    func testNonExternalFixtureDefaultsToControllableSpeakerWithSecondDevice() {
        let snapshot = StatusSnapshot.fixture("desktop")
        let audio = FixtureFactory.makeAudioBackend(for: snapshot)
        let state = audio.current()
        XCTAssertEqual(state.outputs.count, 2)
        XCTAssertTrue(state.device?.hasWritableVolume ?? false)
        XCTAssertTrue(state.device?.hasWritableMute ?? false)
    }

    func testOutputSwitchingThroughActualPanelModelUpdatesReadback() {
        let snapshot = StatusSnapshot.fixture("desktop")
        let audio = FixtureFactory.makeAudioBackend(for: snapshot)
        let initialOutputs = audio.current().outputs
        guard let otherDevice = initialOutputs.first(where: { $0.id != audio.current().device?.id }) else {
            return XCTFail("fixture must expose a second output to switch to")
        }
        let systemBackend = FakeSystemBackend(metrics: FixtureFactory.systemMetrics(for: snapshot),
                                              evidence: FixtureFactory.hardwareEvidence(for: snapshot))
        let networkBackend = FakeNetworkBackend(readings: FixtureFactory.networkReadings(for: snapshot))
        let monitor = SystemMonitor(fixture: snapshot, systemBackend: systemBackend,
                                    networkBackend: networkBackend, audioBackend: audio, enableLiveObservers: false)
        let preferences = OrbitPreferencesModel(backend: FakePreferencesBackend(initial: .init(), legacy: nil))
        let model = OrbitPanelModel(monitor: monitor, preferences: preferences,
                                    audioBackend: audio, networkBackend: networkBackend,
                                    systemBackend: systemBackend, awakeBackend: FakeAwakeBackend(), preview: true,
                                    enableAwakeTimer: false)
        model.selectOutput(otherDevice.id)
        XCTAssertEqual(model.audio.device?.id, otherDevice.id, "panel model must reflect the switched device")
        XCTAssertEqual(monitor.audio.device?.id, otherDevice.id, "shared coordinator must reflect it too (glyph reads from here)")
        XCTAssertEqual(monitor.snapshot.audioDevice, otherDevice.name)
        model.stop(); monitor.stop()
    }

    // MARK: Repair1 section D regression — `resolve` is the ONE place a
    // fixture name maps to (snapshot, preferences, peripherals); previously
    // only the interactive gallery's `FixtureSession` knew "percent-center"/
    // "classic" meant anything beyond a plain (nonexistent) snapshot case,
    // so `--fixture percent-center` from the CLI silently launched with
    // default preferences.

    func testResolvePercentCenterSetsPreferenceAndLaptopSnapshot() {
        let resolved = FixtureFactory.resolve("percent-center")
        XCTAssertEqual(resolved.preferences.ringCenter, .percent)
        XCTAssertEqual(resolved.snapshot.machine, .laptop)
    }

    func testResolveClassicSetsPreferenceAndLaptopSnapshot() {
        let resolved = FixtureFactory.resolve("classic")
        XCTAssertEqual(resolved.preferences.glyphStyle, .classic)
        XCTAssertEqual(resolved.snapshot.machine, .laptop)
    }

    func testResolveUnrelatedNameKeepsDefaultPreferences() {
        let resolved = FixtureFactory.resolve("desktop")
        XCTAssertEqual(resolved.preferences, OrbitPreferencesValues())
        XCTAssertTrue(resolved.peripherals.isEmpty, "only dedicated peripherals-* fixtures ever return non-empty data")
    }

    func testResolveOffilineAndDegradedAlsoHaveNoPeripherals() {
        XCTAssertTrue(FixtureFactory.resolve("offline").peripherals.isEmpty)
        XCTAssertTrue(FixtureFactory.resolve("degraded").peripherals.isEmpty)
        XCTAssertTrue(FixtureFactory.resolve("laptop").peripherals.isEmpty,
                     "root: 'do not inject the same 3 peripherals into every fixture'")
    }

    func testDedicatedPeripheralsFixtureHasExactlyTheThreeNamedDevices() {
        let peripherals = FixtureFactory.resolve("peripherals").peripherals
        XCTAssertEqual(Set(peripherals.map(\.name)), Set(["AirPods Pro", "Magic Keyboard", "Magic Trackpad"]))
        XCTAssertEqual(peripherals.first { $0.name == "AirPods Pro" }?.fraction ?? -1, 0.62, accuracy: 0.001)
        XCTAssertEqual(peripherals.first { $0.name == "Magic Keyboard" }?.fraction ?? -1, 0.15, accuracy: 0.001)
        XCTAssertEqual(peripherals.first { $0.name == "Magic Trackpad" }?.fraction ?? -1, 0.88, accuracy: 0.001)
    }

    func testLongNamesFixtureHasExactlyFourEntries() {
        XCTAssertEqual(FixtureFactory.resolve("peripherals-long-names").peripherals.count, 4)
    }

    func testEmptyPeripheralsFixtureIsGenuinelyEmpty() {
        XCTAssertTrue(FixtureFactory.resolve("peripherals-empty").peripherals.isEmpty)
    }

    func testUnknownPeripheralsFixtureHasNilFraction() {
        let peripherals = FixtureFactory.resolve("peripherals-unknown").peripherals
        XCTAssertFalse(peripherals.isEmpty)
        XCTAssertTrue(peripherals.allSatisfy { $0.fraction == nil })
    }

    func testChargingPeripheralsFixtureIsExplicitlyCharging() {
        let peripherals = FixtureFactory.resolve("peripherals-charging").peripherals
        XCTAssertFalse(peripherals.isEmpty)
        XCTAssertTrue(peripherals.allSatisfy { $0.charging == .charging })
    }
}
