#!/bin/bash
# Local packaging only. APP_PATH may point to an already signed/stapled app.
# This script does not upload artifacts or call the notarization service.
#
# Release artifacts are never overwritten. The authoritative signed update ZIP
# is produced by scripts/prepare-update.py; SKIP_APP_ZIP=1 reuses that ZIP
# verbatim (same bytes, same mtime) instead of rebuilding it, so the appcast
# signature over the ZIP stays valid.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'packaging refused: %s\n' "$1" >&2; exit 1; }

# Content hash, mtime (ns) and size of one file.
fingerprint() {
  python3 - "$1" <<'PY'
import hashlib, os, sys
with open(sys.argv[1], 'rb') as handle:
    digest = hashlib.sha256(handle.read()).hexdigest()
info = os.stat(sys.argv[1])
print(f'{digest} {info.st_mtime_ns} {info.st_size}')
PY
}

if [[ "$(uname -m)" != arm64 ]]; then
  echo 'The published download targets Apple Silicon; package on arm64.' >&2
  exit 1
fi
if [[ "${SKIP_BUILD:-0}" != 1 ]]; then REQUIRE_UPDATER=1 bash scripts/build-app.sh; fi
APP="${APP_PATH:-$PWD/dist/UTUVO Orbit.app}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
python3 scripts/prepare-update.py validate-app "$APP"
OUTPUT="$PWD/release/$VERSION"
STEM="UTUVO-Orbit-$VERSION-arm64"
APP_ZIP="$OUTPUT/$STEM.zip"
DMG="$OUTPUT/$STEM.dmg"
SOURCE_ZIP="$OUTPUT/utuvo-orbit-$VERSION-source.zip"
CHECKSUMS="$OUTPUT/SHA256SUMS.txt"
SKIP_APP_ZIP="${SKIP_APP_ZIP:-0}"

# Fail closed before anything is written: an existing artifact, or a symlink in
# an output path, is never overwritten, replaced or deleted.
if [[ -L "$PWD/release" ]]; then fail "release/ is a symlink."; fi
if [[ -L "$OUTPUT" ]]; then fail "release/$VERSION is a symlink."; fi
for artifact in "$APP_ZIP" "$DMG" "$SOURCE_ZIP" "$CHECKSUMS"; do
  if [[ -L "$artifact" ]]; then fail "refusing to write through the symlink $artifact."; fi
  if [[ -e "$artifact" ]]; then
    if [[ "$SKIP_APP_ZIP" == 1 && "$artifact" == "$APP_ZIP" ]]; then continue; fi
    fail "refusing to overwrite the existing artifact $artifact; remove it yourself first."
  fi
done
if [[ "$SKIP_APP_ZIP" == 1 ]]; then
  [[ -f "$APP_ZIP" ]] || fail "SKIP_APP_ZIP=1 needs the prepared update ZIP at $APP_ZIP."
  python3 -c 'import sys; sys.exit(0 if open(sys.argv[1], "rb").read(2) == b"PK" else 1)' "$APP_ZIP" \
    || fail "$APP_ZIP is not a ZIP archive."
  APP_ZIP_FINGERPRINT=$(fingerprint "$APP_ZIP")
fi

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
codesign --verify --deep --strict "$APP"
lipo -verify_arch arm64 "$APP/Contents/MacOS/UtuvoOrbit"
if [[ "$SKIP_APP_ZIP" == 1 ]]; then
  echo "Reusing the prepared update ZIP: $APP_ZIP"
else
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_ZIP"
fi

mkdir -p "$WORK/content/.background"
ditto "$APP" "$WORK/content/UTUVO Orbit.app"
ln -s /Applications "$WORK/content/Applications"
cp docs/assets/dmg-background.png "$WORK/content/.background/background.png"
hdiutil create -quiet -size 160m -fs HFS+ -volname 'UTUVO Orbit' -format UDRW \
  -srcfolder "$WORK/content" "$WORK/writable.dmg"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT" "$WORK/writable.dmg"
"$PYTHON" scripts/dmg-layout.py "$MOUNT"
sync
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$WORK/writable.dmg" -format UDZO -imagekey zlib-level=9 \
  -o "$DMG"

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
if [[ "$SKIP_APP_ZIP" == 1 ]]; then
  [[ "$(fingerprint "$APP_ZIP")" == "$APP_ZIP_FINGERPRINT" ]] \
    || fail "the prepared update ZIP changed during packaging."
fi
printf 'Release files: %s\n' "$OUTPUT"
