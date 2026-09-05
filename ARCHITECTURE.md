# ble-scanner — Architecture

**Targets:** Zig 0.16.0 · Windows 10/11 + Linux
**Shape:** full-screen terminal UI, passive BLE advertisement scanner

This document describes the system as built. The milestone history at the
end doubles as the roadmap.

---

## 1. Overview

ble-scanner continuously captures BLE advertisements, aggregates them
per device, decodes the payload through a device-type database (Bluetooth
SIG tables + vendor decoders) and renders everything in a full-screen TUI.
It never pairs with or connects to anything — it only observes what
devices broadcast publicly.

### Non-goals

- Pairing, connections, GATT reads/writes (scanner only)
- Decrypting encrypted beacons (Find My, some Xiaomi payloads)
- Mouse UI; keyboard only
- Persistence beyond opt-in `--log` recording

---

## 2. Platform strategy

Userland apps cannot open raw HCI sockets on Windows — the kernel owns the
radio and there is no public HCI API. The compromise that keeps the decode
pipeline byte-identical on both platforms:

| Platform | Capture | Notes |
|---|---|---|
| Linux | **true raw HCI socket** (`AF_BLUETOOTH`, `BTPROTO_HCI`, raw channel) | needs root or `setcap cap_net_raw,cap_net_admin+ep`; full controller access, legacy + extended reports |
| Windows | **WinRT watcher** surfaced as raw AD data sections | user-mode, no elevation; every AD structure of the advertisement is exposed, which is the same information an HCI LE advertising report carries |

One normalization — `AdvEvent` — is the single contract between capture and
everything downstream. If literal raw bytes on Windows ever become a
requirement, a libusb/WinUSB dongle backend can slot in behind the same
interface.

---

## 3. Structure

```
                 ┌────────────────────────────────────────────────┐
                 │                  main thread                    │
                 │  App state ── Renderer (cell buffer + diff)     │
                 │      ▲ events        ▲ size polls (each draw)   │
                 └──────┼───────────────┼──────────────────────────┘
                        │               │
   ┌────────────────────┴───┐      ioctl TIOCGWINSZ (Linux)
   │  EventBus (mutex+cond) │      CONSOLE GET_SCREEN_BUFFER_INFO (Win)
   └───▲──────────▲─────▲───┘
       │          │     │
  input thread  backend thread   replay file reader
  (stdin ESC /  (PS child pro-   (in-process, synthetic)
   ReadConsole-  cess on Win /
   InputW)       raw HCI socket
                 on Linux)
```

```
src/
├── main.zig            CLI, run modes: interactive / headless capture / selftest
├── app.zig             view state machine, key handling, detail-view builder
├── store.zig           per-device aggregation (RSSI stats, merged sections,
│                       name history)
├── bus.zig             event bus + backend lifecycle events
├── filter.zig          the '/' filter query language (parse + match)
├── log.zig             AdvEvent → JSONL (same schema replay consumes)
├── ble/
│   ├── model.zig       AdvEvent / AdSection / AdvType / AddrType — the contract
│   ├── scanner.zig     backend kind selection (auto → per-OS default)
│   ├── win_rt.zig      Windows default: native WinRT/COM watcher (see §4.1)
│   ├── win_ps.zig      Windows fallback: spawn + parse the PowerShell helper
│   ├── win_scanner.ps1 embedded watcher script (inline C#, see §4.2)
│   ├── linux_hci.zig   raw HCI socket backend
│   └── replay.zig      JSONL parse + paced re-emission
├── decode/
│   ├── ad.zig          AD-structure walker + raw [len][type] splitter
│   ├── classify.zig    rule engine → Kind + label
│   └── vendors.zig     vendor payload decoders (Continuity, CDP, Xiaomi, …)
├── db/
│   ├── devices.zig     classification rules (hand-maintained)
│   ├── companies.zig   SIG company identifiers (generated, 4024 entries)
│   ├── services.zig    SIG service UUIDs (generated, 789 entries)
│   └── appearance.zig  SIG GATT appearances (generated)
├── tui/
│   ├── terminal.zig    raw mode/restore, VT setup, size queries
│   ├── screen.zig      cell grid, diffed ANSI rendering, ASCII fallback
│   ├── widgets.zig     list/detail/help/filter/scrollbar drawing
│   └── input.zig       key decoding (shared ESC parser on both platforms)
└── tools/gen_db.py     SIG YAML → generated tables
```

---

## 4. Capture backends

### 4.1 Linux — raw HCI socket

- `socket(AF_BLUETOOTH, SOCK_RAW|SOCK_CLOEXEC, BTPROTO_HCI)`, bound to
  `--adapter hciN` (default hci0) on the raw channel.
- Commands over the socket: `LE Set Scan Parameters (0x200B)` — active
  scan, 10 ms interval/window, public address, accept-all filter — and
  `LE Set Scan Enable (0x200C)` with the duplicate filter off (the store
  deduplicates and wants every RSSI sample).
- Events consumed: `Command Complete (0x0E)` for status checking,
  `LE Meta (0x3E)` subevents `0x02` (legacy advertising report) and `0x0D`
  (extended advertising report, including TX power).
- The report's concatenated AD structures are split into `AdSection`s with
  the same decoder the Windows path uses.

### 4.2 Windows — native WinRT/COM watcher (`win-rt`, default)

A single-process backend: loads `combase.dll`, activates
`BluetoothLEAdvertisementWatcher` via `RoGetActivationFactory`, and consumes
`Received` events through a hand-written COM vtable handler — all in Zig,
no PowerShell, no C# compilation, ~100 ms startup. AD sections arrive via
`IBluetoothLEAdvertisement::get_DataSections`, and section bytes through the
native-only `IBufferByteAccess` from `robuffer.h` (not in any .winmd — the
IID must be hardcoded). The subtlety that cost the most time: WinRT vtable
slot order is not always documented for non-projected interfaces, so the
layouts here were confirmed via .NET reflection over the metadata.

Names come as HSTRING (UTF-16) and are transcoded to UTF-8 with an ASCII
fast path. The COM handler's reference count is atomic — callbacks arrive on
threadpool threads.

### 4.3 Windows — PowerShell helper with inline C# watcher (`win-ps`, fallback)

Kept as a selectable fallback (`--backend win-ps`) for environments where
the native path misbehaves. The interesting constraint discovered during
development: **PowerShell scriptblocks cannot receive WinRT events.**
`Register-ObjectEvent` rejects WinRT event sources outright, and handlers
attached via `add_Received` never fire while the pipeline is blocked. So
`win_scanner.ps1`:

1. embeds a C# `BleWatch` class that subscribes to
   `BluetoothLEAdvertisementWatcher.Received` and writes one JSON object
   per line (address, address type, advertisement type, RSSI, local name,
   **all raw AD data sections as hex**, timestamp);
2. compiles it once with the in-box .NET Framework `csc.exe`, referencing
   the per-namespace `.winmd` files from `System32\WinMetadata` (there is
   no monolithic `Windows.winmd` on current Windows 11);
3. caches the assembly in `%TEMP%\ble-scanner\` keyed by a SHA-256 of the
   embedded source, so subsequent launches start instantly.

`win_ps.zig` spawns it via `powershell -EncodedCommand` (Base64 UTF-16LE —
no temp script files, no quoting hazards) with piped stdout, and parses
lines with the same JSONL parser as `replay`. Status/errors are reported
in-band as `{"status":…}` / `{"error":…}` lines and surfaced as backend
lifecycle events on the bus.

### 4.4 Replay

`--replay FILE` re-emits recorded events with capped pacing; timestamps
are shifted so "last seen" reads live. The same parser backs the
`--selftest` render check, which runs the entire UI headless against a
capture with scripted key presses — the CI-able smoke test.

---

## 5. Data flow and memory

- Backends heap-allocate each `AdvEvent` (one backing buffer for name +
  section payloads) and hand ownership through the bus. The store copies
  what it needs and frees the event; every path that drops an event frees
  it, which keeps the debug allocator silent.
- The **store merges sections per type** across a device's ADV and
  SCAN_RSP frames: a name-only scan response must not wipe the
  manufacturer data seen in the preceding advertisement. Latest non-empty
  section per type wins; up to three previously distinct names are kept
  as history.
- The renderer is a double-buffered cell grid flushed as ANSI diffs;
  the terminal size is polled each frame (no signal handlers needed).

---

## 6. Device identification

Tried in order, first match wins:

1. **Rule table** (`db/devices.zig`): payload fingerprints
   (manufacturer company id + payload prefix, service-data/service UUID)
   and advertised-name prefixes. Adding a rule is the standard way to
   teach the scanner a new device; real captured payloads become unit
   tests.
2. **GATT appearance** (0x19 section) via the generated category table,
   including keyboard/mouse subcategories.
3. **Service-UUID heuristics** (HID, Heart Rate, Thermometer, …).

Vendor payload decoders (`decode/vendors.zig`) render the DECODED PAYLOAD
section of the detail view — Apple Continuity including stacked TLVs,
AirPods proximity pairing (model, ear state, pairing code), Microsoft
CDP/Swift Pair with UTF-16 device name, Xiaomi Mi Beacon (product table,
MAC, encryption detection), Fast Pair model, Exposure Notification RPI,
Eddystone UID/URL/TLM, Find My Device / Quick Share / SmartThings Find
ephemeral IDs.

The generated tables come from the official SIG assigned-numbers YAML
(`tools/gen_db.py`); only `devices.zig` is hand-maintained.

---

## 7. Testing

- **Unit tests** (`zig build test`): AD parsing, section splitting,
  classification rules, vendor decoders against real captured payloads,
  filter parse/match, store aggregation/merging/name history, renderer
  diffs, table sortedness (comptime-enforced where applicable).
- **Selftest** (`--selftest --replay FILE`): scripted keys drive the real
  UI headless; screen contents are dumped as text and asserted on.
- **Live capture loop**: `--seconds N --log FILE` validates a backend
  end-to-end without a terminal and produces replayable captures.
- Cross-compilation for `x86_64-linux` is kept green from Windows.

---

## 8. History / roadmap

| Milestone | Status |
|---|---|
| M0 — TUI core, replay backend, selftest | done |
| M1 — Linux raw HCI backend | done (code); on-hardware pass still welcome |
| M2 — Windows WinRT backend | done, validated against real radios |
| M3 — SIG tables, rule engine, vendor decoders | done, extended through four field captures |
| M4 — raw view, ASCII fallback, name history, filter, scrollbar | done |

Ideas welcome: mouse support (wheel/click), export of the filtered view,
detail-view scrollbar, a D-Bus BlueZ backend as a privilege-free Linux
alternative, decoding more Xiaomi payloads.
