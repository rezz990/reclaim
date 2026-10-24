const std = @import("std");
const cli = @import("cli.zig");
const adb = @import("adb.zig");
const doctor = @import("doctor.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub fn printHelp(writer: *Writer) Writer.Error!void {
    try writer.writeAll(cli.help_text);
}

pub fn printVersion(writer: *Writer) Writer.Error!void {
    try writer.print("reclaim {s}\n", .{cli.version});
}

pub fn notImplemented(writer: *Writer, command: []const u8) Writer.Error!void {
    try writer.print("reclaim: '{s}' is not implemented in this phase\n", .{command});
}

pub fn usageError(writer: *Writer, failure: cli.Failure) Writer.Error!void {
    const arg = failure.arg orelse "";
    try writer.writeAll("reclaim: error: ");
    switch (failure.kind) {
        .missing_command => try writer.writeAll("missing command"),
        .unknown_command => try writer.print("unknown command '{s}'", .{arg}),
        .unknown_flag => try writer.print("unknown option '{s}'", .{arg}),
        .missing_value => try writer.print("option '{s}' requires a value", .{arg}),
        .invalid_value => try writer.print("invalid value for option '{s}'", .{arg}),
        .missing_argument => try writer.print("missing required argument for '{s}'", .{arg}),
        .unexpected_argument => try writer.print("unexpected argument '{s}'", .{arg}),
    }
    try writer.writeAll("\nRun 'reclaim --help' for usage.\n");
}

pub fn printDoctor(writer: *Writer, diagnosis: doctor.Diagnosis) Writer.Error!void {
    const path = diagnosis.adb_path orelse {
        try writer.writeAll("adb: not found\n");
        if (diagnosis.resolve_error) |message| try writer.print("error: {s}\n", .{message});
        return;
    };
    try writer.print("adb: {s}\n", .{path});

    if (diagnosis.version) |version| {
        try writer.print("version: {s}\n", .{version});
    } else if (diagnosis.version_error) |message| {
        try writer.print("version: unavailable ({s})\n", .{message});
    }

    if (diagnosis.server_ok orelse false) {
        try writer.writeAll("server: running\n");
    } else if (diagnosis.server_error) |message| {
        try writer.print("server: unavailable ({s})\n", .{message});
    }

    if (diagnosis.devices_error) |message| {
        try writer.print("devices: unavailable ({s})\n", .{message});
        return;
    }
    try writer.print("devices: {d}\n", .{diagnosis.devices.len});
    for (diagnosis.devices) |entry| {
        try writer.print("  {s}  {s}\n", .{ entry.serial, entry.state.label() });
    }

    var hint_header = false;
    for (diagnosis.devices) |entry| {
        const hint = hintFor(entry.state) orelse continue;
        if (!hint_header) {
            try writer.writeAll("hints:\n");
            hint_header = true;
        }
        try writer.print("  {s} ({s}): {s}\n", .{ entry.serial, entry.state.label(), hint });
    }
}

fn hintFor(state: adb.DeviceState) ?[]const u8 {
    return switch (state) {
        .device => null,
        .unauthorized => "accept the USB debugging prompt on the device, then run doctor again",
        .offline => "reconnect the device or restart the adb server",
        .no_permissions => "fix USB permissions: add your user to the plugdev group on Linux, or install the OEM USB driver on Windows",
        .unknown => "unexpected device state; reconnect the device",
    };
}

pub fn printDoctorJson(
    alloc: Allocator,
    writer: *Writer,
    diagnosis: doctor.Diagnosis,
) (Allocator.Error || Writer.Error)!void {
    const devices = try alloc.alloc(DeviceJson, diagnosis.devices.len);
    defer alloc.free(devices);
    for (diagnosis.devices, 0..) |entry, index| {
        devices[index] = .{
            .serial = entry.serial,
            .state = entry.state.label(),
            .detail = entry.detail,
        };
    }

    const view: DoctorJson = .{
        .adb = .{
            .path = diagnosis.adb_path,
            .version = diagnosis.version,
            .error_message = diagnosis.resolve_error orelse diagnosis.version_error,
        },
        .server = .{
            .ok = diagnosis.server_ok,
            .error_message = diagnosis.server_error,
        },
        .devices = devices,
        .devices_error = diagnosis.devices_error,
    };
    try std.json.Stringify.value(view, .{}, writer);
    try writer.writeAll("\n");
}

const DeviceJson = struct {
    serial: []const u8,
    state: []const u8,
    detail: []const u8,
};

const AdbJson = struct {
    path: ?[]const u8 = null,
    version: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

const ServerJson = struct {
    ok: ?bool = null,
    error_message: ?[]const u8 = null,
};

const DoctorJson = struct {
    adb: AdbJson,
    server: ServerJson,
    devices: []const DeviceJson,
    devices_error: ?[]const u8 = null,
};

const Render = struct {
    allocating: std.Io.Writer.Allocating,

    fn init() Render {
        return .{ .allocating = .init(std.testing.allocator) };
    }

    fn writer(r: *Render) *Writer {
        return &r.allocating.writer;
    }

    fn output(r: *const Render) []const u8 {
        return r.allocating.writer.buffered();
    }

    fn deinit(r: *Render) void {
        r.allocating.deinit();
    }
};

test "version line" {
    var render: Render = .init();
    defer render.deinit();

    try printVersion(render.writer());
    try std.testing.expectEqualStrings("reclaim 0.1.0\n", render.output());
}

test "help lists every command and the exit codes" {
    var render: Render = .init();
    defer render.deinit();

    try printHelp(render.writer());
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "Usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Exit codes:") != null);
    const commands = [_][]const u8{
        "scan", "plan", "apply", "revert", "bench", "debloat", "watch", "doctor",
    };
    for (commands) |command| {
        try std.testing.expect(std.mem.indexOf(u8, text, command) != null);
    }
}

test "not implemented message names the command" {
    var render: Render = .init();
    defer render.deinit();

    try notImplemented(render.writer(), "watch");
    try std.testing.expectEqualStrings(
        "reclaim: 'watch' is not implemented in this phase\n",
        render.output(),
    );
}

test "doctor report lists devices and hints" {
    const devices = [_]adb.DeviceEntry{
        .{ .serial = "FAKE123", .state = .unauthorized, .detail = "unauthorized" },
        .{ .serial = "FAKE456", .state = .device, .detail = "device" },
    };
    const diagnosis: doctor.Diagnosis = .{
        .adb_path = "/platform-tools/adb",
        .version = "Android Debug Bridge version 1.0.41",
        .server_ok = true,
        .devices = &devices,
    };

    var render: Render = .init();
    defer render.deinit();
    try printDoctor(render.writer(), diagnosis);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "adb: /platform-tools/adb\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "version: Android Debug Bridge version 1.0.41\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "server: running\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "devices: 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  FAKE123  unauthorized\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hints:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "accept the USB debugging prompt") != null);
}

test "doctor report handles a missing adb" {
    const diagnosis: doctor.Diagnosis = .{
        .resolve_error = "adb was not found next to the executable, via --adb, or on PATH",
    };

    var render: Render = .init();
    defer render.deinit();
    try printDoctor(render.writer(), diagnosis);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "adb: not found\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "adb was not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hints:") == null);
}

test "doctor report handles server and device failures" {
    const diagnosis: doctor.Diagnosis = .{
        .adb_path = "/platform-tools/adb",
        .version = "Android Debug Bridge version 1.0.41",
        .server_error = "could not start the adb server",
        .devices_error = "could not list devices",
    };

    var render: Render = .init();
    defer render.deinit();
    try printDoctor(render.writer(), diagnosis);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "server: unavailable (could not start the adb server)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "devices: unavailable (could not list devices)\n") != null);
}

test "doctor JSON is machine readable" {
    const devices = [_]adb.DeviceEntry{
        .{ .serial = "FAKE123", .state = .unauthorized, .detail = "unauthorized" },
    };
    const diagnosis: doctor.Diagnosis = .{
        .adb_path = "/usr/bin/adb",
        .version = "Android Debug Bridge version 1.0.41",
        .server_ok = true,
        .devices = &devices,
    };

    var render: Render = .init();
    defer render.deinit();
    try printDoctorJson(std.testing.allocator, render.writer(), diagnosis);
    const text = render.output();

    try std.testing.expect(std.mem.startsWith(u8, text, "{\"adb\":{"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"path\":\"/usr/bin/adb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"state\":\"unauthorized\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"serial\":\"FAKE123\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
}

test "usage errors explain the failure" {
    const cases = [_]struct {
        failure: cli.Failure,
        expected: []const u8,
    }{
        .{
            .failure = .{ .kind = .missing_command },
            .expected = "reclaim: error: missing command\n",
        },
        .{
            .failure = .{ .kind = .unknown_command, .arg = "optimize" },
            .expected = "reclaim: error: unknown command 'optimize'\n",
        },
        .{
            .failure = .{ .kind = .unknown_flag, .arg = "--fast" },
            .expected = "reclaim: error: unknown option '--fast'\n",
        },
        .{
            .failure = .{ .kind = .missing_value, .arg = "--adb" },
            .expected = "reclaim: error: option '--adb' requires a value\n",
        },
        .{
            .failure = .{ .kind = .invalid_value, .arg = "--runs" },
            .expected = "reclaim: error: invalid value for option '--runs'\n",
        },
        .{
            .failure = .{ .kind = .missing_argument, .arg = "plan" },
            .expected = "reclaim: error: missing required argument for 'plan'\n",
        },
        .{
            .failure = .{ .kind = .unexpected_argument, .arg = "extra" },
            .expected = "reclaim: error: unexpected argument 'extra'\n",
        },
    };

    for (cases) |case| {
        var render: Render = .init();
        defer render.deinit();

        try usageError(render.writer(), case.failure);
        try std.testing.expect(std.mem.startsWith(u8, render.output(), case.expected));
        try std.testing.expect(
            std.mem.endsWith(u8, render.output(), "Run 'reclaim --help' for usage.\n"),
        );
    }
}
