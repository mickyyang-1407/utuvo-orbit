import CoreGraphics
import Testing
@testable import UtuvoOrbit

@MainActor
private final class FakeSingleFrameDriver: ScreenshotSingleFrameDriver {
    enum Failure: Error, Equatable { case start, stop, frame }

    var events: [String] = []
    var holdStart = false
    var holdStop = false
    var stopFailure: Failure?
    var startFailure: Failure?
    var startContinuation: CheckedContinuation<Void, Never>?
    var stopContinuation: CheckedContinuation<Void, Never>?
    var frameHandler: (@MainActor @Sendable (ScreenshotFrameEvent) -> Void)?

    func start(onFrame: @escaping @MainActor @Sendable (ScreenshotFrameEvent) -> Void) async throws {
        events.append("start")
        frameHandler = onFrame
        if let startFailure { throw startFailure }
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
        events.append("started")
    }

    func stop() async throws {
        events.append("stop.begin")
        if holdStop { await withCheckedContinuation { stopContinuation = $0 } }
        events.append("stop.end")
        if let stopFailure { throw stopFailure }
    }

    func send(_ event: ScreenshotFrameEvent) { frameHandler?(event) }
    func finishStart() { startContinuation?.resume(); startContinuation = nil }
    func finishStop() { stopContinuation?.resume(); stopContinuation = nil }
}

@MainActor
struct ScreenshotCaptureTests {
    @Test func returnsOwnedFrameOnlyAfterStopAndIgnoresDuplicateFrames() async throws {
        let driver = FakeSingleFrameDriver(); driver.holdStop = true
        let capture = ScreenshotSingleFrameCapture(driver: driver)
        let task = Task { try await capture.capture(frameTimeout: .seconds(2)) }
        var didFinish = false
        let observer = Task { _ = try? await task.value; didFinish = true }
        await waitUntil { driver.events.contains("started") }

        driver.send(.complete(onePixel()))
        await waitUntil { driver.events.contains("stop.begin") }
        driver.send(.complete(onePixel()))
        #expect(driver.events.filter { $0 == "stop.begin" }.count == 1)
        #expect(!didFinish)

        driver.finishStop()
        let image = try await task.value
        await observer.value
        #expect(image.width == 1 && image.height == 1)
        #expect(didFinish)
        #expect(driver.events == ["start", "started", "stop.begin", "stop.end"])
    }

    @Test func cancellationAndFrameDeadlineStopBeforeFinishing() async throws {
        let cancelledDriver = FakeSingleFrameDriver(); cancelledDriver.holdStop = true
        let cancelledCapture = ScreenshotSingleFrameCapture(driver: cancelledDriver)
        let cancelledTask = Task { try await cancelledCapture.capture(frameTimeout: .seconds(5)) }
        await waitUntil { cancelledDriver.events.contains("started") }
        cancelledTask.cancel()
        await waitUntil { cancelledDriver.events.contains("stop.begin") }
        cancelledDriver.finishStop()
        let cancelError = await failure(of: cancelledTask)
        #expect(cancelError as? ScreenshotCaptureError == .cancelled)
        #expect(cancelledDriver.events.suffix(2) == ["stop.begin", "stop.end"])

        let timeoutDriver = FakeSingleFrameDriver()
        let timeoutCapture = ScreenshotSingleFrameCapture(driver: timeoutDriver)
        let timeoutTask = Task { try await timeoutCapture.capture(frameTimeout: .milliseconds(40)) }
        await waitUntil { timeoutDriver.events.contains("started") }
        timeoutDriver.send(.incomplete)
        let timeoutError = await failure(of: timeoutTask)
        #expect(timeoutError as? ScreenshotCaptureError == .frameTimedOut)
        #expect(timeoutDriver.events == ["start", "started", "stop.begin", "stop.end"])
    }

    @Test func frameDeadlineCanFinishAfterStopEvenIfStartCallbackIsStillPending() async throws {
        let driver = FakeSingleFrameDriver(); driver.holdStart = true; driver.holdStop = true
        let capture = ScreenshotSingleFrameCapture(driver: driver)
        let task = Task { try await capture.capture(frameTimeout: .milliseconds(35)) }
        await waitUntil { driver.events.contains("start") }
        await waitUntil { driver.events.contains("stop.begin") }
        var didFinish = false
        var taskError: (any Error)?
        let observer = Task {
            do { _ = try await task.value } catch { taskError = error }
            didFinish = true
        }
        driver.finishStop()
        await waitUntil { didFinish }
        #expect(taskError as? ScreenshotCaptureError == .frameTimedOut)
        driver.finishStart() // release the fake's delayed OS callback after completion
        await observer.value
        #expect(driver.events.suffix(2) == ["stop.begin", "stop.end"])
    }

    @Test func startFrameAndStopErrorsFinishOnceAndAllowRetryWithFreshDriver() async throws {
        let startDriver = FakeSingleFrameDriver(); startDriver.startFailure = .start
        let startTask = Task { try await ScreenshotSingleFrameCapture(driver: startDriver).capture(frameTimeout: .seconds(2)) }
        let startError = await failure(of: startTask)
        #expect(startError as? FakeSingleFrameDriver.Failure == .start)
        #expect(startDriver.events == ["start", "stop.begin", "stop.end"])

        let frameDriver = FakeSingleFrameDriver()
        let frameCapture = ScreenshotSingleFrameCapture(driver: frameDriver)
        let frameTask = Task { try await frameCapture.capture(frameTimeout: .seconds(2)) }
        await waitUntil { frameDriver.events.contains("started") }
        let oldHandler = try #require(frameDriver.frameHandler)
        oldHandler(.failed(FakeSingleFrameDriver.Failure.frame))
        let frameError = await failure(of: frameTask)
        #expect(frameError as? FakeSingleFrameDriver.Failure == .frame)
        #expect(frameDriver.events.filter { $0 == "stop.begin" }.count == 1)

        let retryDriver = FakeSingleFrameDriver()
        let retryCapture = ScreenshotSingleFrameCapture(driver: retryDriver)
        let retryTask = Task { try await retryCapture.capture(frameTimeout: .seconds(2)) }
        await waitUntil { retryDriver.events.contains("started") }
        oldHandler(.complete(onePixel())) // stale callback belongs to the finished attempt
        await Task.yield()
        #expect(!retryDriver.events.contains("stop.begin"))
        retryDriver.send(.complete(onePixel()))
        _ = try await retryTask.value
        #expect(retryDriver.events.filter { $0 == "stop.begin" }.count == 1)

        let stopDriver = FakeSingleFrameDriver(); stopDriver.stopFailure = .stop
        let stopCapture = ScreenshotSingleFrameCapture(driver: stopDriver)
        let stopTask = Task { try await stopCapture.capture(frameTimeout: .seconds(2)) }
        await waitUntil { stopDriver.events.contains("started") }
        stopDriver.send(.complete(onePixel()))
        let stopError = await failure(of: stopTask)
        #expect(stopError as? FakeSingleFrameDriver.Failure == .stop)
        #expect(stopDriver.events.filter { $0 == "stop.begin" }.count == 1)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }

    private func failure(of task: Task<CGImage, any Error>) async -> (any Error)? {
        do { _ = try await task.value; return nil } catch { return error }
    }

    private func onePixel() -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
