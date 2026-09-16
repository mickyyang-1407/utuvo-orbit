import Foundation

// MARK: - Shared Awake lifecycle core
//
// Both the live backend (real IOPMAssertion) and the test/gallery fake share
// this controller. Only the assertion driver (talks to IOKit vs. an in-memory
// snapshot) and the scheduler (real Timer/RunLoop vs. a manually-fired queue)
// differ. This guarantees tests exercise the exact replace/expiry/stale-timer
// logic the live app runs, instead of a hand-duplicated fake state machine.

public protocol AwakeAssertionDriver: AnyObject, Sendable {
    /// Creates the assertion. `status == 0` (kIOReturnSuccess) means `id` is
    /// valid and must eventually be released.
    func createAssertion(name: String, type: String, level: UInt32,
                         timeoutSeconds: UInt32, timeoutAction: String) -> (status: Int32, id: UInt32)
    /// Releases a previously created assertion. Idempotent from the caller's
    /// perspective — the controller never calls this twice for the same id.
    func releaseAssertion(_ id: UInt32) -> Int32
}

/// Abstraction over "run this closure after N seconds". The live
/// implementation wraps `Timer` + `RunLoop.main`; tests use a manually-driven
/// scheduler so expiry can be exercised without a real wait.
public protocol AwakeScheduler: AnyObject, Sendable {
    func schedule(after seconds: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> AnyObject
    func cancel(_ token: AnyObject)
}

/// Shared lifecycle: create/replace/stop/expire, all funneled through one
/// state machine so every caller (live app, tests, gallery) sees identical
/// behavior for the cases that matter: failed create, failed replace, timer
/// expiry, double stop and stale (superseded) timer callbacks.
public final class AwakeController: AwakeBackend, @unchecked Sendable {
    private let driver: AwakeAssertionDriver
    private let scheduler: AwakeScheduler
    private let state = Box<AwakeState>(.inactive)
    private let lock = NSLock()
    private var assertionID: UInt32 = 0
    private var activeToken: AnyObject?
    /// Bumped on every start/stop so a timer callback scheduled for a
    /// previous assertion can recognize it has been superseded and no-op.
    private var generation: UInt64 = 0

    public init(driver: AwakeAssertionDriver, scheduler: AwakeScheduler) {
        self.driver = driver
        self.scheduler = scheduler
    }

    deinit {
        // Defensive: never leave the system assertion dangling across
        // controller/process exit.
        if assertionID != 0 { _ = driver.releaseAssertion(assertionID) }
    }

    public func current() -> AwakeState { state.read { $0 } }

    public func start(duration: AwakeDuration, now: Date) throws -> AwakeState {
        lock.lock(); defer { lock.unlock() }
        cancelScheduledExpiryLocked()
        releaseCurrentAssertionLocked()
        let timeoutSeconds = max(1, UInt32(duration.minutes * 60))
        let result = driver.createAssertion(name: "UTUVO Orbit keep awake",
                                            type: "PreventUserIdleSystemSleep",
                                            level: 255,
                                            timeoutSeconds: timeoutSeconds,
                                            timeoutAction: "TimeoutActionRelease")
        guard result.status == 0 else {
            // A failed replacement must not retain the just-released old
            // assertion's "active" state — the OS-level assertion is gone.
            let failed = AwakeState(isActive: false, deadline: nil,
                                    chosenDuration: state.read { $0.chosenDuration }, lastError: nil)
            state.mutate { $0 = failed }
            throw AwakeError.createFailed(status: result.status)
        }
        assertionID = result.id
        generation &+= 1
        let myGeneration = generation
        let deadline = now.addingTimeInterval(TimeInterval(timeoutSeconds))
        let new = AwakeState(isActive: true, deadline: deadline, chosenDuration: duration, lastError: nil)
        state.mutate { $0 = new }
        activeToken = scheduler.schedule(after: TimeInterval(timeoutSeconds)) { [weak self] in
            self?.handleTimeout(generation: myGeneration)
        }
        return new
    }

    public func stop() -> AwakeState {
        lock.lock(); defer { lock.unlock() }
        cancelScheduledExpiryLocked()
        releaseCurrentAssertionLocked()
        generation &+= 1 // any in-flight timer callback is now stale
        let new = AwakeState(isActive: false, deadline: nil,
                             chosenDuration: state.read { $0.chosenDuration }, lastError: nil)
        state.mutate { $0 = new }
        return new
    }

    /// The live path's real expiry is driven entirely by the OS-level
    /// timeout plus the independent scheduler callback above — both fire
    /// without this call. It exists only so a caller can reconcile UI state
    /// if the deadline has already silently passed (e.g. after the app was
    /// suspended). It never touches the driver or scheduler itself.
    public func advanceClock(to now: Date) -> AwakeState {
        state.transform { current, newValue in
            guard current.isActive, let deadline = current.deadline, now >= deadline else { return current }
            var reconciled = current
            reconciled.isActive = false
            reconciled.deadline = nil
            newValue = reconciled
            return reconciled
        }
    }

    private func handleTimeout(generation callGeneration: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard callGeneration == generation else { return } // superseded by a newer start()/stop()
        releaseCurrentAssertionLocked()
        activeToken = nil
        state.mutate { $0.isActive = false; $0.deadline = nil }
    }

    private func cancelScheduledExpiryLocked() {
        if let token = activeToken { scheduler.cancel(token) }
        activeToken = nil
    }

    private func releaseCurrentAssertionLocked() {
        if assertionID != 0 {
            _ = driver.releaseAssertion(assertionID)
            assertionID = 0
        }
    }
}

// MARK: - Fakes (tests + gallery)

/// In-memory assertion driver. `nextCreateFailureStatus` lets a single test
/// script a failed create/replace without any real IOPM call.
public final class FakeAwakeAssertionDriver: AwakeAssertionDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    public var nextCreateFailureStatus: Int32?
    public private(set) var createCalls: [(name: String, type: String, level: UInt32, timeoutSeconds: UInt32, timeoutAction: String)] = []
    public private(set) var releasedIDs: [UInt32] = []

    public init() {}

    public func createAssertion(name: String, type: String, level: UInt32,
                                timeoutSeconds: UInt32, timeoutAction: String) -> (status: Int32, id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        createCalls.append((name, type, level, timeoutSeconds, timeoutAction))
        if let failure = nextCreateFailureStatus {
            nextCreateFailureStatus = nil
            return (failure, 0)
        }
        let id = nextID
        nextID += 1
        return (0, id)
    }

    public func releaseAssertion(_ id: UInt32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        releasedIDs.append(id)
        return 0
    }
}

/// Manually-driven scheduler: `schedule` records the pending fire closure
/// instead of touching a real Timer/RunLoop. Tests call `fireAll(before:)` or
/// `fireOldest()` to simulate expiry deterministically.
public final class ManualAwakeScheduler: AwakeScheduler, @unchecked Sendable {
    private final class Token { let fire: () -> Void; var cancelled = false; init(_ fire: @escaping () -> Void) { self.fire = fire } }
    private let lock = NSLock()
    private var pending: [Token] = []

    public init() {}

    public func schedule(after seconds: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> AnyObject {
        lock.lock(); defer { lock.unlock() }
        let token = Token(fire)
        pending.append(token)
        return token
    }

    public func cancel(_ token: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        (token as? Token)?.cancelled = true
    }

    /// Fires every still-pending, non-cancelled callback (oldest first) and
    /// clears the queue. Used by tests to simulate the OS-level timeout.
    public func fireAll() {
        lock.lock()
        let tokens = pending
        pending.removeAll()
        lock.unlock()
        for token in tokens where !token.cancelled { token.fire() }
    }

    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.filter { !$0.cancelled }.count }
}
