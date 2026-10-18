#!/usr/bin/env -S python3 -I
"""The slots of a rendition's file, read from the header's `sidx`.

A rendition (stream-server `server/src/rendition/layout.rs`) is a header
(`ftyp` + `moov` + `sidx`, and a second `sidx` for the sound in an estimated
layout with sound) followed by one slot per segment. The video `sidx` holds
two references a slot: the first part, which starts with a SAP and carries
the slot's duration, and the rest, which lasts nothing. A slot therefore
begins at every reference that starts with a SAP. A plain `sidx` with one
reference a segment reads the same way.

    python3 -I tool/rendition_slots.py header-len <file>
        the header's length in bytes; exit 2 and the length the file must
        have when it ends inside the header
    python3 -I tool/rendition_slots.py list <file> [--json]
        every slot: index, byte offset, size, start time in seconds
    python3 -I tool/rendition_slots.py offset <file> <k>
        slot k's byte offset

<file> needs only the header; the rest of the file is not read.
"""

import json
import struct
import sys

HEADER_BOXES = (b"ftyp", b"moov", b"sidx")


class Truncated(Exception):
    """The file ends inside the header: `need` bytes are needed."""

    def __init__(self, need):
        super().__init__(f"the file ends inside the header: {need} bytes needed")
        self.need = need


def boxes(data):
    """The top-level boxes at the file's start, while they are header boxes:
    (type, offset, size). Stops at the first box that is not one, or raises
    Truncated when a header box runs past the end of `data`."""
    out = []
    at = 0
    while True:
        if at + 8 > len(data):
            raise Truncated(at + 16)
        size, kind = struct.unpack(">I4s", data[at : at + 8])
        head = 8
        if size == 1:
            if at + 16 > len(data):
                raise Truncated(at + 16)
            size = struct.unpack(">Q", data[at + 8 : at + 16])[0]
            head = 16
        if kind not in HEADER_BOXES:
            return out
        if size < head:
            raise ValueError(f"box {kind!r} at {at} has size {size}")
        if at + size > len(data):
            raise Truncated(at + size + 8)
        out.append((kind, at, size))
        at += size


def header_len(data):
    """Where the first slot begins: the end of the header boxes."""
    found = boxes(data)
    if not found or found[0][0] != b"ftyp":
        raise ValueError("not a rendition: the file does not start with ftyp")
    if not any(kind == b"sidx" for kind, _, _ in found):
        raise ValueError("not a rendition: the header has no sidx")
    _, at, size = found[-1]
    return at + size


def parse_sidx(data, at, size):
    """One `sidx` box: its timescale, earliest presentation time, the
    absolute offset its references start at, and the references as
    (referenced_size, duration, starts_with_sap)."""
    body = data[at + 8 : at + size]
    version = body[0]
    timescale = struct.unpack(">I", body[8:12])[0]
    if version == 0:
        earliest, first_offset = struct.unpack(">II", body[12:20])
        rest = 20
    else:
        earliest, first_offset = struct.unpack(">QQ", body[12:28])
        rest = 28
    count = struct.unpack(">H", body[rest + 2 : rest + 4])[0]
    refs = []
    for i in range(count):
        word, duration, sap = struct.unpack(
            ">III", body[rest + 4 + 12 * i : rest + 16 + 12 * i]
        )
        if word >> 31:
            raise ValueError("a sidx that references another sidx is not a rendition's")
        refs.append((word & 0x7FFFFFFF, duration, bool(sap >> 31)))
    return timescale, earliest, at + size + first_offset, refs


def slots(data):
    """Every slot of the first `sidx` (the video's): dicts of index, offset,
    size, start (seconds)."""
    end = header_len(data)
    sidx = next((at, size) for kind, at, size in boxes(data) if kind == b"sidx")
    timescale, earliest, offset, refs = parse_sidx(data, *sidx)
    out = []
    time = earliest
    for size, duration, sap in refs:
        if sap or not out:
            out.append(
                {
                    "index": len(out),
                    "offset": offset,
                    "size": size,
                    "start": time / timescale,
                }
            )
        else:
            out[-1]["size"] += size
        offset += size
        time += duration
    if out and out[0]["offset"] != end:
        raise ValueError(
            f"the first slot begins at {out[0]['offset']}, not where the header ends ({end})"
        )
    return out


def main(argv):
    if len(argv) < 2 or argv[0] not in ("header-len", "list", "offset"):
        sys.stderr.write(__doc__)
        return 64
    with open(argv[1], "rb") as f:
        data = f.read()
    try:
        if argv[0] == "header-len":
            print(header_len(data))
        elif argv[0] == "list":
            found = slots(data)
            if "--json" in argv[2:]:
                print(json.dumps(found))
            else:
                for slot in found:
                    print(
                        f"{slot['index']}\t{slot['offset']}\t{slot['size']}\t{slot['start']:.3f}"
                    )
        else:
            if len(argv) != 3:
                sys.stderr.write(__doc__)
                return 64
            found = slots(data)
            k = int(argv[2])
            if not 0 <= k < len(found):
                sys.stderr.write(f"no slot {k}: the file has {len(found)}\n")
                return 1
            print(found[k]["offset"])
    except Truncated as error:
        print(error.need)
        sys.stderr.write(f"{error}\n")
        return 2
    except ValueError as error:
        sys.stderr.write(f"{error}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
