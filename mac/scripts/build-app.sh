#!/bin/bash
# Builds mac/dist/USB Audio Bridge.app, bundles the Android APK, and signs it.
# SIGN_IDENTITY overrides the signing identity (default: first "Apple Development" cert, else ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep the builder's home path out of assert() file names in the vendored C code.
swift build -c release -Xcc "-fmacro-prefix-map=$(cd .. && pwd)=."
APP="dist/USB Audio Bridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/UsbAudioBridge "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

APK=../android/app/build/outputs/apk/release/app-release.apk
if [ -f "$APK" ]; then
  cp "$APK" "$APP/Contents/Resources/UsbAudioBridge.apk"
else
  echo "note: $APK not found; the helper will not be able to install the Android app by itself" >&2
fi

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "built $APP (signed with: $IDENTITY)"
