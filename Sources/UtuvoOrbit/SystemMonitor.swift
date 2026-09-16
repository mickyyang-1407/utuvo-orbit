import AppKit
import Combine
import CoreWLAN
import Foundation
import IOKit
import IOKit.ps
import OrbitCore

// MARK: - SystemMonitor
//
// The ONE production telemetry coordinator. It is the only thing that polls
// audio/system/network — the menubar glyph, `--diagnose`, and
// `OrbitPanelModel` (via Combine subscriptions to the published properties
// below) all read from this single instance. Previously `OrbitPanelModel`
// ran its own second 2s timer polling the SAME `systemBackend`/
// `networkBackend`, and this class ran a second, separate `NWPathMonitor`
// duplicating what `LiveNetworkBackend` already tracks — both pollers called
// `LiveSystemBackend.metrics()`, which advances `previousCPU` as a side
// effect of being called, so the menubar and panel corrupted each other's
// CPU delta interval. Fixture mode used to discard its injected backends
// entirely and just re-assign the static fixture snapshot every tick, so
// fake audio/awake actions never reached the glyph or UI.

@MainActor
final class SystemMonitor: ObservableObject {
    @Published var snapshot = StatusSnapshot()
    @Published var audio: AudioState = .unknown
    @Published var network: NetworkSample = .placeholder
    @Published var networkHistory: [NetworkSample] = []
    @Published var systemMetrics: SystemMetrics = SystemMetrics(cpuUsage: nil, cpuHistory: [], usedBytes: nil, totalBytes: nil, battery: nil, machine: .unknown, model: "")
    /// De-duped, sorted (`PeripheralList.dedupedSorted`), capped at 4.
    @Published var peripherals: [Peripheral] = []
    /// Whether the peripheral read subsystem itself is working — distinct
    /// from `peripherals` being empty, which can mean either "nothing
    /// attached" (available) or "the source failed" (not available). Only
    /// meaningful diagnostics; the product UI keeps showing the same plain
    /// empty/unknown text either way.
    @Published var peripheralReadStatus = PeripheralReadStatus(available: true)

    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private let systemBackend: SystemBackend?
    private let networkBackend: NetworkBackend?
    private let audioBackend: AudioBackend?
    private let peripheralBackend: PeripheralBackend?
    private let fixtureSnapshot: StatusSnapshot?
    private let isFixture: Bool
    private var previousReading: NetworkReading?
    /// Injected so tests can control "time" without a real timer/sleep.
    private let monotonicNow: () -> Double
    private let peripheralPollInterval: TimeInterval
    private var lastPeripheralPollAt: Double?
    /// Exposed at `internal` (setter stays `private`) so isolated tests can
    /// `await` it directly for deterministic synchronization — the actual
    /// peripheral read (which can now include a bounded `pmset` subprocess
    /// call for charging) runs off the main actor; see
    /// `refreshPeripheralsIfDue`.
    private(set) var peripheralRefreshTask: Task<Void, Never>?
    /// Increments on every scheduled read; a finished read publishes only
    /// if it is still the newest one. See `refreshPeripheralsIfDue`.
    private var peripheralReadGeneration = 0
    private var peripheralReadInFlight = false

    /// `enableLiveObservers: false` disables the periodic `Timer`, the IOPS
    /// power-source notification, and the `NSWorkspace` wake observer —
    /// used ONLY by tests, which must not register real OS observers/
    /// timers or depend on the global `NSWorkspace` notification center.
    /// Defaults to `true`, so every real call site (live, fixture, gallery)
    /// is completely unaffected. `peripheralBackend` defaults to `nil` (not
    /// a live instance) so fixture/test construction can never accidentally
    /// fall through to real IOKit reads by omission.
    init(fixture: StatusSnapshot?,
         systemBackend: SystemBackend? = nil,
         networkBackend: NetworkBackend? = nil,
         audioBackend: AudioBackend? = nil,
         peripheralBackend: PeripheralBackend? = nil,
         enableLiveObservers: Bool = true,
         monotonicNow: @escaping () -> Double = MonotonicClock.now,
         peripheralPollInterval: TimeInterval = 30) {
        self.fixtureSnapshot = fixture
        self.isFixture = fixture != nil
        self.systemBackend = systemBackend
        self.networkBackend = networkBackend
        self.audioBackend = audioBackend
        self.peripheralBackend = peripheralBackend
        self.monotonicNow = monotonicNow
        self.peripheralPollInterval = peripheralPollInterval
        if let fixture { self.snapshot = fixture }
        // Real OS notifications only make sense against real hardware —
        // fixtures still get the SAME polling producer below, just not
        // these. No second NWPathMonitor here: `LiveNetworkBackend` already
        // tracks the route and `refresh()` reads its `interfaceType`
        // directly, so there is exactly one source for connection type.
        if !isFixture && enableLiveObservers {
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let monitor = Unmanaged<SystemMonitor>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in monitor.refresh() }
            }, context)?.takeRetainedValue() {
                powerSource = source
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleWake() }
            }
        }
        if enableLiveObservers {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            timer?.tolerance = 0.5
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        // Invalidate any in-flight peripheral read: its result is discarded
        // instead of publishing after the coordinator has been stopped.
        peripheralReadGeneration += 1
        peripheralReadInFlight = false
        peripheralRefreshTask?.cancel()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Real wake resets both the CPU baseline (so the first post-wake
    /// sample isn't a spike from pre-sleep cumulative ticks) AND the
    /// network delta baseline/history (so the first post-wake sample is
    /// "unknown", not a burst averaged across the sleep gap). Exposed as
    /// its own method — not just inline in the `NSWorkspace` observer
    /// closure — so tests can call it directly instead of posting to the
    /// real global notification center.
    func handleWake() {
        systemBackend?.reset()
        previousReading = nil
        networkHistory.removeAll()
        refreshPeripheralsIfDue(force: true)
        refresh()
    }

    /// Peripherals are slow-changing (battery drains over hours, not
    /// seconds) so they poll far less often than the 2s system/network/
    /// audio tick — throttled to `peripheralPollInterval` (~30s), forced
    /// once on wake. Views never poll this themselves; they only ever see
    /// `peripherals` via the `@Published` subscription, same as every other
    /// producer field on this class.
    ///
    /// The actual read now runs OFF the main actor: `LivePeripheralBackend
    /// .currentPeripherals()` can perform a bounded `pmset` subprocess call
    /// (for charging enrichment) that may take up to a couple of seconds,
    /// and this coordinator's own timer tick must never block on that.
    /// `Task.detached` is required (not a plain `Task { }`, which would
    /// inherit this @MainActor context by default) to actually escape the
    /// main actor for the read itself; the outer task hops back to
    /// MainActor to publish the complete, consistent result once — never a
    /// stale placeholder published now and "filled in" later behind the
    /// caller's back.
    ///
    /// Reads can overlap (a forced wake refresh while a scheduled one is
    /// still running), and they do not necessarily finish in the order they
    /// started, so each carries a generation and only the newest one is
    /// allowed to publish — an older result can never overwrite a newer.
    /// `stop()` invalidates the same way, so nothing publishes after it.
    private func refreshPeripheralsIfDue(force: Bool = false) {
        guard let peripheralBackend else { return }
        let now = monotonicNow()
        if !force, let last = lastPeripheralPollAt, now - last < peripheralPollInterval { return }
        // A scheduled tick landing on a still-running read is that
        // interval's sample; only an explicit force starts a second one.
        if !force, peripheralReadInFlight { return }
        lastPeripheralPollAt = now
        peripheralReadGeneration += 1
        let generation = peripheralReadGeneration
        peripheralReadInFlight = true
        peripheralRefreshTask = Task { @MainActor [weak self] in
            let result = await Task.detached {
                (peripheralBackend.currentPeripherals(), peripheralBackend.readStatus())
            }.value
            guard let self, self.peripheralReadGeneration == generation else { return }
            self.peripheralReadInFlight = false
            self.peripherals = PeripheralList.dedupedSorted(result.0)
            self.peripheralReadStatus = result.1
        }
    }

    /// Re-reads ONLY audio and publishes it — used right after a user audio
    /// action (volume/mute/output write) so the UI reflects the write
    /// immediately without waiting for the next full 2s tick, and without
    /// that action itself polling CPU/network.
    func refreshAudioOnly() {
        guard let audioBackend else { return }
        let current = audioBackend.current()
        audio = current
        snapshot.volume = current.masterVolume
        snapshot.muted = current.muted
        snapshot.audioDevice = current.device?.name ?? "無可用輸出"
        snapshot.hasAudioOutput = current.available
    }

    func refresh() {
        refreshPeripheralsIfDue()
        guard let systemBackend, let networkBackend else {
            if let fixtureSnapshot { snapshot = fixtureSnapshot }
            return
        }
        let metrics = systemBackend.metrics(historyCapacity: 30)
        systemMetrics = metrics
        snapshot.model = metrics.model
        snapshot.machine = metrics.machine
        snapshot.battery = metrics.battery
        snapshot.cpu = metrics.cpuUsage

        // Audio — one read per tick, shared by the glyph, the panel and
        // `--diagnose`.
        let current = audioBackend?.current()
        audio = current ?? .unknown
        snapshot.volume = current?.masterVolume
        snapshot.muted = current?.muted ?? false
        snapshot.audioDevice = current?.device?.name ?? (current == nil ? "讀取中" : "無可用輸出")
        snapshot.hasAudioOutput = current?.available

        // Network — one read per tick. `interfaceType` comes straight from
        // the backend's own reading (for the live backend: NWPathMonitor
        // inside `LiveNetworkBackend`; for fakes: the fixture's own
        // `connection`), so this is the only place `snapshot.connection`
        // is set.
        let reading = networkBackend.currentReading()
        snapshot.connection = reading.interfaceType
        let delta = NetworkMath.delta(previous: previousReading, current: reading)
        let sample = NetworkSample(downloadBytesPerSecond: delta.downloadBytesPerSecond,
                                   uploadBytesPerSecond: delta.uploadBytesPerSecond,
                                   localIPv4: reading.localIPv4,
                                   interfaceName: reading.interfaceName,
                                   interfaceType: reading.interfaceType,
                                   reachable: reading.isReachable)
        previousReading = reading
        network = sample
        networkHistory.append(sample)
        if networkHistory.count > 30 { networkHistory.removeFirst(networkHistory.count - 30) }
        if delta.reset { networkHistory.removeAll() }

        if !isFixture, snapshot.connection == .wifi, let wifi = CWWiFiClient.shared().interface() {
            snapshot.wifiStrength = StatusSnapshot.signalLevel(rssi: wifi.rssiValue())
        } else if isFixture {
            snapshot.wifiStrength = fixtureSnapshot?.wifiStrength
        } else {
            snapshot.wifiStrength = nil
        }
    }
}
