#!/bin/bash
# Build LiteMonitor.app dari main.swift
# Syarat: Xcode Command Line Tools  →  xcode-select --install
set -e
cd "$(dirname "$0")"

APP="LiteMonitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ Compile..."
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/LiteMonitor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LiteMonitor</string>
    <key>CFBundleDisplayName</key><string>LiteMonitor</string>
    <key>CFBundleIdentifier</key><string>id.local.litemonitor</string>
    <key>CFBundleExecutable</key><string>LiteMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "▶ Codesign (ad-hoc)..."
codesign --force --sign - "$APP"

echo "✅ Selesai: $APP"
echo "   Pindahkan ke Applications:  mv $APP /Applications/ && open /Applications/$APP"
