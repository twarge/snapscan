#!/usr/bin/env python3
"""Turn a raw USB capture into an annotated protocol transcript.

Reads logs written by the libusb capture hook (scripts/add-usb-trace.py)
and labels each exchange: the Fujitsu USB framing, the SCSI command
inside it, and the status packet. Command names come from the SCSI-2
standard command set; unknown opcodes are reported as raw hex rather than
guessed.

Usage: decode-capture.py docs/captures/<name>.log
"""
import re
import sys
from pathlib import Path

# SCSI-2 standard commands (public standard) plus vendor-range opcodes,
# named only where our own captures/experiments confirm the behavior.
OPCODES = {
    0x00: "TEST UNIT READY",
    0x03: "REQUEST SENSE",
    0x12: "INQUIRY",
    0x15: "MODE SELECT",
    0x16: "RESERVE UNIT",
    0x17: "RELEASE UNIT",
    0x1A: "MODE SENSE",
    0x1B: "SCAN",
    0x1C: "READ DIAGNOSTIC",
    0x1D: "SEND DIAGNOSTIC",
    0x24: "SET WINDOW",
    0x25: "GET WINDOW",
    0x28: "READ",
    0x2A: "SEND",
    0x31: "OBJECT POSITION",
    0xC0: "vendor 0xC0",
    0xC1: "vendor 0xC1",
    0xC2: "vendor 0xC2",
    0xF1: "vendor 0xF1",
}

HEADER = re.compile(
    r"^(IN |OUT) ep=0x([0-9a-f]{2}) req=(-?\d+) act=(-?\d+) status=(-?\d+)")


def parse(path: Path):
    """Yields (direction, endpoint, requested, actual, status, payload)."""
    transfers = []
    current = None
    hex_lines: list[str] = []
    for line in path.read_text().splitlines():
        match = HEADER.match(line)
        if match:
            if current:
                transfers.append((*current, bytes.fromhex("".join(hex_lines))))
            direction, endpoint, requested, actual, status = match.groups()
            current = (direction.strip(), int(endpoint, 16), int(requested),
                       int(actual), int(status))
            hex_lines = []
        elif current and re.fullmatch(r"[0-9a-f ]+", line.strip()) and line.strip():
            hex_lines.append(line.replace(" ", "").strip())
    if current:
        transfers.append((*current, bytes.fromhex("".join(hex_lines))))
    return transfers


def describe(direction, endpoint, requested, actual, status, payload) -> str:
    # The Fujitsu USB wrapper: 0x43-tagged command packet carrying a CDB.
    if direction == "OUT" and payload[:1] == b"\x43" and len(payload) >= 12:
        cdb = payload[10:]
        name = OPCODES.get(cdb[0], f"opcode 0x{cdb[0]:02x}")
        return (f"CMD  {name}\n"
                f"     wrapper: {payload[:10].hex(' ')}\n"
                f"     cdb:     {cdb[:12].hex(' ')}")
    if direction == "IN " and actual == 13:
        return f"STAT {payload.hex(' ')}"
    if direction == "OUT":
        return f"DATA out {actual} bytes: {payload[:32].hex(' ')}" + (
            " ..." if actual > 32 else "")
    return f"DATA in  {actual} bytes: {payload[:32].hex(' ')}" + (
        " ..." if actual > 32 else "")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = Path(sys.argv[1])
    transfers = parse(path)
    print(f"# {path.name}: {len(transfers)} transfers\n")
    for index, transfer in enumerate(transfers):
        print(f"[{index:04d}] ep=0x{transfer[1]:02x} status={transfer[4]}")
        print(describe(*transfer))
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
