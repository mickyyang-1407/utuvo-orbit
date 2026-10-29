import Foundation

public struct SceneAudioDevice: Equatable, Sendable, Identifiable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public init(id: UInt32, uid: String, name: String) { self.id = id; self.uid = uid; self.name = name }
}

public struct SceneAudioRoutes: Sendable {
    public var outputs: [SceneAudioDevice]
    public var inputs: [SceneAudioDevice]
    public var currentOutput: UInt32
    public var currentInput: UInt32
    public init(outputs: [SceneAudioDevice], inputs: [SceneAudioDevice], currentOutput: UInt32, currentInput: UInt32) {
        self.outputs = outputs; self.inputs = inputs; self.currentOutput = currentOutput; self.currentInput = currentInput
    }
}

public protocol AudioSceneRouting: AnyObject, Sendable {
    func routes() -> SceneAudioRoutes
    func selectInput(_ id: UInt32) throws
}

public struct AudioScene: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var outputUID: String
    public var outputName: String
    public var inputUID: String?
    public var inputName: String?
    public var volume: Double?
    public var awakeMinutes: Int?
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 64 && !outputUID.isEmpty &&
        (inputUID.map { !$0.isEmpty } ?? true) &&
        (volume.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
        (awakeMinutes.map { [30, 60, 120].contains($0) } ?? true)
    }
    public init(id: UUID = UUID(), name: String, outputUID: String, outputName: String,
                inputUID: String? = nil, inputName: String? = nil, volume: Double? = nil, awakeMinutes: Int? = nil) {
        self.id = id; self.name = name; self.outputUID = outputUID; self.outputName = outputName
        self.inputUID = inputUID; self.inputName = inputName; self.volume = volume; self.awakeMinutes = awakeMinutes
    }
}

public enum AudioSceneError: Error, Equatable {
    case invalid
    case missingOutput(String)
    case missingInput(String)
    case volumeUnsupported
    case routeChanged
}

/// Every device is resolved before the first write. UIDs survive ID changes
/// after reconnect/reboot; a similarly named device is never a substitute.
public struct AudioSceneApplier {
    public let routing: any AudioSceneRouting
    public let audio: any AudioBackend
    public init(routing: any AudioSceneRouting, audio: any AudioBackend) { self.routing = routing; self.audio = audio }

    public func capture(name: String, includeVolume: Bool, awakeMinutes: Int?) throws -> AudioScene {
        let routes = routing.routes(), state = audio.current()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64,
              awakeMinutes.map({ [30, 60, 120].contains($0) }) ?? true,
              let output = routes.outputs.first(where: { $0.id == routes.currentOutput }), !output.uid.isEmpty else { throw AudioSceneError.invalid }
        guard state.device?.id == output.id else { throw AudioSceneError.routeChanged }
        let input = routes.inputs.first { $0.id == routes.currentInput }
        return AudioScene(name: name, outputUID: output.uid, outputName: output.name,
                          inputUID: input?.uid, inputName: input?.name,
                          volume: includeVolume && state.device?.id == output.id && state.device?.hasWritableVolume == true ? state.masterVolume : nil,
                          awakeMinutes: awakeMinutes)
    }

    public func apply(_ scene: AudioScene) throws {
        guard scene.isValid else { throw AudioSceneError.invalid }
        let routes = routing.routes()
        let outputs = routes.outputs.filter { $0.uid == scene.outputUID }
        guard outputs.count == 1, let output = outputs.first else { throw AudioSceneError.missingOutput(scene.outputName) }
        let input: SceneAudioDevice?
        if let uid = scene.inputUID {
            let matches = routes.inputs.filter { $0.uid == uid }
            guard matches.count == 1 else { throw AudioSceneError.missingInput(scene.inputName ?? uid) }
            input = matches.first
        } else { input = nil }
        if scene.volume != nil, !audio.current().outputs.contains(where: { $0.id == output.id && $0.hasWritableVolume }) {
            throw AudioSceneError.volumeUnsupported
        }
        if routes.currentOutput != output.id { _ = try audio.selectDefaultOutput(deviceID: output.id) }
        if let input, input.id != routes.currentInput {
            guard routing.routes().inputs.contains(input) else { throw AudioSceneError.routeChanged }
            try routing.selectInput(input.id)
        }
        if let volume = scene.volume {
            let fresh = routing.routes()
            guard fresh.currentOutput == output.id, fresh.outputs.contains(output) else { throw AudioSceneError.routeChanged }
            _ = try audio.setMasterVolume(volume, expectedDeviceID: output.id)
        }
        let readback = routing.routes()
        guard readback.currentOutput == output.id, readback.outputs.contains(output),
              input.map({ readback.currentInput == $0.id && readback.inputs.contains($0) }) ?? true else { throw AudioSceneError.routeChanged }
    }
}
