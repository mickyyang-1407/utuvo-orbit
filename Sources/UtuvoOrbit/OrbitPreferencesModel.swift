import Foundation
import Combine
import SwiftUI
import OrbitCore

@MainActor
final class OrbitPreferencesModel: ObservableObject {
    @Published var values: OrbitPreferencesValues
    private let backend: PreferencesBackend
    init(backend: PreferencesBackend) {
        self.backend = backend
        self.values = backend.load()
    }
    func update(_ mutation: (inout OrbitPreferencesValues) -> Void) {
        var copy = values
        mutation(&copy)
        guard copy != values else { return }
        values = copy
        backend.save(copy)
    }
}
