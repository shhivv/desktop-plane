#!/bin/bash
# Builds dist/Desktop Plane.app:
#   Contents/MacOS/DesktopPlane         menu bar app (runs the host)
#   Contents/MacOS/planed               headless host + image CLI (same engine)
#   Contents/Resources/DesktopPlaneAgent.app   the guest agent shipped into VMs
# Signs ad hoc with the virtualization entitlement. Set SIGN_ID to sign with a Developer ID.
set -euo pipefail
cd "$(dirname "$0")/.."
SIGN_ID="${SIGN_ID:--}"
VERSION="${VERSION:-0.1.0}"

swift build -c release --arch arm64
BIN=.build/arm64-apple-macosx/release
APP="dist/Desktop Plane.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DesktopPlane" "$BIN/planed" "$APP/Contents/MacOS/"

AGENT="$APP/Contents/Resources/DesktopPlaneAgent.app"
mkdir -p "$AGENT/Contents/MacOS"
cp "$BIN/GuestAgent" "$AGENT/Contents/MacOS/GuestAgent"
cat > "$AGENT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.desktopplane.agent</string>
  <key>CFBundleName</key><string>Desktop Plane Agent</string>
  <key>CFBundleExecutable</key><string>GuestAgent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.desktopplane.app</string>
  <key>CFBundleName</key><string>Desktop Plane</string>
  <key>CFBundleDisplayName</key><string>Desktop Plane</string>
  <key>CFBundleExecutable</key><string>DesktopPlane</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST

codesign --force --sign "$SIGN_ID" --identifier dev.desktopplane.agent --options runtime "$AGENT"
for exe in planed DesktopPlane; do
  codesign --force --sign "$SIGN_ID" --options runtime --entitlements scripts/entitlements.plist "$APP/Contents/MacOS/$exe"
done
codesign --force --sign "$SIGN_ID" --options runtime --entitlements scripts/entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
