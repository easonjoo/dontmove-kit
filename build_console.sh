#!/bin/bash
# 构建 CellBridge Console.app（macOS 原生前端）
set -e
cd "$(dirname "$0")"
echo "编译 CellBridgeConsole.swift ..."
swiftc -O CellBridgeConsole.swift -o /tmp/CellBridgeConsole
APP="CellBridge Console.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp /tmp/CellBridgeConsole "$APP/Contents/MacOS/CellBridgeConsole"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CellBridge Console</string>
    <key>CFBundleDisplayName</key><string>CellBridge Console</string>
    <key>CFBundleIdentifier</key><string>local.cellbridge.console</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>CellBridgeConsole</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>10.13</string>
</dict>
</plist>
PLIST
echo "完成：$PWD/$APP"
