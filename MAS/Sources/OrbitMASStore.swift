#if MAS
import AppKit

// MARK: - Mac App Store edition glue
//
// Only compiled into the `UTUVOOrbitMAS` Xcode target (SWIFT_ACTIVE_
// COMPILATION_CONDITIONS = MAS). The SwiftPM / Developer-ID build never sees
// this directory.
//
// Orbit is completely free in every build: there is no purchase, no trial,
// no entitlement and no account, so this file holds nothing but the app's
// metadata and the local QA arguments. Nothing here reads or writes system
// state.

enum OrbitMAS {
    static let appName = "UTUVO Orbit"

    /// One line that describes the app in the user's own language.
    static func tagline(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        (preferredLanguages.first?.hasPrefix("zh") ?? false)
            ? "選單列一顆小圖示，看電源、網路、音量"
            : "One small menu bar icon for power, network and volume."
    }

    #if DEBUG
    /// Local QA only: open the live panel on a given tab (`network`/`system`).
    static let qaTabArgument = "--mas-qa-tab"
    /// Local QA only: open the Settings window (modules) on launch.
    static let qaSettingsArgument = "--mas-qa-settings"
    /// Local QA only: put these `|`-separated files on the shelf on launch.
    static let qaShelfFilesArgument = "--mas-qa-shelf-files"
    #endif
}
#endif
