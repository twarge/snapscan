# Third-party components

SnapScan bundles the following third-party software inside the app bundle
(`SnapScan.app/Contents/Resources/sane`). These components keep their own
licenses, reproduced in this repository:

## sane-backends 1.4.0

- Upstream: http://www.sane-project.org (https://gitlab.com/sane-project/backends)
- License: GNU General Public License v2.0 or later (see [LICENSE](LICENSE)).
  The SANE backend libraries additionally carry the "SANE exception" permitting
  linking into non-GPL executables; SnapScan does not rely on it (the tools run
  as separate processes). The `scanimage` frontend is plain GPL-2.0-or-later.
- Bundled pieces: `scanimage`, `libsane.1.dylib`, `libsane-fujitsu.1.so`,
  configuration files under `etc/sane.d`.

## libusb 1.0.27

- Upstream: https://libusb.info (https://github.com/libusb/libusb)
- License: GNU Lesser General Public License v2.1 or later
  (see [licenses/LGPL-2.1.txt](licenses/LGPL-2.1.txt)).
- Bundled piece: `libusb-1.0.0.dylib` (dynamically linked by the SANE tools).

## Source availability

The exact source archives these binaries were built from are kept in
`vendor/src/` (`sane-backends-1.4.0.tar.gz`, `libusb-1.0.27.tar.bz2`) and were
retrieved from the upstream release pages above. `scripts/build-sane.sh`
reproduces the build. If you redistribute the app, distribute these archives
(or equivalent access to them) alongside it to satisfy GPL/LGPL source
requirements.
