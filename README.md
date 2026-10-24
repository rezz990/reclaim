# Reclaim

Reclaim your old Android. A CLI written in Zig that tunes an Android device over USB
using the stock `adb` binary — no root, always reversible, always measured.

**Status:** P1 (adb layer and doctor). `doctor` reports the adb binary, its version,
server status, and connected devices with repair hints. Other commands still report
that they are not implemented yet.

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
zig build run -- scan --json
```

Exit codes: `0` success, `1` general error, `2` bad arguments, `3` adb not found,
`4` no device or unauthorized, `5` partial failure, `6` blocked by denylist.

## Layout

| Path | Purpose |
| --- | --- |
| `src/main.zig` | Entry point and command dispatch |
| `src/cli.zig` | Argument parsing, help text, version |
| `src/paths.zig` | Config, snapshot, and log locations per OS |
| `src/adb.zig` | The only module that spawns processes (adb layer) |
| `src/doctor.zig` | Diagnoses adb, server, and devices |
| `src/report.zig` | The only module that writes to stdout/stderr |
| `tests/fake_adb/` | Fake adb binary used by the test suite |

The full design (PRD, architecture, tweak catalog, roadmap) lives in
[Reclaim.md](Reclaim.md).
