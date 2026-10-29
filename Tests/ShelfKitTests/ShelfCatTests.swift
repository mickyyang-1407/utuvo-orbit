import AppKit
import Testing
@testable import ShelfKit

@MainActor @Test func catCancelKeepsFilesAndSuccessfulHandoffShrinksOnlyItsBelly() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-cat-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = ["one.txt", "two.txt"].map { root.appendingPathComponent($0) }
    let bytes = Data("Owned cat fixture".utf8)
    for file in files { try bytes.write(to: file) }
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    #expect(pb.writeObjects(files.map { $0 as NSURL }))
    let controller = ShelfWindowController()
    let content = controller.content
    #expect(content.acceptFiles(from: pb))
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    let fullBelly = content.cat.bellyScale
    #expect(fullBelly > 1)
    #expect(content.acceptFiles(from: pb))
    #expect(content.cat.bellyScale == fullBelly, "duplicates do not inflate the cat")
    #expect(content.isExpanded, "an accepted drop opens the thought bubble")
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 60, y: 50), modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    var nativeCount = 0
    content.startSession = { items, _ in
        nativeCount = items.count
        #expect(content.cat.mood == .giving)
        let mouth = content.convert(content.cat.mouthPoint, from: content.cat)
        #expect(items.first?.draggingFrame.midY == mouth.y)
        content.completeDrag(operation: [])
    }
    content.cat.mouseDown(with: down)
    content.cat.mouseDragged(with: drag)
    #expect(nativeCount == 2)
    #expect(content.viewModel.allItems.count == 2)
    #expect(content.cat.bellyScale == fullBelly)
    #expect(content.cat.mood == .idle)
    content.startSession = { _, _ in content.completeDrag(operation: .copy) }
    content.beginDrag(for: [ShelfModel.normalize(files[0])], event: drag)
    #expect(content.viewModel.allItems.map(\.url) == [ShelfModel.normalize(files[1])])
    #expect(content.cat.bellyScale < fullBelly)
    #expect(content.cat.bellyScale > 1)
    for file in files { #expect(try Data(contentsOf: file) == bytes) }
}
