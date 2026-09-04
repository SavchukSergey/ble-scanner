#!/usr/bin/env python3
"""Build a deduplicated regression corpus from wild captures.

Scans captures/wild*.jsonl and emits one representative event per unique
"event type", where uniqueness ignores the device address and volatile
payload bytes:

  key = (etype, atype, name, [(sec_type, len, first <=6 bytes of data
         with the device MAC zeroed out)])

The emitted events are original, unmodified lines — only the DEDUP KEY is
normalized, so the corpus replays real bytes through the whole pipeline.
Run it after new captures, then verify with:

    ble-scanner --selftest --replay captures/all-unique-types.jsonl
"""
import glob
import json
import os
import sys

CAPTURES = sys.argv[1] if len(sys.argv) > 1 else "captures"
OUT = os.path.join(CAPTURES, "all-unique-types.jsonl")


def key_of(ev):
    addr = bytes.fromhex(ev["mac"].replace(":", ""))
    variants = (addr, addr[::-1])
    secs = []
    for s in ev.get("secs", []):
        data = bytes.fromhex(s["d"]) if s["d"] else b""
        head = data[:6]
        for v in variants:
            head = head.replace(v, b"\x00" * 6)
        secs.append((s["t"], len(data), head.hex()))
    return (ev["etype"], ev["atype"], ev.get("name"), tuple(sorted(secs)))


def main():
    files = sorted(glob.glob(os.path.join(CAPTURES, "wild*.jsonl")))
    if not files:
        sys.exit(f"no wild*.jsonl captures found in {CAPTURES}")
    seen = {}
    total = 0
    for path in files:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                total += 1
                ev = json.loads(line)
                k = key_of(ev)
                if k not in seen:
                    seen[k] = (line, ev, os.path.basename(path))

    with open(OUT, "w", encoding="utf-8") as f:
        for line, _, _ in seen.values():
            f.write(line + "\n")

    # Summary by identification shape.
    kinds = {}
    for _, ev, src in seen.values():
        mfr = next((s["d"] for s in ev.get("secs", []) if s["t"] == 255), "")
        svc = next((s["d"] for s in ev.get("secs", []) if s["t"] == 22), "")
        if mfr:
            label = "mfr " + mfr[:4]
        elif svc:
            label = "svc " + svc[:4]
        elif ev.get("name"):
            label = "name"
        else:
            label = "plain"
        kinds.setdefault(label, []).append(src)
    print(f"{total} events from {len(files)} captures -> {len(seen)} unique types -> {OUT}")
    for label in sorted(kinds, key=lambda l: -len(kinds[l])):
        srcs = sorted(set(kinds[label]))
        print(f"  {label:10s} {len(kinds[label]):4d}  ({', '.join(srcs)})")


if __name__ == "__main__":
    main()
