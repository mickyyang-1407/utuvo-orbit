import XCTest
import AppKit
@testable import UtuvoOrbit

// MARK: - Popover anchor host
//
// Replaces the obsolete positioningRect geometry tests: width compensation
// is gone, the popover is anchored to a stationary host window instead.
// Value fixtures only — the pure screen-change decision. The host window's
// own contract (no opaque ghost, no click interception, window count 0
// after Escape) is root's native QA, not a unit test.

@MainActor
final class PopoverAnchorHostTests: XCTestCase {
    private let mainScreen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private let secondScreen = NSRect(x: 1920, y: 0, width: 1920, height: 1080)
    private let buttonRect = NSRect(x: 1800, y: 1058, width: 27, height: 22)

    private func action(shown: Bool, rect: NSRect?, screens: [NSRect]? = nil) -> PopoverAnchorHost.ScreenChangeAction {
        PopoverAnchorHost.screenChangeAction(isPopoverShown: shown, buttonScreenRect: rect,
                                             screens: screens ?? [mainScreen, secondScreen])
    }

    func testClosedPopoverJustPutsTheHostAway() {
        XCTAssertEqual(action(shown: false, rect: buttonRect), .hide)
    }

    func testOpenPopoverRepositionsToTheCurrentStatusItem() {
        XCTAssertEqual(action(shown: true, rect: buttonRect), .reposition(buttonRect))
    }

    func testStatusItemOnASecondaryScreenIsStillAValidAnchor() {
        let onSecond = NSRect(x: 3700, y: 1058, width: 27, height: 22)
        XCTAssertEqual(action(shown: true, rect: onSecond), .reposition(onSecond))
    }

    func testAnchorNoLongerOnAnyScreenClosesRatherThanStranding() {
        // The display the menu bar was on has gone away.
        let orphaned = NSRect(x: 5000, y: 2400, width: 27, height: 22)
        XCTAssertEqual(action(shown: true, rect: orphaned, screens: [mainScreen]), .close)
    }

    func testMissingOrEmptyButtonRectCloses() {
        XCTAssertEqual(action(shown: true, rect: nil), .close)
        XCTAssertEqual(action(shown: true, rect: NSRect(x: 1800, y: 1058, width: 0, height: 0)), .close)
    }

    func testNoScreensAtAllCloses() {
        XCTAssertEqual(action(shown: true, rect: buttonRect, screens: []), .close)
    }
}
