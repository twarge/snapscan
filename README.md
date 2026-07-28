# SnapScan

A small macOS app that scans documents with a Fujitsu ScanSnap iX500 and saves
them as multi-page PDFs.

ScanSnap scanners don't speak TWAIN or Apple's Image Capture protocol, so this
app drives the scanner through [SANE](http://www.sane-project.org)'s `fujitsu`
backend over **USB**, calling the SANE C API **in-process** (libsane is
linked directly, packaged as `SANE.xcframework` for Xcode). That's what makes
pages appear live in the window while the sheet is still feeding. The whole
SANE stack (libusb + sane-backends) is built from source and embedded inside
the app bundle — no Homebrew, drivers, or ScanSnap Home required at runtime.

## Using it

1. Connect the iX500 via USB and open the feeder flap (that powers it on).
2. Launch `dist/SnapScan.app` (copy it to /Applications if you like — the
   bundle is self-contained).
3. Load paper, then press **Scan** in the app — or the **hardware Scan
   button on the scanner itself** (SnapScan polls it about once a second
   while idle).
4. Pages are auto-rotated upright, assembled into a PDF at true physical
   size, and saved directly into your scans folder (default
   `~/Documents/Scans`). No save dialog.

The sidebar lists the scans this app has made (tracked by file bookmarks,
so a scan moved or renamed in Finder keeps its place; entries whose file is
gone are dropped). Select one to preview it; click a selected row again
(pause, Finder-style) to rename it inline; right-click to reveal in Finder.
Drag a scan into Finder to **move** it there (hold Option to copy instead).

In the page grid: pinch to zoom the thumbnails, click to select pages
(⌘-click for multiple), and press delete to remove them. The toolbar shows
live scanner presence — driven by IOKit USB events, so it flips the moment
the iX500 is plugged in or its flap opens — and the Scan button enables
accordingly.

With "Combine scans into one document" on (the default), scanning again
appends pages to the current PDF — run several batches through the feeder,
then press **Done** to finalize; the next scan starts a new PDF. With it
off, every batch becomes its own PDF. Selecting a previous scan in the
sidebar also finalizes the active one — looking away commits it.

A name field sits above the pages: when a new scan starts it is focused
with the proposed name selected, so just typing and pressing return renames
the PDF.

**Auto paper size** (Paper ▸ Auto): scans full-width with hardware length
detection and the scanner's black background, crops to the detected paper,
and snaps to a standard size (Letter, A4, Legal, A5, photo sizes, …) when
within ~5 mm per axis — receipts and other odd sizes keep their exact
measured dimensions. Snapped pages are centered on the standard-size PDF
page; the page cell shows what was decided.

All settings live in SnapScan ▸ Settings (⌘,): sides, color mode, 150–600
dpi, paper size, deskew, auto-crop, blank-page skip, auto-rotate, the scans
folder, the hardware button toggle, menu-bar-only mode, and start-at-login.

**Menu bar mode** hides the Dock icon and puts a scanner icon in the menu
bar (click it for status, a Scan button, and Quit). Scans started with the
scanner's hardware button pop up a floating preview near the menu bar with
the latest page and — in combine mode — a Done button. Start-at-login uses
the system login items (the app should live in /Applications for that).

## Building

```bash
scripts/build-sane.sh        # downloads + builds libusb and sane-backends into vendor/
scripts/make-xcframework.sh  # wraps vendored libsane as SANE.xcframework (Xcode builds)
scripts/make-app.sh          # swift build + assembles dist/SnapScan.app
swift test                   # frame/PDF/orientation/filename tests
swift run SaneSmokeTest      # headless hardware check of the in-process SANE stack
```

Or open `SnapScan.xcodeproj` — the app target runs, debugs, and tests
(⌘U) from Xcode, and an "Embed SANE Runtime" build phase calls
`scripts/embed-sane.sh` so Xcode-built bundles are just as self-contained.
Both builds share the same sources; run `scripts/build-sane.sh` once before
either. Requires Xcode 16+ (Swift 6.2 tools, macOS 15 target) and
pkg-config. During development, `swift run` from the repo root uses
`vendor/` directly; bundled apps use the copy in
`Contents/Resources/sane`.

The app is **sandboxed** (USB device entitlement for the scanner,
user-selected file access for the scans folder — choosing a folder in
Settings stores a security-scoped bookmark). It builds in the Swift 6
language mode with main-actor default isolation, tests with Swift Testing,
and uses the async Swift Vision API.

## How the pieces fit

- `Sources/SnapScan/SaneSession.swift` — the in-process SANE layer: an
  actor owning the blocking C calls (`sane_open`, `sane_start`, streaming
  `sane_read`), emitting partial-page images as rows arrive and complete
  pages per sheet. `sane_cancel` is async-safe by spec and bypasses the
  actor so Stop works mid-read. The dll loader finds the bundled backend
  and config via `SANE_CONFIG_DIR`/`LD_LIBRARY_PATH` set before
  `sane_init`. The `CSane` Clang module comes from `SANE.xcframework`'s
  headers in Xcode and `Sources/CSane` under SwiftPM.
- `Sources/SnapScan/ScannerEngine.swift` — app-facing state machine:
  document lifecycle, direct-save, post-processing, and the hardware-button
  watch (reading the fujitsu `scan` sensor through the open handle, an
  in-process option read instead of spawning anything). Straightening runs
  per page, concurrently, starting the moment each page lands (spinner on
  the page's cell); the scanner frees as soon as the batch ends, so the
  next scan can start while the previous document is still processing —
  such documents appear as spinner rows in the sidebar until their final
  PDF is written.
- `Sources/SnapScan/OrientationDetector.swift` — auto-rotate and deskew.
  Vision's fast OCR scores 0°/180° identically (it reads flipped text as
  confident gibberish) and accurate OCR silently auto-corrects all four
  orientations, so neither can vote by score alone. Instead: fast OCR picks
  the text *axis* (horizontal vs vertical), then one accurate pass checks
  whether reading order flows down the page — if the first-read line sits
  at the bottom, the page is flipped 180°. Rotation itself is an exact
  per-pixel permutation (rasterizing a 90° rotation through CGContext
  corrupts edge pixels). "Straighten pages" deskews in-app from the median
  tilt of Vision's text-line quads, gated on evidence (≥4 wide lines,
  consistent angles, 0.25–6°) — sparse pages are deliberately left alone.
  SANE's `--swdeskew` is not used: its estimator tilts straight-but-sparse
  pages.
- `Sources/SnapScan/PNM.swift` — decodes scanimage's PNM output (P4/P5/P6);
  the vendored build has no libpng/libjpeg on purpose.
- `Sources/SnapScan/PDFBuilder.swift` — assembles pages into a PDF at true
  physical size (pixels ÷ dpi × 72 points).
- `scripts/make-app.sh` — copies the SANE runtime into the bundle, rewrites
  dylib install names to `@executable_path`/`@loader_path`, writes a minimal
  `dll.conf` (just `fujitsu`), and ad-hoc codesigns everything.

## License

Copyright © 2026 Tom Kornack.

SnapScan is free software, licensed under the GNU General Public License,
version 2 or (at your option) any later version — see [LICENSE](LICENSE).
It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.

The app bundles sane-backends (GPL-2.0-or-later) and libusb
(LGPL-2.1-or-later); see [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)
for details and source availability.

## Limitations

- USB only — SANE cannot reach an iX500 over Wi-Fi (that protocol is
  proprietary).
- One scanner: the app picks the first SANE device it finds.
- Only the iX500's backend is bundled; other SANE-supported scanners would
  need their backends added in `scripts/build-sane.sh` (`BACKENDS=…`) and
  `scripts/make-app.sh`.
