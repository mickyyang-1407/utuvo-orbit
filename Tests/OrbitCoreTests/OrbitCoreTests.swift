import XCTest
@testable import OrbitCore

final class OrbitCoreTests: XCTestCase {
    // Value-only fixtures: this target does not link the executable or any live monitor.
    func testMacBookOnACStillLaptop() {
        let evidence = HardwareEvidence(model: "Mac16,5", hasInternalBattery: true, hasLid: true)
        XCTAssertEqual(evidence.kind, .laptop)
        var s = StatusSnapshot(); s.machine = evidence.kind
        s.battery = BatteryReading(current: 80, maximum: 100, charging: false, onAC: true)
        XCTAssertEqual(s.ringFraction(desktop: .cpu), 0.8)
    }
    func testClamshellAndMissingBatteryDoNotBecomeDesktop() {
        XCTAssertEqual(HardwareEvidence(model: "Mac16,5", hasInternalBattery: false, hasLid: true).kind, .laptop)
        XCTAssertEqual(HardwareEvidence(model: "MacBookPro18,3", hasInternalBattery: false, hasLid: false,
                                       powerReadSucceeded: false).kind, .laptop)
    }
    func testDesktopWithExternalUPSIsStillDesktop() {
        let power = PowerTelemetry.internalBattery(in: [["Type": "UPS", "Current Capacity": 90, "Max Capacity": 100]])
        XCTAssertFalse(power.present); XCTAssertNil(power.reading)
        XCTAssertEqual(HardwareEvidence(model: "Mac15,14", hasInternalBattery: power.present, hasLid: false).kind, .desktop)
        XCTAssertEqual(HardwareEvidence(model: "iMac20,1", hasInternalBattery: false, hasLid: false).kind, .desktop)
    }
    func testInternalBatterySelectedAfterUPS() {
        let power = PowerTelemetry.internalBattery(in: [
            ["Type": "UPS", "Current Capacity": 90, "Max Capacity": 100],
            ["Type": "InternalBattery", "Current Capacity": 40, "Max Capacity": 80, "Is Present": true,
             "Power Source State": "AC Power", "Is Charging": false]
        ])
        XCTAssertTrue(power.present); XCTAssertEqual(power.reading?.fraction, 0.5)
        XCTAssertEqual(power.reading?.onAC, true)
        let missing = PowerTelemetry.internalBattery(in: [["Type": "InternalBattery", "Is Present": false]])
        XCTAssertTrue(missing.present); XCTAssertNil(missing.reading)
    }
    func testFailedReadsAndVirtualMachinesAreUnknown() {
        XCTAssertEqual(HardwareEvidence(model: "Mac16,5", hasInternalBattery: false, hasLid: false,
                                       powerReadSucceeded: false).kind, .unknown)
        XCTAssertEqual(HardwareEvidence(model: "Mac16,5", hasInternalBattery: false, hasLid: false,
                                       registryReadSucceeded: false).kind, .unknown)
        XCTAssertEqual(HardwareEvidence(model: "VirtualMac2,1", hasInternalBattery: false, hasLid: false).kind, .unknown)
    }
    func testInvalidCapacityStaysUnknown() {
        for values: (Double?, Double?) in [(50, 0), (-1, 100), (nil, 100), (50, nil), (.nan, 100)] {
            XCTAssertNil(BatteryReading(current: values.0, maximum: values.1, charging: false, onAC: false).fraction)
        }
        XCTAssertEqual(BatteryReading(current: 150, maximum: 100, charging: false, onAC: false).fraction, 1)
        XCTAssertEqual(BatteryReading(current: 2250, maximum: 4500, charging: false, onAC: false).fraction, 0.5)
    }
    func testDesktopRingModesDoNotShowFakeBattery() {
        let desktop = StatusSnapshot.fixture("desktop")
        XCTAssertNil(desktop.battery)
        XCTAssertEqual(desktop.ringFraction(desktop: .cpu), 0.24)
        XCTAssertEqual(desktop.ringFraction(desktop: .power), 1)
        XCTAssertNil(desktop.ringFraction(desktop: .hidden))
        XCTAssertNil(StatusSnapshot.fixture("unknown").ringFraction(desktop: .power))
    }
    func testVolumeLevelsMuteAndUnknownOutput() {
        var s = StatusSnapshot()
        XCTAssertEqual(s.volumeLabel, "讀取中")
        s.hasAudioOutput = false; XCTAssertEqual(s.volumeLabel, "無輸出")
        s.hasAudioOutput = true
        XCTAssertNil(s.volumeDots); XCTAssertEqual(s.volumeLabel, "由裝置控制")
        for (volume, dots) in [(0.0, 0), (0.01, 1), (0.25, 1), (0.26, 2), (0.5, 2), (0.75, 3), (1, 4)] {
            s.volume = volume; XCTAssertEqual(s.volumeDots, dots)
        }
        s.muted = true; XCTAssertEqual(s.volumeDots, 0); XCTAssertEqual(s.volumeLabel, "靜音")
    }
    func testCPUUsesIntervalNotLifetimeAndHandlesReset() {
        XCTAssertEqual(CPUTicks(busy: 180, idle: 920).usage(since: CPUTicks(busy: 100, idle: 900)), 0.8)
        XCTAssertNil(CPUTicks(busy: 100, idle: 900).usage(since: CPUTicks(busy: 100, idle: 900)))
        XCTAssertNil(CPUTicks(busy: 0, idle: 10).usage(since: CPUTicks(busy: 100, idle: 900)))
    }
    func testSignalDoesNotInventReadings() {
        XCTAssertNil(StatusSnapshot.signalLevel(rssi: 0))
        XCTAssertEqual(StatusSnapshot.signalLevel(rssi: -50), 3)
        XCTAssertEqual(StatusSnapshot.signalLevel(rssi: -70), 2)
        XCTAssertEqual(StatusSnapshot.signalLevel(rssi: -85), 1)
    }
    func testChargingAndLowBatteryFixtures() {
        XCTAssertEqual(StatusSnapshot.fixture("charging").battery?.charging, true)
        XCTAssertEqual(StatusSnapshot.fixture("low").batteryLabel, "12%")
        XCTAssertEqual(StatusSnapshot.fixture("low").connection, .offline)
        XCTAssertEqual(StatusSnapshot.fixture("external").volumeLabel, "由裝置控制")
    }
}
