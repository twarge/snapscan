#!/bin/bash
# Embeds the vendored SANE runtime, licenses, and icon into an app bundle's
# Contents directory. Runs as the app target's "Embed SANE Runtime" phase.
# The app links libsane directly (in-process scanning): libsane and libusb go
# to Contents/Frameworks; the dlopen'd fujitsu backend and its config live
# under Resources/sane (found via SANE_CONFIG_DIR / LD_LIBRARY_PATH set by
# the app before sane_init).
# Usage: embed-sane.sh <path-to-SnapScan.app/Contents>
set -euo pipefail

CONTENTS="${1:?usage: embed-sane.sh <App.app/Contents>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$REPO/vendor"
V="$VENDOR/lib"
SANE_DEST="$CONTENTS/Resources/sane"
FRAMEWORKS="$CONTENTS/Frameworks"

[ -f "$V/libsane.1.dylib" ] || {
    echo "vendor/lib/libsane.1.dylib missing - run scripts/build-sane.sh first" >&2
    exit 1
}

mkdir -p "$FRAMEWORKS" "$SANE_DEST/lib/sane" "$SANE_DEST/etc/sane.d" \
    "$CONTENTS/Resources/licenses"

cp -f "$V/libsane.1.dylib" "$FRAMEWORKS/"
cp -f "$V/libusb-1.0.0.dylib" "$FRAMEWORKS/"
cp -f "$V/sane/libsane-fujitsu.1.so" "$SANE_DEST/lib/sane/"
cp -f "$VENDOR/etc/sane.d/fujitsu.conf" "$SANE_DEST/etc/sane.d/"
# Only the fujitsu backend is bundled; a minimal dll.conf avoids probing ~90 absent ones.
echo "fujitsu" > "$SANE_DEST/etc/sane.d/dll.conf"

install_name_tool \
    -id "@rpath/libsane.1.dylib" \
    -change "$V/libusb-1.0.0.dylib" "@rpath/libusb-1.0.0.dylib" \
    "$FRAMEWORKS/libsane.1.dylib" 2>/dev/null
install_name_tool \
    -id "@rpath/libusb-1.0.0.dylib" \
    "$FRAMEWORKS/libusb-1.0.0.dylib" 2>/dev/null
# The backend module resolves libusb through the host process's rpath.
install_name_tool \
    -change "$V/libusb-1.0.0.dylib" "@rpath/libusb-1.0.0.dylib" \
    "$SANE_DEST/lib/sane/libsane-fujitsu.1.so" 2>/dev/null

# The SANE pieces must be signed themselves; the outer bundle signature is
# Xcode's job. Sign with the same identity as the app
# (EXPANDED_CODE_SIGN_IDENTITY); ad hoc otherwise.
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
codesign --force -s "$SIGN_IDENTITY" \
    "$SANE_DEST/lib/sane/libsane-fujitsu.1.so" \
    "$FRAMEWORKS/libusb-1.0.0.dylib" "$FRAMEWORKS/libsane.1.dylib" 2>/dev/null

cp -f "$REPO/LICENSE" "$CONTENTS/Resources/licenses/LICENSE"
cp -f "$REPO/licenses/LGPL-2.1.txt" "$CONTENTS/Resources/licenses/"
cp -f "$REPO/THIRD-PARTY-LICENSES.md" "$CONTENTS/Resources/licenses/"

if [ ! -f "$REPO/Support/AppIcon.icns" ]; then
    swift "$REPO/scripts/make-icon.swift" "$REPO/dist/AppIcon.iconset"
    iconutil -c icns "$REPO/dist/AppIcon.iconset" -o "$REPO/Support/AppIcon.icns"
    rm -rf "$REPO/dist/AppIcon.iconset"
fi
cp -f "$REPO/Support/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

echo "Embedded SANE runtime into $CONTENTS"
