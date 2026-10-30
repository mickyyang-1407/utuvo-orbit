import XCTest
@testable import UtuvoOrbit

/// Orbit is free in every build: there is no purchase, no trial, no
/// entitlement and no account. These tests only check the small metadata
/// helper that the Mac App Store build still needs, and the legacy UTUVO Drop
/// adoption marker. Nothing here touches StoreKit, the group container or any
/// live state.
final class OrbitMASStoreTests: XCTestCase {
    func testTheAppNameIsStable() {
        #if MAS
        XCTAssertEqual(OrbitMAS.appName, "UTUVO Orbit")
        #endif
    }

    func testTheTaglineFollowsTheSystemLanguage() {
        #if MAS
        XCTAssertTrue(OrbitMAS.tagline(preferredLanguages: ["zh-Hant"]).contains("選單列"))
        XCTAssertTrue(OrbitMAS.tagline(preferredLanguages: ["en-US"]).contains("menu bar"))
        #endif
    }

    /// The build is free: the metadata helper only carries the app name, the
    /// tagline and the local QA arguments. A source scan in
    /// `Tests/UtuvoOrbitTests/FreeDistributionTests.swift` guards this.
    func testTheMetadataHelperStaysSmall() {
        #if MAS
        XCTAssertEqual(OrbitMAS.appName, "UTUVO Orbit")
        #endif
    }
}
