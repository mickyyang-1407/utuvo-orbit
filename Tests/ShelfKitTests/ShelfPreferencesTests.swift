import AppKit
import Testing
@testable import ShelfKit

@Suite(.serialized) @MainActor struct ShelfPreferencesTests {
    private func event(_ type: NSEvent.EventType, at screenPoint: NSPoint, in window: NSWindow,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screenPoint),
            modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
    }
    @Test func tailMovementAndLanguagePersistWithoutChangingFiles() throws {
        _ = NSApplication.shared
        let suite = "drop-preferences-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("My original.txt")
        let bytes = Data("untouched reference".utf8); try bytes.write(to: file)
        let settings = DropSettings(defaults: defaults)
        let controller = ShelfWindowController(settings: settings)
        let window = try #require(controller.window)
        defer { window.orderOut(nil) }
        controller.viewModel.insert([file]); controller.reload()
        controller.content.tuckAwayIfIdle(animated: false)
        let before = controller.petOrigin
        let start = NSPoint(x: before.x + 105, y: before.y + 70)
        let end = NSPoint(x: start.x - 120, y: start.y - 30)
        var fileDrags = 0
        controller.content.startSession = { _, _ in fileDrags += 1 }
        controller.content.tail.mouseDown(with: try event(.leftMouseDown, at: start, in: window))
        controller.content.tail.mouseDragged(with: try event(.leftMouseDragged, at: end, in: window))
        controller.content.tail.mouseUp(with: try event(.leftMouseUp, at: end, in: window))
        #expect(controller.petOrigin == NSPoint(x: before.x - 120, y: before.y - 30))
        #expect(fileDrags == 0)
        #expect(controller.viewModel.allItems.count == 1)
        #expect(!controller.content.isExpanded, "a completed move must not become a click")
        controller.content.setDetailsVisible(true)
        controller.changeLanguage(.english)
        #expect(controller.content.clearButton.title == "Clear")
        #expect(controller.content.dragAllHandle.title == "Take all files")
        #expect(controller.content.rowsByURL[file]?.nameLabel.stringValue == "My original.txt")
        #expect(controller.content.isExpanded)
        let restoredSettings = DropSettings(defaults: defaults)
        let restored = ShelfWindowController(settings: restoredSettings)
        defer { restored.window?.orderOut(nil) }
        #expect(restoredSettings.language == .english)
        #expect(restored.petOrigin == controller.petOrigin)
        #expect(restored.viewModel.isEmpty, "preferences persist, file references do not")
        controller.changeLanguage(.traditionalChinese)
        #expect(controller.content.clearButton.title == "清空")
        #expect(try Data(contentsOf: file) == bytes)
    }
    @Test func optionDragMovesFullCatWhileNormalDragStillExports() throws {
        _ = NSApplication.shared
        let controller = ShelfWindowController()
        let window = try #require(controller.window)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-option-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { window.orderOut(nil); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt"); try Data("fixture".utf8).write(to: file)
        controller.viewModel.insert([file]); controller.reload()
        controller.content.setDetailsVisible(true)
        let before = controller.petOrigin
        let start = NSPoint(x: before.x + 64, y: before.y + 80)
        let end = NSPoint(x: start.x - 80, y: start.y - 25)
        var exports = 0
        controller.content.startSession = { _, _ in exports += 1; controller.content.completeDrag(operation: []) }
        let cat = controller.content.cat
        cat.mouseDown(with: try event(.leftMouseDown, at: start, in: window, modifiers: .option))
        cat.mouseDragged(with: try event(.leftMouseDragged, at: end, in: window, modifiers: .option))
        cat.mouseUp(with: try event(.leftMouseUp, at: end, in: window, modifiers: .option))
        #expect(exports == 0)
        #expect(controller.petOrigin == NSPoint(x: before.x - 80, y: before.y - 25))
        cat.mouseDown(with: try event(.leftMouseDown, at: end, in: window))
        cat.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: end.x + 12, y: end.y), in: window))
        #expect(exports == 1)
        #expect(controller.viewModel.allItems.count == 1)
    }
    @Test func bubbleFitsAboveAndBelowWithoutDisplacingPet() {
        let visible = NSRect(x: -1920, y: -900, width: 1920, height: 880)
        for origin in [NSPoint(x: -500, y: -880), NSPoint(x: -1800, y: -175)] {
            let result = ShelfPlacement.make(origin: origin, visible: visible, expanded: true, count: 3, onLeft: false)
            #expect(visible.contains(result.frame))
            #expect(result.frame.minX + result.petOffsetX == origin.x)
            let actualY = result.bubbleAbove ? result.frame.minY : result.frame.maxY - ShelfLayout.collapsedHeight
            #expect(actualY == origin.y)
            #expect(result.bubbleAbove == (origin.y < visible.midY))
        }
        let screens = [visible, NSRect(x: 100, y: 0, width: 1440, height: 900)]
        #expect(ShelfPlacement.screenIndex(for: NSPoint(x: -800, y: -500), frames: screens) == 0)
        #expect(ShelfPlacement.screenIndex(for: NSPoint(x: 600, y: 500), frames: screens) == 1)
        let recovered = ShelfPlacement.clamp(NSPoint(x: -20000, y: 20000), to: screens[1])
        #expect(recovered == NSPoint(x: 100, y: 756))
    }
    @Test func languageRefreshIncludesFileStatusAndKeepsNames() throws {
        _ = NSApplication.shared
        let controller = ShelfWindowController()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID()).txt")
        controller.viewModel.insert([missing]); controller.reload()
        _ = controller.content.draggingItems(for: [missing])
        controller.changeLanguage(.english)
        #expect(controller.content.errorMessage == "Missing or unreadable file — cannot drag")
        #expect(controller.content.rowsByURL[missing]?.metaLabel.stringValue == "Missing — remove or re-drop")
        controller.changeLanguage(.traditionalChinese)
        #expect(controller.content.errorMessage == "檔案遺失或無法讀取，不能拖出")
        #expect(controller.content.rowsByURL[missing]?.nameLabel.stringValue == missing.lastPathComponent)
        #expect(DropLanguage.system.resolved(preferred: ["en-US"]) == .english)
        #expect(DropLanguage.system.resolved(preferred: ["zh-TW"]) == .traditionalChinese)
    }
}
