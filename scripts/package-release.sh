#!/bin/bash
# Local packaging only. No upload, signing identity, or notarization service.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -m)" != arm64 ]]; then
  echo 'The published download targets Apple Silicon; package on arm64.' >&2
  exit 1
fi
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then bash scripts/build-app.sh; fi
APP="$PWD/dist/UTUVO Orbit.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
OUTPUT="$PWD/release/$VERSION"
mkdir -p "$OUTPUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/orbit-package.XXXXXX")
MOUNT="$WORK/volume"
cleanup() {
  if mount | grep -Fq " on $MOUNT "; then hdiutil detach "$MOUNT" -quiet || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Optional artwork metadata tooling is isolated from the application and source tree.
PYTHON="${PACKAGING_PYTHON:-}"
if [[ -z "$PYTHON" ]]; then
  python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" -q install 'ds-store==1.3.3' 'mac-alias==2.2.3'
  PYTHON="$WORK/venv/bin/python"
fi
codesign --verify --strict "$APP"
lipo -verify_arch arm64 "$APP/Contents/MacOS/UtuvoOrbit"
STEM="UTUVO-Orbit-$VERSION-arm64"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/$STEM.zip"

mkdir -p "$WORK/content/.background"
ditto "$APP" "$WORK/content/UTUVO Orbit.app"
ln -s /Applications "$WORK/content/Applications"
cp docs/assets/dmg-background.png "$WORK/content/.background/background.png"
hdiutil create -quiet -size 64m -fs HFS+ -volname 'UTUVO Orbit' -format UDRW \
  -srcfolder "$WORK/content" "$WORK/writable.dmg"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT" "$WORK/writable.dmg"
"$PYTHON" scripts/dmg-layout.py "$MOUNT"
sync
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$WORK/writable.dmg" -format UDZO -imagekey zlib-level=9 \
  -o "$OUTPUT/$STEM.dmg" -ov

SOURCE="$WORK/utuvo-orbit-$VERSION"
python3 scripts/export-source.py "$SOURCE"
python3 - "$SOURCE" "$OUTPUT/utuvo-orbit-$VERSION-source.zip" <<'PYZIP'
import sys, zipfile
from pathlib import Path
root = Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(root.rglob('*')):
        if file.is_file(): archive.write(file, str(file.relative_to(root.parent)))
PYZIP
(
  cd "$OUTPUT"
  shasum -a 256 "$STEM.dmg" "$STEM.zip" "utuvo-orbit-$VERSION-source.zip" > SHA256SUMS.txt
)
printf 'Release files: %s\n' "$OUTPUT"
