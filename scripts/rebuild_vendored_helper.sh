#!/bin/bash
# Build, sign, and vendor KeytideHelper.app into vendor/.
#
# Run for an intentional change to the production Helper. Review the
# resulting signature and permissions before shipping that new binary.
#
# Usage: ./scripts/rebuild_vendored_helper.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "🔨 Building KeytideHelper (Release, universal)..."
xcodebuild -project Keytide.xcodeproj \
    -scheme helper \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/dd" \
    CODE_SIGN_IDENTITY="-" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    -destination 'platform=macOS' \
    build > "$BUILD_DIR/xcodebuild.log" 2>&1 \
    || { tail -50 "$BUILD_DIR/xcodebuild.log"; exit 1; }

HELPER_BUILT="$BUILD_DIR/dd/Build/Products/Release/KeytideHelper.app"
if [ ! -d "$HELPER_BUILT" ]; then
    echo "❌ Helper build product not found at $HELPER_BUILT"
    exit 1
fi

echo "🔏 Signing helper with KeytideHelper.entitlements..."
codesign --force --sign - \
    --entitlements "$PROJECT_DIR/KeytideHelper/KeytideHelper.entitlements" \
    "$HELPER_BUILT"

CDHASH=$(codesign -d -vvv --arch arm64 "$HELPER_BUILT" 2>&1 | awk -F'=' '/^CDHash=/ {print $2}')
if [ -z "$CDHASH" ]; then
    echo "❌ Failed to extract cdhash from signed helper"
    exit 1
fi

echo "📦 Replacing vendor/KeytideHelper.app..."
mkdir -p vendor
rm -rf vendor/KeytideHelper.app
ditto "$HELPER_BUILT" vendor/KeytideHelper.app

echo "$CDHASH" > vendor/KeytideHelper.cdhash.txt

echo ""
echo "✅ Vendored helper updated."
echo "   Path:   vendor/KeytideHelper.app"
echo "   CDHash: $CDHASH"
echo ""
echo "Next: review with 'git status' and commit both vendor/KeytideHelper.app"
echo "and vendor/KeytideHelper.cdhash.txt together."
