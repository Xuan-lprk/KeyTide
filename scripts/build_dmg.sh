#!/bin/bash
# Build local macOS distribution artifacts. Does not launch or publish the app.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

RELEASE_VERSION="${KEYSTATS_RELEASE_VERSION:-}"
if [[ -n "$RELEASE_VERSION" && ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "KEYSTATS_RELEASE_VERSION must be numeric X.Y.Z." >&2
    exit 1
fi

"$SCRIPT_DIR/check_vendored_helper.sh"
# Keep the current manual-update distribution contract explicit.
python3 - <<'PYTHON'
import plistlib
with open("Keytide/Info.plist", "rb") as source:
    info = plistlib.load(source)
if info.get("KeyStatsInAppUpdatesEnabled") is not False or info.get("SUEnableAutomaticChecks") is not False:
    raise SystemExit("Manual release packaging requires in-app and automatic updates to remain disabled.")
PYTHON

# Each run owns one directory; never delete build/ or other QA evidence.
PACKAGING_DIR="$PROJECT_DIR/build/ReleasePackaging"
OUTPUT_DIR="$PACKAGING_DIR/output"
mkdir -p "$PACKAGING_DIR"
RUN_DIR="$(mktemp -d "$PACKAGING_DIR/run.XXXXXX")"
STAGING_DIR="$RUN_DIR/dmg"
ARCHIVE_PATH="$RUN_DIR/Keytide.xcarchive"
mkdir -p "$STAGING_DIR"
echo "Packaging log and intermediate files: $RUN_DIR"

VERSION_SETTING=()
if [[ -n "$RELEASE_VERSION" ]]; then
    VERSION_SETTING=("MARKETING_VERSION=$RELEASE_VERSION")
fi
xcodebuild -project Keytide.xcodeproj \
    -scheme Keytide -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$RUN_DIR/DerivedData" \
    -archivePath "$ARCHIVE_PATH" \
    archive CODE_SIGN_IDENTITY="-" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    "${VERSION_SETTING[@]}" 2>&1 | tee "$RUN_DIR/xcodebuild.log"

APP_PATH="$ARCHIVE_PATH/Products/Applications/Keytide.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Archive did not contain Keytide.app: $APP_PATH" >&2
    exit 1
fi

ditto "$APP_PATH" "$STAGING_DIR/Keytide.app"
"$SCRIPT_DIR/embed_vendored_helper.sh" "$STAGING_DIR/Keytide.app"
"$SCRIPT_DIR/sign_app.sh" "$STAGING_DIR/Keytide.app"

# A UI-only release must retain the vendored Helper identity after packaging.
EXPECTED_HASH="$(tr -d '[:space:]' < vendor/KeyStatsHelper.cdhash.txt)"
ACTUAL_HASH="$(codesign -d -vvv "$STAGING_DIR/Keytide.app/Contents/Resources/KeyStatsHelper.app" 2>&1 | awk -F= '/^CDHash=/ {print $2}')"
if [[ -z "$ACTUAL_HASH" || "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
    echo "Packaged Helper cdhash differs from vendor; stop for signature/permission review." >&2
    exit 1
fi

# Both distribution formats contain the very same staged, signed app.
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname Keytide -srcfolder "$STAGING_DIR" \
    -ov -format UDZO "$RUN_DIR/Keytide.dmg"
ditto -c -k --sequesterRsrc --keepParent \
    "$STAGING_DIR/Keytide.app" "$RUN_DIR/Keytide.zip"
(
    cd "$RUN_DIR"
    shasum -a 256 Keytide.dmg Keytide.zip > SHA256SUMS
)
mkdir -p "$OUTPUT_DIR"
cp "$RUN_DIR/Keytide.dmg" "$RUN_DIR/Keytide.zip" "$RUN_DIR/SHA256SUMS" "$OUTPUT_DIR/"
echo "Local artifacts ready: $OUTPUT_DIR (ad-hoc signed; not notarized)"
