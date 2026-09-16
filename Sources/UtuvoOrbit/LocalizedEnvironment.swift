import SwiftUI
import OrbitCore

private struct OrbitStringsKey: EnvironmentKey {
    static let defaultValue = OrbitStrings()
}

extension EnvironmentValues {
    var orbitStrings: OrbitStrings {
        get { self[OrbitStringsKey.self] }
        set { self[OrbitStringsKey.self] = newValue }
    }
}
