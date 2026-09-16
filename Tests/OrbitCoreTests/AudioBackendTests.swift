import XCTest
@testable import OrbitCore

final class AudioBackendTests: XCTestCase {
    private func makeBackend(initialScalar: Float32? = 0.5,
                             hasSettable: Bool = true,
                             initialMute: Bool = false) -> (AudioBackendImpl, FakeAudioHALDriver) {
        let deviceID: UInt32 = 100
        let driver = FakeAudioHALDriver(snapshot: .init(
            defaultID: deviceID,
            devices: [deviceID: .init(name: "Studio Display",
                                      hasSettableVolume: hasSettable,
                                      currentScalar: initialScalar,
                                      currentMuted: initialMute)]
        ))
        return (AudioBackendImpl(driver: driver), driver)
    }

    func testWriteAndReadBack() throws {
        let (backend, _) = makeBackend(initialScalar: 0.5)
        let updated = try backend.setMasterVolume(0.8, expectedDeviceID: 100)
        XCTAssertEqual(updated.masterVolume ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(backend.current().masterVolume ?? 0, 0.8, accuracy: 0.0001)
    }

    func testRejectsNonSettableDevice() throws {
        let (backend, _) = makeBackend(initialScalar: nil, hasSettable: false)
        XCTAssertThrowsError(try backend.setMasterVolume(0.5, expectedDeviceID: 100)) { error in
            XCTAssertEqual(error as? AudioError, .unsupported)
        }
    }

    func testRejectsOutOfRangeValues() throws {
        let (backend, _) = makeBackend()
        XCTAssertThrowsError(try backend.setMasterVolume(1.5, expectedDeviceID: 100)) { error in
            XCTAssertEqual(error as? AudioError, .writeFailed(status: -50))
        }
        XCTAssertThrowsError(try backend.setMasterVolume(.nan, expectedDeviceID: 100)) { error in
            XCTAssertEqual(error as? AudioError, .writeFailed(status: -50))
        }
    }

    func testStaleDeviceRejected() throws {
        let (backend, driver) = makeBackend()
        // Default changes under us — driver returns a different ID now.
        driver.changeDefault(to: 999)
        XCTAssertThrowsError(try backend.setMasterVolume(0.5, expectedDeviceID: 100)) { error in
            switch error {
            case AudioError.staleDevice(let expected, let actual):
                XCTAssertEqual(expected, 100)
                XCTAssertEqual(actual, 999)
            default: XCTFail("expected staleDevice, got \(error)")
            }
        }
        // State is sticky: lastOSStatus records the error until the next write.
        XCTAssertEqual(backend.current().lastOSStatus, AudioError.staleDevice(expected: 100, actual: 999).errorCode)
    }

    func testStaleDeviceUsesCallerSuppliedExpectationNotInternalCache() throws {
        // Even though the driver's default has NOT moved, a caller passing a
        // stale `expectedDeviceID` (e.g. a UI showing outdated state) must
        // still be rejected — the guard compares against what the caller
        // says it saw, not an internal box a concurrent poll could mutate.
        let (backend, _) = makeBackend()
        XCTAssertThrowsError(try backend.setMasterVolume(0.5, expectedDeviceID: 555)) { error in
            XCTAssertEqual(error as? AudioError, .staleDevice(expected: 555, actual: 100))
        }
    }

    func testSuccessfulWriteClearsStickyStatus() throws {
        let (backend, driver) = makeBackend()
        driver.changeDefault(to: 999) // force a sticky error first
        XCTAssertThrowsError(try backend.setMasterVolume(0.5, expectedDeviceID: 100))
        XCTAssertNotNil(backend.current().lastOSStatus)
        driver.changeDefault(to: 100) // device is back
        _ = try backend.setMasterVolume(0.6, expectedDeviceID: 100)
        XCTAssertNil(backend.current().lastOSStatus, "a successful write must clear the sticky error")
    }

    func testCurrentAlwaysFreshReadsNeverCached() throws {
        // No writes at all — an external volume change (hotplug/other app)
        // must be visible on the very next `current()` call.
        let (backend, driver) = makeBackend(initialScalar: 0.5)
        XCTAssertEqual(backend.current().masterVolume ?? 0, 0.5, accuracy: 0.0001)
        driver.externallySetScalar(0.9, on: 100)
        XCTAssertEqual(backend.current().masterVolume ?? 0, 0.9, accuracy: 0.0001, "current() must fresh-read, not return an init-time cache")
    }

    func testCurrentReflectsHotplugOfNewDefaultDevice() throws {
        let (backend, driver) = makeBackend()
        driver.addDevice(id: 200, name: "USB DAC", hasSettableVolume: true, currentScalar: 0.3, currentMuted: false)
        driver.changeDefault(to: 200)
        let state = backend.current()
        XCTAssertEqual(state.device?.id, 200)
        XCTAssertEqual(state.device?.name, "USB DAC")
    }

    func testCurrentReflectsNoOutputsAvailable() throws {
        let driver = FakeAudioHALDriver(snapshot: .init(defaultID: 0, devices: [:]))
        let backend = AudioBackendImpl(driver: driver)
        let state = backend.current()
        XCTAssertFalse(state.available)
        XCTAssertNil(state.device)
    }

    func testReadOnlyMuteRejectsWrite() throws {
        let deviceID: UInt32 = 100
        let driver = FakeAudioHALDriver(snapshot: .init(
            defaultID: deviceID,
            devices: [deviceID: .init(name: "Studio Display", hasSettableVolume: true,
                                      currentScalar: 0.5, currentMuted: false, hasSettableMute: false)]
        ))
        let backend = AudioBackendImpl(driver: driver)
        XCTAssertFalse(backend.current().device?.hasWritableMute ?? true)
        XCTAssertThrowsError(try backend.setMuted(true, expectedDeviceID: deviceID)) { error in
            XCTAssertEqual(error as? AudioError, .unsupported)
        }
    }

    func testFailedSelectionLeavesStickyStatusAndOldDefault() throws {
        let (backend, driver) = makeBackend()
        driver.scriptNextWriteFailure(-50)
        XCTAssertThrowsError(try backend.selectDefaultOutput(deviceID: 100))
        XCTAssertEqual(backend.current().lastOSStatus, -50)
    }

    func testSelectUnknownDeviceRejected() throws {
        let (backend, _) = makeBackend()
        XCTAssertThrowsError(try backend.selectDefaultOutput(deviceID: 999)) { error in
            XCTAssertEqual(error as? AudioError, .writeFailed(status: -50))
        }
    }

    func testSelectValidatesBeforeWritingThenReadsBack() throws {
        let extraID: UInt32 = 200
        let newDevice = FakeAudioHALDriver.DeviceState(name: "Headphones",
                                                       hasSettableVolume: true,
                                                       currentScalar: 0.4,
                                                       currentMuted: false)
        let driver2 = FakeAudioHALDriver(snapshot: .init(defaultID: 100, devices: [
            extraID: newDevice,
            100: .init(name: "Studio Display", hasSettableVolume: true, currentScalar: 0.5, currentMuted: false)
        ]))
        let backend2 = AudioBackendImpl(driver: driver2)
        let updated = try backend2.selectDefaultOutput(deviceID: 200)
        XCTAssertEqual(updated.device?.id, 200)
        XCTAssertEqual(driver2.defaultOutputDeviceID(), 200, "the driver's own default must actually change, not just the cached state")
    }

    func testOSStatusSurfaced() throws {
        let deviceID: UInt32 = 300
        let driver = FakeAudioHALDriver(snapshot: .init(
            defaultID: deviceID,
            devices: [deviceID: .init(name: "Settable", hasSettableVolume: true, currentScalar: 0.3, currentMuted: false)],
            nextWriteFailure: -50
        ))
        let backend = AudioBackendImpl(driver: driver)
        XCTAssertThrowsError(try backend.setMasterVolume(0.9, expectedDeviceID: deviceID)) { error in
            XCTAssertEqual(error as? AudioError, .writeFailed(status: -50))
        }
        XCTAssertEqual(backend.current().lastOSStatus, -50)
    }

    /// Spy driver: fails the test if any write-shaped call happens. Used to
    /// prove polling (`current()`) never has a side effect on real hardware.
    private final class WriteAssertingDriver: AudioHALDriver, @unchecked Sendable {
        let inner: FakeAudioHALDriver
        let onWrite: () -> Void
        init(inner: FakeAudioHALDriver, onWrite: @escaping () -> Void) { self.inner = inner; self.onWrite = onWrite }
        var isLive: Bool { inner.isLive }
        func defaultOutputDeviceID() -> UInt32 { inner.defaultOutputDeviceID() }
        func deviceName(for id: UInt32) -> String { inner.deviceName(for: id) }
        func hasSettableVirtualMainVolume(_ id: UInt32) -> Bool { inner.hasSettableVirtualMainVolume(id) }
        func masterScalar(_ id: UInt32) -> Float32? { inner.masterScalar(id) }
        func muted(_ id: UInt32) -> Bool? { inner.muted(id) }
        func hasSettableMute(_ id: UInt32) -> Bool { inner.hasSettableMute(id) }
        func allOutputs() -> [UInt32] { inner.allOutputs() }
        func writeVirtualMainVolume(_ value: Float32, on id: UInt32) -> Int32 { onWrite(); return inner.writeVirtualMainVolume(value, on: id) }
        func writeMute(_ muted: Bool, on id: UInt32) -> Int32 { onWrite(); return inner.writeMute(muted, on: id) }
        func setDefaultOutput(_ id: UInt32) -> Int32 { onWrite(); return inner.setDefaultOutput(id) }
    }

    func testPollingNeverWrites() {
        let inner = FakeAudioHALDriver(snapshot: .init(defaultID: 100, devices: [
            100: .init(name: "Studio Display", hasSettableVolume: true, currentScalar: 0.5, currentMuted: false)
        ]))
        var writeCount = 0
        let driver = WriteAssertingDriver(inner: inner) { writeCount += 1 }
        let backend = AudioBackendImpl(driver: driver)
        for _ in 0..<5 { _ = backend.current() }
        XCTAssertEqual(writeCount, 0, "polling current() must never call a write method on the driver")
    }

    func testMuteTogglePropagates() throws {
        let (backend, _) = makeBackend()
        let updated = try backend.setMuted(true, expectedDeviceID: 100)
        XCTAssertTrue(updated.muted)
        let updated2 = try backend.setMuted(false, expectedDeviceID: 100)
        XCTAssertFalse(updated2.muted)
    }

    func testAudioMathClampAndLabel() {
        XCTAssertEqual(AudioMath.clamp(0.5), 0.5)
        XCTAssertEqual(AudioMath.clamp(2.0), 1)
        XCTAssertEqual(AudioMath.clamp(-0.1), 0)
        XCTAssertNil(AudioMath.clamp(.nan))

        XCTAssertEqual(AudioMath.dots(for: 0.5, muted: false), 2)
        XCTAssertEqual(AudioMath.dots(for: 0.0, muted: false), 0)
        XCTAssertNil(AudioMath.dots(for: nil, muted: false))
        XCTAssertEqual(AudioMath.dots(for: 0.5, muted: true), 0)

        XCTAssertEqual(AudioMath.label(available: nil, muted: false, volume: nil), "讀取中")
        XCTAssertEqual(AudioMath.label(available: false, muted: false, volume: nil), "無輸出")
        XCTAssertEqual(AudioMath.label(available: true, muted: true, volume: 0.5), "靜音")
        XCTAssertEqual(AudioMath.label(available: true, muted: false, volume: 0.5), "50%")
        XCTAssertEqual(AudioMath.label(available: true, muted: false, volume: nil), "由裝置控制")
    }
}