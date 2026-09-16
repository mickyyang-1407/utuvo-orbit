# Development

## Toolchain

Xcode 26+ (macOS SDK with the Liquid Glass declarations) and Swift 6. The package deployment target is macOS 14. Use an Apple Silicon Mac to reproduce the downloadable arm64 build. Intel/source portability is not validated by this release.

```sh
bash scripts/build-app.sh
open "dist/UTUVO Orbit.app"
```

`Resources/AppIcon.icns` is committed original artwork. To regenerate it:

```sh
swift scripts/render-brand.swift Resources
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

## Structure

- `Sources/OrbitCore`: values, pure state resolution, interfaces and fake backends.
- `Sources/UtuvoOrbit`: native menu-bar host, one-panel SwiftUI views and live macOS adapters.
- `Tests`: value/fake tests; no real audio, network, power or saved preferences.
- `scripts`: app assembly, original artwork and release packaging.

There are no third-party Swift package dependencies.

## Focused checks

Run tests for the code you changed. For example:

```sh
swift test --filter InlineSettingsTests
swift test --filter PreferencesTests
```

The complete value/fixture suite is available with `swift test`, but it is not necessary for an isolated copy/layout edit. UI changes need a brief native check of the affected flow.

## Demo data

```sh
.build/release/UtuvoOrbit --fixture desktop --show
.build/release/UtuvoOrbit --fixture laptop --show
.build/release/UtuvoOrbit --fixture peripherals-charging --show
.build/release/UtuvoOrbit --gallery
```

Fixtures use fake preferences and fake hardware. Quit another instance with the same bundle identifier first. `--diagnose` without a fixture is a **live read-only** diagnostic, not a unit test. Treat diagnostic output as local information until redacted.

## Localization

`Sources/OrbitCore/Resources/{en,zh-Hant}.lproj/Localizable.strings` contains interface strings. `OrbitStrings` is immutable and passed through the SwiftUI environment; it never changes the global locale or system preferences. AppKit menus and the status-item tooltip use the same selected language. `build-app.sh` includes the SwiftPM resource bundle.

Preview a language without touching saved preferences:

```sh
.build/release/UtuvoOrbit --fixture desktop --language en --show
.build/release/UtuvoOrbit --fixture desktop --language zh-Hant --show
swift test --filter LocalizationTests
```

## Packaging

```sh
bash scripts/package-release.sh
```

Produces Apple Silicon app ZIP, drag-install DMG, source ZIP and SHA-256 checksums in `release/0.4.1/`. The packaging script creates an isolated temporary Python environment with `ds-store==1.3.3` and `mac-alias==2.2.3` to write Finder layout metadata; these are build tools, not shipped runtime dependencies. Packaging does not upload, notarize or change Gatekeeper. The curated source export excludes local handoffs, evidence, diagnostics and retired prototype code.

### Official signing / notarization

The default local build remains ad-hoc signed. The official 0.4.1 downloads are Developer ID signed with Hardened Runtime and a secure timestamp, then submitted to Apple's notary service. No signing credentials are stored in this repository.

Release sequence: sign an isolated copy of the app → submit its ZIP with `notarytool` → require `Accepted` → staple and validate the app → package that app → sign and submit the DMG → require `Accepted` → staple and validate the DMG → regenerate checksums. Verify Gatekeeper on both the DMG and the app inside it. This requires your own Developer ID certificate and a configured Keychain notarization profile.

To package an already signed/stapled app without rebuilding it:

```sh
SKIP_BUILD=1 APP_PATH="/absolute/path/UTUVO Orbit.app" bash scripts/package-release.sh
```

Packaging preserves the input app's signature and ticket. The DMG still needs its own Developer ID signature, notarization and ticket; packaging alone does not perform those steps. Regenerate `SHA256SUMS.txt` after stapling.

## Design constraints

Keep the menu-bar glyph compact. Do not infer known values from missing data. Retain native SwiftUI/AppKit with availability-checked materials. Do not create new permissions, startup items, telemetry or automatic system-icon hiding as a side effect of unrelated work.
