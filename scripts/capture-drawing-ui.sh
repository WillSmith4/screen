#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/preview/DrawingPreview.app build/screenshots
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -sdk "$SDK" -target arm64-apple-ios18.0-simulator \
  'scrcpy-app/Scrcpy Remote/DrawingToolkitOptions.swift' \
  'scrcpy-app/Scrcpy Remote/DrawingToolkitView.swift' tests/DrawingToolkitPreview.swift \
  -o build/preview/DrawingPreview.app/DrawingPreview
cat > build/preview/DrawingPreview.app/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.scrcpy.drawing-preview</string>
<key>CFBundleExecutable</key><string>DrawingPreview</string>
<key>CFBundleName</key><string>Drawing Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>18.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
DEVICE=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for a in d["devices"].values() for x in a if "iPad" in x["name"]))')
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" build/preview/DrawingPreview.app
xcrun simctl ui "$DEVICE" appearance light
xcrun simctl launch "$DEVICE" com.scrcpy.drawing-preview
sleep 3
xcrun simctl io "$DEVICE" screenshot build/screenshots/drawing-toolkit-light.png
xcrun simctl ui "$DEVICE" appearance dark
sleep 2
xcrun simctl io "$DEVICE" screenshot build/screenshots/drawing-toolkit-dark.png
xcrun simctl launch --terminate-running-process "$DEVICE" com.scrcpy.drawing-preview --pressure
sleep 3
xcrun simctl io "$DEVICE" screenshot build/screenshots/pressure-curve-dark.png
xcrun simctl shutdown "$DEVICE"
