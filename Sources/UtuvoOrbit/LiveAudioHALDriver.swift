import AudioToolbox
import CoreAudio
import Foundation
import OrbitCore

// MARK: - Live Audio HAL driver
//
// Thin wrapper over CoreAudio. We use `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`
// (vmvc) when it is settable so multi-channel balance is preserved. We do NOT
// fall back to writing identical values to channels 1...2 — that loses the
// channel IDs, can push values out of range on hardware that scales per
// channel, and leaves no clean rollback path if a partial write fails.
//
// IMPORTANT: vmvc is a "hardware service" virtual property, not a plain
// per-object property — it is synthesized by the HAL across whatever real
// channel layout the device has. It must be queried/written through the
// `AudioHardwareService*` entry points (`AudioHardwareServiceHasProperty`,
// `AudioHardwareServiceGetPropertyData`, `AudioHardwareServiceIsPropertySettable`,
// `AudioHardwareServiceSetPropertyData`). Calling the plain `AudioObject*`
// equivalents on it (as this file previously did) silently reports "not
// present" on hardware where it should be available. The `AudioHardwareService*`
// symbols carry a "deprecated in 10.11" annotation in the SDK header but
// remain the only working entry point for this specific property — the
// annotation does not mean they stopped functioning.



public final class LiveAudioHALDriver: AudioHALDriver, @unchecked Sendable {
    public init() {}
    public let isLive: Bool = true

    public func defaultOutputDeviceID() -> UInt32 {
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                               &address, 0, nil, &size, &deviceID)
        guard status == noErr else { return 0 }
        return UInt32(deviceID)
    }

    public func deviceName(for id: UInt32) -> String {
        var name: CFString = "音訊輸出" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(AudioObjectID(id), &nameAddress, 0, nil, &nameSize, &name)
        return name as String
    }

    private static let vmvcAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    public func hasSettableVirtualMainVolume(_ id: UInt32) -> Bool {
        var address = Self.vmvcAddress
        guard AudioHardwareServiceHasProperty(AudioObjectID(id), &address) else { return false }
        var settable: DarwinBoolean = false
        _ = AudioHardwareServiceIsPropertySettable(AudioObjectID(id), &address, &settable)
        return settable.boolValue
    }

    public func masterScalar(_ id: UInt32) -> Float32? {
        var address = Self.vmvcAddress
        guard AudioHardwareServiceHasProperty(AudioObjectID(id), &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioHardwareServiceGetPropertyData(AudioObjectID(id), &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    public func writeVirtualMainVolume(_ value: Float32, on id: UInt32) -> Int32 {
        var address = Self.vmvcAddress
        var local = value
        return AudioHardwareServiceSetPropertyData(AudioObjectID(id), &address, 0, nil,
                                                   UInt32(MemoryLayout<Float32>.size), &local)
    }

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    public func muted(_ id: UInt32) -> Bool? {
        var address = Self.muteAddress
        guard AudioObjectHasProperty(AudioObjectID(id), &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(id), &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value == 1
    }

    /// Mute is a plain per-object property (not a hardware-service virtual
    /// one), so `AudioObjectIsPropertySettable` is the correct check — but it
    /// must be checked, not assumed from readability alone.
    public func hasSettableMute(_ id: UInt32) -> Bool {
        var address = Self.muteAddress
        guard AudioObjectHasProperty(AudioObjectID(id), &address) else { return false }
        var settable: DarwinBoolean = false
        _ = AudioObjectIsPropertySettable(AudioObjectID(id), &address, &settable)
        return settable.boolValue
    }

    public func writeMute(_ muted: Bool, on id: UInt32) -> Int32 {
        var address = Self.muteAddress
        var local: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(AudioObjectID(id), &address, 0, nil,
                                         UInt32(MemoryLayout<UInt32>.size), &local)
    }

    public func setDefaultOutput(_ id: UInt32) -> Int32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = id
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &address, 0, nil, size, &value)
    }

    public func allOutputs() -> [UInt32] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        var outputs: [UInt32] = []
        for device in devices {
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var outSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(device, &outputAddress, 0, nil, &outSize) == noErr, outSize > 0 {
                outputs.append(UInt32(device))
            }
        }
        return outputs
    }
}