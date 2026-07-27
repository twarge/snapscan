#!/bin/bash
# Builds the vendored scanner stack (libusb + sane-backends, fujitsu backend only)
# into <repo>/vendor. Requires: Xcode CLT, pkg-config. No Homebrew writes needed.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="$REPO/vendor"
SRC="$PREFIX/src"
JOBS="$(sysctl -n hw.ncpu)"

# Match the app's deployment target so the linker doesn't warn about
# dylibs built for a newer macOS than the app targets.
export MACOSX_DEPLOYMENT_TARGET=14.0

LIBUSB_VER=1.0.27
LIBUSB_URL="https://github.com/libusb/libusb/releases/download/v${LIBUSB_VER}/libusb-${LIBUSB_VER}.tar.bz2"
SANE_VER=1.4.0
SANE_URL="https://gitlab.com/-/project/429008/uploads/843c156420e211859e974f78f64c3ea3/sane-backends-${SANE_VER}.tar.gz"

mkdir -p "$SRC"
cd "$SRC"

[ -f "libusb-${LIBUSB_VER}.tar.bz2" ] || curl -fsSL -o "libusb-${LIBUSB_VER}.tar.bz2" "$LIBUSB_URL"
[ -d "libusb-${LIBUSB_VER}" ] || tar xjf "libusb-${LIBUSB_VER}.tar.bz2"
[ -f "sane-backends-${SANE_VER}.tar.gz" ] || curl -fsSL -o "sane-backends-${SANE_VER}.tar.gz" "$SANE_URL"
[ -d "sane-backends-${SANE_VER}" ] || tar xzf "sane-backends-${SANE_VER}.tar.gz"

echo "== libusb =="
cd "$SRC/libusb-${LIBUSB_VER}"
make distclean >/dev/null 2>&1 || true
./configure --prefix="$PREFIX" --disable-dependency-tracking >/dev/null
make -j"$JOBS" >/dev/null
make install >/dev/null

echo "== sane-backends (fujitsu backend) =="
cd "$SRC/sane-backends-${SANE_VER}"
make distclean >/dev/null 2>&1 || true
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" ./configure \
    --prefix="$PREFIX" \
    --disable-dependency-tracking \
    --without-gphoto2 \
    BACKENDS="fujitsu" >/dev/null
make -j"$JOBS" >/dev/null
make install >/dev/null

echo "== verify =="
"$PREFIX/bin/scanimage" --version
echo "Done. Run '$PREFIX/bin/scanimage -L' with the scanner attached."
