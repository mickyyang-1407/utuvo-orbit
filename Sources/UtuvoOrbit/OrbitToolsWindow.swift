import AppKit
import Combine
import SwiftUI
import OrbitCore
import ShelfKit

@MainActor
final class OrbitToolsNavigation: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case modes, actions, audio, timer, clocks, reminders, clipboard, notes, snippets, links, integrity, text, calculator, files, pdf, screenshots, colors, qr
        var id: Self { self }
        func title(_ c: ToolCopy) -> String {
            switch self {
            case .modes: c("情境模式", "Modes"); case .actions: c("快捷動作", "Actions")
            case .audio: c("音訊情境", "Audio scenes"); case .timer: c("計時器", "Timer")
            case .reminders: c("聰明提醒", "Reminders"); case .clipboard: c("剪貼簿", "Clipboard")
            case .text: c("文字工具", "Text"); case .files: c("檔案處理", "Files")
            case .pdf: "PDF"; case .screenshots: c("截圖", "Screenshots")
            case .colors: c("取色器", "Colors"); case .qr: "QR Code"
            case .calculator: c("計算與換算", "Calculator"); case .clocks: c("世界時鐘", "World clock")
            case .notes: c("快速筆記", "Notes")
            case .links: c("快捷連結", "Quick links")
            case .snippets: c("文字片段", "Snippets")
            case .integrity: c("檔案檢查", "File integrity")
            }
        }
        var symbol: String {
            switch self { case .modes: "sparkles"; case .actions: "command"; case .audio: "waveform"; case .timer: "timer"; case .reminders: "bell"; case .clipboard: "doc.on.clipboard"; case .text: "text.alignleft"; case .files: "folder"; case .pdf: "doc.richtext"; case .screenshots: "crop"; case .colors: "eyedropper"; case .qr: "qrcode"; case .calculator: "function"; case .clocks: "globe"; case .notes: "note.text"; case .links: "link"; case .snippets: "text.quote"; case .integrity: "checkmark.shield" }
        }
    }
    @Published var page: Page = .modes
}

@MainActor
final class OrbitToolsWindowController {
    let scenes: AudioScenesModel
    let timer: OrbitTimerModel
    let screenshots: ScreenshotToolsModel
    let files: QuickFileToolsModel
    let workbench: OrbitWorkbench
    private var actionWindow: NSPanel?
    private var allowed = true
    let navigation = OrbitToolsNavigation()
    private let preferences: OrbitPreferencesModel
    private let preview: Bool
    private let allowFileActionsInPreview: Bool
    /// Opens the offline guide. The workbench and the help window show the
    /// same content.
    private let onOpenHelp: () -> Void
    private(set) var window: NSWindow?
    private var appearanceSubscription: AnyCancellable?

    init(preferences: OrbitPreferencesModel, scenes: AudioScenesModel, timer: OrbitTimerModel, preview: Bool = false, allowFileActionsInPreview: Bool = false,
         screenshots: ScreenshotToolsModel? = nil, defaults: UserDefaults? = nil,
         workbenchOverrides: OrbitWorkbenchOverrides? = nil,
         onOpenHelp: @escaping () -> Void = {}) {
        self.preferences = preferences; self.scenes = scenes; self.timer = timer; self.preview = preview
        self.allowFileActionsInPreview = allowFileActionsInPreview
        self.onOpenHelp = onOpenHelp
        let workbench = OrbitWorkbench(scenes: scenes, timer: timer, preview: preview,
                                       allowFileActionsInPreview: allowFileActionsInPreview,
                                       defaults: defaults, language: preferences.values.language,
                                       overrides: workbenchOverrides)
        self.workbench = workbench
        self.files = QuickFileToolsModel(copyText: workbench.copyText)
        self.screenshots = screenshots ?? ScreenshotToolsModel(preview: preview)
        self.screenshots.onSendToFiles = { [weak self] url in
            self?.files.setFiles([url]); self?.navigation.page = .files
        }
        self.screenshots.onSendToQR = { [weak self] image in
            self?.workbench.qr.recognize(image); self?.navigation.page = .qr
        }
        workbench.commands.onOpen = { [weak self] in self?.showActions() }
        workbench.commands.onClose = { [weak self] in self?.actionWindow?.orderOut(nil) }
        appearanceSubscription = preferences.$values.sink { [weak self] _ in self?.syncWindow() }
    }

    func show(page: OrbitToolsNavigation.Page = .modes, files urls: [URL]? = nil) {
        guard allowed else { return }
        navigation.page = page
        scenes.refreshCatalog()
        prepareActions()
        if let urls { files.setFiles(urls) }
        if window == nil {
            let view = OrbitToolsView(preferences: preferences, scenes: scenes, timer: timer, files: files, screenshots: screenshots, navigation: navigation, workbench: workbench, onOpenActions: { [weak self] in self?.showActions() },
                                      onOpenHelp: onOpenHelp,
                                      preview: preview, allowFileActionsInPreview: allowFileActionsInPreview)
            let controller = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 940, height: 750)); window.center()
            self.window = window
        }
        syncWindow()
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showActions() {
        guard allowed else { return }
        prepareActions()
        if actionWindow == nil {
            let panel = NSPanel(contentViewController: NSHostingController(rootView: ActionPanelView(model: workbench.commands)))
            panel.styleMask = [.titled, .closable, .utilityWindow]; panel.isReleasedWhenClosed = false
            panel.level = .floating; panel.setContentSize(NSSize(width: 520, height: 490)); panel.center()
            actionWindow = panel
        }
        actionWindow?.title = ToolCopy(language: preferences.values.language)("Orbit 快捷動作", "Orbit Actions")
        actionWindow?.appearance = window?.appearance
        workbench.commands.query = ""; workbench.commands.selection = workbench.commands.filtered.first?.id
        NSApp.activate(ignoringOtherApps: true); actionWindow?.makeKeyAndOrderFront(nil)
        workbench.commands.focusRequest = UUID()
    }
    func prepareActions() {
        let c = ToolCopy(language: preferences.values.language); workbench.language(preferences.values.language)
        workbench.commands.actions = OrbitToolsNavigation.Page.allCases.filter { $0 != .actions }.map { page in
            OrbitAction(id: "page." + page.rawValue, title: page.title(c), detail: c("開啟工具", "Open tool"), symbol: page.symbol, perform: { [weak self] in self?.show(page: page) })
        } + workbench.modes.modes.map { mode in
            OrbitAction(id: "mode." + mode.id.uuidString, title: mode.name, detail: c("啟動情境", "Start mode"), symbol: mode.symbol, perform: { [weak self] in self?.show(page: .modes); self?.workbench.modes.apply(mode) })
        } + scenes.scenes.map { scene in
            OrbitAction(id: "audio." + scene.id.uuidString, title: scene.name, detail: c("套用音訊情境", "Apply audio scene"), symbol: "waveform", perform: { [weak self] in self?.show(page: .audio); self?.scenes.apply(scene) })
        } + workbench.quicklinks.links.map { link in
            // Resolved by id at perform time so the action always uses the
            // link's current state, not a stale copy.
            OrbitAction(id: "quicklink." + link.id.uuidString, title: link.title, detail: c("開啟連結", "Open link"), symbol: "link", perform: { [weak self] in
                guard let self else { return }
                self.show(page: .links)
                self.workbench.quicklinks.requestOpen(link.id)
            })
        } + workbench.snippets.snippets.map { snippet in
            // The keyword travels in the detail so the action search finds the
            // snippet by title or by keyword. The snippet itself is resolved
            // by id when the action runs.
            let detail = snippet.keyword.isEmpty ? c("開啟片段", "Open snippet") : snippet.keyword + " · " + c("開啟片段", "Open snippet")
            return OrbitAction(id: "snippet." + snippet.id.uuidString, title: snippet.title, detail: detail, symbol: "text.quote", perform: { [weak self] in
                guard let self else { return }
                self.show(page: .snippets)
                _ = self.workbench.snippets.select(snippet.id)
            })
        }
    }
    func stop() { workbench.stop(); timer.stop(); screenshots.stop(); actionWindow?.orderOut(nil) }
    func setAllowed(_ value: Bool) {
        allowed = value; workbench.commands.setAllowed(value); workbench.clipboard.setSuspended(!value); workbench.reminders.setSuspended(!value)
        if !value { window?.orderOut(nil); actionWindow?.orderOut(nil); workbench.modes.stop(); timer.reset(); screenshots.cancel(); workbench.pdf.stop(); workbench.qr.stop() }
    }
    private func syncWindow() {
        window?.title = OrbitStrings(language: preferences.values.language)("UTUVO Orbit 工具")
        let theme = preferences.values.theme
        window?.appearance = theme == .system ? nil : NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
    }
}

struct OrbitToolsView: View {
    @ObservedObject var preferences: OrbitPreferencesModel
    @ObservedObject var scenes: AudioScenesModel
    @ObservedObject var timer: OrbitTimerModel
    @ObservedObject var files: QuickFileToolsModel
    @ObservedObject var screenshots: ScreenshotToolsModel
    @ObservedObject var navigation: OrbitToolsNavigation
    let workbench: OrbitWorkbench
    var onOpenActions: () -> Void
    /// Opens the offline guide, the same content the Settings help page shows.
    var onOpenHelp: () -> Void = {}
    var preview = false
    var allowFileActionsInPreview = false
    @State private var renaming: AudioScene?
    @State private var renameDraft = ""
    private var l: OrbitStrings { OrbitStrings(language: preferences.values.language) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        Text(navigation.page.title(ToolCopy(language: preferences.values.language))).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: onOpenActions) { Label(ToolCopy(language: preferences.values.language)("搜尋動作", "Search actions"), systemImage: "magnifyingglass") }.keyboardShortcut("k", modifiers: .command).buttonStyle(.bordered)
                    }.padding(.horizontal, 28).padding(.vertical, 16)
                    Divider().opacity(0.5)
                    ScrollView {
                        Group {
                            switch navigation.page {
                            case .audio: audio
                            case .timer: timerView
                            case .files: QuickFileToolsView(model: files, language: preferences.values.language.rawValue, preview: preview && !allowFileActionsInPreview)
                            case .screenshots: ScreenshotToolsView(model: screenshots, language: preferences.values.language, preview: preview && !allowFileActionsInPreview)
                            case .modes: ContextModesView(model: workbench.modes, scenes: scenes, language: preferences.values.language, preview: preview && !allowFileActionsInPreview)
                            case .actions: CommandsToolsView(model: workbench.commands, language: preferences.values.language, onOpen: onOpenActions)
                            case .reminders: SmartRemindersView(model: workbench.reminders, language: preferences.values.language, preview: preview)
                            case .clipboard: ClipboardToolsView(model: workbench.clipboard, language: preferences.values.language, onSendToText: { text in workbench.text.input = text; navigation.page = .text })
                            case .text: TextToolsView(model: workbench.text, language: preferences.values.language, copyText: workbench.copyText, pasteText: workbench.pasteText, onSendToQR: { text in workbench.qr.text = text; workbench.qr.generate(); navigation.page = .qr })
                            case .pdf: PDFToolsView(model: workbench.pdf, language: preferences.values.language, preview: preview && !allowFileActionsInPreview)
                            case .colors: ColorToolsView(model: workbench.colors, language: preferences.values.language, preview: preview)
                            case .qr: QRToolsView(model: workbench.qr, language: preferences.values.language, preview: preview && !allowFileActionsInPreview)
                            case .calculator: CalculatorToolsView(model: workbench.calculator, language: preferences.values.language, copyText: workbench.copyText)
                            case .clocks: WorldClockToolsView(model: workbench.clocks, language: preferences.values.language, copyText: workbench.copyText)
                            case .notes: QuickNotesToolsView(model: workbench.notes, language: preferences.values.language, preview: preview && !allowFileActionsInPreview, copyText: workbench.copyText, onSendToText: { text in workbench.text.input = text; navigation.page = .text })
                                            case .links: QuickLinksToolsView(model: workbench.quicklinks, language: preferences.values.language,
                                                                               preview: preview && !allowFileActionsInPreview)
                            case .snippets: SnippetsToolsView(model: workbench.snippets, language: preferences.values.language,
                                                             preview: preview && !allowFileActionsInPreview,
                                                             onSendToText: { text in workbench.text.input = text; navigation.page = .text },
                                                             onSendToNotes: { title, text in workbench.notes.create(title: title, body: text); navigation.page = .notes })
                            case .integrity: FileIntegrityToolsView(model: workbench.integrity, language: preferences.values.language,
                                                                    preview: preview && !allowFileActionsInPreview,
                                                                    onSendToText: { text in workbench.text.input = text; navigation.page = .text })
                            }
                        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack {
                Label(l(preview ? "預覽資料" : "工具都在本機執行。"), systemImage: "circle.dotted")
                Spacer()
                Text(OrbitVersion.label).monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 14)
                .background(.primary.opacity(0.025))
        }
        .frame(width: 940, height: 750)
        .background(Color(nsColor: .windowBackgroundColor)).tint(OrbitPalette.accent)
        .preferredColorScheme(preferences.values.theme == .system ? nil : (preferences.values.theme == .dark ? .dark : .light))
        .environment(\.locale, Locale(identifier: l.identifier))
        .onAppear { updateLanguages() }
        .onChange(of: preferences.values.language) { _, _ in updateLanguages() }
        .onChange(of: navigation.page) { _, value in if value == .audio { scenes.refreshCatalog() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if navigation.page == .audio { scenes.refreshCatalog() }
        }
        .sheet(item: $renaming) { scene in
            VStack(alignment: .leading, spacing: 16) {
                Text(l("重新命名情境")).font(.headline)
                TextField(l("情境名稱"), text: $renameDraft).textFieldStyle(.roundedBorder)
                if let error = scenes.error { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button(l("取消")) { renaming = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(l("儲存")) { scenes.rename(scene, to: renameDraft); if scenes.error == nil { renaming = nil } }
                        .keyboardShortcut(.defaultAction).disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 360)
        }
    }

    private var sidebar: some View {
        let c = ToolCopy(language: preferences.values.language)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) { OrbitBrandMark(size: 32); VStack(alignment: .leading, spacing: 1) { Text("Orbit").font(.system(size: 20, weight: .semibold, design: .rounded)); Text(c("隨手工作台", "Your workbench")).font(.system(size: 10)).foregroundStyle(.secondary) } }.padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 24)
            ScrollView {
              VStack(alignment: .leading, spacing: 4) {
               ForEach(OrbitToolsNavigation.Page.allCases) { page in
                if page == .clipboard || page == .files { Divider().padding(.vertical, 8).padding(.horizontal, 10) }
                Button { navigation.page = page } label: {
                    HStack(spacing: 11) { Image(systemName: page.symbol).frame(width: 19); Text(page.title(c)).lineLimit(1).minimumScaleFactor(0.85); Spacer() }
                        .font(.system(size: 12, weight: navigation.page == page ? .semibold : .regular)).padding(.horizontal, 12).padding(.vertical, 9)
                        .foregroundStyle(navigation.page == page ? OrbitPalette.accent : Color.primary.opacity(0.75))
                        .background(navigation.page == page ? OrbitPalette.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).accessibilityAddTraits(navigation.page == page ? .isSelected : [])
               }
              }
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 12)
            Button { onOpenHelp() } label: {
                HStack(spacing: 11) { Image(systemName: "questionmark.circle").frame(width: 19); Text(c("使用說明", "Help")).lineLimit(1); Spacer() }
                    .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 9)
                    .foregroundStyle(Color.primary.opacity(0.75))
            }.buttonStyle(.plain).accessibilityLabel(c("開啟使用說明", "Open the guide"))
            Label(c("在你的 Mac 上完成", "Made local"), systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
        }.padding(.horizontal, 12).frame(width: 170).frame(maxHeight: .infinity).background(.primary.opacity(0.025))
    }

    private var audio: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(l("一鍵，回到熟悉的聲音。"), detail: l("先選好目前的輸入、輸出與音量，再儲存成情境。"))
            card {
                Picker(l("目前輸出"), selection: Binding(get: { scenes.catalog.currentOutput }, set: { scenes.selectOutput($0) })) {
                    if !scenes.catalog.outputs.contains(where: { $0.id == scenes.catalog.currentOutput }) {
                        Text("—").tag(scenes.catalog.currentOutput)
                    }
                    ForEach(scenes.catalog.outputs) { device in Text(device.name).tag(device.id) }
                }
                Picker(l("目前輸入"), selection: Binding(get: { scenes.catalog.currentInput }, set: { scenes.selectInput($0) })) {
                    if !scenes.catalog.inputs.contains(where: { $0.id == scenes.catalog.currentInput }) {
                        Text("—").tag(scenes.catalog.currentInput)
                    }
                    ForEach(scenes.catalog.inputs) { device in Text(device.name).tag(device.id) }
                }
                Divider()
                TextField(l("情境名稱，例如：工作室"), text: $scenes.name)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(l("情境名稱"))
                HStack {
                    Toggle(l("包含音量"), isOn: $scenes.includeVolume)
                    Spacer()
                    Picker(l("保持喚醒"), selection: $scenes.awakeMinutes) {
                        Text(l("不變更")).tag(0)
                        Text(l("30 分鐘")).tag(30)
                        Text(l("60 分鐘")).tag(60)
                        Text(l("120 分鐘")).tag(120)
                    }.frame(width: 230)
                }
                Button(l("儲存目前的音訊設定")) { scenes.saveCurrent() }.buttonStyle(.borderedProminent)
                    .disabled(scenes.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if scenes.scenes.isEmpty {
                Label(l("還沒有情境。把常用的裝置組合存下來，下次就能一鍵切換。"), systemImage: "waveform")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(scenes.scenes) { scene in
                    card {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform").foregroundStyle(OrbitPalette.accent).font(.system(size: 22))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(scene.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(scene.outputName + (scene.inputName.map { " · " + $0 } ?? ""))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                if let volume = scene.volume {
                                    Text(l("音量 %d%%", Int((volume * 100).rounded()))).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                if let minutes = scene.awakeMinutes {
                                    Text(l("保持喚醒") + " · " + l("%d 分鐘", minutes)).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(l("套用")) { scenes.apply(scene) }.buttonStyle(.bordered)
                                .tint(.primary)
                                .accessibilityLabel(l("套用情境 %@", scene.name))
                            Menu {
                                Button(l("重新命名")) { renameDraft = scene.name; renaming = scene }
                                Button(l("向上移")) { scenes.move(scene, by: -1) }.disabled(scenes.scenes.first?.id == scene.id)
                                Button(l("向下移")) { scenes.move(scene, by: 1) }.disabled(scenes.scenes.last?.id == scene.id)
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                                .accessibilityLabel(l("情境選項"))
                            Button(role: .destructive) { scenes.delete(scene) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).accessibilityLabel(l("刪除情境 %@", scene.name))
                        }
                    }
                }
            }
            if let message = scenes.applied { Label(message, systemImage: "checkmark.circle").foregroundStyle(OrbitPalette.accent) }
            if let error = scenes.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if scenes.needsStorageRecovery { Button(l("備份並重設情境")) { scenes.backupAndReset() } }
            Text(l("情境只在按下「套用」時生效；沒有連上的裝置會顯示錯誤。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }

    private var timerView: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(l("留一段時間，專心做事。"), detail: l("倒數會計入睡眠時間，也可以隨時暫停。"))
            Picker(l("計時模式"), selection: $timer.pomodoro) {
                Text(l("倒數")).tag(false)
                Text(l("番茄鐘 25／5")).tag(true)
            }.pickerStyle(.segmented).disabled(timer.countdown.phase == .running || timer.countdown.phase == .paused)
            card {
                VStack(spacing: 12) {
                    Text(timer.display).font(.system(size: 60, weight: .light, design: .rounded)).monospacedDigit()
                        .accessibilityLabel(l("剩餘時間 %@", timer.display))
                    Text(l(timerStatus)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    ProgressView(value: timer.countdown.total > 0 ? 1 - timer.countdown.remaining / timer.countdown.total : 0)
                    if timer.pomodoro {
                        Text(l("已完成 %d 次專注", timer.completedFocusSessions)).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                    HStack(spacing: 10) {
                        ForEach([5, 15, 25, 50], id: \.self) { minutes in
                            Button(l("%d 分鐘", minutes)) { timer.reset(); timer.minutes = minutes }
                                .buttonStyle(.bordered).tint(.primary)
                                .fontWeight(timer.minutes == minutes ? .semibold : .regular)
                        }
                    }.disabled(timer.countdown.phase == .running || timer.countdown.phase == .paused)
                    Stepper(l("自訂 %d 分鐘", timer.minutes), value: $timer.minutes, in: 1...120)
                        .frame(maxWidth: 240)
                        .disabled(timer.countdown.phase == .running || timer.countdown.phase == .paused)
                    }
                    HStack {
                        if timer.countdown.phase == .running {
                            Button(l("暫停")) { timer.pause() }.buttonStyle(.borderedProminent)
                        } else if timer.countdown.phase == .paused {
                            Button(l("繼續")) { timer.resume() }.buttonStyle(.borderedProminent)
                        } else {
                            Button(l(timer.pomodoro ? (timer.countdown.phase == .finished && timer.pomodoroStep == .focus ? "開始休息 5 分鐘" : "開始專注 25 分鐘") : "開始計時")) { timer.start() }.buttonStyle(.borderedProminent)
                        }
                        Button(l("重設")) { timer.reset() }.buttonStyle(.bordered)
                    }.controlSize(.large)
                }.frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            card {
                HStack {
                    Toggle(l("計時時保持喚醒"), isOn: $timer.keepAwake)
                    Spacer()
                    Toggle(l("完成時通知"), isOn: Binding(get: { timer.notify }, set: { timer.setNotify($0) })).disabled(preview)
                }
                Text(l("暫停或結束時，只解除計時器自己的喚醒。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = timer.error { Text(error).foregroundStyle(.orange) }
        }.font(.system(size: 12))
    }

    private var timerStatus: String {
        switch timer.countdown.phase {
        case .idle: "準備好就開始"
        case .paused: "已暫停"
        case .running: timer.pomodoro && timer.pomodoroStep == .rest ? "休息中" : "專注中"
        case .finished: timer.pomodoro && timer.pomodoroStep == .rest ? "休息完成，準備下一段專注。" : "計時完成，休息一下。"
        }
    }

    private func updateLanguages() { workbench.language(preferences.values.language); scenes.language = preferences.values.language; timer.language = preferences.values.language; files.language = preferences.values.language.rawValue; screenshots.language = preferences.values.language }
    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 21, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }
}
