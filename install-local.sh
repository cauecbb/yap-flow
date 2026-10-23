#!/usr/bin/env bash
#
# Builds Yap and installs it into /Applications, signed with the local
# "Yap Local Signing" certificate when the keychain has one (create it once with
# scripts/create-signing-cert.sh).
#
# Why the certificate: an ad-hoc signature changes on every rebuild, so macOS
# treats each build as a new app and forgets Microphone, Accessibility and the
# keychain grant. A stable certificate keeps the same identity across rebuilds.

set -euo pipefail

APP_NAME="Yap"
BUILD_DIR="build"
BUILT_APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
IDENTITY="Yap Local Signing"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

info() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }

cd "$(dirname "$0")"

[ -d "$DEVELOPER_DIR" ] || { echo "Xcode 26 or later is required (App Store). Elsewhere than /Applications? Set DEVELOPER_DIR."; exit 1; }
command -v xcodegen >/dev/null 2>&1 || { info "Installing XcodeGen"; brew install xcodegen; }

info "Building"
xcodegen generate >/dev/null
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" build \
  | grep -E "error:|BUILD" || true
[ -d "$BUILT_APP" ] || { echo "Build failed"; exit 1; }

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  info "Signing with $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$BUILT_APP"
else
  info "No \"$IDENTITY\" certificate: signed ad-hoc, so macOS will ask for permissions again after each rebuild"
fi

info "Installing"
killall "$APP_NAME" 2>/dev/null && sleep 1 || true
rm -rf "/Applications/$APP_NAME.app"
cp -R "$BUILT_APP" /Applications/
open "/Applications/$APP_NAME.app"
