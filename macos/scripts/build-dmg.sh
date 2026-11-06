#!/usr/bin/env bash
# Builds a universal ExpandDisplay.app and packages it into build/ExpandDisplay.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD_NUMBER:-1}"

swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/ExpandDisplay"

rm -rf build
APP="build/ExpandDisplay.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ExpandDisplay"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# Ad-hoc signature (no Apple Developer ID available in CI).
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "ExpandDisplay" -srcfolder build/dmg -ov -format UDZO build/ExpandDisplay.dmg
echo "Built build/ExpandDisplay.dmg"
