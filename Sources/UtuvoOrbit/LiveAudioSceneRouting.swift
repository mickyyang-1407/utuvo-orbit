import CoreAudio
import OrbitCore

final class LiveAudioSceneRouting: AudioSceneRouting, @unchecked Sendable {
    private let output = LiveAudioHALDriver()

    func routes() -> SceneAudioRoutes {
        let outputs = output.allOutputs().compactMap(device)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var inputs: [SceneAudioDevice] = []
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr {
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            if !ids.isEmpty, AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr {
                for id in ids {
                    var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
                    var count: UInt32 = 0
                    if AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &count) == noErr, count > 0, let device = device(id) { inputs.append(device) }
                }
            }
        }
        return SceneAudioRoutes(outputs: outputs, inputs: inputs, currentOutput: output.defaultOutputDeviceID(), currentInput: inputID())
    }

    func selectInput(_ id: UInt32) throws {
        guard routes().inputs.contains(where: { $0.id == id }) else { throw AudioSceneError.routeChanged }
        var address = inputAddress
        var value = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else { throw AudioError.writeFailed(status: status) }
        guard inputID() == id else { throw AudioSceneError.routeChanged }
    }

    private var inputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func inputID() -> UInt32 {
        var address = inputAddress, id: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr ? id : 0
    }

    private func device(_ id: UInt32) -> SceneAudioDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        // AudioHardwareBase.h assigns ownership of this CFObject to the caller.
        let uid = value.takeRetainedValue() as String
        guard !uid.isEmpty else { return nil }
        return SceneAudioDevice(id: id, uid: uid, name: output.deviceName(for: id))
    }
}
