#!/bin/bash
# Builds ORB.app (release) into ./build/ORB.app, ad-hoc signed with mic entitlement.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product OrbApp
BIN="$(swift build -c release --show-bin-path)/OrbApp"
APP="build/ORB.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ORB"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ORB</string>
<key>CFBundleDisplayName</key><string>ORB</string>
<key>CFBundleIdentifier</key><string>app.orb.local</string>
<key>CFBundleExecutable</key><string>ORB</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><false/>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>ORB listens to your voice locally to talk with your on-device AI. Audio never leaves this Mac.</string>
</dict></plist>
PL
cat > build/ORB.entitlements <<EN
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
EN
codesign --force --deep --sign - --entitlements build/ORB.entitlements "$APP"
echo "Built $APP"
