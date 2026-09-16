import XCTest
@testable import OrbitCore

final class AwakeMathTests: XCTestCase {
    private let reference = Date(timeIntervalSinceReferenceDate: 0)

    func testInactiveWhenNotActive() {
        let state = AwakeState(isActive: false, deadline: nil, chosenDuration: .sixty, lastError: nil)
        switch AwakeMath.status(state: state, now: reference) {
        case .inactive: break
        default: XCTFail("expected inactive")
        }
    }

    func testActiveComputesRemaining() {
        let deadline = reference.addingTimeInterval(125)
        let state = AwakeState(isActive: true, deadline: deadline, chosenDuration: .sixty, lastError: nil)
        if case .active(let remaining) = AwakeMath.status(state: state, now: reference) {
            XCTAssertEqual(remaining, 125, accuracy: 0.001)
        } else { XCTFail("expected active") }
    }

    func testExpiredWhenDeadlinePassed() {
        let deadline = reference.addingTimeInterval(-1)
        let state = AwakeState(isActive: true, deadline: deadline, chosenDuration: .sixty, lastError: nil)
        XCTAssertEqual(AwakeMath.status(state: state, now: reference), .expired)
    }

    func testCountdownLabelFormats() {
        let deadline = reference.addingTimeInterval(125)
        let state = AwakeState(isActive: true, deadline: deadline, chosenDuration: .sixty, lastError: nil)
        XCTAssertEqual(AwakeMath.countdownLabel(state: state, now: reference), "02:05")
        XCTAssertEqual(AwakeMath.countdownLabel(state: state, now: deadline), "00:00")
    }

    func testCountdownLabelInactiveShowsDash() {
        let state = AwakeState(isActive: false, deadline: nil, chosenDuration: .sixty, lastError: nil)
        XCTAssertEqual(AwakeMath.countdownLabel(state: state, now: reference), "—")
    }

    func testReconcileClearsExpiredState() {
        let deadline = reference.addingTimeInterval(-1)
        let state = AwakeState(isActive: true, deadline: deadline, chosenDuration: .sixty, lastError: nil)
        let reconciled = AwakeMath.reconcile(state: state, now: reference)
        XCTAssertFalse(reconciled.isActive)
        XCTAssertNil(reconciled.deadline)
    }

    func testReconcileKeepsActive() {
        let deadline = reference.addingTimeInterval(60)
        let state = AwakeState(isActive: true, deadline: deadline, chosenDuration: .sixty, lastError: nil)
        let reconciled = AwakeMath.reconcile(state: state, now: reference)
        XCTAssertTrue(reconciled.isActive)
        XCTAssertEqual(reconciled.deadline, deadline)
    }

    func testFakeAwakeBackendCreatesDeadlineAndStops() throws {
        let backend = FakeAwakeBackend()
        let started = try backend.start(duration: .thirty, now: reference)
        XCTAssertTrue(started.isActive)
        XCTAssertEqual(started.deadline, reference.addingTimeInterval(30 * 60))
        let stopped = backend.stop()
        XCTAssertFalse(stopped.isActive)
        XCTAssertNil(stopped.deadline)
    }

    func testFakeAwakeBackendStartReplacesExisting() throws {
        let backend = FakeAwakeBackend()
        _ = try backend.start(duration: .thirty, now: reference)
        let replaced = try backend.start(duration: .sixty, now: reference.addingTimeInterval(60))
        XCTAssertEqual(replaced.chosenDuration, .sixty)
        XCTAssertEqual(replaced.deadline, reference.addingTimeInterval(60 + 60 * 60))
    }

    func testAwakeDurationAllCases() {
        XCTAssertEqual(AwakeDuration.thirty.minutes, 30)
        XCTAssertEqual(AwakeDuration.sixty.minutes, 60)
        XCTAssertEqual(AwakeDuration.oneTwenty.minutes, 120)
        XCTAssertEqual(AwakeDuration.allCases.count, 3)
    }

    // MARK: - AwakeController shared lifecycle
    //
    // These exercise the exact controller the live IOPM-backed backend runs,
    // via an injected fake driver + manually-driven scheduler. No real IOPM
    // call is ever made.

    func testControllerFailCreateLeavesInactive() {
        let driver = FakeAwakeAssertionDriver()
        driver.nextCreateFailureStatus = -1
        let controller = AwakeController(driver: driver, scheduler: ManualAwakeScheduler())
        XCTAssertThrowsError(try controller.start(duration: .thirty, now: reference)) { error in
            XCTAssertEqual(error as? AwakeError, .createFailed(status: -1))
        }
        XCTAssertFalse(controller.current().isActive)
        XCTAssertNil(controller.current().deadline)
    }

    func testControllerReplaceFailLeavesInactiveNotStaleActive() throws {
        let driver = FakeAwakeAssertionDriver()
        let scheduler = ManualAwakeScheduler()
        let controller = AwakeController(driver: driver, scheduler: scheduler)
        _ = try controller.start(duration: .thirty, now: reference)
        XCTAssertTrue(controller.current().isActive)
        driver.nextCreateFailureStatus = -2
        XCTAssertThrowsError(try controller.start(duration: .sixty, now: reference.addingTimeInterval(10)))
        // The old assertion was released as part of the replace attempt; the
        // failed create must not leave state claiming it is still active.
        XCTAssertFalse(controller.current().isActive)
        XCTAssertNil(controller.current().deadline)
        XCTAssertEqual(driver.releasedIDs.count, 1, "old assertion must be released exactly once")
    }

    func testControllerExpiryReleasesAndGoesInactive() throws {
        let driver = FakeAwakeAssertionDriver()
        let scheduler = ManualAwakeScheduler()
        let controller = AwakeController(driver: driver, scheduler: scheduler)
        _ = try controller.start(duration: .thirty, now: reference)
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.fireAll()
        XCTAssertFalse(controller.current().isActive)
        XCTAssertNil(controller.current().deadline)
        XCTAssertEqual(driver.releasedIDs, [1])
    }

    func testControllerDoubleStopIsIdempotent() throws {
        let driver = FakeAwakeAssertionDriver()
        let controller = AwakeController(driver: driver, scheduler: ManualAwakeScheduler())
        _ = try controller.start(duration: .thirty, now: reference)
        _ = controller.stop()
        let second = controller.stop()
        XCTAssertFalse(second.isActive)
        // Only one real release call for the one real assertion that existed.
        XCTAssertEqual(driver.releasedIDs, [1])
    }

    /// A real `Timer.invalidate()` cannot un-fire a closure that the run
    /// loop already dequeued and is in the middle of invoking — this
    /// scheduler models that race by recording every scheduled closure and
    /// letting the test invoke ANY of them regardless of whether the
    /// controller "cancelled" it. This proves the controller's own
    /// generation counter — not the scheduler's bookkeeping — is what makes
    /// a superseded timer callback a no-op.
    private final class RaceProneScheduler: AwakeScheduler, @unchecked Sendable {
        private(set) var scheduled: [@Sendable () -> Void] = []
        func schedule(after seconds: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> AnyObject {
            scheduled.append(fire)
            return NSObject()
        }
        func cancel(_ token: AnyObject) {} // intentionally does nothing — models the race
    }

    func testControllerStaleTimerCallbackCannotClearNewerAssertion() throws {
        let driver = FakeAwakeAssertionDriver()
        let scheduler = RaceProneScheduler()
        let controller = AwakeController(driver: driver, scheduler: scheduler)
        _ = try controller.start(duration: .thirty, now: reference)
        let staleCallback = scheduler.scheduled[0]
        // Replace before the first (stale) timer fires.
        _ = try controller.start(duration: .sixty, now: reference.addingTimeInterval(5))
        XCTAssertTrue(controller.current().isActive)
        let deadlineBefore = controller.current().deadline
        // The old timer's closure fires anyway (the race the scheduler
        // cannot fully prevent) — the controller must recognize it is stale
        // and leave the CURRENT (newer) assertion's state untouched.
        staleCallback()
        XCTAssertTrue(controller.current().isActive, "a stale callback must not deactivate the current assertion")
        XCTAssertEqual(controller.current().deadline, deadlineBefore)
        XCTAssertEqual(driver.releasedIDs, [1], "only the old assertion (released on replace) — the stale callback must not release the current one")
    }

    func testControllerNoAutostartOnInit() {
        let driver = FakeAwakeAssertionDriver()
        _ = AwakeController(driver: driver, scheduler: ManualAwakeScheduler())
        XCTAssertTrue(driver.createCalls.isEmpty, "constructing the controller must not create an assertion")
    }

    func testControllerUsesRealIOPMKeyNames() throws {
        let driver = FakeAwakeAssertionDriver()
        let controller = AwakeController(driver: driver, scheduler: ManualAwakeScheduler())
        _ = try controller.start(duration: .sixty, now: reference)
        guard let call = driver.createCalls.first else { return XCTFail("expected a create call") }
        XCTAssertEqual(call.type, "PreventUserIdleSystemSleep")
        XCTAssertEqual(call.level, 255)
        XCTAssertEqual(call.timeoutSeconds, 3600)
        XCTAssertEqual(call.timeoutAction, "TimeoutActionRelease")
    }
}
