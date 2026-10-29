import XCTest
#if canImport(AppKit)
import AppKit
@testable import ShelfKit


/// Hermetic AppKit tests: real NSPanel/views in-process, fresh unique pasteboards,
/// temp files only. No global hooks, no other apps, no user files, no real drags.
final class AppKitShelfIntegrationTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = NSApplication.shared
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("utuvo-drop-appkit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    private func makeFile(_ name: String, bytes: Int = 128) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        return url
    }

    private func makePasteboard(_ urls: [URL]) -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        return pb
    }

    private func makeInfo(_ pb: NSPasteboard, source: Any? = nil) -> NSDraggingInfo {
        final class Info: NSObject, NSDraggingInfo {
            let pb: NSPasteboard
            let source: Any?
            init(_ pb: NSPasteboard, source: Any?) { self.pb = pb; self.source = source }
            var draggingDestinationWindow: NSWindow? { nil }
            var draggingSourceOperationMask: NSDragOperation { .copy }
            var draggingLocation: NSPoint { .zero }
            var draggedImageLocation: NSPoint { .zero }
            var draggedImage: NSImage? { nil }
            var draggingSource: Any? { source }
            var draggingSequenceNumber: Int { 0 }
            var draggingPasteboard: NSPasteboard { pb }
            func slideDraggedImage(to: NSPoint) {}
            var draggingFormation: NSDraggingFormation = .none
            var animatesToDestination: Bool = false
            var numberOfValidItemsForDrop: Int = 1
            var springLoadingHighlight: NSSpringLoadingHighlight { .none }
            func resetSpringLoading() {}
            func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for: NSView?,
                                       classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                       using: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        }
        return Info(pb, source: source)
    }

    // 1. Real NSPanel is persistent, non-activating, floating, becomes visible on launch.
    func testPanelPropertiesAndLaunchVisibility() throws {
        let wc = ShelfWindowController(viewModel: ShelfViewModel())
        let panel = try XCTUnwrap(wc.window as? NSPanel)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        wc.showShelf()
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.hidesOnDeactivate)
        panel.orderOut(nil)
    }

    // 2. Panel frame sits inside each attached screen's visibleFrame, both edges.
    func testFrameInsideVisibleFrameOnAttachedScreensAndBothEdges() throws {
        XCTAssertFalse(NSScreen.screens.isEmpty, "GUI test host has a window server")
        for screen in NSScreen.screens {
            for edge in [ShelfLayout.Edge.left, .right] {
                let wc = ShelfWindowController(viewModel: ShelfViewModel())
                if edge == .left { wc.cycleEdge() }
                let visible = screen.visibleFrame
                let frame = ShelfLayout.frame(in: visible, edge: wc.edge, expanded: false, count: 0)
                XCTAssertGreaterThanOrEqual(frame.minX, visible.minX - 0.5, "screen \(screen.localizedName)")
                XCTAssertLessThanOrEqual(frame.maxX, visible.maxX + 0.5, "screen \(screen.localizedName)")
                XCTAssertGreaterThanOrEqual(frame.minY, visible.minY - 0.5, "screen \(screen.localizedName)")
                XCTAssertLessThanOrEqual(frame.maxY, visible.maxY + 0.5, "screen \(screen.localizedName)")
            }
        }
    }

    // 3. Fake non-contiguous geometries (negative origins, tiny displays): frame stays inside.
    func testLayoutMathWithFakeScreenGeometries() {
        let fakes = [
            NSRect(x: -2560, y: 0, width: 2560, height: 1414),
            NSRect(x: 0, y: -1055, width: 1920, height: 1055),
            NSRect(x: 0, y: 0, width: 800, height: 500),
            NSRect(x: 5120, y: 2000, width: 1280, height: 720),
        ]
        for visible in fakes {
            for edge in [ShelfLayout.Edge.left, .right] {
                for expanded in [false, true] {
                    let f = ShelfLayout.frame(in: visible, edge: edge, expanded: expanded, count: 9)
                    XCTAssertTrue(visible.insetBy(dx: -0.5, dy: -0.5).contains(f.origin),
                        "origin \(f.origin) outside \(visible) edge=\(edge) expanded=\(expanded)")
                    XCTAssertLessThanOrEqual(f.maxX, visible.maxX + 0.5)
                    XCTAssertLessThanOrEqual(f.maxY, visible.maxY + 0.5)
                    XCTAssertGreaterThanOrEqual(f.minX, visible.minX - 0.5)
                    XCTAssertGreaterThanOrEqual(f.minY, visible.minY - 0.5)
                    XCTAssertLessThanOrEqual(f.width, visible.width)
                    XCTAssertLessThanOrEqual(f.height, visible.height)
                    XCTAssertGreaterThan(f.width, 0)
                    XCTAssertGreaterThan(f.height, 0)
                }
            }
        }
    }

    // 4. Drag entry stays compact; an accepted drop opens the thought bubble.
    func testDestinationAcceptsMultipleFileURLsAndExpands() throws {
        let wc = ShelfWindowController(viewModel: ShelfViewModel())
        let content = wc.content
        let a = try makeFile("in-a.txt")
        let b = try makeFile("in-b.txt", bytes: 4096)
        let info = makeInfo(makePasteboard([a, b]))
        let restingFrame = wc.window?.frame
        XCTAssertFalse(content.isRevealed)
        XCTAssertTrue(content.tail.isPresented)
        XCTAssertEqual(content.draggingEntered(info), .copy)
        XCTAssertTrue(content.isRevealed)
        XCTAssertFalse(content.tail.isPresented)
        XCTAssertEqual(wc.window?.frame, restingFrame, "peek keeps the native drop target fixed")
        XCTAssertFalse(content.isExpanded, "drag entry must not move the target")
        XCTAssertEqual(content.cat.mood, .hungry)
        XCTAssertTrue(content.prepareForDragOperation(info))
        XCTAssertTrue(content.performDragOperation(info))
        XCTAssertEqual(wc.viewModel.allItems.count, 2, "both file references stored")
        wc.reload()
        let frame = try XCTUnwrap(wc.window?.frame)
        XCTAssertEqual(frame.width, ShelfLayout.expandedWidth, "accepted files automatically open the thought bubble")
        XCTAssertGreaterThan(content.cat.bellyScale, 1, "stored files enlarge the belly")
        XCTAssertEqual(Set(content.rowsByURL.values.map { $0.nameLabel.stringValue }), ["in-a.txt", "in-b.txt"])
        content.draggingExited(info)
        content.concludeDragOperation(info)
        content.tuckAwayIfIdle(animated: false)
        XCTAssertTrue(content.isExpanded, "the thought bubble stays open after the drop ends")
        XCTAssertTrue(content.isRevealed)
        content.closeButton.performClick(nil)
        content.tuckAwayIfIdle(animated: false)
        XCTAssertFalse(content.isExpanded)
        XCTAssertFalse(content.isRevealed, "closing the bubble lets the cat hide again")
        content.clearShelf()
        XCTAssertFalse(content.isExpanded, "an emptied shelf collapses back to the tiny target")
    }

    // 5. Non-file drag (text) refused: returns [], no expansion, nothing stored.
    func testDestinationRejectsNonFileDrag() throws {
        let wc = ShelfWindowController(viewModel: ShelfViewModel())
        let content = wc.content
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("plain text", forType: .string)
        let info = makeInfo(pb)
        XCTAssertEqual(content.draggingEntered(info), [])
        XCTAssertFalse(content.isExpanded)
        XCTAssertFalse(content.prepareForDragOperation(info))
        XCTAssertFalse(content.performDragOperation(info))
        XCTAssertTrue(wc.viewModel.isEmpty)
    }

    // 6. Source side: always .copy in both contexts (refs only, never move/delete).
    func testSourceOperationMaskIsCopyOnly() {
        let wc = ShelfWindowController(viewModel: ShelfViewModel())
        XCTAssertEqual(wc.content.draggingSession(NSDraggingSession(), sourceOperationMaskFor: .outsideApplication), .copy)
        XCTAssertEqual(wc.content.draggingSession(NSDraggingSession(), sourceOperationMaskFor: .withinApplication), .copy)
        XCTAssertEqual(ShelfContentView.sourceOperations, .copy)
    }

    // 7. Drag back out: native NSDraggingItems carry real file URLs (round-trip the writer).
    func testDragOutBuildsNativeFileURLDraggingItems() throws {
        let wc = ShelfWindowController(viewModel: ShelfViewModel())
        let a = try makeFile("out-a.txt")
        let b = try makeFile("out-b.txt")
        wc.viewModel.insert([a, b])
        wc.reload()
        let items = wc.content.draggingItems(for: [ShelfModel.normalize(a)])
        XCTAssertEqual(items.count, 1)
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        let writers = try items.map { try XCTUnwrap($0.item as? NSPasteboardWriting) }
        XCTAssertTrue(pb.writeObjects(writers))
        let read = PasteboardFileURLReader().readFileURLs(from: pb)
        XCTAssertEqual(read, [ShelfModel.normalize(a)], "drag-out writer emits the exact file URL")
    }

    // 8. Stale reference blocks drag-out and is surfaced on the row + title.
    func testStaleReferenceBlocksDragOutAndSurfacesError() throws {
        let wc = ShelfWindowController(viewModel: ShelfViewModel())
        wc.changeLanguage(.english)
        let ghost = try makeFile("ghost.txt")
        wc.viewModel.insert([ghost])
        wc.reload()
        try FileManager.default.removeItem(at: ghost)
        wc.reload()
        let row = try XCTUnwrap(wc.content.rowsByURL[ShelfModel.normalize(ghost)])
        XCTAssertEqual(row.status, .missing)
        XCTAssertEqual(wc.content.errorMessage, nil) // set lazily on drag attempt
        XCTAssertTrue(wc.content.draggingItems(for: [ShelfModel.normalize(ghost)]).isEmpty,
                      "missing file must not produce a draggable item")
        XCTAssertEqual(wc.content.errorMessage, "Missing or unreadable file — cannot drag")
        XCTAssertTrue(wc.content.errorMessage != nil)
    }

    // 9. Native icon per row; metadata line present; remove one; clear all.
    func testRowIconMetadataRemoveAndClear() throws {
        let wc = ShelfWindowController(viewModel: ShelfViewModel())
        let a = try makeFile("row-a.txt", bytes: 2048)
        let b = try makeFile("row-b.txt")
        wc.viewModel.insert([a, b])
        wc.reload()
        let rowA = try XCTUnwrap(wc.content.rowsByURL[ShelfModel.normalize(a)])
        // Compare by size rather than TIFF bytes: the representation carries
        // variable metadata, so byte equality is flaky across icon-cache state.
        let native = NSWorkspace.shared.icon(forFile: a.path)
        XCTAssertEqual(rowA.iconView.image?.size, native.size, "native NSWorkspace icon")
        XCTAssertNotNil(rowA.iconView.image?.tiffRepresentation)
        XCTAssertFalse(rowA.metaLabel.stringValue.isEmpty)
        XCTAssertTrue(rowA.metaLabel.stringValue.contains("KB"), "byte size formatted")
        XCTAssertTrue(rowA.metaLabel.stringValue.contains(tmpDir.lastPathComponent), "source folder is visible")

        rowA.onRemoveRequested?(ShelfModel.normalize(a))
        XCTAssertEqual(wc.viewModel.allItems.count, 1)
        wc.content.clearShelf()
        XCTAssertTrue(wc.viewModel.isEmpty)
        XCTAssertFalse(wc.content.isExpanded, "cleared shelf returns to the tiny target")
    }

    // 10. Refs only: no copies created, no deletion on remove/clear, byte size unchanged.
    func testReferenceOnlyNoCopyMoveOrDelete() throws {
        let wc = ShelfWindowController(viewModel: ShelfViewModel())
        let src = try makeFile("ref-only.txt", bytes: 512)
        let before = try FileManager.default.attributesOfItem(atPath: src.path)
        wc.viewModel.insert([src])
        wc.reload()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmpDir.path).count, 1,
                       "no copy beside the source")
        wc.content.clearShelf()
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "clear must not delete the file")
        let after = try FileManager.default.attributesOfItem(atPath: src.path)
        XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
    }

    // 11. Explicit list opening, not hover, changes geometry; cat stays anchored.
    func testClickListOpenCloseKeepsCatAnchored() throws {
        let wc = ShelfWindowController(viewModel: ShelfViewModel())
        wc.showShelf()
        let content = wc.content
        XCTAssertFalse(content.isExpanded)
        XCTAssertFalse(content.isRevealed)
        content.setHovered(true)
        XCTAssertFalse(content.isExpanded, "hover must not move the pet")
        XCTAssertFalse(content.isRevealed, "ordinary pointer hover keeps the cat tucked away")
        content.tail.onClick?()
        XCTAssertTrue(content.isExpanded)
        XCTAssertTrue(content.isRevealed)
        content.tuckAwayIfIdle(animated: false)
        XCTAssertTrue(content.isRevealed, "the open file list holds the cat outside")
        let expandedFrame = try XCTUnwrap(wc.window?.frame).width
        XCTAssertGreaterThan(expandedFrame, ShelfLayout.collapsedWidth)
        content.setDetailsVisible(false)
        XCTAssertFalse(content.isExpanded)
        XCTAssertLessThanOrEqual(try XCTUnwrap(wc.window?.frame).width, ShelfLayout.collapsedWidth + 0.5)
        content.tuckAwayIfIdle(animated: false)
        XCTAssertFalse(content.isRevealed)
        XCTAssertTrue(content.tail.isPresented)
        wc.window?.orderOut(nil)
    }

    func testTailWagRespectsPresentationAndReducedMotion() {
        let wc = ShelfWindowController()
        let tail = wc.content.tail
        tail.reduceMotionOverride = false
        XCTAssertTrue(tail.isWagging)
        tail.reduceMotionOverride = true
        XCTAssertFalse(tail.isWagging)
        tail.reduceMotionOverride = false
        wc.content.revealCat(animated: false)
        XCTAssertFalse(tail.isWagging)
        wc.content.tuckAwayIfIdle(animated: false)
        XCTAssertTrue(tail.isWagging)
    }

    // 12. Mouse-drag on a row wires the event into a native session via the injectable hook.
    func testRowMouseDragStartsSessionViaHook() throws {
        let wc = ShelfWindowController(viewModel: ShelfViewModel())
        let a = try makeFile("drag-row.txt")
        wc.viewModel.insert([a])
        wc.reload()
        let row = try XCTUnwrap(wc.content.rowsByURL[ShelfModel.normalize(a)])
        var hooked: (items: Int, event: NSEvent?) = (0, nil)
        wc.content.startSession = { items, event in
            hooked = (items.count, event)
            wc.content.draggingSession(NSDraggingSession(), endedAt: .zero, operation: .copy)
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 10, y: 10),
                                       modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1.0))
        row.onDragRequested?(ShelfModel.normalize(a), event)
        XCTAssertEqual(hooked.items, 1, "injectable session hook receives the native drag item")
        XCTAssertFalse(wc.content.outgoing, "session end clears the outgoing flag")
        XCTAssertFalse(wc.content.isExpanded, "empty cat returns to compact state")
        XCTAssertEqual(wc.viewModel.allItems.count, 0, "successful handoff consumes only the reference")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "original file stays in place")
    }

    // 13. beginDrag ignores non-mouse events (defensive; no crash without a real event).
    func testBeginDragIgnoresNonMouseEvents() throws {
        let wc = ShelfWindowController(viewModel: ShelfViewModel())
        let a = try makeFile("no-drag.txt")
        wc.viewModel.insert([a])
        wc.reload()
        var hooked = 0
        wc.content.startSession = { _, _ in hooked += 1 }
        let keyEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                      timestamp: 0, windowNumber: 0, context: nil,
                                                      characters: "a", charactersIgnoringModifiers: "a",
                                                      isARepeat: false, keyCode: 0))
        wc.content.beginDrag(for: ShelfModel.normalize(a), event: keyEvent)
        XCTAssertEqual(hooked, 0, "only leftMouseDragged may start a session")
    }

    func testCatDoesNotSwallowItsOwnOutgoingDrag() throws {
        let wc = ShelfWindowController()
        let file = try makeFile("self-drop.txt")
        let pb = makePasteboard([file])
        defer { pb.releaseGlobally() }
        wc.content.acceptFiles(from: pb)
        wc.content.startSession = { _, _ in
            for source: Any? in [wc.content, nil] {
                let info = self.makeInfo(pb, source: source)
                XCTAssertEqual(wc.content.draggingEntered(info), [])
                XCTAssertEqual(wc.content.draggingUpdated(info), [])
                XCTAssertFalse(wc.content.prepareForDragOperation(info))
            }
            wc.content.completeDrag(operation: [])
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        wc.content.beginDrag(for: ShelfModel.normalize(file), event: event)
        XCTAssertEqual(wc.viewModel.allItems.count, 1)
        XCTAssertEqual(wc.content.cat.mood, .idle)
    }

    // 14. Destination refuses a file URL that is not a local path (e.g. http:// -> not file).
    func testDestinationIgnoresNonFileURLScheme() throws {
        let wc = ShelfWindowController(viewModel: ShelfViewModel())
        let content = wc.content
        let web = URL(string: "https://example.com/x.pdf")!
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([web as NSURL]))
        let info = makeInfo(pb)
        XCTAssertEqual(content.draggingEntered(info), [], "non-file URL drag is not a copy target")
        XCTAssertFalse(content.isExpanded)
        XCTAssertFalse(content.acceptFiles(from: pb))
        XCTAssertTrue(wc.viewModel.isEmpty)
    }
}
#endif
