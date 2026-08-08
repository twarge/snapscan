# SnapScan

A small macOS app that scans documents with a Fujitsu ScanSnap iX500 and saves
them as multi-page PDFs.

ScanSnap scanners don't speak TWAIN or Apple's Image Capture protocol, so
SnapScan talks to the iX500 **directly over USB** with its own driver:
SCSI-2 scanner commands in Fujitsu's USB framing, spoken through
IOUSBLib. There are **no third-party components** — no SANE, no libusb,
no drivers or ScanSnap Home to install. The protocol was derived from USB
captures of the scanner itself; see [docs/PROTOCOL.md](docs/PROTOCOL.md)
for the specification and [docs/CLEANROOM-STUDY.md](docs/CLEANROOM-STUDY.md)
for how and why it was written.

## Using it

1. Connect the iX500 via USB and open the feeder flap (that powers it on).
2. Launch SnapScan (copy it to /Applications if you like — the bundle is
   self-contained).
3. Load paper, then press **Scan** in the app — or the **hardware Scan
   button on the scanner itself** (SnapScan polls it about once a second
   while idle).
4. Pages are auto-rotated upright, assembled into a PDF at true physical
   size, and saved directly into your scans folder (default
   `~/Downloads`). No save dialog.

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

**Suggested names** (Saving ▸ Suggest a name from the document): the first
two pages are read with Vision and summarized into a filename by Apple's
on-device language model — "Riverside Water Authority Quarterly Statement
2025-04-08" rather than "Scan 2025-04-09 at 11.02.55". It runs entirely on
this Mac; nothing is uploaded. Macs without Apple Intelligence fall back to
picking the page's heading, and a name you type yourself is never replaced.

**Auto paper size** (Paper ▸ Auto): scans full-width with hardware length
detection, crops to the detected paper,
and snaps to a standard size (Letter, A4, Legal, A5, photo sizes, …) when
within ~5 mm per axis — receipts and other odd sizes keep their exact
measured dimensions. Snapped pages are centered on the standard-size PDF
page; the page cell shows what was decided.

**Searchable scans** (Saving ▸ Make scans searchable): every page is read
with Vision and its words are written into the PDF as an invisible text
layer over the image. ⌘F finds them in Preview, text can be selected and
copied, and Spotlight indexes the contents — macOS's own PDF importer reads
embedded text, so there's no importer here. The recognition rides along with
the straightening pass that already runs per page.

**Compression** (Saving ▸ Compression) trades file size against fidelity.
A 300 dpi colour page costs about 12 MB stored losslessly, so a ten-page
duplex batch runs past 100 MB; the lossy levels store each page as JPEG
inside the PDF — roughly 2.5 MB a page on Light, 1 MB on Medium (the
default), 0.5 MB on Maximum. Black & white scans are 1 bit a pixel and are
always stored losslessly, whatever the setting: JPEG would enlarge them and
blur the edges they exist to keep sharp.

All settings live in SnapScan ▸ Settings (⌘,): sides, color mode, 150–600
dpi, paper size, deskew, auto-crop, blank-page skip, auto-rotate, the scans
folder, compression, searchable text, suggested names, the hardware button
toggle, menu-bar-only mode, and start-at-login.

**Shortcuts, Spotlight and Siri**: *Scan a Document* runs a scan and hands
back the finished PDF, so a shortcut can go straight on to mail or file it;
its sides, colour mode, resolution and name are all optional and fall back
to the settings in the app. *Get Latest Scan* returns the newest PDF without
touching the scanner, and saved scans are available as entities to pick from
in the Shortcuts editor. Both open the app when run — the driver talks to
the scanner from inside this process, so there's no daemon to hand the work
to. An intent waits for straightening, the text layer and the final save
before returning, since the paper stops moving well before the PDF is done.

**Menu bar mode** hides the Dock icon and puts a scanner icon in the menu
bar (click it for status, a Scan button, and Quit). Scans started with the
scanner's hardware button pop up a floating preview near the menu bar with
the latest page and — in combine mode — a Done button. Start-at-login uses
the system login items (the app should live in /Applications for that).

## Building

```bash
make          # build the app (Release); prints the product path
make test     # unit tests
make probe    # headless driver check against the scanner (quit SnapScan first)
```

Xcode is the only build system, and there is nothing to build first:
**a fresh checkout is just open the project and ⌘R.** No vendored
libraries, no dependency scripts, no package manager. The app lives only
where Xcode puts it (DerivedData; `make` prints the product path, or use
Product ▸ Show Build Folder). Requires Xcode 16+ (macOS 15 target).

The app is **sandboxed** (USB device entitlement for the scanner,
user-selected file access for the scans folder — choosing a folder in
Settings stores a security-scoped bookmark). It builds in the Swift 6
language mode with main-actor default isolation, tests with Swift Testing,
and uses the async Swift Vision API.

## How the pieces fit

- `Sources/SnapScan/USBTransport.swift` — the USB layer: finds the
  scanner, claims its interface, and speaks the 31-byte command / data /
  13-byte status framing. Built on IOUSBLib because IOUSBHost's user
  client cannot be opened inside the App Sandbox.
- `Sources/SnapScan/ScannerCommands.swift` — SCSI command builders and
  response parsers: window descriptors in 1/1200-inch units, mode pages,
  sense decoding, sensor bits.
- `Sources/SnapScan/NativeScanner.swift` — the scan pipeline: device
  setup, feed, streaming reads with live partial pages, duplex window
  alternation, and end-of-page handling.
- `Sources/SnapScan/ScannerEngine.swift` — app-facing state machine:
  document lifecycle, direct-save, post-processing, and the hardware-button
  watch (reading the Scan-button sensor over the open USB connection).
  Straightening runs
  per page, concurrently, starting the moment each page lands (spinner on
  the page's cell); the scanner frees as soon as the batch ends, so the
  next scan can start while the previous document is still processing —
  such documents appear as spinner rows in the sidebar until their final
  PDF is written.
- `Sources/SnapScan/OrientationDetector.swift` — auto-rotate and deskew.
  Accurate OCR reads text at any rotation but keeps its observation quads
  in the *given* coordinate space, so the circular mean of the text lines'
  topLeft→topRight vectors encodes the page's rotation directly — rounding
  it to the nearest 90° gives the correction in one pass. (An older
  two-step fast/accurate scheme is gone: fast recognition no longer sees
  enough text to vote.) Rotation itself is an exact per-pixel permutation
  (rasterizing a 90° rotation through CGContext corrupts edge pixels).
  "Straighten pages" deskews in-app from the median tilt of Vision's
  text-line quads, gated on evidence (≥4 wide lines, consistent angles,
  0.25–6°) — sparse pages are deliberately left alone. (A backend-side
  deskew was tried and abandoned: its estimator tilts straight-but-sparse
  pages.)
- `Sources/SnapScan/Intents.swift` — the Shortcuts/Spotlight/Siri surface:
  a scan action returning the PDF, a latest-scan action, and an entity
  query over the library. The parameter enums' `AppEnum` conformances live
  in `Models.swift`, since `AppEnum` implies `Sendable` and that has to be
  declared alongside the type.
- `Sources/SnapScan/TextLayer.swift` — recognizes a page's words and draws
  them into the PDF in text rendering mode 3: searchable and selectable,
  never painted. Coordinates are normalized, so they follow the image
  rather than the sheet when a page is size-snapped.
- `Sources/SnapScan/NameSuggester.swift` — reads the first pages with
  Vision and asks the on-device model for a filename; falls back to the
  page's heading where there's no model.
- `Sources/SnapScan/FrameImage.swift` — builds CGImages from raw scanner
  frames (including partial pages mid-scan).
- `Sources/SnapScan/PDFBuilder.swift` — assembles pages into a PDF at true
  size, optionally re-encoding each page as JPEG so the PDF carries the
  compressed stream directly (`/DCTDecode`) instead of raw pixels.
  physical size (pixels ÷ dpi × 72 points), centering size-snapped pages.
- `scripts/make-icon.swift` — the app icon's source; only run if
  `Support/AppIcon.icns` is ever deleted.

## CI and releases

GitHub Actions builds and tests every push (`.github/workflows/ci.yml`,
ad-hoc signed, app attached as a CI artifact). Pushing a `vX.Y.Z` tag —
or running the Release workflow manually — archives with cloud-managed
Developer ID signing, notarizes, staples, and publishes a GitHub
Release with the zipped app. One set of secrets drives all of it (an
App Store Connect API key: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`
— see the comments in `.github/workflows/release.yml`); there is no
certificate to export or rotate, since `xcodebuild` manages signing via
the API key.


## License

Copyright © 2026 Tom Kornack.

Licensed under the Apache License, Version 2.0 — see [LICENSE](LICENSE).
Distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND. SnapScan bundles no third-party code.

## Limitations

- USB only — the iX500's Wi-Fi mode uses a proprietary protocol this
  driver doesn't speak.
- One scanner: the app uses the first iX500 it finds on USB.
- The driver targets the iX500 specifically (USB 0x04C5:0x132B). Other
  ScanSnap models speak a similar dialect but are untested.
