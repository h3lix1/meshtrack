#!/usr/bin/env bash
# Build Meshtrack.app and package it as GitHub Release assets.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG_NAME="${TAG_NAME:-${GITHUB_REF_NAME:-}}"
if [[ -z "$TAG_NAME" ]]; then
    TAG_NAME="$(git describe --tags --exact-match 2>/dev/null || true)"
fi
if [[ -z "$TAG_NAME" ]]; then
    echo "TAG_NAME is required (or run from an exact release tag)" >&2
    exit 2
fi

VERSION="${TAG_NAME#v}"
BUILD_NUMBER="${MESHTRACK_BUILD:-${GITHUB_RUN_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}}"
DIST_DIR="${DIST_DIR:-dist}"
APP_PATH="$DIST_DIR/Meshtrack.app"
ZIP_NAME="Meshtrack-${TAG_NAME}-macOS.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
SHA_PATH="$ZIP_PATH.sha256"
NOTES_PATH="$DIST_DIR/release-notes.md"
SIGN_IDENTITY="${MESHTRACK_SIGN_IDENTITY:-}"
REQUIRE_SIGNING="${MESHTRACK_REQUIRE_SIGNING:-false}"
NOTARY_PROFILE="${MESHTRACK_NOTARY_PROFILE:-}"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

if [[ "$REQUIRE_SIGNING" == "true" && -z "$SIGN_IDENTITY" ]]; then
    echo "MESHTRACK_REQUIRE_SIGNING=true but MESHTRACK_SIGN_IDENTITY is not set" >&2
    exit 2
fi

echo "==> building Meshtrack.app for $TAG_NAME"
MESHTRACK_VERSION="$VERSION" \
MESHTRACK_BUILD="$BUILD_NUMBER" \
MESHTRACK_SIGN_IDENTITY="$SIGN_IDENTITY" \
APP_OUTPUT="$APP_PATH" \
    make app CONFIG=release

if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --verify --deep --strict "$APP_PATH"
    codesign -dv "$APP_PATH"
fi

notary_args=()
if [[ -n "$NOTARY_PROFILE" ]]; then
    notary_args=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    notary_args=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
elif [[ "$REQUIRE_SIGNING" == "true" ]]; then
    echo "Signing is required, but notarization credentials are missing" >&2
    echo "Set MESHTRACK_NOTARY_PROFILE or APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD" >&2
    exit 2
fi

if [[ ${#notary_args[@]} -gt 0 ]]; then
    NOTARY_ZIP="$DIST_DIR/notary-$ZIP_NAME"
    echo "==> submitting app for notarization"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" "${notary_args[@]}" --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    spctl --assess --type execute --verbose=4 "$APP_PATH"
    rm -f "$NOTARY_ZIP"
fi

echo "==> packaging $ZIP_NAME"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

(
    cd "$DIST_DIR"
    shasum -a 256 "$ZIP_NAME" > "$(basename "$SHA_PATH")"
)

if [[ ${#notary_args[@]} -gt 0 ]]; then
    SIGNING_NOTE="This build is Developer ID signed, notarized, and stapled."
elif [[ -n "$SIGN_IDENTITY" ]]; then
    SIGNING_NOTE="This build is Developer ID signed but not notarized."
else
    SIGNING_NOTE="This preview build is ad-hoc signed but not notarized. If macOS blocks the first launch, right-click Meshtrack.app and choose Open."
fi

cat > "$NOTES_PATH" <<EOF_NOTES
Meshtrack $TAG_NAME for macOS.

$SIGNING_NOTE

Checksum:

\`\`\`
$(cat "$SHA_PATH")
\`\`\`
EOF_NOTES

echo "✓ release assets ready:"
echo "  $ZIP_PATH"
echo "  $SHA_PATH"
echo "  $NOTES_PATH"
