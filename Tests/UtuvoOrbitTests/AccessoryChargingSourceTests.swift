import XCTest
@testable import UtuvoOrbit

// MARK: - ORBIT-004 C
//
// All XML below is hand-authored SYNTHETIC fixture data (fake identifiers,
// fake capacities) — never copied from any real captured device output —
// per the evidence doc's "fixtures anonymized synthetic XML only" rule.

final class AccessoryChargingSourceTests: XCTestCase {
    private func plist(identifier: String, isChargingXML: String, isPresentXML: String = "<true/>") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Accessory Identifier</key>
        \t<string>\(identifier)</string>
        \t<key>Current Capacity</key>
        \t<integer>50</integer>
        \t<key>Is Charging</key>
        \t\(isChargingXML)
        \t<key>Is Present</key>
        \t\(isPresentXML)
        \t<key>Max Capacity</key>
        \t<integer>100</integer>
        \t<key>Type</key>
        \t<string>Accessory Source</string>
        </dict>
        </plist>
        """
    }

    // MARK: Parser — boolean type strictness

    func testParsesGenuineCFBooleanTrue() {
        let xml = plist(identifier: "AA:BB:CC:DD:EE:01", isChargingXML: "<true/>")
        let records = AccessoryChargingParser.parseAccessories(Data(xml.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].isCharging, true)
    }

    func testParsesGenuineCFBooleanFalse() {
        let xml = plist(identifier: "AA:BB:CC:DD:EE:02", isChargingXML: "<false/>")
        let records = AccessoryChargingParser.parseAccessories(Data(xml.utf8))
        XCTAssertEqual(records[0].isCharging, false)
    }

    func testMissingIsChargingKeyIsNil() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
        \t<key>Accessory Identifier</key>
        \t<string>AA:BB:CC:DD:EE:03</string>
        \t<key>Is Present</key>
        \t<true/>
        \t<key>Type</key>
        \t<string>Accessory Source</string>
        </dict>
        </plist>
        """
        let records = AccessoryChargingParser.parseAccessories(Data(xml.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].isCharging)
    }

    // MARK: Parser — Type filter (native QA correction)

    func testMissingTypeKeyIsNotRecordedAtAll() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
        \t<key>Accessory Identifier</key>
        \t<string>AA:BB:CC:DD:EE:09</string>
        \t<key>Is Present</key>
        \t<true/>
        \t<key>Is Charging</key>
        \t<true/>
        </dict>
        </plist>
        """
        XCTAssertTrue(AccessoryChargingParser.parseAccessories(Data(xml.utf8)).isEmpty,
                     "an entry with no Type at all must never become a charging-match candidate")
    }

    func testWrongTypeValueIsNotRecordedAtAll() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
        \t<key>Accessory Identifier</key>
        \t<string>AA:BB:CC:DD:EE:10</string>
        \t<key>Is Present</key>
        \t<true/>
        \t<key>Is Charging</key>
        \t<true/>
        \t<key>Type</key>
        \t<string>Internal Battery</string>
        </dict>
        </plist>
        """
        XCTAssertTrue(AccessoryChargingParser.parseAccessories(Data(xml.utf8)).isEmpty,
                     "only Type == 'Accessory Source' may ever become a charging-match candidate")
    }

    // MARK: normalize — MAC-shaped vs arbitrary serial (native QA correction)

    func testMACShapedIdentifierNormalizesCaseAndSeparator() {
        XCTAssertEqual(AccessoryChargingParser.normalize("AA:BB:CC:DD:EE:FF"),
                       AccessoryChargingParser.normalize("aa-bb-cc-dd-ee-ff"))
    }

    func testArbitrarySerialIsExactTrimmedOnly() {
        XCTAssertNotEqual(AccessoryChargingParser.normalize("A-B"), AccessoryChargingParser.normalize("AB"),
                          "an arbitrary (non-MAC-shaped) serial's punctuation is significant — A-B must not collide with AB")
    }

    func testArbitrarySerialIsCaseSensitive() {
        XCTAssertNotEqual(AccessoryChargingParser.normalize("AbC123"), AccessoryChargingParser.normalize("abc123"),
                          "root: prefer EXACT trimmed serial string matching for arbitrary (non-MAC-shaped) serials")
    }

    func testArbitrarySerialTrimsWhitespaceOnly() {
        XCTAssertEqual(AccessoryChargingParser.normalize("  ABC123  "), AccessoryChargingParser.normalize("ABC123"))
    }

    func testSevenGroupsIsNotMACShaped() {
        XCTAssertFalse(AccessoryChargingParser.isMACShaped("AA:BB:CC:DD:EE:FF:00"))
    }

    func testNonHexGroupIsNotMACShaped() {
        XCTAssertFalse(AccessoryChargingParser.isMACShaped("ZZ:BB:CC:DD:EE:FF"))
    }

    func testIntegerOneIsRejectedNotTrue() {
        // Root's proven case: a legacy alias entry reports `Is Charging`
        // as an INTEGER, not a CFBoolean — must never read as charging.
        let xml = plist(identifier: "Legacy Alias 1", isChargingXML: "<integer>1</integer>")
        let records = AccessoryChargingParser.parseAccessories(Data(xml.utf8))
        XCTAssertNil(records[0].isCharging, "an integer 1 must be rejected, not coerced into true")
    }

    func testStringTrueIsRejectedNotTrue() {
        let xml = plist(identifier: "AA:BB:CC:DD:EE:04", isChargingXML: "<string>true</string>")
        let records = AccessoryChargingParser.parseAccessories(Data(xml.utf8))
        XCTAssertNil(records[0].isCharging)
    }

    func testIsPresentFalseIsCapturedDistinctFromMissing() {
        let xml = plist(identifier: "AA:BB:CC:DD:EE:05", isChargingXML: "<true/>", isPresentXML: "<false/>")
        let records = AccessoryChargingParser.parseAccessories(Data(xml.utf8))
        XCTAssertEqual(records[0].isPresent, false)
    }

    // MARK: Parser — concatenated documents + malformed spans

    func testParsesMultipleConcatenatedDocuments() {
        let xml = plist(identifier: "AA:BB:CC:DD:EE:06", isChargingXML: "<true/>")
            + plist(identifier: "AA:BB:CC:DD:EE:07", isChargingXML: "<false/>")
        let records = AccessoryChargingParser.parseAccessories(Data(xml.utf8))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.identifier)), Set([
            AccessoryChargingParser.normalize("AA:BB:CC:DD:EE:06"),
            AccessoryChargingParser.normalize("AA:BB:CC:DD:EE:07")
        ]))
    }

    func testMalformedSpanIsSkippedNotFatal() {
        let malformed = "<plist version=\"1.0\">\n<dict><key>Accessory Identifier</key><string>Broken\n"
        let good = plist(identifier: "AA:BB:CC:DD:EE:08", isChargingXML: "<true/>")
        let records = AccessoryChargingParser.parseAccessories(Data((malformed + good).utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].identifier, AccessoryChargingParser.normalize("AA:BB:CC:DD:EE:08"))
    }

    func testEmptyDataReturnsNoRecords() {
        XCTAssertTrue(AccessoryChargingParser.parseAccessories(Data()).isEmpty)
    }

    // MARK: Matcher — exact identity, ambiguity, presence

    func testExactNormalizedMatchResolvesCharging() {
        let records = [AccessoryChargingRecord(identifier: AccessoryChargingParser.normalize("AA:BB:CC:DD:EE:FF"), isPresent: true, isCharging: true)]
        XCTAssertEqual(AccessoryChargingMatcher.resolve(candidateTokens: ["aa-bb-cc-dd-ee-ff"], records: records), .charging)
    }

    func testExactNormalizedMatchResolvesNotCharging() {
        let records = [AccessoryChargingRecord(identifier: AccessoryChargingParser.normalize("AA:BB:CC:DD:EE:FF"), isPresent: true, isCharging: false)]
        XCTAssertEqual(AccessoryChargingMatcher.resolve(candidateTokens: ["AA:BB:CC:DD:EE:FF"], records: records), .notCharging)
    }

    func testNoCandidateTokensIsUnknown() {
        let records = [AccessoryChargingRecord(identifier: AccessoryChargingParser.normalize("AA:BB:CC:DD:EE:FF"), isPresent: true, isCharging: true)]
        XCTAssertEqual(AccessoryChargingMatcher.resolve(candidateTokens: [], records: records), .unknown)
    }

    func testMismatchSameProductDifferentIdentifierIsUnknown() {
        // A same-name/product legacy alias with a DIFFERENT identifier must
        // never match — identity only, never name/model.
        let records = [AccessoryChargingRecord(identifier: AccessoryChargingParser.normalize("LEGACY-ALIAS-XYZ"), isPresent: true, isCharging: true)]
        XCTAssertEqual(AccessoryChargingMatcher.resolve(candidateTokens: ["AA:BB:CC:DD:EE:FF"], records: records), .unknown)
    }

    func testDuplicateAmbiguousIdentifiersResolveUnknown() {
        let token = "AA:BB:CC:DD:EE:FF"
        let records = [
            AccessoryChargingRecord(identifier: AccessoryChargingParser.normalize(token), isPresent: true, isCharging: true),
            AccessoryChargingRecord(identifier: AccessoryChargingParser.normalize(token), isPresent: true, isCharging: false)
        ]
        XCTAssertEqual(AccessoryChargingMatcher.resolve(candidateTokens: [token], records: records), .unknown,
                       "conflicting duplicate identifiers must never be resolved by picking either one")
    }

    func testNotPresentIsUnknownEvenWithChargingValue() {
        let records = [AccessoryChargingRecord(identifier: AccessoryChargingParser.normalize("AA:BB:CC:DD:EE:FF"), isPresent: false, isCharging: true)]
        XCTAssertEqual(AccessoryChargingMatcher.resolve(candidateTokens: ["AA:BB:CC:DD:EE:FF"], records: records), .unknown)
    }

    func testMissingIsChargingIsUnknownEvenWhenPresent() {
        let records = [AccessoryChargingRecord(identifier: AccessoryChargingParser.normalize("AA:BB:CC:DD:EE:FF"), isPresent: true, isCharging: nil)]
        XCTAssertEqual(AccessoryChargingMatcher.resolve(candidateTokens: ["AA:BB:CC:DD:EE:FF"], records: records), .unknown)
    }
}

// MARK: - Executor output collector (pure value contract; no process)
//
// Truncated output must never be parsed as if complete, so the collector
// has to report a drop on the chunk that STRADDLES the cap, not only on
// chunks arriving at an already-full buffer.

final class AccessoryChargingCollectorTests: XCTestCase {
    private func append(_ count: Int, into data: inout Data, cap: Int) -> Bool {
        PMSetAccessoryChargingExecutor.appendBounded(Data(repeating: 0x41, count: count), into: &data, maxBytes: cap)
    }

    func testChunkWellWithinCapacityIsAppendedWhole() {
        var data = Data()
        XCTAssertFalse(append(10, into: &data, cap: 100))
        XCTAssertEqual(data.count, 10)
    }

    func testChunkExactlyFillingCapacityIsNotAnOverflow() {
        var data = Data(repeating: 0x41, count: 90)
        XCTAssertFalse(append(10, into: &data, cap: 100), "nothing was dropped, so this is not a truncation")
        XCTAssertEqual(data.count, 100)
    }

    func testChunkStraddlingTheCapIsFlaggedNotSilentlyTruncated() {
        var data = Data(repeating: 0x41, count: 90)
        XCTAssertTrue(append(25, into: &data, cap: 100), "the straddling chunk must report the drop")
        XCTAssertEqual(data.count, 100, "and must still stop exactly at the cap")
    }

    func testChunkArrivingAtAFullBufferIsFlagged() {
        var data = Data(repeating: 0x41, count: 100)
        XCTAssertTrue(append(1, into: &data, cap: 100))
        XCTAssertEqual(data.count, 100)
    }

    func testEmptyChunkAtAFullBufferDropsNothing() {
        var data = Data(repeating: 0x41, count: 100)
        XCTAssertFalse(append(0, into: &data, cap: 100))
        XCTAssertEqual(data.count, 100)
    }

    func testFirstOversizeChunkOnAnEmptyBufferIsFlagged() {
        var data = Data()
        XCTAssertTrue(append(150, into: &data, cap: 100))
        XCTAssertEqual(data.count, 100)
    }
}

// MARK: - LivePeripheralBackend charging reads. The backend keeps NO cache
// and NO throttle of its own (scheduling belongs to the coordinator alone):
// every read must hit the executor and report what it says right now, and a
// failed read must report nothing rather than an older value. Uses
// `currentChargingRecords()` directly (not `currentPeripherals()`, which
// needs real IOKit matching) with a fake executor — no live subprocess.

final class LivePeripheralBackendChargingReadTests: XCTestCase {
    private final class FakeExecutor: AccessoryChargingExecutor, @unchecked Sendable {
        private(set) var callCount = 0
        var result: Data?
        func run(timeout: TimeInterval) -> Data? { callCount += 1; return result }
    }

    private func plist(identifier: String, isCharging: Bool) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
        \t<key>Accessory Identifier</key>
        \t<string>\(identifier)</string>
        \t<key>Is Present</key>
        \t<true/>
        \t<key>Is Charging</key>
        \t<\(isCharging ? "true" : "false")/>
        \t<key>Type</key>
        \t<string>Accessory Source</string>
        </dict>
        </plist>
        """.utf8)
    }

    func testFirstReadFetchesImmediatelyNotEmptyPlaceholder() {
        // The exact defect `--diagnose` hit: a fresh backend must not
        // return an empty/stale placeholder on its very first call.
        let executor = FakeExecutor()
        executor.result = plist(identifier: "AA:BB:CC:DD:EE:FF", isCharging: true)
        let backend = LivePeripheralBackend(chargingExecutor: executor)
        let records = backend.currentChargingRecords()
        XCTAssertEqual(executor.callCount, 1, "the very first read must actually invoke the executor, not defer it")
        XCTAssertEqual(records.first?.isCharging, true)
    }

    func testEveryReadIsFreshRegardlessOfHowSoonItFollowsTheLastOne() {
        // The coordinator decides WHEN to sample (~30s, forced on wake); a
        // second throttle here made a forced wake refresh return pre-sleep
        // records.
        let executor = FakeExecutor()
        executor.result = plist(identifier: "AA:BB:CC:DD:EE:FF", isCharging: true)
        let backend = LivePeripheralBackend(chargingExecutor: executor)
        XCTAssertEqual(backend.currentChargingRecords().first?.isCharging, true)
        executor.result = plist(identifier: "AA:BB:CC:DD:EE:FF", isCharging: false)
        let second = backend.currentChargingRecords()
        XCTAssertEqual(executor.callCount, 2, "an immediately following read must still invoke the executor")
        XCTAssertEqual(second.first?.isCharging, false, "the second read must report the CURRENT value, not a cached one")
    }

    func testSourceFailureYieldsNoRecordsRatherThanAnOlderValue() {
        let executor = FakeExecutor()
        executor.result = plist(identifier: "AA:BB:CC:DD:EE:FF", isCharging: true)
        let backend = LivePeripheralBackend(chargingExecutor: executor)
        XCTAssertEqual(backend.currentChargingRecords().first?.isCharging, true)
        executor.result = nil // simulated timeout/failure
        XCTAssertTrue(backend.currentChargingRecords().isEmpty,
                      "a source failure must report no charging, never repeat an old value")
    }
}
