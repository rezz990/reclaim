# Reclaim — Rancangan Lengkap untuk Vibe Coding

Untuk: Raka · Versi 0.1 · 24 Oktober 2026 · Stack: Zig + binary adb

## 0. Cara memakai dokumen ini

- Satu paket: PRD (bagian 1-4), desain teknis (5-10), testing dan roadmap (11-12), prompt siap tempel (13), risiko (14).
- Aturan emas: **satu fase = satu sesi AI.** Selesai, build hijau, commit, baru lanjut ke fase berikutnya.
- Awal setiap sesi: tempel **Master Prompt** (13.1), lalu prompt fase yang relevan (13.2 dst), lalu lampirkan bagian dokumen yang disebut di prompt itu.
- Nama project **Reclaim**, binary `reclaim`, alias `rcl`. Kalau nama berubah, find-replace saja.
- Setiap revisi dokumen: naikkan versi dan catat di changelog (bagian terakhir).

## 1. Ringkasan produk

**Reclaim** adalah CLI Zig untuk PC. Begitu Android dicolok via USB, Reclaim membaca spek device, memilih profil optimasi, menyimpan snapshot kondisi asli, menerapkan tweak lewat adb tanpa root, mengukur hasilnya, dan bisa membalikkan semuanya kapan saja.

**Tagline:** Reclaim your old Android.

**Masalah:** HP lama lambat karena bloatware, animasi, background process, dan kompilasi app yang kurang optimal. Tweak manual lewat adb berantakan, tanpa revert, dan tanpa bukti efeknya.

**Tiga janji produk:**

1. Satu perintah untuk semua tweak.
2. Selalu bisa di-revert.
3. Selalu ada angka before/after.

**Non-goals (v1):** root, flash ROM, ubah kernel/governor, GUI, app Android pendamping, fitur RAM booster placebo, dukungan iOS.

## 2. Pengguna dan skenario

**Persona:** developer yang punya banyak HP lama, teknisi servis HP, pemakai HP dengan RAM 2-3GB.

| ID | Skenario |
| --- | --- |
| S1 | Colok HP, jalankan `reclaim scan`, lihat info device dan rekomendasi profil. |
| S2 | `reclaim apply light --yes`, HP dioptimasi, report tampil. |
| S3 | Tidak cocok, `reclaim revert`, semua kembali seperti snapshot. |
| S4 | `reclaim watch` jalan terus, tiap HP dicolok otomatis diterapkan profil. |
| S5 | `reclaim bench` sebelum dan sesudah untuk bukti angka. |

## 3. Scope

| Rilis | Isi |
| --- | --- |
| MVP | adb layer, scan, profil JSON (light, balanced), plan dan dry-run, snapshot, apply, revert, bench dasar, doctor |
| v1.1 | debloat per vendor, watch mode, profil aggressive, report JSON/HTML |
| Later | direct ADB protocol, helper pairing wireless debugging, multi-device paralel, app Shizuku pendamping, repo profil komunitas |

## 4. Spesifikasi CLI

| Command | Fungsi | Flag penting |
| --- | --- | --- |
| `scan` | Info device, rekomendasi profil | `--json` |
| `plan <profil>` | Tampilkan diff apa yang akan berubah | `--json` |
| `apply <profil>` | Terapkan profil (default dry-run) | `--yes`, `--skip <id>`, `--only <id>` |
| `revert` | Balikkan dari snapshot terakhir | `--snapshot <file>`, `--yes` |
| `bench` | Ukur performa | `--pkg <paket>`, `--runs <n>`, `--label <nama>` |
| `debloat` | Daftar dan eksekusi debloat (v1.1) | `--list`, `--risk safe\|caution`, `--yes` |
| `watch` | Daemon auto-apply saat colok (v1.1) | `--profile <nama>`, `--yes` |
| `doctor` | Diagnosa adb, driver, otorisasi | `--json` |

**Flag global:** `-s/--serial`, `--json`, `--verbose`, `--adb <path>`, `--version`.

**Aturan:** `apply`, `debloat`, dan `revert` tanpa `--yes` hanya menampilkan rencana (dry-run). Tidak ada perubahan ke device tanpa `--yes`.

**Exit code:** 0 sukses · 1 error umum · 2 argumen salah · 3 adb tidak ditemukan · 4 device tidak ada atau unauthorized · 5 sebagian step gagal · 6 diblokir denylist.

## 5. Alur utama (colok lalu jalan)

1. **Resolve adb** (folder binary, lalu PATH, lalu `--adb`), pastikan server hidup.
2. **Pilih device** (satu device otomatis, banyak device wajib `-s`).
3. **Fingerprint**: SDK, rilis Android, vendor, model, ABI, RAM total, flag low\_ram.
4. **Pilih profil**: dari argumen, atau rekomendasi berdasarkan RAM dan SDK.
5. **Plan**: filter step yang cocok (min/max SDK, batas RAM), buang yang kena denylist, tandai risiko.
6. **Snapshot**: baca nilai asli SEMUA step yang akan diubah, tulis ke file sebelum menyentuh device.
7. **Apply**: kirim sebagai satu script batch, catat hasil per baris.
8. **Verify**: baca ulang nilai, bandingkan dengan yang diharapkan.
9. **Report**: ringkasan step sukses, gagal, dilewati, plus hasil bench bila diminta.

## 6. Arsitektur

```
reclaim/
  build.zig
  build.zig.zon
  .zig-version          # kunci versi Zig, WAJIB
  README.md
  src/
    main.zig            # entry, dispatch command
    cli.zig             # parsing argumen, help
    paths.zig           # lokasi config/snapshot/log per OS
    adb.zig             # SATU-SATUNYA modul yang spawn proses adb
    device.zig          # fingerprint dan info device
    profile.zig         # load dan validasi profil JSON
    plan.zig            # bikin rencana dan diff dari profil + device
    denylist.zig        # aturan package terlarang (statis + dinamis)
    snapshot.zig        # simpan dan baca nilai asli
    apply.zig           # SATU-SATUNYA modul yang mengubah device
    bench.zig           # pengukuran
    debloat.zig         # daftar package per vendor (v1.1)
    watch.zig           # track-devices loop (v1.1)
    doctor.zig          # diagnosa
    report.zig          # output teks dan JSON
  profiles/             # light.json, balanced.json, aggressive.json
  debloat/              # generic.json, xiaomi.json, samsung.json, dst
  tests/
    fake_adb/           # skrip adb palsu untuk test
    fixtures/           # contoh output getprop, dumpsys, dll
```

**Aturan dependensi (wajib dipatuhi):**

- Hanya `adb.zig` yang boleh menjalankan proses eksternal.
- Hanya `apply.zig` yang boleh mengirim perintah yang MENGUBAH state device. Modul lain read-only.
- `apply.zig` menolak jalan kalau snapshot belum tertulis.
- `report.zig` satu-satunya modul yang mencetak ke stdout/stderr (selain `cli.zig` untuk help).

**Kebijakan teknis:**

- Allocator: satu arena per command, dibebaskan di akhir command.
- Error: error set per modul, propagasi dengan `try`, tidak ada `catch unreachable` pada I/O atau parsing output device.
- Output device tidak dipercaya: parse defensif, field hilang jadi null, bukan crash.
- Tanpa dependensi eksternal. Format data semuanya JSON (std Zig).

## 7. Spesifikasi layer adb (`adb.zig`)

**Resolve binary:** urutan folder executable, lalu `--adb`, lalu PATH. Windows butuh `AdbWinApi.dll` dan `AdbWinUsbApi.dll` di folder yang sama dengan `adb.exe`. Kunci versi adb yang dipakai di README.

**API minimum:**

```zig
pub const Result = struct { stdout: []u8, stderr: []u8, exit_code: ?u8, timed_out: bool };

pub fn resolve(alloc: Allocator, override: ?[]const u8) !AdbPath;
pub fn startServer(alloc: Allocator, adb: AdbPath) !void;
pub fn run(alloc: Allocator, adb: AdbPath, args: []const []const u8, timeout_ms: u32) !Result;
pub fn shell(alloc: Allocator, adb: AdbPath, serial: []const u8, cmd: []const u8) !ShellResult;
pub fn runScript(alloc: Allocator, adb: AdbPath, serial: []const u8, script: []const u8) ![]ScriptLine;
pub fn listDevices(alloc: Allocator, adb: AdbPath) ![]DeviceEntry; // serial + state
pub fn trackDevices(alloc: Allocator, adb: AdbPath, cb: *const fn (DeviceEvent) void) !void;
```

**Perilaku wajib:**

1. Semua perintah ke device memakai `-s <serial>`.
2. Argumen dikirim sebagai array argv, bukan satu string.
3. `shell()` menambahkan penanda exit code di akhir (`; echo __RC=$?`) lalu mem-parse-nya, karena adb lama tidak meneruskan exit code.
4. `runScript()` menulis script ke file sementara di PC, `adb push` ke `/data/local/tmp/reclaim_<id>.sh`, jalankan `sh` file itu, parse hasil per baris (tiap baris script mengeluarkan penanda `__STEP=<id> __RC=<n>`), lalu hapus file di device.
5. Timeout default 15 detik per command, 120 detik untuk script. Timeout menghasilkan `timed_out = true`, bukan hang.
6. State device yang dikenali: `device`, `unauthorized`, `offline`, `no permissions`. Selain `device` ditolak dengan pesan jelas.
7. `trackDevices` membaca stdout `adb track-devices` (format: 4 digit hex panjang lalu daftar `serial<TAB>state`).
8. Perintah kompleks (ada spasi, titik koma, tanda kutip) SELALU lewat `runScript`, bukan inline.

## 8. Spesifikasi data

### 8.1 Profil (`profiles/*.json`)

```json
{
  "schema": 1,
  "name": "light",
  "description": "Tweak aman untuk HP RAM kecil",
  "requires": { "min_sdk": 21, "max_ram_mb": 3072 },
  "steps": [
    { "id": "anim-window", "kind": "setting", "namespace": "global",
      "key": "window_animation_scale", "value": "0.5", "risk": "safe", "min_sdk": 17 },
    { "id": "dexopt", "kind": "compile", "mode": "speed-profile",
      "scope": "all", "risk": "safe", "min_sdk": 24 },
    { "id": "phantom", "kind": "device_config", "namespace": "activity_manager",
      "key": "max_phantom_processes", "value": "2147483647", "risk": "caution", "min_sdk": 31 }
  ]
}
```

**Jenis step (`kind`):** `setting` (settings put), `device_config`, `compile`, `appops`, `standby_bucket`, `wm` (density/size), `package` (disable/uninstall-user), `maintenance` (sm idle-maint).

**Validasi:** `schema` harus dikenal, `id` unik, `risk` salah satu dari `safe|caution|dangerous`, `kind` dikenal, field wajib per kind lengkap. Profil tidak valid ditolak dengan pesan yang menyebut field dan baris/step-nya.

### 8.2 Snapshot (`snapshots/<serial>_<timestamp>.json`)

```json
{
  "schema": 1,
  "created": "2026-10-24T10:00:00Z",
  "device": { "serial": "ABC123", "model": "...", "sdk": 29 },
  "profile": "light",
  "entries": [
    { "step_id": "anim-window", "kind": "setting", "target": "global/window_animation_scale",
      "before": "1.0", "after": "0.5", "status": "applied" }
  ]
}
```

**Aturan revert:** `before` bernilai `null` berarti key semula tidak ada, jadi revert memakai `settings delete`, bukan `put`. Step `compile` dicatat tapi revert-nya best effort (`cmd package compile --reset -a`).

### 8.3 Report

Teks untuk manusia dan JSON untuk mesin (`--json`). Isi: device, profil, daftar step (applied/skipped/failed + alasan), hasil verify, delta bench bila ada.

## 9. Katalog tweak

| ID | Perintah | Revert | Min SDK | Risiko |
| --- | --- | --- | --- | --- |
| anim-window | `settings put global window_animation_scale 0.5` | pulihkan nilai asli, atau `settings delete` | 17 | safe |
| anim-transition | `settings put global transition_animation_scale 0.5` | sama | 17 | safe |
| anim-animator | `settings put global animator_duration_scale 0.5` | sama | 17 | safe |
| dexopt | `cmd package compile -m speed-profile -a` | `cmd package compile --reset -a` | 24 | safe |
| idle-maint | `sm idle-maint run` | tidak perlu | 23 | safe |
| disable-pkg | `pm disable-user --user 0 <pkg>` | `pm enable <pkg>` | 21 | tergantung daftar |
| uninstall-user | `pm uninstall -k --user 0 <pkg>` | `cmd package install-existing <pkg>` | 24 | caution |
| bucket | `am set-standby-bucket <pkg> restricted` | set ke bucket asli (`am get-standby-bucket` dulu) | 28 | caution |
| appops-bg | `cmd appops set <pkg> RUN_IN_BACKGROUND ignore` | set ke `default` | 26 | caution |
| phantom | `device_config put activity_manager max_phantom_processes 2147483647` dan `settings put global settings_enable_monitor_phantom_procs false` | hapus/pulihkan nilai | 31 | caution |
| wm-density | `wm density <n>` (opt-in) | `wm density reset` | 17 | caution |
| wm-size | `wm size <WxH>` (opt-in) | `wm size reset` | 17 | caution |

**Catatan:** semua perintah ini perlu diverifikasi di device nyata per versi Android. Perilaku `device_config` bisa direset sistem (karena itu ada mode `watch`). Jangan menambah tweak di luar katalog tanpa menambahkannya ke dokumen ini lebih dulu.

**Metrik bench:**

- Cold start: `am force-stop <pkg>` lalu `am start -W -n <pkg>/<activity>`, ambil `TotalTime`. Minimal 5 kali, ambil median. Activity didapat dari `cmd package resolve-activity --brief <pkg>`.
- Memori: `dumpsys meminfo` (Total/Free/Used RAM) dan `MemAvailable` dari `/proc/meminfo`.
- Jank: `dumpsys gfxinfo <pkg> reset`, pakai app sebentar, lalu `dumpsys gfxinfo <pkg>` dan ambil persentase janky frames.

## 10. Keamanan dan guardrail

1. Dry-run adalah default. Perubahan hanya dengan `--yes`.
2. Snapshot WAJIB tertulis dan terverifikasi sebelum step pertama jalan.
3. **Denylist statis** (tidak bisa di-override): `android`, `com.android.systemui`, `com.android.settings`, `com.android.phone`, `com.android.shell`, `com.android.bluetooth`, `com.android.nfc`, `com.android.providers.*`, `com.android.inputmethod.*`, `com.android.packageinstaller`, `com.google.android.permissioncontroller`.
4. **Denylist dinamis** (dibaca saat runtime): launcher default (`cmd package resolve-activity --brief -c android.intent.category.HOME`), keyboard aktif (`settings get secure default_input_method`), aplikasi dialer dan SMS default.
5. `com.google.android.gms` dan layanan Google inti berstatus caution: tidak masuk profil bawaan, hanya lewat opt-in eksplisit.
6. Hanya satu operasi mengubah device per waktu per serial. Tidak ada eksekusi paralel ke device yang sama.
7. Kalau lebih dari separuh step gagal, berhenti dan tawarkan revert otomatis.
8. Log lengkap tiap perintah yang dikirim ke device disimpan di folder log.
9. Tidak ada telemetri, tidak ada akses jaringan dari Reclaim sendiri.

## 11. Strategi testing

- **Unit test** parser (getprop, meminfo, dumpsys, am start -W, track-devices) memakai file di `tests/fixtures/`.
- **Fake adb**: skrip kecil bernama `adb` di `tests/fake_adb/` yang membalas perintah dari tabel respons, dipakai lewat `--adb`. Semua test modul lain berjalan tanpa device asli.
- **Test revert**: apply lalu revert pada fake device harus menghasilkan state identik dengan awal.
- **Test denylist**: setiap package denylist harus ditolak di plan, apa pun profilnya.
- **Matriks device nyata** (manual, minimal): Android 7-9, 10-11, 12+, masing-masing satu device. Catat hasilnya di `docs/device-matrix.md`.
- Gerbang tiap fase: `zig build test` hijau tanpa warning.

## 12. Roadmap fase

| Fase | Hasil | Selesai kalau |
| --- | --- | --- |
| P0 | Scaffold repo | `reclaim --version` dan `--help` jalan |
| P1 | Layer adb | `doctor` melaporkan adb dan daftar device |
| P2 | Device dan scan | `scan` menampilkan info lengkap dan rekomendasi |
| P3 | Profil dan plan | `plan light` menampilkan diff, dry-run benar |
| P4 | Snapshot, apply, revert | apply lalu revert mengembalikan state awal |
| P5 | Bench | `bench` menampilkan before/after |
| P6 | Debloat | daftar per vendor, aman dari denylist |
| P7 | Watch | colok device otomatis memicu apply |
| P8 | Polish dan rilis | README, build lintas OS, device matrix |

MVP = P0 sampai P5. P6 dan seterusnya = v1.1.

## 13. Prompt vibe coding

### 13.1 Master Prompt (tempel di awal SETIAP sesi)

```
Kamu adalah engineer Zig senior. Project: Reclaim, CLI Zig untuk optimasi Android tanpa root lewat binary adb.

Aturan keras:
1. Pakai versi Zig yang tertulis di .zig-version. Jangan pakai API yang tidak ada di versi itu. Kalau ragu soal API std, tulis kode paling sederhana yang pasti ada, jangan menebak.
2. Ikuti dokumen desain (bagian yang saya lampirkan) apa adanya. Jangan ubah nama modul, struktur folder, schema JSON, atau exit code.
3. Hanya adb.zig yang spawn proses. Hanya apply.zig yang mengubah device. Hanya report.zig yang mencetak.
4. DILARANG: stub, TODO sebagai pengganti implementasi, fungsi kosong, kode palsu, data contoh yang dikarang. Kalau sesuatu tidak bisa diimplementasi di fase ini, katakan terus terang di akhir.
5. DILARANG scope creep: kerjakan HANYA fase yang diminta. Jangan menambah fitur, flag, atau modul di luar spesifikasi.
6. Tanpa dependensi eksternal. Format data JSON.
7. Tidak ada catch unreachable pada I/O atau parsing output device. Parse defensif.
8. Setiap fungsi publik punya test. Kode harus lolos zig build test.
9. Di akhir, beri ringkasan: file yang dibuat/diubah, keputusan penting, hal yang belum bisa diverifikasi tanpa device nyata.
```

### 13.2 Prompt P0 — Scaffold

```
Fase P0. Buat scaffold repo sesuai bagian 6 (struktur folder). Isi: build.zig, build.zig.zon, .zig-version, README singkat, src/main.zig, src/cli.zig, src/paths.zig, src/report.zig. Implementasi: parsing argumen untuk semua command di bagian 4 (command yang belum ada fasenya cukup menampilkan pesan 'belum diimplementasi di fase ini' dengan exit code 1), flag global, --version, --help. paths.zig: lokasi config/snapshot/log per OS (Windows: APPDATA, Linux/macOS: XDG atau HOME). Selesai kalau: zig build test hijau, reclaim --version dan --help jalan.
```

### 13.3 Prompt P1 — Layer adb

```
Fase P1. Implementasikan src/adb.zig dan src/doctor.zig sesuai bagian 7. Wajib: resolve binary, startServer, run dengan timeout, shell dengan penanda exit code, runScript (push, sh, parse penanda per step, cleanup), listDevices, trackDevices. Buat tests/fake_adb dan test yang memakainya. doctor menampilkan: path adb dan versi, status server, daftar device dengan state, dan petunjuk perbaikan per state (unauthorized, offline, no permissions). Selesai kalau: semua test hijau dengan fake adb, doctor jalan.
```

### 13.4 Prompt P2 — Device dan scan

```
Fase P2. Implementasikan src/device.zig dan command scan. Baca: ro.build.version.sdk, ro.build.version.release, ro.product.manufacturer, ro.product.model, ro.product.cpu.abi, ro.config.low_ram, MemTotal dari /proc/meminfo. Rekomendasi profil: RAM <= 3072MB dan SDK < 31 menyarankan light; RAM <= 4096MB menyarankan balanced; selain itu menyatakan device sudah cukup lega. Parser dengan fixture di tests/fixtures. Output teks dan --json lewat report.zig. Selesai kalau: scan benar pada fixture dan fake adb, semua field hilang ditangani tanpa crash.
```

### 13.5 Prompt P3 — Profil dan plan

```
Fase P3. Implementasikan src/profile.zig, src/denylist.zig, src/plan.zig, dan command plan. Sesuai bagian 8.1 dan 10. Buat profiles/light.json dan profiles/balanced.json hanya dari katalog bagian 9 (jangan menambah tweak). Plan memfilter step berdasarkan min/max SDK dan batas RAM, membuang yang kena denylist, menandai risiko, dan menampilkan diff nilai sekarang vs nilai target (baca nilai sekarang lewat adb, read-only). Selesai kalau: plan light pada fake device menampilkan diff benar, profil rusak ditolak dengan pesan jelas, test denylist hijau.
```

### 13.6 Prompt P4 — Snapshot, apply, revert

```
Fase P4. Implementasikan src/snapshot.zig dan src/apply.zig, serta command apply dan revert, sesuai bagian 5, 8.2, dan 10. Urutan wajib: snapshot ditulis dan dibaca ulang sebelum apply mengirim apa pun. Apply memakai runScript satu batch. Verify setelah apply. before=null berarti revert memakai settings delete. Tanpa --yes hanya dry-run. Jika lebih dari separuh step gagal, berhenti dan tawarkan revert. Selesai kalau: test apply lalu revert pada fake device menghasilkan state identik, apply menolak jalan tanpa snapshot, exit code sesuai bagian 4.
```

### 13.7 Prompt P5 — Bench

```
Fase P5. Implementasikan src/bench.zig dan command bench sesuai bagian 9 (metrik bench). Cold start minimal 5 run, ambil median. Simpan hasil dengan --label ke folder data, dan tampilkan perbandingan antar label (before/after) beserta persentase perubahan. Parser untuk am start -W, dumpsys meminfo, dumpsys gfxinfo, dengan fixture. Selesai kalau: perbandingan dua label benar, parser tahan terhadap output yang tidak lengkap.
```

### 13.8 Prompt P6 sampai P8 (v1.1)

```
P6 Debloat: implementasikan src/debloat.zig dan debloat/*.json (generic dulu). Tiap entri: package, vendor, kategori, risiko (safe/caution), alasan. Wajib melewati denylist statis dan dinamis. Aksi: disable-user (default) atau uninstall-user. Semua masuk snapshot dan bisa di-revert.

P7 Watch: implementasikan src/watch.zig memakai trackDevices. Saat device masuk state device, jalankan alur apply dengan profil dari --profile. Hormati lock satu operasi per serial. Berhenti rapi saat Ctrl+C.

P8 Polish: README lengkap, build lintas OS (Windows, Linux, macOS) lewat build.zig, docs/device-matrix.md, pesan error dirapikan, --json konsisten di semua command.
```

### 13.9 Template prompt bugfix

```
Master Prompt berlaku. Bug: <deskripsi singkat>.
Langkah reproduksi: <perintah persis>.
Hasil sekarang: <output>. Hasil seharusnya: <output>.
Batasi perubahan pada file: <daftar file>. Tambahkan test yang gagal sebelum perbaikan dan lolos sesudahnya. Jangan refactor di luar bug ini.
```

### 13.10 Checklist review sebelum commit

- `zig build test` hijau, tanpa warning.
- Tidak ada stub, TODO pengganti implementasi, atau data karangan.
- Tidak ada file di luar scope fase yang berubah.
- Aturan dependensi (bagian 6) tidak dilanggar.
- Tidak ada perintah baru ke device di luar katalog bagian 9.
- Revert tetap bekerja untuk semua step baru.
- Dicoba minimal sekali di device nyata (kalau fase menyentuh device).

## 14. Risiko dan pertanyaan terbuka

| Risiko | Mitigasi |
| --- | --- |
| API Zig berubah antar versi | Kunci versi di `.zig-version`, upgrade hanya sengaja |
| Perilaku adb dan Android beda per versi/vendor | Device matrix, tweak berflag min/max SDK, semua step bisa di-skip |
| Debloat membuat fitur vendor rusak | Dry-run default, snapshot, denylist dinamis, revert |
| `device_config` direset sistem | Mode `watch` untuk apply ulang, dokumentasikan di README |
| Lisensi redistribusi binary adb | Cek lisensi platform-tools sebelum rilis publik, atau minta user menyediakan sendiri |
| Klaim performa tanpa bukti | `bench` wajib, laporkan angka apa adanya termasuk yang tidak berubah |

**Pertanyaan terbuka:**

1. Nama final dan ketersediaannya di GitHub/domain (cek dulu sebelum rilis).
2. Lisensi project (MIT, Apache-2.0, atau lainnya).
3. Apakah profil bawaan ikut di-embed ke binary atau dibaca dari folder.
4. Daftar device uji nyata yang tersedia untuk device matrix.

## Changelog

- v0.1 (24 Oktober 2026): draf awal PRD, arsitektur, katalog tweak, dan prompt P0-P8.
