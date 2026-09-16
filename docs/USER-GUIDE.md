# User guide

Orbit lives in the menu bar. Click its icon for the panel, click outside to dismiss, or use Escape. The pin button keeps the panel open; pinning is session-only. The power button quits Orbit. Right-click the icon for a small Open/Quit menu.

## One panel, preferences included

The top selector changes the **status detail** shown above the display controls:

- **總覽 / Overview:** volume, output device, mute, keep-awake, system and network summary. Confirmed warnings appear above the controls.
- **網路 / Network:** active interface, local IPv4 with Copy, receive/transmit activity and a recent trend.
- **系統 / System:** CPU, memory, battery on laptops and up to four peripheral batteries, lowest known charge first.

Display preferences are always below the detail area; there is no separate settings page.

## Language

Use the globe menu in the footer: **System**, **English**, or **繁體中文**. System follows your macOS language preferences and falls back to English for unsupported languages. The choice is saved and takes effect immediately, including menus, tooltips and accessibility labels. Device names stay exactly as reported.

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

## Limits

- Interface traffic is **not** a speed test or proof of internet reachability. Orbit does not probe external websites or read your Wi-Fi SSID.
- Memory is an estimate based on active, wired and compressed memory, not an exact duplicate of every Activity Monitor category.
- Keep-awake does not override a closed MacBook lid, explicit sleep, or all OS power decisions.
- Peripheral IORegistry properties are best-effort and can change with macOS/device firmware. No promise of support for every AirPods, iPhone or Bluetooth accessory.
- Unknown hardware remains unknown. Connected AC power or an external display does not turn a laptop into a desktop.
- Orbit does not hide the original system icons, start at login, or update itself automatically.

## Troubleshooting

**No icon:** check for space on the menu bar, particularly on notched displays. Quit any older copy before reopening.

**No peripheral data:** the device may not publish readable properties. `UtuvoOrbit --diagnose` can help locally. Review and redact its output before sharing: it may contain model, interface and device details.

**Unexpected appearance:** choose System, then the explicit desired theme. macOS accessibility appearance settings can affect material rendering.
