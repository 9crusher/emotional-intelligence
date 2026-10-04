#!/usr/bin/env bash
# Builds the SwiftUI app and assembles a signed (ad-hoc) .app bundle in app/build/.
# Needs only the Swift command-line tools, not Xcode.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$APP_DIR/.." && pwd)"
APP="$APP_DIR/build/Emotional Intelligence.app"

cd "$APP_DIR"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/EIApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EIApp"
sed "s|__REPO_PATH__|$REPO|" Resources/Info.plist > "$APP/Contents/Info.plist"
"$APP_DIR/scripts/make-icon.sh" "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --entitlements Resources/EIApp.entitlements "$APP"
echo "Built $APP"
