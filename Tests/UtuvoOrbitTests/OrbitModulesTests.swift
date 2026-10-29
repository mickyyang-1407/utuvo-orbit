import XCTest
@testable import UtuvoOrbit

/// Module switches: off by default, never start while locked, and a locked
/// request goes to the paywall instead of being saved. Uses a throwaway
/// defaults suite; the clothesline is never started (no monitors/hotkeys).
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

    func testLockedRequestOpensPaywallAndIsNotSaved() {
        let modules = OrbitModules(defaults: defaults, language: "en", libraryRoot: root)
        var locked = 0
        modules.isAllowed = { false }
        modules.onLocked = { locked += 1 }
        modules.setEnabled(.shelf, true)
        XCTAssertEqual(locked, 1)
        XCTAssertFalse(modules.shelfEnabled)
        XCTAssertFalse(defaults.bool(forKey: OrbitModules.enabledKey(.shelf)))
        XCTAssertFalse(modules.shelf.isRunning)
    }

    func testShelfFollowsSwitchAndEntitlement() {
        let modules = OrbitModules(defaults: defaults, language: "en", libraryRoot: root)
        var allowed = true
        modules.isAllowed = { allowed }
        modules.setEnabled(.shelf, true)
        XCTAssertTrue(modules.shelf.isRunning)
        XCTAssertTrue(defaults.bool(forKey: OrbitModules.enabledKey(.shelf)))

        allowed = false          // trial ran out
        modules.apply()
        XCTAssertFalse(modules.shelf.isRunning)
        XCTAssertTrue(modules.shelfEnabled, "the user's choice survives a lock")

        allowed = true           // unlocked
        modules.apply()
        XCTAssertTrue(modules.shelf.isRunning)

        modules.setEnabled(.shelf, false)
        XCTAssertFalse(modules.shelf.isRunning)
        XCTAssertFalse(defaults.bool(forKey: OrbitModules.enabledKey(.shelf)))
    }

    func testDropUserGetsShelfOnceAndCanTurnItOff() {
        let modules = OrbitModules(defaults: defaults, language: "en", libraryRoot: root)
        modules.isAllowed = { false }            // still locked: saved, not started
        modules.adoptDropUser()
        XCTAssertTrue(modules.shelfEnabled)
        XCTAssertFalse(modules.shelf.isRunning)
        modules.isAllowed = { true }
        modules.apply()
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
