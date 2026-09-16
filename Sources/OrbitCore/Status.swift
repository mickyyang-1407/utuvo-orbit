import Foundation
import IOKit.ps

public enum MachineKind: String, Sendable, Codable { case desktop, laptop, unknown }
public enum Connection: String, Sendable, Codable { case wifi, ethernet, other, offline, checking }
public enum DesktopRing: String, CaseIterable, Sendable, Codable, Equatable {
    case cpu, power, hidden
    public var localizedTitle: String {
        switch self {
        case .cpu: return "CPU"
        case .power: return "供電"
        case .hidden: return "隱藏"
        }
    }
}

public struct HardwareEvidence: Sendable {
    public var model: String
    public var hasInternalBattery: Bool
    public var hasLid: Bool
    public var powerReadSucceeded: Bool
    public var registryReadSucceeded: Bool

    public init(model: String, hasInternalBattery: Bool, hasLid: Bool,
                powerReadSucceeded: Bool = true, registryReadSucceeded: Bool = true) {
        self.model = model; self.hasInternalBattery = hasInternalBattery; self.hasLid = hasLid
        self.powerReadSucceeded = powerReadSucceeded; self.registryReadSucceeded = registryReadSucceeded
    }

    public var kind: MachineKind {
        if hasInternalBattery || hasLid || model.hasPrefix("MacBook") { return .laptop }
        if ["Macmini", "MacPro", "iMac", "MacStudio"].contains(where: model.hasPrefix) { return .desktop }
        // Modern model identifiers do not encode the product family. Require both observations.
        if model.range(of: #"^Mac\d+,\d+$"#, options: .regularExpression) != nil,
           powerReadSucceeded, registryReadSucceeded { return .desktop }
        return .unknown
    }
}

public struct BatteryReading: Equatable, Sendable, Codable {
    public var fraction: Double?
    public var charging: Bool
    public var onAC: Bool

    public init(current: Double?, maximum: Double?, charging: Bool, onAC: Bool) {
        if let current, let maximum, current.isFinite, maximum.isFinite, maximum > 0, current >= 0 {
            fraction = min(1, current / maximum)
        } else { fraction = nil }
        self.charging = charging; self.onAC = onAC
    }
}

public struct StatusSnapshot: Sendable, Codable {
    public var machine: MachineKind = .unknown
    public var model = ""
    public var battery: BatteryReading?
    public var cpu: Double?
    public var connection: Connection = .checking
    public var wifiStrength: Int? // 1...3, nil means signal data is withheld
    public var volume: Double?
    public var hasAudioOutput: Bool?
    public var muted = false
    public var audioDevice = "讀取中"

    public init() {}
    public var machineLabel: String {
        switch machine { case .desktop: "桌機"; case .laptop: "筆電"; case .unknown: "機型未確認" }
    }
    public var connectionLabel: String {
        switch connection {
        case .wifi: "Wi-Fi"; case .ethernet: "有線網路"; case .other: "其他網路"
        case .offline: "未連線"; case .checking: "讀取中"
        }
    }
    public var volumeDots: Int? {
        if muted { return 0 }
        guard let volume, volume.isFinite else { return nil }
        return Int(ceil(min(1, max(0, volume)) * 4))
    }
    public var volumeLabel: String {
        guard let hasAudioOutput else { return "讀取中" }
        guard hasAudioOutput else { return "無輸出" }
        if muted { return "靜音" }
        return Self.percent(volume) ?? "由裝置控制"
    }
    public var batteryLabel: String { Self.percent(battery?.fraction) ?? "電量未知" }
    public func ringFraction(desktop: DesktopRing) -> Double? {
        switch machine {
        case .laptop: battery?.fraction
        case .desktop: desktop == .cpu ? cpu : (desktop == .power ? 1 : nil)
        case .unknown: nil
        }
    }
    public static func percent(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }
    public static func signalLevel(rssi: Int) -> Int? {
        guard (-120 ... -1).contains(rssi) else { return nil }
        return rssi >= -60 ? 3 : (rssi >= -75 ? 2 : 1)
    }

    public static func fixture(_ name: String) -> Self {
        var s = Self()
        s.model = "Mac15,14"; s.machine = .desktop; s.cpu = 0.24
        s.connection = .ethernet; s.volume = 0.5; s.hasAudioOutput = true; s.audioDevice = "Studio Display"
        switch name {
        case "laptop":
            s.machine = .laptop; s.model = "MacBook Pro"; s.connection = .wifi; s.wifiStrength = 3
            s.battery = BatteryReading(current: 78, maximum: 100, charging: false, onAC: false)
            s.volume = 0.75; s.audioDevice = "MacBook Pro 揚聲器"
        case "charging":
            s = fixture("laptop"); s.battery = BatteryReading(current: 46, maximum: 100, charging: true, onAC: true)
        case "low":
            s = fixture("laptop"); s.battery = BatteryReading(current: 12, maximum: 100, charging: false, onAC: false)
            s.connection = .offline; s.muted = true
        case "external": s.volume = nil; s.audioDevice = "USB 音訊介面"
        case "precision":
            // CLI-only fixture (`--fixture precision`, not in the gallery
            // selector): reproduces the exact volume/mute pair root
            // observed changing spuriously during a normal open→settings→
            // Escape session, on a controllable (non-read-only) speaker,
            // so that sequence can be replayed against fake data to check
            // for UI-side quantization/rounding rather than a real driver
            // change. Not a claim that this IS the cause.
            s.volume = 0.006903913803398609
            s.muted = true
        case "offline":
            s = fixture("laptop"); s.connection = .offline; s.wifiStrength = nil
        case "degraded":
            // All three `AttentionReason`s at once (8% unplugged, offline,
            // no audio output) — for the 0.3 attention-cue gallery/glyph
            // entries. 8%, not 10%, so it is unambiguously under the <=10%
            // threshold regardless of any future rounding change.
            s = fixture("laptop")
            s.battery = BatteryReading(current: 8, maximum: 100, charging: false, onAC: false)
            s.connection = .offline; s.wifiStrength = nil
            s.hasAudioOutput = false; s.audioDevice = "無可用輸出"
        case "unknown": s = Self(); s.connection = .offline; s.hasAudioOutput = false; s.audioDevice = "無可用輸出"
        default: break
        }
        return s
    }
}

public enum PowerTelemetry {
    /// Pure adapter: accepts copied descriptions, never accesses the host's power sources.
    public static func internalBattery(in descriptions: [[String: Any]]) -> (present: Bool, reading: BatteryReading?) {
        for d in descriptions where d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
            guard d[kIOPSIsPresentKey] as? Bool != false else { return (true, nil) }
            return (true, BatteryReading(current: (d[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                maximum: (d[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
                charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue))
        }
        return (false, nil)
    }
}

public struct CPUTicks: Sendable {
    public var busy: UInt64
    public var idle: UInt64
    public init(busy: UInt64, idle: UInt64) { self.busy = busy; self.idle = idle }
    public func usage(since previous: Self) -> Double? {
        guard busy >= previous.busy, idle >= previous.idle else { return nil }
        let b = busy - previous.busy, i = idle - previous.idle
        guard b + i > 0 else { return nil }
        return Double(b) / Double(b + i)
    }
}
