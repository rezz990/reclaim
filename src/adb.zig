//! The only module allowed to spawn processes. Everything that talks to adb
//! goes through here.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const default_timeout_ms: u32 = 15_000;
pub const script_timeout_ms: u32 = 120_000;

pub const Error = error{
    AdbNotFound,
    AdbFailed,
    OutOfMemory,
};

pub const AdbPath = struct {
    path: []const u8,
    io: Io,
};

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: ?u8,
    timed_out: bool,

    pub fn deinit(result: *Result, alloc: Allocator) void {
        alloc.free(result.stdout);
        alloc.free(result.stderr);
        result.* = undefined;
    }
};

pub const ShellResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: ?u8,
    timed_out: bool,

    pub fn deinit(result: *ShellResult, alloc: Allocator) void {
        alloc.free(result.stdout);
        alloc.free(result.stderr);
        result.* = undefined;
    }
};

pub const DeviceState = enum {
    device,
    unauthorized,
    offline,
    no_permissions,
    unknown,

    pub fn label(state: DeviceState) []const u8 {
        return switch (state) {
            .device => "device",
            .unauthorized => "unauthorized",
            .offline => "offline",
            .no_permissions => "no permissions",
            .unknown => "unknown",
        };
    }
};

pub const DeviceEntry = struct {
    serial: []const u8,
    state: DeviceState,
    /// Raw state text reported by adb, including any reason suffix.
    detail: []const u8,
};

pub const DeviceEvent = union(enum) {
    connected: DeviceEntry,
    disconnected: []const u8,
};

pub const ScriptLine = struct {
    step_id: []const u8,
    exit_code: u8,
};

pub fn resolve(
    alloc: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    override: ?[]const u8,
) Error!AdbPath {
    const binary_name = if (builtin.os.tag == .windows) "adb.exe" else "adb";

    const exe_path = std.process.executablePathAlloc(io, alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    if (exe_path) |path| {
        defer alloc.free(path);
        if (std.fs.path.dirname(path)) |dir| {
            if (try existingInDir(alloc, io, dir, binary_name)) |found| {
                return .{ .path = found, .io = io };
            }
        }
    }

    if (override) |path| {
        if (try existingPath(alloc, io, path)) |found| {
            return .{ .path = found, .io = io };
        }
    }

    if (env.get("PATH")) |path_value| {
        var parts = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
        while (parts.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, "\"");
            if (part.len == 0) continue;
            if (try existingInDir(alloc, io, part, binary_name)) |found| {
                return .{ .path = found, .io = io };
            }
        }
    }

    return error.AdbNotFound;
}

fn existingInDir(alloc: Allocator, io: Io, dir: []const u8, name: []const u8) Error!?[]u8 {
    const joined = try std.fs.path.join(alloc, &.{ dir, name });
    if (!pathExists(io, joined)) {
        alloc.free(joined);
        return null;
    }
    return joined;
}

fn existingPath(alloc: Allocator, io: Io, path: []const u8) Error!?[]u8 {
    if (!pathExists(io, path)) return null;
    if (std.fs.path.isAbsolute(path)) return try alloc.dupe(u8, path);
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
}

fn pathExists(io: Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

pub fn startServer(alloc: Allocator, adb: AdbPath) Error!void {
    var result = try run(alloc, adb, &.{"start-server"}, default_timeout_ms);
    defer result.deinit(alloc);
    if (result.timed_out or result.exit_code != 0) return error.AdbFailed;
}

pub fn run(
    alloc: Allocator,
    adb: AdbPath,
    args: []const []const u8,
    timeout_ms: u32,
) Error!Result {
    const argv = try alloc.alloc([]const u8, args.len + 1);
    defer alloc.free(argv);
    argv[0] = adb.path;
    @memcpy(argv[1..], args);

    const timeout: Io.Timeout = .{
        .duration = .{
            .raw = Io.Duration.fromMilliseconds(@intCast(timeout_ms)),
            .clock = .awake,
        },
    };
    const outcome = std.process.run(alloc, adb.io, .{
        .argv = argv,
        .timeout = timeout,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return .{
            .stdout = try alloc.alloc(u8, 0),
            .stderr = try alloc.alloc(u8, 0),
            .exit_code = null,
            .timed_out = true,
        },
        else => return error.AdbFailed,
    };

    const exit_code: ?u8 = switch (outcome.term) {
        .exited => |code| code,
        else => null,
    };
    return .{
        .stdout = outcome.stdout,
        .stderr = outcome.stderr,
        .exit_code = exit_code,
        .timed_out = false,
    };
}

pub fn shell(
    alloc: Allocator,
    adb: AdbPath,
    serial: []const u8,
    command: []const u8,
) Error!ShellResult {
    const marked = try std.mem.concat(alloc, u8, &.{ command, "; echo __RC=$?" });
    defer alloc.free(marked);

    var result = try run(alloc, adb, &.{ "-s", serial, "shell", marked }, default_timeout_ms);
    defer result.deinit(alloc);

    const marker = parseExitMarker(result.stdout);
    const stdout = try alloc.dupe(u8, marker.output);
    errdefer alloc.free(stdout);
    const stderr = try alloc.dupe(u8, result.stderr);
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = marker.exit_code,
        .timed_out = result.timed_out,
    };
}

pub const ExitMarker = struct {
    output: []const u8,
    exit_code: ?u8,
};

/// Extracts the trailing `__RC=<n>` line that `shell` appends and removes it
/// from the output. Output without a marker yields a null exit code.
pub fn parseExitMarker(text: []const u8) ExitMarker {
    var output = text;
    var exit_code: ?u8 = null;
    var line_start: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const start = line_start;
        line_start += raw_line.len + 1;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "__RC=")) {
            exit_code = std.fmt.parseInt(u8, line["__RC=".len..], 10) catch null;
            output = text[0..start];
            while (output.len > 0 and
                (output[output.len - 1] == '\n' or output[output.len - 1] == '\r'))
            {
                output = output[0 .. output.len - 1];
            }
            break;
        }
    }
    return .{ .output = output, .exit_code = exit_code };
}

pub fn listDevices(alloc: Allocator, adb: AdbPath) Error![]DeviceEntry {
    var result = try run(alloc, adb, &.{"devices"}, default_timeout_ms);
    defer result.deinit(alloc);
    if (result.timed_out or result.exit_code != 0) return error.AdbFailed;
    return parseDevices(alloc, result.stdout);
}

pub fn parseDevices(alloc: Allocator, text: []const u8) Error![]DeviceEntry {
    var entries: std.ArrayList(DeviceEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            alloc.free(entry.serial);
            alloc.free(entry.detail);
        }
        entries.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "List of devices")) continue;
        if (line[0] == '*') continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const serial = std.mem.trim(u8, line[0..tab], " ");
        const detail = std.mem.trim(u8, line[tab + 1 ..], " ");
        if (serial.len == 0 or detail.len == 0) continue;

        const serial_copy = try alloc.dupe(u8, serial);
        errdefer alloc.free(serial_copy);
        const detail_copy = try alloc.dupe(u8, detail);
        errdefer alloc.free(detail_copy);
        try entries.append(alloc, .{
            .serial = serial_copy,
            .state = parseState(detail),
            .detail = detail_copy,
        });
    }
    return entries.toOwnedSlice(alloc);
}

pub fn freeDevices(alloc: Allocator, entries: []const DeviceEntry) void {
    for (entries) |entry| {
        alloc.free(entry.serial);
        alloc.free(entry.detail);
    }
    alloc.free(entries);
}

pub fn parseState(detail: []const u8) DeviceState {
    if (std.mem.eql(u8, detail, "device")) return .device;
    if (std.mem.eql(u8, detail, "unauthorized")) return .unauthorized;
    if (std.mem.eql(u8, detail, "offline")) return .offline;
    if (std.mem.startsWith(u8, detail, "no permissions")) return .no_permissions;
    return .unknown;
}

/// Streams `adb track-devices` and reports connects, state changes, and
/// disconnects. Entry slices passed to the callback are only valid for the
/// duration of the call.
pub fn trackDevices(alloc: Allocator, adb: AdbPath, callback: *const fn (DeviceEvent) void) Error!void {
    var child = std.process.spawn(adb.io, .{
        .argv = &.{ adb.path, "track-devices" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AdbFailed,
    };
    defer child.kill(adb.io);

    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(adb.io, &buffer);

    var previous: []DeviceEntry = &.{};
    defer freeDevices(alloc, previous);

    while (true) {
        const payload = readTrackMessage(alloc, &reader.interface) catch |err| switch (err) {
            error.EndOfStream => break,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.AdbFailed,
        };
        defer alloc.free(payload);

        const current = try parseDevices(alloc, payload);
        for (current) |entry| {
            const known = findEntry(previous, entry.serial);
            const changed = if (known) |old| old.state != entry.state else true;
            if (changed) callback(.{ .connected = entry });
        }
        for (previous) |entry| {
            if (findEntry(current, entry.serial) == null) {
                callback(.{ .disconnected = entry.serial });
            }
        }

        freeDevices(alloc, previous);
        previous = current;
    }

    const term = child.wait(adb.io) catch return error.AdbFailed;
    if (!term.success()) return error.AdbFailed;
}

fn readTrackMessage(alloc: Allocator, reader: *Io.Reader) TrackReadError![]u8 {
    const hex = reader.takeArray(4) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => return error.AdbFailed,
    };
    const length = std.fmt.parseInt(u16, hex, 16) catch return error.AdbFailed;
    const payload = alloc.alloc(u8, length) catch return error.OutOfMemory;
    errdefer alloc.free(payload);
    if (length > 0) {
        reader.readSliceAll(payload) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return error.AdbFailed,
        };
    }
    return payload;
}

const TrackReadError = error{
    EndOfStream,
    AdbFailed,
    OutOfMemory,
};

fn findEntry(entries: []const DeviceEntry, serial: []const u8) ?DeviceEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.serial, serial)) return entry;
    }
    return null;
}

pub fn runScript(
    alloc: Allocator,
    adb: AdbPath,
    serial: []const u8,
    script: []const u8,
    scratch_dir: Io.Dir,
) Error![]ScriptLine {
    var random: [8]u8 = undefined;
    adb.io.random(&random);
    const id = std.fmt.bytesToHex(random, .lower);

    const name = try std.fmt.allocPrint(alloc, "reclaim_{s}.sh", .{id[0..]});
    defer alloc.free(name);
    const remote = try std.fmt.allocPrint(alloc, "/data/local/tmp/{s}", .{name});
    defer alloc.free(remote);

    scratch_dir.writeFile(adb.io, .{ .sub_path = name, .data = script }) catch
        return error.AdbFailed;
    defer scratch_dir.deleteFile(adb.io, name) catch {};

    const local = scratch_dir.realPathFileAlloc(adb.io, name, alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AdbFailed,
    };
    defer alloc.free(local);

    var pushed = try run(alloc, adb, &.{ "-s", serial, "push", local, remote }, default_timeout_ms);
    defer pushed.deinit(alloc);
    if (pushed.timed_out or pushed.exit_code != 0) return error.AdbFailed;

    var executed = run(
        alloc,
        adb,
        &.{ "-s", serial, "shell", "sh", remote },
        script_timeout_ms,
    ) catch |err| {
        cleanupRemote(alloc, adb, serial, remote);
        return err;
    };
    defer executed.deinit(alloc);
    defer cleanupRemote(alloc, adb, serial, remote);

    if (executed.timed_out) return error.AdbFailed;
    return parseScriptLines(alloc, executed.stdout);
}

fn cleanupRemote(alloc: Allocator, adb: AdbPath, serial: []const u8, remote: []const u8) void {
    var result = run(alloc, adb, &.{ "-s", serial, "shell", "rm", "-f", remote }, default_timeout_ms) catch
        return;
    result.deinit(alloc);
}

pub fn parseScriptLines(alloc: Allocator, text: []const u8) Error![]ScriptLine {
    var lines: std.ArrayList(ScriptLine) = .empty;
    errdefer {
        for (lines.items) |line| alloc.free(line.step_id);
        lines.deinit(alloc);
    }

    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const marker = std.mem.indexOf(u8, line, "__STEP=") orelse continue;
        const rest = line[marker + "__STEP=".len ..];
        const id_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        if (id_end == 0) continue;

        const rc_marker = std.mem.indexOf(u8, rest, "__RC=") orelse continue;
        const rc_start = rc_marker + "__RC=".len;
        var rc_end = rc_start;
        while (rc_end < rest.len and std.ascii.isDigit(rest[rc_end])) : (rc_end += 1) {}
        if (rc_end == rc_start) continue;
        const code = std.fmt.parseInt(u8, rest[rc_start..rc_end], 10) catch continue;

        const step_id = try alloc.dupe(u8, rest[0..id_end]);
        errdefer alloc.free(step_id);
        try lines.append(alloc, .{ .step_id = step_id, .exit_code = code });
    }
    return lines.toOwnedSlice(alloc);
}

pub fn freeScriptLines(alloc: Allocator, lines: []const ScriptLine) void {
    for (lines) |line| alloc.free(line.step_id);
    alloc.free(lines);
}

test "parseState recognizes adb device states" {
    try std.testing.expectEqual(DeviceState.device, parseState("device"));
    try std.testing.expectEqual(DeviceState.unauthorized, parseState("unauthorized"));
    try std.testing.expectEqual(DeviceState.offline, parseState("offline"));
    try std.testing.expectEqual(
        DeviceState.no_permissions,
        parseState("no permissions (user in plugdev group; are your udev rules wrong?)"),
    );
    try std.testing.expectEqual(DeviceState.unknown, parseState("recovery"));
}

test "parseDevices skips headers and noise" {
    const text =
        "List of devices attached\n" ++
        "ABC123\tdevice\n" ++
        "DEF456\tunauthorized\n" ++
        "\n" ++
        "* daemon started successfully *\n" ++
        "not a device line\n";

    const entries = try parseDevices(std.testing.allocator, text);
    defer freeDevices(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("ABC123", entries[0].serial);
    try std.testing.expectEqual(DeviceState.device, entries[0].state);
    try std.testing.expectEqualStrings("DEF456", entries[1].serial);
    try std.testing.expectEqual(DeviceState.unauthorized, entries[1].state);
}

test "parseDevices handles empty output" {
    const entries = try parseDevices(std.testing.allocator, "List of devices attached\n");
    defer freeDevices(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseExitMarker removes the marker and returns the code" {
    const parsed = parseExitMarker("hello\nworld\n__RC=0\n");
    try std.testing.expectEqualStrings("hello\nworld", parsed.output);
    try std.testing.expectEqual(@as(?u8, 0), parsed.exit_code);

    const failed = parseExitMarker("__RC=7\n");
    try std.testing.expectEqualStrings("", failed.output);
    try std.testing.expectEqual(@as(?u8, 7), failed.exit_code);

    const missing = parseExitMarker("no marker here\n");
    try std.testing.expectEqualStrings("no marker here\n", missing.output);
    try std.testing.expectEqual(@as(?u8, null), missing.exit_code);

    const junk = parseExitMarker("value\n__RC=abc\n");
    try std.testing.expectEqualStrings("value", junk.output);
    try std.testing.expectEqual(@as(?u8, null), junk.exit_code);
}

test "parseScriptLines reads step markers and skips noise" {
    const text =
        "starting\n" ++
        "__STEP=anim-window __RC=0\n" ++
        "__STEP=dexopt __RC=1\n" ++
        "no marker\n" ++
        "__STEP=broken\n";

    const lines = try parseScriptLines(std.testing.allocator, text);
    defer freeScriptLines(std.testing.allocator, lines);

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("anim-window", lines[0].step_id);
    try std.testing.expectEqual(@as(u8, 0), lines[0].exit_code);
    try std.testing.expectEqualStrings("dexopt", lines[1].step_id);
    try std.testing.expectEqual(@as(u8, 1), lines[1].exit_code);
}
