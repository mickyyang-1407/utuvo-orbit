# User guide

Orbit lives in the menu bar. Click its icon for the panel, click outside to dismiss, or use Escape. The pin button keeps the panel open; pinning is session-only. The power button quits Orbit.

Everything below describes the **current local candidate (0.12.1 (18))**. It is a working build on this machine, not a published download — see [Versions and downloads](#versions-and-downloads) for what is actually released.

## Where to start: the help inside the app

Orbit carries its own offline guide. Nothing in it needs a network connection, and it reads the same with or without one.

- **⌘?** — opens the guide while Orbit is the frontmost app. This is an app-local shortcut; Orbit registers no global hotkey.
- **Help** in the menu-bar right-click menu.
- **Help** at the bottom of the workbench sidebar.
- **說明 / Help** in Settings → the last tab.

All four open the same content, in the app's current language. The Settings tab shows the guide inline; the other three open it in its own window, with a search field.

## Entry points

- **Panel** — click the menu-bar icon.
- **Settings** — the gear in the panel, or the right-click menu.
- **Workbench (the 18 tools)** — **Tools** in the panel, **隨手工具 / Tools** in the right-click menu, or a file dropped on the file shelf.
- **Actions** — the search field in the workbench, or **快捷動作 / Actions** in the right-click menu.
- **Screenshots** — **截圖與編修** in the right-click menu, or the Screenshots page of the workbench.
- **Help** — ⌘?, or **使用說明 / Help** in the right-click menu.

### The menu-bar right-click menu

Right-clicking the menu-bar icon opens a menu with: **Open UTUVO Orbit**, **Settings & Modules…**, **Tools…**, **Quick actions…**, **Screenshots & markup…**, **Help**, **Check for updates…** (or **Update in the App Store**), and **Quit UTUVO Orbit**. When the file shelf or the screenshot clothesline is switched on, it also offers **Shelf: show files** and **Clothesline: show/hide ⌃⌥T**.

The ⌘, / T / K shortcuts listed there are menu key equivalents: they work while that menu is open, and they are not registered as system-wide hotkeys. The only shortcut Orbit handles app-wide is ⌘?.

## One panel, preferences included

The top selector changes the **status detail** shown above the display controls:

- **總覽 / Overview:** volume, output device, mute, keep-awake, system and network summary. Confirmed warnings appear above the controls.
- **網路 / Network:** active interface, local IPv4 with Copy, receive/transmit activity and a recent trend.
- **系統 / System:** CPU, memory, battery on laptops and up to four peripheral batteries, lowest known charge first.

Display preferences are also in the panel, and they are **also** in the Settings window (General → 外觀與語言). The Settings window adds launch at login, the optional modules and the update preferences.

## The workbench: 18 pages

The sidebar lists every page. Each one is a small tool that runs on your Mac.

| Page | What it is for |
| --- | --- |
| 情境模式 / Modes | Save a set of display preferences as a mode and switch to it in one click |
| 快捷動作 / Actions | Search every tool, mode, audio scene, snippet and quick link, and run it |
| 音訊情境 / Audio scenes | Save output, input and volume as a scene, apply it in one click |
| 計時器 / Timer | Countdown or 25/5 Pomodoro, optionally keeping the Mac awake and notifying you |
| 世界時鐘 / World clock | Several cities side by side, with conversion |
| 聰明提醒 / Reminders | Alerts on low battery, charge target, a draining accessory or a lost connection (off until you enable it) |
| 剪貼簿 / Clipboard | A clipboard history you switch on yourself |
| 快速筆記 / Notes | Notes that save as you type, export to Markdown, and restore from Recently Deleted |
| 文字片段 / Snippets | Reusable text with a keyword, findable from the action search |
| 快捷連結 / Quick links | Your own list of links and URL templates |
| 檔案檢查 / File integrity | Check a file's checksum and read it back, to confirm a copy or backup is intact |
| 文字工具 / Text | Trim lines, format JSON, encode URLs, compare strings |
| 計算與換算 / Calculator | Arithmetic and unit conversion |
| 檔案處理 / Files | Look at files, copy paths, zip and unzip; originals are never overwritten |
| PDF | Merge, split, extract pages, rotate, collect images into a document |
| 截圖 / Screenshots | Capture through the macOS picker, then crop, mark up, redact and run OCR |
| 取色器 / Colors | Sample a colour from the screen, copy it as HEX or RGB, keep a palette |
| QR Code | Turn text into a QR code, and read codes out of an image or an edited screenshot |

Handing work from one tool to another is the point of the sidebar: a screenshot can be OCR'd and sent to the text tools, a clipboard entry can go straight to a QR code, a snippet can be pushed into a note, and a checked file path can be copied into one.

## Keyboard

| Keys | What they do |
| --- | --- |
| ⌘? | Open the offline guide (app-local, not a global hotkey) |
| ⌘Z / ⇧⌘Z | Undo, redo — in whatever field you are typing in |
| ⌘X ⌘C ⌘V ⌘A | Cut, copy, paste, select all |
| ⌘K | Search every action from inside the workbench |
| ⌘S | Save the note or snippet you are editing |
| Esc | Close the panel, pinned or not |
| ⌘Q | Quit UTUVO Orbit |
| ⌃⌥T | Show or hide the screenshot clothesline — only while that module is on |

Orbit replaces no system shortcut. Your own ⌘⇧3 / ⌘⇧4 / ⌘⇧5 screenshot keys keep working, and the clothesline only registers ⌃⌥T while you have switched it on.

## Where your data lives, and how to get it back

| Data | Where it is |
| --- | --- |
| Display preferences, theme, language, pin | The `com.utuvo.orbit` preferences domain |
| Notes | `~/Library/Application Support/UTUVO Orbit/Notes/notes.json` |
| Snippets | `~/Library/Application Support/UTUVO Orbit/Snippets/snippets.json` |
| Quick links | `~/Library/Application Support/UTUVO Orbit/Quicklinks/quicklinks.json` |
| Clipboard history | `~/Library/Application Support/UTUVO Orbit/Clipboard/` (only while the clipboard tool is on) |
| Clothesline copies | `~/Library/Application Support/UTUVO Orbit/Clothesline/` |
| Calculator history, world clock cities | The `com.utuvo.orbit` preferences domain |

**Drafts.** Notes and snippets save as you type. If something has not been saved when you quit, Orbit tells you and offers to keep editing or to quit without saving — it does not silently drop it.

**Damaged data.** If a file ever stops reading, Orbit keeps the damaged original, tells you, and offers **back up and reset** instead of overwriting anything.

**Backup and restore.** Notes, snippets and quick links each have **備份與匯入 / Backup and import** in their page: export a JSON backup to a folder you choose, and import one later. An import is previewed before it runs, and it only **adds** records — it never overwrites or deletes what you already have. Backups are plain text: keep them where only you can read them.

## Privacy: everything is opt-in

- **No account, no purchase, no analytics.** Orbit is free and MIT-licensed. The workbench runs on your Mac and does not call out to the network.
- **Launch at login** is off by default. Switching it on registers a login item that only puts the icon in the menu bar; no extra window opens.
- **The file shelf and the screenshot clothesline** are off by default. Switch them on in Settings → Modules.
- **Clipboard history, notifications and reminders** are off until you turn them on. Switching the clipboard off clears the history.
- **Updates** are only checked when you ask for them (or when you switch on the daily check), and an update is installed only after its signature verifies.
- **Screen capture** uses the macOS picker: you pick the window or content, and macOS asks you to confirm that selection. Orbit does not record the whole screen on its own. If you would rather not use the picker, take a screenshot with ⌘⇧3 / ⌘⇧4 and import it into the Screenshots page — the editing, OCR and export tools work the same way.
- **Quick links** open in your browser only when you ask them to.

## Language

Use the globe menu in the panel footer: **System**, **English**, or **繁體中文**. System follows your macOS language preferences and falls back to English for unsupported languages. The choice is saved and takes effect immediately, including the main menu, tooltips and accessibility labels. Device names stay exactly as reported.

## Display choices

| Control | Choices |
| --- | --- |
| 桌機外圈 / Desktop arc | CPU, external-power indication, hidden; desktop only |
| 顯示百分比 / Percentage text | Adds a number alongside the icon, when a value is available |
| 狀態色彩 / State colors | Color or monochrome glyph |
| 主題 / Theme | System, Light, Dark; the panel appearance |
| 選單列樣式 / Glyph | Combined or Classic |
| 中央內容 / Center | Network or Percentage; disabled in Classic mode |

The two percentage controls are independent. Center numbers require a valid reading. While charging, when a desktop arc represents power or is hidden, or when the machine/value is unknown, the center falls back to network state. There is no invented 0% or 100%.

## Sound and awake

Audio commands act on the selected current output. Some devices have hardware-only volume controls; Orbit reports that limit. A changed default device is checked before writing volume/mute.

Choose 30, 60 or 120 minutes and press 啟動 / Start. Stop ends it immediately; expiration or quitting also ends the assertion. Merely selecting a duration while inactive does not start keep-awake.

## Peripherals

The System detail shows batteries macOS exposes through HID properties. Names and percentages come from the device. A charging bolt requires an explicit charging value matched to the device's identity. Missing, conflicting or wrong-typed data stays unknown. It is not inferred from a USB cable.

## Versions and downloads

| Version | State |
| --- | --- |
| **0.4.2** | The stable download. Developer ID signed, Apple-notarized and stapled. This is what the "Releases" link gives you. |
| **0.9.1** | The published engineering prerelease (`v0.9.1-rc.1`). Signed, notarized and stapled, with the production update key and HTTPS appcast live. |
| **0.12.1 (18)** | The current local candidate: the workbench, the screenshot editor, the library backups and the offline guide. It is **not** published and **not** notarized yet, so there is no download for it. |

The features described above are the 0.12.1 candidate's. The 0.4.2 download has the menu-bar panel and the display preferences, not the workbench.

See [installing](INSTALL.md), [quick tools](TOOLS.md), [screenshots](TOOLS-SCREENSHOTS.md), [library backups](LIBRARY-BACKUPS.md) and [software updates](UPDATING.md).

## Limits

- Interface traffic is **not** a speed test or proof of internet reachability. Orbit does not probe external websites or read your Wi-Fi SSID.
- Memory is an estimate based on active, wired and compressed memory, not an exact duplicate of every Activity Monitor category.
- Keep-awake does not override a closed MacBook lid, explicit sleep, or all OS power decisions.
- Peripheral IORegistry properties are best-effort and can change with macOS/device firmware. No promise of support for every AirPods, iPhone or Bluetooth accessory.
- Unknown hardware remains unknown. Connected AC power or an external display does not turn a laptop into a desktop.
- Launch at login and automatic installation require the user's choice. Orbit does not hide the original system icons.
- The screenshot editor works on whatever you give it. Orbit never modifies the original file; exports are new files.

## Troubleshooting

**No icon:** check for space on the menu bar, particularly on notched displays. Quit any older copy before reopening.

**Nothing in the guide:** ⌘? opens it while Orbit is frontmost. The guide is bundled with the app, so it works with no network at all.

**No peripheral data:** the device may not publish readable properties. `UtuvoOrbit --diagnose` can help locally. Review and redact its output before sharing: it may contain model, interface and device details.

**Unexpected appearance:** choose System, then the explicit desired theme. macOS accessibility appearance settings can affect material rendering.

**Something will not save:** Orbit keeps the unreadable original and offers **back up and reset**. Use the **備份與匯入 / Backup and import** control on the page to export a JSON copy before resetting.
