#!/usr/bin/env python3
"""Inject a USB bulk-transfer capture hook into libusb's sync.c.

Records every synchronous bulk transfer — direction, endpoint, requested
and actual length, status, and payload hex — to the file named by
SNAPSCAN_USB_TRACE. Inert unless that variable is set, so traced and
untraced builds behave identically.

This exists to record factual USB traffic from our own hardware for the
clean-room protocol spec (docs/CLEANROOM-STUDY.md); it is not part of the
shipping app's behavior. Idempotent: re-running on a patched tree is a
no-op.

Usage: add-usb-trace.py <path-to-libusb-source>
"""
import sys
from pathlib import Path

HOOK = r'''
/* --- SnapScan protocol-capture hook (see docs/CLEANROOM-STUDY.md) --- */
#include <stdio.h>
#include <stdlib.h>

static FILE *snapscan_trace_file(void)
{
	static FILE *file;
	static int tried;
	if (!tried) {
		const char *path = getenv("SNAPSCAN_USB_TRACE");
		tried = 1;
		if (path && *path) {
			file = fopen(path, "a");
			if (file)
				setvbuf(file, NULL, _IOLBF, 0);
		}
	}
	return file;
}

static void snapscan_trace_bulk(unsigned char endpoint,
	const unsigned char *buffer, int requested, int actual, int status)
{
	FILE *file = snapscan_trace_file();
	int i, shown;

	if (!file)
		return;

	fprintf(file, "%s ep=0x%02x req=%d act=%d status=%d\n",
		(endpoint & 0x80) ? "IN " : "OUT", endpoint, requested, actual,
		status);

	/* Image reads are megabytes; protocol meaning lives in the headers,
	 * so cap the dump and note the elision. */
	shown = actual;
	if (shown > 512)
		shown = 512;
	if (buffer && shown > 0) {
		for (i = 0; i < shown; i++) {
			fprintf(file, "%02x", buffer[i]);
			if ((i & 31) == 31)
				fprintf(file, "\n");
			else if ((i & 1) == 1)
				fprintf(file, " ");
		}
		if ((shown & 31) != 0)
			fprintf(file, "\n");
	}
	if (actual > shown)
		fprintf(file, "... %d more bytes\n", actual - shown);
	fprintf(file, "\n");
	fflush(file);
}
/* --- end capture hook --- */
'''

CALL = """	snapscan_trace_bulk(endpoint, buffer,
		length, transfer->actual_length, (int)transfer->status);

	libusb_free_transfer(transfer);
	return r;
}
"""

ANCHOR_INCLUDE = '#include "libusbi.h"\n'
ANCHOR_CALL = """	libusb_free_transfer(transfer);
	return r;
}
"""


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    sync = Path(sys.argv[1]) / "libusb" / "sync.c"
    source = sync.read_text()

    if "snapscan_trace_bulk" in source:
        print("libusb already has the capture hook")
        return 0

    if ANCHOR_INCLUDE not in source:
        print(f"error: include anchor not found in {sync}", file=sys.stderr)
        return 1
    source = source.replace(ANCHOR_INCLUDE, ANCHOR_INCLUDE + HOOK, 1)

    # The first occurrence of the free/return tail is do_sync_bulk_transfer's;
    # the control-transfer path above it returns differently.
    marker = "static int do_sync_bulk_transfer"
    start = source.index(marker)
    tail = source.index(ANCHOR_CALL, start)
    source = source[:tail] + CALL + source[tail + len(ANCHOR_CALL):]

    sync.write_text(source)
    print(f"capture hook added to {sync}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
