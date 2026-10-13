#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/tests/FramePresenterTests.app
mkdir -p "$APP"
xcrun clang -fobjc-arc -fmodules tests/EventPumpTests.m \
  scrcpy-app/VNCClient/ScrcpyCommonRuntime.m -framework Foundation -o build/tests/test-event-pump
build/tests/test-event-pump
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun clang -fobjc-arc -fmodules -isysroot "$SDK" -target arm64-apple-ios17.0-simulator \
  -Iporting/include -Iscrcpy-app/ADBClient tests/FramePresenterTests.m \
  scrcpy-app/ADBClient/ScrcpyFramePresenter.m \
  scrcpy-app/ADBClient/ScrcpyFrameQueue.m \
  scrcpy-app/ADBClient/ScrcpyMetalRenderer.m \
  -framework UIKit -framework AVFoundation -framework QuartzCore -framework CoreMedia -framework CoreVideo -framework Metal \
  -o "$APP/FramePresenterTests"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.scrcpy.frame-presenter-tests</string>
<key>CFBundleExecutable</key><string>FramePresenterTests</string>
<key>CFBundleName</key><string>Frame Presenter Tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>CADisableMinimumFrameDurationOnPhone</key><true/>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
DEVICE=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for a in d["devices"].values() for x in a if "iPad" in x["name"]))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
trap 'xcrun simctl shutdown "$DEVICE" || true' EXIT
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" com.scrcpy.frame-presenter-tests
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.scrcpy.frame-presenter-tests data)
for attempt in {1..30}; do
  if [ -f "$CONTAINER/Documents/presenter-results.json" ]; then
    cp "$CONTAINER/Documents/presenter-results.json" build/tests/presenter-results.json
    python3 -c 'import json; r=json.load(open("build/tests/presenter-results.json")); print(r); assert r["passed"], r'
    exit 0
  fi
  sleep 1
done
echo 'Presenter simulator tests did not produce a result' >&2
exit 1
