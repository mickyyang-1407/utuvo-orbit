import XCTest
@testable import OrbitCore

final class GlyphContentTests: XCTestCase {
    // MARK: CenterContent

    func testNetworkModeAlwaysNetworkRegardlessOfMachine() {
        var s = StatusSnapshot.fixture("laptop")
        XCTAssertEqual(CenterContent.resolve(snapshot: s, desktopRing: .cpu, ringCenter: .network), .network)
        s = StatusSnapshot.fixture("desktop")
        XCTAssertEqual(CenterContent.resolve(snapshot: s, desktopRing: .cpu, ringCenter: .network), .network)
    }

    func testLaptopValidBatteryProducesPercent() {
        let s = StatusSnapshot.fixture("laptop") // battery fraction 0.78
        guard case .percent(let value, let source) = CenterContent.resolve(snapshot: s, desktopRing: .cpu, ringCenter: .percent) else {
            return XCTFail("expected a percent")
        }
        XCTAssertEqual(value, 0.78, accuracy: 0.001)
        XCTAssertEqual(source, .laptopBattery)
    }

    func testChargingLaptopFallsBackToNetworkToPreserveTopSlotBolt() {
        let s = StatusSnapshot.fixture("charging") // laptop, battery.charging == true
        XCTAssertEqual(s.battery?.charging, true)
        XCTAssertEqual(CenterContent.resolve(snapshot: s, desktopRing: .cpu, ringCenter: .percent), .network)
    }

    func testDesktopCPUProducesPercentOnlyWhenRingIsCPU() {
        let s = StatusSnapshot.fixture("desktop") // cpu 0.24
        guard case .percent(let value, let source) = CenterContent.resolve(snapshot: s, desktopRing: .cpu, ringCenter: .percent) else {
            return XCTFail("expected a percent")
        }
        XCTAssertEqual(value, 0.24, accuracy: 0.001)
        XCTAssertEqual(source, .desktopCPU)
    }

    func testDesktopPowerNeverFabricatesHundredPercent() {
        // .power's ringFraction is a synthetic 1 (a full decorative arc) —
        // must NOT surface as "100%".
        let s = StatusSnapshot.fixture("desktop")
        XCTAssertEqual(s.ringFraction(desktop: .power), 1)
        XCTAssertEqual(CenterContent.resolve(snapshot: s, desktopRing: .power, ringCenter: .percent), .network)
    }

    func testDesktopHiddenFallsBackToNetwork() {
        let s = StatusSnapshot.fixture("desktop")
        XCTAssertEqual(CenterContent.resolve(snapshot: s, desktopRing: .hidden, ringCenter: .percent), .network)
    }

    func testUnknownMachineFallsBackToNetwork() {
        let s = StatusSnapshot.fixture("unknown")
        XCTAssertEqual(CenterContent.resolve(snapshot: s, desktopRing: .cpu, ringCenter: .percent), .network)
    }

    // MARK: Repair1 section A regressions (root's value-probe)

    func testOutOfRangeCPUIsRejectedNotClamped() {
        var s = StatusSnapshot.fixture("desktop")
        s.cpu = -0.01
        XCTAssertEqual(CenterContent.resolve(snapshot: s, desktopRing: .cpu, ringCenter: .percent), .network,
                       "a slightly-negative CPU must be rejected, not clamped into a fake 0%")
        s.cpu = 1.01
        XCTAssertEqual(CenterContent.resolve(snapshot: s, desktopRing: .cpu, ringCenter: .percent), .network,
                       "a slightly-over-1 CPU must be rejected, not clamped into a fake 100%")
    }

    func testOutOfRangeBatteryIsRejectedNotClamped() {
        var s = StatusSnapshot.fixture("laptop")
        s.battery?.fraction = -0.01
        XCTAssertEqual(CenterContent.resolve(snapshot: s, desktopRing: .cpu, ringCenter: .percent), .network)
        s.battery?.fraction = 1.01
        XCTAssertEqual(CenterContent.resolve(snapshot: s, desktopRing: .cpu, ringCenter: .percent), .network)
    }

    func testNegativeBatteryNeverTriggersLowBattery() {
        var s = StatusSnapshot.fixture("laptop")
        s.battery?.fraction = -0.01
        XCTAssertFalse(AttentionAnalysis.reasons(snapshot: s).contains(.lowBattery),
                       "an invalid negative fraction must not be treated as '<=10%' just because -0.01 <= 0.10 is arithmetically true")
    }

    func testOutOfRangeBatteryAboveOneNeverTriggersLowBattery() {
        var s = StatusSnapshot.fixture("laptop")
        s.battery?.fraction = 1.01
        XCTAssertFalse(AttentionAnalysis.reasons(snapshot: s).contains(.lowBattery))
    }

    func testNonFiniteOrMissingValuesFallBackToNetwork() {
        var laptop = StatusSnapshot.fixture("laptop")
        laptop.battery = nil
        XCTAssertEqual(CenterContent.resolve(snapshot: laptop, desktopRing: .cpu, ringCenter: .percent), .network)

        var desktop = StatusSnapshot.fixture("desktop")
        desktop.cpu = .nan
        XCTAssertEqual(CenterContent.resolve(snapshot: desktop, desktopRing: .cpu, ringCenter: .percent), .network)
        desktop.cpu = .infinity
        XCTAssertEqual(CenterContent.resolve(snapshot: desktop, desktopRing: .cpu, ringCenter: .percent), .network)
    }

    func testValidZeroAndOneAreNotTreatedAsMissing() {
        var laptop = StatusSnapshot.fixture("laptop")
        laptop.battery = BatteryReading(current: 0, maximum: 100, charging: false, onAC: false)
        guard case .percent(let zero, _) = CenterContent.resolve(snapshot: laptop, desktopRing: .cpu, ringCenter: .percent) else {
            return XCTFail("valid 0% must still resolve to a percent")
        }
        XCTAssertEqual(zero, 0)

        laptop.battery = BatteryReading(current: 100, maximum: 100, charging: false, onAC: false)
        guard case .percent(let hundred, _) = CenterContent.resolve(snapshot: laptop, desktopRing: .cpu, ringCenter: .percent) else {
            return XCTFail("valid 100% must still resolve to a percent")
        }
        XCTAssertEqual(hundred, 1)
    }

    // MARK: AttentionAnalysis

    func testCheckingIsNotOffline() {
        var s = StatusSnapshot.fixture("desktop")
        s.connection = .checking
        XCTAssertFalse(AttentionAnalysis.reasons(snapshot: s).contains(.offline))
    }

    func testExplicitOfflineIsAReason() {
        let s = StatusSnapshot.fixture("offline")
        XCTAssertTrue(AttentionAnalysis.reasons(snapshot: s).contains(.offline))
    }

    func testLowBatteryThresholdAndACRules() {
        var s = StatusSnapshot.fixture("laptop")
        s.battery = BatteryReading(current: 10, maximum: 100, charging: false, onAC: false)
        XCTAssertTrue(AttentionAnalysis.reasons(snapshot: s).contains(.lowBattery), "exactly 10% must trigger")

        s.battery = BatteryReading(current: 11, maximum: 100, charging: false, onAC: false)
        XCTAssertFalse(AttentionAnalysis.reasons(snapshot: s).contains(.lowBattery), "above 10% must not")

        s.battery = BatteryReading(current: 5, maximum: 100, charging: true, onAC: true)
        XCTAssertFalse(AttentionAnalysis.reasons(snapshot: s).contains(.lowBattery), "charging must not trigger even at 5%")

        s.battery = BatteryReading(current: 5, maximum: 100, charging: false, onAC: true)
        XCTAssertFalse(AttentionAnalysis.reasons(snapshot: s).contains(.lowBattery), "on AC but not charging (topped off) must not trigger")

        s.machine = .desktop
        s.battery = BatteryReading(current: 1, maximum: 100, charging: false, onAC: false)
        XCTAssertFalse(AttentionAnalysis.reasons(snapshot: s).contains(.lowBattery), "desktop never reports low battery")
    }

    func testNoAudioOutputOnlyOnExplicitFalse() {
        var s = StatusSnapshot.fixture("desktop")
        s.hasAudioOutput = nil
        XCTAssertFalse(AttentionAnalysis.reasons(snapshot: s).contains(.noAudioOutput), "nil (still reading) is not a failure")
        s.hasAudioOutput = true
        s.volume = nil // device-controlled volume
        XCTAssertFalse(AttentionAnalysis.reasons(snapshot: s).contains(.noAudioOutput))
        s.muted = true // user mute
        XCTAssertFalse(AttentionAnalysis.reasons(snapshot: s).contains(.noAudioOutput), "user mute is not a device failure")
        s.hasAudioOutput = false
        XCTAssertTrue(AttentionAnalysis.reasons(snapshot: s).contains(.noAudioOutput))
    }

    func testIsDegradedMatchesReasonsEmptiness() {
        let healthy = StatusSnapshot.fixture("desktop")
        XCTAssertFalse(AttentionAnalysis.isDegraded(snapshot: healthy))
        let unhealthy = StatusSnapshot.fixture("offline")
        XCTAssertTrue(AttentionAnalysis.isDegraded(snapshot: unhealthy))
    }

    func testMultipleReasonsCanCoexist() {
        var s = StatusSnapshot.fixture("laptop")
        s.connection = .offline
        s.battery = BatteryReading(current: 5, maximum: 100, charging: false, onAC: false)
        s.hasAudioOutput = false
        let reasons = AttentionAnalysis.reasons(snapshot: s)
        XCTAssertEqual(Set(reasons), Set([.offline, .lowBattery, .noAudioOutput]))
    }
}
