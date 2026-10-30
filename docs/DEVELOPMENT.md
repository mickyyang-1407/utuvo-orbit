# Development

## Toolchain

Xcode 26+ (macOS SDK with the Liquid Glass declarations) and Swift 6. The package deployment target is macOS 14. Use an Apple Silicon Mac to reproduce the downloadable arm64 build. Intel/source portability is not validated by this release.

```sh
bash scripts/build-app.sh
open "dist/UTUVO Orbit.app"
```

The build starts with `python3 scripts/check-version.py`. It compares the shipped version and build defaults in `scripts/build-app.sh`, `project.yml` and the fallback literals still present in `Sources/UtuvoOrbit/OrbitStyle.swift` and `Sources/UtuvoOrbit/OrbitPanel.swift`; one disagreeing field blocks the build. `VERSION` and `BUILD_NUMBER` overrides still apply to that single build — a test bundle for example — and are never treated as drift.

`Resources/AppIcon.icns` is committed original artwork. To regenerate it:

```sh
swift scripts/render-brand.swift Resources
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

## Structure

- `Sources/OrbitCore`: values, pure state resolution, interfaces and fake backends.
- `Sources/UtuvoOrbit`: native menu-bar host, one-panel SwiftUI views and live macOS adapters.
- `Tests`: isolated fixtures and injected fakes. Some module/UI suites create windows; do not run those while the computer is in use.
- `MAS`: the free sandboxed Mac App Store target, its assets, entitlements and tests. No StoreKit products, trial or purchase gate.
- `scripts`: app assembly, original artwork and release packaging.

The direct-download executable pins Sparkle 2.10.1 for signed updates. Keep `Package.resolved` checked in and embed its framework when assembling the app. The separate Xcode `MAS` target does not link or embed Sparkle. See [software updates](UPDATING.md).

## Focused checks

Run tests for the code you changed. For example:

```sh
swift test --filter InlineSettingsTests
swift test --filter PreferencesTests
```

Use `swift test` only when native AppKit/module tests are safe to run: some suites start windows. For the 0.11 model/core changes without foreground interaction, run:

```sh
swift test --filter 'QuickLinksTests|SnippetTests|FileIntegrityTests|FreeDistributionTests|ProductivityCoreTests|ProductivityStateTests|previewFileCopyUsesTheInjectedClipboard'
```

GUI and screenshot acceptance for this candidate are deferred to the nightly session at the user’s request. Compilation or pure-model tests do not establish native UI acceptance.

## Demo data

```sh
.build/release/UtuvoOrbit --fixture desktop --show
.build/release/UtuvoOrbit --fixture laptop --show
.build/release/UtuvoOrbit --fixture peripherals-charging --show
.build/release/UtuvoOrbit --gallery
```

Fixtures use fake preferences and fake hardware. Quit another instance with the same bundle identifier first. `--diagnose` without a fixture is a **live read-only** diagnostic, not a unit test. Treat diagnostic output as local information until redacted.

Quick Tools has a separate early fixture entry point, before live preferences or hardware setup:

```sh
.build/debug/UtuvoOrbit --tools-preview --tools-tab audio --language zh-Hant
.build/debug/UtuvoOrbit --tools-preview --tools-tab timer --pomodoro --language en
.build/debug/UtuvoOrbit --tools-preview --tools-tab files --light --snapshot /tmp/orbit-files.png
.build/debug/UtuvoOrbit --tools-preview --tools-tab screenshots --language zh-Hant
swift test --filter 'ToolsCoreTests|ToolsModelsTests|QuickFileProcessorTests'
```

Previews use fake audio/awake/clipboard/app launches/hotkeys, in-memory tools and disabled notifications/file actions. New pages are `modes`, `actions`, `reminders`, `clipboard`, `text`, `pdf`, `colors` and `qr`; existing pages remain available. `--timer-seconds 2` starts a short fixture timer. Only Debug builds accept `--tools-qa-file-actions`, which enables file pickers for sandbox tests with generated temporary files; audio and awake stay fake. Never point this QA mode at personal files. The timer has its own awake backend; audio catalogs refresh on explicit entry/action rather than a second polling loop.

Screenshot previews generate a local demo image and use a fake capture provider with a temporary library. Debug-only `--tools-qa-capture` selects the real ScreenCaptureKit picker while other hardware stays fake; use a distinct QA bundle ID and a fixture-only target window. Native capture uses one complete frame from a bounded ScreenCaptureKit stream, waits for that stream to stop before returning, and captures no audio or microphone. On 2026-10-30, the isolated product backend captured the designated generated test-card window and passed editing, PNG/OCR and image-copy readback. This result is limited to that window fixture; display capture and the complete-App GUI matrix remain pending. Picker observers and request identities are scoped to one attempt, including cancellation. Editor tests and fake captures do not establish native capture acceptance.

## Localization

`Sources/OrbitCore/Resources/{en,zh-Hant}.lproj/Localizable.strings` contains the established interface strings; new workbench surfaces use the explicitly scoped bilingual `ToolCopy` value. `OrbitStrings` is immutable and passed through the SwiftUI environment; it never changes the global locale or system preferences. AppKit menus and the status-item tooltip use the same selected language. `build-app.sh` includes the SwiftPM resource bundle.

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

Produces Apple Silicon app ZIP, drag-install DMG, source ZIP and SHA-256 checksums in `release/<version>/`. The packaging script creates an isolated temporary Python environment with `ds-store==1.3.3` and `mac-alias==2.2.3` to write Finder layout metadata; these are build tools, not shipped runtime dependencies. Packaging does not upload, notarize or change Gatekeeper. The curated source export excludes local handoffs, evidence, diagnostics and retired prototype code.

Packaging never overwrites an existing artifact. When the app ZIP, the DMG, the source ZIP or `SHA256SUMS.txt` already exists — or when an output path is a symlink — the run stops before writing anything and every previous file is left exactly as it was. There is no force or delete option: remove a stale artifact yourself before rerunning.

`SKIP_APP_ZIP=1` reuses an update ZIP that was already prepared and signed by `scripts/prepare-update.py`. That ZIP must already exist at `release/<version>/UTUVO-Orbit-<version>-arm64.zip` as a regular, non-symlink file. Its bytes, size and modification time are kept unchanged, and the script verifies them again after packaging:

```sh
SKIP_BUILD=1 SKIP_APP_ZIP=1 APP_PATH="/absolute/path/UTUVO Orbit.app" bash scripts/package-release.sh
```

### Packaging fixtures

`scripts/tests/test_release_workflow.py` runs the real packaging and version scripts against a synthetic repository tree, with fake `codesign`, `lipo` and `hdiutil` command line tools:

```sh
python3 scripts/tests/test_release_workflow.py
```

No disk image is created, mounted or detached, no signature is produced, no keychain is touched and no notary service is contacted. The fixtures prove the packaging orchestration — refusals, byte-for-byte reuse of the prepared ZIP, blocking a build on version drift. They do not prove signing, notarization or the disk image layout.

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

## Showcase hosting

The bilingual static showcase is hosted at https://mickyyang-1407.github.io/utuvo-orbit/. GitHub Pages publishes `main` → `/docs`. Edit `docs/showcase/en.html` and `docs/showcase/index.html`; source export generates the English root `docs/index.html` and `.nojekyll` marker. The root entry is generated, so do not edit it directly. Assets live under `docs/assets`, and documentation links open the rendered GitHub pages.

### Web images

Keep the original PNG artwork and screenshots. Generate WebP files for the showcase with `python3 scripts/optimize-web-images.py` (requires `cwebp` from libwebp, available with `brew install webp`). The hero has 640/960/1280/1672-pixel variants selected with `srcset`; it loads eagerly at high priority. Screenshots retain their full resolution and load lazily. The light/dark switch uses the same compressed files.

## Free Mac App Store target

Both distributions offer every feature for free. No purchase, trial clock, transaction lookup or account is needed. Optional modules still start only after the user enables them; existing module preferences remain. A bounded legacy Drop marker can adopt its shelf preference once, independently of any old receipt.

Generate and build the sandboxed target with XcodeGen and Xcode:

```sh
xcodegen generate --spec project.yml
xcodebuild -project UTUVOOrbitMAS.xcodeproj -scheme UTUVOOrbitMAS -configuration Release -derivedDataPath build/mas CODE_SIGNING_ALLOWED=NO build
```

An unsigned local build does not establish App Store signing, sandbox runtime acceptance or store availability. Use your own signing team and App Group configuration for distribution; the public project contains no private signing material. The production updater applies only to the direct edition.
