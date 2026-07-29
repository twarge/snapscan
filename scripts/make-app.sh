#!/bin/bash
# Builds dist/SnapScan.app with xcodebuild — the exact same product Xcode
# produces (same project, target, signing, entitlements, and embed phase),
# just the Release configuration copied to dist/ for convenience.
# Run scripts/build-sane.sh and scripts/make-xcframework.sh first.
set -euo pipefail
set -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$REPO/.build/DerivedData"

[ -d "$REPO/SANE.xcframework" ] || {
    echo "SANE.xcframework missing - run scripts/make-xcframework.sh first" >&2
    exit 1
}

echo "== xcodebuild (Release) =="
xcodebuild \
    -project "$REPO/SnapScan.xcodeproj" \
    -scheme SnapScan \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    build 2>&1 | grep -E "^\*\*|error:"

APP="$DERIVED/Build/Products/Release/SnapScan.app"
[ -d "$APP" ] || {
    echo "build did not produce $APP" >&2
    exit 1
}

rm -rf "$REPO/dist/SnapScan.app"
mkdir -p "$REPO/dist"
cp -R "$APP" "$REPO/dist/SnapScan.app"

echo "Done: $REPO/dist/SnapScan.app"
