# ScanSnap iX500 USB protocol

A factual specification of the wire protocol, for an original
Apache-licensed driver (see CLEANROOM-STUDY.md for method and rationale).

**Provenance** is recorded per section:

- **[capture]** — observed directly in our own USB captures of this
  scanner (`docs/captures/`, recorded with `scripts/capture-session.sh`).
- **[SCSI-2]** — the published SCSI-2 standard (X3.131-1994), whose
  scanner device class defines most commands and data formats here.
- **[open]** — not yet established; needs a capture or experiment.

Status: **in progress.** Framing, enumeration, and the single-page scan
sequence (including the image data format and end-of-page signaling) are
established from captures. Duplex, resolution variants, and auto length
detection remain.

## 1. Device identity [capture]

- USB vendor 0x04C5 (Fujitsu), product 0x132B.
- The device only appears on the bus when the feeder flap is open; it
  removes itself when closed. Presence therefore equals readiness.
- One process at a time may claim the interface.

## 2. Transport framing [capture]

Two bulk endpoints: **0x02 out**, **0x81 in**. Every exchange is:

1. **Command packet** — 31 bytes, host → device (ep 0x02):

   | offset | size | value |
   |---|---|---|
   | 0 | 1 | `0x43` (ASCII `C`) |
   | 1–18 | 18 | zero in every observed command |
   | 19–30 | 12 | the SCSI CDB, zero-padded to 12 bytes |

2. **Data phase** (optional) — direction and length per the CDB.
3. **Status packet** — 13 bytes, device → host (ep 0x81), byte 0 =
   `0x53` (ASCII `S`). All-zero payload observed on success.

Note the packet is a fixed 31 bytes regardless of whether the CDB is a
6-, 10-, or 12-byte form; short CDBs are simply zero-padded. [capture]

## 3. Commands observed

Opcodes are SCSI-2 standard unless marked vendor. [SCSI-2] [capture]

| opcode | name | seen in |
|---|---|---|
| 0x00 | TEST UNIT READY | enumeration |
| 0x03 | REQUEST SENSE | error recovery |
| 0x12 | INQUIRY | enumeration |
| 0x15 | MODE SELECT | configuration |
| 0x1A | MODE SENSE | configuration |
| 0x1C | READ DIAGNOSTIC | pre-scan |
| 0x1D | SEND DIAGNOSTIC | pre-scan |
| 0x24 | SET WINDOW | scan setup |
| 0x2A | SEND | scan setup (table download) |
| 0x1B | SCAN | scan start |
| 0x28 | READ | image + metadata transfer |
| 0x31 | OBJECT POSITION | paper feed |
| 0xC2 | vendor: hardware status | sensors |
| 0xF1 | vendor: scanner control | setup, teardown |

GET WINDOW (0x25) has not appeared in any capture. [open]

### 3.1 INQUIRY, standard page [capture] [SCSI-2]

CDB `12 00 00 00 60 00` — allocation length 0x60 (96 bytes).

Response is standard SCSI-2 INQUIRY data:

| offset | size | value |
|---|---|---|
| 0 | 1 | `0x06` — peripheral device type: scanner |
| 8–15 | 8 | vendor: `FUJITSU ` |
| 16–31 | 16 | product: `ScanSnap iX500  ` |

### 3.2 INQUIRY, vendor page 0xF0 [capture]

CDB `12 01 f0 00 cc` — EVPD set, page 0xF0, allocation 0xCC (204 bytes).
Returns 204 bytes of device capability data beginning
`06 f0 02 00 8b 02 58 02 58 11 02 58 02 58 00 32 00 32 …`.

Recognizable: `0x0258` = 600 repeated (the maximum optical resolution in
dpi, matching this model), `0x0032` = 50 (the minimum). Full field
layout is **[open]** — a capture at several resolutions plus comparison
against GET WINDOW output will settle it.

### 3.3 Hardware status, vendor 0xC2 [capture]

CDB `c2 00 00 00 00 00 00 00 0c 00` — allocation 0x0C (12 bytes).
Returns a 12-byte block of sensor bits. Assignments confirmed by
isolating each physical action and watching which bit moves:

| byte | bit | meaning |
|---|---|---|
| 3 | 7 (`0x80`) | feeder flap closed (sustained while closed) |
| 3 | 5 (`0x20`) | front cover open, i.e. opened to clear a jam |
| 4 | 0 (`0x01`) | **Scan button pressed** (momentary) |
| 5 | 0 (`0x01`) | set in every reading observed; meaning unknown |

Idle with the flap open reads `00 00 00 00 00 01 00 00 00 00 00 00`.
Note the scanner still answers while the flap is closed (byte 3 bit 7
set) even though closing it normally removes the device from the bus.
Remaining bytes have not been seen non-zero.

### 3.4 MODE SELECT / MODE SENSE [capture] [SCSI-2]

CDB `15 10 00 00 0c` — PF set, parameter list length 12 (0x0E for one
page). Enumeration writes several such pages in sequence. MODE SENSE
(`1a …`) reads them back; a 20-byte response was observed.

Page contents and page codes are **[open]**; the app-visible settings
that map here are double-feed detection behavior and background color.

### 3.5 SET WINDOW [capture] [SCSI-2]

CDB `24 00 00 00 00 00 00 00 48 00` — parameter list length 0x48 (72
bytes), i.e. an 8-byte window descriptor header plus a 64-byte window
descriptor block, per SCSI-2.

The descriptor carries resolution, scan area, pixel format, and vendor
extension bytes. Exact field usage is **[open]** — capture scans at
known geometry/resolution/mode and correlate.

## 4. Sequences

### 4.1 Enumeration [capture]

Observed order (93 transfers total):

1. TEST UNIT READY
2. INQUIRY standard (96 bytes)
3. INQUIRY vendor page 0xF0 (204 bytes)
4. MODE SENSE ×N interleaved with MODE SELECT ×N — capability probe and
   configuration
5. vendor 0xF1 (scanner control)
6. SET WINDOW
7. vendor 0xC2 (sensor read)
8. SEND DIAGNOSTIC / READ DIAGNOSTIC pair
9. SEND (table download)

### 4.2 Single-page scan [capture]

From `02-scan.log` (1279 transfers, one letter page at the backend's
default settings):

1. **OBJECT POSITION** — CDB `31 01 …`. Byte 1 = `0x01` = load/feed a
   sheet from the hopper.
2. **SCAN** — CDB `1b 00 00 00 01 …`. Byte 4 is the transfer length for
   a 1-byte data-out phase carrying the window ID to scan.
3. **READ, data type 0x80 (pixel size)** — CDB
   `28 00 80 00 00 00 00 00 20`, allocation 32 bytes. Response
   (observed): `00 00 13 e8 00 00 19 c8 …` — big-endian pairs:
   `0x13E8` = 5096 pixels wide, `0x19C8` = 6600 lines. The pair repeats
   (front/back window slots), with a zero block between.
4. **READ, data type 0x00 (image)** — repeated. CDB
   `28 00 00 00 00 00 03 f7 38`, i.e. transfer length `0x03F738` =
   259,896 bytes, which is exactly **17 image lines**. Each read returns
   a full 259,896 bytes and a success status.
5. **End of page**: the status packet of the final read differs — byte 9
   is `0x02` instead of `0x00`. The host then issues **REQUEST SENSE**.
6. **Sense data** (18 bytes): `f0 00 60 00 03 08 58 0a 00 …` — SCSI-2
   fixed-format sense with the VALID bit set, sense key `0x0` (NO
   SENSE) carrying EOM+ILI, and an information field of `0x030858` =
   198,744 bytes = **13 lines of residual** (the unfilled tail of the
   final read).
7. Teardown: vendor `0xF1` with byte 1 = `0x04`, then a MODE SELECT.

Verified arithmetic: 388 full reads × 17 lines + 4 valid lines in the
final read = **6600 lines**, exactly the page height reported in step 3.

### 4.3 Image data format [capture]

**The wire always carries 24-bit RGB**, three bytes per pixel, one row
per line, top to bottom — even when the application requested lineart.
Proof: at 5096 px wide, a line is 15,288 bytes; the observed 259,896-byte
read is exactly 17 such lines, and the line count reconciles to 6600.
The session that produced this capture asked the backend for **lineart**,
yet the transfer is full color: grayscale and lineart are synthesized on
the host, not by the scanner.

**Values are inverted.** The device returns inverted reflectance: blank
paper reads near 0 and ink near 255. A driver must flip the values
(measured on a native scan: mean brightness 9 before inversion, 245
after). CGImage's decode array does this at no cost.

**No JPEG.** No SOI marker (`FF D8`) appears anywhere in the captured
data. A quantization-table download still occurs during setup (the SEND
in §4.1), so JPEG may be reachable in some configuration, but it is not
used here. Whether any mode or resolution switches the device to
compressed output is **[open]** — compare a 600 dpi color capture.

### 4.4 Window IDs and duplex [capture]

Windows are identified by a single byte: **`0x00` = front, `0x80` =
back**. The ID appears in two places:

- **SCAN** — the data-out phase lists the windows to scan. Simplex sends
  one byte (`00`), duplex sends two (`00 80`), and the CDB's byte 4 is
  that list's length (`01` or `02` respectively).
- **READ** — CDB byte 5 (the SCSI data-type qualifier) selects the
  window to read from: `28 00 00 00 00 00 …` reads front image data,
  `28 00 00 00 00 80 …` reads back. The pixel-size read (type `0x80`)
  is likewise per-window.

In duplex the host **alternates reads between the two windows**
(`00`, `80`, `00`, `80`, …) as data becomes available, rather than
draining one side and then the other. From `03-duplex.log` (13,965
transfers).

### 5.1 Multiple windows in one SET WINDOW [capture]

Duplex sends **one** SET WINDOW whose parameter list holds both
descriptors — 8-byte header plus 64 bytes per window, so 136 bytes with
`0x88` in the CDB's length field. Sending two separate SET WINDOW
commands instead earns sense `05/2C/02` (illegal request, command
sequence error).

Only the **leading** descriptor carries the trailing vendor flag
(`0xC0` at descriptor offset 53) and the paper size (offsets 56 and 60);
in the back window's descriptor those bytes are zero.

### 4.5 Flow control and the attention status [capture]

A status packet with **byte 9 = `0x02`** means "check condition": the
host must issue REQUEST SENSE (CDB `03 00 00 00 12`, 18 bytes) before
continuing. The sense payload distinguishes two very different
situations, and both are normal:

| sense bytes | meaning |
|---|---|
| `f0 00 60 … info=residual … 0a` | sense key `0x0` (NO SENSE) with EOM+ILI: **end of page**, information field = unfilled bytes of the final read |
| `f0 00 03 … 80 13 …` | sense key `0x3`, vendor ASC/ASCQ `0x80`/`0x13`: **data not ready for that window** — retry the read |

The second form dominates duplex captures (1,922 occurrences): the
back-side window frequently has no data ready while the sheet is still
feeding, and the host simply reads again. Treating it as an error would
break duplex scanning.

**The retry case still returns a full buffer**, but its contents are not
image data. A driver must discard that read's bytes before retrying;
appending them inflates the page without bound (observed: a 3,300-line
page grew to 24,040 lines before this was fixed).

### 4.6 Resolution and chunking [capture]

Comparing 600 dpi (`02-scan.log`) with 300 dpi color (`04-color-300.log`):

| | 600 dpi | 300 dpi |
|---|---|---|
| pixel size read | 5096 × 6600 | 2550 × 3300 |
| bytes per line (RGB) | 15,288 | 7,650 |
| READ transfer length | 259,896 (`0x03F738`) | 260,100 (`0x03F804`) |
| lines per read | 17 | 34 |

The transfer length is always a **whole number of lines** landing just
under 256 KiB — a host-side buffering choice, not a device requirement;
a new driver may pick its own line-aligned chunk. The data format is
identical at both resolutions (24-bit RGB), and the diagnostic exchange
of §4.1 appears in both, so it is not resolution-gated as previously
suspected.

## 5. SET WINDOW descriptor [capture] [SCSI-2]

The 72-byte parameter list is the SCSI-2 form: an 8-byte header whose
bytes 6–7 hold the descriptor length (`0x0040` = 64), followed by a
64-byte window descriptor. Offsets below are **into the 72-byte
payload** (descriptor offset + 8).

| offset | size | field | observed |
|---|---|---|---|
| 6–7 | 2 | descriptor length | `0x0040` (64) |
| 8 | 1 | window ID | `0x00` front, `0x80` back |
| 9 | 1 | auto bit | `0x00` |
| 10–11 | 2 | **X resolution, dpi** | `0x0258`=600, `0x012C`=300 |
| 12–13 | 2 | **Y resolution, dpi** | same as X in all captures |
| 14–17 | 4 | upper-left X | `0` |
| 18–21 | 4 | upper-left Y | `0` |
| 22–25 | 4 | **scan width** | `0x27D8`=10200, `0x27D0`=10192 |
| 26–29 | 4 | **scan length** | `0x3390`=13200, `0xA1A8`=41384 |
| 30 | 1 | brightness | `0x00` |
| 31 | 1 | threshold | `0x00` |
| 32 | 1 | contrast | `0x00` |
| 33 | 1 | **image composition** | `0x05` (RGB colour) in *every* capture |
| 34 | 1 | **bits per pixel** | `0x08` |
| 35–47 | 13 | halftone, padding, bit order, compression | all `0x00` |
| 48–63 | 16 | vendor block | `c1 00 01 …` with `c0` at offset 61 |
| 64–67 | 4 | **paper width** | `0x27D8` = 10200 |
| 68–71 | 4 | **paper length** | `0x3390`, `0xA1AF` |

**Units.** Geometry is in **1/1200 inch**, independent of resolution:
10200/1200 = 8.5 in, 13200/1200 = 11 in. Pixel count follows as
`units × dpi / 1200` — the 300 dpi capture's 10200 gives 2550 px, and
the 600 dpi capture's 10192 gives 5096 px, both exactly matching the
pixel-size read. (The 600 dpi lineart session asked for 10192 rather
than 10200 so that its 1-bit line came to a whole 637 bytes.)

**Scan area vs paper size.** Offsets 22–29 are the area to digitise;
offsets 64–71 are the sheet's dimensions. They correspond to the two
distinct settings the app exposes (`br-x`/`br-y` and
`page-width`/`page-height`).

**Composition is always colour.** Image composition `0x05` and 8 bits
per pixel appear even in the session that requested lineart — the
protocol-level confirmation of §4.3.

## 6. Auto length detection [capture]

**ALD is enabled by MODE SELECT page `0x3C`, body byte 1 = `0x80`** —
the full page reads `00 00 00 00 3c 06 00 80 00 00 00 00` versus
`… 3c 06 00 00 …` for a fixed-size scan. Established by diffing an ALD
capture against a fixed-size one; it was the only page that differed.
Without it the scanner fills the whole requested window, so a driver
that merely asks for a long window gets a long image, not a
paper-length one.

With ALD enabled (`05-ald.log`, 300 dpi colour):

- The host sets the window **length to the maximum** (`0xA1A8` = 41,384
  units = 34.49 in) rather than the paper's length.
- The pixel-size read then reports that maximum as the line count
  (`0x286A` = 10,346 lines) — it is an **upper bound, not the true page
  length**.
- The device simply **stops sending at the sheet's trailing edge**. The
  host read 3,336 lines (25,520,400 bytes ÷ 7,650) and then received
  end-of-page in the usual way (status byte 9 = `0x02`, then sense).

So a page's real length is **discovered by reading until end-of-page**,
never announced in advance. A driver must therefore treat the line count
from the pixel-size read as a ceiling and size the final image from the
data actually received — which is what a streaming reader does anyway.

## 7. Initialization sequence [capture]

The device will not scan until this runs (observed identically in every
capture, and confirmed by a native implementation):

1. **SEND DIAGNOSTIC** with the 16-byte ASCII string `GET DEVICE ID`
   (space-padded), then **READ DIAGNOSTIC** (10 bytes). Diagnostics on
   this device are an ASCII command channel.
2. **TEST UNIT READY**, then a sensor read (vendor `0xC2`).
3. **SEND DIAGNOSTIC** with `SET PRE READMODE` plus 16 bytes of binary
   parameters: X and Y resolution (16-bit each), scan width and length
   (32-bit, 1/1200 in), composition `0x05`, then `00 00 E4`.
4. **MODE SELECT** ×6 — pages `0x3C`, `0x38`, `0x37`, `0x39`, `0x3A`,
   `0x33`. Only `0x3A` carries data in our captures (`80 C0`); the
   others are written with a zero body. Page `0x39` has an 8-byte body
   (14-byte list); the rest have 6 (12-byte list).
5. **SET WINDOW** for each window to be scanned (§5).
6. **SEND** with data type `0x88`: a 138-byte table (8-byte header plus
   two 64-byte quantization tables). Constant across captures; replay
   verbatim.
7. **vendor `0xF1`** subcommand `0x05`, then a final sensor read.

Then the scan proper (§4.2) may begin. Teardown after a batch uses
vendor `0xF1` subcommand `0x04` followed by a MODE SELECT.

### 7.1 Still open

- Whether any mode or resolution yields JPEG-compressed data (the
  quantization table is downloaded in every session, yet no capture has
  produced compressed output).
- MODE SELECT page layouts — the double-feed and background-colour
  settings the app exposes live here. Derive by diffing the 12/14-byte
  parameter blocks across sessions with those options toggled.
- Sensor bit assignments in the vendor `0xC2` block: capture while
  pressing Scan, loading paper, and opening the cover, then diff.
- The vendor block at descriptor offsets 48–63 (`c1 00 01 … c0`) is
  constant in every capture; its meaning is unknown but it can simply be
  replayed verbatim.
- Jam and cover-open sense codes.
- vendor `0xF1` subcommands (byte 1: `0x04` seen at teardown).
