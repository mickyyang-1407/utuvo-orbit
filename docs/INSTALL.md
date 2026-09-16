# Install UTUVO Orbit / 安裝

## Apple Silicon download

Choose `UTUVO-Orbit-0.4.1-arm64.dmg`. Open it and drag **UTUVO Orbit.app** to **Applications**, then launch the app from Applications. The icon appears in the menu bar, not the Dock. Quit the older Orbit before replacing it.

ZIP alternative: expand `UTUVO-Orbit-0.4.1-arm64.zip`, then move the app into Applications. The ZIP and DMG contain the same build.

## Signing and the first launch

This build is **ad-hoc signed, not Developer ID signed or Apple-notarized**. A valid ad-hoc signature checks bundle integrity; it does not prove an Apple-verified developer identity. Gatekeeper can block software downloaded from the internet.

Only if you trust this release, use the per-app option macOS offers in **System Settings → Privacy & Security → Open Anyway** after the blocked launch. Follow Apple's current [instructions for opening apps safely](https://support.apple.com/en-us/102445). If that option is unavailable or your Mac is managed, use a source build or contact your administrator. Do not disable Gatekeeper or run a blanket quarantine-removal command.

**繁中摘要：** 開啟 DMG，將 Orbit 拖到 Applications，再從 Applications 啟動。本包尚未公證，首次啟動可能被擋；只有在信任下載來源時，依 macOS「隱私權與安全性」提供的個別 App 開啟選項操作。不要關閉 Gatekeeper。

## Verify the download

Place the three release downloads and `SHA256SUMS.txt` in the same folder, then run:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

For a single file, run `shasum -a 256 UTUVO-Orbit-0.4.1-arm64.dmg` and compare its result with the matching line in the checksum file. A checksum establishes file equality, not publisher identity.

## Requirements

- Download: Apple Silicon (arm64).
- Source deployment target: macOS 14 or later.
- Liquid Glass: macOS 26 or later; older systems use native material controls.
- Validated UI environment for 0.4.1: macOS 27 on Apple Silicon.
- No administrator access, account, location, microphone or screen-recording permission is needed by Orbit.

## Update / remove

Quit Orbit, replace the app in Applications and reopen. Existing preferences remain in the app's own `com.utuvo.orbit` domain. To remove Orbit, quit it and move the app to Trash. Deleting the app does not automatically delete its preferences. Orbit does not install a login item, background daemon or browser extension.
