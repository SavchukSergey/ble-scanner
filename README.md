# ble-scanner

A full-screen terminal UI for watching the Bluetooth Low Energy traffic
around you — for Windows and Linux, in pure Zig (std only).

ble-scanner passively lists every device that is advertising, and turns raw
advertisement bytes into meaningful information: it knows all 4000+
Bluetooth SIG company identifiers, GATT appearances and service UUIDs, and
decodes vendor formats such as Apple Continuity (AirPods, Find My), iBeacon,
Eddystone, Google Fast Pair / Quick Share / Find My Device, Microsoft Swift
Pair, Xiaomi Mi Beacon and Samsung SmartThings Find.

```
 ble-scanner · win-ps · sort: last seen                              13 devices · 18:32:07
 ADDRESS           T  NAME                                    RSSI     LAST COMPANY            TYPE
 AA:BB:CC:00:11:22 *  Amazfit Band 7                          ▃ -67    2s   Anhui Huami Infor… Amazfit
 D4:CA:6E:12:34:56 *  (unknown)                               ▄ -58    2s   Xiaomi Inc.        Xiaomi device
 10:2A:B3:CD:EF:01 *  (unknown)                               ▂ -74    3s   Apple, Inc.        Exposure Notif…
 F0:0D:BA:11:22:33 *  (unknown)                               ▁ -84    3s   Google LLC         Eddystone beac…
 DE:AD:BE:E0:00:01    (unknown)                               ▂ -77    3s   Microsoft          Swift Pair
 7A:D9:2C:31:41:52    Pixel 8                                 ▃ -68    4s   Google             Fast Pair
 CC:C2:60:12:34:56 *  K380                                    ▄ -58   14s  Human Interface D… Keyboard
 E7:B1:0A:AA:BB:CC *  (unknown)                               ▂ -79   20s  Apple, Inc.        iBeacon
 88:66:A5:44:55:66 *  AirPods Pro                             ▃ -66   30s  Apple, Inc.        AirPods nearby
 ↑↓ select · ⏎ details · / filter · r raw · s sort · c clear · p pause · ? help · q quit
```

Opening a device (`⏎`) shows everything captured: identity with name
history, RSSI statistics and a signal-strength sparkline, advertised
services, **decoded payload fields** (e.g. AirPods model + pairing code,
Eddystone URL, Xiaomi product, Swift Pair device name) and the raw hex.

## Features

- Live scanning on Windows (WinRT watcher) and Linux (raw HCI socket),
  one platform-neutral event model
- Device list with sorting, scrollbar, colored RSSI bars, age
- Radar view (`m`): approximate distance rings around you, animated sweep,
  nearest-devices readout
- Detail view with vendor-decoded payloads, SIG names, GATT appearance
- Field-aware filter: `name:airpods company:google rssi:-70`
- Record (`--log`) and replay (`--replay`) captures as plain JSONL
- Headless capture mode and terminal-free `--selftest` render check
- `--ascii` fallback for terminals with hostile fonts
- Zero dependencies; 40 unit tests

## Requirements

- Zig 0.16.0 (to build)
- A Bluetooth adapter (to scan) — or use `--replay` with any capture
- A terminal with UTF-8 + ANSI support (Windows Terminal recommended;
  plain conhost works on Win10+)

## Build & run

```sh
zig build run --                                  # live scan (Windows)
zig build run --                                  # live scan (Linux; needs root or setcap)
zig build run -- --replay fixtures/demo.jsonl     # browse a capture, no radio needed
zig build test                                    # run the test suite
```

Linux privilege setup (raw HCI sockets require capabilities):

```sh
sudo setcap cap_net_raw,cap_net_admin+ep zig-out/bin/ble-scanner
```

or just run under `sudo`. On Windows no elevation is needed.

### Recording and replaying

```sh
zig build run -- --seconds 30 --log capture.jsonl   # headless capture
zig build run -- --replay capture.jsonl             # browse it later / elsewhere
zig build run -- --log session.jsonl                # also record while watching live
```

Captures are plain JSONL — one advertisement per line, the same schema the
Windows backend emits — which makes them shareable bug reports and the raw
material for new device-type decoders.

### Keys

`↑↓/jk` select · `⏎` details · `/` filter · `m` radar · `r` raw hex view · `s`
sort · `c` clear · `p` pause · `?` help · `q` quit. Detail view: `↑↓/jk` scroll,
`PgUp/PgDn`, `g/G`, `Esc` back. `Esc` in the list clears the active filter.

The radar view (`m`) plots devices on log-scale distance rings estimated from
signal strength (advertised TX power when present). It deliberately shows no
bearing — a single antenna cannot hear direction. Press `s` inside the radar
for **map mode**: a range-only SLAM solver (classical MDS init + SMACOF
spring relaxation) builds a 2D map of device positions from distances
observed while you walk — walk an L-shape or loop to make the geometry
observable; the map is correct up to rotation/mirror. `x` resets the solve.

`↑↓/jk` walk devices nearest-first (selection bracketed on the chart, listed
in the NEAREST panel, with a name/distance readout), `⏎` opens details and
`Esc` returns to the chart. Good for "walk toward the strong signal" hunting.

### Filtering

`/` opens a filter prompt; terms AND-combine, case-insensitively:

```
apple                 # substring of address, name, company or type
mac:AA:BB             # address substring
name:airpods          # advertised-name substring
company:google        # SIG company-name substring
type:tracker          # device-type substring
rssi:-70              # last RSSI >= -70 (closer than)
rssi:<=-90            # explicit comparisons also work
name:mi type:band     # combine freely
```

## How devices get identified

Three identification vectors, tried in order:

1. **Rule table** (`src/db/devices.zig`) — payload fingerprints
   (company id + prefix + service UUID) and name prefixes; first match wins
2. **GATT appearance** — the advertised device category
   (watch / keyboard / thermometer / headphones / …)
3. **Service-UUID heuristics** — HID, Heart Rate, Weight Scale, …

The underlying tables are generated from the official Bluetooth SIG
assigned-numbers data (all company identifiers, 789 service UUIDs, GATT
appearances):

```sh
git clone --depth 1 https://bitbucket.org/bluetooth-SIG/public sig
python tools/gen_db.py sig/assigned_numbers
```

Found a device that shows as "unknown"? [Contributing](CONTRIBUTING.md)
describes how to turn a `--log` capture into a new rule or decoder —
it's usually one line.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design: the platform-neutral
advertisement contract, the three capture backends (including why the
Windows one embeds inline C#), the rendering pipeline and the test
strategy.

## License

[MIT](LICENSE) © Serhii Savchuk. The generated SIG tables derive from
Bluetooth SIG assigned-numbers data.

## Use responsibly

ble-scanner only observes what devices voluntarily broadcast in public. Use
it to understand your environment, debug your gadgets, and satisfy your
curiosity — not to track people.
