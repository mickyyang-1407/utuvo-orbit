import Foundation
import Testing
import OrbitCore
@testable import UtuvoOrbit

@MainActor
private final class ModeOpenerProbe: ModeApplicationOpening {
    var resolves = 0
    var opens = 0
    var invalid = false
    func resolve(_ application: ModeApplication) throws -> URL {
        resolves += 1
        if invalid { throw CocoaError(.fileNoSuchFile) }
        return URL(fileURLWithPath: "/fixture/" + application.name + ".app")
    }
    func open(_ url: URL) async throws { opens += 1 }
}
@MainActor
private final class ReminderProbe: OrbitTimerNotifications {
    var requests = 0
    var delivered: [String] = []
    var pending: CheckedContinuation<Bool, any Error>?
    func request() async throws -> Bool { requests += 1; return try await withCheckedThrowingContinuation { pending = $0 } }
    func deliver(_ body: String) async throws -> Bool { delivered.append(body); return true }
}

@MainActor
struct ContextReminderTests {
    @Test func modesPersistWithoutAutoApplyingAndRespectTimerPreflight() async throws {
        let name = "orbit.context.tests.\(UUID())"; let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let routing = PreviewSceneRouting(), awake = FakeAwakeBackend(), timerAwake = FakeAwakeBackend(), opener = ModeOpenerProbe()
        let scenes = AudioScenesModel(defaults: nil, routing: routing, audio: AudioBackendImpl(driver: routing.driver), awake: FakeAwakeBackend())
        let timer = OrbitTimerModel(awake: timerAwake, enableTicker: false)
        let model = ContextModesModel(defaults: defaults, scenes: scenes, timer: timer, awake: awake, opener: opener)
        model.draft = ContextMode(name: "Focus", awakeMinutes: 30, timerMinutes: 25, applications: [ModeApplication(name: "Fixture", bookmark: Data([1]))]); model.save()
        let mode = try #require(model.modes.first)
        let restored = ContextModesModel(defaults: defaults, scenes: scenes, timer: timer, awake: awake, opener: opener)
        #expect(restored.modes == [mode] && timer.countdown.phase == .idle && opener.opens == 0 && !awake.current().isActive)
        timer.start(seconds: 90); model.apply(mode)
        #expect(model.failed && !model.busy && opener.resolves == 0 && !awake.current().isActive)
        timer.reset(); opener.invalid = true; model.apply(mode)
        #expect(model.failed && timer.countdown.phase == .idle && !awake.current().isActive)
        opener.invalid = false; model.apply(mode)
        for _ in 0..<200 where model.busy { await Task.yield() }
        #expect(!model.failed && !model.busy && opener.opens == 1 && timer.countdown.phase == .running && timer.minutes == 25)
        #expect(awake.current().isActive && !timerAwake.current().isActive)
        model.endAwake(); #expect(!awake.current().isActive && timer.countdown.phase == .running)
        model.stop(); restored.stop(); timer.stop()
    }
    @Test func missingAudioModeDoesNotStartTimerOrApps() {
        let routing = PreviewSceneRouting(), awake = FakeAwakeBackend(), opener = ModeOpenerProbe()
        let scenes = AudioScenesModel(defaults: nil, routing: routing, audio: AudioBackendImpl(driver: routing.driver), awake: FakeAwakeBackend())
        let timer = OrbitTimerModel(awake: FakeAwakeBackend(), enableTicker: false)
        let model = ContextModesModel(defaults: nil, scenes: scenes, timer: timer, awake: awake, opener: opener)
        model.apply(ContextMode(name: "Missing", audioSceneID: UUID(), awakeMinutes: 30, timerMinutes: 25))
        #expect(model.failed && timer.countdown.phase == .idle && opener.opens == 0 && !awake.current().isActive)
    }
    @Test func remindersAreEdgeTriggeredWithHysteresisAndUnknownValues() {
        var engine = ReminderEngine(); let settings = ReminderSettings(); let copy = ToolCopy(language: .english)
        var snapshot = StatusSnapshot.fixture("laptop"); snapshot.connection = .offline; snapshot.battery = nil
        #expect(engine.consume(snapshot, peripherals: [], settings: settings, copy: copy).isEmpty)
        snapshot.battery = BatteryReading(current: 19, maximum: 100, charging: false, onAC: false)
        #expect(engine.consume(snapshot, peripherals: [], settings: settings, copy: copy).count == 1)
        #expect(engine.consume(snapshot, peripherals: [], settings: settings, copy: copy).isEmpty)
        snapshot.battery = nil; #expect(engine.consume(snapshot, peripherals: [], settings: settings, copy: copy).isEmpty)
        snapshot.battery = BatteryReading(current: 21, maximum: 100, charging: false, onAC: false)
        _ = engine.consume(snapshot, peripherals: [], settings: settings, copy: copy)
        snapshot.battery = BatteryReading(current: 19, maximum: 100, charging: false, onAC: false)
        #expect(engine.consume(snapshot, peripherals: [], settings: settings, copy: copy).isEmpty)
        snapshot.battery = BatteryReading(current: 30, maximum: 100, charging: false, onAC: false); snapshot.connection = .wifi
        _ = engine.consume(snapshot, peripherals: [], settings: settings, copy: copy)
        snapshot.connection = .checking; _ = engine.consume(snapshot, peripherals: [], settings: settings, copy: copy)
        snapshot.connection = .offline; snapshot.battery = BatteryReading(current: 19, maximum: 100, charging: false, onAC: false)
        #expect(engine.consume(snapshot, peripherals: [], settings: settings, copy: copy).count == 2)
    }
    @Test func peripheralIdentityChargingAndDesktopRules() {
        var engine = ReminderEngine(); let c = ToolCopy(language: .english), settings = ReminderSettings()
        var snapshot = StatusSnapshot.fixture("charging"); snapshot.machine = .desktop
        snapshot.battery = BatteryReading(current: 100, maximum: 100, charging: false, onAC: true)
        let low = Peripheral(id: "headphones", name: "Headphones", kind: .airpods, fraction: 0.1, charging: .notCharging, source: "fixture")
        let unknown = Peripheral(id: "unknown", name: "Unknown", kind: .airpods, fraction: nil, charging: .unknown, source: "fixture")
        #expect(engine.consume(snapshot, peripherals: [low,unknown], settings: settings, copy: c).count == 1)
        #expect(engine.consume(snapshot, peripherals: [], settings: settings, copy: c).isEmpty)
        #expect(engine.consume(snapshot, peripherals: [low], settings: settings, copy: c).isEmpty)
        var charged = low; charged.charging = .charging
        #expect(engine.consume(snapshot, peripherals: [charged], settings: settings, copy: c).isEmpty)
        #expect(engine.consume(snapshot, peripherals: [low], settings: settings, copy: c).count == 1)
        snapshot.machine = .laptop
        #expect(engine.consume(snapshot, peripherals: [], settings: settings, copy: c).count == 1)
        #expect(engine.consume(snapshot, peripherals: [], settings: settings, copy: c).isEmpty)
    }
    @Test func notificationLateGrantCannotEnableRemindersAfterCancellation() async throws {
        let service = ReminderProbe(); let model = SmartRemindersModel(defaults: nil, notifications: service)
        #expect(!model.enabled && service.requests == 0)
        model.setEnabled(true)
        for _ in 0..<100 where service.pending == nil { await Task.yield() }
        let pending = try #require(service.pending); model.setEnabled(false); pending.resume(returning: true)
        for _ in 0..<100 { await Task.yield() }
        #expect(!model.enabled && !model.requesting)
        model.consume(StatusSnapshot.fixture("low"), peripherals: [])
        #expect(service.delivered.isEmpty && model.history.isEmpty)
    }
    @Test func concealedClipboardTypesNeverEnterHistory() {
        for type in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"] {
            #expect(!ClipboardEntry.canRecord(types: ["public.utf8-plain-text", type]))
        }
        #expect(ClipboardEntry.canRecord(types: ["public.utf8-plain-text"]))
    }
}
