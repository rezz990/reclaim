const std = @import("std");
const cli = @import("cli.zig");
const doctor = @import("doctor.zig");
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
    const result = try runForTest(&.{"scan"});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 1), result.code);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'scan' is not implemented") != null);
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
