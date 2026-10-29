import Foundation
import Testing
import OrbitCore
import ClotheslineKit
@testable import UtuvoOrbit

@MainActor
private final class PendingNotifications: OrbitTimerNotifications {
    var requests = 0
    var delivered: [String] = []
    var pending: CheckedContinuation<Bool, any Error>?
    func request() async throws -> Bool {
        requests += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func deliver(_ body: String) async throws -> Bool { delivered.append(body); return true }
}

@MainActor
struct ToolsAlignmentTests {
    @Test func notificationLateGrantCannotReenableCancelledPreference() async throws {
        let service = PendingNotifications()
        let model = OrbitTimerModel(awake: FakeAwakeBackend(), enableTicker: false, notifications: service)
        #expect(service.requests == 0)
        model.setNotify(true)
        for _ in 0..<50 where service.pending == nil { await Task.yield() }
        #expect(service.requests == 1 && model.notify)
        model.setNotify(false)
        let pending = try #require(service.pending); service.pending = nil; pending.resume(returning: true)
        for _ in 0..<50 { await Task.yield() }
        #expect(!model.notify)
        #expect(service.delivered.isEmpty)
        model.stop()
    }

    @Test func timerPreferencesRestoreWithoutStartingOrRequestingPermission() throws {
        let name = "orbit.alignment.timer.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let service = PendingNotifications(), awake = FakeAwakeBackend()
        let first = OrbitTimerModel(awake: awake, enableTicker: false, defaults: defaults, notifications: service)
        first.minutes = 37; first.keepAwake = true; first.pomodoro = true
        defaults.set(true, forKey: OrbitTimerModel.notifyKey)
        let second = OrbitTimerModel(awake: awake, enableTicker: false, defaults: defaults, notifications: service)
        #expect(second.minutes == 37 && second.pomodoro && second.keepAwake && second.notify)
        #expect(second.countdown.phase == .idle && second.display == "25:00")
        #expect(!awake.current().isActive && service.requests == 0)
        second.pomodoro = false
        #expect(second.display == "37:00")
        second.minutes = Int.max
        #expect(second.minutes == 37 && second.display == "37:00")
        first.stop(); second.stop()
    }

    @Test func renameReorderAndCorruptStorageBackupPreserveSourceData() throws {
        let name = "orbit.alignment.scene.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let router = PreviewSceneRouting(), audio = AudioBackendImpl(driver: router.driver), awake = FakeAwakeBackend()
        let model = AudioScenesModel(defaults: defaults, routing: router, audio: audio, awake: awake)
        model.name = "One"; model.saveCurrent(); model.name = "Two"; model.saveCurrent()
        let second = try #require(model.scenes.last)
        model.rename(second, to: "  Meeting  "); model.move(second, by: -1)
        #expect(model.scenes.first?.name == "Meeting")
        let restored = AudioScenesModel(defaults: defaults, routing: router, audio: audio, awake: awake)
        #expect(restored.scenes.first?.name == "Meeting")
        let invalid = Data("damaged scenes".utf8); defaults.set(invalid, forKey: AudioScenesModel.storageKey)
        let damaged = AudioScenesModel(defaults: defaults, routing: router, audio: audio, awake: awake)
        damaged.name = "Attempt"; damaged.saveCurrent()
        #expect(damaged.needsStorageRecovery && defaults.data(forKey: AudioScenesModel.storageKey) == invalid)
        damaged.backupAndReset()
        #expect(!damaged.needsStorageRecovery && damaged.scenes.isEmpty)
        let backup = defaults.dictionaryRepresentation().first { $0.key.hasPrefix(AudioScenesModel.storageKey + ".backup.") }
        #expect(backup?.value as? Data == invalid)
        #expect(router.driver.defaultOutputDeviceID() == 1 && !awake.current().isActive)
    }
}
