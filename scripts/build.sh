#!/usr/bin/env bash
# Build libmdr (from the SonyHeadphonesClient submodule) + the SwiftUI app, and assemble SoundConnect.app.
#   scripts/build.sh            # release build -> build/SoundConnect.app
#   scripts/build.sh --run      # ...and launch it
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f vendor/SonyHeadphonesClient/CMakeLists.txt ]; then
  git submodule update --init --recursive
fi

echo "==> libmdr (CMake)"
cmake -S vendor/SonyHeadphonesClient -B build/mdr -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DMDR_BUILD_CLIENT=OFF -DMDR_BUILD_TESTING=OFF -DMDR_BUILD_SHARED=OFF \
  -DMDR_BUILD_WITH_IPO=OFF -DMDR_BT_BLE_SUPPORT=OFF >/dev/null
cmake --build build/mdr

echo "==> SoundConnect (SwiftPM)"
swift build -c release

APP="build/SoundConnect.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/SoundConnect" "$APP/Contents/MacOS/SoundConnect"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Sign with a real identity when available: TCC keys the Bluetooth grant on the signature, and an
# ad-hoc signature changes every build (=> macOS re-prompts after each rebuild).
IDENTITY="${SOUNDCONNECT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "    signed with ${IDENTITY:-ad-hoc}"
echo "==> $APP"

if [ "${1:-}" = "--run" ]; then
  # Quit politely so the app releases its Bluetooth channel before the new build opens it.
  osascript -e 'tell application id "dev.soundconnect.mac" to quit' 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x SoundConnect >/dev/null || break; sleep 0.3; done
  pkill -x SoundConnect 2>/dev/null || true
  sleep 1
  open "$APP"
fi
