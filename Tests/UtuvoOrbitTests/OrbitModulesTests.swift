import XCTest
@testable import UtuvoOrbit

/// Module switches: off by default, and the user's choice is always honoured
/// — Orbit is free, so there is no purchase, trial or entitlement that could
/// suspend a module.
///
/// Uses a throwaway defaults suite. **These tests start the file shelf**, so
/// they are not part of the daytime filtered run.
@MainActor
final class OrbitModulesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUp() async throws {
        suiteName = "orbit.modules.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-modules-\(UUID())")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testModulesAreOffByDefault() {
        let modules = OrbitModules(defaults: defaults, language: "en", libraryRoot: root)
        modules.apply()
        XCTAssertFalse(modules.shelfEnabled)
        XCTAssertFalse(modules.clotheslineEnabled)
        XCTAssertFalse(modules.shelf.isRunning)
        XCTAssertFalse(modules.clothesline.isRunning)
    }

    func testSwitchingOnIsSavedAndStarted() {
        let modules = OrbitModules(defaults: defaults, language: "en", libraryRoot: root)
        modules.setEnabled(.shelf, true)
        XCTAssertTrue(modules.shelfEnabled)
        XCTAssertTrue(defaults.bool(forKey: OrbitModules.enabledKey(.shelf)))
        XCTAssertTrue(modules.shelf.isRunning)
    }

    func testShelfFollowsTheSwitchOnly() {
        let modules = OrbitModules(defaults: defaults, language: "en", libraryRoot: root)
        modules.setEnabled(.shelf, true)
        XCTAssertTrue(modules.shelf.isRunning)

        modules.setEnabled(.shelf, false)
        XCTAssertFalse(modules.shelf.isRunning)
        XCTAssertFalse(defaults.bool(forKey: OrbitModules.enabledKey(.shelf)))
        XCTAssertFalse(modules.shelfEnabled)
    }

    func testDropUserGetsShelfOnceAndCanTurnItOff() {
        let modules = OrbitModules(defaults: defaults, language: "en", libraryRoot: root)
        modules.adoptDropUser()
        XCTAssertTrue(modules.shelfEnabled)
        XCTAssertTrue(modules.shelf.isRunning)
        modules.setEnabled(.shelf, false)
        modules.adoptDropUser()                  // second launch: must not flip it back on
        XCTAssertFalse(modules.shelfEnabled)
        XCTAssertFalse(modules.shelf.isRunning)
    }

    func testEnabledStateIsRestoredOnRelaunch() {
        defaults.set(true, forKey: OrbitModules.enabledKey(.shelf))
        let modules = OrbitModules(defaults: defaults, language: "zh-Hant", libraryRoot: root)
        XCTAssertTrue(modules.shelfEnabled)
        XCTAssertFalse(modules.clotheslineEnabled)
        modules.apply()
        XCTAssertTrue(modules.shelf.isRunning)
        modules.stopAll()
        XCTAssertFalse(modules.shelf.isRunning)
    }
}
