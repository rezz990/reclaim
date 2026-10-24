const std = @import("std");
const adb = @import("adb.zig");
const cli = @import("cli.zig");
const device = @import("device.zig");
const doctor = @import("doctor.zig");
const plan = @import("plan.zig");
const profile = @import("profile.zig");
const report = @import("report.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, i| argv[i] = arg;

    var out_buffer: [4096]u8 = undefined;
    var out_file: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    defer out_file.interface.flush() catch {};
    var err_buffer: [4096]u8 = undefined;
    var err_file: std.Io.File.Writer = .init(.stderr(), init.io, &err_buffer);
    defer err_file.interface.flush() catch {};

    const args = if (argv.len > 1) argv[1..] else argv[0..0];
    return run(
        arena,
        init.io,
        init.environ_map,
        args,
        &out_file.interface,
        &err_file.interface,
    );
}

pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    args: []const []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    switch (try cli.parse(alloc, args)) {
        .invocation => |invocation| switch (invocation) {
            .help => {
                try report.printHelp(out);
                return 0;
            },
            .version => {
                try report.printVersion(out);
                return 0;
            },
            .command => |app| switch (app.command) {
                .scan => return runScan(alloc, io, env, app.global, out, err),
                .plan => |request| return runPlan(
                    alloc,
                    io,
                    env,
                    app.global,
                    request.profile,
                    out,
                    err,
                ),
                .doctor => return runDoctor(alloc, io, env, app.global, out),
                else => {
                    try report.notImplemented(err, cli.commandName(app.command));
                    return 1;
                },
            },
        },
        .failure => |failure| {
            try report.usageError(err, failure);
            return 2;
        },
    }
}

const Setup = struct {
    adb_path: adb.AdbPath,
    entries: []adb.DeviceEntry,
    fingerprint: device.Fingerprint,

    fn deinit(setup: *Setup, alloc: std.mem.Allocator) void {
        setup.fingerprint.deinit(alloc);
        adb.freeDevices(alloc, setup.entries);
        alloc.free(setup.adb_path.path);
        setup.* = undefined;
    }
};

const SetupResult = union(enum) {
    ready: Setup,
    failed: u8,
};

fn openSession(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    global: cli.GlobalOptions,
    err: *std.Io.Writer,
) !SetupResult {
    const adb_path = adb.resolve(alloc, io, env, global.adb_path) catch |resolve_err| switch (resolve_err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report.printError(
                err,
                "adb was not found next to the executable, via --adb, or on PATH",
            );
            return .{ .failed = 3 };
        },
    };
    var keep_path = false;
    defer if (!keep_path) alloc.free(adb_path.path);

    adb.startServer(alloc, adb_path) catch |start_err| switch (start_err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report.printError(err, "could not start the adb server");
            return .{ .failed = 1 };
        },
    };

    const entries = adb.listDevices(alloc, adb_path) catch |list_err| switch (list_err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report.printError(err, "could not list devices");
            return .{ .failed = 1 };
        },
    };
    var keep_entries = false;
    defer if (!keep_entries) adb.freeDevices(alloc, entries);

    const selected = device.select(entries, global.serial) catch |select_err| {
        try report.printSelectionError(err, select_err, global.serial, entries);
        return .{ .failed = 4 };
    };

    const fingerprint = device.probe(alloc, adb_path, selected.serial) catch |probe_err| switch (probe_err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report.printError(err, "could not read device information");
            return .{ .failed = 1 };
        },
    };

    keep_path = true;
    keep_entries = true;
    return .{ .ready = .{
        .adb_path = adb_path,
        .entries = entries,
        .fingerprint = fingerprint,
    } };
}

fn runScan(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    global: cli.GlobalOptions,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    var setup = switch (try openSession(alloc, io, env, global, err)) {
        .failed => |code| return code,
        .ready => |ready| ready,
    };
    defer setup.deinit(alloc);

    var recommendation = try device.recommend(alloc, setup.fingerprint);
    defer recommendation.deinit(alloc);

    if (global.json) {
        try report.printScanJson(out, setup.fingerprint, recommendation);
    } else {
        try report.printScan(out, setup.fingerprint, recommendation);
    }
    return 0;
}

fn runPlan(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    global: cli.GlobalOptions,
    profile_name: []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    var diagnostic: profile.Diagnostic = .{};
    defer diagnostic.deinit(alloc);

    var loaded = profile.load(alloc, io, profile_name, &diagnostic) catch |load_err| switch (load_err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report.printError(
                err,
                diagnostic.message orelse "could not load the profile",
            );
            return 1;
        },
    };
    defer loaded.deinit(alloc);

    var setup = switch (try openSession(alloc, io, env, global, err)) {
        .failed => |code| return code,
        .ready => |ready| ready,
    };
    defer setup.deinit(alloc);

    var built = try plan.build(alloc, setup.adb_path, setup.fingerprint, loaded);
    defer built.deinit(alloc);

    if (global.json) {
        try report.printPlanJson(alloc, out, built);
    } else {
        try report.printPlan(out, built);
    }

    return if (built.count(.blocked) > 0) 6 else 0;
}

fn runDoctor(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    global: cli.GlobalOptions,
    out: *std.Io.Writer,
) !u8 {
    var diagnosis = try doctor.diagnose(alloc, io, env, global.adb_path);
    defer diagnosis.deinit(alloc);

    if (global.json) {
        try report.printDoctorJson(alloc, out, diagnosis);
    } else {
        try report.printDoctor(out, diagnosis);
    }

    if (diagnosis.adb_path == null) return 3;
    if (diagnosis.version_error != null or
        diagnosis.server_error != null or
        diagnosis.devices_error != null) return 1;
    return 0;
}

test {
    _ = @import("paths.zig");
}

const RunOutput = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(r: *const RunOutput) void {
        std.testing.allocator.free(r.stdout);
        std.testing.allocator.free(r.stderr);
    }
};

fn runForTest(args: []const []const u8) !RunOutput {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var err: std.Io.Writer.Allocating = .init(alloc);
    errdefer err.deinit();

    const code = try run(arena.allocator(), std.testing.io, &env, args, &out.writer, &err.writer);
    const stdout = try out.toOwnedSlice();
    errdefer alloc.free(stdout);
    const stderr = try err.toOwnedSlice();
    return .{ .code = code, .stdout = stdout, .stderr = stderr };
}

test "version prints to stdout and exits zero" {
    const result = try runForTest(&.{"--version"});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expectEqualStrings("reclaim 0.1.0\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "help prints to stdout and exits zero" {
    const result = try runForTest(&.{"--help"});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Usage:") != null);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "missing command reports a usage error" {
    const result = try runForTest(&.{});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 2), result.code);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "missing command") != null);
}

test "unimplemented commands exit one" {
    const result = try runForTest(&.{"bench"});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 1), result.code);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'bench' is not implemented") != null);
}

test "scan without adb exits three" {
    const result = try runForTest(&.{ "scan", "--adb", "definitely-missing-adb-binary" });
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 3), result.code);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "adb was not found") != null);
}

test "plan loads the profile before resolving adb" {
    const result = try runForTest(&.{ "plan", "light", "--adb", "definitely-missing-adb-binary" });
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 3), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "adb was not found") != null);
}

test "invalid arguments exit two" {
    const result = try runForTest(&.{"plan"});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 2), result.code);
    try std.testing.expect(
        std.mem.indexOf(u8, result.stderr, "missing required argument for 'plan'") != null,
    );
}

test "doctor without adb exits three" {
    const result = try runForTest(&.{ "doctor", "--adb", "definitely-missing-adb-binary" });
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 3), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "adb: not found") != null);
    try std.testing.expectEqualStrings("", result.stderr);
}
