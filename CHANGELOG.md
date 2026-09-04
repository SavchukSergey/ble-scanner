# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- SLAM map mode (`s` inside the radar view): range-only simultaneous
  localization and mapping builds a live 2D map of device positions from
  distance estimates gathered while walking (no odometry). Classical-MDS
  initialization over the shortest-path distance matrix, SMACOF stress
  majorization with robustness-weighted springs, soft motion constraints
  between observer steps, first observer pinned as the frame anchor.
  `x` resets the solve; map is correct up to rotation/mirror, and the
  view says so.

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

[Unreleased]: https://github.com/SavchukSergey/ble-scanner/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/SavchukSergey/ble-scanner/releases/tag/v0.1.0
