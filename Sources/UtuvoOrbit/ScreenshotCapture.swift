import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

enum ScreenshotCaptureMode: Equatable { case window, display }
enum ScreenshotCaptureError: Error, Equatable { case cancelled, busy, invalidSize, unavailable, selectionRejected, selectionTimedOut, frameTimedOut, frameUnavailable }

@MainActor
protocol ScreenshotCapturing: AnyObject {
    func capture(_ mode: ScreenshotCaptureMode) async throws -> CGImage
    func cancel()
}

/// One explicit system selection and one bounded, screen-only stream; no recording UX or files.
@MainActor
final class SystemScreenshotCapture: NSObject, ScreenshotCapturing {
    private let eligibleFilter: ((SCContentFilter) -> Bool)?
    private let excludedBundleIDs: Set<String>
    private let frameTimeout: Duration
    private var continuation: CheckedContinuation<CGImage, any Error>?
    private var selectionID: UUID?
    private var requestID: UUID?
    private var observer: ScreenshotPickerObserver?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?
    private var selectionDeadline: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private let picker = SCContentSharingPicker.shared

    init(frameTimeout: Duration = .seconds(15), excludedBundleIDs: Set<String> = [],
         eligibleFilter: ((SCContentFilter) -> Bool)? = nil) {
        self.frameTimeout = frameTimeout
        self.excludedBundleIDs = excludedBundleIDs
        self.eligibleFilter = eligibleFilter
    }

    func capture(_ mode: ScreenshotCaptureMode) async throws -> CGImage {
        guard continuation == nil else { throw ScreenshotCaptureError.busy }
        if #available(macOS 27.0, *), !picker.isAvailable { throw ScreenshotCaptureError.unavailable }
        let request = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: ScreenshotCaptureError.cancelled); return }
                self.continuation = continuation; selectionID = nil; requestID = request
                var config = SCContentSharingPickerConfiguration()
                config.allowedPickerModes = mode == .window ? [.singleWindow] : [.singleDisplay]
                config.excludedBundleIDs = excludedBundleIDs.sorted()
                config.allowsChangingSelectedContent = false
                picker.defaultConfiguration = config
                let observer = ScreenshotPickerObserver(
                    select: { [weak self] filter in self?.selected(filter, request: request) },
                    cancel: { [weak self] in self?.cancel(request: request) },
                    fail: { [weak self] error in
                        guard let self, self.requestID == request, self.selectionID == nil else { return }
                        self.finish(.failure(error))
                    })
                self.observer = observer
                // Keep the app discoverable during this explicit system selection.
                // Restore its prior policy on every completion/cancellation path.
                previousActivationPolicy = NSApp.activationPolicy()
                NSApp.setActivationPolicy(.regular)
                picker.add(observer); picker.isActive = true
                picker.maximumStreamCount = 1
                selectionDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    guard let self, self.requestID == request, self.selectionID == nil else { return }
                    self.finish(.failure(ScreenshotCaptureError.selectionTimedOut))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.requestID == request else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    self.picker.present(using: mode == .window ? .window : .display)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(request: request) } }
    }

    func cancel() {
        guard let requestID else { return }
        cancel(request: requestID)
    }
    private func cancel(request: UUID) {
        guard requestID == request else { return }
        if selectionID != nil, let frameTask { frameTask.cancel(); return }
        finish(.failure(ScreenshotCaptureError.cancelled))
    }

    private func finish(_ result: Result<CGImage, any Error>) {
        guard let continuation else { return }
        self.continuation = nil; selectionID = nil; requestID = nil
        selectionDeadline?.cancel(); selectionDeadline = nil
        frameTask = nil
        picker.isActive = false
        if let observer { picker.remove(observer) }; observer = nil
        if let previousActivationPolicy { NSApp.setActivationPolicy(previousActivationPolicy) }
        previousActivationPolicy = nil
        continuation.resume(with: result)
    }

    private func selected(_ filter: SCContentFilter, request: UUID) {
        guard requestID == request, continuation != nil, selectionID == nil else { return }
        guard eligibleFilter?(filter) ?? true else {
            finish(.failure(ScreenshotCaptureError.selectionRejected)); return
        }
        let scale = Double(filter.pointPixelScale)
        let w = ceil(filter.contentRect.width * scale), h = ceil(filter.contentRect.height * scale)
        guard w.isFinite, h.isFinite, w >= 1, h >= 1, w <= 32768, h <= 32768, w * h <= 80_000_000 else {
            finish(.failure(ScreenshotCaptureError.invalidSize)); return
        }
        let id = UUID(); selectionID = id
        selectionDeadline?.cancel(); selectionDeadline = nil
        let config = SCStreamConfiguration()
        config.width = Int(w); config.height = Int(h)
        config.showsCursor = false; config.capturesAudio = false; config.queueDepth = 1
        if #available(macOS 15.0, *) { config.captureMicrophone = false }
        if #available(macOS 14.2, *) { config.ignoreShadowsSingleWindow = true }
        let capture = ScreenshotSingleFrameCapture(driver: ScreenCaptureKitSingleFrameDriver(filter: filter, configuration: config))
        frameTask = Task { [weak self, capture] in
            do {
                let image = try await capture.capture(frameTimeout: self?.frameTimeout ?? .seconds(15))
                guard let self, self.selectionID == id else { return }
                self.frameTask = nil
                self.finish(.success(image))
            } catch {
                guard let self, self.selectionID == id else { return }
                self.frameTask = nil
                self.finish(.failure(error))
            }
        }
    }
}

/// A new observer for every request prevents queued cancellation/selection
/// callbacks from a previous picker from affecting its successor.
@MainActor
private final class ScreenshotPickerObserver: NSObject, SCContentSharingPickerObserver {
    let select: (SCContentFilter) -> Void
    let cancelSelection: () -> Void
    let fail: (any Error) -> Void
    init(select: @escaping (SCContentFilter) -> Void, cancel: @escaping () -> Void, fail: @escaping (any Error) -> Void) {
        self.select = select; cancelSelection = cancel; self.fail = fail
    }
    private final class Selection: @unchecked Sendable {
        let filter: SCContentFilter
        init(_ filter: SCContentFilter) { self.filter = filter }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let selected = Selection(filter)
        Task { @MainActor [weak self] in self?.select(selected.filter) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in self?.cancelSelection() }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor [weak self] in self?.fail(error) }
    }
}

@MainActor
final class PreviewScreenshotCapture: ScreenshotCapturing {
    func capture(_ mode: ScreenshotCaptureMode) async throws -> CGImage { ScreenshotFixture.image() }
    func cancel() {}
}

enum ScreenshotFixture {
    @MainActor static func image() -> CGImage {
        let size = NSSize(width: 1200, height: 680)
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let rect = NSRect(origin: .zero, size: size)
            NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.95, alpha: 1).setFill(); rect.fill()
            NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 56, y: 48, width: 1088, height: 584), xRadius: 28, yRadius: 28).fill()
            NSColor(calibratedRed: 0.06, green: 0.43, blue: 0.46, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 100, y: 470, width: 280, height: 92), xRadius: 20, yRadius: 20).fill()
            ("UTUVO Orbit" as NSString).draw(at: NSPoint(x: 128, y: 495), withAttributes: [.font: NSFont.systemFont(ofSize: 32, weight: .semibold), .foregroundColor: NSColor.white])
            ("A little more room to focus." as NSString).draw(at: NSPoint(x: 100, y: 370), withAttributes: [.font: NSFont.systemFont(ofSize: 42, weight: .semibold), .foregroundColor: NSColor.black])
            ("Screenshot workspace · Demo content" as NSString).draw(at: NSPoint(x: 100, y: 308), withAttributes: [.font: NSFont.systemFont(ofSize: 25), .foregroundColor: NSColor.darkGray])
            for i in 0..<3 {
                NSColor(calibratedRed: 0.9, green: 0.94, blue: 0.94, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 100 + i * 350, y: 100, width: 310, height: 145), xRadius: 20, yRadius: 20).fill()
            }
        return context.makeImage()!
    }
}
