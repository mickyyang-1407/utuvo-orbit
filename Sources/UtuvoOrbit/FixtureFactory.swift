import Foundation
import OrbitCore

// MARK: - FixtureFactory
//
// Single source of fake audio/network/system state for BOTH the CLI
// `--fixture`/`--gallery` path (AppDelegate) and the gallery grid
// (GalleryView). Previously each had its own copy, and both hard-coded
// `.ethernet` + `isReachable: true` regardless of what the requested
// `StatusSnapshot` fixture actually said. All fake IPv4 addresses use the
// RFC 5737 TEST-NET-1 block (192.0.2.0/24), reserved for documentation and
// unable to resolve to a real host.

enum FixtureFactory {
    /// Builds a real `AudioBackendImpl` over a `FakeAudioHALDriver` with TWO
    /// devices — a controllable "speaker" (settable volume + mute) and a
    /// read-only "digital output" (no settable volume/mute, matching a
    /// real class-compliant digital/USB output that only reports a fixed
    /// level) — so output switching and per-device capability differences
    /// are actually exercisable, instead of the single-device
    /// `FakeAudioBackend(state:)` convenience path (which also discards
    /// `outputs`/mute capability flags entirely).
    ///
    /// "external" starts on the digital output (matches the fixture's own
    /// `audioDevice` name, e.g. "USB 音訊介面"); every other usable fixture
    /// starts on the speaker. `unknown`/no-output fixtures get an empty
    /// device list — no usable output at all.
    static func makeAudioBackend(for snapshot: StatusSnapshot) -> AudioBackend {
        guard snapshot.machine != .unknown, snapshot.hasAudioOutput != false else {
            return AudioBackendImpl(driver: FakeAudioHALDriver(snapshot: .init(defaultID: 0, devices: [:])))
        }
        let speakerID: UInt32 = 100
        let digitalID: UInt32 = 101
        // "external" fixture reports no readable volume (`snapshot.volume
        // == nil`) — that's the signal it's the read-only digital case.
        let isExternal = snapshot.volume == nil
        let speaker = FakeAudioHALDriver.DeviceState(
            name: isExternal ? "MacBook Pro 揚聲器" : snapshot.audioDevice,
            hasSettableVolume: true,
            currentScalar: isExternal ? 0.6 : Float32(snapshot.volume ?? 0.5),
            currentMuted: isExternal ? false : snapshot.muted,
            hasSettableMute: true)
        let digital = FakeAudioHALDriver.DeviceState(
            name: isExternal ? snapshot.audioDevice : "Digital Output",
            hasSettableVolume: false,
            currentScalar: nil,
            currentMuted: nil,
            hasSettableMute: false)
        let devices: [UInt32: FakeAudioHALDriver.DeviceState] = [speakerID: speaker, digitalID: digital]
        let driver = FakeAudioHALDriver(snapshot: .init(defaultID: isExternal ? digitalID : speakerID, devices: devices))
        return AudioBackendImpl(driver: driver)
    }

    static func networkReadings(for snapshot: StatusSnapshot) -> [NetworkReading] {
        // `.checking` means "don't know yet" — it must not fabricate a
        // reachable interface/IP any more than `.offline` does.
        guard snapshot.connection != .offline, snapshot.connection != .checking else {
            return [NetworkReading(interfaceName: nil, interfaceType: snapshot.connection, localIPv4: nil,
                                   isReachable: false, receivedBytes: 0, sentBytes: 0,
                                   timestamp: Date(timeIntervalSinceReferenceDate: 0), monotonicSeconds: 0,
                                   countersValid: false)]
        }
        let interfaceName: String
        switch snapshot.connection {
        case .ethernet: interfaceName = "en0"
        case .wifi: interfaceName = "en1"
        case .other: interfaceName = "utun0"
        case .offline, .checking: interfaceName = "en0" // unreachable, guarded above
        }
        let now = Date()
        return (0..<12).map { index in
            let timestamp = now.addingTimeInterval(TimeInterval(-12 + index))
            let base = UInt64(1_000_000 + index * 12_000)
            return NetworkReading(interfaceName: interfaceName, interfaceType: snapshot.connection,
                                  localIPv4: "192.0.2.\(10 + index)",
                                  isReachable: true, receivedBytes: base, sentBytes: base / 4,
                                  timestamp: timestamp, monotonicSeconds: Double(index), countersValid: true)
        }
    }

    /// `unknown` machine gets NO invented metrics — nil CPU, nil
    /// memory, empty history — rather than a fabricated 8/16GB and a fake
    /// CPU curve that implies real telemetry was actually read.
    static func systemMetrics(for snapshot: StatusSnapshot) -> SystemMetrics {
        guard snapshot.machine != .unknown else {
            return SystemMetrics(cpuUsage: nil, cpuHistory: [], usedBytes: nil, totalBytes: nil,
                                 battery: nil, machine: .unknown, model: snapshot.model)
        }
        return SystemMetrics(cpuUsage: snapshot.cpu,
                             cpuHistory: (0..<20).map { Double(($0 + 5) % 24) / 100 },
                             usedBytes: 8 * 1024 * 1024 * 1024, totalBytes: 16 * 1024 * 1024 * 1024,
                             battery: snapshot.battery, machine: snapshot.machine, model: snapshot.model)
    }

    static func hardwareEvidence(for snapshot: StatusSnapshot) -> HardwareEvidence {
        HardwareEvidence(model: snapshot.model,
                         hasInternalBattery: snapshot.machine == .laptop,
                         hasLid: snapshot.machine == .laptop)
    }

    /// Peripherals are keyed on the FIXTURE NAME, not the snapshot — every
    /// other fixture (desktop/laptop/offline/degraded/...) now gets an
    /// honest EMPTY peripherals list instead of the same 3 devices injected
    /// everywhere (root: "Do not inject the same 3 peripherals into every
    /// fixture"). Only the dedicated `peripherals*` fixtures below ever
    /// return non-empty data, each demonstrating one distinct scenario.
    static func peripherals(for name: String) -> [Peripheral] {
        switch name {
        case "peripherals":
            return [
                Peripheral(id: "fixture-airpods", name: "AirPods Pro", kind: .airpods, fraction: 0.62, charging: .unknown, source: "fixture"),
                Peripheral(id: "fixture-keyboard", name: "Magic Keyboard", kind: .keyboard, fraction: 0.15, charging: .unknown, source: "fixture"),
                Peripheral(id: "fixture-trackpad", name: "Magic Trackpad", kind: .trackpad, fraction: 0.88, charging: .unknown, source: "fixture")
            ]
        case "peripherals-long-names":
            // Exactly 4 (the display cap). Root's native gallery QA found
            // the original ~44-character names all fit without ellipsizing
            // — truncation itself was never actually exercised. The first
            // entry is now ~95 characters (plus explicitly `.charging`, to
            // exercise the charging badge alongside a name that must
            // truncate) so the panel's ellipsis/AX-full-name behavior has a
            // genuine case to prove against, not just a theoretical one.
            return [
                Peripheral(id: "fixture-long-1", name: "Micky 的 Magic Keyboard with Numeric Keypad（英式鍵盤配列，藍牙第三代韌體，序號 A1843-JP-2024-0007-ZZ，辦公室備用鍵盤，勿外借）", kind: .keyboard, fraction: 0.42, charging: .charging, source: "fixture"),
                Peripheral(id: "fixture-long-2", name: "Micky 的 Magic Trackpad 2（黑色特別版）", kind: .trackpad, fraction: 0.77, charging: .unknown, source: "fixture"),
                Peripheral(id: "fixture-long-3", name: "AirPods Pro 第二代主動降噪耳機", kind: .airpods, fraction: 0.31, charging: .unknown, source: "fixture"),
                Peripheral(id: "fixture-long-4", name: "Micky 的 iPhone 16 Pro Max 鈦金屬版", kind: .iphone, fraction: 0.58, charging: .unknown, source: "fixture")
            ]
        case "peripherals-empty":
            return []
        case "peripherals-unknown":
            return [
                Peripheral(id: "fixture-unknown-1", name: "未知裝置", kind: .other, fraction: nil,
                          charging: .unknown, source: "fixture", statusNote: "缺少電量欄位")
            ]
        case "peripherals-charging":
            return [
                Peripheral(id: "fixture-charging-1", name: "AirPods Pro", kind: .airpods, fraction: 0.35, charging: .charging, source: "fixture")
            ]
        default:
            return []
        }
    }

    /// The one place that knows a fixture NAME can imply a `StatusSnapshot`
    /// name that differs from it (percent-center/classic are preference
    /// demos layered on "laptop"; the peripherals-* demos are layered on
    /// "desktop"), a starting `OrbitPreferencesValues` override, AND a
    /// distinct peripherals set. Every call site that accepts a fixture
    /// name — the CLI `--fixture` path, `--gallery`, the standalone
    /// `--snapshot` export, and the interactive gallery's `FixtureSession`
    /// — must resolve through this so none of them can drift from another
    /// (previously only `FixtureSession` special-cased "percent-center"/
    /// "classic"; the CLI path silently launched them with default
    /// preferences, so the real menubar ignored the name entirely).
    static func resolve(_ name: String) -> (snapshot: StatusSnapshot, preferences: OrbitPreferencesValues, peripherals: [Peripheral]) {
        var preferences = OrbitPreferencesValues()
        var snapshotName = name
        switch name {
        case "percent-center": snapshotName = "laptop"; preferences.ringCenter = .percent
        case "classic": snapshotName = "laptop"; preferences.glyphStyle = .classic
        case "peripherals", "peripherals-long-names", "peripherals-empty", "peripherals-unknown", "peripherals-charging":
            snapshotName = "desktop"
        default: break
        }
        return (StatusSnapshot.fixture(snapshotName), preferences, peripherals(for: name))
    }

    /// One call builds ALL FOUR fake backends for a fixture, so every call
    /// site constructs them identically — no call site can silently drift
    /// from another's device/network/system shape. `peripherals` defaults
    /// to empty — callers that resolved a fixture NAME should pass
    /// `resolve(name).peripherals` explicitly rather than relying on the
    /// default.
    static func makeBackends(for snapshot: StatusSnapshot, peripherals: [Peripheral] = []) -> (audio: AudioBackend, network: NetworkBackend, system: SystemBackend, peripheral: PeripheralBackend) {
        (audio: makeAudioBackend(for: snapshot),
         network: FakeNetworkBackend(readings: networkReadings(for: snapshot)),
         system: FakeSystemBackend(metrics: systemMetrics(for: snapshot), evidence: hardwareEvidence(for: snapshot)),
         peripheral: FakePeripheralBackend(peripherals: peripherals))
    }
}
