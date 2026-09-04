# Security Policy

## Scope

ble-scanner is a **passive** observer: it reads Bluetooth Low Energy
advertisements that devices around you broadcast publicly, decodes them
locally, and writes files only when you explicitly pass `--log`. It performs
no network connections, no telemetry, and no pairing or connection to
Bluetooth devices.

The Windows backend spawns a local PowerShell helper that compiles an
embedded C# watcher with the in-box .NET compiler; the compiled artifact is
cached under `%TEMP%\ble-scanner\` and verified by a SHA-256 hash of the
embedded source. The Linux backend opens a raw HCI socket, which requires
elevated capabilities (`setcap` instructions in the README).

## Reporting a vulnerability

Please open a private security advisory on the repository (GitHub:
*Security → Report a vulnerability*) or contact the maintainer directly.
Include reproduction steps and, if relevant, a `--log` capture. You will
hear back within a few days; fixes ship as patch releases.

## Responsible use

Observing advertisements is legal in most jurisdictions, but using this
tool to track or identify people without their consent may not be. RSSI
distance estimates are rough. Do not use ble-scanner for stalking —
that's not what it's for, and it's a crime in many places.
