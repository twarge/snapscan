# ScanSnap iX500 USB protocol

A factual specification of the wire protocol, for an original
Apache-licensed driver (see CLEANROOM-STUDY.md for method and rationale).

**Provenance** is recorded per section:

- **[capture]** — observed directly in our own USB captures of this
  scanner (`docs/captures/`, recorded with `scripts/capture-session.sh`).
- **[SCSI-2]** — the published SCSI-2 standard (X3.131-1994), whose
  scanner device class defines most commands and data formats here.
- **[open]** — not yet established; needs a capture or experiment.

Status: **in progress.** Framing and enumeration are established;
the scan sequence needs a capture with paper loaded.

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
| 0xC2 | vendor: hardware status | sensors |
| 0xF1 | vendor: scanner control | setup |

Expected but not yet in a capture (need a scan session): SCAN (0x1B),
READ (0x28), OBJECT POSITION (0x31), GET WINDOW (0x25). [open]

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

### 4.2 Scan [open]

Needs a capture with paper loaded. Open questions to settle there:

- Does color data arrive JPEG-compressed or as raw RGB rows? (A
  quantization-table download is required at setup, which suggests JPEG,
  yet our current sessions surface raw rows to the app.)
- READ chunking: transfer sizes, and how end-of-page is signaled.
- Duplex: how front/back streams are selected and interleaved.
- Auto length detection: how the actual page length is reported.
- Empty feeder and jam: which status/sense codes appear.
