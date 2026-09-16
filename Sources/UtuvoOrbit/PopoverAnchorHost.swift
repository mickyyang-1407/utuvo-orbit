import AppKit

// MARK: - PopoverAnchorHost
//
// A popover is automatically moved when its positioning view moves or
// resizes, and the status item does both (combined/classic, showPercent,
// digit count) — root measured 17–44pt jumps. Compensating through
// `positioningRect` did not hold it either. So the popover is anchored to
// something that simply does not move: a borderless, non-activating,
// fully transparent window parked at the status button's screen rect for
// as long as the popover is open. The status item is then free to resize
// without touching the popover, and no window frame is ever written.
//
// It draws nothing, takes no mouse events, and cannot become key or main,
// so it is invisible to the user and never steals focus. It is ordered out
// when the popover closes and re-positioned to the CURRENT status item on
// every open.

@MainActor
final class PopoverAnchorHost {
    /// What should happen to an anchored popover when the screen layout
    /// changes — pure so it can be tested without windows or displays.
    enum ScreenChangeAction: Equatable {
        /// Nothing is anchored; the host is put away.
        case hide
        /// Anchored, but the status item no longer has a usable on-screen
        /// position: close rather than leave the host stranded off-screen.
        case close
        case reposition(NSRect)
    }

    static func screenChangeAction(isPopoverShown: Bool,
                                   buttonScreenRect: NSRect?,
                                   screens: [NSRect]) -> ScreenChangeAction {
        guard isPopoverShown else { return .hide }
        guard let rect = buttonScreenRect, rect.width > 0, rect.height > 0,
              screens.contains(where: { $0.intersects(rect) }) else { return .close }
        return .reposition(rect)
    }

    private var panel: NSPanel?

    /// Parks the host at `rect` and returns the view to show the popover
    /// relative to. Ordered in without activating the app.
    func anchorView(at rect: NSRect) -> NSView? {
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.setFrame(rect, display: false)
        panel.orderFrontRegardless()
        return panel.contentView
    }

    func reposition(to rect: NSRect) {
        panel?.setFrame(rect, display: false)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    /// `internal` so a test can assert the invisible/non-interactive
    /// contract on the real window object without ever ordering it in.
    static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        // Same level as the status bar the anchor stands in for, so the
        // popover orders exactly as it did when anchored to the button.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Empty, layer-free view: the anchor needs geometry, not pixels.
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        return panel
    }
}
