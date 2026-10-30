import AppKit
import Combine
import ClotheslineKit
import ShelfKit

/// Owns Orbit's optional modules. Each one is OFF by default and only exists
/// (window, observers, hotkey, folder watch) while the user has switched it
/// on. There is no purchase, trial or entitlement any more: nothing here
/// suspends a module. Nothing runs in the isolated diagnose / gallery /
/// fixture modes.
@MainActor
final class OrbitModules: ObservableObject {
    enum Kind: String, CaseIterable { case shelf, clothesline }

    static func enabledKey(_ kind: Kind) -> String { "modules.\(kind.rawValue).enabled" }

    private let defaults: UserDefaults
    let shelf: ShelfModule
    let clothesline: ClotheslineModule
    @Published private(set) var shelfEnabled: Bool
    @Published private(set) var clotheslineEnabled: Bool
    @Published private(set) var clotheslineError: String?

    init(defaults: UserDefaults, language: String, libraryRoot: URL) {
        self.defaults = defaults
        shelfEnabled = defaults.bool(forKey: Self.enabledKey(.shelf))
        clotheslineEnabled = defaults.bool(forKey: Self.enabledKey(.clothesline))
        shelf = ShelfModule(defaults: defaults, language: language)
        clothesline = ClotheslineModule(settings: ClotheslineSettings(defaults: defaults),
                                        libraryRoot: libraryRoot, language: language)
    }

    /// Default location of the clothesline's managed copies. Inside the
    /// container for the App Store build.
    static func defaultLibraryRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UTUVO Orbit/Clothesline", isDirectory: true)
    }

    static let adoptedDropKey = "modules.adoptedDropUser"

    /// One time only: a UTUVO Drop user finds the file shelf already on.
    /// If they later switch it off, it stays off.
    func adoptDropUser() {
        guard !defaults.bool(forKey: Self.adoptedDropKey) else { return }
        defaults.set(true, forKey: Self.adoptedDropKey)
        defaults.set(true, forKey: Self.enabledKey(.shelf))
        shelfEnabled = true
        apply()
    }

    func isEnabled(_ kind: Kind) -> Bool {
        kind == .shelf ? shelfEnabled : clotheslineEnabled
    }

    func setEnabled(_ kind: Kind, _ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey(kind))
        switch kind {
        case .shelf: shelfEnabled = on
        case .clothesline:
            clotheslineEnabled = on
            if on, clothesline.settings.needsFolder { clothesline.settings.chooseFolder() }
        }
        apply()
    }

    /// Reconciles the running modules with what the user switched on.
    func apply() {
        if shelfEnabled { shelf.start() } else { shelf.stop() }
        if clotheslineEnabled {
            do { try clothesline.start(); clotheslineError = nil }
            catch { clotheslineError = error.localizedDescription; clothesline.stop() }
        } else {
            clothesline.stop()
        }
    }

    func setLanguage(_ code: String) {
        shelf.setLanguage(code)
        clothesline.setLanguage(code)
        objectWillChange.send()
    }

    func stopAll() {
        shelf.stop()
        clothesline.stop()
    }
}

