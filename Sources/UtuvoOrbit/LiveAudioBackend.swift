import Foundation
import OrbitCore

// MARK: - Live AudioBackend factory
//
// `AudioBackendImpl` (OrbitCore) is the only place that knows the
// read/write/validate protocol; the live path just injects the real
// CoreAudio driver so it runs the exact same code the tests exercise with a
// fake driver.

public func makeLiveAudioBackend() -> AudioBackend {
    AudioBackendImpl(driver: LiveAudioHALDriver())
}
