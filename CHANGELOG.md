# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.2] - 2026-09-04

### Added
- Range-only SLAM map mode: a 2D map of device positions built from
  distance estimates gathered while walking (no odometry). Classical-MDS
  initialization over the shortest-path distance matrix, SMACOF stress
  majorization with robustness-weighted springs, soft motion constraints
  between observer steps. `m` cycles list → rings → map; `z` toggles
  you-centered camera; `x` resets the solve.
- Radar view with log-scale distance rings, scrollable nearest-devices
  panel, selection brackets and detail-view round-trip.
- Xiaomi Mi Beacon sensor object decoding (battery, temperature, humidity)
  with corrected frame-control bits verified against real LYWSD03MMC
  hardware.
- Device-type rules from live captures: Tuya smart-home devices, YUNMAI
  smart scales, Wi-Fi access-point provisioning beacons, BYD vehicles,
  WHOOP bands, Find My nearby (Apple 0x12), Find My Device network
  (short discovery frames), Quick Share / Nearby.
- Full service-UUID display: 16/32/128-bit lists decoded from
  little-endian, names shown as text, GATT appearance with SIG names,
  vendor-specific label for unknown UUIDs.
- Regression corpus builder (`tools/make_corpus.py`): deduplicates wild
  captures into a replayable file covering every observed payload type.
- Local time display (Windows: `GetTimeZoneInformation`; Linux: TZif
  /etc/localtime parsing), replacing the previous UTC clock.

### Fixed
- Remote crash: raw appearance value ≥ 0x4000 overflowed the category
  lookup cast — any BLE device in radio range could kill the scanner.
- Linux extended advertising reports: Tx_Power/RSSI/Data_Length were
  read 4 bytes early (RSSI came from Primary_PHY; data started inside
  Direct_Address).
- Use-after-free: detached input/backend threads writing into a freed
  event bus at shutdown.
- Map-view crash on wide terminals (meter-grid coordinate went
  negative in `@intFromFloat`); now bounds-checked through `putF()`.
- RSSI −127 "not measured" markers no longer pollute statistics,
  history or radar placement.
- AD sections merge correctly across ADV and SCAN_RSP frames (a
  name-only scan response no longer wipes manufacturer data).
- iBeacon prefix no longer misread as an Apple Continuity TLV.
- 13 bugs total found by systematic audit (allocator leaks, off-by-one
  errors, OOM paths, race conditions, silent data truncation).

## [0.1.0] - 2026-09-04

Initial public release.

### Added

- Full-screen TUI: live device list with address, name, colored RSSI bars,
  age, SIG company name and decoded device type; scrollable per-device
  detail view with identity, radio statistics, RSSI history sparkline,
  services, decoded payloads and raw hex; help overlay; scrollbar.
- Live capture backends behind one platform-neutral event contract:
  - Windows (`win-ps`): WinRT `BluetoothLEAdvertisementWatcher` driven by an
    embedded C# helper compiled once with the in-box `csc.exe` (PowerShell
    scriptblocks cannot receive WinRT events — see ARCHITECTURE.md).
  - Linux (`linux-hci`): raw HCI socket with active LE scanning, legacy and
    extended advertising report parsing (root or `setcap` required).
  - `replay`: record/playback JSONL captures; doubles as the test harness.
- Device-type database built from the official Bluetooth SIG
  assigned-numbers data (all company identifiers, 789 service UUIDs,
  GATT appearance categories) plus a rule engine with three identification
  vectors: payload fingerprints (company id + prefix + service UUID),
  GATT appearance, and advertised-name prefixes.
- Vendor payload decoders: Apple Continuity (stacked TLVs, AirPods
  proximity pairing with model/pairing code/ear state, Nearby
  Action/Info, Find My), Microsoft CDP/Swift Pair with device name,
  Xiaomi Mi Beacon with product names, Google Fast Pair, Exposure
  Notification, Eddystone UID/URL/TLM, Find My Device network, Quick
  Share/Nearby, Samsung SmartThings Find.
- Advertisement sections merge per type across ADV and SCAN_RSP frames;
  devices keep a history of up to three previously seen names.
- Filter prompt (`/`) with a field-aware query language: bare text across
  address/name/company/type plus `mac:`, `name:`, `company:`, `type:` and
  `rssi:` threshold terms, AND-combined.
- Sort cycling (last seen / RSSI / name / address), raw hex view (`r`),
  pause (`p`), clear (`c`), `--ascii` glyph fallback, `--log` session
  recording, headless `--seconds N --log FILE` capture mode, and a
  terminal-free `--selftest` render check.
- Radar view (`m`): devices plotted on log-scale distance rings estimated
  from signal strength, with an animated sweep, a scrollable
  nearest-devices panel, selection brackets/readout and detail-view
  round-trip. No directional data — a single antenna hears no bearing,
  and the view says so.

[Unreleased]: https://github.com/SavchukSergey/ble-scanner/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/SavchukSergey/ble-scanner/compare/v0.1.0...v0.0.2
[0.1.0]: https://github.com/SavchukSergey/ble-scanner/releases/tag/v0.1.0
