#!/bin/bash
# Verify vendor/KeytideHelper.app's actual cdhash matches the value
# recorded in vendor/KeytideHelper.cdhash.txt.
#
# Check the pinned bundle's arm64 identity on both Intel and Apple Silicon.
#
# Exit 0 on match, 1 on mismatch / missing files.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR_APP="$PROJECT_DIR/vendor/KeytideHelper.app"
EXPECTED_FILE="$PROJECT_DIR/vendor/KeytideHelper.cdhash.txt"

if [ ! -d "$VENDOR_APP" ]; then
    echo "❌ Missing vendored helper bundle: $VENDOR_APP"
    echo "   Run: ./scripts/rebuild_vendored_helper.sh"
    exit 1
fi

if [ ! -f "$EXPECTED_FILE" ]; then
    echo "❌ Missing expected cdhash file: $EXPECTED_FILE"
    echo "   Run: ./scripts/rebuild_vendored_helper.sh"
    exit 1
fi

EXPECTED=$(tr -d '[:space:]' < "$EXPECTED_FILE")
ACTUAL=$(codesign -d -vvv --arch arm64 "$VENDOR_APP" 2>&1 | awk -F'=' '/^CDHash=/ {print $2}' | tr -d '[:space:]')

if [ -z "$ACTUAL" ]; then
    echo "❌ Failed to extract cdhash from $VENDOR_APP (codesign -d failed?)"
    exit 1
fi

if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "❌ Vendored helper cdhash mismatch."
    echo "   Expected (vendor/KeytideHelper.cdhash.txt): $EXPECTED"
    echo "   Actual   (vendor/KeytideHelper.app):        $ACTUAL"
    echo ""
    echo "   The vendored bundle no longer matches the pinned identity. For an intended update, run:"
    echo "     ./scripts/rebuild_vendored_helper.sh"
    echo "   then commit both vendor/KeytideHelper.app and vendor/KeytideHelper.cdhash.txt."
    exit 1
fi

echo "✅ Vendored helper cdhash OK: $ACTUAL"
