import XCTest
@testable import UtuvoOrbit
import OrbitCore

// In-panel display preferences use fake backends and no timers.

@MainActor
final class InlineSettingsTests: XCTestCase {
    private func makeModel(tab: OrbitPanelModel.Tab = .overview) -> (OrbitPanelModel, SystemMonitor) {
        let metrics = SystemMetrics(cpuUsage: 0.2, cpuHistory: [], usedBytes: nil, totalBytes: nil,
                                    battery: nil, machine: .desktop, model: "Mac15,14")
        let evidence = HardwareEvidence(model: "Mac15,14", hasInternalBattery: false, hasLid: false)
        let system = FakeSystemBackend(metrics: metrics, evidence: evidence)
        let network = FakeNetworkBackend(readings: [])
        let audio = FakeAudioBackend(state: .unknown)
        let monitor = SystemMonitor(fixture: nil, systemBackend: system, networkBackend: network,
                                    audioBackend: audio, enableLiveObservers: false)
        let preferences = OrbitPreferencesModel(backend: FakePreferencesBackend(initial: .init(), legacy: nil))
        let model = OrbitPanelModel(monitor: monitor, preferences: preferences, audioBackend: audio,
                                    networkBackend: network, systemBackend: system,
                                    awakeBackend: FakeAwakeBackend(), preview: true,
                                    initialTab: tab, enableAwakeTimer: false)
        return (model, monitor)
    }

    func testDisplayChangesPreserveTheSelectedStatusTab() {
        let (model, monitor) = makeModel(tab: .network)
        model.setShowPercent(true)
        model.setGlyphStyle(.classic)
        model.setTheme(.dark)
        XCTAssertEqual(model.tab, .network)
        model.stop(); monitor.stop()
    }
}
