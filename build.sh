#!/bin/bash
# Builds EACapture.app (native SwiftUI wrapper around Silicondust's eacapture.php),
# universal (Apple silicon + Intel), with the built-in PHP from vendor/out.
#
# Usage: ./build.sh                 -> ./EACapture.app
#        APP_OUT=/some/dir/EACapture.app ./build.sh   -> build somewhere else
set -euo pipefail
cd "$(dirname "$0")"

# SwiftUI's @State macro needs the plugin that ships with full Xcode (not the
# Command Line Tools). Use it for this build without changing xcode-select.
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP="${APP_OUT:-EACapture.app}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target "$ARCH-apple-macos13.0" \
    -parse-as-library \
    -o "$TMP/EACapture-$ARCH" Sources/main.swift
done
lipo -create "$TMP/EACapture-arm64" "$TMP/EACapture-x86_64" -output "$APP/Contents/MacOS/EACapture"

# Built-in PHP (built by vendor/scripts/build-php.sh).
if [ -f vendor/out/php-arm64 ] && [ -f vendor/out/php-x86_64 ]; then
  lipo -create vendor/out/php-arm64 vendor/out/php-x86_64 -output "$APP/Contents/Helpers/php"
elif [ -f vendor/out/php-arm64 ]; then
  echo "WARNING: only the arm64 PHP exists; this build will not run its capture engine on Intel Macs." >&2
  cp vendor/out/php-arm64 "$APP/Contents/Helpers/php"
else
  echo "WARNING: no built-in PHP found in vendor/out; the app will fall back to a system PHP." >&2
  rmdir "$APP/Contents/Helpers"
fi
[ -f "$APP/Contents/Helpers/php" ] && chmod +x "$APP/Contents/Helpers/php"

cp src/eacapture.php "$APP/Contents/Resources/eacapture.php"
cp Icons/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>EACapture</string>
<key>CFBundleDisplayName</key><string>EACapture</string>
<key>CFBundleIdentifier</key><string>local.eacapture.mac</string>
<key>CFBundleExecutable</key><string>EACapture</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1.0.0</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>EACapture finds HDHomeRun tuners on your local network.</string>
</dict></plist>
EOF

# Ad-hoc signature for local use. package.sh re-signs with the Developer ID.
[ -f "$APP/Contents/Helpers/php" ] && codesign --force -s - "$APP/Contents/Helpers/php"
codesign --force -s - "$APP"
echo "Built $APP"
