import Foundation
import CoreGraphics
import Testing
import ClotheslineKit
@testable import UtuvoOrbit

@MainActor
private final class PendingCapture: ScreenshotCapturing {
    var requests = 0
    private var pendingRequests: [Int: CheckedContinuation<CGImage, any Error>] = [:]
    private(set) var receivedModes: [ScreenshotCaptureMode] = []
    var pending: CheckedContinuation<CGImage, any Error>? {
        get { pendingRequests[requests] }
        set {
            if let newValue { pendingRequests[requests] = newValue }
            else { pendingRequests.removeValue(forKey: requests) }
        }
    }
    func capture(_ mode: ScreenshotCaptureMode) async throws -> CGImage {
        requests += 1; receivedModes.append(mode)
        let request = requests
        return try await withCheckedThrowingContinuation { pendingRequests[request] = $0 }
    }
    func cancel() {
        let pending = Array(pendingRequests.values); pendingRequests.removeAll()
        for continuation in pending { continuation.resume(throwing: ScreenshotCaptureError.cancelled) }
    }
}

@MainActor
struct ScreenshotToolsTests {
    @Test func selectionTimeoutEndsWaitingAndAllowsAnotherRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = PendingCapture(), model = ScreenshotToolsModel(root: root, capture: capture)
        model.language = .english
        defer { model.stop() }
        model.take(.window)
        for _ in 0..<50 where capture.pending == nil { await Task.yield() }
        let pending = try #require(capture.pending); capture.pending = nil
        pending.resume(throwing: ScreenshotCaptureError.selectionTimedOut)
        try await wait(model)
        #expect(model.failed && !model.waitingForSelection && model.image == nil)
        #expect(model.message?.contains("timed out") == true)
        model.take(.window)
        for _ in 0..<50 where capture.pending == nil { await Task.yield() }
        #expect(capture.requests == 2 && model.waitingForSelection)
        model.cancel(); try await wait(model)
        #expect(!model.failed && !model.waitingForSelection)
    }
    private func wait(_ model: ScreenshotToolsModel, timeout: Duration = .seconds(5)) async throws {
        let end = ContinuousClock.now.advanced(by: timeout)
        while model.busy && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!model.busy)
    }

    @Test func immediateCancelBeforeQueuedCaptureNeverCallsBackend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = PendingCapture(), model = ScreenshotToolsModel(root: root, capture: capture)
        model.language = .english
        defer { model.stop() }

        model.take(.window)
        model.cancel()
        for _ in 0..<50 { await Task.yield() }

        #expect(capture.requests == 0 && capture.receivedModes.isEmpty)
        #expect(!model.busy && !model.waitingForSelection && model.image == nil && !model.failed)
    }

    @Test func immediateCancelThenNewCaptureKeepsOnlyNewGenerationActive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = PendingCapture(), model = ScreenshotToolsModel(root: root, capture: capture)
        defer { model.stop() }

        model.take(.window)
        model.cancel()
        model.take(.display)
        for _ in 0..<50 where capture.pending == nil { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        #expect(capture.requests == 1 && capture.receivedModes == [.display])
        #expect(model.busy && model.waitingForSelection && model.image == nil)

        let pending = try #require(capture.pending)
        capture.pending = nil
        pending.resume(returning: Self.onePixel())
        try await wait(model)
        for _ in 0..<50 { await Task.yield() }
        #expect(model.image?.width == 1 && model.image?.height == 1)
        #expect(!model.busy && !model.waitingForSelection && !model.failed)
    }

    private static func onePixel() -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    @Test func captureRequiresExplicitActionAndCancellationLeavesNoImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = PendingCapture(), model = ScreenshotToolsModel(root: root, capture: capture)
        defer { model.stop() }
        #expect(capture.requests == 0 && model.recent.isEmpty)
        model.take(.window)
        for _ in 0..<50 where capture.pending == nil { await Task.yield() }
        #expect(capture.requests == 1 && model.busy && model.waitingForSelection)
        model.cancel(); try await wait(model)
        for _ in 0..<50 { await Task.yield() }
        #expect(model.recent.isEmpty && model.image == nil && !model.failed && !model.waitingForSelection)
    }

    @Test func editsPersistAcrossSelectionAndReopenAndShareFlattenedCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var copied: CGImage?, shared: URL?
        let model = ScreenshotToolsModel(root: root, capture: PreviewScreenshotCapture(), copyImage: { copied = $0 }, copyText: { _ in })
        defer { model.stop() }
        model.loadFixture(); let id = try #require(model.selectedID)
        let originalWidth = try #require(model.image).width
        let source = try #require(model.recent.first).filename
        let original = try Data(contentsOf: root.appendingPathComponent(source))
        model.tool = .crop; model.apply(from: .zero, to: .init(x: 0.5, y: 1)); try await wait(model)
        #expect(model.image?.width == originalWidth / 2 && model.edits.count == 1)
        model.copy(); #expect(copied?.width == originalWidth / 2)
        model.onSendToFiles = { shared = $0 }; model.sendToFiles()
        let sharedImage = try ScreenshotEditing.load(try #require(shared))
        #expect(sharedImage.width == originalWidth / 2)
        #expect(try Data(contentsOf: root.appendingPathComponent(source)) == original)
        let reopened = ScreenshotToolsModel(root: root, capture: PreviewScreenshotCapture())
        defer { reopened.stop() }
        reopened.select(id); try await wait(reopened)
        #expect(reopened.image?.width == originalWidth / 2 && reopened.edits.count == 1)
        reopened.undo(); try await wait(reopened)
        #expect(reopened.image?.width == originalWidth && reopened.edits.isEmpty)
    }

    @Test func exportMakesNewFolderAndMalformedDraftDoesNotOverwriteOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ScreenshotToolsModel(root: root, capture: PreviewScreenshotCapture())
        defer { model.stop() }
        model.loadFixture(); let id = try #require(model.selectedID)
        let source = root.appendingPathComponent(try #require(model.recent.first).filename)
        let original = try Data(contentsOf: source)
        model.export(to: root); try await wait(model)
        #expect(!model.failed)
        let exports = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("Orbit Export ") }
        #expect(exports.count == 1)
        let corrupt = Data("broken edit history".utf8), draft = root.appendingPathComponent(id.uuidString + ".edits.json")
        try corrupt.write(to: draft)
        model.select(id); try await wait(model)
        #expect(model.failed && model.draftNeedsRecovery)
        model.apply(from: .zero, to: .init(x: 0.5, y: 0.5))
        #expect(try Data(contentsOf: draft) == corrupt)
        #expect(try Data(contentsOf: source) == original)
        model.resetEdits()
        #expect(!model.draftNeedsRecovery && model.edits.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".edits.backup-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == corrupt)
    }

    @Test func ocrUsesEditedPixelsAndFullyRedactedTextIsNotCopied() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var text: [String] = []
        let model = ScreenshotToolsModel(root: root, capture: PreviewScreenshotCapture(), copyText: { text.append($0) })
        defer { model.stop() }
        // Accurate bilingual Vision OCR took 17.5 s cold in the isolated fixture probe.
        // Keep a bounded OCR deadline without changing the 5 s editing/cancel checks.
        model.loadFixture(); model.recognize(); try await wait(model, timeout: .seconds(45))
        #expect(text.count == 1)
        #expect(text.first?.contains("Orbit") == true)
        model.tool = .redact; model.apply(from: .zero, to: .init(x: 1, y: 1)); try await wait(model)
        model.recognize(); try await wait(model, timeout: .seconds(45))
        #expect(text.count == 1)
        #expect(!model.failed)
    }
}
