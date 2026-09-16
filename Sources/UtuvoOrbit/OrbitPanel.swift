import AppKit
import Combine
import SwiftUI
import OrbitCore

// MARK: - View model shared by tab content
//
// Holds everything that would otherwise need to be passed by value through the
// SwiftUI tree. Each tab binds to a tiny slice of this; the model owns the
// async refresh + write retry bookkeeping.

@MainActor
final class OrbitPanelModel: ObservableObject {
    @Published var tab: Tab = .overview
    @Published var audio: AudioState
    @Published var audioWriteError: String?
    @Published var network: NetworkSample = .placeholder
    @Published var networkHistory: [NetworkSample] = []
    @Published var systemMetrics: SystemMetrics
    @Published var peripherals: [Peripheral] = []
    @Published var awake: AwakeState
    @Published var awakeError: String?
    /// The duration the picker shows when awake is NOT active. Purely local
    /// UI state — selecting a duration must never create or replace a real
    /// assertion; only pressing "啟動" does. (Previously the picker called
    /// start()+stop() just to relabel itself, which briefly created a real
    /// IOPMAssertion on every duration change.)
    @Published var pendingAwakeDuration: AwakeDuration
    @Published var localIPv4: String?
    /// Purely local, in-memory UI state — deliberately NOT routed through
    /// `OrbitPreferencesModel`/`PreferencesBackend` at all (not even the
    /// force-false-on-save/load path those already have for "never persists
    /// across launches"). Threading it through the shared preferences
    /// round-trip meant an unrelated setting change (any `preferences.update`
    /// call) could re-save the whole values struct and, if pin ever got
    /// wired into a subsequent `load()`, silently unpin the panel out from
    /// under the user. Keeping it fully separate makes that impossible by
    /// construction.
    @Published var pin: Bool = false
    /// Fires when the user toggles the pin. AppDelegate listens so it can
    /// flip the popover's behavior immediately while the panel is visible.
    /// (Without this, the new behavior wouldn't apply until the next open.)
    var onPinChanged: ((Bool) -> Void)?

    let audioBackend: AudioBackend
    let networkBackend: NetworkBackend
    let systemBackend: SystemBackend
    let awakeBackend: AwakeBackend
    private let monitor: SystemMonitor
    private let preferences: OrbitPreferencesModel
    private let isPreview: Bool

    /// Awake is the ONLY thing this model still polls directly — it needs a
    /// per-second tick to keep the countdown label live, and it is not part
    /// of the shared system/network/audio coordinator (`SystemMonitor`)
    /// which owns everything else. Audio/system/network come in exclusively
    /// via the Combine subscriptions in `observeMonitor()` below; this class
    /// must never call `systemBackend.metrics()` / `networkBackend
    /// .currentReading()` itself — that was the second poller that raced
    /// `SystemMonitor`'s and corrupted `LiveSystemBackend`'s CPU baseline.
    private var awakeTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    enum Tab: String, CaseIterable, Identifiable {
        case overview, network, system
        var id: String { rawValue }
        var localizedTitle: String {
            switch self {
            case .overview: return "總覽"
            case .network: return "網路"
            case .system: return "系統"
            }
        }
    }

    /// `enableAwakeTimer: false` skips scheduling the per-second countdown
    /// timer — used ONLY by tests, which must not register real `Timer`s
    /// that keep firing after the test method returns. Defaults to `true`;
    /// every real call site is unaffected.
    init(monitor: SystemMonitor, preferences: OrbitPreferencesModel,
         audioBackend: AudioBackend, networkBackend: NetworkBackend,
         systemBackend: SystemBackend, awakeBackend: AwakeBackend,
         preview: Bool, initialTab: Tab = .overview,
         enableAwakeTimer: Bool = true) {
        self.monitor = monitor
        self.preferences = preferences
        self.audioBackend = audioBackend
        self.networkBackend = networkBackend
        self.systemBackend = systemBackend
        self.awakeBackend = awakeBackend
        self.isPreview = preview
        self.tab = initialTab
        self.audio = monitor.audio
        self.network = monitor.network
        self.networkHistory = monitor.networkHistory
        self.localIPv4 = monitor.network.localIPv4
        self.systemMetrics = monitor.systemMetrics
        self.peripherals = monitor.peripherals
        self.awake = awakeBackend.current()
        self.pendingAwakeDuration = awakeBackend.current().chosenDuration
        observeMonitor()
        if enableAwakeTimer {
            awakeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.awake = self?.awakeBackend.current() ?? .inactive }
            }
            awakeTimer?.tolerance = 0.2
        }
    }

    func stop() { awakeTimer?.invalidate(); awakeTimer = nil }

    /// Mirrors the single coordinator's published audio/network/system
    /// state into this model's own `@Published` properties (which the tab
    /// views already bind to) — this model performs NO polling of its own
    /// for any of these.
    private func observeMonitor() {
        // No `.receive(on: RunLoop.main)` — both classes are already
        // `@MainActor`, so every publish already happens on the main
        // thread. Adding `receive(on:)` anyway does not just relocate
        // delivery, it defers it via `RunLoop.main.schedule`, which is
        // never synchronous even when already on that runloop — an audio
        // write's readback (via `monitor.refreshAudioOnly()`) would only
        // reach this model on the NEXT runloop turn, not immediately.
        monitor.$audio.sink { [weak self] in self?.audio = $0 }.store(in: &cancellables)
        monitor.$network.sink { [weak self] sample in
            self?.network = sample
            self?.localIPv4 = sample.localIPv4
        }.store(in: &cancellables)
        monitor.$networkHistory.sink { [weak self] in self?.networkHistory = $0 }.store(in: &cancellables)
        monitor.$systemMetrics.sink { [weak self] in self?.systemMetrics = $0 }.store(in: &cancellables)
        monitor.$peripherals.sink { [weak self] in self?.peripherals = $0 }.store(in: &cancellables)
    }

    // MARK: - Audio actions

    // Writes go straight to `audioBackend`; the readback is fed back
    // through the SAME coordinator (`monitor.refreshAudioOnly()`) instead
    // of setting `audio` locally, so there is exactly one place audio state
    // is ever published from. This never triggers a CPU/network poll — it
    // only re-reads audio.

    func setVolume(_ value: Double) {
        // `audio.device?.id` is what the UI is showing right now — the write
        // is rejected as stale if the driver's fresh default no longer
        // matches, instead of comparing against an internal cache that a
        // concurrent poll could have moved.
        let expected = audio.device?.id ?? 0
        do { _ = try audioBackend.setMasterVolume(value, expectedDeviceID: expected); audioWriteError = nil }
        catch let error as AudioError { audioWriteError = describe(error: error) }
        catch { audioWriteError = l("無法寫入音量") }
        monitor.refreshAudioOnly()
    }

    func toggleMute() {
        let expected = audio.device?.id ?? 0
        do { _ = try audioBackend.setMuted(!audio.muted, expectedDeviceID: expected); audioWriteError = nil }
        catch let error as AudioError { audioWriteError = describe(error: error) }
        catch { audioWriteError = l("無法切換靜音") }
        monitor.refreshAudioOnly()
    }

    func selectOutput(_ id: UInt32) {
        do { _ = try audioBackend.selectDefaultOutput(deviceID: id); audioWriteError = nil }
        catch let error as AudioError { audioWriteError = describe(error: error) }
        catch { audioWriteError = l("無法切換輸出裝置") }
        monitor.refreshAudioOnly()
    }

    private func describe(error: AudioError) -> String {
        switch error {
        case .staleDevice: return l("目前的輸出裝置已變更")
        case .writeFailed(let s): return l("系統拒絕了寫入（status %@）", String(s))
        case .unsupported: return l("目前的裝置不支援這個操作")
        }
    }

    // MARK: - Awake actions

    func startAwake(duration: AwakeDuration) {
        do {
            awake = try awakeBackend.start(duration: duration, now: Date())
            pendingAwakeDuration = duration
            awakeError = nil
        } catch let error as AwakeError {
            awakeError = describe(error: error)
        } catch {
            awakeError = l("無法建立保持喚醒")
        }
    }

    func stopAwake() {
        awake = awakeBackend.stop(); awakeError = nil
    }

    /// Change the duration the picker shows without touching the real
    /// assertion. Only takes effect immediately when awake is already
    /// active (the user is explicitly changing a live session).
    func setPendingAwakeDuration(_ duration: AwakeDuration) {
        pendingAwakeDuration = duration
        if awake.isActive { startAwake(duration: duration) }
    }

    private func describe(error: AwakeError) -> String {
        switch error {
        case .createFailed(let s): return l("系統拒絕了保持喚醒（status %@）", String(s))
        case .alreadyActive: return l("已經在保持喚醒")
        }
    }

    // MARK: - Preferences

    func setDesktopRing(_ value: DesktopRing) { preferences.update { $0.desktopRing = value } }
    func setShowPercent(_ value: Bool) { preferences.update { $0.showPercent = value } }
    func setColorful(_ value: Bool) { preferences.update { $0.colorful = value } }
    func setLanguage(_ value: AppLanguage) { preferences.update { $0.language = value } }
    private var l: OrbitStrings { OrbitStrings(language: preferences.values.language) }
    func setTheme(_ value: AppTheme) { preferences.update { $0.theme = value } }
    func setRingCenter(_ value: RingCenter) { preferences.update { $0.ringCenter = value } }
    func setGlyphStyle(_ value: GlyphStyle) { preferences.update { $0.glyphStyle = value } }
    func setPin(_ value: Bool) {
        pin = value
        onPinChanged?(value)
    }
}

// MARK: - Root panel

struct OrbitPanel: View {
    @Environment(\.orbitStrings) private var l
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var preferences: OrbitPreferencesModel
    let audioBackend: AudioBackend
    let networkBackend: NetworkBackend
    let systemBackend: SystemBackend
    let awakeBackend: AwakeBackend
    var preview = false
    @Environment(\.colorScheme) private var scheme

    @StateObject private var model: OrbitPanelModel

    init(monitor: SystemMonitor, preferences: OrbitPreferencesModel,
         audioBackend: AudioBackend, networkBackend: NetworkBackend,
         systemBackend: SystemBackend, awakeBackend: AwakeBackend,
         preview: Bool,
         initialTab: OrbitPanelModel.Tab = .overview,
         onPinChanged: ((Bool) -> Void)? = nil) {
        self.monitor = monitor
        self.preferences = preferences
        self.audioBackend = audioBackend
        self.networkBackend = networkBackend
        self.systemBackend = systemBackend
        self.awakeBackend = awakeBackend
        self.preview = preview
        let initialModel = OrbitPanelModel(monitor: monitor, preferences: preferences,
                                          audioBackend: audioBackend,
                                          networkBackend: networkBackend,
                                          systemBackend: systemBackend,
                                          awakeBackend: awakeBackend,
                                          preview: preview,
                                          initialTab: initialTab)
        initialModel.onPinChanged = onPinChanged
        _model = StateObject(wrappedValue: initialModel)
    }

    var body: some View {
        VStack(spacing: 0) {
                HeaderBar()
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
                TabBar(selection: $model.tab)
                    .padding(.horizontal, 14)
                Divider().opacity(0.25).padding(.top, 4)
                ZStack {
                    switch model.tab {
                    case .overview: OverviewTab(model: model, monitor: monitor, preferences: preferences)
                    case .network: NetworkTab(model: model)
                    case .system: SystemTab(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: monitor.snapshot.machine == .laptop ? 258 : 228, alignment: .top)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
                Divider().opacity(0.25).padding(.horizontal, 14)
                DisplayPreferencesView(model: model, preferences: preferences, monitor: monitor)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
                FooterBar(model: model, preferences: preferences, preview: preview)
                    .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .environment(\.orbitStrings, OrbitStrings(language: preferences.values.language))
        .environment(\.locale, Locale(identifier: OrbitStrings(language: preferences.values.language).identifier))
        .frame(width: 372)
        .fixedSize(horizontal: false, vertical: true)
        // Single outer surface: NSPopover already draws its own native
        // vibrant chrome behind the content view, so a second full-panel
        // `.regularMaterial`/`.glassEffect` fill here double-layered the
        // translucency (visible as an over-blurred, muddy look with a seam
        // where the two roundrects' corner radii didn't quite line up).
        // Display preferences draw on that same surface; individual controls
        // keep their own glass styling via `.glassButton()`.
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // AppKit owns the popover's material appearance. Set only the
        // SwiftUI environment here, avoiding a competing window override.
        .environment(\.colorScheme, preferences.values.theme == .system ? scheme :
                              (preferences.values.theme == .dark ? .dark : .light))
    }
}

private struct HeaderBar: View {
    @Environment(\.orbitStrings) private var l
    var body: some View {
        HStack(spacing: 8) {
            Text("UTUVO Orbit")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("0.4.1")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(height: 24)
    }
}

private struct TabBar: View {
    @Environment(\.orbitStrings) private var l
    @Binding var selection: OrbitPanelModel.Tab
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(OrbitPanelModel.Tab.allCases) { tab in
                Text(l(tab.localizedTitle)).tag(tab)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityLabel(l("分頁選擇"))
    }
}

private struct FooterBar: View {
    @Environment(\.orbitStrings) private var l
    @ObservedObject var model: OrbitPanelModel
    @ObservedObject var preferences: OrbitPreferencesModel
    @StateObject private var languageMenu = NativeMenuAnchor()
    var preview: Bool
    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.setPin(!model.pin)
            } label: {
                Image(systemName: model.pin ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .frame(width: 28, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.pin ? l("取消釘選面板") : l("釘選面板"))
            Spacer()
            HStack(spacing: 6) {
                if preview {
                    Text(l("預覽資料"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    languageMenu.present(AppLanguage.allCases.map { language in
                        NativeMenuEntry(title: l(language.displayName),
                                        isChecked: preferences.values.language == language) {
                            model.setLanguage(language)
                        }
                    })
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                        Text(l(preferences.values.language.displayName))
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .overlay(NativeMenuAnchorView(anchor: languageMenu).allowsHitTesting(false))
                .accessibilityLabel(l("語言，目前選擇 %@", l(preferences.values.language.displayName)))
            }
            Spacer()
            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(l("結束 UTUVO Orbit"))
        }
    }
}
