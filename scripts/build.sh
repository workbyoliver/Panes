#!/usr/bin/env bash
# Builds Panes.app into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/Panes.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Panes" "$APP/Contents/MacOS/Panes"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: compile the layered Icon Composer document when there is one.
if [ -d Resources/AppIcon.icon ]; then
  xcrun actool Resources/AppIcon.icon \
    --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist build/assetcatalog_info.plist \
    --errors --warnings --output-format human-readable-text | grep -vE "^/\* com.apple.actool.compilation-results \*/|\.(car|icns|plist)$|^$" || true
fi

# Sign with a development certificate when there is one: the Accessibility permission is
# tied to the signature, and an ad-hoc signature changes on every build, so macOS would
# forget the grant each time. Override with CODESIGN_IDENTITY.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"

echo "Built $APP (signed: $IDENTITY)"
