# Changelog

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
