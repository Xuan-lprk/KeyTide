#!/bin/bash
# Prepare macOS version metadata locally. Never commit, tag, push, or publish.
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: ./scripts/release.sh X.Y.Z[-beta.N]"
    echo "Only updates local macOS app version/build metadata; review the diff before publishing."
    exit 0
fi
if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]]; then
    echo "Usage: ./scripts/release.sh X.Y.Z[-beta.N]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"
python3 - "$1" <<'PYTHON'
from pathlib import Path
import re
import sys

version = sys.argv[1].split("-beta.")[0]
path = Path("Keytide.xcodeproj/project.pbxproj")
source = path.read_text()
pattern = re.compile(r"buildSettings = \{.*?\n\t\t\t\};", re.S)
blocks = [m.group() for m in pattern.finditer(source)
          if "INFOPLIST_FILE = Keytide/Info.plist;" in m.group()]
if len(blocks) != 2:
    raise SystemExit("Expected exactly two main-app build configurations; no files changed.")
builds = []
for block in blocks:
    build = re.findall(r"CURRENT_PROJECT_VERSION = ([0-9]+);", block)
    marketing = re.findall(r"MARKETING_VERSION = [^;]+;", block)
    if len(build) != 1 or len(marketing) != 1:
        raise SystemExit("Ambiguous main-app version settings; no files changed.")
    builds.append(int(build[0]))
if len(set(builds)) != 1:
    raise SystemExit("Debug and Release build numbers differ; no files changed.")
next_build = builds[0] + 1

def update(match):
    block = match.group()
    if "INFOPLIST_FILE = Keytide/Info.plist;" not in block:
        return block
    block = re.sub(r"CURRENT_PROJECT_VERSION = [0-9]+;",
                   f"CURRENT_PROJECT_VERSION = {next_build};", block)
    return re.sub(r"MARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {version};", block)

path.write_text(pattern.sub(update, source))
print(f"Prepared macOS version {version}, build {next_build} locally.")
print("Helper metadata is unchanged. No Git or remote actions performed.")
PYTHON

echo "Review the version diff, then build with ./scripts/build_dmg.sh."
echo "Tag v$1 is only a suggested release name; this script does not create it."
