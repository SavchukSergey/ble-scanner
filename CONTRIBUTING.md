# Contributing to ble-scanner

Thanks for your interest in improving ble-scanner! Bug reports, new device
decoders and platform fixes are all welcome.

## Getting started

```sh
git clone <repository-url>
cd ble-scanner
zig build test          # 40+ unit tests
zig build run -- --selftest --replay fixtures/demo.jsonl   # render check, no terminal needed
zig build run -- --replay fixtures/demo.jsonl              # browse the demo capture
zig build run --                                          # live scan (needs a Bluetooth adapter)
```

- **Zig 0.16.0** is required (the std API surface moves between releases;
  the version is pinned in `build.zig.zon`).
- No third-party dependencies — std only.

## Project layout

| Path | Purpose |
|---|---|
| `src/main.zig` | CLI entry, arg parsing, run modes (interactive / capture / selftest) |
| `src/app.zig` | View state machine, key handling, detail-view construction |
| `src/store.zig` | Per-device aggregation (RSSI stats, merged sections, name history) |
| `src/bus.zig` | Event bus connecting backend threads to the render loop |
| `src/filter.zig` | The `/` filter query language |
| `src/ble/` | Capture backends (`win_ps`, `linux_hci`, `replay`) + the shared `model.zig` contract |
| `src/decode/` | AD-structure parsing, classification, vendor payload decoders |
| `src/db/` | SIG-generated tables + the classification rule table |
| `src/tui/` | Terminal setup, cell-grid renderer, widgets, input decoding |
| `tools/gen_db.py` | Regenerates the SIG tables from assigned-numbers data |

See `ARCHITECTURE.md` for the full design.

## Adding a device type

This is the most common contribution. The workflow:

1. **Capture** the device:
   ```sh
   zig build run -- --seconds 30 --log wild.jsonl
   ```
2. **Inspect** it: `zig build run -- --replay wild.jsonl`, select the
   device, press `⏎`, and study the RAW ADVERTISING DATA section — the
   manufacturer id, payload bytes and service UUIDs are what you'll match on.
3. **Add a rule** in `src/db/devices.zig` (first match wins):
   ```zig
   .{ .company = 0x0157, .kind = .band, .detail = "Amazfit" },
   .{ .svc = 0xFD69, .kind = .tracker, .detail = "SmartThings Find" },
   .{ .name_prefix = "WHOOP", .kind = .band, .detail = "WHOOP fitness band" },
   ```
   Pick a `Kind` from the enum (add one if nothing fits) and keep the
   `detail` short — it's a list column.
4. **Optional**: if the payload has structure worth showing, add a decoder
   in `src/decode/vendors.zig` that writes `key: value` lines through an
   `std.Io.Writer`, and register it in `decodeMfr`/`decodeSvcData`.
   Real captured payloads make the best test cases — add them as unit tests.
5. `zig build test` — the sorted-table and rule sanity tests keep
   everything consistent.

## Regenerating the SIG tables

```sh
git clone --depth 1 https://bitbucket.org/bluetooth-SIG/public sig
python tools/gen_db.py sig/assigned_numbers
```

`tools/gen_db.py` also accepts a path via the `SIG_NUMBERS` environment
variable. Only touch the non-generated files in `src/db/` by hand.

## Commit & PR conventions

- Use Conventional Commit prefixes (`feat:`, `fix:`, `docs:`, …) — the
  changelog is generated from them.
- Include a real captured payload (as a test fixture or inline test data)
  with device-type contributions when possible.
- Keep the public surface of `src/ble/model.zig` stable — all three
  backends and the whole decode pipeline depend on it.
- `zig build test` must pass; run the selftest if you touched the TUI.

## Reporting issues

Include: OS, terminal, `zig version`, how you ran the tool, and ideally a
`--log` capture (JSONL) that reproduces the problem.
