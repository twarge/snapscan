# Study: replacing SANE with an original, Apache-licensed scanner driver

Goal: eliminate the GPL sane-backends and LGPL libusb dependencies by
writing an original iX500 driver, so the whole app can be relicensed
Apache-2.0 — unlocking Mac App Store distribution and simplifying the
build (no vendored C stack, no xcframework, no embed phase).

## The legal ground rules

**What is not possible:** porting, translating, or adapting `fujitsu.c`
to Swift. A translation is a derivative work; it stays GPL no matter the
language. "Mining" the code in the sense of transcribing it is exactly
what copyright forbids.

**What is possible:** reimplementing the *protocol*. Copyright protects
expression, not facts, methods of operation, or interfaces (Sega v.
Accolade, Sony v. Connectix, Google v. Oracle). The wire protocol the
iX500 speaks is a fact about Fujitsu's hardware — one the SANE authors
themselves obtained by reverse engineering. An original implementation
of the same protocol, written from a factual specification, is lawful
and can be licensed Apache-2.0.

**Method — spec-then-implement:**

1. Write `PROTOCOL.md`: a purely factual specification — command codes,
   byte layouts, sequences, timing, quirks — with per-item provenance.
2. Implement from the spec alone, never from GPL source: no mirrored
   structure, names, or comments.
3. The gold standard is a two-person clean room (spec author ≠
   implementer). Solo, the discipline is: derive the spec **primarily
   from USB captures and public documents**, quarantine the GPL source
   during the implementation phase, and keep provenance notes. Residual
   risk is modest and mitigable; the GPL-derived *knowledge of which
   facts matter* is not itself infringement.

**Spec sources, in order of cleanliness:**

1. **USB traffic captures of the actual scanner.** We own an ideal
   capture rig: the vendored libusb is built from source, so a
   transfer-dump hook (log every bulk in/out with payload) added to our
   own build records complete, honest sessions of the current app
   driving the hardware. Facts, first-hand.
2. **Public standards and documents.** The core command set is the
   SCSI-2 scanner device class (INQUIRY, SET WINDOW, READ, OBJECT
   POSITION…), a published standard. Fujitsu/PFU has published command
   reference manuals for fi-series scanners covering their vendor
   extensions (GET HW STATUS, endorser, etc.); the iX500 deviates from
   fi-series in places, but the family resemblance is strong.
3. The SANE source, *only as a scoping map* (what exists, which quirks
   to probe for), feeding capture experiments — not feeding code.

## What the protocol actually is (from analysis + our runtime experience)

- **Transport:** USB bulk pipes carrying SCSI CDBs in a thin Fujitsu
  wrapper: a 0x1F-byte command packet (first byte 0x43) containing the
  CDB, a data phase on the bulk pipes, and a 0x0D-byte status packet.
  Simpler than USB Mass Storage's BOT framing.
- **Core commands (SCSI-2 scanner class):** TEST UNIT READY (0x00),
  REQUEST SENSE (0x03), INQUIRY (0x12), MODE SELECT/SENSE (0x15/0x1A),
  SCAN (0x1B), SET/GET WINDOW (0x24/0x25), READ (0x28), SEND (0x2A),
  OBJECT POSITION (0x31).
- **Vendor commands:** SET SUBWINDOW (0xC0), ENDORSER (0xC1), GET
  HARDWARE STATUS (0xC2 — the Scan button and paper sensors we poll),
  SCANNER CONTROL (0xF1), READ/SEND DIAGNOSTIC (0x1C/0x1D).
- **iX500-specific quirks (small, explicit, must be in the spec):**
  - Scans **color only** natively; grayscale and lineart are synthesized
    in software (we already own that image machinery).
  - Requires a JPEG quantization table download at setup (via SEND) —
    whether color data returns JPEG-compressed or raw in our
    configuration is the **first open question for captures** (our
    current sessions receive raw RGB rows, yet the table is required).
  - Requires a diagnostic pre-read for resolutions above 300 dpi.
  - Check the hopper sensor before OBJECT POSITION; don't wait after it.
  - Color pixels-per-line must be a multiple of 2.
  - Duplex arrives as two logical streams selected by window ID.
  - Options we use map to MODE SELECT pages (double-feed handling,
    background color) and window fields (geometry, resolution, ALD).

## The replacement architecture

- **Transport:** IOUSBHost.framework (native, sandbox-compatible with
  the existing USB entitlement) replaces libusb entirely. One actor
  owning the device: claim interface, bulk in/out, the 0x43 framing.
- **Driver:** command builders + a session state machine exposing the
  same surface `SaneSession` has today (list/open, configure, read
  sensor, streaming scan batch with partial pages). `ScannerEngine`
  barely changes — the actor interface was designed for this.
- **Estimated size:** ~1,500–2,500 lines of Swift. (fujitsu.c is 10,318
  lines, but it covers ~150 scanner models, three transports, and
  decades of quirks; we need one model, one transport.)

## Phases and effort

| Phase | Work | Estimate |
|---|---|---|
| 1 | libusb capture hook + record sessions (simplex/duplex, all modes/dpi, ALD, sensors, error cases) | 1–2 days |
| 2 | Write PROTOCOL.md from captures + public docs | 2–3 days |
| 3 | IOUSBHost transport + INQUIRY/status bring-up | 1–2 days |
| 4 | Scan pipeline: window, q-table, pre-read, feed, streaming READ, duplex, ALD | 3–5 days (hardware-iteration bound) |
| 5 | Sensors, MODE SELECT options, gray/lineart synthesis | 1 day |
| 6 | Oracle validation (GPL build as reference: same params → same pixels), cutover, relicense | 1–2 days |

Realistic total: **two to three weeks part-time**, dominated by phase 4
hardware iteration. The current GPL build remains permanently useful as
the reference oracle and capture rig.

## Payoff and risks

Payoff: Apache-2.0 across the board; Mac App Store eligible (sandbox and
entitlements already done); the vendored C stack, xcframework, embed
phase, and scheme pre-actions all disappear — the project becomes a
plain one-target Xcode app.

Risks: the q-table/JPEG question; diagnostic pre-read payload semantics;
calibration behaviors; firmware timeout/recovery edge cases. All are
resolvable by capture, and the oracle keeps us honest. Worst case, the
GPL edition continues as the distribution-by-GitHub-Release product it
already is.
