const std = @import("std");
const adb = @import("adb.zig");
const apply = @import("apply.zig");
const cli = @import("cli.zig");
const device = @import("device.zig");
const doctor = @import("doctor.zig");
const paths = @import("paths.zig");
const plan = @import("plan.zig");
const profile = @import("profile.zig");
const report = @import("report.zig");
const snapshot = @import("snapshot.zig");

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
                .apply => |request| return runApply(
                    alloc,
                    io,
                    env,
                    app.global,
                    request.profile,
                    .{
                        .yes = request.yes,
                        .skip = request.skip,
                        .only = request.only,
                    },
                    out,
                    err,
                ),
                .revert => |request| return runRevert(
                    alloc,
                    io,
                    env,
                    app.global,
                    request.snapshot,
                    request.yes,
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

const CommandDirs = struct {
    snapshot: []u8,
    log: []u8,

    fn deinit(dirs: *CommandDirs, alloc: std.mem.Allocator) void {
        alloc.free(dirs.snapshot);
        alloc.free(dirs.log);
        dirs.* = undefined;
    }
};

const DirsResult = union(enum) {
    ready: CommandDirs,
    failed: u8,
};

fn resolveDirs(
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    err: *std.Io.Writer,
) !DirsResult {
    const snapshot_dir = paths.snapshotDir(alloc, env) catch |path_err| switch (path_err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report.printError(
                err,
                "could not resolve the snapshot directory; set APPDATA (Windows) or HOME",
            );
            return .{ .failed = 1 };
        },
    };
    var keep = false;
    defer if (!keep) alloc.free(snapshot_dir);

    const log_dir = paths.logDir(alloc, env) catch |path_err| switch (path_err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report.printError(
                err,
                "could not resolve the log directory; set APPDATA (Windows) or HOME",
            );
            return .{ .failed = 1 };
        },
    };

    keep = true;
    return .{ .ready = .{ .snapshot = snapshot_dir, .log = log_dir } };
}

fn runApply(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    global: cli.GlobalOptions,
    profile_name: []const u8,
    options: apply.ApplyOptions,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    var profile_diagnostic: profile.Diagnostic = .{};
    defer profile_diagnostic.deinit(alloc);

    var loaded = profile.load(alloc, io, profile_name, &profile_diagnostic) catch |load_err| switch (load_err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report.printError(
                err,
                profile_diagnostic.message orelse "could not load the profile",
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

    var dirs = switch (try resolveDirs(alloc, env, err)) {
        .failed => |code| return code,
        .ready => |ready| ready,
    };
    defer dirs.deinit(alloc);

    var diagnostic: apply.Diagnostic = .{};
    defer diagnostic.deinit(alloc);

    var outcome = apply.apply(
        alloc,
        io,
        setup.adb_path,
        setup.fingerprint,
        built,
        options,
        .{ .snapshot_dir = dirs.snapshot, .log_dir = dirs.log },
        &diagnostic,
    ) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return reportApplyError(err, failure, diagnostic),
    };
    defer outcome.deinit(alloc);

    if (global.json) {
        try report.printApplyJson(alloc, out, outcome);
    } else {
        try report.printApply(out, outcome);
    }
    return outcomeCode(outcome);
}

fn runRevert(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    global: cli.GlobalOptions,
    requested_snapshot: ?[]const u8,
    yes: bool,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    var load_diagnostic: snapshot.Diagnostic = .{};
    defer load_diagnostic.deinit(alloc);

    var preloaded: ?snapshot.Snapshot = null;
    defer if (preloaded) |*value| value.deinit(alloc);
    var preloaded_path: ?[]u8 = null;
    defer if (preloaded_path) |path| alloc.free(path);

    if (requested_snapshot) |given| {
        preloaded = snapshot.load(alloc, io, given, &load_diagnostic) catch |load_err| switch (load_err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try report.printError(
                    err,
                    load_diagnostic.message orelse "could not read the snapshot",
                );
                return 1;
            },
        };
        preloaded_path = try alloc.dupe(u8, given);
    }

    var setup = switch (try openSession(alloc, io, env, global, err)) {
        .failed => |code| return code,
        .ready => |ready| ready,
    };
    defer setup.deinit(alloc);

    var dirs = switch (try resolveDirs(alloc, env, err)) {
        .failed => |code| return code,
        .ready => |ready| ready,
    };
    defer dirs.deinit(alloc);

    var snap: snapshot.Snapshot = undefined;
    var chosen_path: []const u8 = undefined;
    var latest_path: ?[]u8 = null;
    defer if (latest_path) |path| alloc.free(path);

    if (preloaded) |value| {
        snap = value;
        preloaded = null;
        chosen_path = preloaded_path.?;
    } else {
        const latest = snapshot.latestPath(
            alloc,
            io,
            dirs.snapshot,
            setup.fingerprint.serial,
            &load_diagnostic,
        ) catch |lookup_err| switch (lookup_err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try report.printError(
                    err,
                    load_diagnostic.message orelse "could not look up the latest snapshot",
                );
                return 1;
            },
        };
        const found = latest orelse {
            try report.printError(
                err,
                "no snapshot found for this device; run 'reclaim apply <profile> --yes' first",
            );
            return 1;
        };
        latest_path = found;
        chosen_path = found;
        snap = snapshot.load(alloc, io, found, &load_diagnostic) catch |load_err| switch (load_err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try report.printError(
                    err,
                    load_diagnostic.message orelse "could not read the latest snapshot",
                );
                return 1;
            },
        };
    }
    defer snap.deinit(alloc);

    var diagnostic: apply.Diagnostic = .{};
    defer diagnostic.deinit(alloc);

    var outcome = apply.revert(
        alloc,
        io,
        setup.adb_path,
        setup.fingerprint,
        snap,
        chosen_path,
        .{ .yes = yes },
        .{ .snapshot_dir = dirs.snapshot, .log_dir = dirs.log },
        &diagnostic,
    ) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return reportApplyError(err, failure, diagnostic),
    };
    defer outcome.deinit(alloc);

    if (global.json) {
        try report.printRevertJson(alloc, out, outcome);
    } else {
        try report.printRevert(out, outcome);
    }
    return outcomeCode(outcome);
}

fn reportApplyError(
    err: *std.Io.Writer,
    failure: apply.Error,
    diagnostic: apply.Diagnostic,
) !u8 {
    const message = diagnostic.message orelse switch (failure) {
        error.BlockedByDenylist => "refusing to apply a blocked step",
        error.UnknownSelection => "unknown step id selected",
        error.SnapshotMismatch => "the snapshot was taken on a different device",
        error.InvalidTarget => "a step target is invalid",
        error.SnapshotWriteFailed => "could not write the snapshot",
        error.LogFailed => "could not write the log",
        error.AdbFailed => "could not execute the batch on the device",
        error.OutOfMemory => "out of memory",
    };
    try report.printError(err, message);
    return switch (failure) {
        error.BlockedByDenylist => 6,
        error.UnknownSelection => 2,
        else => 1,
    };
}

fn outcomeCode(outcome: apply.Outcome) u8 {
    return if (outcome.count(.failed) > 0) 5 else 0;
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
