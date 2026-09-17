import AppKit
import Combine
import SwiftUI
import OrbitCore

@main
struct UtuvoOrbitMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover = NSPopover()
    private var monitor: SystemMonitor!
    private var preferencesModel: OrbitPreferencesModel!
    private var preferencesBackend: PreferencesBackend!
    private var audioBackend: AudioBackend!
    private var networkBackend: NetworkBackend!
    private var systemBackend: SystemBackend!
    private var peripheralBackend: PeripheralBackend!
    private var awakeBackend: AwakeBackend!
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    /// Light/dark state the menu-bar glyph was last rendered for.
    private var lastIconIsDark: Bool?
    private var galleryWindow: NSWindow?
    /// Mirrors the panel's in-memory `pin` state (via `onPinChanged`).
    /// `preferencesModel.values.pin` is NOT this value — pin was
    /// deliberately decoupled from the preferences round-trip (session-only,
    /// never persisted) and always reads back `false` there. `showPopover()`
    /// must consult THIS, or reopening the popover after pinning silently
    /// reverts its behavior to `.transient` even though the pin button still
    /// shows pinned.
    private var isPinned = false
    /// Screen-space x the popover was anchored to when it opened — the
    /// status button's own mid-x, read from the (non-animating) button, not
    /// from the popover window. `nil` while closed. See `syncPopoverAnchor()`.
    /// The popover is anchored to this, not to the resizing status button.
    private let anchorHost = PopoverAnchorHost()
    private var screenObserver: NSObjectProtocol?

    /// The anchor exists only while the popover is open; the next open
    /// parks it at wherever the status item is then.
    func popoverDidClose(_ notification: Notification) {
        anchorHost.hide()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        // Checked first and unconditionally: dev-only, fake-data-only,
        // exits immediately after — must never fall through to any real
        // preferences/audio/power/menubar construction below.
        if let directory = Self.argValue(args, after: "--export-glyphs") {
            exportGlyphs(to: directory)
            return
        }
        let diagnose = args.contains("--diagnose")
        let gallery = args.contains("--gallery")
        let fixtureName = Self.argValue(args, after: "--fixture")
        let isolated = diagnose || gallery || fixtureName != nil

        // `FixtureFactory.resolve` is the ONE place that maps a fixture NAME
        // to its (snapshot, preferences, peripherals) — previously only
        // `FixtureSession` (the interactive gallery) special-cased
        // "percent-center"/"classic" this way, so `--fixture percent-center`
        // from the CLI silently launched with default preferences and the
        // real menubar ignored the name entirely.
        if isolated, let fixtureName {
            let resolved = FixtureFactory.resolve(fixtureName)
            preferencesBackend = FakePreferencesBackend(initial: resolved.preferences, legacy: nil)
        } else if isolated {
            preferencesBackend = FakePreferencesBackend(initial: .init(), legacy: nil)
        } else {
            preferencesBackend = LivePreferencesBackend()
        }
        preferencesModel = OrbitPreferencesModel(backend: preferencesBackend)
        // Preview language overrides are confined to the fake preferences backend.
        if isolated, let raw = Self.argValue(args, after: "--language"), let language = AppLanguage(rawValue: raw) {
            preferencesModel.update { $0.language = language }
        }

        if let fixtureName {
            let resolved = FixtureFactory.resolve(fixtureName)
            let fixture = resolved.snapshot
            let backends = FixtureFactory.makeBackends(for: fixture, peripherals: resolved.peripherals)
            audioBackend = backends.audio
            networkBackend = backends.network
            systemBackend = backends.system
            peripheralBackend = backends.peripheral
            awakeBackend = FakeAwakeBackend()
            monitor = SystemMonitor(fixture: fixture,
                                    systemBackend: systemBackend,
                                    networkBackend: networkBackend,
                                    audioBackend: audioBackend,
                                    peripheralBackend: peripheralBackend)
        } else if gallery {
            let fixture = StatusSnapshot.fixture("desktop")
            let backends = FixtureFactory.makeBackends(for: fixture)
            audioBackend = backends.audio
            networkBackend = backends.network
            systemBackend = backends.system
            peripheralBackend = backends.peripheral
            awakeBackend = FakeAwakeBackend()
            monitor = SystemMonitor(fixture: fixture,
                                    systemBackend: systemBackend,
                                    networkBackend: networkBackend,
                                    audioBackend: audioBackend,
                                    peripheralBackend: peripheralBackend)
        } else {
            audioBackend = makeLiveAudioBackend()
            networkBackend = LiveNetworkBackend()
            systemBackend = LiveSystemBackend()
            peripheralBackend = LivePeripheralBackend()
            awakeBackend = makeLiveAwakeBackend()
            monitor = SystemMonitor(fixture: nil,
                                    systemBackend: systemBackend,
                                    networkBackend: networkBackend,
                                    audioBackend: audioBackend,
                                    peripheralBackend: peripheralBackend)
        }

        if diagnose {
            // Hard watchdog: --diagnose must never hang. This fires
            // regardless of whether the normal 3s read path below completes,
            // as a backstop independent of it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                fputs("orbit: --diagnose watchdog fired (10s), forcing exit\n", stderr)
                exit(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                Task { @MainActor in
                    // Awaits the coordinator's OWN peripheral read instead
                    // of issuing a second one — that duplicate meant two
                    // IOKit sweeps and two `pmset` launches per run, and
                    // reported a different sample than the app's. Bounded
                    // by the 10s watchdog above.
                    await monitor.peripheralRefreshTask?.value
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let report = DiagnoseReport(snapshot: monitor.snapshot, peripherals: monitor.peripherals,
                                              peripheralReadStatus: monitor.peripheralReadStatus)
                    if let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) { print(json) }
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if gallery {
            showGallery()
            return
        }
        if let fixtureName, let snapshotPath = Self.argValue(args, after: "--snapshot") {
            exportFixtureSnapshot(fixtureName: fixtureName, path: snapshotPath,
                                  tab: Self.argValue(args, after: "--tab"),
                                  dark: !args.contains("--light"))
            return
        }

        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.autosaveName = "UtuvoOrbit.status"
        item.button?.target = self; item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        popover.behavior = .transient
        popover.delegate = self
        // A display change can strand the anchor host off-screen; this is
        // the only thing that moves it while the popover is open.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenChange() }
        }
        popover.contentViewController = NSHostingController(rootView: OrbitPanel(monitor: monitor,
                                                                                preferences: preferencesModel,
                                                                                audioBackend: audioBackend,
                                                                                networkBackend: networkBackend,
                                                                                systemBackend: systemBackend,
                                                                                awakeBackend: awakeBackend,
                                                                                preview: fixtureName != nil,
                                                                                onPinChanged: { [weak self] pinned in
                                                                                    guard let self else { return }
                                                                                    self.isPinned = pinned
                                                                                    // Apply the new behavior live — without
                                                                                    // this, pin only takes effect on next open.
                                                                                    if self.popover.isShown {
                                                                                        self.popover.behavior = pinned
                                                                                            ? .applicationDefined
                                                                                            : .transient
                                                                                    }
                                                                                }))
        preferencesModel.$values.map(\.theme).removeDuplicates()
            .sink { [weak self] theme in
                let appearance: NSAppearance?
                switch theme {
                case .system: appearance = nil
                case .light: appearance = NSAppearance(named: .aqua)
                case .dark: appearance = NSAppearance(named: .darkAqua)
                }
                // Change native glass and hosted controls together. A
                // SwiftUI-only theme left dark text styling on light chrome.
                self?.popover.appearance = appearance
                self?.popover.contentViewController?.view.appearance = appearance
            }.store(in: &cancellables)
        monitor.$snapshot.combineLatest(preferencesModel.$values)
            .receive(on: RunLoop.main).sink { [weak self] _, _ in self?.updateIcon() }.store(in: &cancellables)
        if let button = item.button {
            // Only redraw when light/dark actually flips. Setting
            // `button.image` inside `updateIcon()` makes AppKit refresh the
            // status-item replicant, which re-applies the button's
            // appearance and fires this KVO again — without the guard that
            // is a self-sustaining loop (measured 60–90 % CPU idle).
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] button, _ in
                let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                Task { @MainActor in
                    guard let self, self.lastIconIsDark != dark else { return }
                    self.updateIcon()
                }
            }
        }
        updateIcon()
        if args.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.showPopover() }
        }
        installEscapeMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        _ = awakeBackend?.stop()
        anchorHost.close()
    }

    /// Local Escape-key monitor: closes the popover regardless of pin state so
    /// the user always has a way out. (NSPopover's built-in click-outside only
    /// works for `.transient`, not `.applicationDefined` / pinned.)
    ///
    /// All controls share one panel; Escape closes it, pinned or not.
    private func installEscapeMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            // 53 = kVK_Escape
            guard event.keyCode == 53 else { return event }
            self.popover.performClose(nil)
            return nil
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover(); return true
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        lastIconIsDark = dark
        let s = monitor.snapshot
        let prefs = preferencesModel.values
        let l = OrbitStrings(language: prefs.language)
        button.image = OrbitGlyph.image(s, desktop: prefs.desktopRing, size: 27,
                                       foreground: dark ? .white : .black, color: prefs.colorful,
                                       ringCenter: prefs.ringCenter, glyphStyle: prefs.glyphStyle)
        var percent: String?
        if s.machine == .laptop { percent = StatusSnapshot.percent(s.battery?.fraction) }
        else if s.machine == .desktop && prefs.desktopRing == .cpu { percent = StatusSnapshot.percent(s.cpu) }
        button.title = prefs.showPercent ? percent.map { " " + $0 } ?? "" : ""
        // The image/title just set above can resize the auto-sized
        // `NSStatusItem.variableLength` button. Nothing to do about it here:
        // an open popover is anchored to `PopoverAnchorHost`, not to this
        // button, so it no longer follows the resize.
        // Previously any non-`.cpu` desktop ring choice (including
        // `.hidden`) reported "外接電源" in the tooltip — `.hidden` must say
        // so, not silently claim to be showing power. `ring` is `nil` for
        // an unknown machine — `s.machineLabel` already says "機型未確認";
        // repeating the identical string a second time as the "ring"
        // segment said nothing new.
        let ring: String?
        switch s.machine {
        case .laptop:
            ring = l("電量 %@", l(s.batteryLabel))
        case .desktop:
            switch prefs.desktopRing {
            case .cpu: ring = "CPU \(StatusSnapshot.percent(s.cpu) ?? l("未知"))"
            case .power: ring = l("外接電源")
            case .hidden: ring = l("外圈已隱藏")
            }
        case .unknown:
            ring = nil
        }
        // `s.connectionLabel` alone doesn't distinguish "no Wi-Fi signal"
        // from "we don't know the signal strength" — `wifiStrength == nil`
        // must say so honestly, never invented as a 0-bar reading.
        var connectionLabel = l(s.connectionLabel)
        if s.connection == .wifi, s.wifiStrength == nil {
            connectionLabel += l("（訊號強度未知）")
        }
        var label = "UTUVO Orbit · \(l(s.machineLabel))"
        if let ring { label += " · \(ring)" }
        label += " · \(connectionLabel) · " + l("音量 %@", l(s.volumeLabel))
        // The center numeral has no "%" glyph in the icon itself (keeps
        // "100" as legible as "8" at 27pt) — the tooltip/AX label is where
        // its meaning and source (CPU vs battery) are actually stated.
        // Classic mode has NO center at all (three independent cells), so
        // this must never claim one just because the retained `ringCenter`
        // preference happens to be `.percent` — that preference only
        // applies to combined's own layout.
        let center = CenterContent.resolve(snapshot: s, desktopRing: prefs.desktopRing, ringCenter: prefs.ringCenter)
        if prefs.glyphStyle == .combined {
            if case .percent(let value, let source) = center {
                let sourceLabel = source == .desktopCPU ? "CPU" : l("電量")
                label += " · " + l("中央顯示 %@ %@", sourceLabel, StatusSnapshot.percent(value) ?? "")
            } else if prefs.ringCenter == .percent, s.machine == .laptop, s.battery?.charging == true {
                // The ONE fallback reason worth explaining: percent is
                // ACTIVELY suppressed here (not just inapplicable) to keep
                // the top-slot charging bolt visible — see
                // `CenterContent.resolve`. Charging is read from the
                // explicit `battery.charging` flag only, never inferred
                // from `onAC` alone.
                label += " · " + l("充電中，中央顯示改為網路以保留閃電符號")
            }
        }
        let reasons = AttentionAnalysis.reasons(snapshot: s)
        if !reasons.isEmpty {
            label += " · " + l("需注意：%@", reasons.map { l($0.localizedTitle) }.joined(separator: ", "))
        }
        button.toolTip = label; button.setAccessibilityLabel(label)
    }

    @objc private func clicked() {
        let l = OrbitStrings(language: preferencesModel.values.language)
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let show = NSMenuItem(title: l("開啟 UTUVO Orbit"), action: #selector(openDetails), keyEquivalent: "")
            show.target = self; menu.addItem(show); menu.addItem(.separator())
            let quit = NSMenuItem(title: l("結束 UTUVO Orbit"), action: #selector(quitApp), keyEquivalent: "q")
            quit.target = self; menu.addItem(quit)
            statusItem?.menu = menu; statusItem?.button?.performClick(nil); statusItem?.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }
    @objc private func openDetails() { showPopover() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    private func showPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        // `isPinned` (mirrored from the panel's in-memory pin state via
        // `onPinChanged`), NOT `preferencesModel.values.pin` — pin is
        // session-only and never persists, so that always reads back
        // `false` and previously reverted a pinned popover to `.transient`
        // on every reopen.
        popover.behavior = isPinned ? .applicationDefined : .transient
        // Anchor captured from the BUTTON, before/independent of the
        // popover's own opening animation: the popover window's frame is
        // still in flight for several frames after `show` (root sampled it
        // at y=-91 while its settled y is 29), so it is never a valid
        // reference. The button is already laid out and does not animate.
        // Anchored to the stationary host parked at the button's CURRENT
        // screen rect, so the status item can resize underneath without
        // moving the popover. Falls back to the button itself only if it
        // has no window to take a screen rect from.
        if let rect = Self.screenRect(of: button), let anchorView = anchorHost.anchorView(at: rect) {
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func handleScreenChange() {
        let buttonRect: NSRect? = statusItem?.button.flatMap { Self.screenRect(of: $0) }
        switch PopoverAnchorHost.screenChangeAction(isPopoverShown: popover.isShown,
                                                    buttonScreenRect: buttonRect,
                                                    screens: NSScreen.screens.map(\.frame)) {
        case .hide:
            anchorHost.hide()
        case .close:
            popover.performClose(nil)
            anchorHost.hide()
        case .reposition(let rect):
            anchorHost.reposition(to: rect)
        }
    }

    private static func screenRect(of view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func showGallery() {
        let args = CommandLine.arguments
        let root = GalleryView(fixture: Self.argValue(args, after: "--fixture"), light: args.contains("--light"))
            .environment(\.orbitStrings, OrbitStrings(language: preferencesModel.values.language))
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = OrbitStrings(language: preferencesModel.values.language)("UTUVO Orbit · 機型預覽（模擬資料）")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 640))
        window.center(); window.makeKeyAndOrderFront(nil)
        galleryWindow = window
        NSApp.activate(ignoringOtherApps: true)
        if let path = Self.argValue(args, after: "--snapshot") {
            let destination = URL(fileURLWithPath: path)
            // 5s, not 1s: the coordinator polls every 2s, so a 1s capture
            // delay only ever sees the first (dash-only, no trend) sample.
            // 5s guarantees at least two real samples exist. Capture-only —
            // does not touch the live poll interval.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Self.capturePNG(of: controller.view, to: destination)
                NSApp.terminate(nil)
            }
        }
    }

    /// Standalone `--fixture NAME --snapshot PATH [--tab overview|network|system] [--light]`
    /// export: renders the actual `OrbitPanel` (not the gallery chrome) for
    /// one fixture/tab/theme combination and writes its own rendered pixels.
    /// Feeds the same fixture backends the running app would use in
    /// `--fixture` mode, so this is a real (if static) render of the app's
    /// own view, not a mockup.
    ///
    /// `--tab settings` is deliberately NOT supported here: presenting a
    /// SwiftUI `.sheet` at construction time and then force-terminating
    /// before its presentation/dismissal animation settles left the process
    /// hung on `NSApp.terminate` in testing — a real "capture the settings
    /// sheet" export would need to click the gear button and wait for the
    /// sheet's own lifecycle, not force one open synchronously.
    private func exportFixtureSnapshot(fixtureName: String, path: String, tab: String?, dark: Bool) {
        let resolved = FixtureFactory.resolve(fixtureName)
        let fixture = resolved.snapshot
        var exportValues = resolved.preferences
        exportValues.language = preferencesModel.values.language
        let exportPreferences = OrbitPreferencesModel(backend: FakePreferencesBackend(initial: exportValues, legacy: nil))
        let backends = FixtureFactory.makeBackends(for: fixture, peripherals: resolved.peripherals)
        let exportAudio = backends.audio
        let exportNetwork = backends.network
        let exportSystem = backends.system
        let exportPeripheral = backends.peripheral
        // Same backends the panel uses must also back the monitor, or
        // `refresh()` has nothing to read and the panel (which only
        // mirrors the coordinator's published state) shows empty metrics.
        let exportMonitor = SystemMonitor(fixture: fixture, systemBackend: exportSystem,
                                          networkBackend: exportNetwork, audioBackend: exportAudio,
                                          peripheralBackend: exportPeripheral)
        let exportAwake: AwakeBackend = FakeAwakeBackend()
        let initialTab: OrbitPanelModel.Tab = {
            switch tab {
            case "network": return .network
            case "system": return .system
            default: return .overview
            }
        }()
        let panel = OrbitPanel(monitor: exportMonitor, preferences: exportPreferences,
                               audioBackend: exportAudio, networkBackend: exportNetwork,
                               systemBackend: exportSystem, awakeBackend: exportAwake,
                               preview: true, initialTab: initialTab)
            // OrbitPanel deliberately has no opaque background of its own
            // (that was the double-glass-layer fix — the real menubar
            // popover supplies its own native chrome). Standalone/off-window
            // export has no such host, so it needs one explicitly here —
            // without it `cacheDisplay` captures native-control borders fine
            // but silently drops all pure-SwiftUI content (Text, shapes, SF
            // Symbols) that only exists as Core Animation layers with
            // nothing opaque behind them to flatten against.
            .background(dark ? Color.black : Color.white)
            .preferredColorScheme(dark ? .dark : .light)
        let controller = NSHostingController(rootView: panel)
        let window = NSWindow(contentViewController: controller)
        // Match `showGallery()`'s window recipe exactly (titled + explicit
        // style mask). A borderless/default-style window's SwiftUI content
        // (Text, shapes, SF Symbols — anything drawn via Core Animation
        // layers rather than a native NSControl bezel) did not reliably
        // flush into the `cacheDisplay` capture; only native control borders
        // showed up. This export path is otherwise identical to the
        // known-working gallery capture below.
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(controller.view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        galleryWindow = window
        let destination = URL(fileURLWithPath: path)
        // 5s for the same reason as showGallery()'s capture above — two
        // real 2s-interval samples instead of only the first dash-only one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Self.capturePNG(of: controller.view, to: destination)
            NSApp.terminate(nil)
        }
    }

    /// Dev-only, fake-data-only glyph matrix: exports the ACTUAL
    /// `OrbitGlyph` renderer (not a mockup/screenshot) at a logical 27pt,
    /// rasterized into exact 1x (27px) and 2x (54px) pixel bitmaps — no
    /// live app prefs/audio/power reads, no menubar/awake/preferences
    /// writes, exits immediately after. A static export cannot itself
    /// prove native Liquid Glass composition (there is none here — this is
    /// the plain vector glyph, not the popover), only the geometry/content
    /// logic; root inspects real-size and enlarged copies plus the native
    /// UI separately.
    private func exportGlyphs(to directory: String) {
        struct Case { let name: String; let snapshot: StatusSnapshot; let desktop: DesktopRing; let ringCenter: RingCenter; let glyphStyle: GlyphStyle }
        func battery(_ percent: Double, charging: Bool = false, onAC: Bool = false) -> StatusSnapshot {
            var s = StatusSnapshot.fixture("laptop")
            s.battery = BatteryReading(current: percent, maximum: 100, charging: charging, onAC: onAC)
            return s
        }
        var allBad = StatusSnapshot.fixture("laptop")
        allBad.connection = .offline
        allBad.battery = BatteryReading(current: 5, maximum: 100, charging: false, onAC: false)
        allBad.hasAudioOutput = false

        let cases: [Case] = [
            Case(name: "combined-normal", snapshot: StatusSnapshot.fixture("desktop"), desktop: .cpu, ringCenter: .network, glyphStyle: .combined),
            Case(name: "combined-percent-0", snapshot: battery(0), desktop: .cpu, ringCenter: .percent, glyphStyle: .combined),
            Case(name: "combined-percent-8", snapshot: battery(8), desktop: .cpu, ringCenter: .percent, glyphStyle: .combined),
            Case(name: "combined-percent-99", snapshot: battery(99), desktop: .cpu, ringCenter: .percent, glyphStyle: .combined),
            Case(name: "combined-percent-100", snapshot: battery(100), desktop: .cpu, ringCenter: .percent, glyphStyle: .combined),
            Case(name: "combined-unknown-machine", snapshot: StatusSnapshot.fixture("unknown"), desktop: .cpu, ringCenter: .percent, glyphStyle: .combined),
            Case(name: "combined-offline", snapshot: StatusSnapshot.fixture("offline"), desktop: .cpu, ringCenter: .network, glyphStyle: .combined),
            Case(name: "combined-noaudio", snapshot: { var s = StatusSnapshot.fixture("desktop"); s.hasAudioOutput = false; return s }(), desktop: .cpu, ringCenter: .network, glyphStyle: .combined),
            Case(name: "combined-allbad", snapshot: allBad, desktop: .cpu, ringCenter: .percent, glyphStyle: .combined),
            Case(name: "combined-charging", snapshot: battery(46, charging: true, onAC: true), desktop: .cpu, ringCenter: .percent, glyphStyle: .combined),
            Case(name: "combined-desktop-power", snapshot: StatusSnapshot.fixture("desktop"), desktop: .power, ringCenter: .network, glyphStyle: .combined),
            Case(name: "combined-desktop-hidden", snapshot: StatusSnapshot.fixture("desktop"), desktop: .hidden, ringCenter: .network, glyphStyle: .combined),
            Case(name: "classic-healthy", snapshot: StatusSnapshot.fixture("laptop"), desktop: .cpu, ringCenter: .network, glyphStyle: .classic),
            Case(name: "classic-allbad", snapshot: allBad, desktop: .cpu, ringCenter: .network, glyphStyle: .classic),
            // Repair1 section E additions — states root's fixed defects
            // specifically need visual evidence for, none of which any
            // existing case above actually exercised.
            Case(name: "classic-desktop-cpu-known", snapshot: StatusSnapshot.fixture("desktop"), desktop: .cpu, ringCenter: .network, glyphStyle: .classic),
            Case(name: "classic-desktop-cpu-unknown", snapshot: { var s = StatusSnapshot.fixture("desktop"); s.cpu = nil; return s }(), desktop: .cpu, ringCenter: .network, glyphStyle: .classic),
            Case(name: "combined-audio-unknown", snapshot: { var s = StatusSnapshot.fixture("desktop"); s.hasAudioOutput = nil; return s }(), desktop: .cpu, ringCenter: .network, glyphStyle: .combined),
            Case(name: "combined-percent-ethernet-mini", snapshot: { var s = battery(62); s.connection = .ethernet; return s }(), desktop: .cpu, ringCenter: .percent, glyphStyle: .combined),
            Case(name: "combined-wifi-unknown-strength", snapshot: { var s = StatusSnapshot.fixture("laptop"); s.wifiStrength = nil; return s }(), desktop: .cpu, ringCenter: .network, glyphStyle: .combined),
            // Repair2 additions — classic-only defects root proved via
            // actual pixels (speaker shape, network vertical alignment,
            // truthful CPU gauge, charging-bolt contrast): CPU 0/24/100/nil
            // (24 comes from classic-desktop-cpu-known's default fixture),
            // audio available/mute/unavailable/unknown (available via
            // classic-healthy, unavailable via classic-allbad), charging,
            // and all 5 connection types.
            Case(name: "classic-cpu-0", snapshot: { var s = StatusSnapshot.fixture("desktop"); s.cpu = 0; return s }(), desktop: .cpu, ringCenter: .network, glyphStyle: .classic),
            Case(name: "classic-cpu-100", snapshot: { var s = StatusSnapshot.fixture("desktop"); s.cpu = 1; return s }(), desktop: .cpu, ringCenter: .network, glyphStyle: .classic),
            Case(name: "classic-audio-mute", snapshot: { var s = StatusSnapshot.fixture("desktop"); s.muted = true; return s }(), desktop: .cpu, ringCenter: .network, glyphStyle: .classic),
            Case(name: "classic-audio-unknown", snapshot: { var s = StatusSnapshot.fixture("desktop"); s.hasAudioOutput = nil; return s }(), desktop: .cpu, ringCenter: .network, glyphStyle: .classic),
            Case(name: "classic-charging", snapshot: battery(46, charging: true, onAC: true), desktop: .cpu, ringCenter: .network, glyphStyle: .classic),
            // LABEL-FINISH: the 46% case only partly overlaps the fill and
            // can hide the mono-mode bolt-invisibility defect — a FULL
            // battery's fill covers the bolt's entire path, so only this
            // case actually proves the halo/cutout fix.
            Case(name: "classic-charging-100", snapshot: battery(100, charging: true, onAC: true), desktop: .cpu, ringCenter: .network, glyphStyle: .classic),
            Case(name: "classic-ethernet", snapshot: { var s = StatusSnapshot.fixture("laptop"); s.connection = .ethernet; return s }(), desktop: .cpu, ringCenter: .network, glyphStyle: .classic),
            Case(name: "classic-other", snapshot: { var s = StatusSnapshot.fixture("laptop"); s.connection = .other; return s }(), desktop: .cpu, ringCenter: .network, glyphStyle: .classic),
            Case(name: "classic-checking", snapshot: { var s = StatusSnapshot.fixture("laptop"); s.connection = .checking; return s }(), desktop: .cpu, ringCenter: .network, glyphStyle: .classic)
        ]

        let root = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var manifest: [[String: Any]] = []
        // One representative (dark/color/1x) image + resolved-state label per
        // case, captured during the main loop below — feeds the contact
        // sheet so root can review every state in one place instead of
        // opening 152 individual files by hand.
        var contactSheetEntries: [(name: String, image: NSImage, label: String, backgroundIsDark: Bool)] = []
        for testCase in cases {
            for background in ["light", "dark"] {
                for colorful in [true, false] {
                    let foreground: NSColor = background == "dark" ? .white : .black
                    for scale in [1, 2] {
                        let logicalSize: CGFloat = 27
                        let pixelSize = Int(logicalSize) * scale
                        let image = OrbitGlyph.image(testCase.snapshot, desktop: testCase.desktop, size: logicalSize * CGFloat(scale),
                                                     foreground: foreground, color: colorful,
                                                     ringCenter: testCase.ringCenter, glyphStyle: testCase.glyphStyle)
                        let isClassic = testCase.glyphStyle == .classic
                        let pixelWidth = isClassic ? pixelSize * 3 : pixelSize
                        let fileName = "\(testCase.name)-\(background)-\(colorful ? "color" : "mono")-\(scale)x.png"
                        let destination = root.appendingPathComponent(fileName)
                        // A rasterize/write failure must ABORT the whole
                        // export, not silently skip one file — a manifest
                        // that's missing an entry because of a swallowed
                        // failure looks identical to one that never had that
                        // case, which is indistinguishable from a truthful
                        // export at a glance.
                        guard let data = Self.rasterizeExact(image, pixelWidth: pixelWidth, pixelHeight: pixelSize,
                                                             backgroundIsDark: background == "dark") else {
                            fputs("orbit: --export-glyphs failed to rasterize \(fileName)\n", stderr)
                            exit(1)
                        }
                        do {
                            try data.write(to: destination)
                        } catch {
                            fputs("orbit: --export-glyphs failed to write \(fileName): \(error)\n", stderr)
                            exit(1)
                        }
                        let center = CenterContent.resolve(snapshot: testCase.snapshot, desktopRing: testCase.desktop, ringCenter: testCase.ringCenter)
                        let centerDescription: String
                        switch center {
                        case .network: centerDescription = "network"
                        case .percent(let value, let source): centerDescription = "percent(\(Int((value * 100).rounded()))%, \(source))"
                        }
                        manifest.append([
                            "file": fileName,
                            "case": testCase.name,
                            "glyphStyle": testCase.glyphStyle.rawValue,
                            "ringCenter": testCase.ringCenter.rawValue,
                            "desktopRing": testCase.desktop.rawValue,
                            "background": background,
                            "colorful": colorful,
                            "logicalPointSize": Int(logicalSize),
                            "scale": scale,
                            "pixelWidth": pixelWidth,
                            "pixelHeight": pixelSize,
                            "resolvedCenter": centerDescription,
                            "attentionReasons": AttentionAnalysis.reasons(snapshot: testCase.snapshot).map(\.rawValue)
                        ])
                        // Repair2: root asked for BOTH color themes plus
                        // mono in the contact sheet, not just one
                        // representative combo — same production `image`
                        // already rendered above, just also captured here
                        // (no repaint).
                        if scale == 1 {
                            let reasons = AttentionAnalysis.reasons(snapshot: testCase.snapshot).map(\.rawValue).joined(separator: ",")
                            let label = "\(background)/\(colorful ? "color" : "mono")  center=\(centerDescription)" + (reasons.isEmpty ? "" : "  attention=\(reasons)")
                            contactSheetEntries.append((name: testCase.name, image: image, label: label, backgroundIsDark: background == "dark"))
                        }
                    }
                }
            }
        }
        if let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? manifestData.write(to: root.appendingPathComponent("manifest.json"))
        }
        guard let sheetData = Self.buildContactSheet(contactSheetEntries) else {
            fputs("orbit: --export-glyphs failed to build contact sheet\n", stderr)
            exit(1)
        }
        do {
            try sheetData.write(to: root.appendingPathComponent("contact-sheet.png"))
        } catch {
            fputs("orbit: --export-glyphs failed to write contact sheet: \(error)\n", stderr)
            exit(1)
        }
        print("Exported \(manifest.count) glyph PNGs + manifest.json + contact-sheet.png to \(root.path)")
        NSApp.terminate(nil)
    }

    /// Dev-only: composites the ACTUAL rendered glyph for every
    /// (case, background theme, color/mono) combination at 1x — real size
    /// plus a 4x enlargement — with its case name and resolved-state label,
    /// stacked into one tall PNG. Composites already-rendered production
    /// `NSImage`s; draws no pixels of its own beyond a background swatch
    /// (matching each entry's OWN theme, not a fixed dark backdrop — a
    /// light-theme/black-foreground glyph would otherwise be invisible
    /// against a dark sheet) and text, so nothing here fabricates glyph
    /// content.
    private static func buildContactSheet(_ entries: [(name: String, image: NSImage, label: String, backgroundIsDark: Bool)]) -> Data? {
        guard !entries.isEmpty else { return nil }
        let rowHeight: CGFloat = 130
        let enlargeScale: CGFloat = 4
        let width = 760
        let height = Int(rowHeight) * entries.count
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.35, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        // Y-up bitmap coordinates (origin bottom-left) — row 0 must land at
        // the TOP of the sheet, so its slot is the highest band: from
        // `height - rowHeight` to `height`.
        for (index, entry) in entries.enumerated() {
            let rowBottomY = CGFloat(height) - CGFloat(index + 1) * rowHeight
            let realSize = entry.image.size
            let enlargedSize = NSSize(width: realSize.width * enlargeScale, height: realSize.height * enlargeScale)
            let enlargedX: CGFloat = 90
            // Swatch width must cover the WIDEST thing drawn on it —
            // classic glyphs are 3x wider (81pt) than combined (27pt), so a
            // fixed width would clip the enlarged classic glyph off the
            // edge of its own background.
            let swatchInk: NSColor = entry.backgroundIsDark ? .black : .white
            swatchInk.setFill()
            NSRect(x: 0, y: rowBottomY, width: enlargedX + enlargedSize.width + 10, height: rowHeight).fill()
            let realY = rowBottomY + (rowHeight - realSize.height) / 2
            entry.image.draw(in: NSRect(x: 16, y: realY, width: realSize.width, height: realSize.height),
                             from: .zero, operation: .sourceOver, fraction: 1)
            let enlargedY = rowBottomY + (rowHeight - enlargedSize.height) / 2
            entry.image.draw(in: NSRect(x: enlargedX, y: enlargedY, width: enlargedSize.width, height: enlargedSize.height),
                             from: .zero, operation: .sourceOver, fraction: 1)
            let textX = enlargedX + enlargedSize.width + 24
            let textRect = NSRect(x: textX, y: rowBottomY, width: CGFloat(width) - textX - 12, height: rowHeight)
            let text = NSMutableAttributedString()
            text.append(NSAttributedString(string: entry.name + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white
            ]))
            text.append(NSAttributedString(string: entry.label, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor(white: 0.75, alpha: 1)
            ]))
            text.draw(with: textRect, options: [.usesLineFragmentOrigin])
            if index > 0 {
                NSColor(white: 1, alpha: 0.08).setFill()
                NSRect(x: 0, y: rowBottomY + rowHeight - 1, width: CGFloat(width), height: 1).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Rasterizes an already-rendered vector `NSImage` into an EXACT pixel
    /// bitmap regardless of the current screen's backing scale factor —
    /// `NSImage.lockFocus()` (used inside `OrbitGlyph.image`) sizes its
    /// backing store relative to whatever screen is current, which would
    /// silently make "1x"/"2x" ambiguous. A solid background is drawn
    /// first because a menu-bar glyph is normally composited over the real
    /// (non-transparent) menu bar, and a template/mono image on a fully
    /// transparent PNG is unreadable when merely opened in an image viewer.
    private static func rasterizeExact(_ image: NSImage, pixelWidth: Int, pixelHeight: Int, backgroundIsDark: Bool) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixelWidth, height: pixelHeight)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let full = NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        (backgroundIsDark ? NSColor.black : NSColor.white).setFill()
        full.fill()
        // `image`'s own logical size already matches the target pixel rect
        // 1:1 (callers request `size: logicalSize * scale`), so this is a
        // direct (not up/down-sampled) draw.
        image.draw(in: full, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func capturePNG(of view: NSView, to destination: URL) {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        do { try data.write(to: destination); print("Preview saved: \(destination.path)") }
        catch { fputs("Unable to save preview: \(error)\n", stderr) }
    }

    private static func argValue(_ args: [String], after flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }
}

/// `--diagnose`'s JSON payload: the existing snapshot fields plus the
/// actual, real (or fixture) peripherals list + each entry's `source`/
/// `statusNote` diagnostics, plus `peripheralReadStatus` — so an empty
/// `peripherals` list can be told apart as "no readable device" (`available
/// == true`) versus "the read source itself failed" (`available == false`,
/// with `errorNote` saying why), not just a pass/fail.
private struct DiagnoseReport: Encodable {
    let snapshot: StatusSnapshot
    let peripherals: [Peripheral]
    let peripheralReadStatus: PeripheralReadStatus
}
