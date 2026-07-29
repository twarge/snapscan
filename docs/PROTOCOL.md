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
Returns a 12-byte block of sensor bits: the Scan/Function buttons, paper
loaded, cover open, and related switches. Bit assignments are **[open]**
— derive by toggling each physical condition and diffing the block
(press Scan, load paper, open the flap).

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

### 4.7 Still open

- Auto length detection: how a short page's true length is reported
  (presumably the pixel-size read after start, or the sense residual).
- Whether any mode or resolution yields JPEG-compressed data.
- MODE SELECT page layouts (double-feed behavior, background color).
- SET WINDOW descriptor field usage — the largest remaining gap, and
  the one a new driver most needs. Derive by capturing scans at several
  known geometries/resolutions/modes and diffing the 72-byte payload.
- Sensor bit assignments in the vendor `0xC2` block.
- Jam and cover-open sense codes.
