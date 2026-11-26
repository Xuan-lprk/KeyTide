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
if info.get("KeytideInAppUpdatesEnabled") is not False or info.get("SUEnableAutomaticChecks") is not False:
    raise SystemExit("Manual release packaging requires in-app and automatic updates to remain disabled.")
PYTHON

# Each run owns one directory; never delete build/ or other QA evidence.
PACKAGING_DIR="$PROJECT_DIR/build/ReleasePackaging"
OUTPUT_DIR="$PACKAGING_DIR/output"
mkdir -p "$PACKAGING_DIR"
RUN_DIR="$(mktemp -d "$PACKAGING_DIR/run.XXXXXX")"
# File providers may add Finder metadata to transient signed bundles.
TEMP_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keytide-package.XXXXXX")"
trap 'rm -rf "$TEMP_BUILD_DIR"' EXIT
STAGING_DIR="$TEMP_BUILD_DIR/dmg"
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
    -derivedDataPath "$TEMP_BUILD_DIR/DerivedData" \
    -archivePath "$ARCHIVE_PATH" \
    archive CODE_SIGN_IDENTITY="-" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    "${VERSION_SETTING[@]}" 2>&1 | tee "$RUN_DIR/xcodebuild.log"

APP_PATH="$ARCHIVE_PATH/Products/Applications/Keytide.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Archive did not contain Keytide.app: $APP_PATH" >&2
    exit 1
fi

# The Release target embeds the signed vendor before Xcode signs the outer app.
# Stage that archive verbatim and reject a foreign app or Helper before packaging.
STAGED_APP="$STAGING_DIR/Keytide.app"
STAGED_HELPER="$STAGED_APP/Contents/Resources/KeytideHelper.app"
ditto --norsrc --noextattr --noacl "$APP_PATH" "$STAGED_APP"
if [[ "$(plutil -extract CFBundleIdentifier raw "$STAGED_APP/Contents/Info.plist")" != com.xuanlprk.KeyTide ||
      "$(plutil -extract CFBundleIdentifier raw "$STAGED_HELPER/Contents/Info.plist")" != com.xuanlprk.KeyTide.helper ]]; then
    echo "Unexpected Release app or Helper bundle identifier." >&2
    exit 1
fi
if ! cmp -s vendor/KeytideHelper.app/Contents/MacOS/KeytideHelper "$STAGED_HELPER/Contents/MacOS/KeytideHelper"; then
    echo "Archived Helper executable differs from the signed vendor." >&2
    exit 1
fi
LINKED_LIBRARIES="$(otool -arch all -L "$STAGED_APP/Contents/MacOS/Keytide")"
if [[ -e "$STAGED_APP/Contents/Frameworks/Sparkle.framework" || "$LINKED_LIBRARIES" == *Sparkle.framework* ]]; then
    echo "Manual-update builds must not embed or link Sparkle." >&2
    exit 1
fi
xcrun lipo "$STAGED_APP/Contents/MacOS/Keytide" -verify_arch arm64 x86_64
xcrun lipo "$STAGED_HELPER/Contents/MacOS/KeytideHelper" -verify_arch arm64 x86_64
codesign --verify --deep --strict --all-architectures -R='identifier "com.xuanlprk.KeyTide"' "$STAGED_APP"
codesign --verify --strict --all-architectures -R='identifier "com.xuanlprk.KeyTide.helper"' "$STAGED_HELPER"

# Both distribution formats contain the very same staged, signed app.
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname Keytide -srcfolder "$STAGING_DIR" \
    -ov -format UDZO "$RUN_DIR/Keytide.dmg"
ditto -c -k --norsrc --noextattr --noacl --keepParent \
    "$STAGING_DIR/Keytide.app" "$RUN_DIR/Keytide.zip"
(
    cd "$RUN_DIR"
    shasum -a 256 Keytide.dmg Keytide.zip > SHA256SUMS
)
mkdir -p "$OUTPUT_DIR"
cp "$RUN_DIR/Keytide.dmg" "$RUN_DIR/Keytide.zip" "$RUN_DIR/SHA256SUMS" "$OUTPUT_DIR/"
echo "Local artifacts ready: $OUTPUT_DIR (ad-hoc signed; not notarized)"
