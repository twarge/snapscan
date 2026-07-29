#!/usr/bin/env python3
"""Extract the data-out payload that follows a given command in a capture.

Used to compare parameter blocks (SET WINDOW, MODE SELECT) across scans
taken at different settings, so their field layouts can be derived by
diffing.

Usage: extract-payload.py <capture.log> <opcode-hex> [--index N]
Example: extract-payload.py docs/captures/02-scan.log 24
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from importlib import import_module

decode = import_module("decode-capture".replace("-", "_")) if False else None

# Reuse the sibling decoder's parser without renaming the file.
import re

HEADER = re.compile(
    r"^(IN |OUT) ep=0x([0-9a-f]{2}) req=(-?\d+) act=(-?\d+) status=(-?\d+)")
CMD_TAG = b"\x43"
CDB_OFFSET = 19


def parse(path: Path):
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
        elif current and line.strip() and re.fullmatch(r"[0-9a-f ]+", line.strip()):
            hex_lines.append(line.replace(" ", "").strip())
    if current:
        transfers.append((*current, bytes.fromhex("".join(hex_lines))))
    return transfers


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    path = Path(sys.argv[1])
    opcode = int(sys.argv[2], 16)
    want = 0
    if "--index" in sys.argv:
        want = int(sys.argv[sys.argv.index("--index") + 1])

    transfers = parse(path)
    found = 0
    for index, (direction, _, _, actual, _, payload) in enumerate(transfers):
        if direction != "OUT" or payload[:1] != CMD_TAG:
            continue
        if payload[CDB_OFFSET] != opcode:
            continue
        if found != want:
            found += 1
            continue
        # The data-out phase is the next OUT transfer that is not a command.
        for follower in transfers[index + 1:]:
            if follower[0] == "OUT" and follower[5][:1] != CMD_TAG:
                data = follower[5]
                print(f"# {path.name}: opcode 0x{opcode:02x} payload, {len(data)} bytes")
                for offset in range(0, len(data), 16):
                    chunk = data[offset:offset + 16]
                    print(f"{offset:3d}: {chunk.hex(' ')}")
                return 0
            if follower[0] == "OUT":
                break
        print("no data-out phase found after that command", file=sys.stderr)
        return 1
    print(f"opcode 0x{opcode:02x} #{want} not found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
