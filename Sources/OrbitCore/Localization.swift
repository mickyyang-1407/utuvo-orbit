import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case system
    case english = "en"
    case traditionalChinese = "zh-Hant"

    /// Uses the first supported system preference. Other languages fall back to English.
    public func resolvedIdentifier(preferredLanguages: [String]) -> String {
        guard self == .system else { return rawValue }
        for language in preferredLanguages {
            let prefix = language.lowercased().replacingOccurrences(of: "_", with: "-")
            if prefix == "zh" || prefix.hasPrefix("zh-") { return "zh-Hant" }
            if prefix == "en" || prefix.hasPrefix("en-") { return "en" }
        }
        return "en"
    }

    public var displayName: String {
        switch self {
        case .system: return "系統"
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        }
    }
}

/// Immutable, explicitly scoped localization. No global locale or preference mutation.
public struct OrbitStrings: Sendable {
    public let identifier: String
    private let bundle: Bundle

    public init(language: AppLanguage = .system, preferredLanguages: [String] = Locale.preferredLanguages) {
        identifier = language.resolvedIdentifier(preferredLanguages: preferredLanguages)
        let path = Bundle.module.path(forResource: identifier, ofType: "lproj")!
        bundle = Bundle(path: path)!
    }

    public func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        let value = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return value }
        return String(format: value, locale: Locale(identifier: identifier), arguments: arguments)
    }
}
