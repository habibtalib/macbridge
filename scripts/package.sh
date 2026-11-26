#!/bin/bash
# Builds a Release copy of MacBridge and zips it for copying to another Mac.
#
#   DEVELOPMENT_TEAM=XXXXXXXXXX scripts/package.sh   # development-signed zip in dist/
#   NOTARY_PROFILE=name scripts/package.sh
#       also notarises and staples; needs a "Developer ID Application"
#       certificate and a keychain profile made with
#       `xcrun notarytool store-credentials <name>`.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple team ID}"

xcodegen generate >/dev/null
args=(-project MacBridge.xcodeproj -scheme MacBridge -configuration Release
      -derivedDataPath build -destination 'platform=macOS,arch=arm64')
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  args+=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application"
         "OTHER_CODE_SIGN_FLAGS=--timestamp")
fi
xcodebuild "${args[@]}" build | grep -E "error|BUILD" || true

app=build/Build/Products/Release/MacBridge.app
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
mkdir -p dist
zip="dist/MacBridge-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$app"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
fi
echo "$zip"
