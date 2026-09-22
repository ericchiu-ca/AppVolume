#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.1.0"
RELEASE_DIR="$ROOT_DIR/dist/release"
APP_BUNDLE="$RELEASE_DIR/AppVolume.app"
ARCHIVE="$RELEASE_DIR/AppVolume-$VERSION-macos.zip"
SIGNING_IDENTITY="${APPVOLUME_RELEASE_SIGNING_IDENTITY:-Developer ID Application: Zirui Qiu (A9A5LS66BT)}"

cd "$ROOT_DIR"
swift build -c release --disable-sandbox
BUILD_BINARY="$(swift build -c release --disable-sandbox --show-bin-path)/AppVolume"

rm -rf "$APP_BUNDLE" "$ARCHIVE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/AppVolume"
cp "$ROOT_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>AppVolume</string>
  <key>CFBundleIdentifier</key><string>com.ericchiu.AppVolume</string>
  <key>CFBundleName</key><string>AppVolume</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAudioCaptureUsageDescription</key><string>AppVolume captures audio from selected apps to control each app's playback volume. Audio stays in memory and is never saved or uploaded.</string>
</dict></plist>
PLIST

codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [[ -n "${APPVOLUME_NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE"
  xcrun notarytool submit "$ARCHIVE" --keychain-profile "$APPVOLUME_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  rm "$ARCHIVE"
fi

ditto -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE"
shasum -a 256 "$ARCHIVE"
echo "Release archive: $ARCHIVE"
