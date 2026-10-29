import Foundation
import Testing
@testable import OrbitCore

struct ToolsCoreTests {
    @Test func countdownUsesElapsedTimePausesAndCompletesOnce() {
        var timer = OrbitCountdown()
        let invalid = timer.start(seconds: .nan, now: 1); #expect(!invalid)
        let tooLong = timer.start(seconds: 7201, now: 1); #expect(!tooLong)
        let started = timer.start(seconds: 1500, now: 10); #expect(started)
        let early = timer.tick(now: 110); #expect(!early)
        #expect(timer.remaining == 1400)
        timer.pause(now: 210)
        #expect(timer.phase == .paused)
        let paused = timer.tick(now: 9999); #expect(!paused)
        #expect(timer.remaining == 1300)
        timer.resume(now: 10000)
        let completed = timer.tick(now: 12000); #expect(completed) // includes sleep / delayed callbacks
        #expect(timer.phase == .finished)
        let repeated = timer.tick(now: 12001); #expect(!repeated)
        timer.reset(); #expect(timer.phase == .idle)
    }

    @Test func customAwakeUsesExactSecondsAndRejectsInvalidWithoutReplacing() throws {
        let driver = FakeAwakeAssertionDriver(), scheduler = ManualAwakeScheduler()
        let controller = AwakeController(driver: driver, scheduler: scheduler)
        let date = Date(timeIntervalSince1970: 100)
        let state = try controller.start(duration: .custom(seconds: 7), now: date)
        #expect(state.deadline == date.addingTimeInterval(7))
        #expect(driver.createCalls.last?.3 == 7)
        #expect(throws: AwakeError.self) { _ = try controller.start(duration: .custom(seconds: UInt32.max), now: date) }
        #expect(controller.current().isActive)
        #expect(driver.createCalls.count == 1)
    }

    @Test func sceneCaptureDoesNotChangeHardwareAndUIDResolvesReconnectedID() throws {
        let router = TestSceneRouter()
        let applier = AudioSceneApplier(routing: router, audio: AudioBackendImpl(driver: router.driver))
        let scene = try applier.capture(name: "Studio", includeVolume: true, awakeMinutes: nil)
        #expect(scene.outputUID == "speakers")
        #expect(router.driver.defaultOutputDeviceID() == 1)
        #expect(router.inputWrites == 0)
        router.driver.addDevice(id: 91, name: "New device ID", hasSettableVolume: true, currentScalar: 0.2, currentMuted: false)
        router.outputs[0] = SceneAudioDevice(id: 91, uid: "speakers", name: "Same hardware")
        router.driver.changeDefault(to: 2)
        try applier.apply(scene)
        #expect(router.driver.defaultOutputDeviceID() == 91)
        #expect(router.driver.masterScalar(91) == 0.5)
    }

    @Test(arguments: [true, false])
    func missingOrAmbiguousDevicePreflightsBeforeAnyWrite(inputMissing: Bool) throws {
        let router = TestSceneRouter()
        let applier = AudioSceneApplier(routing: router, audio: AudioBackendImpl(driver: router.driver))
        var scene = try applier.capture(name: "Meeting", includeVolume: true, awakeMinutes: nil)
        router.driver.changeDefault(to: 2)
        if inputMissing { scene.inputUID = "gone" } else { router.outputs.append(router.outputs[0]) }
        #expect(throws: AudioSceneError.self) { try applier.apply(scene) }
        #expect(router.driver.defaultOutputDeviceID() == 2)
        #expect(router.inputWrites == 0)
    }

    @Test func staleUIDAndOutputWriteFailuresAreNotSuccess() throws {
        let router = TestSceneRouter()
        let applier = AudioSceneApplier(routing: router, audio: AudioBackendImpl(driver: router.driver))
        let scene = try applier.capture(name: "Studio", includeVolume: true, awakeMinutes: nil)
        router.driver.changeDefault(to: 2)
        router.driver.scriptNextWriteFailure(-123)
        #expect(throws: AudioError.self) { try applier.apply(scene) }
        #expect(router.driver.defaultOutputDeviceID() == 2)
        router.replaceUIDAfterNextRead = true
        #expect(throws: AudioSceneError.self) { try applier.apply(scene) }
        #expect(router.driver.masterScalar(1) == 0.5)
    }
}

final class TestSceneRouter: AudioSceneRouting, @unchecked Sendable {
    let driver = FakeAudioHALDriver(snapshot: .init(defaultID: 1, devices: [
        1: .init(name: "Speakers", hasSettableVolume: true, currentScalar: 0.5, currentMuted: false),
        2: .init(name: "Headphones", hasSettableVolume: true, currentScalar: 0.3, currentMuted: false)]))
    var outputs = [SceneAudioDevice(id: 1, uid: "speakers", name: "Speakers"), SceneAudioDevice(id: 2, uid: "headphones", name: "Headphones")]
    var inputWrites = 0
    var replaceUIDAfterNextRead = false
    func routes() -> SceneAudioRoutes {
        let snapshot = SceneAudioRoutes(outputs: outputs, inputs: [.init(id: 3, uid: "mic", name: "Microphone")], currentOutput: driver.defaultOutputDeviceID(), currentInput: 3)
        if replaceUIDAfterNextRead {
            replaceUIDAfterNextRead = false
            outputs[0] = .init(id: 1, uid: "replacement", name: "Unrelated hardware")
        }
        return snapshot
    }
    func selectInput(_ id: UInt32) throws { inputWrites += 1 }
}
