import XCTest
@testable import UtuvoOrbit
import OrbitCore

// MARK: - Repair1 section C regression: the shared pure raw-property parser
//
// Exercises the SAME static functions `LivePeripheralBackend.parse(service:)`
// calls internally — not a separate reimplementation — with synthetic raw
// values. No IOKit involved.

final class LivePeripheralParserTests: XCTestCase {
    private typealias Raw = LivePeripheralBackend.RawPeripheralProperties

    func testMissingProductReturnsNil() {
        let raw = Raw(product: nil, batteryPercent: 50, transport: "USB", usagePage: nil, usage: nil)
        XCTAssertNil(LivePeripheralBackend.parsePure(id: "x", raw: raw))
    }

    func testEmptyProductReturnsNil() {
        let raw = Raw(product: "", batteryPercent: 50, transport: "USB", usagePage: nil, usage: nil)
        XCTAssertNil(LivePeripheralBackend.parsePure(id: "x", raw: raw))
    }

    func testMissingBatteryPercentGivesMissingNote() {
        let raw = Raw(product: "Magic Trackpad", batteryPercent: nil, transport: "USB", usagePage: nil, usage: nil)
        let p = LivePeripheralBackend.parsePure(id: "x", raw: raw)
        XCTAssertNil(p?.fraction)
        XCTAssertEqual(p?.statusNote, "缺少電量欄位")
    }

    func testWrongTypeBatteryPercentGivesTypeNote() {
        let raw = Raw(product: "Magic Trackpad", batteryPercent: "62", transport: "USB", usagePage: nil, usage: nil)
        let p = LivePeripheralBackend.parsePure(id: "x", raw: raw)
        XCTAssertNil(p?.fraction)
        XCTAssertEqual(p?.statusNote, "電量欄位型別錯誤")
    }

    // Proven by root's probe: `(true as Any) as? NSNumber` succeeds with
    // `.doubleValue == 1` — a stray CFBoolean-typed property must not be
    // silently read as "100%"/"0%".
    func testBooleanTrueBatteryPercentIsRejectedNotOneHundredPercent() {
        let raw = Raw(product: "Magic Trackpad", batteryPercent: true, transport: "USB", usagePage: nil, usage: nil)
        let p = LivePeripheralBackend.parsePure(id: "x", raw: raw)
        XCTAssertNil(p?.fraction, "a Boolean true must never become 100%")
        XCTAssertEqual(p?.statusNote, "電量欄位型別錯誤")
    }

    func testBooleanFalseBatteryPercentIsRejectedNotZeroPercent() {
        let raw = Raw(product: "Magic Trackpad", batteryPercent: false, transport: "USB", usagePage: nil, usage: nil)
        let p = LivePeripheralBackend.parsePure(id: "x", raw: raw)
        XCTAssertNil(p?.fraction, "a Boolean false must never become a genuine 0%")
        XCTAssertEqual(p?.statusNote, "電量欄位型別錯誤")
    }

    func testNonFiniteBatteryPercentGivesRangeNote() {
        let raw = Raw(product: "Magic Trackpad", batteryPercent: Double.nan, transport: "USB", usagePage: nil, usage: nil)
        let p = LivePeripheralBackend.parsePure(id: "x", raw: raw)
        XCTAssertNil(p?.fraction)
        XCTAssertEqual(p?.statusNote, "電量數值超出範圍")
    }

    func testOutOfRangeBatteryPercentGivesRangeNote() {
        let raw = Raw(product: "Magic Trackpad", batteryPercent: 140, transport: "USB", usagePage: nil, usage: nil)
        let p = LivePeripheralBackend.parsePure(id: "x", raw: raw)
        XCTAssertNil(p?.fraction, "140% is a corrupt reading, not a clampable near-miss")
        XCTAssertEqual(p?.statusNote, "電量數值超出範圍")
    }

    func testValidBatteryPercentParsesCleanlyWithNoNote() {
        let raw = Raw(product: "Magic Trackpad", batteryPercent: 88, transport: "USB", usagePage: nil, usage: nil)
        let p = LivePeripheralBackend.parsePure(id: "x", raw: raw)
        XCTAssertEqual(p?.fraction ?? -1, 0.88, accuracy: 0.0001)
        XCTAssertNil(p?.statusNote)
    }

    func testChargingIsUnknownWithNoSerialNumberRegardlessOfTransport() {
        // No `SerialNumber` at all means no candidate token to match
        // against pmset — never inferred from USB/Bluetooth transport.
        let raw = Raw(product: "Magic Trackpad", batteryPercent: 88, transport: "USB", usagePage: nil, usage: nil)
        XCTAssertEqual(LivePeripheralBackend.parsePure(id: "x", raw: raw)?.charging, .unknown)
    }

    func testChargingIsUnknownWithSerialButNoMatchingRecord() {
        let raw = Raw(product: "Magic Trackpad", batteryPercent: 88, transport: "USB", usagePage: nil, usage: nil,
                       serialNumber: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(LivePeripheralBackend.parsePure(id: "x", raw: raw, chargingRecords: []).map(\.charging), .unknown)
    }

    func testChargingResolvesTrueOnExactNormalizedSerialMatch() {
        let raw = Raw(product: "Magic Keyboard", batteryPercent: 34, transport: "USB", usagePage: nil, usage: nil,
                       serialNumber: "AA:BB:CC:DD:EE:FF")
        let records = [AccessoryChargingRecord(identifier: AccessoryChargingParser.normalize("aabbccddeeff"), isPresent: true, isCharging: true)]
        XCTAssertEqual(LivePeripheralBackend.parsePure(id: "x", raw: raw, chargingRecords: records)?.charging, .charging)
    }

    func testChargingResolvesFalseOnExactMatchUSBNotCharging() {
        // Root's proof that USB must not be treated as charging: the
        // trackpad is USB-connected but pmset reports Is Charging=false.
        let raw = Raw(product: "Magic Trackpad", batteryPercent: 100, transport: "USB", usagePage: nil, usage: nil,
                       serialNumber: "11:22:33:44:55:66")
        let records = [AccessoryChargingRecord(identifier: AccessoryChargingParser.normalize("112233445566"), isPresent: true, isCharging: false)]
        XCTAssertEqual(LivePeripheralBackend.parsePure(id: "x", raw: raw, chargingRecords: records)?.charging, .notCharging)
    }

    func testChargingNeverLeaksSerialIntoAnyPeripheralField() {
        let raw = Raw(product: "Magic Keyboard", batteryPercent: 34, transport: "USB", usagePage: nil, usage: nil,
                       serialNumber: "AA:BB:CC:DD:EE:FF")
        let records = [AccessoryChargingRecord(identifier: AccessoryChargingParser.normalize("aabbccddeeff"), isPresent: true, isCharging: true)]
        let p = LivePeripheralBackend.parsePure(id: "x", raw: raw, chargingRecords: records)
        XCTAssertFalse((p?.source ?? "").contains("AA:BB:CC:DD:EE:FF"))
        XCTAssertFalse((p?.statusNote ?? "").contains("AA:BB:CC:DD:EE:FF"))
        XCTAssertFalse((p?.name ?? "").contains("AA:BB:CC:DD:EE:FF"))
    }

    func testUnknownVendorUsagePageFallsBackToNameHeuristicNotOther() {
        // This machine's own real devices expose a vendor-specific
        // usagePage 65280 / usage 11 — ambiguous, not absent — so the
        // standard-usage-page check correctly declines it and the name
        // heuristic takes over instead of forcing `.other`.
        let raw = Raw(product: "Micky KB Black Keyboard", batteryPercent: 27, transport: "Bluetooth",
                       usagePage: 65280, usage: 11)
        XCTAssertEqual(LivePeripheralBackend.parsePure(id: "x", raw: raw)?.kind, .keyboard)
    }

    func testStandardUsagePageTakesPriorityOverName() {
        let raw = Raw(product: "Anything", batteryPercent: 50, transport: "USB", usagePage: 0x01, usage: 0x06)
        XCTAssertEqual(LivePeripheralBackend.parsePure(id: "x", raw: raw)?.kind, .keyboard)
    }

    func testBooleanUsagePageIsRejectedNotMisread() {
        let raw = Raw(product: "Something Trackpad", batteryPercent: 50, transport: "USB", usagePage: true, usage: false)
        // A rejected Boolean usagePage must fall through to the name
        // heuristic, not be misread as page 1/0.
        XCTAssertEqual(LivePeripheralBackend.parsePure(id: "x", raw: raw)?.kind, .trackpad)
    }

    func testMissingTransportDefaultsToUnknownString() {
        let raw = Raw(product: "Magic Trackpad", batteryPercent: 50, transport: nil, usagePage: nil, usage: nil)
        XCTAssertEqual(LivePeripheralBackend.parsePure(id: "x", raw: raw)?.source, "AppleDeviceManagementHIDEventService(unknown)")
    }

    // MARK: readStatus() default

    private final class MinimalBackend: PeripheralBackend, @unchecked Sendable {
        func currentPeripherals() -> [Peripheral] { [] }
    }

    func testDefaultReadStatusIsAvailable() {
        XCTAssertEqual(MinimalBackend().readStatus(), PeripheralReadStatus(available: true))
    }
}
