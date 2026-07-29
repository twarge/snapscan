#!/bin/bash
# Records a USB trace of the vendored SANE stack driving the scanner, for
# the clean-room protocol spec (docs/CLEANROOM-STUDY.md).
#
#   scripts/capture-session.sh <name> [--scan] [--source S] [--mode M]
#                                     [--resolution N]
#
# Writes docs/captures/<name>.log. Pass --scan to also read image data
# (load paper first); extra flags are forwarded to the smoke tool, e.g.
#   --source "ADF Duplex"   --mode Color   --resolution 300
# The scanner must be free — quit SnapScan, since one process at a time
# can hold it.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:?usage: capture-session.sh <name> [--scan]}"
shift || true

if pgrep -f "SnapScan.app/Contents/MacOS/SnapScan" >/dev/null; then
    echo "SnapScan is running and holds the scanner; quit it first." >&2
    exit 1
fi

SMOKE="$(xcodebuild -project "$REPO/SnapScan.xcodeproj" -scheme SaneSmokeTest \
    -configuration Release -showBuildSettings 2>/dev/null \
    | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')/SaneSmokeTest"
[ -x "$SMOKE" ] || {
    echo "build SaneSmokeTest first: make smoke" >&2
    exit 1
}

mkdir -p "$REPO/docs/captures"
OUT="$REPO/docs/captures/$NAME.log"
rm -f "$OUT"

echo "Recording to $OUT ..."
SNAPSCAN_USB_TRACE="$OUT" "$SMOKE" "$@" || true

if [ -s "$OUT" ]; then
    echo "Captured $(grep -c '^\(IN \|OUT\)' "$OUT") transfers."
else
    echo "No traffic recorded — is the scanner plugged in with the flap open?" >&2
    exit 1
fi
