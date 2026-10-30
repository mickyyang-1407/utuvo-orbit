#if !SWIFT_PACKAGE
import Foundation

// MARK: - Bundle.module for the Xcode (Mac App Store) build
//
// SwiftPM synthesizes `Bundle.module` for OrbitCore's processed resources.
// The `UTUVOOrbitMAS` Xcode project builds OrbitCore as a framework instead,
// with the same `.lproj` tables copied into the framework bundle — so the
// "module" bundle is simply the framework's own bundle. Never compiled by
// SwiftPM (SWIFT_PACKAGE is defined there).

private final class OrbitCoreBundleToken {}

extension Bundle {
    static var module: Bundle { Bundle(for: OrbitCoreBundleToken.self) }
}
#endif
