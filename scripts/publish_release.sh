#!/bin/bash
# Compatibility alias: local version preparation only, despite the legacy name.
set -euo pipefail
if [[ $# -ne 1 || "$1" != v* ]]; then
    echo "Usage: ./scripts/publish_release.sh vX.Y.Z[-beta.N]" >&2
    echo "This deprecated alias only prepares local metadata; it does not publish." >&2
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Deprecated: use ./scripts/release.sh. This command only prepares local metadata."
exec "$SCRIPT_DIR/release.sh" "${1#v}"
