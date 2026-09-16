import Foundation

// MARK: - Backend protocols
//
// All side-effecting surfaces are abstracted behind protocols so tests, gallery
// mode and the live monitor can share the same call sites. Default live impls
// live in the executable target (UtuvoOrbit). Fakes live next to them here so
// the OrbitCore target stays platform-agnostic.

public struct AudioDeviceInfo: Equatable, Sendable, Codable {
    public var id: UInt32
    public var name: String
    /// True when the device exposes a writable scalar master volume the app can drive.
    public var hasWritableVolume: Bool
    /// True when the device exposes a writable mute toggle.
    public var hasWritableMute: Bool
    /// True when the device has any volume property at all (master or per-channel).
    public var reportsVolume: Bool

    public init(id: UInt32, name: String, hasWritableVolume: Bool, hasWritableMute: Bool, reportsVolume: Bool) {
        self.id = id; self.name = name
        self.hasWritableVolume = hasWritableVolume
        self.hasWritableMute = hasWritableMute
        self.reportsVolume = reportsVolume
    }
}

public struct AudioState: Equatable, Sendable, Codable {
    public var available: Bool
    public var muted: Bool
    /// Volume in 0...1 if the device exposes a master scalar, otherwise nil.
    public var masterVolume: Double?
    public var device: AudioDeviceInfo?
    /// Devices the user can pick from. Empty when nothing is available.
    public var outputs: [AudioDeviceInfo]
    public var lastOSStatus: Int32?

    public init(available: Bool, muted: Bool, masterVolume: Double?, device: AudioDeviceInfo?, outputs: [AudioDeviceInfo], lastOSStatus: Int32? = nil) {
        self.available = available; self.muted = muted; self.masterVolume = masterVolume
        self.device = device; self.outputs = outputs; self.lastOSStatus = lastOSStatus
    }

    public static let unknown = AudioState(available: false, muted: false, masterVolume: nil, device: nil, outputs: [], lastOSStatus: nil)
}

public enum AudioError: Error, Equatable, Sendable {
    case staleDevice(expected: UInt32, actual: UInt32)
    case writeFailed(status: Int32)
    case unsupported
}

public protocol AudioBackend: AnyObject, Sendable {
    /// Fresh snapshot of the current default output + device list — always
    /// re-reads the driver, never a cached value, so hotplug and external
    /// volume/mute changes show up on the next poll.
    func current() -> AudioState
    /// Pick a new default output. Returns refreshed state.
    func selectDefaultOutput(deviceID: UInt32) throws -> AudioState
    /// Set master scalar volume (0...1). `expectedDeviceID` is the device the
    /// caller (UI) was showing when the user acted — the write is rejected as
    /// `.staleDevice` if the driver's fresh default no longer matches it, so
    /// a concurrent poll can never move the comparison target out from under
    /// the user's gesture.
    func setMasterVolume(_ value: Double, expectedDeviceID: UInt32) throws -> AudioState
    /// Set mute state. See `setMasterVolume` for `expectedDeviceID`.
    func setMuted(_ muted: Bool, expectedDeviceID: UInt32) throws -> AudioState
}

public struct NetworkReading: Equatable, Sendable, Codable {
    /// `nil` means no path is currently usable (offline or checking).
    public var interfaceName: String?
    public var interfaceType: Connection
    /// IPv4 address of the active interface, when known.
    public var localIPv4: String?
    public var isReachable: Bool
    /// Cumulative byte counters read from the OS at `timestamp`.
    public var receivedBytes: UInt64
    public var sentBytes: UInt64
    /// Wall-clock at sample time, kept for display.
    public var timestamp: Date
    /// Monotonic sample stamp — `mach_continuous_time`-derived seconds since
    /// boot, used by delta math so paused runloops, wake from sleep and
    /// DST jumps never corrupt throughput.
    public var monotonicSeconds: Double
    /// False when `receivedBytes`/`sentBytes` were NOT actually read from a
    /// live counter this sample (interface read failure, missing target,
    /// nil `ifa_data`, or the reading is inherently counter-less like
    /// offline/checking) — distinct from a genuinely valid zero-traffic
    /// reading. `NetworkMath.delta` must treat an invalid reading as
    /// "unknown", never as "0 B/s".
    public var countersValid: Bool

    public init(interfaceName: String?, interfaceType: Connection, localIPv4: String?,
                isReachable: Bool, receivedBytes: UInt64, sentBytes: UInt64,
                timestamp: Date, monotonicSeconds: Double, countersValid: Bool = true) {
        self.interfaceName = interfaceName
        self.interfaceType = interfaceType
        self.localIPv4 = localIPv4
        self.isReachable = isReachable
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.timestamp = timestamp
        self.monotonicSeconds = monotonicSeconds
        self.countersValid = countersValid
    }

    public static let offline = NetworkReading(
        interfaceName: nil, interfaceType: .offline, localIPv4: nil,
        isReachable: false, receivedBytes: 0, sentBytes: 0,
        timestamp: Date(timeIntervalSinceReferenceDate: 0), monotonicSeconds: 0,
        countersValid: false)
}

public struct NetworkSample: Equatable, Sendable, Codable {
    /// Bytes per second averaged over the interval since the previous
    /// sample. `nil` means "no valid rate yet" (first sample, interface
    /// change, reset, offline) — the UI must show "—", never coalesce this
    /// to a fake zero.
    public var downloadBytesPerSecond: Double?
    public var uploadBytesPerSecond: Double?
    /// Local IPv4 address (best-effort, copied by the caller).
    public var localIPv4: String?
    public var interfaceName: String?
    public var interfaceType: Connection
    public var reachable: Bool

    public init(downloadBytesPerSecond: Double?, uploadBytesPerSecond: Double?, localIPv4: String?,
                interfaceName: String?, interfaceType: Connection = .checking, reachable: Bool) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.localIPv4 = localIPv4
        self.interfaceName = interfaceName
        self.interfaceType = interfaceType
        self.reachable = reachable
    }

    public static let placeholder = NetworkSample(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil,
                                                  localIPv4: nil, interfaceName: nil, interfaceType: .checking, reachable: false)
}

public protocol NetworkBackend: AnyObject, Sendable {
    func currentReading() -> NetworkReading
}

public struct SystemMetrics: Equatable, Sendable, Codable {
    /// CPU usage in 0...1 if computable, otherwise nil.
    public var cpuUsage: Double?
    /// Rolling CPU history (most-recent last), bounded length.
    public var cpuHistory: [Double]
    /// Used memory in bytes; nil if unreadable.
    public var usedBytes: UInt64?
    /// Total physical memory in bytes; nil if unreadable.
    public var totalBytes: UInt64?
    /// Battery snapshot (nil on a true desktop with no internal battery).
    public var battery: BatteryReading?
    public var machine: MachineKind
    public var model: String

    public init(cpuUsage: Double?, cpuHistory: [Double], usedBytes: UInt64?, totalBytes: UInt64?, battery: BatteryReading?, machine: MachineKind, model: String) {
        self.cpuUsage = cpuUsage; self.cpuHistory = cpuHistory
        self.usedBytes = usedBytes; self.totalBytes = totalBytes
        self.battery = battery; self.machine = machine; self.model = model
    }

    public var memoryFraction: Double? {
        guard let used = usedBytes, let total = totalBytes, total > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }
}

public protocol SystemBackend: AnyObject, Sendable {
    func metrics(historyCapacity: Int) -> SystemMetrics
    func modelIdentifier() -> String
    func hardwareEvidence() -> HardwareEvidence
    /// Clears any baseline the backend caches between polls (e.g. the
    /// previous CPU tick counts) so the caller can force a clean first
    /// sample after a real system wake instead of computing a spike/garbage
    /// delta across the sleep gap. No-op by default.
    func reset()
}

public extension SystemBackend {
    func reset() {}
}

public enum AwakeDuration: Hashable, Sendable, Codable, CaseIterable {
    case thirty
    case sixty
    case oneTwenty
    public var minutes: Int {
        switch self {
        case .thirty: return 30
        case .sixty: return 60
        case .oneTwenty: return 120
        }
    }
    public static var defaultChoice: AwakeDuration { .sixty }
    public var localizedTitle: String {
        switch self {
        case .thirty: return "30 分鐘"
        case .sixty: return "60 分鐘"
        case .oneTwenty: return "120 分鐘"
        }
    }
}

public struct AwakeState: Equatable, Sendable, Codable {
    public var isActive: Bool
    /// Real wall-clock deadline; nil when inactive.
    public var deadline: Date?
    public var chosenDuration: AwakeDuration
    public var lastError: String?

    public init(isActive: Bool, deadline: Date?, chosenDuration: AwakeDuration, lastError: String?) {
        self.isActive = isActive; self.deadline = deadline
        self.chosenDuration = chosenDuration; self.lastError = lastError
    }

    public static let inactive = AwakeState(isActive: false, deadline: nil, chosenDuration: .defaultChoice, lastError: nil)
}

public enum AwakeError: Error, Equatable, Sendable {
    case createFailed(status: Int32)
    case alreadyActive
}

public protocol AwakeBackend: AnyObject, Sendable {
    func current() -> AwakeState
    /// Acquire a new assertion; throws when the underlying IOPM call fails.
    /// Backend must release any existing assertion before creating a new one.
    func start(duration: AwakeDuration, now: Date) throws -> AwakeState
    /// Release the active assertion, if any. Idempotent.
    func stop() -> AwakeState
    /// Advance the simulated clock and reconcile state. The fake uses this to
    /// expire; the live backend ignores it because its deadline is driven by
    /// the OS-level IOPMAssertionTimeoutKey plus an independent in-process timer.
    func advanceClock(to now: Date) -> AwakeState
}

public enum AppTheme: String, CaseIterable, Sendable, Codable {
    case system, light, dark
    public var localizedTitle: String {
        switch self {
        case .system: return "跟隨系統"
        case .light: return "淺色"
        case .dark: return "深色"
        }
    }
}

/// What the center of the combined glyph shows. Desktop `.power`/`.hidden`,
/// unknown machine, and any non-finite value fall back to `.network` — see
/// `CenterContent.resolve` in `GlyphContent.swift`. Default `.network` keeps
/// v0.2's look unchanged until the user opts in.
public enum RingCenter: String, Sendable, Codable, CaseIterable, Equatable {
    case network, percent
    public var localizedTitle: String {
        switch self { case .network: return "網路"; case .percent: return "百分比" }
    }
}

/// `.combined` is the existing single 27pt ring+center glyph. `.classic`
/// renders three separate fixed-width symbols instead (see
/// `OrbitGlyph.classicImage`). Default `.combined` preserves v0.2.
public enum GlyphStyle: String, Sendable, Codable, CaseIterable, Equatable {
    case combined, classic
    public var localizedTitle: String {
        switch self { case .combined: return "合併"; case .classic: return "傳統" }
    }
}

public struct OrbitPreferencesValues: Equatable, Sendable, Codable {
    public var desktopRing: DesktopRing
    public var showPercent: Bool
    public var colorful: Bool
    public var theme: AppTheme
    public var pin: Bool
    public var ringCenter: RingCenter
    public var glyphStyle: GlyphStyle
    public var language: AppLanguage

    public init(desktopRing: DesktopRing = .cpu, showPercent: Bool = false, colorful: Bool = true, theme: AppTheme = .system, pin: Bool = false,
                ringCenter: RingCenter = .network, glyphStyle: GlyphStyle = .combined, language: AppLanguage = .system) {
        self.desktopRing = desktopRing; self.showPercent = showPercent; self.colorful = colorful
        self.theme = theme; self.pin = pin
        self.ringCenter = ringCenter; self.glyphStyle = glyphStyle; self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case desktopRing, showPercent, colorful, theme, pin, ringCenter, glyphStyle, language
    }

    /// Custom decode: 0.2 JSON (or a 0.3 dict missing/invalid new keys) has
    /// no `ringCenter`/`glyphStyle` at all — `decodeIfPresent` falls back to
    /// the default instead of failing the whole decode or fabricating a
    /// value that looks user-chosen.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        // `decodeIfPresent(SomeRawRepresentableEnum.self, forKey:)` only
        // returns `nil` when the KEY is absent/null — if the key IS present
        // but its raw string doesn't match any case, the synthesized
        // `Decodable` for a raw-representable enum THROWS
        // `DecodingError.dataCorrupted` instead of returning `nil`. That
        // previously made an unrecognised (e.g. future/newer) value abort
        // the ENTIRE decode instead of falling back on just that one field —
        // proven by root's probe: `{"ringCenter":"future-value"}` threw
        // rather than defaulting. Decoding each as a plain `String` first
        // and mapping through `init(rawValue:)` ourselves can never throw
        // for a bad value; only a genuine type mismatch (not a string at
        // all) still throws, same as any other malformed field.
        let desktopRingRaw = try box.decodeIfPresent(String.self, forKey: .desktopRing)
        desktopRing = desktopRingRaw.flatMap(DesktopRing.init(rawValue:)) ?? .cpu
        showPercent = try box.decodeIfPresent(Bool.self, forKey: .showPercent) ?? false
        colorful = try box.decodeIfPresent(Bool.self, forKey: .colorful) ?? true
        let themeRaw = try box.decodeIfPresent(String.self, forKey: .theme)
        theme = themeRaw.flatMap(AppTheme.init(rawValue:)) ?? .system
        pin = try box.decodeIfPresent(Bool.self, forKey: .pin) ?? false
        let ringCenterRaw = try box.decodeIfPresent(String.self, forKey: .ringCenter)
        ringCenter = ringCenterRaw.flatMap(RingCenter.init(rawValue:)) ?? .network
        let glyphStyleRaw = try box.decodeIfPresent(String.self, forKey: .glyphStyle)
        glyphStyle = glyphStyleRaw.flatMap(GlyphStyle.init(rawValue:)) ?? .combined
        let languageRaw = try box.decodeIfPresent(String.self, forKey: .language)
        language = languageRaw.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }
}

public protocol PreferencesBackend: AnyObject, Sendable {
    /// Load values; performs one-time migration from the legacy `app.pik.orbit.local`
    /// domain the first time it sees the new keys empty.
    func load() -> OrbitPreferencesValues
    func save(_ values: OrbitPreferencesValues)
}
