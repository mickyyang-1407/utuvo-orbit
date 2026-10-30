# Software updates

The direct-download edition uses Sparkle 2.10.1. The App Store target does not link Sparkle; its Updates page opens Orbit's Mac App Store page instead.

In Settings → Updates, automatic checks default to once per day. Automatic downloading and installation are opt-in. A manual Check for Updates action is also available from the status item's right-click menu. Sparkle owns these preferences and preserves the user's choices across launches. Update archives are verified before extraction, and the appcast is signed. No system profiling is enabled.

Settings → General contains Open at Login. It only registers `SMAppService.mainApp` after the user enables the switch. If macOS requires approval, the status explains this and offers an Open Login Items button. Returning from System Settings refreshes the switch from the actual system status.

## Release setup

The 0.9.1 (14) engineering candidate embeds the production Ed25519 public key and the HTTPS feed at `https://mickyyang-1407.github.io/utuvo-orbit/updates/appcast.xml`. The release is a candidate while native screenshot GUI acceptance remains incomplete. `Resources/UpdateConfiguration.plist` contains public configuration only. Never put a private key into the repository, a shell argument, or a release artifact.

The production key already exists in the login Keychain under `com.utuvo.orbit.sparkle`. Do not generate or replace it for routine releases. To inspect only its public key:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.utuvo.orbit.sparkle -p
```

The private key stays in the login Keychain. Its matching public key is in `Resources/UpdateConfiguration.plist`. Keep the feed URL under the controlled GitHub Pages product path. Keychain access may take time or require the owner’s authentication; never export the production private key to work around it.

Build with `REQUIRE_UPDATER=1 bash scripts/build-app.sh`. Run `bash scripts/sign-app.sh "/absolute/path/UTUVO Orbit.app"` to sign nested Sparkle executables, the framework and outer app with the existing UTUVO Developer ID identity, hardened runtime and secure timestamps. Notarize and staple the app using the existing approved release procedure. The local build script intentionally produces only an ad-hoc preview.

Prepare a signed archive and feed locally:

```sh
python3 scripts/prepare-update.py create \
  --app '/absolute/path/UTUVO Orbit.app' \
  --output '/absolute/path/update-candidate' \
  --download-url 'https://github.com/mickyyang-1407/utuvo-orbit/releases/download/v0.9.1-rc.1/UTUVO-Orbit-0.9.1-arm64.zip' \
  --notes '/absolute/path/release-notes.txt'
```

The tool verifies the app's update configuration, Developer ID team, nested signatures, stapling, and the signing account's public key before preparing the update. It signs and verifies both ZIP and appcast and records SHA-256 hashes. It does not publish anything. For later versions, place the existing signed appcast in the output folder before generating the next entry; old entries are preserved. Increment `CFBundleVersion` for every update.

### One artifact per release

The ZIP written by `scripts/prepare-update.py` is the authoritative update archive: the appcast signs its exact bytes. The packaging script must not build a second ZIP for the same version. A rebuilt archive can differ byte for byte from the signed one, and the appcast signature would then no longer match the published file.

The local release flow is:

1. Sign and staple the app.
2. Run `prepare-update.py create` with `--output 'release/<version>'` and a download URL whose file name is `UTUVO-Orbit-<version>-arm64.zip`. This writes the authoritative ZIP, the signed appcast and the update hashes into that folder.
3. Package the DMG, the source ZIP and the checksums without touching that ZIP:

```sh
SKIP_BUILD=1 SKIP_APP_ZIP=1 APP_PATH='/absolute/path/UTUVO Orbit.app' bash scripts/package-release.sh
```

4. Verify the published file: the ZIP hash against `update-sha256.json` and against `SHA256SUMS.txt`, and the enclosure length in the appcast against the ZIP on disk.

`scripts/package-release.sh` refuses to run when an output artifact already exists and never overwrites or deletes one. With `SKIP_APP_ZIP=1` the prepared ZIP is kept exactly as prepared — same bytes, same size, same modification time — and the script checks it again after packaging. Plain offline packaging still produces its own ZIP for a version that has no signed update archive yet; it must not be used to replace one that does.

Publish the matching ZIP first, then place the signed `appcast.xml` at the configured HTTPS feed URL. Never edit the XML after signing. Verify the published file hashes and test a real update in an isolated installation before announcing it.

People using releases before 0.6 need to install an updater-enabled version once. An older binary with no updater cannot bootstrap this feature itself.

## Local verification

`swift test --filter LifecycleSettingsTests` uses fake login/update drivers and never registers system login items or starts a production updater. Fixture rendering uses `--settings-preview` and `--fixture ... --panel-preview`; these use fake preferences, audio and power backends. Module side effects are disabled in Settings previews.

The 2026-10-28 integration evidence separately exercises real Sparkle with a disposable signing key, a unique fixture bundle ID and loopback HTTP feed: a damaged archive is refused while the original version remains installed; a valid signed feed/archive installs and relaunches version 2. Production uses HTTPS; the HTTP exception exists only in the disposable fixture app and is absent from Orbit.


## HTTPS acceptance, 2026-10-29

The separately identified `com.utuvo.orbit.updateverification20261029` edition compiles the real `OrbitUpdateModel` and `SparkleUpdateDriver` with `ORBIT_UPDATE_VERIFICATION`. Its early startup path never constructs normal Orbit preferences, hardware controllers or optional modules. The verification startup code is absent from normal builds and from the App Store edition.

Both test editions were signed with UTUVO Developer ID and notarized. Their embedded production public key matches the normal app. The signed test feed and archives are served over public HTTPS under the separate `updates/verification-20261029/` path. A deliberately damaged archive was refused, leaving build 13 installed. With automatic updates enabled and only the isolated suite’s last-check date moved into the past, relaunch triggered a background check and download without a manual check. The cached ZIP hash matched the signed archive. Install and Relaunch replaced build 13 with build 14, the new app wrote its launch receipt, and the window showed 0.9.1 (14). Automatic-update preferences survived. A further check reported that the version was current.

This verifies the real Orbit updater in an isolated bundle. It does not claim an upgrade was performed on the daily-use Orbit installation. Native screenshot acceptance is separate. On 2026-10-30, an isolated generated test-card window was captured through the system picker and passed local editing, PNG, OCR and copy readback checks. That scoped result does not establish unrestricted display capture or the later complete-App acceptance matrix. The earlier -3801 result came from a different one-shot capture path; it does not show that the system picker requires broad screen-recording permission or owner authentication.
