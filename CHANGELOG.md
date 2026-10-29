# Changelog

## 0.12.0 (17) — local candidate, GUI acceptance pending

- Adds per-library JSON backups and previewed merge imports for Notes, Snippets and Quicklinks, preserving text, IDs, pins, dates, keywords and Recently Deleted.
- Refuses conflicts, stale previews, unsaved drafts, damaged libraries and merged limits; identical reimports make no copies or writes.
- Uses private unique exports, bounded regular-file reads and atomic private library writes with a pre-commit failure seam.
- Keeps every feature free and MIT licensed. GUI and native screenshot acceptance remain deferred to the nightly session; no stable binary/feed or App Store update.

## 0.11.0 (16) — local candidate, GUI acceptance pending

- Makes both distribution targets fully free: removes StoreKit trial/purchase/paywall gates and purchase/restore menus. Existing MIT licensing continues; the source export includes the Mac App Store target.
- Adds saved Web Quicklinks with fixed HTTP(S) destinations and optional `{query}` searches; terms are encoded once and links open only on request.
- Adds private plain-text Snippets with date/time and named fields, one-pass expansion, autosave/draft protection, and explicit Copy / Text / Notes handoffs.
- Adds streaming SHA-256 / SHA-512 / compatibility MD5 checksums for explicitly selected files, expected-checksum checks and two-file hash comparison.
- Integrates all three pages and saved items into action search. No new dependency, background scan, automatic typing or global shortcut.
- Daytime verification remains isolated tests and builds. Actual GUI and native capture acceptance are deferred to the existing nightly schedule; this candidate is not published and does not change the production feed.

## 0.10.0 (15) — local candidate, GUI acceptance pending

- Adds calculator/history and dimensional unit conversion with bounded parsing and explicit errors.
- Adds offline world-clock favorites, date preview, DST-aware offsets and date rollover.
- Adds private quick notes with autosave, search, pins, recoverable trash, Markdown export and unsaved-draft protection.
- Integrates all three tools into the workbench/action search; makes the sidebar scroll.
- Daytime checks are isolated tests and builds only. GUI and native screenshot acceptance run at night at the user’s request. No public release or feed update for this build.

## 0.9.1 (14) — engineering prerelease

- Configures the production Sparkle public key and HTTPS feed; signs and verifies update archives and appcasts with the private key kept in Keychain.
- Adds an inside-out Developer ID signing script. The direct app is notarized and passes Gatekeeper assessment.
- Verifies the real Orbit updater in a separate, notarized bundle: damaged archive refused without replacing build 13; automatic background download, installation and Sparkle relaunch to build 14 passed; update preferences persisted, and a further check reported the current version.
- Adds a screen-capture usage description, explicit window/display picker presentation and bounded selection waiting with timeout recovery. Native screenshot capture remains NOT ACCEPTED: no selected frame was obtained; direct ScreenCaptureKit permission diagnostics return -3801 and permission refresh requires the owner's macOS authentication.
- Regression: 257 XCTest tests and 73 Swift Testing functions pass; direct and App Store Release builds pass. The normal App Store target does not include Sparkle.

## 0.9.0 (13) — local candidate, not released

- Adds a sidebar workbench and context recipes combining audio, a timer, a dedicated keep-awake assertion and user-selected Apps, with dependency checks and partial-failure feedback.
- Adds searchable/pinnable actions, keyboard navigation, ⌘K and an optional global ⌃⌥Space shortcut (off by default).
- Adds opt-in battery/accessory/network reminders using the existing telemetry coordinator, with edge detection, hysteresis and permission-race protection.
- Adds bounded local clipboard history with search/pins, sensitive-type filtering, private atomic storage and explicit corruption recovery. Tracking starts disabled.
- Adds text cleanup/JSON/URL/Base64, non-destructive PDF merge/extract/split/rotate/image conversion, a saved color palette with native sampler, and offline QR generation/recognition.
- Connects clipboard → text → QR and edited screenshots → QR. Text drafts survive page changes. Standard native editing shortcuts are supported.
- Native screenshot capture remains unaccepted from 0.8. Production updater key/feed, notarization and public/App Store release remain pending.

## 0.8.0 (12) — local engineering candidate, not released

- Added screenshot import, crop, arrows, boxes, flattened opaque redaction, undo/reset and persistent edit history. Copy, OCR, PNG export and file-tool handoff use the edited pixels; originals stay intact.
- Added a native one-shot ScreenCaptureKit window/display picker path. Its picker did not appear on this test Mac; native capture remains unaccepted. Use macOS screenshot shortcuts and import the resulting file for the validated editor path.
- Added audio-scene rename/reorder and explicit backup/reset for damaged saved data.
- Added 1–120-minute custom countdowns, persisted timer options and protection against late notification authorization re-enabling a cancelled choice. Pomodoro preserves the separate countdown duration.
- Added file drag/drop, duplicate-reference removal and individual removal without touching files.
- Synchronized tool/settings window titles and chrome with language/theme; corrected CoreAudio CFString ownership and appearance-observer actor access.
- Fixture regression, sandbox editor/export checks and bilingual screenshots are recorded locally. Production update signing/feed and public release remain pending.

## 0.7.0 (11) — local candidate, not released

- Added a bilingual Quick Tools window, available from the panel, status menu and file shelf.
- Save audio scenes with stable device UIDs, optional volume and 30/60/120-minute keep-awake. Missing or ambiguous saved devices are checked before any scene write.
- Added countdown presets, pause/resume, explicit 25/5 Pomodoro stages, optional notifications and a separate timer-owned keep-awake assertion. System sleep counts toward elapsed time.
- Export ZIP, PNG, JPEG or 1600px PNG copies to a new folder, or copy file paths. Original files remain intact; image exports honor orientation and flatten JPEG transparency onto white.
- Added isolated core/model/file tests and exercised real sandbox file pickers, ZIP/JPEG exports and fake-audio/timer UI flows. Production update feed and release signing remain pending.

## 0.6.0 — local candidate, not released

- Refreshed the menu panel and added General, Modules and Updates pages with English/Traditional Chinese and light/dark support.
- Completed opt-in launch at login with system approval guidance and status refresh.
- Added pinned Sparkle 2.10.1 integration, update preferences and a status-menu update action to the direct-download edition; the App Store edition uses its store update path.
- Added signed-update packaging checks and isolated login/update tests. Production signing key and public update feed await release approval.

## 0.4.2 — 2026-09-17

- Fixed: the menu-bar glyph redrew itself in a loop (status-item replicant refresh re-fired the appearance observer), burning 60–90 % of one CPU core while idle. The observer now redraws only when light/dark actually changes. Idle CPU measured at 0.3 % after the fix.

## 0.4.1 — English + Traditional Chinese

- September 16 signing refresh: official App and DMG now use Developer ID signing and Apple notarization, with stapled tickets. Same app version/build and features; release files and checksums refreshed.

- Full English interface, including menus, state descriptions, tooltips and accessibility labels.
- A footer language menu: System, English and 繁體中文. Changes apply immediately and persist.
- Real English screenshots, bilingual showcase pages, updated release artwork and bundled localization resources.

## 0.4.0 — 2026-09-16

### One panel

- Display preferences live below the status details. Removed the separate settings page and its gear/back/done navigation.
- A tighter panel brings common controls and appearance choices together.
- Added original app artwork and a curated MIT open-source release kit.
- Added bilingual documentation, real demo screenshots, DMG/ZIP/source downloads and checksums.

### Retained fixes

- Native material and SwiftUI text share the same Light/Dark/System appearance.
- Changing percentage visibility or combined/classic glyph width does not drag the open panel across the screen.
- Duration and keep-awake actions use matching native glass controls.
- Peripheral charging is displayed only from explicit, identity-matched system data.

### Distribution

Apple Silicon, macOS 14+ deployment target; macOS 27 UI validation. Ad-hoc signed, not Apple-notarized. No universal-binary or Intel validation claim.
