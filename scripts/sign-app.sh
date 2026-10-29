#!/bin/bash
# Sign a staged Orbit app with the existing Developer ID. Does not publish or notarize.
set -euo pipefail
APP="${1:?Pass the staged .app path}"
IDENTITY="${ORBIT_SIGNING_IDENTITY:-Developer ID Application: MIN CHI YANG (RPNT54P79S)}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
test -f "$APP/Contents/MacOS/UtuvoOrbit"
test -d "$FRAMEWORK"
for COMPONENT in "$FRAMEWORK/XPCServices/Downloader.xpc" "$FRAMEWORK/XPCServices/Installer.xpc" "$FRAMEWORK/Updater.app" "$FRAMEWORK/Autoupdate"; do
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$COMPONENT"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
