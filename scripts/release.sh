#!/bin/bash
# Builds a signed, notarized dist/DesktopPlane-<version>.dmg that opens cleanly on any Mac.
#   SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=<profile> VERSION=0.2.0 scripts/release.sh
# NOTARY_PROFILE is a notarytool keychain profile, made once with:
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team> --password <app-specific password>
# Leave NOTARY_PROFILE unset to build and sign without notarizing.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_ID:?set SIGN_ID to a Developer ID Application identity (security find-identity -v -p codesigning)}"
VERSION="${VERSION:-0.2.0}"
export SIGN_ID VERSION

scripts/bundle.sh
APP="dist/Desktop Plane.app"
# Developer ID signatures need a secure timestamp.
codesign --force --sign "$SIGN_ID" --timestamp --identifier dev.desktopplane.agent --options runtime "$APP/Contents/Resources/DesktopPlaneAgent.app"
codesign --force --sign "$SIGN_ID" --timestamp --identifier dev.desktopplane.agent-core --options runtime "$APP/Contents/Resources/agent-core"
for exe in planed DesktopPlane; do
  codesign --force --sign "$SIGN_ID" --timestamp --options runtime --entitlements scripts/entitlements.plist "$APP/Contents/MacOS/$exe"
done
codesign --force --sign "$SIGN_ID" --timestamp --options runtime --entitlements scripts/entitlements.plist "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

DMG="dist/DesktopPlane-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Desktop Plane" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
else
  echo "Not notarized (NOTARY_PROFILE unset): Gatekeeper will warn on other Macs."
fi
echo "Built $DMG"
