# Install UTUVO Orbit / 安裝

## Apple Silicon download

Choose `UTUVO-Orbit-0.4.2-arm64.dmg`. Open it and drag **UTUVO Orbit.app** to **Applications**, then launch the app from Applications. The icon appears in the menu bar, not the Dock. Quit the older Orbit before replacing it.

ZIP alternative: expand `UTUVO-Orbit-0.4.2-arm64.zip`, then move the app into Applications. The ZIP and DMG contain the same build.

## Signing and the first launch

The official App and DMG are **Developer ID signed and Apple-notarized**. Both have stapled notarization tickets. The app inside the ZIP is also signed, notarized and stapled.

The signing identity is **Developer ID Application: MIN CHI YANG (RPNT54P79S)**. macOS may still show the usual confirmation that an app was downloaded from the internet. No Gatekeeper or quarantine changes are needed. Local builds made with `scripts/build-app.sh` remain ad-hoc signed; notarization applies to the official release downloads.

If you installed 0.4.1, download 0.4.2 and replace the old app: 0.4.1 has a menu-bar redraw loop that keeps one CPU core busy while idle. If macOS reports damage or an unidentified developer, verify the download against the latest checksum file and download it again from the official release.

**繁中摘要：** 官方 App 與 DMG 已完成 Developer ID 簽署、Apple 公證與公證票附加；ZIP 內的 App 亦同。開啟 DMG，拖曳到 Applications，再啟動即可。macOS 仍可能顯示一般的網路下載確認。若先前下載的是未公證版本，請重新下載 0.4.1 並替換；功能與版本不變，簽章及校驗碼已更新。

## Verify the download

Place the three release downloads and `SHA256SUMS.txt` in the same folder, then run:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

For a single file, run `shasum -a 256 UTUVO-Orbit-0.4.2-arm64.dmg` and compare its result with the matching line in the checksum file. A checksum establishes file equality, not publisher identity.

### Verify signing and notarization

After mounting the disk image:

```sh
spctl --assess --type open --context context:primary-signature --verbose=2 UTUVO-Orbit-0.4.2-arm64.dmg
xcrun stapler validate UTUVO-Orbit-0.4.2-arm64.dmg
spctl --assess --type execute --verbose=2 "/Volumes/UTUVO Orbit/UTUVO Orbit.app"
xcrun stapler validate "/Volumes/UTUVO Orbit/UTUVO Orbit.app"
```

Gatekeeper assessment should report `accepted` and `Notarized Developer ID`. `stapler` should report that validation worked. These are read-only checks; `stapler` requires Apple's command-line developer tools.

## Requirements

- Download: Apple Silicon (arm64).
- Source deployment target: macOS 14 or later.
- Liquid Glass: macOS 26 or later; older systems use native material controls.
- Validated UI environment for 0.4.2: macOS 27 on Apple Silicon.
- No administrator access, account, location, microphone or screen-recording permission is needed by Orbit.

## Update / remove

Quit Orbit, replace the app in Applications and reopen. Existing preferences remain in the app's own `com.utuvo.orbit` domain. To remove Orbit, quit it and move the app to Trash. Deleting the app does not automatically delete its preferences. Orbit does not install a login item, background daemon or browser extension.
