#!/usr/bin/env bash
# Build a distributable SoundConnect.app: universal (arm64 + x86_64), ad-hoc signed, zipped.
#   scripts/release.sh            -> dist/SoundConnect-<version>.dmg and .zip (+ .sha256)
#
# Ad-hoc on purpose: a personal "Apple Development" certificate embeds its owner's name/email in
# the signature and isn't valid for distribution anyway. Without a Developer ID + notarization,
# users approve the app once via System Settings > Privacy & Security > Open Anyway.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -f vendor/SonyHeadphonesClient/CMakeLists.txt ] || git submodule update --init --recursive
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
MDR="$ROOT/build/mdr-universal"

echo "==> libmdr (universal)"
cmake -S vendor/SonyHeadphonesClient -B "$MDR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DMDR_BUILD_CLIENT=OFF -DMDR_BUILD_TESTING=OFF -DMDR_BUILD_SHARED=OFF \
  -DMDR_BUILD_WITH_IPO=OFF -DMDR_BT_BLE_SUPPORT=OFF >/dev/null
cmake --build "$MDR"

echo "==> SoundConnect (universal)"
export MDR_BUILD_DIR="$MDR"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SoundConnect"

APP="dist/SoundConnect.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SoundConnect"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "==> verify"
lipo -archs "$APP/Contents/MacOS/SoundConnect"
codesign -dv "$APP" 2>&1 | grep -E 'Signature|Identifier'

ZIP="dist/SoundConnect-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> DMG"
# dmgbuild writes the Finder layout (.DS_Store) directly, so no Finder scripting is needed.
# Installed into a throwaway venv to keep the system Python clean.
VENV="build/dmgbuild-venv"
[ -x "$VENV/bin/dmgbuild" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q dmgbuild; }
DMG="dist/SoundConnect-$VERSION.dmg"
"$VENV/bin/dmgbuild" -s scripts/dmg-settings.py -D app="$APP" "SoundConnect" "$DMG" >/dev/null

(cd dist && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" | tee SHA256SUMS.txt)
echo "==> $DMG"
echo "==> $ZIP"
