#!/usr/bin/env bash
# Assemble a double-clickable Meshtrack.app from the SwiftPM MeshtrackApp executable.
# SwiftPM doesn't emit .app bundles, so we lay out the standard
# Contents/{MacOS,Resources} structure + an Info.plist (so the app gets a Dock icon,
# a proper menu-bar name, and a stable bundle id). Local builds are ad-hoc signed;
# release builds can pass MESHTRACK_SIGN_IDENTITY for Developer ID signing.
#
#   CONFIG=release|debug   (default release)   build configuration
#   MESHTRACK_VERSION      CFBundleShortVersionString (default 0.1.0)
#   MESHTRACK_BUILD        CFBundleVersion (default git commit count)
#   MESHTRACK_SIGN_IDENTITY
#                         Developer ID identity for distribution signing.
#   APP_OUTPUT             output app path (default Meshtrack.app)
#   make app                                   builds Meshtrack.app
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="Meshtrack"
EXE="MeshtrackApp"
BUNDLE_ID="${MESHTRACK_BUNDLE_ID:-org.meshtrack.app}"
SHORT_VERSION="${MESHTRACK_VERSION:-0.1.0}"
BUILD_VERSION="${MESHTRACK_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
MIN_MACOS_VERSION="${MESHTRACK_MIN_MACOS_VERSION:-26.0}"
SIGN_IDENTITY="${MESHTRACK_SIGN_IDENTITY:-}"
APP="${APP_OUTPUT:-$APP_NAME.app}"

echo "==> building $EXE ($CONFIG)"
swift build -c "$CONFIG" --product "$EXE"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$EXE" "$APP/Contents/MacOS/$EXE"

# SwiftPM resource bundles (e.g. SwiftProtobuf's privacy manifest) sit next to the
# binary; copy them where Bundle.module resolves inside an .app.
shopt -s nullglob
for bundle in "$BIN"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundleExecutable</key><string>$EXE</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_VERSION</string>
	<key>LSMinimumSystemVersion</key><string>$MIN_MACOS_VERSION</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Developer ID sign release builds when an identity is provided. Local builds fall
# back to ad-hoc signing for a stable local code identity.
if command -v codesign >/dev/null 2>&1; then
    if [[ -n "$SIGN_IDENTITY" ]]; then
        codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
        echo "==> Developer ID signed with $SIGN_IDENTITY"
    else
        if codesign --force --sign - "$APP" >/dev/null 2>&1; then
            echo "==> ad-hoc signed"
        else
            echo "⚠️  ad-hoc codesign failed (app still runs locally)"
        fi
    fi
fi

echo "✓ $APP ready — launch with:  open $APP   (or: make run-app)"
