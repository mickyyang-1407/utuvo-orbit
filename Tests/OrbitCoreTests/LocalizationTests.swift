import Foundation
import XCTest
@testable import OrbitCore

final class LocalizationTests: XCTestCase {
    func testLanguageResolutionAndExplicitOverride() {
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["zh-TW", "en-US"]), "zh-Hant")
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["en-GB", "zh-Hant"]), "en")
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["fr-FR"]), "en")
        XCTAssertEqual(AppLanguage.english.resolvedIdentifier(preferredLanguages: ["zh-TW"]), "en")
    }

    func testPackagedStringsFormattingAndUnknownValues() {
        let en = OrbitStrings(language: .english)
        let zh = OrbitStrings(language: .traditionalChinese)
        XCTAssertEqual(en("總覽"), "Overview")
        XCTAssertEqual(zh("總覽"), "總覽")
        XCTAssertEqual(en("記憶體 %@ / %@", "8 GB", "16 GB"), "Memory 8 GB / 16 GB")
        XCTAssertEqual(en("電量未知"), "Battery unknown")
        XCTAssertEqual(en("—"), "—")
        XCTAssertEqual(en("24%"), "24%")
        XCTAssertEqual(zh("充電中"), "充電中")
    }

    func testLanguageRoundTripUsesOnlyInjectedPreferences() throws {
        let domain = "fixture.orbit.localization"
        let legacy = OrbitPreferencesStore.legacyDomain
        let inspector = InMemoryDefaultsInspector(initial: [legacy: ["language": "zh-Hant"]])
        let backend = LivePreferencesBackend(inspector: inspector, newDomain: domain, legacyDomain: legacy)
        // A new key is never migrated from the old app's domain.
        XCTAssertEqual(backend.load().language, .system)
        var values = backend.load()
        values.language = .english
        backend.save(values)
        let reopened = LivePreferencesBackend(inspector: inspector, newDomain: domain, legacyDomain: legacy)
        XCTAssertEqual(reopened.load().language, .english)
        XCTAssertEqual(inspector.store[legacy]?["language"] as? String, "zh-Hant")
        XCTAssertTrue(inspector.writesRefused.isEmpty)
        XCTAssertFalse(OrbitPreferencesStore.looksFresh(values))
        let decoded = try JSONDecoder().decode(OrbitPreferencesValues.self, from: JSONEncoder().encode(values))
        XCTAssertEqual(decoded.language, .english)
        for json in ["{}", "{\"language\":\"future\"}"] {
            XCTAssertEqual(try JSONDecoder().decode(OrbitPreferencesValues.self, from: Data(json.utf8)).language, .system)
        }
    }
}
