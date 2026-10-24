//! Integration tests for the adb layer and doctor, driven by the fake adb
//! binary built from tests/fake_adb/adb.zig.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const adb = @import("adb.zig");
const doctor = @import("doctor.zig");
const main = @import("main.zig");

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

    const lines = try adb.runScript(alloc, fake.handle(), "FAKE123", "echo step\n", scratch.dir);
    defer adb.freeScriptLines(alloc, lines);

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("anim-window", lines[0].step_id);
    try std.testing.expectEqual(@as(u8, 0), lines[0].exit_code);
    try std.testing.expectEqualStrings("dexopt", lines[1].step_id);
    try std.testing.expectEqual(@as(u8, 1), lines[1].exit_code);

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
