import AppKit
import Combine
import SwiftUI
import ClotheslineKit
import OrbitCore

@MainActor
final class OrbitSettingsWindowController {
    private var window: NSWindow?
    private let modules: OrbitModules
    private let preferences: OrbitPreferencesModel
    private let updates: OrbitUpdateModel
    private let loginItem: LoginItemModel
    private let onOpenHelp: () -> Void
    private var appearanceSubscription: AnyCancellable?

    init(modules: OrbitModules, preferences: OrbitPreferencesModel, updates: OrbitUpdateModel,
         loginItem: LoginItemModel = LoginItemModel(),
         onOpenHelp: @escaping () -> Void = {}) {
        self.modules = modules
        self.preferences = preferences
        self.updates = updates
        self.loginItem = loginItem
        self.onOpenHelp = onOpenHelp
        appearanceSubscription = preferences.$values.sink { [weak self] _ in self?.syncWindow() }
    }

    func show() {
        loginItem.refresh()
        if window == nil {
            let view = OrbitSettingsView(modules: modules, clothesline: modules.clothesline.settings,
                                         preferences: preferences, loginItem: loginItem, updates: updates,
                                         onOpenHelp: onOpenHelp)
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 620, height: 600))
            window.center()
            self.window = window
        }
        syncWindow()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    private func syncWindow() {
        window?.title = OrbitStrings(language: preferences.values.language)("UTUVO Orbit 設定")
        let theme = preferences.values.theme
        window?.appearance = theme == .system ? nil : NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
    }
}

struct OrbitSettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general, modules, updates, help
        var id: Self { self }
        var title: String {
            switch self { case .general: "一般"; case .modules: "模組"; case .updates: "更新"; case .help: "說明" }
        }
        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"; case .modules: "square.stack.3d.up"
            case .updates: "arrow.down.circle"; case .help: "questionmark.circle"
            }
        }
    }

    @ObservedObject var modules: OrbitModules
    @ObservedObject var clothesline: ClotheslineSettings
    @ObservedObject var preferences: OrbitPreferencesModel
    @ObservedObject var loginItem: LoginItemModel
    @ObservedObject var updates: OrbitUpdateModel
    /// Opens the offline guide. The Settings page shows the same text the
    /// help window does, so there is one copy of the words.
    var onOpenHelp: () -> Void = {}
    @State var page: Page = .general
    var preview = false

    private var l: OrbitStrings { OrbitStrings(language: preferences.values.language) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                OrbitBrandMark(size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("UTUVO Orbit").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(l("讓 Mac，照你的方式運轉。"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(OrbitVersion.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 22)
            Picker(l("設定分類"), selection: $page) {
                ForEach(Page.allCases) { item in
                    Label(l(item.title), systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.large)
            .padding(.horizontal, 28).padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch page {
                    case .general: general
                    case .modules: moduleSettings
                    case .updates: updateSettings
                    case .help: helpContent
                    }
                }
                .padding(.horizontal, 28).padding(.top, 2).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Label(l(preview ? "預覽資料" : "選單列裡，剛剛好的工具。"), systemImage: "circle.dotted")
                Spacer()
                Text("UTUVO").tracking(2).fontWeight(.medium)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 28).padding(.vertical, 14)
            .background(.primary.opacity(0.025))
        }
        .frame(width: 620, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(OrbitPalette.accent)
        .environment(\.orbitStrings, l)
        .environment(\.locale, Locale(identifier: l.identifier))
        .preferredColorScheme(preferences.values.theme == .system ? nil : (preferences.values.theme == .dark ? .dark : .light))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeading(l("隨時就緒"), detail: l("登入後，在選單列陪你開始一天。"))
            settingsCard {
                Toggle(isOn: Binding(get: { loginItem.isOn }, set: { loginItem.set($0) })) {
                    settingLabel(l("登入時開啟 UTUVO Orbit"), symbol: "power",
                                 detail: l("只在選單列啟動，不打開額外視窗。"))
                }.toggleStyle(.switch)
                    .accessibilityLabel(l("登入時開啟 UTUVO Orbit"))
                    .accessibilityHint(l("只在選單列啟動，不打開額外視窗。"))
                Divider().padding(.vertical, 4)
                HStack(spacing: 6) {
                    Image(systemName: loginItem.status == .enabled ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(loginItem.status == .enabled ? OrbitPalette.accent : Color.secondary)
                    Text(l(loginStatus)).font(.system(size: 11))
                    Spacer()
                    if loginItem.status == .requiresApproval || loginItem.status == .notFound {
                        Button(l("打開登入項目")) { loginItem.openSettings() }.controlSize(.small)
                    }
                }.foregroundStyle(.secondary)
                if let error = loginItem.lastError { note(error, warning: true) }
            }
            sectionHeading(l("外觀與語言"), detail: l("讓 Orbit 融入你的桌面。"))
            settingsCard {
                Picker(l("主題"), selection: Binding(get: { preferences.values.theme }, set: { value in preferences.update { $0.theme = value } })) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in Text(l(theme.localizedTitle)).tag(theme) }
                }.pickerStyle(.segmented)
                Divider().padding(.vertical, 4)
                Picker(l("語言"), selection: Binding(get: { preferences.values.language }, set: { value in preferences.update { $0.language = value } })) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in Text(l(language.displayName)).tag(language) }
                }
            }
        }
    }

    private var loginStatus: String {
        switch loginItem.status {
        case .enabled: "已開啟，下次登入會自動啟動。"
        case .requiresApproval: "等待你在系統設定中允許。"
        case .notFound: "請先將 Orbit 放進「應用程式」再開啟。"
        default: "尚未開啟，隨時可以手動啟動。"
        }
    }

    private var moduleSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading(l("你的桌面小幫手"), detail: l("需要時才開啟，讓桌面保持簡單。"))
            settingsCard {
                Toggle(isOn: binding(.shelf)) {
                    settingLabel(l("貓尾巴檔案架"), symbol: "cat",
                          detail: l("螢幕邊緣的小貓平常只露出尾巴。把檔案拖到牠身上暫放，要用時再拖出來；原始檔案不會被移動或改動。"))
                }.toggleStyle(.switch).disabled(preview)
                    .accessibilityLabel(l("貓尾巴檔案架"))
                if modules.shelfEnabled {
                    Divider().padding(.vertical, 4)
                    HStack {
                        Button(l("移到另一側")) { modules.shelf.moveToOtherEdge() }
                        Button(l("重設位置")) { modules.shelf.resetPosition() }
                    }.disabled(preview)
                }
            }
            settingsCard {
                Toggle(isOn: binding(.clothesline)) {
                    settingLabel(l("截圖晾衣繩"), symbol: "photo.on.rectangle.angled",
                          detail: l("新截圖會掛在螢幕上緣的繩子上。滑鼠移到選單列就會滑出來，⌃⌥T 固定顯示。點一下拷貝、雙擊用「預覽程式」打開、拖出去就能用。"))
                }.toggleStyle(.switch).disabled(preview)
                    .accessibilityLabel(l("截圖晾衣繩"))
                if modules.clotheslineEnabled {
                    Divider().padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent(l("截圖資料夾")) {
                            HStack {
                                Text(clothesline.folderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? l("尚未選擇"))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Button(l("選擇…")) { clothesline.chooseFolder() }
                            }
                        }
                        Toggle(l("不上桌面：收好後把原檔移到垃圾桶"), isOn: $clothesline.noDesktop)
                        Picker(l("自動收進垃圾桶"), selection: $clothesline.days) {
                            ForEach(ClotheslineSettings.retentionChoices, id: \.self) { days in
                                Text(days == 0 ? l("不自動清理") : l("%d 天後", days)).tag(days)
                            }
                        }
                        Slider(value: $clothesline.frameWidth, in: 120...240) { Text(l("相框大小")) }
                        HStack {
                            Button(l("打開素材庫")) { modules.clothesline.openLibrary() }
                            Button(l("現在收拾過期截圖")) { modules.clothesline.cleanNow() }
                        }
                        note(l("只收開始監聽後新增的系統截圖（⌘⇧3／⌘⇧4／⌘⇧5 存成檔案的那種）。UTUVO Orbit 不改系統截圖位置與快捷鍵；清理只放進垃圾桶，可以復原。"))
                        if let problem = modules.clothesline.hotkeyProblem { note(problem, warning: true) }
                        if let error = modules.clotheslineError { note(error, warning: true) }
                    }.disabled(preview)
                }
            }
        }
    }

    private var updateSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeading(l("持續變得更好"), detail: l("更新方式，由你決定。"))
            settingsCard {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 30, weight: .light)).foregroundStyle(OrbitPalette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("UTUVO Orbit").font(.system(size: 14, weight: .semibold))
                        Text(l("目前版本 %@", OrbitVersion.label)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if updates.distribution == .appStore {
                        Button(l("在 App Store 更新")) { updates.openAppStore() }.buttonStyle(.borderedProminent)
                    } else {
                        Button(l("檢查更新…")) { updates.check() }
                            .buttonStyle(.borderedProminent).disabled(!updates.state.canCheck)
                    }
                }
                if updates.distribution == .direct {
                    Divider().padding(.vertical, 6)
                    Toggle(isOn: Binding(get: { updates.state.automaticChecks }, set: { updates.setAutomaticChecks($0) })) {
                        Text(l("自動檢查更新")).frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch)
                    Toggle(isOn: Binding(get: { updates.state.automaticDownloads }, set: { updates.setAutomaticDownloads($0) })) {
                        Text(l("自動下載並安裝更新")).frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch).disabled(!updates.state.automaticChecks)
                    note(l("每天檢查一次。開啟自動安裝後，更新會在結束 Orbit 時套用。"))
                    if let date = updates.state.lastCheck {
                        Text(l("上次檢查 %@", date.formatted(date: .abbreviated, time: .shortened)))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else { note(l("尚未檢查更新")) }
                } else if updates.distribution == .appStore {
                    note(l("此版本透過 Mac App Store 更新。你可以在 App Store 設定中開啟自動更新。"))
                } else {
                    note(l("此測試版尚未連接正式更新服務。正式發布前會完成設定。"))
                }
                if let error = updates.state.error { note(error, warning: true) }
            }
            Label(l("更新安裝前會驗證簽章。你的設定與檔案會保留。"), systemImage: "checkmark.seal")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func binding(_ kind: OrbitModules.Kind) -> Binding<Bool> {
        Binding(get: { modules.isEnabled(kind) }, set: { modules.setEnabled(kind, $0) })
    }

    /// The guide, inline. It is exactly the content the help window shows —
    /// one copy of the words, two ways to read it.
    private var helpContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            OrbitHelpBody(language: preferences.values.language) { url in
                // Only ever reached from an explicit press on the link row.
                NSWorkspace.shared.open(url)
            }
            Button(l("另開視窗")) { onOpenHelp() }
                .controlSize(.small)
        }
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .font(.system(size: 12)).padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.055)))
    }

    private func settingLabel(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(OrbitPalette.accent)
                .frame(width: 32, height: 32).background(OrbitPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(warning ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
