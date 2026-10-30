import AppKit
import OrbitCore

@MainActor
final class PreviewToolNotifications: OrbitTimerNotifications {
    func request() async throws -> Bool { true }
    func deliver(_ body: String) async throws -> Bool { true }
}

/// Narrow constructor seams for an isolated, persistent tools session.
/// Production callers leave this nil and keep the existing live defaults.
@MainActor
struct OrbitWorkbenchOverrides {
    var storageRoot: URL?
    var clipboard: (any ClipboardAccess)?
    var awake: (any AwakeBackend)?
    var modeApplicationOpening: (any ModeApplicationOpening)?
    var notifications: (any OrbitTimerNotifications)?
    var actionShortcut: (any ActionShortcut)?
    var quickLinkOpening: (any QuickLinkOpening)?
    var copyText: ((String) -> Void)?
}

@MainActor
final class OrbitWorkbench {
    let modes: ContextModesModel
    let clipboard: ClipboardToolsModel
    let reminders: SmartRemindersModel
    let commands: ActionPanelModel
    let pdf = PDFToolsModel()
    let text = TextToolsModel()
    let colors: ColorToolsModel
    let qr: QRToolsModel
    let calculator: CalculatorToolsModel
    let clocks: WorldClockModel
    let notes: QuickNotesModel
    let quicklinks: QuickLinksModel
    let snippets: SnippetsModel
    let integrity: FileIntegrityModel
    let copyText: (String) -> Void
    let pasteText: () -> String?
    private let access: any ClipboardAccess

    init(scenes: AudioScenesModel, timer: OrbitTimerModel, preview: Bool, allowFileActionsInPreview: Bool = false,
         defaults: UserDefaults?, language: AppLanguage, overrides: OrbitWorkbenchOverrides? = nil) {
        let access: any ClipboardAccess = overrides?.clipboard ?? (preview ? PreviewClipboardAccess() : SystemClipboardAccess())
        self.access = access
        let copyText: (String) -> Void = overrides?.copyText ?? { text in access.write(ClipboardEntry(text: text)) }
        self.copyText = copyText; pasteText = { access.read()?.text }
        modes = ContextModesModel(defaults: defaults, scenes: scenes, timer: timer,
                                  awake: overrides?.awake ?? (preview ? FakeAwakeBackend() : makeLiveAwakeBackend()),
                                  opener: overrides?.modeApplicationOpening ?? (preview ? PreviewModeApplicationOpening() : SystemModeApplicationOpening()))
        let clipboardRoot = overrides?.storageRoot?.appendingPathComponent("Clipboard", isDirectory: true)
            ?? (preview ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("UTUVO Orbit/Clipboard", isDirectory: true))
        clipboard = ClipboardToolsModel(defaults: defaults, access: access, enableTicker: !preview, root: clipboardRoot)
        reminders = SmartRemindersModel(defaults: defaults, notifications: overrides?.notifications ?? (preview ? PreviewToolNotifications() : SystemTimerNotifications()))
        commands = ActionPanelModel(defaults: defaults, shortcut: overrides?.actionShortcut ?? (preview ? PreviewActionShortcut() : SystemActionShortcut()))
        colors = ColorToolsModel(defaults: defaults, copyText: copyText)
        qr = QRToolsModel(copyText: copyText)
        calculator = CalculatorToolsModel(defaults: preview ? nil : (defaults ?? .standard))
        clocks = WorldClockModel(defaults: preview ? nil : (defaults ?? .standard))
        notes = QuickNotesModel(root: overrides?.storageRoot?.appendingPathComponent("Notes", isDirectory: true), preview: preview)
        quicklinks = QuickLinksModel(root: overrides?.storageRoot?.appendingPathComponent("Quicklinks", isDirectory: true), preview: preview,
                                     opener: overrides?.quickLinkOpening)
        snippets = SnippetsModel(root: overrides?.storageRoot?.appendingPathComponent("Snippets", isDirectory: true),
                                 preview: preview, copyText: copyText)
        // Only the file integrity tool may read a file in the preview, and
        // only when the caller explicitly opted in. Every other tool keeps
        // its preview fakes.
        integrity = FileIntegrityModel(preview: preview && !allowFileActionsInPreview, copyText: copyText)
        self.language(language)
        if preview {
            let c = ToolCopy(language: language)
            modes.draft = ContextMode(name: c("專心工作", "Deep work"), symbol: "moon", awakeMinutes: 30, timerMinutes: 25); modes.save()
            modes.draft = ContextMode(name: c("開會", "Meeting"), symbol: "video", awakeMinutes: 60); modes.save()
            clipboard.admit(ClipboardEntry(text: "https://utuvo.app", pinned: true))
            clipboard.admit(ClipboardEntry(text: "A little less friction. A little more focus."))
            colors.save(); colors.input = "#E9B872"; colors.save(); colors.input = "#2C394B"; colors.save(); colors.input = "#27A89A"
            qr.generate()
            calculator.input = "(240 + 36) / 3"; calculator.calculate()
            notes.create(title: c("下一個小點子", "The next small idea"), body: c("把想法先留下來，回頭再整理。\n\n- 錄音前確認清單\n- 寫下今天最重要的一件事", "Catch the idea now. Make room for it later.\n\n- Check the recording setup\n- Pick one thing that matters today"))
            quicklinks.add(title: c("UTUVO", "UTUVO"), template: "https://utuvo.app")
            quicklinks.add(title: c("搜尋教學", "Search tutorials"), template: "https://www.google.com/search?q={query}")
            snippets.create(title: c("會議紀錄", "Meeting notes"),
                            body: c("{{date}} 會議\n與 {{name}} 討論\n", "{{date}} meeting\nWith {{name}}\n"), keyword: "meeting")
        }
    }
    func language(_ value: AppLanguage) { modes.language = value; reminders.language = value; commands.language = value; qr.language = value }
    func stop() { modes.stop(); clipboard.stop(); reminders.stop(); commands.stop(); pdf.stop(); colors.stop(); qr.stop(); notes.stop(); snippets.stop(); integrity.stop() }
}
