import Foundation

// MARK: - Audio HAL driver abstraction
//
// The audio backend writes go through a thin "driver" layer that the live
// CoreAudio path and the fake test path both implement. This lets the tests
// exercise the exact code the live app uses (including stale-device guards,
// balance preservation, OSStatus propagation) instead of a permissive mock
// that only verifies the protocol surface.

public protocol AudioHALDriver: AnyObject, Sendable {
    /// Returns the current default output device ID, or 0 if none.
    func defaultOutputDeviceID() -> UInt32
    /// Returns the human-readable name for the given device ID.
    func deviceName(for id: UInt32) -> String
    /// True when the given device exposes a settable scalar virtual main volume.
    func hasSettableVirtualMainVolume(_ id: UInt32) -> Bool
    /// Returns the current master scalar (0...1) or nil if not exposed.
    func masterScalar(_ id: UInt32) -> Float32?
    /// Returns the current mute state. nil if not exposed.
    func muted(_ id: UInt32) -> Bool?
    /// True when the given device exposes a settable mute toggle (distinct
    /// from merely being able to read one).
    func hasSettableMute(_ id: UInt32) -> Bool
    /// Writes the virtual main volume on the given device. Returns OSStatus.
    func writeVirtualMainVolume(_ value: Float32, on id: UInt32) -> Int32
    /// Writes the mute state on the given device. Returns OSStatus.
    func writeMute(_ muted: Bool, on id: UInt32) -> Int32
    /// Lists currently available output devices.
    func allOutputs() -> [UInt32]
    /// Writes the system default output device. Returns OSStatus. The shared
    /// core validates the target is a known output BEFORE calling this and
    /// reads state back after — this call only performs the write.
    func setDefaultOutput(_ id: UInt32) -> Int32
    /// True when this driver can be considered "real" (i.e. live hardware).
    /// Used so we can decide between fake and real error semantics in tests.
    var isLive: Bool { get }
}

extension AudioError {
    /// A stable numeric tag we can stash in `AudioState.lastOSStatus` so the
    /// UI can distinguish stale-device errors from raw OSStatus values.
    public var errorCode: Int32 {
        switch self {
        case .staleDevice: return -10001
        case .writeFailed(let s): return s
        case .unsupported: return -10002
        }
    }
}

extension AudioState {
    public func withStatus(_ status: Int32?) -> AudioState {
        AudioState(available: available, muted: muted, masterVolume: masterVolume,
                   device: device, outputs: outputs, lastOSStatus: status)
    }
}

// MARK: - AudioBackend shared core
//
// This is the only place that knows the write/read protocol. Live and fake
// share it; both inject an `AudioHALDriver` so tests can simulate device
// switches, write failures and balance-aware volume without spinning up a
// real CoreAudio session.

public final class AudioBackendImpl: AudioBackend, @unchecked Sendable {
    private let driver: AudioHALDriver
    /// Sticky UI-facing error status only — NOT a cache of device/volume
    /// data. `current()` always re-reads the driver; only this status
    /// persists across polls, until the next write attempt overwrites it.
    private let stickyStatus = Box<Int32?>(nil)

    public init(driver: AudioHALDriver) { self.driver = driver }

    public func current() -> AudioState {
        readState().withStatus(stickyStatus.read { $0 })
    }

    public func selectDefaultOutput(deviceID: UInt32) throws -> AudioState {
        guard driver.allOutputs().contains(deviceID) else {
            try fail(.writeFailed(status: -50))
        }
        let status = driver.setDefaultOutput(deviceID)
        guard status == noErr else { try fail(.writeFailed(status: status)) }
        return succeed()
    }

    public func setMasterVolume(_ value: Double, expectedDeviceID: UInt32) throws -> AudioState {
        guard value.isFinite, value >= 0, value <= 1 else {
            try fail(.writeFailed(status: -50))
        }
        let freshID = driver.defaultOutputDeviceID()
        guard freshID != 0, freshID == expectedDeviceID else {
            try fail(.staleDevice(expected: expectedDeviceID, actual: freshID))
        }
        guard driver.hasSettableVirtualMainVolume(freshID) else {
            try fail(.unsupported)
        }
        let status = driver.writeVirtualMainVolume(Float32(value), on: freshID)
        guard status == noErr else { try fail(.writeFailed(status: status)) }
        return succeed()
    }

    public func setMuted(_ muted: Bool, expectedDeviceID: UInt32) throws -> AudioState {
        let freshID = driver.defaultOutputDeviceID()
        guard freshID != 0, freshID == expectedDeviceID else {
            try fail(.staleDevice(expected: expectedDeviceID, actual: freshID))
        }
        guard driver.hasSettableMute(freshID) else {
            try fail(.unsupported)
        }
        let status = driver.writeMute(muted, on: freshID)
        guard status == noErr else { try fail(.writeFailed(status: status)) }
        return succeed()
    }

    /// Records the sticky UI-facing error and throws it. `Never` lets call
    /// sites use `try fail(...)` as the sole statement in a `guard ... else`
    /// block.
    private func fail(_ error: AudioError) throws -> Never {
        stickyStatus.mutate { $0 = error.errorCode }
        throw error
    }
    private func succeed() -> AudioState {
        stickyStatus.mutate { $0 = nil }
        return current()
    }

    public func readState() -> AudioState {
        let id = driver.defaultOutputDeviceID()
        guard id != 0 else {
            let outputs = driver.allOutputs().map { deviceID in
                AudioDeviceInfo(id: deviceID, name: driver.deviceName(for: deviceID),
                                hasWritableVolume: driver.hasSettableVirtualMainVolume(deviceID),
                                hasWritableMute: driver.hasSettableMute(deviceID),
                                reportsVolume: driver.masterScalar(deviceID) != nil)
            }
            return AudioState(available: false, muted: false, masterVolume: nil,
                              device: nil, outputs: outputs, lastOSStatus: nil)
        }
        let name = driver.deviceName(for: id)
        let hasSettable = driver.hasSettableVirtualMainVolume(id)
        let scalar = driver.masterScalar(id)
        let muteState = driver.muted(id)
        let outputs = driver.allOutputs().map { deviceID in
            AudioDeviceInfo(id: deviceID, name: driver.deviceName(for: deviceID),
                            hasWritableVolume: driver.hasSettableVirtualMainVolume(deviceID),
                            hasWritableMute: driver.hasSettableMute(deviceID),
                            reportsVolume: driver.masterScalar(deviceID) != nil)
        }
        let device = AudioDeviceInfo(id: id, name: name,
                                     hasWritableVolume: hasSettable,
                                     hasWritableMute: driver.hasSettableMute(id),
                                     reportsVolume: scalar != nil)
        return AudioState(available: true,
                          muted: muteState ?? false,
                          masterVolume: scalar.map(Double.init),
                          device: device, outputs: outputs, lastOSStatus: nil)
    }
}

// MARK: - Fake Audio HAL driver (tests)

public final class FakeAudioHALDriver: AudioHALDriver, @unchecked Sendable {
    public struct Snapshot {
        public var defaultID: UInt32
        public var devices: [UInt32: DeviceState]
        public var nextWriteFailure: Int32?
        public init(defaultID: UInt32, devices: [UInt32: DeviceState], nextWriteFailure: Int32? = nil) {
            self.defaultID = defaultID; self.devices = devices
            self.nextWriteFailure = nextWriteFailure
        }
    }
    public struct DeviceState {
        public var name: String
        public var hasSettableVolume: Bool
        public var currentScalar: Float32?
        public var currentMuted: Bool?
        /// Defaults to "settable iff the mute state is even readable", but
        /// tests can override to simulate a device that reports mute
        /// read-only (readable, not settable).
        public var hasSettableMute: Bool
        public var writeHistory: [(Float32?, Bool?)]
        public init(name: String, hasSettableVolume: Bool, currentScalar: Float32?, currentMuted: Bool?,
                    hasSettableMute: Bool? = nil, writeHistory: [(Float32?, Bool?)] = []) {
            self.name = name; self.hasSettableVolume = hasSettableVolume
            self.currentScalar = currentScalar; self.currentMuted = currentMuted
            self.hasSettableMute = hasSettableMute ?? (currentMuted != nil)
            self.writeHistory = writeHistory
        }
    }
    private let lock = NSLock()
    private var snapshot: Snapshot
    public let isLive: Bool = false
    public init(snapshot: Snapshot) { self.snapshot = snapshot }
    public func defaultOutputDeviceID() -> UInt32 { lock.lock(); defer { lock.unlock() }; return snapshot.defaultID }
    public func deviceName(for id: UInt32) -> String {
        lock.lock(); defer { lock.unlock() }
        return snapshot.devices[id]?.name ?? "未知"
    }
    public func hasSettableVirtualMainVolume(_ id: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.devices[id]?.hasSettableVolume ?? false
    }
    public func masterScalar(_ id: UInt32) -> Float32? {
        lock.lock(); defer { lock.unlock() }
        return snapshot.devices[id]?.currentScalar
    }
    public func muted(_ id: UInt32) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return snapshot.devices[id]?.currentMuted
    }
    public func hasSettableMute(_ id: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshot.devices[id]?.hasSettableMute ?? false
    }
    public func setDefaultOutput(_ id: UInt32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if let failure = snapshot.nextWriteFailure {
            snapshot.nextWriteFailure = nil
            return failure
        }
        guard snapshot.devices[id] != nil else { return -50 }
        snapshot.defaultID = id
        return 0
    }
    public func writeVirtualMainVolume(_ value: Float32, on id: UInt32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if let failure = snapshot.nextWriteFailure {
            snapshot.nextWriteFailure = nil
            return failure
        }
        guard var device = snapshot.devices[id] else { return -50 }
        device.currentScalar = value
        device.writeHistory.append((value, nil))
        snapshot.devices[id] = device
        return 0
    }
    public func writeMute(_ muted: Bool, on id: UInt32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if let failure = snapshot.nextWriteFailure {
            snapshot.nextWriteFailure = nil
            return failure
        }
        guard var device = snapshot.devices[id] else { return -50 }
        device.currentMuted = muted
        device.writeHistory.append((nil, muted))
        snapshot.devices[id] = device
        return 0
    }
    public func allOutputs() -> [UInt32] {
        lock.lock(); defer { lock.unlock() }
        return Array(snapshot.devices.keys)
    }
    /// Test helper: change the current default and force a stale-device error.
    public func changeDefault(to id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        snapshot.defaultID = id
    }
    /// Test helper: simulate an external change (another app, hardware knob,
    /// remote) that did not go through this backend's write path at all.
    public func externallySetScalar(_ value: Float32, on id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        snapshot.devices[id]?.currentScalar = value
    }
    /// Test helper: simulate a hotplug — a new device becomes available.
    public func addDevice(id: UInt32, name: String, hasSettableVolume: Bool,
                          currentScalar: Float32?, currentMuted: Bool?) {
        lock.lock(); defer { lock.unlock() }
        snapshot.devices[id] = DeviceState(name: name, hasSettableVolume: hasSettableVolume,
                                           currentScalar: currentScalar, currentMuted: currentMuted)
    }
    /// Test helper: script the next OS-level write (volume, mute, OR default
    /// output — all funnel through the same simulated OSStatus) to fail.
    public func scriptNextWriteFailure(_ status: Int32) {
        lock.lock(); defer { lock.unlock() }
        snapshot.nextWriteFailure = status
    }
}