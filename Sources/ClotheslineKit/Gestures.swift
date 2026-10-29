import SwiftUI
import AppKit
import QuickLookUI

struct GestureSurface: NSViewRepresentable {
    let capture: Capture
    let model: Model
    let markup: (Capture) -> Void

    func makeNSView(context: Context) -> CaptureGestureView { CaptureGestureView() }
    func updateNSView(_ view: CaptureGestureView, context: Context) {
        view.capture = capture; view.model = model; view.markup = markup
    }
}

@MainActor final class CaptureGestureView: NSView, NSDraggingSource {
    var capture: Capture?
    weak var model: Model?
    var markup: ((Capture) -> Void)?
    private var down: NSEvent?
    private var longPress: DispatchWorkItem?
    private var click: DispatchWorkItem?
    private var handled = false

    override func mouseDown(with event: NSEvent) {
        down = event; handled = false
        if event.clickCount > 1 { click?.cancel() }
        let job = DispatchWorkItem { [weak self] in
            guard let self, !self.handled, let capture = self.capture else { return }
            self.handled = true; self.click?.cancel(); self.markup?(capture)
        }
        longPress = job; DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: job)
    }

    override func mouseUp(with event: NSEvent) {
        longPress?.cancel(); down = nil
        guard !handled, let capture, let model else { return }
        if event.clickCount >= 2 { click?.cancel(); model.preview(capture) }
        else {
            let job = DispatchWorkItem { [weak model] in model?.copy(capture) }
            click = job
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: job)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !handled, let down, let capture, let model,
              hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 5 else { return }
        handled = true; longPress?.cancel(); click?.cancel()
        let url = model.library.url(for: capture)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = model.thumbnails[capture.id] ?? NSImage(size: bounds.size)
        item.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .delete]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let capture { model?.endDrag(capture, operation: operation) }
    }
}

@MainActor private final class PreviewHost: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor final class PreviewController: NSWindowController, QLPreviewPanelDataSource {
    private var item: NSURL?
    func show(_ url: URL) {
        item = url as NSURL
        guard let panel = QLPreviewPanel.shared() else { return }
        // Use the public responder-chain ownership protocol, never call begin/end ourselves.
        NSApp.activate(ignoringOtherApps: true)
        let host = PreviewHost(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        host.nextResponder = self
        window = host; host.makeKeyAndOrderFront(nil)
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
    }
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self; panel.reloadData() }
    }
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil; window?.orderOut(nil) }
    }
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { item == nil ? 0 : 1 }
    }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { item }
    }
}
