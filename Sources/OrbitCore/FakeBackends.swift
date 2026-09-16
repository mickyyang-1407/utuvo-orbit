import Foundation

// MARK: - In-memory fake backends
//
// Every fake is `@unchecked Sendable` and stores state inside `Lock`-protected
// boxes so the live monitor can also call into them in `--gallery`/`--fixture`
// modes (and so tests can verify state mutations deterministically).

public final class Box<T>: @unchecked Sendable {
    private var value: T
    // NSRecursiveLock so a read closure that re-enters via mutate does not
    // deadlock on the same thread (NSLock would hang). The deadlock was real
    // in LiveSystemBackend.metrics where previousCPU.read held the lock while
    // it called previousCPU.mutate to store the new ticks.
    private let lock = NSRecursiveLock()
    public init(_ initial: T) { value = initial }
    public func read<R>(_ body: (T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(value) }
    public func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; var v = value; body(&v); value = v }
    /// Read-modify-write that also returns a value, all under one lock
    /// acquisition. Use this for "compute next state from current state and
    /// return the result" without risking nested locking.
    public func transform<R>(_ body: (T, inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        var v = value
        let result = body(v, &v)
        value = v
        return result
    }
}

public final class FakeAudioBackend: AudioBackend, @unchecked Sendable {
    private let impl: AudioBackendImpl
    public init(driver: FakeAudioHALDriver) {
        self.impl = AudioBackendImpl(driver: driver)
    }
    public convenience init(state: AudioState = .unknown) {
        // Construct a minimal fake driver from a legacy AudioState so older
        // call sites keep working.
        let deviceID = state.device?.id ?? 0
        let devices: [UInt32: FakeAudioHALDriver.DeviceState] = {
            guard deviceID != 0 else { return [:] }
            return [deviceID: .init(name: state.device?.name ?? "音訊輸出",
                                    hasSettableVolume: state.device?.hasWritableVolume ?? false,
                                    currentScalar: state.masterVolume.map(Float32.init),
                                    currentMuted: state.muted)]
        }()
        self.init(driver: FakeAudioHALDriver(snapshot: .init(defaultID: deviceID, devices: devices)))
    }
    public func current() -> AudioState { impl.current() }
    public func selectDefaultOutput(deviceID: UInt32) throws -> AudioState {
        try impl.selectDefaultOutput(deviceID: deviceID)
    }
    public func setMasterVolume(_ value: Double, expectedDeviceID: UInt32) throws -> AudioState {
        try impl.setMasterVolume(value, expectedDeviceID: expectedDeviceID)
    }
    public func setMuted(_ muted: Bool, expectedDeviceID: UInt32) throws -> AudioState {
        try impl.setMuted(muted, expectedDeviceID: expectedDeviceID)
    }
}

public final class FakeNetworkBackend: NetworkBackend, @unchecked Sendable {
    /// Bounded playback state: an immutable `script`, a cursor into it, and
    /// a single `last` reading — never a growing array. The previous
    /// implementation ignored `script`'s order entirely (every call jumped
    /// straight to "the script's last element + one synthetic tick") and
    /// appended to an ever-growing backing array on every single call.
    private struct State {
        let script: [NetworkReading]
        var index = 0
        var last: NetworkReading?
    }
    private let state: Box<State>
    public init(readings: [NetworkReading] = []) { self.state = Box(State(script: readings)) }

    public func currentReading() -> NetworkReading {
        state.transform { current, newValue in
            var next = current
            let reading: NetworkReading
            if next.index < next.script.count {
                // Play the scripted sequence back in order first.
                reading = next.script[next.index]
                next.index += 1
            } else if let last = next.last {
                // Script exhausted: keep the preview graph moving, but never
                // manufacture valid traffic out of an invalid/offline state
                // — only advance counters when the last sample was itself a
                // valid, reachable reading.
                if last.countersValid && last.isReachable {
                    reading = NetworkReading(interfaceName: last.interfaceName, interfaceType: last.interfaceType,
                                             localIPv4: last.localIPv4, isReachable: last.isReachable,
                                             receivedBytes: last.receivedBytes &+ 12_000,
                                             sentBytes: last.sentBytes &+ 3_000,
                                             timestamp: Date(), monotonicSeconds: last.monotonicSeconds + 1,
                                             countersValid: true)
                } else {
                    reading = NetworkReading(interfaceName: last.interfaceName, interfaceType: last.interfaceType,
                                             localIPv4: last.localIPv4, isReachable: last.isReachable,
                                             receivedBytes: last.receivedBytes, sentBytes: last.sentBytes,
                                             timestamp: Date(), monotonicSeconds: last.monotonicSeconds + 1,
                                             countersValid: last.countersValid)
                }
            } else {
                reading = NetworkReading(interfaceName: nil, interfaceType: .offline,
                                         localIPv4: nil, isReachable: false,
                                         receivedBytes: 0, sentBytes: 0,
                                         timestamp: Date(), monotonicSeconds: 0, countersValid: false)
            }
            next.last = reading
            newValue = next
            return reading
        }
    }
}

public final class FakeSystemBackend: SystemBackend, @unchecked Sendable {
    private let metrics: Box<SystemMetrics>
    private let evidence: HardwareEvidence
    public init(metrics: SystemMetrics, evidence: HardwareEvidence) {
        self.metrics = Box(metrics); self.evidence = evidence
    }
    public func metrics(historyCapacity: Int) -> SystemMetrics {
        metrics.read { snapshot in
            var copy = snapshot
            if copy.cpuHistory.count > historyCapacity {
                copy.cpuHistory = Array(copy.cpuHistory.suffix(historyCapacity))
            }
            return copy
        }
    }
    public func modelIdentifier() -> String { evidence.model }
    public func hardwareEvidence() -> HardwareEvidence { evidence }
}

/// Thin wrapper over the shared `AwakeController` used by live code, backed
/// by an in-memory driver + manually-driven scheduler. This means gallery /
/// fixture / test call sites exercise the exact same replace, stop and
/// stale-timer logic the live IOPM-backed path runs — not a hand-duplicated
/// state machine.
public final class FakeAwakeBackend: AwakeBackend, @unchecked Sendable {
    private let controller: AwakeController
    public init(initial: AwakeState = .inactive) {
        let driver = FakeAwakeAssertionDriver()
        let scheduler = ManualAwakeScheduler()
        controller = AwakeController(driver: driver, scheduler: scheduler)
        if initial.isActive, let deadline = initial.deadline {
            let elapsedBack = TimeInterval(initial.chosenDuration.minutes * 60)
            _ = try? controller.start(duration: initial.chosenDuration, now: deadline.addingTimeInterval(-elapsedBack))
        }
    }
    public func current() -> AwakeState { controller.current() }
    public func start(duration: AwakeDuration, now: Date) throws -> AwakeState {
        try controller.start(duration: duration, now: now)
    }
    public func stop() -> AwakeState { controller.stop() }
    /// Injected clock: when the wall clock crosses the deadline, the fake
    /// transitions to inactive just like the live timer-driven path would.
    public func advanceClock(to now: Date) -> AwakeState { controller.advanceClock(to: now) }
}

/// In-memory preferences that optionally seed from a legacy values dict so we
/// can test the migration codepath without touching real UserDefaults.
public final class FakePreferencesBackend: PreferencesBackend, @unchecked Sendable {
    private var values: OrbitPreferencesValues
    private let legacy: [String: Any]?
    public init(initial: OrbitPreferencesValues = .init(), legacy: [String: Any]? = nil) {
        self.values = initial; self.legacy = legacy
        self.values = Self.migrateIfNeeded(current: initial, legacy: legacy)
    }
    public func load() -> OrbitPreferencesValues {
        var copy = values
        copy.pin = false
        return copy
    }
    public func save(_ values: OrbitPreferencesValues) {
        var copy = values
        copy.pin = false
        self.values = copy
    }

    static func migrateIfNeeded(current: OrbitPreferencesValues, legacy: [String: Any]?) -> OrbitPreferencesValues {
        // Migration is only meaningful when the new keys are at their defaults
        // and the legacy dict has at least one of the three recognised keys.
        let looksFresh = OrbitPreferencesStore.looksFresh(current)
        guard looksFresh, let legacy else { return current }
        let presence: (String) -> Bool = { _ in false }
        return OrbitPreferencesStore.migrate(current: current, legacyDefaults: legacy, presenceOf: presence)
    }
}
