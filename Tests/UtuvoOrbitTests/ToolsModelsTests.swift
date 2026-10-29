import Foundation
import Testing
import OrbitCore
@testable import UtuvoOrbit

@MainActor
struct ToolsModelsTests {
    @Test func pomodoroAlternatesFocusAndRestOnlyAfterExplicitStart() {
        var clock = 0.0
        let timer = OrbitTimerModel(awake: FakeAwakeBackend(), now: { clock }, enableTicker: false)
        timer.pomodoro = true; timer.start()
        #expect(timer.countdown.total == 1500)
        clock = 1500; timer.tick()
        #expect(timer.completedFocusSessions == 1)
        #expect(timer.countdown.phase == .finished)
        timer.start()
        #expect(timer.pomodoroStep == .rest)
        #expect(timer.countdown.total == 300)
        clock = 1800; timer.tick(); timer.start()
        #expect(timer.pomodoroStep == .focus)
        #expect(timer.countdown.total == 1500)
        #expect(timer.completedFocusSessions == 1)
    }
    @Test func timerPauseResumeAndCompletionLeaveManualAwakeAlone() throws {
        let manual = FakeAwakeBackend(), owned = FakeAwakeBackend()
        _ = try manual.start(duration: .sixty, now: Date())
        var clock = 100.0, completions = 0
        let model = OrbitTimerModel(awake: owned, now: { clock }, enableTicker: false)
        model.onFinished = { completions += 1 }
        model.keepAwake = true; model.start(seconds: 10)
        #expect(owned.current().isActive)
        clock = 103; model.pause()
        #expect(model.countdown.remaining == 7)
        #expect(!owned.current().isActive)
        #expect(manual.current().isActive)
        clock = 200; model.resume()
        #expect(owned.current().chosenDuration == .custom(seconds: 7))
        clock = 500; model.tick(); model.tick()
        #expect(completions == 1)
        #expect(!owned.current().isActive)
        #expect(manual.current().isActive)
        #expect(!model.notify)
    }

    @Test func scenesPersistWithoutApplyingAndCanBeDeleted() throws {
        let name = "orbit.tools.tests.\(UUID())", router = PreviewSceneRouting()
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let audio = AudioBackendImpl(driver: router.driver), awake = FakeAwakeBackend()
        let model = AudioScenesModel(defaults: defaults, routing: router, audio: audio, awake: awake)
        model.name = "Studio"; model.awakeMinutes = 60; model.saveCurrent()
        #expect(model.scenes.count == 1)
        #expect(!awake.current().isActive)
        router.driver.changeDefault(to: 2)
        let reopened = AudioScenesModel(defaults: defaults, routing: router, audio: audio, awake: awake)
        #expect(router.driver.defaultOutputDeviceID() == 2)
        #expect(reopened.scenes.count == 1)
        let scene = try #require(reopened.scenes.first)
        reopened.apply(scene)
        #expect(router.driver.defaultOutputDeviceID() == 1)
        #expect(awake.current().isActive)
        #expect(reopened.applied != nil)
        reopened.delete(scene)
        #expect(AudioScenesModel(defaults: defaults, routing: router, audio: audio, awake: awake).scenes.isEmpty)
        var invalid = scene; invalid.volume = 1e300
        defaults.set(try JSONEncoder().encode([invalid]), forKey: AudioScenesModel.storageKey)
        let damaged = AudioScenesModel(defaults: defaults, routing: router, audio: audio, awake: awake)
        #expect(damaged.scenes.isEmpty)
        #expect(damaged.error != nil)
    }
}
