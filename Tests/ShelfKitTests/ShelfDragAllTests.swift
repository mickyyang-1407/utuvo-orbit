import AppKit
import Testing
@testable import ShelfKit

@MainActor @Test func dragAllHandleUsesNativeURLsAndKeepsOriginals() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = ["first.txt", "second.txt"].map { directory.appendingPathComponent($0) }
    let bytes = Data("Owned drag fixture".utf8)
    for file in files { try bytes.write(to: file) }
    let controller = ShelfWindowController()
    controller.viewModel.insert(files)
    controller.reload()
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    var received: [URL] = []
    controller.content.startSession = { items, _ in
        let writers = items.compactMap { $0.item as? NSPasteboardWriting }
        #expect(pasteboard.writeObjects(writers))
        received = PasteboardFileURLReader().readFileURLs(from: pasteboard)
        controller.content.completeDrag(operation: .copy)
    }
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10),
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 20, y: 20),
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    controller.content.dragAllHandle.mouseDown(with: down)
    controller.content.dragAllHandle.mouseDragged(with: drag)
    #expect(received == files.map(ShelfModel.normalize))
    #expect(controller.viewModel.allItems.isEmpty)
    #expect(controller.content.cat.bellyScale == 1)
    #expect(!controller.content.outgoing)
    controller.content.clearShelf()
    for file in files { #expect(try Data(contentsOf: file) == bytes) }
}
