import Foundation

/// Follows UTUVO Orbit's own language setting ("system", "en" or "zh-Hant"),
/// which the host pushes through `ClotheslineModule.setLanguage(_:)`.
enum L {
    nonisolated(unsafe) static var languageCode = "system"
    static var chinese: Bool {
        switch languageCode {
        case "zh-Hant": return true
        case "en": return false
        default: return Locale.preferredLanguages.first?.hasPrefix("zh") == true
        }
    }
    static func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }
    static var title: String { text("晾衣繩", "Clothesline") }
}
