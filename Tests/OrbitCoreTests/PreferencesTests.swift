import XCTest
@testable import OrbitCore

final class PreferencesTests: XCTestCase {
    // MARK: Repair1 section A regression — decoder must never throw on an
    // unrecognised raw enum string, for ANY enum field (old or new).

    func testDecodeFallsBackSafelyOnInvalidNewEnumValues() throws {
        let json = #"{"ringCenter":"future-value","glyphStyle":"future-value"}"#.data(using: .utf8)!
        let values = try JSONDecoder().decode(OrbitPreferencesValues.self, from: json)
        XCTAssertEqual(values.ringCenter, .network)
        XCTAssertEqual(values.glyphStyle, .combined)
    }

    func testDecodeFallsBackSafelyOnInvalidOldEnumValues() throws {
        let json = #"{"desktopRing":"future-ring","theme":"future-theme"}"#.data(using: .utf8)!
        let values = try JSONDecoder().decode(OrbitPreferencesValues.self, from: json)
        XCTAssertEqual(values.desktopRing, .cpu)
        XCTAssertEqual(values.theme, .system)
    }

    func testDecodeMissingKeysAllFallBackToDefaults() throws {
        let values = try JSONDecoder().decode(OrbitPreferencesValues.self, from: "{}".data(using: .utf8)!)
        XCTAssertEqual(values, OrbitPreferencesValues())
    }

    func testDecodePreservesValidValuesAlongsideInvalidOnes() throws {
        let json = #"{"ringCenter":"percent","glyphStyle":"not-a-real-style","colorful":false}"#.data(using: .utf8)!
        let values = try JSONDecoder().decode(OrbitPreferencesValues.self, from: json)
        XCTAssertEqual(values.ringCenter, .percent, "a genuinely valid value must still decode correctly")
        XCTAssertEqual(values.glyphStyle, .combined, "an invalid sibling value must not affect it")
        XCTAssertFalse(values.colorful)
    }

    func testMigrationCopiesThreeKeysWhenFresh() {
        let legacy: [String: Any] = [
            "desktopRing": "power",
            "showPercent": true,
            "colorful": false
        ]
        let merged = OrbitPreferencesStore.migrate(current: OrbitPreferencesValues(),
                                                   legacyDefaults: legacy,
                                                   presenceOf: { _ in false })
        XCTAssertEqual(merged.desktopRing, .power)
        XCTAssertTrue(merged.showPercent)
        XCTAssertFalse(merged.colorful)
    }

    func testMigrationIgnoresUnrecognisedValues() {
        let legacy: [String: Any] = [
            "desktopRing": "unknown_value",
            "showPercent": true,
            "colorful": "not_a_bool"
        ]
        let merged = OrbitPreferencesStore.migrate(current: OrbitPreferencesValues(),
                                                   legacyDefaults: legacy,
                                                   presenceOf: { _ in false })
        XCTAssertEqual(merged.desktopRing, .cpu)
        XCTAssertTrue(merged.showPercent)
        XCTAssertTrue(merged.colorful)
    }

    func testMigrationPreservesAllKeysWhenAllArePresent() {
        // Meaningful replacement for a previous version of this test that
        // gated its only assertions behind `if looksFresh(current)` — since
        // `current` here is deliberately non-default, that condition was
        // always false and the assertions never ran (an always-green test).
        // Real behavior under test: `migrate` is per-key presence gated, so
        // when every key is already present it must leave ALL of them
        // untouched, regardless of what the legacy domain holds or whether
        // the current values "look fresh".
        let current = OrbitPreferencesValues(desktopRing: .hidden, showPercent: true,
                                            colorful: false, theme: .dark, pin: true)
        let legacy: [String: Any] = ["desktopRing": "power", "showPercent": false, "colorful": true]
        let merged = OrbitPreferencesStore.migrate(current: current, legacyDefaults: legacy,
                                                    presenceOf: { _ in true })
        XCTAssertEqual(merged, current, "every already-present key must be preserved untouched")
    }

    func testMigrationSkipsWhenNoLegacy() {
        let merged = OrbitPreferencesStore.migrate(current: OrbitPreferencesValues(),
                                                   legacyDefaults: [:],
                                                   presenceOf: { _ in false })
        XCTAssertEqual(merged, OrbitPreferencesValues())
    }

    func testMigrationPreservesExplicitDefaults() {
        // User has explicitly set desktopRing to "hidden" but showPercent and
        // colorful remain at their defaults. Migration should not overwrite the
        // explicit value, but should still copy the absent keys.
        let legacy: [String: Any] = [
            "desktopRing": "power",
            "showPercent": true,
            "colorful": false
        ]
        let current = OrbitPreferencesValues(desktopRing: .hidden,
                                            showPercent: false, // default
                                            colorful: true,    // default
                                            theme: .system, pin: false)
        let newRaw: [String: Any] = [
            "desktopRing": "hidden"
        ]
        let presence: (String) -> Bool = { key in newRaw[key] != nil }
        let merged = OrbitPreferencesStore.migrate(current: current,
                                                    legacyDefaults: legacy,
                                                    presenceOf: presence)
        XCTAssertEqual(merged.desktopRing, .hidden, "explicit user value must be preserved")
        XCTAssertTrue(merged.showPercent, "absent key migrated")
        XCTAssertFalse(merged.colorful, "absent key migrated")
    }

    func testLivePreferencesBackendMigratesAndSentinelWrites() {
        let inspector = InMemoryDefaultsInspector(initial: [
            OrbitPreferencesStore.legacyDomain: [
                "desktopRing": "power",
                "showPercent": true,
                "colorful": false
            ]
        ])
        let backend = LivePreferencesBackend(inspector: inspector)
        let values = backend.load()
        XCTAssertEqual(values.desktopRing, .power)
        XCTAssertTrue(values.showPercent)
        XCTAssertFalse(values.colorful)
        XCTAssertEqual(inspector.store[OrbitPreferencesStore.newDomain]?[OrbitPreferencesStore.migrationSentinelKey] as? Bool, true)
        let secondLoad = backend.load()
        XCTAssertEqual(secondLoad, values)
    }

    func testInspectorRefusesLegacyWrite() {
        let inspector = InMemoryDefaultsInspector()
        inspector.set("value", forKey: "desktopRing", domain: OrbitPreferencesStore.legacyDomain)
        inspector.removeObject(forKey: "colorful", domain: OrbitPreferencesStore.legacyDomain)
        XCTAssertEqual(inspector.writesRefused.count, 2)
        XCTAssertTrue(inspector.store[OrbitPreferencesStore.legacyDomain]?.isEmpty ?? true)
    }

    func testFakePreferencesBackendMigrates() {
        let backend = FakePreferencesBackend(initial: OrbitPreferencesValues(),
                                              legacy: ["desktopRing": "hidden",
                                                       "showPercent": true,
                                                       "colorful": false])
        let values = backend.load()
        XCTAssertEqual(values.desktopRing, .hidden)
        XCTAssertTrue(values.showPercent)
        XCTAssertFalse(values.colorful)
    }

    func testFakePreferencesBackendPinNeverPersists() {
        let backend = FakePreferencesBackend()
        backend.save(OrbitPreferencesValues(desktopRing: .power, showPercent: true,
                                            colorful: false, theme: .dark, pin: true))
        let reloaded = backend.load()
        XCTAssertTrue(reloaded.pin == false, "pin must reset across load")
        XCTAssertEqual(reloaded.desktopRing, .power)
    }

    func testLivePreferencesBackendSavesAndReloads() {
        let inspector = InMemoryDefaultsInspector()
        let backend = LivePreferencesBackend(inspector: inspector)
        backend.save(OrbitPreferencesValues(desktopRing: .hidden, showPercent: true,
                                            colorful: false, theme: .light, pin: true))
        let reloaded = backend.load()
        XCTAssertEqual(reloaded.desktopRing, .hidden)
        XCTAssertTrue(reloaded.showPercent)
        XCTAssertFalse(reloaded.colorful)
        XCTAssertEqual(reloaded.theme, .light)
        XCTAssertFalse(reloaded.pin, "live backend must also drop pin on load")
        // Inspector should never see a pin write
        XCTAssertFalse(inspector.store[OrbitPreferencesStore.newDomain]?.keys.contains(OrbitPreferencesStore.keys.pin) ?? false)
    }

    func testLivePreferencesBackendMigratesAbsentKeysEvenWhenOneKeyAlreadyCustomized() {
        // Regression: the new domain already has an explicit, non-default
        // showPercent — so `looksFresh` alone would say "not fresh" and skip
        // migration entirely, leaving desktopRing/colorful at code defaults
        // forever instead of picking up the still-absent legacy values.
        let inspector = InMemoryDefaultsInspector(initial: [
            OrbitPreferencesStore.newDomain: ["showPercent": true],
            OrbitPreferencesStore.legacyDomain: ["desktopRing": "power", "colorful": false]
        ])
        let backend = LivePreferencesBackend(inspector: inspector)
        let values = backend.load()
        XCTAssertTrue(values.showPercent, "already-present key must be preserved")
        XCTAssertEqual(values.desktopRing, .power, "absent key must still migrate")
        XCTAssertFalse(values.colorful, "absent key must still migrate")
        XCTAssertEqual(inspector.store[OrbitPreferencesStore.newDomain]?[OrbitPreferencesStore.migrationSentinelKey] as? Bool, true)
    }

    func testLooksFreshIgnoresPin() {
        // pin=true but everything else default => looksFresh stays true.
        let current = OrbitPreferencesValues(desktopRing: .cpu, showPercent: false,
                                            colorful: true, theme: .system, pin: true)
        XCTAssertTrue(OrbitPreferencesStore.looksFresh(current))
    }

    // MARK: LABEL-FINISH — `looksFresh` must actually consider the 0.3
    // additions (`ringCenter`/`glyphStyle`), not just the four original
    // fields; it is a fixture-only exposed predicate, not the live
    // backend's migration gate (that's sentinel-only — see `loadFresh`).

    func testLooksFreshIsFalseWhenRingCenterIsCustomized() {
        let current = OrbitPreferencesValues(ringCenter: .percent)
        XCTAssertFalse(OrbitPreferencesStore.looksFresh(current))
    }

    func testLooksFreshIsFalseWhenGlyphStyleIsCustomized() {
        let current = OrbitPreferencesValues(glyphStyle: .classic)
        XCTAssertFalse(OrbitPreferencesStore.looksFresh(current))
    }

    func testLooksFreshIsTrueWhenAllValuesIncludingNewOnesAreDefault() {
        XCTAssertTrue(OrbitPreferencesStore.looksFresh(OrbitPreferencesValues()))
    }
}