# Reclaim

Reclaim your old Android. A CLI written in Zig that tunes an Android device over USB
using the stock `adb` binary — no root, always reversible, always measured.

**Status:** P4 (snapshot, apply, revert). `scan` reads the device fingerprint over
adb and recommends a profile. `plan` loads a profile, filters it for the device,
and shows the current-to-target diff without changing anything. `apply` writes a
local snapshot, executes the plan in one batch, and verifies the result; `revert`
restores a snapshot. `doctor` reports the adb binary, its version, server status,
and connected devices with repair hints. Other commands still report that they
are not implemented yet.

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
zig build run -- apply light
zig build run -- apply light --yes
zig build run -- apply light --yes --skip dexopt
zig build run -- apply light --yes --json
zig build run -- revert
zig build run -- revert --snapshot snap.json --yes
```

With more than one device attached, `scan`, `plan`, `apply`, and `revert` require
`-s <serial>`. Exit codes: `0` success, `1` general error, `2` bad arguments,
`3` adb not found, `4` no device or unauthorized, `5` partial failure,
`6` blocked by denylist.

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

Nothing in `plan` modifies the device.

## Apply and revert

`apply <profile>` builds the same diff as `plan` and shows what it would do.
Without `--yes` it is a dry run: nothing is written and the device is untouched.

With `--yes`, `apply`:

- writes a snapshot of every value it is about to change to
  `snapshots/<serial>_<timestamp>.json` and reads it back before touching the
  device; if the snapshot cannot be written or read back, nothing runs
- sends every command in one script through adb instead of one round trip per
  change
- reads each tracked value back and marks the step `verified` or `failed`
- writes an execution log under `logs/` in the same directory
- exits `5` if any step failed; when more than half fail it stops and points at
  `revert`

`--skip <id>` (repeatable) and `--only <id>` narrow the run. Steps on the static
or dynamic denylist are refused with exit `6` unless excluded this way; unknown
ids are rejected with exit `2`.

`revert` with no arguments restores the newest snapshot for the selected device.
`--snapshot <file>` picks a specific one. Without `--yes` it only shows what it
would restore. A snapshot recorded on a different device is refused. Idle
maintenance changes no persistent value, so it is left out of snapshots;
compiled artifacts are reset on revert.

Snapshots and logs live in the per-user config directory:

- Windows: `%APPDATA%\reclaim\snapshots` and `%APPDATA%\reclaim\logs`
- macOS: `~/Library/Application Support/reclaim/...`
- Linux and others: `$XDG_CONFIG_HOME/reclaim` (or `~/.config/reclaim`)

Both commands accept `--json` for machine-readable output.

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
| `src/snapshot.zig` | Snapshot records: save with read-back, load, latest lookup |
| `src/apply.zig` | The only module that changes the device: apply, verify, revert |
| `src/doctor.zig` | Diagnoses adb, server, and devices |
| `src/report.zig` | The only module that writes to stdout/stderr |
| `profiles/` | Built-in `light` and `balanced` profiles |
| `tests/fake_adb/` | Fake adb binary used by the test suite |
| `tests/fixtures/` | Captured `getprop` and `/proc/meminfo` samples for parser tests |

The full design (PRD, architecture, tweak catalog, roadmap) lives in
[Reclaim.md](Reclaim.md).
