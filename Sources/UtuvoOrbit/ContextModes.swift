import AppKit
import Combine
import OrbitCore

struct ModeApplication: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var bookmark: Data
}
struct ContextMode: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol = "sparkles"
    var audioSceneID: UUID?
    var awakeMinutes = 0
    var timerMinutes = 0
    var applications: [ModeApplication] = []
    var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 60 && [0,30,60,120].contains(awakeMinutes) && (0...120).contains(timerMinutes) && applications.count <= 8 && applications.allSatisfy { !$0.bookmark.isEmpty && $0.bookmark.count <= 64_000 } }
}

@MainActor
protocol ModeApplicationOpening: AnyObject {
    func resolve(_ application: ModeApplication) throws -> URL
    func open(_ url: URL) async throws
}
@MainActor
final class SystemModeApplicationOpening: ModeApplicationOpening {
    func resolve(_ application: ModeApplication) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: application.bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard !stale, url.pathExtension.lowercased() == "app", Bundle(url: url)?.bundleIdentifier != nil else {
            throw WorkbenchError.invalid("Reselect application / 請重新選擇 App：" + application.name)
        }; return url
    }
    func open(_ url: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
@MainActor
final class PreviewModeApplicationOpening: ModeApplicationOpening {
    var opened: [URL] = []
    func resolve(_ application: ModeApplication) throws -> URL { URL(fileURLWithPath: "/fixture/" + application.name + ".app") }
    func open(_ url: URL) async throws { opened.append(url) }
}

@MainActor
final class ContextModesModel: ObservableObject {
    @Published private(set) var modes: [ContextMode]
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var failed = false
    @Published var draft = ContextMode(name: "")
    var language: AppLanguage = .system
    private let storage: ToolStorage<[ContextMode]>
    private let scenes: AudioScenesModel
    private let timer: OrbitTimerModel
    private let awake: any AwakeBackend
    private let opener: any ModeApplicationOpening
    private var job: Task<Void, Never>?
    private var token = UUID()
    var needsRecovery: Bool { storage.damaged }
    init(defaults: UserDefaults?, scenes: AudioScenesModel, timer: OrbitTimerModel, awake: any AwakeBackend, opener: any ModeApplicationOpening) {
        self.scenes = scenes; self.timer = timer; self.awake = awake; self.opener = opener
        storage = ToolStorage(defaults, "tools.contextModes.v1")
        modes = storage.load(fallback: [], validate: { items in items.count <= 24 && items.allSatisfy(\.valid) && Set(items.map(\.id)).count == items.count })
    }
    func save() {
        var value = draft; value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.valid else { show("Name or settings invalid / 名稱或設定不完整", failed: true); return }
        var values = modes
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
        else { guard values.count < 24 else { show("Limit: 24 modes / 最多 24 個情境", failed: true); return }; values.append(value) }
        do { try storage.save(values); modes = values; draft = ContextMode(name: ""); show(ToolCopy(language: language)("情境已儲存", "Mode saved")) }
        catch { show(error.localizedDescription, failed: true) }
    }
    func edit(_ mode: ContextMode) { draft = mode }
    func remove(_ mode: ContextMode) {
        guard !busy else { return }
        do { let values = modes.filter { $0.id != mode.id }; try storage.save(values); modes = values } catch { show(error.localizedDescription, failed: true) }
    }
    func addApplications() {
        let urls = ToolFiles.choose([.applicationBundle])
        do {
            var values = draft.applications
            for url in urls {
                guard values.count < 8, Bundle(url: url)?.bundleIdentifier != nil else { throw WorkbenchError.invalid("Limit: 8 valid Apps / 最多 8 個有效 App") }
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                if !values.contains(where: { $0.name == url.deletingPathExtension().lastPathComponent && $0.bookmark == bookmark }) {
                    values.append(ModeApplication(name: url.deletingPathExtension().lastPathComponent, bookmark: bookmark))
                }
            }
            draft.applications = values
        } catch { show(error.localizedDescription, failed: true) }
    }
    func apply(_ mode: ContextMode) {
        guard !busy, mode.valid else { return }
        // Resolve every dependency before the first side effect.
        let audioScene: AudioScene?
        let urls: [URL]
        do {
            if mode.timerMinutes > 0, timer.countdown.phase == .running || timer.countdown.phase == .paused {
                throw WorkbenchError.invalid(ToolCopy(language: language)("請先結束目前的計時器，再套用含計時的情境。", "Finish the current timer before applying a timed mode."))
            }
            if let id = mode.audioSceneID {
                guard let scene = scenes.scenes.first(where: { $0.id == id }) else { throw WorkbenchError.invalid("Audio scene missing / 音訊情境已移除") }
                audioScene = scene
            } else { audioScene = nil }
            urls = try mode.applications.map { try opener.resolve($0) }
        } catch { show(error.localizedDescription, failed: true); return }
        busy = true; let current = UUID(); token = current
        job = Task { [weak self] in
            guard let self else { return }
            defer { if token == current { busy = false } }
            do {
                if let audioScene { guard scenes.apply(audioScene) else { throw WorkbenchError.invalid(scenes.error ?? "Audio failed") } }
                try Task.checkCancellation()
                if mode.awakeMinutes > 0 {
                    _ = try awake.start(duration: .custom(seconds: UInt32(mode.awakeMinutes * 60)), now: Date())
                }
                if mode.timerMinutes > 0 { timer.reset(); timer.pomodoro = false; timer.minutes = mode.timerMinutes; timer.start() }
                for url in urls { try Task.checkCancellation(); try await opener.open(url) }
                guard token == current else { return }
                show(ToolCopy(language: language)("已套用：", "Applied: ") + mode.name)
            } catch {
                guard token == current else { return }
                show(error.localizedDescription + ToolCopy(language: language)("；先前成功的步驟可能已生效。", "; earlier successful steps may already be active."), failed: true)
            }
        }
    }
    func endAwake() { _ = awake.stop(); show(ToolCopy(language: language)("已解除情境的喚醒", "Mode keep-awake ended")) }
    func recover() {
        do { try storage.backupAndReset([]); modes = []; show(ToolCopy(language: language)("已備份並重設", "Backed up and reset")) } catch { show(error.localizedDescription, failed: true) }
    }
    func stop() { token = UUID(); job?.cancel(); busy = false; _ = awake.stop() }
    private func show(_ text: String, failed: Bool = false) { message = text; self.failed = failed }
}
