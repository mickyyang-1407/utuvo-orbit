import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

enum ScreenshotFrameEvent {
    case incomplete
    case complete(CGImage)
    case failed(any Error)
}

@MainActor
protocol ScreenshotSingleFrameDriver: AnyObject {
    func start(onFrame: @escaping @MainActor @Sendable (ScreenshotFrameEvent) -> Void) async throws
    func stop() async throws
}

/// Owns one SCStream attempt. Its continuation is released only after the
/// driver has stopped, so a retry cannot overlap stream teardown.
@MainActor
final class ScreenshotSingleFrameCapture {
    private enum State { case idle, starting, running, stopping, finished }

    private let driver: any ScreenshotSingleFrameDriver
    private var state: State = .idle
    private var continuation: CheckedContinuation<CGImage, any Error>?
    private var result: Result<CGImage, any Error>?
    private var startFinished = false
    private var stopFinished = false
    private var timeoutTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var request = UUID()

    init(driver: any ScreenshotSingleFrameDriver) { self.driver = driver }

    func capture(frameTimeout: Duration) async throws -> CGImage {
        guard case .idle = state else { throw ScreenshotCaptureError.busy }
        let request = UUID()
        self.request = request
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard self.request == request, !Task.isCancelled else {
                    continuation.resume(throwing: ScreenshotCaptureError.cancelled)
                    return
                }
                self.continuation = continuation
                state = .starting
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: frameTimeout) } catch { return }
                    guard let self, self.request == request else { return }
                    self.requestStop(.failure(ScreenshotCaptureError.frameTimedOut), request: request)
                }
                startTask = Task { [weak coordinator = self, driver] in
                    guard let coordinator, coordinator.request == request else { return }
                    guard case nil = coordinator.result else {
                        coordinator.startFinished = true
                        coordinator.stopFinished = true
                        coordinator.finishIfReady(request: request)
                        return
                    }
                    do {
                        try await driver.start { [weak callbackOwner = coordinator] event in
                            guard let callbackOwner, callbackOwner.request == request else { return }
                            callbackOwner.receive(event, request: request)
                        }
                        guard coordinator.request == request else { return }
                        coordinator.didStart(nil, request: request)
                    } catch {
                        guard coordinator.request == request else { return }
                        coordinator.didStart(error, request: request)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.request == request, self.continuation != nil else { return }
                self.requestStop(.failure(ScreenshotCaptureError.cancelled), request: request)
            }
        }
    }

    private func receive(_ event: ScreenshotFrameEvent, request: UUID) {
        guard self.request == request else { return }
        switch event {
        case .incomplete:
            return
        case .complete(let image):
            switch state {
            case .starting, .running: break
            default: return
            }
            requestStop(.success(image), request: request)
        case .failed(let error):
            requestStop(.failure(error), request: request)
        }
    }

    private func didStart(_ error: (any Error)?, request: UUID) {
        guard self.request == request, !startFinished else { return }
        startFinished = true
        if let error {
            switch result {
            case nil, .some(.success(_)): result = .failure(error)
            case .some(.failure(_)): break
            }
        }
        if case .some = result {
            startStopIfNeeded(request: request)
        } else {
            state = .running
        }
        finishIfReady(request: request)
    }

    private func requestStop(_ result: Result<CGImage, any Error>, request: UUID) {
        guard self.request == request, !isFinished else { return }
        if case nil = self.result {
            self.result = result
            timeoutTask?.cancel(); timeoutTask = nil
        }
        if case .some(.failure(_)) = self.result { startTask?.cancel() }
        startStopIfNeeded(request: request)
    }

    private var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    private func startStopIfNeeded(request: UUID) {
        guard self.request == request, !isFinished else { return }
        guard case .stopping = state else {
            state = .stopping
            Task { [weak self, driver] in
                var stopError: (any Error)?
                do { try await driver.stop() } catch { stopError = error }
                guard let self, self.request == request else { return }
                // A settled stop is the resource boundary. If startCapture is
                // still awaiting an OS callback, ignore its late completion.
                self.startFinished = true
                self.stopFinished = true
                if let stopError, case .success = self.result {
                    self.result = .failure(stopError)
                }
                self.finishIfReady(request: request)
            }
            return
        }
    }

    private func finishIfReady(request: UUID) {
        guard self.request == request, startFinished, stopFinished,
              let continuation, let result else { return }
        state = .finished
        self.continuation = nil
        self.result = nil
        timeoutTask?.cancel(); timeoutTask = nil
        startTask?.cancel(); startTask = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class ScreenCaptureKitSingleFrameDriver: NSObject, ScreenshotSingleFrameDriver, SCStreamOutput, SCStreamDelegate {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private var stream: SCStream?
    private var frameHandler: (@MainActor @Sendable (ScreenshotFrameEvent) -> Void)?
    private let outputQueue = DispatchQueue(label: "com.utuvo.orbit.screenshot.single-frame")
    nonisolated private let frameGate = ScreenshotFrameGate()

    init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        self.filter = filter
        self.configuration = configuration
    }

    func start(onFrame: @escaping @MainActor @Sendable (ScreenshotFrameEvent) -> Void) async throws {
        guard stream == nil else { throw ScreenshotCaptureError.busy }
        frameHandler = onFrame
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
    }

    func stop() async throws {
        guard let stream else { return }
        self.stream = nil
        frameHandler = nil
        var firstError: (any Error)?
        do { try stream.removeStreamOutput(self, type: .screen) } catch { firstError = error }
        do { try await stream.stopCapture() } catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        guard frameGate.claim() else { return }
        let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard let image = CIContext().createCGImage(CIImage(cvPixelBuffer: pixelBuffer), from: rect) else {
            Task { @MainActor [weak self] in self?.frameHandler?(.failed(ScreenshotCaptureError.frameUnavailable)) }
            return
        }
        Task { @MainActor [weak self] in self?.frameHandler?(.complete(image)) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard frameGate.claim() else { return }
        Task { @MainActor [weak self] in self?.frameHandler?(.failed(error)) }
    }
}

// Stream callbacks arrive off actor. The lock admits only the first terminal
// frame/error so later video frames are not converted while shutdown queues.
private final class ScreenshotFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}
