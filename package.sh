#!/bin/bash
# Builds a Developer ID-signed, notarized, stapled EACapture.dmg in ./dist.
#
#  1. builds a fresh universal app into ./dist (the live ./EACapture.app is NOT touched)
#  2. signs the built-in PHP, then the app (hardened runtime + secure timestamp)
#  3. notarizes and staples the app
#  4. builds the DMG from the stapled app, signs, notarizes and staples it
#
# Steps 3-4 upload to Apple's notary service using the keychain profile below.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="Developer ID Application: Matthew Keys (4ZCZZ298M8)"
PROFILE="pomodoro-notary"
DIST="dist"
APP="$DIST/EACapture.app"
DMG="$DIST/EACapture.dmg"
STAGE="$DIST/dmg-root"

rm -rf "$DIST"
mkdir -p "$DIST"
APP_OUT="$PWD/$APP" ./build.sh

echo "=== signing"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/php"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "=== notarizing the app"
ditto -c -k --keepParent "$APP" "$DIST/EACapture-app.zip"
xcrun notarytool submit "$DIST/EACapture-app.zip" --keychain-profile "$PROFILE" --wait | tee "$DIST/notarize-app.txt"
grep -q "status: Accepted" "$DIST/notarize-app.txt" || { echo "App notarization was not accepted."; exit 1; }
xcrun stapler staple "$APP"
rm -f "$DIST/EACapture-app.zip"

echo "=== building the DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "EACapture" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"

echo "=== notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait | tee "$DIST/notarize-dmg.txt"
grep -q "status: Accepted" "$DIST/notarize-dmg.txt" || { echo "DMG notarization was not accepted."; exit 1; }
xcrun stapler staple "$DMG"

echo "Built $PWD/$DMG"
