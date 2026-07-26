#!/bin/bash
# Packages the vendored libsane as SANE.xcframework (repo root) with headers
# and a Clang module map so Swift can `import CSane`. The dylib inside is
# rewritten to @rpath install names for embedding in an app bundle.
# Run scripts/build-sane.sh first.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$REPO/vendor"
STAGE="$REPO/.build/xcframework-stage"
OUT="$REPO/SANE.xcframework"

[ -f "$VENDOR/lib/libsane.1.dylib" ] || {
    echo "vendor/lib/libsane.1.dylib missing - run scripts/build-sane.sh first" >&2
    exit 1
}

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/headers/sane"

cp "$VENDOR/lib/libsane.1.dylib" "$STAGE/libsane.1.dylib"
install_name_tool \
    -id "@rpath/libsane.1.dylib" \
    -change "$VENDOR/lib/libusb-1.0.0.dylib" "@rpath/libusb-1.0.0.dylib" \
    "$STAGE/libsane.1.dylib" 2>/dev/null
codesign --force -s - "$STAGE/libsane.1.dylib" 2>/dev/null

cp "$VENDOR/include/sane/sane.h" "$VENDOR/include/sane/saneopts.h" "$STAGE/headers/sane/"
cat > "$STAGE/headers/module.modulemap" <<'EOF'
module CSane {
    header "sane/sane.h"
    header "sane/saneopts.h"
    export *
}
EOF

xcodebuild -create-xcframework \
    -library "$STAGE/libsane.1.dylib" \
    -headers "$STAGE/headers" \
    -output "$OUT" >/dev/null

rm -rf "$STAGE"
echo "Created $OUT"
