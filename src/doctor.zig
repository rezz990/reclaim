//! `reclaim doctor`: diagnose the adb binary, server, and connected devices.
//! Read-only; it never changes device state.

const std = @import("std");
const adb = @import("adb.zig");

const Allocator = std.mem.Allocator;

pub const Diagnosis = struct {
    adb_path: ?[]const u8 = null,
    resolve_error: ?[]const u8 = null,
    version: ?[]const u8 = null,
    version_error: ?[]const u8 = null,
    server_ok: ?bool = null,
    server_error: ?[]const u8 = null,
    devices: []const adb.DeviceEntry = &.{},
    devices_error: ?[]const u8 = null,

    pub fn deinit(diagnosis: *Diagnosis, alloc: Allocator) void {
        if (diagnosis.adb_path) |value| alloc.free(value);
        if (diagnosis.resolve_error) |value| alloc.free(value);
        if (diagnosis.version) |value| alloc.free(value);
        if (diagnosis.version_error) |value| alloc.free(value);
        if (diagnosis.server_error) |value| alloc.free(value);
        if (diagnosis.devices_error) |value| alloc.free(value);
        adb.freeDevices(alloc, diagnosis.devices);
        diagnosis.* = .{};
    }
};

pub fn diagnose(
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    adb_override: ?[]const u8,
) Allocator.Error!Diagnosis {
    var diagnosis: Diagnosis = .{};
    errdefer diagnosis.deinit(alloc);

    const adb_path = adb.resolve(alloc, io, env, adb_override) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagnosis.resolve_error = try alloc.dupe(
                u8,
                "adb was not found next to the executable, via --adb, or on PATH",
            );
            return diagnosis;
        },
    };
    diagnosis.adb_path = adb_path.path;

    var version_result = adb.run(alloc, adb_path, &.{"version"}, adb.default_timeout_ms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            diagnosis.version_error = try alloc.dupe(u8, "could not run 'adb version'");
            break :blk null;
        },
    };
    if (version_result) |*result| {
        defer result.deinit(alloc);
        if (result.timed_out or result.exit_code != 0) {
            diagnosis.version_error = try alloc.dupe(u8, "adb version failed");
        } else if (try firstLine(alloc, result.stdout)) |version| {
            diagnosis.version = version;
        } else {
            diagnosis.version_error = try alloc.dupe(u8, "adb version returned no output");
        }
    }

    adb.startServer(alloc, adb_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagnosis.server_error = try alloc.dupe(u8, "could not start the adb server");
        },
    };
    if (diagnosis.server_error == null) diagnosis.server_ok = true;

    diagnosis.devices = adb.listDevices(alloc, adb_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            diagnosis.devices_error = try alloc.dupe(u8, "could not list devices");
            break :blk &.{};
        },
    };

    return diagnosis;
}

fn firstLine(alloc: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        return try alloc.dupe(u8, line);
    }
    return null;
}
