#!/bin/bash
# Builds the vendored scanner stack (libusb + sane-backends, fujitsu backend only)
# into <repo>/vendor. Requires: Xcode CLT, pkg-config. No Homebrew writes needed.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="$REPO/vendor"
SRC="$PREFIX/src"
JOBS="$(sysctl -n hw.ncpu)"

# When invoked from an Xcode script phase or scheme pre-action, Xcode's
# exported build settings poison autoconf ("C compiler cannot create
# executables"). Re-exec under a clean environment instead of playing
# whack-a-mole with individual variables.
if [ -n "${XCODE_VERSION_ACTUAL:-}" ] && [ -z "${SNAPSCAN_CLEAN_ENV:-}" ]; then
    exec /usr/bin/env -i \
        SNAPSCAN_CLEAN_ENV=1 \
        HOME="$HOME" \
        PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        /bin/bash "$0" "$@"
fi

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
# Protocol-capture hook: dormant unless SNAPSCAN_USB_TRACE is set at
# runtime (see docs/CLEANROOM-STUDY.md).
python3 "$REPO/scripts/add-usb-trace.py" "$SRC/libusb-${LIBUSB_VER}"
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

echo "== prune =="
# Keep only what the app consumes: the two dylibs, the fujitsu backend
# module, the SANE headers (for the xcframework), and etc/sane.d config.
# Frontends (scanimage), saned, docs, static libs, and libtool metadata
# are install byproducts nothing uses.
cd "$PREFIX"
rm -rf bin sbin share var lib/pkgconfig
rm -f lib/*.a lib/*.la lib/sane/*.la
# The dll meta-backend lives inside libsane itself; its standalone module
# is never loaded.
rm -f lib/sane/libsane-dll*
# Extracted source trees are spent once installed; the tarballs stay.
find "$SRC" -maxdepth 1 -type d ! -path "$SRC" -exec rm -rf {} +

echo "Done. Runtime pieces are in $PREFIX/lib, headers in $PREFIX/include."
