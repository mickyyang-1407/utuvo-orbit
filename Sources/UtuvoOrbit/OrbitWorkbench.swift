import AppKit
import OrbitCore

@MainActor
final class PreviewToolNotifications: OrbitTimerNotifications {
    func request() async throws -> Bool { true }
    func deliver(_ body: String) async throws -> Bool { true }
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
    let copyText: (String) -> Void
    let pasteText: () -> String?
    private let access: any ClipboardAccess

    init(scenes: AudioScenesModel, timer: OrbitTimerModel, preview: Bool, defaults: UserDefaults?, language: AppLanguage) {
        let access: any ClipboardAccess = preview ? PreviewClipboardAccess() : SystemClipboardAccess()
        self.access = access
        let copyText: (String) -> Void = { text in access.write(ClipboardEntry(text: text)) }
        self.copyText = copyText; pasteText = { access.read()?.text }
        modes = ContextModesModel(defaults: defaults, scenes: scenes, timer: timer,
                                  awake: preview ? FakeAwakeBackend() : makeLiveAwakeBackend(),
                                  opener: preview ? PreviewModeApplicationOpening() : SystemModeApplicationOpening())
        let clipboardRoot = preview ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("UTUVO Orbit/Clipboard", isDirectory: true)
        clipboard = ClipboardToolsModel(defaults: defaults, access: access, enableTicker: !preview, root: clipboardRoot)
        reminders = SmartRemindersModel(defaults: defaults, notifications: preview ? PreviewToolNotifications() : SystemTimerNotifications())
        commands = ActionPanelModel(defaults: defaults, shortcut: preview ? PreviewActionShortcut() : SystemActionShortcut())
        colors = ColorToolsModel(defaults: defaults, copyText: copyText)
        qr = QRToolsModel(copyText: copyText)
        self.language(language)
        if preview {
            let c = ToolCopy(language: language)
            modes.draft = ContextMode(name: c("專心工作", "Deep work"), symbol: "moon", awakeMinutes: 30, timerMinutes: 25); modes.save()
            modes.draft = ContextMode(name: c("開會", "Meeting"), symbol: "video", awakeMinutes: 60); modes.save()
            clipboard.admit(ClipboardEntry(text: "https://utuvo.app", pinned: true))
            clipboard.admit(ClipboardEntry(text: "A little less friction. A little more focus."))
            colors.save(); colors.input = "#E9B872"; colors.save(); colors.input = "#2C394B"; colors.save(); colors.input = "#27A89A"
            qr.generate()
        }
    }
    func language(_ value: AppLanguage) { modes.language = value; reminders.language = value; commands.language = value; qr.language = value }
    func stop() { modes.stop(); clipboard.stop(); reminders.stop(); commands.stop(); pdf.stop(); colors.stop(); qr.stop() }
}
