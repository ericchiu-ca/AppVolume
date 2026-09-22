#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/AppVolume.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/AppVolume"
BUNDLE_ID="com.ericchiu.AppVolume"

case "$MODE" in
  run|--verify|--debug|--logs|--telemetry) ;;
  *) echo "usage: $0 [run|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

# Stop only this project's already running bundle.
for pid in $(pgrep -x AppVolume || true); do
  command_path="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  if [[ "$command_path" == "$APP_BINARY" ]]; then kill -TERM "$pid" || true; fi
done
for attempt in $(seq 1 25); do
  found=0
  for pid in $(pgrep -x AppVolume || true); do
    if [[ "$(ps -p "$pid" -o comm= 2>/dev/null || true)" == "$APP_BINARY" ]]; then found=1; fi
  done
  if [[ "$found" == 0 ]]; then break; fi
  sleep 0.2
done
if [[ "$found" == 1 ]]; then
  echo "AppVolume did not exit after SIGTERM; refusing to replace its running bundle" >&2
  exit 1
fi

cd "$ROOT_DIR"
swift build --disable-sandbox
BUILD_BINARY="$(swift build --disable-sandbox --show-bin-path)/AppVolume"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Assets/AppIcon.icns" "$APP_CONTENTS/Resources/AppIcon.icns"
chmod +x "$APP_BINARY"
cat > "$APP_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>AppVolume</string>
  <key>CFBundleIdentifier</key><string>com.ericchiu.AppVolume</string>
  <key>CFBundleName</key><string>AppVolume</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleShortVersionString</key><string>0.1.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAudioCaptureUsageDescription</key><string>AppVolume captures audio from selected apps to control each app's playback volume. Audio stays in memory and is never saved or uploaded.</string>
</dict></plist>
PLIST

# Reuse a configured local signing identity when present; ad hoc is the fallback.
SIGNING_IDENTITY="${APPVOLUME_SIGNING_IDENTITY:--}"
codesign --force --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"

case "$MODE" in
  --debug) lldb -- "$APP_BINARY" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "AppVolume"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 2
    verified=0
    for pid in $(pgrep -x AppVolume || true); do
      if [[ "$(ps -p "$pid" -o comm= 2>/dev/null || true)" == "$APP_BINARY" ]]; then verified=1; fi
    done
    [[ "$verified" == 1 ]]
    echo "AppVolume running: $APP_BUNDLE"
    ;;
  *) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
