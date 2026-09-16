import Foundation

// MARK: - Preferences + migration
//
// New domain: `com.utuvo.orbit`. One-time migration copies ONLY three keys
// from the legacy `app.pik.orbit.local` domain when the new keys look fresh
// (default values + migration sentinel missing). It never blindly copies the
// whole domain and never writes back into the legacy domain.

public enum OrbitPreferencesStore {
    public static let newDomain = "com.utuvo.orbit"
    public static let legacyDomain = "app.pik.orbit.local"

    public static let migrationSentinelKey = "_migrated_from_pik_orbit_v1"

    public static let keys = (
        desktopRing: "desktopRing",
        showPercent: "showPercent",
        colorful: "colorful",
        theme: "theme",
        pin: "pin",
        ringCenter: "ringCenter",
        glyphStyle: "glyphStyle",
        language: "language"
    )

    /// Pure migration: copy each allowed legacy key ONLY if it is absent in the
    /// current (new-domain) dictionary. Even when one key is present, the
    /// others are still candidates. We never overwrite an explicit value the
    /// user has set in the new domain, including the default values. `pin`
    /// is intentionally not migrated — it is a per-session UI flag.
    public static func migrate(current: OrbitPreferencesValues,
                                legacyDefaults: [String: Any],
                                presenceOf: (String) -> Bool) -> OrbitPreferencesValues {
        var updated = current
        // desktopRing
        if !presenceOf(keys.desktopRing),
           let raw = legacyDefaults[keys.desktopRing] as? String,
           let ring = DesktopRing(rawValue: raw) {
            updated.desktopRing = ring
        }
        // showPercent
        if !presenceOf(keys.showPercent),
           let value = legacyDefaults[keys.showPercent] as? Bool {
            updated.showPercent = value
        }
        // colorful
        if !presenceOf(keys.colorful),
           let value = legacyDefaults[keys.colorful] as? Bool {
            updated.colorful = value
        }
        return updated
    }

    /// Pure predicate: true when EVERY preference (including the 0.3
    /// additions) is still at its shipped default. NOT the live backend's
    /// migration gate — `loadFresh` gates strictly on the sentinel key
    /// (see its own comment), specifically because gating on "everything
    /// still default" let one already-customized key silently block
    /// migrating the others forever. This predicate is exposed publicly
    /// for callers that want a simple "has the user touched anything yet"
    /// check (e.g. `FakePreferencesBackend`, tests). We deliberately
    /// ignore `pin` because it is a session flag that never persists
    /// across launches.
    public static func looksFresh(_ current: OrbitPreferencesValues) -> Bool {
        current.desktopRing == .cpu
            && current.showPercent == false
            && current.colorful == true
            && current.theme == .system
            && current.ringCenter == .network
            && current.glyphStyle == .combined
            && current.language == .system
    }
}

/// Helper to inspect what `UserDefaults` actually returns for a domain, used by
/// the live preferences backend. Kept pure so tests can swap the implementation.
///
/// IMPORTANT: only the new bundle domain (`com.utuvo.orbit`) is ever written to.
/// The legacy `app.pik.orbit.local` domain is read-only and only consulted for the
/// one-time migration. The implementation uses `UserDefaults.persistentDomain`
/// to read raw presence so we never accidentally create a writeable suite
/// that the OS would treat as a new preference domain.
public protocol UserDefaultsInspecting: AnyObject, Sendable {
    func dictionary(forDomain domain: String) -> [String: Any]
    func set(_ value: Any?, forKey key: String, domain: String)
    func removeObject(forKey key: String, domain: String)
    func synchronize(domain: String)
    /// Read the legacy presence-only domain. Never write through this path.
    func legacyPresence(forDomain domain: String) -> [String: Any]
}

public final class UserDefaultsInspector: UserDefaultsInspecting, @unchecked Sendable {
    public init() {}

    // MARK: - CFPreferences, not UserDefaults(suiteName:)
    //
    // `UserDefaults(suiteName:)` is for APP GROUP suites shared across
    // processes/extensions. Passing the app's OWN bundle identifier
    // (`com.utuvo.orbit`) is explicitly documented as nonsensical — macOS
    // logs "Using your own bundle identifier as an NSUserDefaults suite
    // name does not make sense and will not work" and the writes never
    // reach a real plist (confirmed on-device: `com.utuvo.orbit.plist`
    // stayed absent after a normal launch + settings change). CFPreferences
    // has no such restriction: any domain string — the app's own bundle ID
    // or a disposable QA domain — round-trips identically through the same
    // get/set/synchronize calls (verified against the real SDK with a
    // throwaway `com.utuvo.orbit.qa.<UUID>` domain: write → synchronize →
    // read-back → remove-all → synchronize left zero keys).
    public func dictionary(forDomain domain: String) -> [String: Any] {
        guard let keyList = CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return [:]
        }
        return (CFPreferencesCopyMultiple(keyList, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]) ?? [:]
    }
    public func set(_ value: Any?, forKey key: String, domain: String) {
        guard domain != OrbitPreferencesStore.legacyDomain else {
            // Hard guard: the legacy domain is never written to.
            assertionFailure("refusing to write to legacy domain \(domain)")
            return
        }
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    public func removeObject(forKey key: String, domain: String) {
        guard domain != OrbitPreferencesStore.legacyDomain else { return }
        CFPreferencesSetValue(key as CFString, nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    public func synchronize(domain: String) {
        guard domain != OrbitPreferencesStore.legacyDomain else { return }
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    public func legacyPresence(forDomain domain: String) -> [String: Any] {
        dictionary(forDomain: domain)
    }
}

/// Test-only inspector that captures calls without touching the real filesystem.
public final class InMemoryDefaultsInspector: UserDefaultsInspecting, @unchecked Sendable {
    public var store: [String: [String: Any]] = [:]
    public var removed: [(String, String)] = []
    public var writesRefused: [(String, String)] = []
    public init(initial: [String: [String: Any]] = [:]) { self.store = initial }
    public func dictionary(forDomain domain: String) -> [String: Any] { store[domain] ?? [:] }
    public func set(_ value: Any?, forKey key: String, domain: String) {
        if domain == OrbitPreferencesStore.legacyDomain {
            writesRefused.append((domain, key))
            return
        }
        if store[domain] == nil { store[domain] = [:] }
        if let value { store[domain]?[key] = value } else { store[domain]?.removeValue(forKey: key) }
    }
    public func removeObject(forKey key: String, domain: String) {
        if domain == OrbitPreferencesStore.legacyDomain {
            writesRefused.append((domain, key))
            return
        }
        store[domain]?.removeValue(forKey: key)
        removed.append((domain, key))
    }
    public func synchronize(domain: String) {}
    public func legacyPresence(forDomain domain: String) -> [String: Any] {
        store[domain] ?? [:]
    }
}

/// Live preferences backend. Loads from new domain; one-time copies three keys
/// from legacy domain if it hasn't run yet, then marks the sentinel so we don't
/// keep re-running. Never writes to the legacy domain.
public final class LivePreferencesBackend: PreferencesBackend, @unchecked Sendable {
    private let inspector: UserDefaultsInspecting
    private let newDomain: String
    private let legacyDomain: String
    private var cached: OrbitPreferencesValues

    public init(inspector: UserDefaultsInspecting = UserDefaultsInspector(),
                newDomain: String = OrbitPreferencesStore.newDomain,
                legacyDomain: String = OrbitPreferencesStore.legacyDomain,
                now: Date = Date()) {
        self.inspector = inspector
        self.newDomain = newDomain
        self.legacyDomain = legacyDomain
        self.cached = Self.loadFresh(inspector: inspector, newDomain: newDomain, legacyDomain: legacyDomain, now: now)
    }

    public func load() -> OrbitPreferencesValues {
        // Pin never persists across process launch; always reset.
        var values = cached
        values.pin = false
        cached = values
        return values
    }

    public func save(_ values: OrbitPreferencesValues) {
        // Pin is session-scoped — write everything except pin to the store,
        // but never persist pin itself.
        var persisted = values
        persisted.pin = false
        cached = persisted
        inspector.set(persisted.desktopRing.rawValue, forKey: OrbitPreferencesStore.keys.desktopRing, domain: newDomain)
        inspector.set(persisted.showPercent, forKey: OrbitPreferencesStore.keys.showPercent, domain: newDomain)
        inspector.set(persisted.colorful, forKey: OrbitPreferencesStore.keys.colorful, domain: newDomain)
        inspector.set(persisted.theme.rawValue, forKey: OrbitPreferencesStore.keys.theme, domain: newDomain)
        inspector.set(persisted.ringCenter.rawValue, forKey: OrbitPreferencesStore.keys.ringCenter, domain: newDomain)
        inspector.set(persisted.glyphStyle.rawValue, forKey: OrbitPreferencesStore.keys.glyphStyle, domain: newDomain)
        inspector.set(persisted.language.rawValue, forKey: OrbitPreferencesStore.keys.language, domain: newDomain)
        inspector.removeObject(forKey: OrbitPreferencesStore.keys.pin, domain: newDomain)
        inspector.synchronize(domain: newDomain)
    }

    static func loadFresh(inspector: UserDefaultsInspecting, newDomain: String, legacyDomain: String, now: Date) -> OrbitPreferencesValues {
        let newRaw = inspector.dictionary(forDomain: newDomain)
        let migrated = (newRaw[OrbitPreferencesStore.migrationSentinelKey] as? Bool) ?? false
        let current = Self.readValues(from: newRaw)
        guard !migrated else { return current }
        // Gate migration on the sentinel alone, NOT on `looksFresh(current)`.
        // `migrate` already only copies a key that is genuinely absent from
        // the new domain (via `presenceOf`) — gating the whole pass on every
        // value being at its default meant a single already-customized key
        // (e.g. showPercent already true) silently skipped migrating the
        // OTHER, still-absent keys forever, since the sentinel never got a
        // chance to run.
        let legacyRaw = inspector.legacyPresence(forDomain: legacyDomain)
        let presence: (String) -> Bool = { key in newRaw[key] != nil }
        let merged = OrbitPreferencesStore.migrate(current: current,
                                                    legacyDefaults: legacyRaw,
                                                    presenceOf: presence)
        // Write order matters: migrated VALUES first, sentinel LAST, ONE
        // `synchronize` after everything. The previous order (sentinel,
        // then its own synchronize, then the values) meant a crash/kill in
        // between left the sentinel durably marking "already migrated"
        // while the actual migrated values were never flushed — silently
        // losing them forever on the next launch.
        if merged != current {
            inspector.set(merged.desktopRing.rawValue, forKey: OrbitPreferencesStore.keys.desktopRing, domain: newDomain)
            inspector.set(merged.showPercent, forKey: OrbitPreferencesStore.keys.showPercent, domain: newDomain)
            inspector.set(merged.colorful, forKey: OrbitPreferencesStore.keys.colorful, domain: newDomain)
        }
        inspector.set(true, forKey: OrbitPreferencesStore.migrationSentinelKey, domain: newDomain)
        inspector.synchronize(domain: newDomain)
        return merged
    }

    static func readValues(from raw: [String: Any]) -> OrbitPreferencesValues {
        let ring = (raw[OrbitPreferencesStore.keys.desktopRing] as? String).flatMap(DesktopRing.init(rawValue:)) ?? .cpu
        let show = (raw[OrbitPreferencesStore.keys.showPercent] as? Bool) ?? false
        let colorful = (raw[OrbitPreferencesStore.keys.colorful] as? Bool) ?? true
        let theme = (raw[OrbitPreferencesStore.keys.theme] as? String).flatMap(AppTheme.init(rawValue:)) ?? .system
        let pin = (raw[OrbitPreferencesStore.keys.pin] as? Bool) ?? false
        // New 0.3 keys: missing or an unrecognised raw string both fall back
        // to the default — never migrated from Pik, never gated by
        // `looksFresh`. An existing, valid new-domain value is preserved.
        let ringCenter = (raw[OrbitPreferencesStore.keys.ringCenter] as? String).flatMap(RingCenter.init(rawValue:)) ?? .network
        let glyphStyle = (raw[OrbitPreferencesStore.keys.glyphStyle] as? String).flatMap(GlyphStyle.init(rawValue:)) ?? .combined
        let language = (raw[OrbitPreferencesStore.keys.language] as? String).flatMap(AppLanguage.init(rawValue:)) ?? .system
        return OrbitPreferencesValues(desktopRing: ring, showPercent: show, colorful: colorful, theme: theme, pin: pin,
                                      ringCenter: ringCenter, glyphStyle: glyphStyle, language: language)
    }
}
