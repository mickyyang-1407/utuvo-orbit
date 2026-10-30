import AppKit
import Combine
import SwiftUI
import OrbitCore

// Offline help for Orbit.
//
// Everything in this file is bundled text: no network call, no web view, no
// telemetry, no analytics. The same content backs three doors — the Settings
// "Help" page, the help window opened from the menu-bar context menu and the
// workbench, and the ⌘? item in the app's main menu — so there is exactly one
// copy of the words and one place to correct them.
//
// The strings live in `OrbitCore`'s `Localizable.strings` (en + zh-Hant) under
// the `orbit.help.*` namespace. Unlike the older entries in that file — whose
// keys are the Chinese source text — the help keys are stable identifiers, so
// a paragraph can be reworded without renaming its key, and a missing
// translation is detectable instead of silently falling back to English.

/// One paragraph of help: a short title and its body.
struct OrbitHelpEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
}

/// One chapter of the help.
struct OrbitHelpSection: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let entries: [OrbitHelpEntry]
}

/// An optional pointer to an official source. It opens only when the reader
/// explicitly presses it — Orbit never loads it on its own, and it carries no
/// data of any kind.
struct OrbitHelpLink: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let url: URL
}

/// The help text itself, resolved for one language.
@MainActor
enum OrbitHelpContent {
    /// One entry per workbench page, in the order the sidebar lists them.
    ///
    /// The list is derived from the navigation itself, so a tool cannot be
    /// added without a matching paragraph — the coverage is structural, not a
    /// promise somebody has to keep by hand.
    static func toolEntries(language: AppLanguage) -> [OrbitHelpEntry] {
        let copy = ToolCopy(language: language)
        let strings = OrbitStrings(language: language)
        return OrbitToolsNavigation.Page.allCases.map { page in
            OrbitHelpEntry(id: "tool." + page.rawValue,
                           title: page.title(copy),
                           body: strings("orbit.help.tool.\(page.rawValue).body"))
        }
    }

    static func sections(language: AppLanguage) -> [OrbitHelpSection] {
        let strings = OrbitStrings(language: language)
        return [
            OrbitHelpSection(
                id: "gettingStarted",
                title: strings("orbit.help.gettingStarted.title"),
                summary: strings("orbit.help.gettingStarted.summary"),
                entries: [
                    entry("menuBar", "orbit.help.gettingStarted.menuBar.title", "orbit.help.gettingStarted.menuBar.body", strings),
                    entry("panel", "orbit.help.gettingStarted.panel.title", "orbit.help.gettingStarted.panel.body", strings),
                    entry("workbench", "orbit.help.gettingStarted.workbench.title", "orbit.help.gettingStarted.workbench.body", strings),
                    entry("settings", "orbit.help.gettingStarted.settings.title", "orbit.help.gettingStarted.settings.body", strings)
                ]),
            OrbitHelpSection(
                id: "tools",
                title: strings("orbit.help.tools.title"),
                summary: strings("orbit.help.tools.summary"),
                entries: toolEntries(language: language)),
            OrbitHelpSection(
                id: "workflows",
                title: strings("orbit.help.workflows.title"),
                summary: strings("orbit.help.workflows.summary"),
                entries: [
                    entry("screenshot", "orbit.help.workflow.screenshot.title", "orbit.help.workflow.screenshot.body", strings),
                    entry("clipboard", "orbit.help.workflow.clipboard.title", "orbit.help.workflow.clipboard.body", strings),
                    entry("snippet", "orbit.help.workflow.snippet.title", "orbit.help.workflow.snippet.body", strings),
                    entry("file", "orbit.help.workflow.file.title", "orbit.help.workflow.file.body", strings),
                    entry("audio", "orbit.help.workflow.audio.title", "orbit.help.workflow.audio.body", strings),
                    entry("backup", "orbit.help.workflow.backup.title", "orbit.help.workflow.backup.body", strings)
                ]),
            OrbitHelpSection(
                id: "shortcuts",
                title: strings("orbit.help.shortcuts.title"),
                summary: strings("orbit.help.shortcuts.summary"),
                entries: [
                    entry("help", "orbit.help.shortcut.help.title", "orbit.help.shortcut.help.body", strings),
                    entry("edit", "orbit.help.shortcut.edit.title", "orbit.help.shortcut.edit.body", strings),
                    entry("actions", "orbit.help.shortcut.actions.title", "orbit.help.shortcut.actions.body", strings),
                    entry("save", "orbit.help.shortcut.save.title", "orbit.help.shortcut.save.body", strings),
                    entry("escape", "orbit.help.shortcut.escape.title", "orbit.help.shortcut.escape.body", strings),
                    entry("quit", "orbit.help.shortcut.quit.title", "orbit.help.shortcut.quit.body", strings),
                    entry("clothesline", "orbit.help.shortcut.clothesline.title", "orbit.help.shortcut.clothesline.body", strings)
                ]),
            OrbitHelpSection(
                id: "privacy",
                title: strings("orbit.help.privacy.title"),
                summary: strings("orbit.help.privacy.summary"),
                entries: [
                    entry("local", "orbit.help.privacy.local.title", "orbit.help.privacy.local.body", strings),
                    entry("login", "orbit.help.privacy.login.title", "orbit.help.privacy.login.body", strings),
                    entry("modules", "orbit.help.privacy.modules.title", "orbit.help.privacy.modules.body", strings),
                    entry("clipboard", "orbit.help.privacy.clipboard.title", "orbit.help.privacy.clipboard.body", strings),
                    entry("capture", "orbit.help.privacy.capture.title", "orbit.help.privacy.capture.body", strings),
                    entry("updates", "orbit.help.privacy.updates.title", "orbit.help.privacy.updates.body", strings),
                    entry("data", "orbit.help.privacy.data.title", "orbit.help.privacy.data.body", strings)
                ])
        ]
    }

    static func links(language: AppLanguage) -> [OrbitHelpLink] {
        let strings = OrbitStrings(language: language)
        return [
            OrbitHelpLink(id: "repository",
                          title: strings("orbit.help.links.repository.title"),
                          body: strings("orbit.help.links.repository.body"),
                          url: URL(string: "https://github.com/mickyyang-1407/utuvo-orbit")!),
            OrbitHelpLink(id: "appleCapture",
                          title: strings("orbit.help.links.apple.title"),
                          body: strings("orbit.help.links.apple.body"),
                          url: URL(string: "https://developer.apple.com/documentation/screencapturekit")!)
        ]
    }

    private static func entry(_ id: String, _ titleKey: String, _ bodyKey: String, _ strings: OrbitStrings) -> OrbitHelpEntry {
        OrbitHelpEntry(id: id, title: strings(titleKey), body: strings(bodyKey))
    }
}

/// The language and theme pair the help follows. A named type rather than a
/// tuple, because tuples are not `Equatable` and the change has to be
/// de-duplicated before it reaches the view.
struct OrbitHelpLanguageTheme: Equatable {
    let language: AppLanguage
    let theme: AppTheme
}

/// The language and theme the help is rendered in. Held as an object so the
/// window can follow an app-language change without rebuilding its view
/// hierarchy — rebuilding would throw away the reader's scroll position.
@MainActor
final class OrbitHelpState: ObservableObject {
    @Published private(set) var language: AppLanguage
    @Published private(set) var theme: AppTheme

    init(language: AppLanguage, theme: AppTheme) {
        self.language = language
        self.theme = theme
    }

    func update(language: AppLanguage, theme: AppTheme) {
        if self.language != language { self.language = language }
        if self.theme != theme { self.theme = theme }
    }
}

/// The help text, without a scroll view of its own.
///
/// The Settings window already scrolls, so it embeds this directly; the
/// standalone help window wraps it in a `ScrollView` of its own.
struct OrbitHelpBody: View {
    let language: AppLanguage
    var onOpenLink: (URL) -> Void = { _ in }

    private var strings: OrbitStrings { OrbitStrings(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(OrbitHelpContent.sections(language: language)) { section in
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title).font(.system(size: 17, weight: .semibold))
                        Text(section.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 8) {
                        ForEach(section.entries) { entry in
                            helpCard(title: entry.title, body: entry.body)
                        }
                    }
                }
            }
            let links = OrbitHelpContent.links(language: language)
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(strings("orbit.help.links.title")).font(.system(size: 17, weight: .semibold))
                        Text(strings("orbit.help.links.summary")).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 8) {
                        ForEach(links) { link in
                            helpCard(title: link.title, body: link.body) {
                                // Explicit press only. The browser opens with
                                // nothing but the address itself — no data.
                                Button(strings("orbit.help.links.open")) { onOpenLink(link.url) }
                                    .controlSize(.small)
                                    .accessibilityLabel(strings("orbit.help.links.openLabel") + link.title)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func helpCard<Accessory: View>(title: String, body: String,
                                           @ViewBuilder accessory: () -> Accessory = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(body).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            accessory()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.055)))
    }
}

/// The standalone help window: a search field over the same content.
struct OrbitHelpView: View {
    @ObservedObject var state: OrbitHelpState
    var onOpenLink: (URL) -> Void = { _ in }
    @State private var query = ""

    private var strings: OrbitStrings { OrbitStrings(language: state.language) }

    /// Sections filtered by the search field. An empty query shows
    /// everything; a query that matches a section title keeps the whole
    /// section, and otherwise only the matching paragraphs survive.
    private var filtered: [OrbitHelpSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return OrbitHelpContent.sections(language: state.language) }
        return OrbitHelpContent.sections(language: state.language).compactMap { section in
            if section.title.localizedCaseInsensitiveContains(needle)
                || section.summary.localizedCaseInsensitiveContains(needle) {
                return section
            }
            let entries = section.entries.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
                    || $0.body.localizedCaseInsensitiveContains(needle)
            }
            return entries.isEmpty ? nil : OrbitHelpSection(id: section.id, title: section.title,
                                                            summary: section.summary, entries: entries)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(strings("orbit.help.intro.title")).font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(strings("orbit.help.intro.body")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(strings("orbit.help.search.placeholder"), text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel(strings("orbit.help.search.placeholder"))
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel(strings("orbit.help.search.clear"))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }
            .padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 16)
            Divider().opacity(0.5)
            ScrollView {
                if filtered.isEmpty {
                    Text(strings("orbit.help.search.empty")).font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else {
                    OrbitHelpBody(language: state.language, onOpenLink: onOpenLink)
                        .padding(.horizontal, 26).padding(.vertical, 20)
                }
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: 760, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(OrbitPalette.accent)
        .environment(\.orbitStrings, strings)
        .environment(\.locale, Locale(identifier: strings.identifier))
        .preferredColorScheme(state.theme == .system ? nil : (state.theme == .dark ? .dark : .light))
    }
}

/// Owns the help window. The window is created on first use and reused
/// afterwards, so opening the help twice never stacks two windows.
@MainActor
final class OrbitHelpWindowController {
    private var window: NSWindow?
    private var hosting: NSHostingController<OrbitHelpView>?
    private let state: OrbitHelpState
    private var subscription: AnyCancellable?

    init(preferences: OrbitPreferencesModel) {
        state = OrbitHelpState(language: preferences.values.language, theme: preferences.values.theme)
        subscription = preferences.$values
            .map { OrbitHelpLanguageTheme(language: $0.language, theme: $0.theme) }
            .removeDuplicates()
            .sink { [weak self] value in
                self?.state.update(language: value.language, theme: value.theme)
                self?.syncWindow()
            }
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: OrbitHelpView(state: state, onOpenLink: { [weak self] url in
                // Only ever reached from an explicit press on the link row.
                NSWorkspace.shared.open(url)
                _ = self
            }))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 760, height: 620))
            window.center()
            self.hosting = hosting
            self.window = window
        }
        syncWindow()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func syncWindow() {
        window?.title = OrbitStrings(language: state.language)("orbit.help.window.title")
        window?.appearance = state.theme == .system ? nil : NSAppearance(named: state.theme == .dark ? .darkAqua : .aqua)
    }
}
