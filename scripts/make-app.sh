#!/bin/bash
# Builds SnapScan.app into dist/ with SwiftPM, embedding the vendored SANE
# stack so the bundle is self-contained and relocatable. Run
# scripts/build-sane.sh first. (The Xcode project produces the same bundle
# via scripts/embed-sane.sh in a build phase.)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/dist/SnapScan.app"
CONTENTS="$APP/Contents"

echo "== swift build =="
cd "$REPO"
swift build -c release >/dev/null

echo "== assemble bundle =="
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$REPO/.build/release/SnapScan" "$CONTENTS/MacOS/SnapScan"
cp "$REPO/Support/Info.plist" "$CONTENTS/Info.plist"

# The SwiftPM binary links libsane by its vendor path; point it at the
# bundled copy instead. (Xcode builds link @rpath via SANE.xcframework.)
install_name_tool \
    -change "$REPO/vendor/lib/libsane.1.dylib" "@rpath/libsane.1.dylib" \
    -add_rpath "@executable_path/../Frameworks" \
    "$CONTENTS/MacOS/SnapScan" 2>/dev/null

echo "== embed sane runtime =="
"$REPO/scripts/embed-sane.sh" "$CONTENTS"

echo "== codesign (ad hoc) =="
codesign --force -s - "$APP" 2>/dev/null

echo "== verify bundle links =="
otool -L "$CONTENTS/MacOS/SnapScan" | grep -E "libsane" || {
    echo "libsane link missing" >&2
    exit 1
}

echo "Done: $APP"
