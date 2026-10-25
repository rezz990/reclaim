//! Integration tests for the adb layer and doctor, driven by the fake adb
//! binary built from tests/fake_adb/adb.zig.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const adb = @import("adb.zig");
const denylist = @import("denylist.zig");
const device = @import("device.zig");
const doctor = @import("doctor.zig");
const main = @import("main.zig");
const paths = @import("paths.zig");
const snapshot = @import("snapshot.zig");

const io = std.testing.io;
const alloc = std.testing.allocator;
const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

const Fake = struct {
    tmp: std.testing.TmpDir,
    dir_path: []u8,
    path: []u8,

    fn init(name: []const u8) !Fake {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const dir_len = try tmp.dir.realPath(io, &dir_buffer);
        const dir_path = try alloc.dupe(u8, dir_buffer[0..dir_len]);
        errdefer alloc.free(dir_path);

        const path = try std.fs.path.join(alloc, &.{ dir_path, name });
        errdefer alloc.free(path);

        const source = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.fake_adb, alloc);
        defer alloc.free(source);
        try std.Io.Dir.copyFileAbsolute(source, path, io, .{ .replace = true });
        return .{ .tmp = tmp, .dir_path = dir_path, .path = path };
    }

    fn scenario(name: []const u8) !Fake {
        const file_name = try std.fmt.allocPrint(alloc, "fake_{s}{s}", .{ name, exe_suffix });
        defer alloc.free(file_name);
        return init(file_name);
    }

    fn deinit(fake: *Fake) void {
        alloc.free(fake.path);
        alloc.free(fake.dir_path);
        fake.tmp.cleanup();
    }

    fn handle(fake: *const Fake) adb.AdbPath {
        return .{ .path = fake.path, .io = io };
    }
};

fn emptyEnv() std.process.Environ.Map {
    return std.process.Environ.Map.init(alloc);
}

test "resolve uses an explicit adb path" {
    var fake = try Fake.scenario("ok");
    defer fake.deinit();
    var env = emptyEnv();
    defer env.deinit();

    const found = try adb.resolve(alloc, io, &env, fake.path);
    defer alloc.free(found.path);

    try std.testing.expect(std.mem.indexOf(u8, found.path, "fake_ok") != null);
}

test "resolve searches PATH when no override is given" {
    var fake = try Fake.init("adb" ++ exe_suffix);
    defer fake.deinit();
    var env = emptyEnv();
    defer env.deinit();
    try env.put("PATH", fake.dir_path);

    const found = try adb.resolve(alloc, io, &env, null);
    defer alloc.free(found.path);

    try std.testing.expect(std.mem.endsWith(u8, found.path, "adb" ++ exe_suffix));
}

test "resolve fails when adb is missing" {
    var fake = try Fake.scenario("ok");
    defer fake.deinit();
    var env = emptyEnv();
    defer env.deinit();
    try env.put("PATH", fake.dir_path);

    try std.testing.expectError(
        error.AdbNotFound,
        adb.resolve(alloc, io, &env, "definitely-missing-adb-binary"),
    );
}

test "run captures stdout and the exit code" {
    var fake = try Fake.scenario("ok");
    defer fake.deinit();

    var result = try adb.run(alloc, fake.handle(), &.{"version"}, adb.default_timeout_ms);
    defer result.deinit(alloc);

    try std.testing.expect(!result.timed_out);
    try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Android Debug Bridge version") != null);
}

test "run reports a non-zero exit code" {
    var fake = try Fake.scenario("ok");
    defer fake.deinit();

    var result = try adb.run(alloc, fake.handle(), &.{"exit-7"}, adb.default_timeout_ms);
    defer result.deinit(alloc);

    try std.testing.expect(!result.timed_out);
    try std.testing.expectEqual(@as(?u8, 7), result.exit_code);
    try std.testing.expectEqualStrings("boom\n", result.stderr);
}

test "run gives up on timeout instead of hanging" {
    var fake = try Fake.scenario("slow");
    defer fake.deinit();

    var result = try adb.run(alloc, fake.handle(), &.{"version"}, 150);
    defer result.deinit(alloc);

    try std.testing.expect(result.timed_out);
    try std.testing.expectEqual(@as(?u8, null), result.exit_code);
}

test "shell strips the exit marker" {
    var fake = try Fake.scenario("ok");
    defer fake.deinit();

    var success = try adb.shell(alloc, fake.handle(), "FAKE123", "echo hello");
    defer success.deinit(alloc);
    try std.testing.expectEqualStrings("hello", success.stdout);
    try std.testing.expectEqual(@as(?u8, 0), success.exit_code);
    try std.testing.expect(!success.timed_out);

    var failure = try adb.shell(alloc, fake.handle(), "FAKE123", "false");
    defer failure.deinit(alloc);
    try std.testing.expectEqualStrings("", failure.stdout);
    try std.testing.expectEqual(@as(?u8, 1), failure.exit_code);
}

test "startServer succeeds and reports failures" {
    var ok = try Fake.scenario("ok");
    defer ok.deinit();
    try adb.startServer(alloc, ok.handle());

    var failing = try Fake.scenario("serverfail");
    defer failing.deinit();
    try std.testing.expectError(error.AdbFailed, adb.startServer(alloc, failing.handle()));
}

test "listDevices reports connected devices" {
    var fake = try Fake.scenario("ok");
    defer fake.deinit();

    const entries = try adb.listDevices(alloc, fake.handle());
    defer adb.freeDevices(alloc, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("FAKE123", entries[0].serial);
    try std.testing.expectEqual(adb.DeviceState.device, entries[0].state);
}

test "listDevices reports unauthorized devices" {
    var fake = try Fake.scenario("unauthorized");
    defer fake.deinit();

    const entries = try adb.listDevices(alloc, fake.handle());
    defer adb.freeDevices(alloc, entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(adb.DeviceState.unauthorized, entries[0].state);
}

const TrackKind = enum { connected, disconnected };

const TrackRecord = struct {
    kind: TrackKind,
    serial: [16]u8 = undefined,
    serial_len: usize = 0,
    state: adb.DeviceState = .unknown,
};

var track_records: [8]TrackRecord = undefined;
var track_record_count: usize = 0;

fn recordTrackEvent(event: adb.DeviceEvent) void {
    if (track_record_count >= track_records.len) return;
    switch (event) {
        .connected => |entry| {
            const len = @min(entry.serial.len, track_records[track_record_count].serial.len);
            @memcpy(track_records[track_record_count].serial[0..len], entry.serial[0..len]);
            track_records[track_record_count].serial_len = len;
            track_records[track_record_count].kind = .connected;
            track_records[track_record_count].state = entry.state;
        },
        .disconnected => |serial| {
            const len = @min(serial.len, track_records[track_record_count].serial.len);
            @memcpy(track_records[track_record_count].serial[0..len], serial[0..len]);
            track_records[track_record_count].serial_len = len;
            track_records[track_record_count].kind = .disconnected;
        },
    }
    track_record_count += 1;
}

test "trackDevices reports connects and disconnects" {
    track_record_count = 0;
    var fake = try Fake.scenario("track");
    defer fake.deinit();

    try adb.trackDevices(alloc, fake.handle(), &recordTrackEvent);

    try std.testing.expectEqual(@as(usize, 4), track_record_count);

    try std.testing.expectEqual(TrackKind.connected, track_records[0].kind);
    try std.testing.expectEqualStrings("FAKE123", track_records[0].serial[0..track_records[0].serial_len]);
    try std.testing.expectEqual(adb.DeviceState.device, track_records[0].state);

    try std.testing.expectEqual(TrackKind.connected, track_records[1].kind);
    try std.testing.expectEqualStrings("FAKE456", track_records[1].serial[0..track_records[1].serial_len]);
    try std.testing.expectEqual(adb.DeviceState.offline, track_records[1].state);

    try std.testing.expectEqual(TrackKind.disconnected, track_records[2].kind);
    try std.testing.expectEqualStrings("FAKE123", track_records[2].serial[0..track_records[2].serial_len]);

    try std.testing.expectEqual(TrackKind.disconnected, track_records[3].kind);
    try std.testing.expectEqualStrings("FAKE456", track_records[3].serial[0..track_records[3].serial_len]);
}

test "runScript parses step markers and removes its temp file" {
    var fake = try Fake.scenario("ok");
    defer fake.deinit();
    var scratch = std.testing.tmpDir(.{ .iterate = true });
    defer scratch.cleanup();

    const script =
        "echo \"__STEP=anim-window __RC=$?\"\n" ++
        "echo \"__STEP=dexopt __RC=$?\"\n";
    const lines = try adb.runScript(alloc, fake.handle(), "FAKE123", script, scratch.dir);
    defer adb.freeScriptLines(alloc, lines);

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("anim-window", lines[0].step_id);
    try std.testing.expectEqual(@as(u8, 0), lines[0].exit_code);
    try std.testing.expectEqualStrings("dexopt", lines[1].step_id);
    try std.testing.expectEqual(@as(u8, 0), lines[1].exit_code);

    var iterator = scratch.dir.iterate();
    try std.testing.expect((try iterator.next(io)) == null);
}

test "runScript fails when the push fails and still cleans up" {
    var fake = try Fake.scenario("pushfail");
    defer fake.deinit();
    var scratch = std.testing.tmpDir(.{ .iterate = true });
    defer scratch.cleanup();

    try std.testing.expectError(
        error.AdbFailed,
        adb.runScript(alloc, fake.handle(), "FAKE123", "echo step\n", scratch.dir),
    );

    var iterator = scratch.dir.iterate();
    try std.testing.expect((try iterator.next(io)) == null);
}

test "doctor diagnoses a healthy device" {
    var fake = try Fake.scenario("ok");
    defer fake.deinit();
    var env = emptyEnv();
    defer env.deinit();

    var diagnosis = try doctor.diagnose(alloc, io, &env, fake.path);
    defer diagnosis.deinit(alloc);

    try std.testing.expect(diagnosis.adb_path != null);
    try std.testing.expect(diagnosis.resolve_error == null);
    try std.testing.expect(diagnosis.version != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnosis.version.?, "Android Debug Bridge") != null);
    try std.testing.expectEqual(@as(?bool, true), diagnosis.server_ok);
    try std.testing.expectEqual(@as(usize, 1), diagnosis.devices.len);
    try std.testing.expectEqual(adb.DeviceState.device, diagnosis.devices[0].state);
}

test "doctor reports an unauthorized device" {
    var fake = try Fake.scenario("unauthorized");
    defer fake.deinit();
    var env = emptyEnv();
    defer env.deinit();

    var diagnosis = try doctor.diagnose(alloc, io, &env, fake.path);
    defer diagnosis.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), diagnosis.devices.len);
    try std.testing.expectEqual(adb.DeviceState.unauthorized, diagnosis.devices[0].state);
    try std.testing.expect(diagnosis.devices_error == null);
}

test "doctor records a missing adb binary" {
    var env = emptyEnv();
    defer env.deinit();

    var diagnosis = try doctor.diagnose(alloc, io, &env, "definitely-missing-adb-binary");
    defer diagnosis.deinit(alloc);

    try std.testing.expect(diagnosis.adb_path == null);
    try std.testing.expect(diagnosis.resolve_error != null);
    try std.testing.expectEqual(@as(usize, 0), diagnosis.devices.len);
}

test "doctor records a server that cannot start" {
    var fake = try Fake.scenario("serverfail");
    defer fake.deinit();
    var env = emptyEnv();
    defer env.deinit();

    var diagnosis = try doctor.diagnose(alloc, io, &env, fake.path);
    defer diagnosis.deinit(alloc);

    try std.testing.expect(diagnosis.server_error != null);
    try std.testing.expectEqual(@as(?bool, null), diagnosis.server_ok);
    try std.testing.expectEqual(@as(usize, 1), diagnosis.devices.len);
}

test "doctor command exits zero and prints the device" {
    var fake = try Fake.scenario("ok");
    defer fake.deinit();
    var env = emptyEnv();
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(alloc);
    defer err.deinit();

    const code = try main.run(
        arena.allocator(),
        io,
        &env,
        &.{ "doctor", "--adb", fake.path },
        &out.writer,
        &err.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "FAKE123") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "server: running") != null);
    try std.testing.expectEqualStrings("", err.writer.buffered());
}

const CommandOutput = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(output: *const CommandOutput) void {
        alloc.free(output.stdout);
        alloc.free(output.stderr);
    }
};

fn runWithEnv(
    fake: *const Fake,
    env: *const std.process.Environ.Map,
    args: []const []const u8,
) !CommandOutput {
    const full = try alloc.alloc([]const u8, args.len + 2);
    defer alloc.free(full);
    @memcpy(full[0..args.len], args);
    full[args.len] = "--adb";
    full[args.len + 1] = fake.path;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var err_writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer err_writer.deinit();

    const code = try main.run(arena.allocator(), io, env, full, &out.writer, &err_writer.writer);
    const stdout = try out.toOwnedSlice();
    errdefer alloc.free(stdout);
    const stderr = try err_writer.toOwnedSlice();
    return .{ .code = code, .stdout = stdout, .stderr = stderr };
}

fn runWithFake(fake: *const Fake, args: []const []const u8) !CommandOutput {
    var env = emptyEnv();
    defer env.deinit();
    return runWithEnv(fake, &env, args);
}

const TestEnv = struct {
    map: std.process.Environ.Map,
    appdata: []u8,
    snapshot_dir: []u8,
    log_dir: []u8,

    fn init(fake: *const Fake) !TestEnv {
        var map = std.process.Environ.Map.init(alloc);
        errdefer map.deinit();

        const appdata = try std.fs.path.join(alloc, &.{ fake.dir_path, "appdata" });
        errdefer alloc.free(appdata);
        try std.Io.Dir.cwd().createDirPath(io, appdata);

        try map.put("APPDATA", appdata);
        try map.put("XDG_CONFIG_HOME", appdata);
        try map.put("HOME", appdata);

        const snapshot_dir = try paths.snapshotDir(alloc, &map);
        errdefer alloc.free(snapshot_dir);
        const log_dir = try paths.logDir(alloc, &map);
        return .{
            .map = map,
            .appdata = appdata,
            .snapshot_dir = snapshot_dir,
            .log_dir = log_dir,
        };
    }

    fn deinit(env: *TestEnv) void {
        alloc.free(env.log_dir);
        alloc.free(env.snapshot_dir);
        alloc.free(env.appdata);
        env.map.deinit();
    }

    fn pointAt(env: *TestEnv, path: []const u8) !void {
        try env.map.put("APPDATA", path);
        try env.map.put("XDG_CONFIG_HOME", path);
        try env.map.put("HOME", path);
    }

    fn snapshotCount(env: *const TestEnv) !usize {
        return entryCount(env.snapshot_dir);
    }

    fn logCount(env: *const TestEnv) !usize {
        return entryCount(env.log_dir);
    }
};

fn entryCount(dir_path: []const u8) !usize {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);

    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |_| count += 1;
    return count;
}

fn exists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

test "probe reads the fingerprint from the fake adb" {
    var fake = try Fake.scenario("scan_light");
    defer fake.deinit();

    var fingerprint = try device.probe(alloc, fake.handle(), "FAKE123");
    defer fingerprint.deinit(alloc);

    try std.testing.expectEqualStrings("FAKE123", fingerprint.serial);
    try std.testing.expectEqual(@as(?u32, 29), fingerprint.sdk);
    try std.testing.expectEqualStrings("10", fingerprint.release.?);
    try std.testing.expectEqualStrings("Xiaomi", fingerprint.manufacturer.?);
    try std.testing.expectEqualStrings("Redmi Note 5", fingerprint.model.?);
    try std.testing.expectEqualStrings("arm64-v8a", fingerprint.abi.?);
    try std.testing.expectEqual(@as(?bool, false), fingerprint.low_ram);
    try std.testing.expectEqual(@as(?u64, 2947), fingerprint.ram_total_mb);
}

test "probe fails when the device cannot be queried" {
    var fake = try Fake.scenario("unauthorized");
    defer fake.deinit();

    try std.testing.expectError(
        error.AdbFailed,
        device.probe(alloc, fake.handle(), "FAKE123"),
    );
}

test "scan prints the device info and a light recommendation" {
    var fake = try Fake.scenario("scan_light");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{"scan"});
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqualStrings("", output.stderr);

    const text = output.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "device: FAKE123\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "model: Redmi Note 5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "android: 10 (SDK 29)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ram: 2947 MB\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "recommendation: light") != null);
}

test "scan emits the fingerprint and recommendation as JSON" {
    var fake = try Fake.scenario("scan_light");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{ "scan", "--json" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    const text = output.stdout;
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"device\":{"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"sdk\":29") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"model\":\"Redmi Note 5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"ram_total_mb\":2947") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"profile\":\"light\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
}

test "scan recommends balanced for a mid-range device" {
    var fake = try Fake.scenario("ok");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{"scan"});
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(
        std.mem.indexOf(u8, output.stdout, "recommendation: balanced (RAM 3800 MB <= 4096 MB)") != null,
    );
}

test "scan leaves a high-end device alone" {
    var fake = try Fake.scenario("scan_roomy");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{ "scan", "--json" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    const text = output.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"sdk\":34") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"ram_total_mb\":7910") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"profile\":null") != null);
}

test "scan tolerates missing device fields" {
    var fake = try Fake.scenario("scan_partial");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{ "scan", "--json" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqualStrings("", output.stderr);
    const text = output.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"sdk\":30") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"release\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"model\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"low_ram\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"ram_total_mb\":2947") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"profile\":\"light\"") != null);
}

test "scan reports an unknown recommendation without RAM" {
    var fake = try Fake.scenario("scan_no_ram");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{"scan"});
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "ram: unknown") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, output.stdout, "recommendation: none (RAM total is unavailable)") != null,
    );
}

test "scan refuses multiple devices without a serial" {
    var fake = try Fake.scenario("multi");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{"scan"});
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 4), output.code);
    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "multiple devices connected") != null);
}

test "scan accepts an explicit serial when several devices are attached" {
    var fake = try Fake.scenario("multi");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{ "scan", "-s", "FAKE123" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stdout, "device: FAKE123") != null);
}

test "scan refuses an offline selected device" {
    var fake = try Fake.scenario("multi");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{ "scan", "-s", "FAKE456" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 4), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "device 'FAKE456' is offline") != null);
}

test "scan refuses an unauthorized device" {
    var fake = try Fake.scenario("unauthorized");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{"scan"});
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 4), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "is unauthorized") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "USB debugging prompt") != null);
}

test "scan reports when no device is attached" {
    var fake = try Fake.scenario("none");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{"scan"});
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 4), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "no device connected") != null);
}

test "scan reports a serial that does not exist" {
    var fake = try Fake.scenario("multi");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{ "scan", "-s", "NOPE" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 4), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "device 'NOPE' not found") != null);
}

test "doctor command can emit JSON" {
    var fake = try Fake.scenario("ok");
    defer fake.deinit();
    var env = emptyEnv();
    defer env.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(alloc);
    defer err.deinit();

    const code = try main.run(
        arena.allocator(),
        io,
        &env,
        &.{ "doctor", "--json", "--adb", fake.path },
        &out.writer,
        &err.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), code);
    const text = out.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"adb\":{"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"state\":\"device\"") != null);
}

test "plan light prints the diff for a matching device" {
    var fake = try Fake.scenario("scan_light");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{ "plan", "light" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqualStrings("", output.stderr);

    const text = output.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "profile: light\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "device: FAKE123\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "android: SDK 29\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ram: 2947 MB\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "steps: 5 (apply 5, skip 0, blocked 0)\n") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "global/window_animation_scale  1.0 -> 0.5  [safe]") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "global/transition_animation_scale  0.5 -> 0.5  (unchanged)") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "global/animator_duration_scale  (unset) -> 0.5") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "compile speed-profile (all)  (not tracked)") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "idle maintenance  (not tracked)") != null);
}

test "plan light can emit JSON" {
    var fake = try Fake.scenario("scan_light");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{ "plan", "light", "--json" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    const text = output.stdout;
    try std.testing.expect(std.mem.startsWith(
        u8,
        text,
        "{\"profile\":\"light\",\"device\":\"FAKE123\",\"sdk\":29,\"ram_total_mb\":2947",
    ));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"id\":\"anim-window\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "\"current\":{\"state\":\"value\",\"value\":\"1.0\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "\"current\":{\"state\":\"unset\",\"value\":null}") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "\"summary\":{\"apply\":5,\"skip\":0,\"blocked\":0}") != null,
    );
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
}

test "plan balanced applies the phantom steps on a supported device" {
    var fake = try Fake.scenario("plan_balanced");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{ "plan", "balanced" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    const text = output.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "profile: balanced\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "android: SDK 33\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ram: 3808 MB\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "steps: 7 (apply 7, skip 0, blocked 0)\n") != null);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            text,
            "activity_manager/max_phantom_processes  32 -> 2147483647  [caution]",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            text,
            "global/settings_enable_monitor_phantom_procs  true -> false  [caution]",
        ) != null,
    );
}

test "plan skips every step when the device is outside the profile limits" {
    var fake = try Fake.scenario("scan_roomy");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{ "plan", "light" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    const text = output.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "steps: 5 (apply 0, skip 5, blocked 0)\n") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "profile requires RAM <= 3072 MB (device has 7910 MB)") != null,
    );
}

test "plan reports a missing profile before touching adb" {
    var fake = try Fake.scenario("ok");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{ "plan", "missing-profile" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 1), output.code);
    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expect(
        std.mem.indexOf(u8, output.stderr, "profile 'missing-profile' was not found") != null,
    );
}

test "plan refuses multiple devices without a serial" {
    var fake = try Fake.scenario("multi");
    defer fake.deinit();

    const output = try runWithFake(&fake, &.{ "plan", "light" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 4), output.code);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "multiple devices connected") != null);
}

test "apply without --yes is a dry run and writes nothing" {
    var fake = try Fake.scenario("scan_light");
    defer fake.deinit();
    var env = try TestEnv.init(&fake);
    defer env.deinit();

    const output = try runWithEnv(&fake, &env.map, &.{ "apply", "light" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    try std.testing.expectEqualStrings("", output.stderr);
    const text = output.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "mode: apply\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dry run: yes\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "snapshot: (dry run, nothing written)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pass --yes to apply the plan") != null);
    try std.testing.expectEqual(@as(usize, 0), try env.snapshotCount());
    try std.testing.expectEqual(@as(usize, 0), try env.logCount());

    const state_file = try std.fs.path.join(alloc, &.{ fake.dir_path, ".fake_adb_state" });
    defer alloc.free(state_file);
    try std.testing.expect(!exists(state_file));
}

test "apply dry run can emit JSON" {
    var fake = try Fake.scenario("scan_light");
    defer fake.deinit();
    var env = try TestEnv.init(&fake);
    defer env.deinit();

    const output = try runWithEnv(&fake, &env.map, &.{ "apply", "light", "--json" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 0), output.code);
    const text = output.stdout;
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"mode\":\"apply\",\"profile\":\"light\",\"device\":\"FAKE123\""));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"dry_run\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"snapshot_path\":null") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "\"summary\":{\"planned\":4,\"applied\":0,\"reverted\":0,\"unchanged\":1,\"skipped\":0,\"failed\":0}") != null,
    );
}

test "apply then revert restores the same plan" {
    var fake = try Fake.scenario("scan_light");
    defer fake.deinit();
    var env = try TestEnv.init(&fake);
    defer env.deinit();

    const baseline = try runWithEnv(&fake, &env.map, &.{ "plan", "light", "--json" });
    defer baseline.deinit();
    try std.testing.expectEqual(@as(u8, 0), baseline.code);

    const applied = try runWithEnv(&fake, &env.map, &.{ "apply", "light", "--yes" });
    defer applied.deinit();
    try std.testing.expectEqual(@as(u8, 0), applied.code);
    try std.testing.expectEqualStrings("", applied.stderr);
    try std.testing.expect(std.mem.indexOf(u8, applied.stdout, "snapshot: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, applied.stdout, "log: ") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, applied.stdout, "to undo: reclaim revert --snapshot") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            applied.stdout,
            "steps: 5 (planned 0, applied 4, reverted 0, unchanged 1, skipped 0, failed 0)",
        ) != null,
    );
    try std.testing.expectEqual(@as(usize, 1), try env.snapshotCount());
    try std.testing.expectEqual(@as(usize, 1), try env.logCount());

    const changed = try runWithEnv(&fake, &env.map, &.{ "plan", "light", "--json" });
    defer changed.deinit();
    try std.testing.expectEqual(@as(u8, 0), changed.code);
    try std.testing.expect(std.mem.indexOf(
        u8,
        changed.stdout,
        "\"target\":\"global/window_animation_scale\",\"current\":{\"state\":\"value\",\"value\":\"0.5\"},\"desired\":\"0.5\",\"status\":\"apply\",\"changed\":false",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        changed.stdout,
        "\"target\":\"global/animator_duration_scale\",\"current\":{\"state\":\"value\",\"value\":\"0.5\"}",
    ) != null);

    const preview = try runWithEnv(&fake, &env.map, &.{"revert"});
    defer preview.deinit();
    try std.testing.expectEqual(@as(u8, 0), preview.code);
    try std.testing.expect(std.mem.indexOf(u8, preview.stdout, "mode: revert\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview.stdout, "dry run: yes\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview.stdout, "steps: 3 (planned 3") != null);

    const reverted = try runWithEnv(&fake, &env.map, &.{ "revert", "--yes" });
    defer reverted.deinit();
    try std.testing.expectEqual(@as(u8, 0), reverted.code);
    try std.testing.expectEqualStrings("", reverted.stderr);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            reverted.stdout,
            "steps: 3 (planned 0, applied 0, reverted 3, unchanged 0, skipped 0, failed 0)",
        ) != null,
    );

    const restored = try runWithEnv(&fake, &env.map, &.{ "plan", "light", "--json" });
    defer restored.deinit();
    try std.testing.expectEqual(@as(u8, 0), restored.code);
    try std.testing.expectEqualStrings(baseline.stdout, restored.stdout);
}

test "apply refuses to run when the snapshot cannot be written" {
    var fake = try Fake.scenario("scan_light");
    defer fake.deinit();
    var env = try TestEnv.init(&fake);
    defer env.deinit();

    const baseline = try runWithEnv(&fake, &env.map, &.{ "plan", "light", "--json" });
    defer baseline.deinit();

    const blocker = try std.fs.path.join(alloc, &.{ fake.dir_path, "blocked-appdata" });
    defer alloc.free(blocker);
    var file = try std.Io.Dir.createFileAbsolute(io, blocker, .{});
    file.close(io);
    try env.pointAt(blocker);

    const output = try runWithEnv(&fake, &env.map, &.{ "apply", "light", "--yes" });
    defer output.deinit();
    try std.testing.expectEqual(@as(u8, 1), output.code);
    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "snapshot") != null);

    const after = try runWithEnv(&fake, &env.map, &.{ "plan", "light", "--json" });
    defer after.deinit();
    try std.testing.expectEqualStrings(baseline.stdout, after.stdout);
}

test "apply reports a partial failure and revert still restores the device" {
    var fake = try Fake.scenario("apply_fail");
    defer fake.deinit();
    var env = try TestEnv.init(&fake);
    defer env.deinit();

    const baseline = try runWithEnv(&fake, &env.map, &.{ "plan", "light", "--json" });
    defer baseline.deinit();

    const applied = try runWithEnv(&fake, &env.map, &.{ "apply", "light", "--yes" });
    defer applied.deinit();
    try std.testing.expectEqual(@as(u8, 5), applied.code);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            applied.stdout,
            "steps: 5 (planned 0, applied 4, reverted 0, unchanged 0, skipped 0, failed 1)",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, applied.stdout, "the command exited with code 1") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, applied.stdout, "more than half of the steps failed") == null,
    );
    try std.testing.expectEqual(@as(usize, 1), try env.snapshotCount());

    const reverted = try runWithEnv(&fake, &env.map, &.{ "revert", "--yes" });
    defer reverted.deinit();
    try std.testing.expectEqual(@as(u8, 0), reverted.code);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            reverted.stdout,
            "steps: 4 (planned 0, applied 0, reverted 4, unchanged 0, skipped 0, failed 0)",
        ) != null,
    );

    const restored = try runWithEnv(&fake, &env.map, &.{ "plan", "light", "--json" });
    defer restored.deinit();
    try std.testing.expectEqualStrings(baseline.stdout, restored.stdout);
}

test "apply verifies changes and reports a mismatch" {
    var fake = try Fake.scenario("apply_liar");
    defer fake.deinit();
    var env = try TestEnv.init(&fake);
    defer env.deinit();

    const baseline = try runWithEnv(&fake, &env.map, &.{ "plan", "light", "--json" });
    defer baseline.deinit();

    const applied = try runWithEnv(&fake, &env.map, &.{ "apply", "light", "--yes", "--json" });
    defer applied.deinit();

    try std.testing.expectEqual(@as(u8, 5), applied.code);
    try std.testing.expect(std.mem.indexOf(u8, applied.stdout, "\"aborted\":true") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        applied.stdout,
        "\"status\":\"failed\",\"verified\":false,\"exit_code\":0,\"reason\":\"verification failed: expected '0.5', found '(unset)'\"",
    ) != null);

    const after = try runWithEnv(&fake, &env.map, &.{ "plan", "light", "--json" });
    defer after.deinit();
    try std.testing.expectEqualStrings(baseline.stdout, after.stdout);
}

test "apply aborts when more than half of the steps fail" {
    var fake = try Fake.scenario("apply_broken");
    defer fake.deinit();
    var env = try TestEnv.init(&fake);
    defer env.deinit();

    const baseline = try runWithEnv(&fake, &env.map, &.{ "plan", "light", "--json" });
    defer baseline.deinit();

    const applied = try runWithEnv(&fake, &env.map, &.{ "apply", "light", "--yes", "--json" });
    defer applied.deinit();
    try std.testing.expectEqual(@as(u8, 5), applied.code);
    try std.testing.expect(std.mem.indexOf(u8, applied.stdout, "\"aborted\":true") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, applied.stdout, "\"summary\":{\"planned\":0,\"applied\":0,\"reverted\":0,\"unchanged\":0,\"skipped\":0,\"failed\":5}") != null,
    );

    const after = try runWithEnv(&fake, &env.map, &.{ "plan", "light", "--json" });
    defer after.deinit();
    try std.testing.expectEqualStrings(baseline.stdout, after.stdout);
}

test "revert without a snapshot exits one" {
    var fake = try Fake.scenario("scan_light");
    defer fake.deinit();
    var env = try TestEnv.init(&fake);
    defer env.deinit();

    const output = try runWithEnv(&fake, &env.map, &.{"revert"});
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 1), output.code);
    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "no snapshot found") != null);
}

test "revert refuses a snapshot taken on another device" {
    var fake = try Fake.scenario("scan_light");
    defer fake.deinit();
    var env = try TestEnv.init(&fake);
    defer env.deinit();

    var entries: [0]snapshot.Entry = .{};
    const snap: snapshot.Snapshot = .{
        .created = "2026-10-25T10:00:00Z",
        .device = .{ .serial = "OTHER", .sdk = 29 },
        .profile = "light",
        .entries = &entries,
    };
    var diagnostic: snapshot.Diagnostic = .{};
    defer diagnostic.deinit(alloc);
    const path = try snapshot.save(alloc, io, env.snapshot_dir, snap, 1_700_000_000, &diagnostic);
    defer alloc.free(path);

    const output = try runWithEnv(&fake, &env.map, &.{ "revert", "--snapshot", path, "--yes" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 1), output.code);
    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expect(
        std.mem.indexOf(u8, output.stderr, "snapshot was taken on device 'OTHER'") != null,
    );
}

test "apply rejects unknown step ids" {
    var fake = try Fake.scenario("scan_light");
    defer fake.deinit();
    var env = try TestEnv.init(&fake);
    defer env.deinit();

    const output = try runWithEnv(&fake, &env.map, &.{ "apply", "light", "--yes", "--only", "nope" });
    defer output.deinit();

    try std.testing.expectEqual(@as(u8, 2), output.code);
    try std.testing.expectEqualStrings("", output.stdout);
    try std.testing.expect(std.mem.indexOf(u8, output.stderr, "unknown step id 'nope'") != null);
    try std.testing.expectEqual(@as(usize, 0), try env.snapshotCount());
}

test "denylist reads the default apps from the device" {
    var fake = try Fake.scenario("deny");
    defer fake.deinit();

    var dynamic = try denylist.readDynamic(alloc, fake.handle(), "FAKE123");
    defer dynamic.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 4), dynamic.entries.len);
    try std.testing.expectEqual(denylist.Role.launcher, dynamic.roleOf("com.example.launcher").?);
    try std.testing.expectEqual(denylist.Role.keyboard, dynamic.roleOf("com.example.keyboard").?);
    try std.testing.expectEqual(denylist.Role.dialer, dynamic.roleOf("com.example.dialer").?);
    try std.testing.expectEqual(denylist.Role.sms, dynamic.roleOf("com.example.sms").?);
}

test "denylist fails closed when a device query fails" {
    var fake = try Fake.scenario("deny_fail");
    defer fake.deinit();

    try std.testing.expectError(
        error.AdbFailed,
        denylist.readDynamic(alloc, fake.handle(), "FAKE123"),
    );
}
