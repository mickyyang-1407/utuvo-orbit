import SwiftUI
import OrbitCore

// MARK: - GalleryView
//
// One panel + a fixture selector, not a 2-column/3-row grid. The panel is a
// fixed 372pt wide; a 2×3 grid of full panels needs >1100pt of height and
// previously clipped inside this window with no ScrollView. A single panel
// at a time always fits, and every fixture state — including ones that only
// make sense alone (e.g. "unknown") — is reachable via the picker instead of
// being permanently hidden off-grid.
//
// Uses fake backends only; nothing reads live system state. `--snapshot`
// writes the rendered window's own pixels, never via ScreenCaptureKit or
// accessibility — a static export can't prove native glass renders
// correctly on-device, only that the fixture data plumbing is right.

struct GalleryView: View {
    @Environment(\.orbitStrings) private var l
    static let fixtureNames = ["desktop", "laptop", "charging", "low", "external", "offline", "unknown",
                               "degraded", "percent-center", "classic",
                               "peripherals", "peripherals-long-names", "peripherals-empty",
                               "peripherals-unknown", "peripherals-charging"]
    @State private var selection: String
    @State private var dark: Bool

    init(fixture: String? = nil, light: Bool = false) {
        _selection = State(initialValue: fixture ?? "desktop")
        _dark = State(initialValue: !light)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(l("UTUVO Orbit · 預覽（模擬資料）"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle(l("深色"), isOn: $dark).toggleStyle(.switch).frame(width: 90)
            }
            // A `.segmented` picker with this many entries clipped at this
            // window's 480pt width (10 entries already crowded it; the 5
            // peripheral fixtures below would make it worse) — a native
            // popup menu scales to any entry count without reflowing or
            // truncating labels.
            Picker(l("情境"), selection: $selection) {
                ForEach(GalleryView.fixtureNames, id: \.self) { name in
                    Text(l(GalleryView.title(for: name))).tag(name)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220, alignment: .leading)
            FixturePanel(name: selection, language: AppLanguage(rawValue: l.identifier) ?? .english)
                .id(selection)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 480, height: 640)
        .background(dark ? Color(white: 0.075) : Color(white: 0.93))
        .preferredColorScheme(dark ? .dark : .light)
    }

    static func title(for name: String) -> String {
        switch name {
        case "desktop": return "桌機"
        case "laptop": return "筆電"
        case "charging": return "充電中"
        case "low": return "低電量"
        case "external": return "外接音訊"
        case "offline": return "離線"
        case "unknown": return "未知"
        case "degraded": return "多重異常"
        case "percent-center": return "百分比中央"
        case "classic": return "傳統樣式"
        case "peripherals": return "周邊裝置"
        case "peripherals-long-names": return "周邊裝置（長名稱 x4）"
        case "peripherals-empty": return "周邊裝置（無資料）"
        case "peripherals-unknown": return "周邊裝置（電量未知）"
        case "peripherals-charging": return "周邊裝置（充電中）"
        default: return name
        }
    }
}

/// Owns one fixture's stable backends + coordinator, created exactly once
/// per fixture selection. Previously `FixturePanel.body` created FRESH fake
/// backends on every SwiftUI body evaluation while `SystemMonitor(fixture:)`
/// was constructed with none at all — the monitor's `refresh()` early-
/// returned forever (no `systemBackend`/`networkBackend`), so the panel
/// (which now only mirrors the coordinator's published state, not its own
/// polls) showed nothing but empty/placeholder metrics. Holding one
/// `FixtureSession` in a `@StateObject` means the monitor is constructed
/// WITH the same backends the panel uses, so it actually has something to
/// read and publish.
@MainActor
final class FixtureSession: ObservableObject {
    let monitor: SystemMonitor
    let preferences: OrbitPreferencesModel
    let audioBackend: AudioBackend
    let networkBackend: NetworkBackend
    let systemBackend: SystemBackend
    let peripheralBackend: PeripheralBackend
    let awakeBackend: AwakeBackend

    init(fixtureName: String, language: AppLanguage = .system) {
        // `FixtureFactory.resolve` is the ONE place that maps a fixture
        // NAME to its (snapshot, preferences, peripherals) — shared with
        // the CLI `--fixture` path so this gallery and a real `--fixture`
        // launch can never silently diverge on what a given name means.
        let resolved = FixtureFactory.resolve(fixtureName)
        let snapshot = resolved.snapshot
        let backends = FixtureFactory.makeBackends(for: snapshot, peripherals: resolved.peripherals)
        audioBackend = backends.audio
        networkBackend = backends.network
        systemBackend = backends.system
        peripheralBackend = backends.peripheral
        awakeBackend = FakeAwakeBackend()
        monitor = SystemMonitor(fixture: snapshot, systemBackend: systemBackend,
                                networkBackend: networkBackend, audioBackend: audioBackend,
                                peripheralBackend: peripheralBackend)
        var values = resolved.preferences
        values.language = language
        preferences = OrbitPreferencesModel(backend: FakePreferencesBackend(initial: values, legacy: nil))
    }

    func stop() { monitor.stop() }
}

struct FixturePanel: View {
    @StateObject private var session: FixtureSession
    init(name: String, language: AppLanguage = .system) {
        _session = StateObject(wrappedValue: FixtureSession(fixtureName: name, language: language))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MenubarGlyphPreview(monitor: session.monitor, preferences: session.preferences)
            OrbitPanel(monitor: session.monitor, preferences: session.preferences,
                      audioBackend: session.audioBackend, networkBackend: session.networkBackend,
                      systemBackend: session.systemBackend, awakeBackend: session.awakeBackend,
                      preview: true)
        }
            // Small related lifecycle fix: previously nothing ever called
            // `session.stop()` — `.id(selection)` in `GalleryView` already
            // tears down and rebuilds this whole `@StateObject` on every
            // fixture switch, so the outgoing session's `Timer` (and now
            // also its peripheral-poll state) kept running/leaking instead
            // of being invalidated.
            .onDisappear { session.stop() }
    }
}

/// Dev-only: renders the ACTUAL production `OrbitGlyph.image(...)` (the
/// same call `AppDelegate.updateIcon()` makes for the real menu bar) at real
/// size plus a 3x enlargement, so a style/center/state change is reviewable
/// without needing the real menubar — root's own review previously required
/// inspecting exported PNGs by hand for exactly this reason.
private struct MenubarGlyphPreview: View {
    @Environment(\.orbitStrings) private var l
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var preferences: OrbitPreferencesModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let foreground: NSColor = colorScheme == .dark ? .white : .black
        let image = OrbitGlyph.image(monitor.snapshot, desktop: preferences.values.desktopRing, size: 27,
                                     foreground: foreground, color: preferences.values.colorful,
                                     ringCenter: preferences.values.ringCenter, glyphStyle: preferences.values.glyphStyle)
        return HStack(spacing: 10) {
            Text(l("實際選單列圖示")).font(.system(size: 11)).foregroundStyle(.secondary)
            Image(nsImage: image).frame(width: image.size.width, height: image.size.height)
            Image(nsImage: image).resizable()
                .frame(width: image.size.width * 3, height: image.size.height * 3)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}
