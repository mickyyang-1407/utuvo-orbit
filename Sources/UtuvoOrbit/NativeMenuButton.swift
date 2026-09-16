import AppKit
import SwiftUI

// MARK: - Native menu bridge
//
// SwiftUI's `Menu` draws its own NSPopUpButton bezel and ignores
// `.buttonStyle` — with and without `.menuStyle(.button)`, root's pixels
// still showed a flat grey bezel and a blue indicator next to a glass
// button. So the trigger is an ordinary SwiftUI `Button` (whatever style
// its neighbours use, no exception), and the menu itself is a real
// `NSMenu` popped up through the public
// `NSMenu.popUp(positioning:at:in:)`. Nothing is hand-drawn: checkmarks,
// keyboard navigation and VoiceOver all come from AppKit.

struct NativeMenuEntry {
    let title: String
    let isChecked: Bool
    let action: @MainActor () -> Void
}

@MainActor
final class NativeMenuAnchor: ObservableObject {
    fileprivate weak var view: NSView?
    /// `NSMenuItem.target` is weak — these boxes must outlive the popup.
    private var targets: [MenuItemTarget] = []

    func present(_ entries: [NativeMenuEntry]) {
        guard let view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        targets = entries.map { MenuItemTarget(action: $0.action) }
        var current: NSMenuItem?
        for (entry, target) in zip(entries, targets) {
            let item = NSMenuItem(title: entry.title, action: #selector(MenuItemTarget.fire), keyEquivalent: "")
            item.target = target
            item.isEnabled = true
            item.state = entry.isChecked ? .on : .off
            menu.addItem(item)
            if entry.isChecked { current = item }
        }
        // Drops from the control's top-left with the current choice over
        // it, the way a native popup menu does.
        _ = menu.popUp(positioning: current, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }
}

@MainActor
private final class MenuItemTarget: NSObject {
    private let action: @MainActor () -> Void
    init(action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func fire() { action() }
}

/// Gives `NativeMenuAnchor` a real `NSView` to pop the menu up in. Draws
/// nothing and never takes a mouse event, so the SwiftUI button underneath
/// keeps its own hit testing and appearance.
struct NativeMenuAnchorView: NSViewRepresentable {
    let anchor: NativeMenuAnchor

    func makeNSView(context: Context) -> NSView { PassthroughView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isOpaque: Bool { false }
    }
}
