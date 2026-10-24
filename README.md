# Reclaim

Reclaim your old Android. A CLI written in Zig that tunes an Android device over USB
using the stock `adb` binary — no root, always reversible, always measured.

**Status:** P3 (profiles, denylist, plan). `scan` reads the device fingerprint over
adb and recommends a profile. `plan` loads a profile, filters it for the device,
and shows the current-to-target diff without changing anything. `doctor` reports
the adb binary, its version, server status, and connected devices with repair
hints. Other commands still report that they are not implemented yet.

## Requirements

- Zig `0.17.0-dev.2127+e90365cd5` (pinned in `.zig-version`)
- Android platform-tools (`adb`). Reclaim looks in the executable folder, then `--adb`,
  then `PATH`.
- On Windows, `AdbWinApi.dll` and `AdbWinUsbApi.dll` must sit next to `adb.exe`.

## Build

```sh
zig build
zig build test
```

The binary is written to `zig-out/bin/reclaim`.

## Usage

```sh
zig build run -- --help
zig build run -- --version
zig build run -- doctor
zig build run -- doctor --json
zig build run -- scan
zig build run -- scan --json
zig build run -- scan -s SERIAL
zig build run -- plan light
zig build run -- plan balanced --json
```

With more than one device attached, `scan` and `plan` require `-s <serial>`. Exit
codes: `0` success, `1` general error, `2` bad arguments, `3` adb not found,
`4` no device or unauthorized, `5` partial failure, `6` blocked by denylist.

## Scan recommendation

`scan` reads SDK level, Android release, manufacturer, model, ABI, the low-RAM flag,
and `MemTotal` from `/proc/meminfo`:

- `light` when RAM is at most 3072 MB and SDK is below 31
- `balanced` when RAM is at most 4096 MB
- no profile when the device has more than 4096 MB

Missing fields are reported as unknown and never abort the scan.

## Plan

`plan <profile>` loads `profiles/<profile>.json`, validates it, and builds a
read-only diff for the selected device:

- steps below `min_sdk` or above `max_sdk` are skipped
- when the profile's `requires` (SDK and RAM limits) do not match the device,
  every step is skipped with the reason
- packages on the static or dynamic denylist are blocked and the command exits
  `6`; protected packages are never part of a plan
- current values are read with read-only adb queries, so the diff shows
  `current -> target` and marks values already at target as unchanged

Nothing in `plan` modifies the device. `apply` (P4) is what will execute it.

## Layout

| Path | Purpose |
| --- | --- |
| `src/main.zig` | Entry point and command dispatch |
| `src/cli.zig` | Argument parsing, help text, version |
| `src/paths.zig` | Config, snapshot, and log locations per OS |
| `src/adb.zig` | The only module that spawns processes (adb layer) |
| `src/device.zig` | Device selection, fingerprint parsing, and recommendation |
| `src/profile.zig` | Profile JSON loading and validation |
| `src/denylist.zig` | Static package rules and dynamic default-app detection |
| `src/plan.zig` | Read-only plan builder: gates, denylist, current-value diff |
| `src/doctor.zig` | Diagnoses adb, server, and devices |
| `src/report.zig` | The only module that writes to stdout/stderr |
| `profiles/` | Built-in `light` and `balanced` profiles |
| `tests/fake_adb/` | Fake adb binary used by the test suite |
| `tests/fixtures/` | Captured `getprop` and `/proc/meminfo` samples for parser tests |

The full design (PRD, architecture, tweak catalog, roadmap) lives in
[Reclaim.md](Reclaim.md).
