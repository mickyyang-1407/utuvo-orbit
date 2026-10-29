#if !SWIFT_PACKAGE
import Foundation

// MARK: - Bundle.module for the Xcode (Mac App Store) build
//
// SwiftPM synthesizes `Bundle.module` for ShelfKit's copied `Assets` folder.
// The Xcode project builds ShelfKit as a framework with the same folder
// copied into the framework bundle, so "module" is the framework's bundle.

private final class ShelfKitBundleToken {}

extension Bundle {
    static var module: Bundle { Bundle(for: ShelfKitBundleToken.self) }
}
#endif
