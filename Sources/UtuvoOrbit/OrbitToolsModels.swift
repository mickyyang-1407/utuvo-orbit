import AppKit
import Combine
import OrbitCore
import UserNotifications

@MainActor
final class AudioScenesModel: ObservableObject {
    @Published private(set) var scenes: [AudioScene] = []
    @Published private(set) var error: String?
    @Published private(set) var applied: String?
    @Published private(set) var catalog: SceneAudioRoutes
    @Published private(set) var needsStorageRecovery = false
    @Published var name = ""
    @Published var includeVolume = true
    @Published var awakeMinutes = 0
    var language: AppLanguage = .system
    var onReadback: (() -> Void)?
    private let defaults: UserDefaults?
    private let applier: AudioSceneApplier
    private let awake: any AwakeBackend
    static let storageKey = "tools.audioScenes.v1"
    private var l: OrbitStrings { OrbitStrings(language: language) }

    init(defaults: UserDefaults?, routing: any AudioSceneRouting, audio: any AudioBackend, awake: any AwakeBackend) {
        self.defaults = defaults
        self.applier = AudioSceneApplier(routing: routing, audio: audio)
        self.awake = awake
        self.catalog = routing.routes()
        if let raw = defaults?.object(forKey: Self.storageKey) {
            do {
                guard let data = raw as? Data else { throw AudioSceneError.invalid }
                let decoded = try JSONDecoder().decode([AudioScene].self, from: data)
                var ids = Set<UUID>()
                scenes = decoded.filter { $0.isValid && ids.insert($0.id).inserted }
                if scenes.count != decoded.count { throw AudioSceneError.invalid }
            }
            catch { needsStorageRecovery = true; self.error = l("情境資料需要修復；原始資料已保留，請先備份並重設。") }
        }
    }

    /// Point-of-use catalog refresh, never a second audio polling loop.
    func refreshCatalog() { catalog = applier.routing.routes() }
    func selectOutput(_ id: UInt32) {
        do { _ = try applier.audio.selectDefaultOutput(deviceID: id); error = nil; applied = nil }
        catch { self.error = describe(error) }
        refreshCatalog(); onReadback?()
    }
    func selectInput(_ id: UInt32) {
        do { try applier.routing.selectInput(id); error = nil; applied = nil }
        catch { self.error = describe(error) }
        refreshCatalog(); onReadback?()
    }

    func saveCurrent() {
        do {
            let scene = try applier.capture(name: name, includeVolume: includeVolume, awakeMinutes: awakeMinutes == 0 ? nil : awakeMinutes)
            try persist(scenes + [scene])
            name = ""; error = nil; applied = nil
        } catch { self.error = describe(error) }
    }

    func delete(_ scene: AudioScene) {
        do { try persist(scenes.filter { $0.id != scene.id }); error = nil; applied = nil }
        catch { self.error = describe(error) }
    }

    func rename(_ scene: AudioScene, to name: String) {
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        var values = scenes; values[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard values[index].isValid else { throw AudioSceneError.invalid }
            try persist(values); error = nil; applied = nil
        } catch { self.error = describe(error) }
    }
    func move(_ scene: AudioScene, by offset: Int) {
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }), scenes.indices.contains(index + offset) else { return }
        var values = scenes; values.swapAt(index, index + offset)
        do { try persist(values); error = nil } catch { self.error = describe(error) }
    }
    func backupAndReset() {
        guard needsStorageRecovery else { return }
        if let raw = defaults?.object(forKey: Self.storageKey) {
            defaults?.set(raw, forKey: Self.storageKey + ".backup." + UUID().uuidString)
        }
        needsStorageRecovery = false
        do { try persist([]); error = nil; applied = l("已備份並重設情境資料。") }
        catch { needsStorageRecovery = true; self.error = describe(error) }
    }

    @discardableResult func apply(_ scene: AudioScene) -> Bool {
        applied = nil; error = nil
        do {
            try applier.apply(scene)
            if let minutes = scene.awakeMinutes {
                let duration: AwakeDuration = switch minutes { case 30: .thirty; case 60: .sixty; default: .oneTwenty }
                _ = try awake.start(duration: duration, now: Date())
            }
            applied = l("已套用 %@", scene.name)
        } catch {
            if let typed = error as? AudioSceneError, typed != .routeChanged {
                self.error = describe(error)
            } else {
                self.error = describe(error) + " " + l("若切換途中失敗，部分設定可能已變更，請查看目前裝置。")
            }
        }
        refreshCatalog()
        onReadback?()
        return error == nil
    }

    private func persist(_ values: [AudioScene]) throws {
        guard !needsStorageRecovery else { throw SceneStorageError.recoveryRequired }
        let data = try JSONEncoder().encode(values)
        defaults?.set(data, forKey: Self.storageKey)
        scenes = values
    }

    private func describe(_ error: any Error) -> String {
        switch error {
        case SceneStorageError.recoveryRequired: return l("情境資料需要修復；原始資料已保留，請先備份並重設。")
        case AudioSceneError.invalid: return l("請輸入名稱，並確認有可用的音訊輸出。")
        case AudioSceneError.missingOutput(let name): return l("找不到輸出裝置：%@", name)
        case AudioSceneError.missingInput(let name): return l("找不到輸入裝置：%@", name)
        case AudioSceneError.volumeUnsupported: return l("這個裝置目前不支援軟體音量，請重新儲存不含音量的情境。")
        case AudioSceneError.routeChanged, AudioError.staleDevice: return l("裝置已變更，請再試一次。")
        default: return l("無法完成音訊情境：%@", error.localizedDescription)
        }
    }
    private enum SceneStorageError: Error { case recoveryRequired }
}

@MainActor
protocol OrbitTimerNotifications: AnyObject {
    func request() async throws -> Bool
    func deliver(_ body: String) async throws -> Bool
}

@MainActor
final class SystemTimerNotifications: OrbitTimerNotifications {
    func request() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }
    func deliver(_ body: String) async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return false }
        let content = UNMutableNotificationContent(); content.title = "UTUVO Orbit"; content.body = body
        try await center.add(UNNotificationRequest(identifier: "orbit.timer.\(UUID())", content: content, trigger: nil))
        return true
    }
}

@MainActor
final class OrbitTimerModel: ObservableObject {
    enum PomodoroStep { case focus, rest }
    @Published private(set) var countdown = OrbitCountdown()
    @Published private(set) var error: String?
    @Published var minutes = 25 { didSet {
        if !(1...120).contains(minutes) { minutes = oldValue; return }
        defaults?.set(minutes, forKey: Self.minutesKey)
        if countdown.phase == .finished { reset() }
    } }
    @Published var pomodoro = false { didSet { reset(); defaults?.set(pomodoro, forKey: Self.pomodoroKey) } }
    @Published private(set) var pomodoroStep: PomodoroStep = .focus
    @Published private(set) var completedFocusSessions = 0
    @Published var keepAwake = false {
        didSet { defaults?.set(keepAwake, forKey: Self.awakeKey); if countdown.phase == .running { reconcileAwake() } }
    }
    @Published private(set) var notify = false { didSet { defaults?.set(notify, forKey: Self.notifyKey) } }
    var language: AppLanguage = .system
    var onFinished: (() -> Void)?
    /// A dedicated assertion controller, never the panel's manual controller.
    private let awake: any AwakeBackend
    private let now: () -> Double
    private let enableTicker: Bool
    private var ticker: Timer?
    private let defaults: UserDefaults?
    private let notifications: any OrbitTimerNotifications
    private var notificationGeneration = UUID()
    private var notificationRequest: Task<Void, Never>?
    private var notificationDelivery: Task<Void, Never>?
    static let minutesKey = "tools.timer.minutes"
    static let pomodoroKey = "tools.timer.pomodoro"
    static let awakeKey = "tools.timer.awake"
    static let notifyKey = "tools.timer.notify"
    private var l: OrbitStrings { OrbitStrings(language: language) }

    init(awake: any AwakeBackend, now: @escaping () -> Double = MonotonicClock.now, enableTicker: Bool = true,
         defaults: UserDefaults? = nil, notifications: (any OrbitTimerNotifications)? = nil) {
        self.awake = awake; self.now = now; self.enableTicker = enableTicker
        self.defaults = defaults; self.notifications = notifications ?? SystemTimerNotifications()
        let stored = defaults?.integer(forKey: Self.minutesKey) ?? 25
        minutes = (1...120).contains(stored) ? stored : 25
        pomodoro = defaults?.bool(forKey: Self.pomodoroKey) ?? false
        keepAwake = defaults?.bool(forKey: Self.awakeKey) ?? false
        notify = defaults?.bool(forKey: Self.notifyKey) ?? false
    }

    private func startTicker() {
        if enableTicker, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            ticker?.tolerance = 0.1
        }
    }

    var display: String {
        let seconds = countdown.phase == .idle ? (pomodoro ? 25 : minutes) * 60 : Int(ceil(countdown.remaining))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func start(seconds: Double? = nil) {
        var duration = seconds ?? Double(minutes) * 60
        if pomodoro, seconds == nil {
            if countdown.phase == .finished { pomodoroStep = pomodoroStep == .focus ? .rest : .focus }
            duration = pomodoroStep == .focus ? 1500 : 300
        }
        guard countdown.start(seconds: duration, now: now()) else { return }
        error = nil; reconcileAwake(); startTicker()
    }
    func tick() {
        if countdown.tick(now: now()) {
            if pomodoro, pomodoroStep == .focus { completedFocusSessions += 1 }
            ticker?.invalidate(); ticker = nil
            _ = awake.stop(); onFinished?()
            if notify {
                let body = l(pomodoro && pomodoroStep == .rest ? "休息完成，準備下一段專注。" : "計時完成，休息一下。")
                let generation = notificationGeneration
                notificationDelivery = Task { [weak self] in
                    guard let self, self.notify, self.notificationGeneration == generation else { return }
                    do {
                        let delivered = try await self.notifications.deliver(body)
                        guard !Task.isCancelled, self.notificationGeneration == generation else { return }
                        if !delivered { self.error = self.l("通知未允許；計時仍會正常運作。") }
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
            }
        }
    }
    func pause() {
        tick(); countdown.pause(now: now()); _ = awake.stop(); ticker?.invalidate(); ticker = nil
    }
    func resume() {
        countdown.resume(now: now())
        if countdown.phase == .running { reconcileAwake(); startTicker() }
    }
    func reset() {
        countdown.reset(); _ = awake.stop(); error = nil; ticker?.invalidate(); ticker = nil
        pomodoroStep = .focus; completedFocusSessions = 0
    }
    func stop() {
        reset(); notificationGeneration = UUID(); notificationRequest?.cancel(); notificationDelivery?.cancel()
    }
    func setNotify(_ enabled: Bool) {
        notificationGeneration = UUID(); notificationRequest?.cancel(); notificationDelivery?.cancel()
        notify = enabled
        guard enabled else { return }
        let generation = notificationGeneration
        notificationRequest = Task { [weak self] in
            guard let self else { return }
            do {
                let granted = try await self.notifications.request()
                guard !Task.isCancelled, self.notificationGeneration == generation else { return }
                self.notify = granted
                if !granted { self.error = self.l("通知未允許；計時仍會正常運作。") }
            } catch {
                guard !Task.isCancelled, self.notificationGeneration == generation else { return }
                self.notify = false; self.error = error.localizedDescription
            }
        }
    }
    private func reconcileAwake() {
        _ = awake.stop()
        guard keepAwake, countdown.phase == .running else { return }
        do { _ = try awake.start(duration: .custom(seconds: UInt32(max(1, ceil(countdown.remaining)))), now: Date()) }
        catch { self.error = l("計時已啟動，但無法保持喚醒。") }
    }
}

final class PreviewSceneRouting: AudioSceneRouting, @unchecked Sendable {
    let driver = FakeAudioHALDriver(snapshot: .init(defaultID: 1, devices: [
        1: .init(name: "Studio Speakers", hasSettableVolume: true, currentScalar: 0.4, currentMuted: false),
        2: .init(name: "Headphones", hasSettableVolume: true, currentScalar: 0.3, currentMuted: false)]))
    private var input: UInt32 = 3
    func routes() -> SceneAudioRoutes {
        SceneAudioRoutes(outputs: [.init(id: 1, uid: "fixture.speakers", name: "Studio Speakers"), .init(id: 2, uid: "fixture.headphones", name: "Headphones")],
                         inputs: [.init(id: 3, uid: "fixture.mic", name: "Studio Microphone")], currentOutput: driver.defaultOutputDeviceID(), currentInput: input)
    }
    func selectInput(_ id: UInt32) throws { input = id }
}
