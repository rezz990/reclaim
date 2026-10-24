const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version = "0.1.0";

pub const help_text =
    \\Reclaim — reclaim your old Android.
    \\
    \\Usage:
    \\  reclaim <command> [options]
    \\
    \\Commands:
    \\  scan                  Device info and profile recommendation
    \\  plan <profile>        Show the diff a profile would apply
    \\  apply <profile>       Apply a profile (dry-run unless --yes)
    \\  revert                Revert to the last snapshot
    \\  bench                 Measure device performance
    \\  debloat               List or apply debloat packages
    \\  watch                 Auto-apply a profile when a device connects
    \\  doctor                Diagnose adb, drivers, and authorization
    \\
    \\Command options:
    \\  scan, plan            --json
    \\  apply                 --yes, --skip <id> (repeatable), --only <id>
    \\  revert                --snapshot <file>, --yes
    \\  bench                 --pkg <package>, --runs <n> (default 5), --label <name>
    \\  debloat               --list, --risk <safe|caution>, --yes
    \\  watch                 --profile <name>, --yes
    \\  doctor                --json
    \\
    \\Global options:
    \\  -s, --serial <serial>  Target device serial (required with multiple devices)
    \\      --json             Machine-readable JSON output
    \\      --verbose          Verbose output
    \\      --adb <path>       Explicit path to the adb binary
    \\  -h, --help             Show this help
    \\      --version          Show version
    \\
    \\Exit codes:
    \\  0 success · 1 general error · 2 bad arguments · 3 adb not found
    \\  4 no device or unauthorized · 5 partial failure · 6 blocked by denylist
    \\
;

pub const Risk = enum { safe, caution };

pub const Command = union(enum) {
    scan,
    plan: struct {
        profile: []const u8,
    },
    apply: struct {
        profile: []const u8,
        yes: bool = false,
        skip: []const []const u8 = &.{},
        only: ?[]const u8 = null,
    },
    revert: struct {
        snapshot: ?[]const u8 = null,
        yes: bool = false,
    },
    bench: struct {
        pkg: ?[]const u8 = null,
        runs: usize = 5,
        label: ?[]const u8 = null,
    },
    debloat: struct {
        list: bool = false,
        risk: ?Risk = null,
        yes: bool = false,
    },
    watch: struct {
        profile: ?[]const u8 = null,
        yes: bool = false,
    },
    doctor,
};

pub const GlobalOptions = struct {
    serial: ?[]const u8 = null,
    json: bool = false,
    verbose: bool = false,
    adb_path: ?[]const u8 = null,
};

pub const App = struct {
    command: Command,
    global: GlobalOptions,
};

pub const Invocation = union(enum) {
    help,
    version,
    command: App,
};

pub const Failure = struct {
    kind: Kind,
    arg: ?[]const u8 = null,

    pub const Kind = enum {
        missing_command,
        unknown_command,
        unknown_flag,
        missing_value,
        invalid_value,
        missing_argument,
        unexpected_argument,
    };
};

pub const ParseResult = union(enum) {
    invocation: Invocation,
    failure: Failure,
};

pub const ParseError = error{
    MissingCommand,
    UnknownCommand,
    UnknownFlag,
    MissingValue,
    InvalidValue,
    MissingArgument,
    UnexpectedArgument,
    OutOfMemory,
};

/// Parses arguments after the program name. Failures are reported as data so the
/// caller can print a specific message and return exit code 2.
pub fn parse(alloc: Allocator, args: []const []const u8) Allocator.Error!ParseResult {
    for (args) |arg| {
        if (isHelp(arg)) return .{ .invocation = .help };
        if (std.mem.eql(u8, arg, "--version")) return .{ .invocation = .version };
    }

    var diag: Failure = undefined;
    const invocation = parseArgs(alloc, args, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = diag },
    };
    return .{ .invocation = invocation };
}

pub fn commandName(command: Command) []const u8 {
    return switch (command) {
        .scan => "scan",
        .plan => "plan",
        .apply => "apply",
        .revert => "revert",
        .bench => "bench",
        .debloat => "debloat",
        .watch => "watch",
        .doctor => "doctor",
    };
}

fn parseArgs(alloc: Allocator, args: []const []const u8, diag: *Failure) ParseError!Invocation {
    var p: Parser = .{ .alloc = alloc, .args = args, .diag = diag };

    while (try p.consumeGlobal()) {}
    const name = p.peek() orelse return fail(diag, .missing_command, null);
    if (isFlag(name)) return fail(diag, .unknown_flag, name);
    p.index += 1;

    const command: Command = if (std.mem.eql(u8, name, "scan"))
        try p.finishWith(.scan)
    else if (std.mem.eql(u8, name, "plan"))
        try parsePlan(&p)
    else if (std.mem.eql(u8, name, "apply"))
        try parseApply(&p)
    else if (std.mem.eql(u8, name, "revert"))
        try parseRevert(&p)
    else if (std.mem.eql(u8, name, "bench"))
        try parseBench(&p)
    else if (std.mem.eql(u8, name, "debloat"))
        try parseDebloat(&p)
    else if (std.mem.eql(u8, name, "watch"))
        try parseWatch(&p)
    else if (std.mem.eql(u8, name, "doctor"))
        try p.finishWith(.doctor)
    else
        return fail(diag, .unknown_command, name);

    return .{ .command = .{ .command = command, .global = p.global } };
}

fn parsePlan(p: *Parser) ParseError!Command {
    const profile = try p.positional("plan");
    try p.finish();
    return .{ .plan = .{ .profile = profile } };
}

fn parseApply(p: *Parser) ParseError!Command {
    var profile: ?[]const u8 = null;
    var yes = false;
    var only: ?[]const u8 = null;
    var skip: std.ArrayList([]const u8) = .empty;

    while (p.peek()) |arg| {
        if (try p.consumeGlobal()) continue;
        if (std.mem.eql(u8, arg, "--yes")) {
            yes = true;
            p.index += 1;
        } else if (std.mem.eql(u8, arg, "--skip")) {
            try skip.append(p.alloc, try p.flagValue());
        } else if (std.mem.eql(u8, arg, "--only")) {
            only = try p.flagValue();
        } else if (isFlag(arg)) {
            return fail(p.diag, .unknown_flag, arg);
        } else if (profile == null) {
            profile = arg;
            p.index += 1;
        } else {
            return fail(p.diag, .unexpected_argument, arg);
        }
    }

    const profile_value = profile orelse return fail(p.diag, .missing_argument, "apply");
    return .{ .apply = .{
        .profile = profile_value,
        .yes = yes,
        .skip = try skip.toOwnedSlice(p.alloc),
        .only = only,
    } };
}

fn parseRevert(p: *Parser) ParseError!Command {
    var snapshot: ?[]const u8 = null;
    var yes = false;

    while (p.peek()) |arg| {
        if (try p.consumeGlobal()) continue;
        if (std.mem.eql(u8, arg, "--yes")) {
            yes = true;
            p.index += 1;
        } else if (std.mem.eql(u8, arg, "--snapshot")) {
            snapshot = try p.flagValue();
        } else if (isFlag(arg)) {
            return fail(p.diag, .unknown_flag, arg);
        } else {
            return fail(p.diag, .unexpected_argument, arg);
        }
    }

    return .{ .revert = .{ .snapshot = snapshot, .yes = yes } };
}

fn parseBench(p: *Parser) ParseError!Command {
    var pkg: ?[]const u8 = null;
    var runs: usize = 5;
    var label: ?[]const u8 = null;

    while (p.peek()) |arg| {
        if (try p.consumeGlobal()) continue;
        if (std.mem.eql(u8, arg, "--pkg")) {
            pkg = try p.flagValue();
        } else if (std.mem.eql(u8, arg, "--runs")) {
            const raw = try p.flagValue();
            const value = std.fmt.parseInt(usize, raw, 10) catch
                return fail(p.diag, .invalid_value, arg);
            if (value == 0) return fail(p.diag, .invalid_value, arg);
            runs = value;
        } else if (std.mem.eql(u8, arg, "--label")) {
            label = try p.flagValue();
        } else if (isFlag(arg)) {
            return fail(p.diag, .unknown_flag, arg);
        } else {
            return fail(p.diag, .unexpected_argument, arg);
        }
    }

    return .{ .bench = .{ .pkg = pkg, .runs = runs, .label = label } };
}

fn parseDebloat(p: *Parser) ParseError!Command {
    var list = false;
    var risk: ?Risk = null;
    var yes = false;

    while (p.peek()) |arg| {
        if (try p.consumeGlobal()) continue;
        if (std.mem.eql(u8, arg, "--list")) {
            list = true;
            p.index += 1;
        } else if (std.mem.eql(u8, arg, "--risk")) {
            const raw = try p.flagValue();
            risk = parseRisk(raw) orelse return fail(p.diag, .invalid_value, arg);
        } else if (std.mem.eql(u8, arg, "--yes")) {
            yes = true;
            p.index += 1;
        } else if (isFlag(arg)) {
            return fail(p.diag, .unknown_flag, arg);
        } else {
            return fail(p.diag, .unexpected_argument, arg);
        }
    }

    return .{ .debloat = .{ .list = list, .risk = risk, .yes = yes } };
}

fn parseWatch(p: *Parser) ParseError!Command {
    var profile: ?[]const u8 = null;
    var yes = false;

    while (p.peek()) |arg| {
        if (try p.consumeGlobal()) continue;
        if (std.mem.eql(u8, arg, "--profile")) {
            profile = try p.flagValue();
        } else if (std.mem.eql(u8, arg, "--yes")) {
            yes = true;
            p.index += 1;
        } else if (isFlag(arg)) {
            return fail(p.diag, .unknown_flag, arg);
        } else {
            return fail(p.diag, .unexpected_argument, arg);
        }
    }

    return .{ .watch = .{ .profile = profile, .yes = yes } };
}

fn parseRisk(value: []const u8) ?Risk {
    if (std.mem.eql(u8, value, "safe")) return .safe;
    if (std.mem.eql(u8, value, "caution")) return .caution;
    return null;
}

fn fail(diag: *Failure, kind: Failure.Kind, arg: ?[]const u8) ParseError {
    diag.* = .{ .kind = kind, .arg = arg };
    return switch (kind) {
        .missing_command => error.MissingCommand,
        .unknown_command => error.UnknownCommand,
        .unknown_flag => error.UnknownFlag,
        .missing_value => error.MissingValue,
        .invalid_value => error.InvalidValue,
        .missing_argument => error.MissingArgument,
        .unexpected_argument => error.UnexpectedArgument,
    };
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn isFlag(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

const Parser = struct {
    alloc: Allocator,
    args: []const []const u8,
    index: usize = 0,
    global: GlobalOptions = .{},
    diag: *Failure,

    fn peek(p: *const Parser) ?[]const u8 {
        return if (p.index < p.args.len) p.args[p.index] else null;
    }

    fn consumeGlobal(p: *Parser) ParseError!bool {
        const arg = p.peek() orelse return false;
        if (std.mem.eql(u8, arg, "--json")) {
            p.global.json = true;
            p.index += 1;
            return true;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            p.global.verbose = true;
            p.index += 1;
            return true;
        }
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--serial")) {
            p.index += 1;
            p.global.serial = try p.valueAfter(arg);
            return true;
        }
        if (std.mem.eql(u8, arg, "--adb")) {
            p.index += 1;
            p.global.adb_path = try p.valueAfter(arg);
            return true;
        }
        return false;
    }

    fn flagValue(p: *Parser) ParseError![]const u8 {
        const flag = p.args[p.index];
        p.index += 1;
        return p.valueAfter(flag);
    }

    fn valueAfter(p: *Parser, flag: []const u8) ParseError![]const u8 {
        const value = p.peek() orelse return fail(p.diag, .missing_value, flag);
        p.index += 1;
        return value;
    }

    fn positional(p: *Parser, command: []const u8) ParseError![]const u8 {
        const arg = p.peek() orelse return fail(p.diag, .missing_argument, command);
        if (isFlag(arg)) return fail(p.diag, .missing_argument, command);
        p.index += 1;
        return arg;
    }

    fn finish(p: *Parser) ParseError!void {
        while (p.peek()) |arg| {
            if (try p.consumeGlobal()) continue;
            if (isFlag(arg)) return fail(p.diag, .unknown_flag, arg);
            return fail(p.diag, .unexpected_argument, arg);
        }
    }

    fn finishWith(p: *Parser, command: Command) ParseError!Command {
        try p.finish();
        return command;
    }
};

fn expectCommand(result: ParseResult) !App {
    return switch (result) {
        .invocation => |invocation| switch (invocation) {
            .command => |app| app,
            else => error.ExpectedCommand,
        },
        .failure => error.ExpectedCommand,
    };
}

fn expectFailure(result: ParseResult) !Failure {
    return switch (result) {
        .invocation => error.ExpectedFailure,
        .failure => |failure| failure,
    };
}

fn expectHelp(result: ParseResult) !void {
    switch (result) {
        .invocation => |invocation| switch (invocation) {
            .help => {},
            else => return error.ExpectedHelp,
        },
        .failure => return error.ExpectedHelp,
    }
}

test "help is recognized anywhere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cases: []const []const []const u8 = &.{
        &.{"--help"},
        &.{"-h"},
        &.{ "apply", "light", "--help" },
    };
    for (cases) |args| {
        const result = try parse(arena.allocator(), args);
        try expectHelp(result);
    }
}

test "version is recognized anywhere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cases: []const []const []const u8 = &.{
        &.{"--version"},
        &.{ "scan", "--version" },
    };
    for (cases) |args| {
        const result = try parse(arena.allocator(), args);
        switch (result) {
            .invocation => |invocation| switch (invocation) {
                .version => {},
                else => return error.ExpectedVersion,
            },
            .failure => return error.ExpectedVersion,
        }
    }
}

test "bare invocation misses a command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const failure = try expectFailure(try parse(arena.allocator(), &.{}));
    try std.testing.expectEqual(Failure.Kind.missing_command, failure.kind);
}

test "scan parses global flags around the command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const app = try expectCommand(try parse(
        arena.allocator(),
        &.{ "--json", "-s", "ABC123", "scan", "--verbose" },
    ));
    try std.testing.expect(std.meta.activeTag(app.command) == .scan);
    try std.testing.expect(app.global.json);
    try std.testing.expect(app.global.verbose);
    try std.testing.expectEqualStrings("ABC123", app.global.serial.?);
}

test "plan takes exactly one profile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const app = try expectCommand(try parse(alloc, &.{ "plan", "light", "--json" }));
    switch (app.command) {
        .plan => |plan| try std.testing.expectEqualStrings("light", plan.profile),
        else => return error.ExpectedPlan,
    }
    try std.testing.expect(app.global.json);

    const missing = try expectFailure(try parse(alloc, &.{"plan"}));
    try std.testing.expectEqual(Failure.Kind.missing_argument, missing.kind);
    try std.testing.expectEqualStrings("plan", missing.arg.?);

    const extra = try expectFailure(try parse(alloc, &.{ "plan", "light", "extra" }));
    try std.testing.expectEqual(Failure.Kind.unexpected_argument, extra.kind);
    try std.testing.expectEqualStrings("extra", extra.arg.?);
}

test "apply defaults to a dry run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const app = try expectCommand(try parse(arena.allocator(), &.{ "apply", "light" }));
    const apply = switch (app.command) {
        .apply => |apply| apply,
        else => return error.ExpectedApply,
    };
    try std.testing.expectEqualStrings("light", apply.profile);
    try std.testing.expect(!apply.yes);
    try std.testing.expectEqual(@as(usize, 0), apply.skip.len);
    try std.testing.expectEqual(@as(?[]const u8, null), apply.only);
}

test "apply parses yes, skip, and only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const app = try expectCommand(try parse(arena.allocator(), &.{
        "apply", "balanced", "--yes", "--skip", "dexopt", "--skip", "idle-maint", "--only", "anim-window",
    }));
    const apply = switch (app.command) {
        .apply => |apply| apply,
        else => return error.ExpectedApply,
    };
    try std.testing.expect(apply.yes);
    try std.testing.expectEqual(@as(usize, 2), apply.skip.len);
    try std.testing.expectEqualStrings("dexopt", apply.skip[0]);
    try std.testing.expectEqualStrings("idle-maint", apply.skip[1]);
    try std.testing.expectEqualStrings("anim-window", apply.only.?);
}

test "apply rejects unknown flags and extra profiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const unknown = try expectFailure(try parse(alloc, &.{ "apply", "light", "--force" }));
    try std.testing.expectEqual(Failure.Kind.unknown_flag, unknown.kind);
    try std.testing.expectEqualStrings("--force", unknown.arg.?);

    const extra = try expectFailure(try parse(alloc, &.{ "apply", "light", "balanced" }));
    try std.testing.expectEqual(Failure.Kind.unexpected_argument, extra.kind);
}

test "revert parses snapshot and confirmation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const app = try expectCommand(try parse(
        arena.allocator(),
        &.{ "revert", "--snapshot", "snap.json", "--yes" },
    ));
    const revert = switch (app.command) {
        .revert => |revert| revert,
        else => return error.ExpectedRevert,
    };
    try std.testing.expectEqualStrings("snap.json", revert.snapshot.?);
    try std.testing.expect(revert.yes);
}

test "bench has sane defaults and parses options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const defaults = try expectCommand(try parse(alloc, &.{"bench"}));
    const bench_default = switch (defaults.command) {
        .bench => |bench| bench,
        else => return error.ExpectedBench,
    };
    try std.testing.expectEqual(@as(usize, 5), bench_default.runs);
    try std.testing.expectEqual(@as(?[]const u8, null), bench_default.pkg);

    const app = try expectCommand(try parse(alloc, &.{
        "bench", "--pkg", "com.android.settings", "--runs", "7", "--label", "before",
    }));
    const bench = switch (app.command) {
        .bench => |bench| bench,
        else => return error.ExpectedBench,
    };
    try std.testing.expectEqualStrings("com.android.settings", bench.pkg.?);
    try std.testing.expectEqual(@as(usize, 7), bench.runs);
    try std.testing.expectEqualStrings("before", bench.label.?);
}

test "bench rejects invalid run counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const not_a_number = try expectFailure(try parse(alloc, &.{ "bench", "--runs", "many" }));
    try std.testing.expectEqual(Failure.Kind.invalid_value, not_a_number.kind);
    try std.testing.expectEqualStrings("--runs", not_a_number.arg.?);

    const zero = try expectFailure(try parse(alloc, &.{ "bench", "--runs", "0" }));
    try std.testing.expectEqual(Failure.Kind.invalid_value, zero.kind);

    const negative = try expectFailure(try parse(alloc, &.{ "bench", "--runs", "-3" }));
    try std.testing.expectEqual(Failure.Kind.invalid_value, negative.kind);
}

test "debloat parses risk levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const app = try expectCommand(try parse(alloc, &.{ "debloat", "--list", "--risk", "caution" }));
    const debloat = switch (app.command) {
        .debloat => |debloat| debloat,
        else => return error.ExpectedDebloat,
    };
    try std.testing.expect(debloat.list);
    try std.testing.expectEqual(Risk.caution, debloat.risk.?);

    const bad = try expectFailure(try parse(alloc, &.{ "debloat", "--risk", "dangerous" }));
    try std.testing.expectEqual(Failure.Kind.invalid_value, bad.kind);
    try std.testing.expectEqualStrings("--risk", bad.arg.?);
}

test "watch parses profile and confirmation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const app = try expectCommand(try parse(
        arena.allocator(),
        &.{ "watch", "--profile", "balanced", "--yes" },
    ));
    const watch = switch (app.command) {
        .watch => |watch| watch,
        else => return error.ExpectedWatch,
    };
    try std.testing.expectEqualStrings("balanced", watch.profile.?);
    try std.testing.expect(watch.yes);
}

test "doctor takes no positionals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const failure = try expectFailure(try parse(arena.allocator(), &.{ "doctor", "now" }));
    try std.testing.expectEqual(Failure.Kind.unexpected_argument, failure.kind);
    try std.testing.expectEqualStrings("now", failure.arg.?);
}

test "unknown commands are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const failure = try expectFailure(try parse(arena.allocator(), &.{"optimize"}));
    try std.testing.expectEqual(Failure.Kind.unknown_command, failure.kind);
    try std.testing.expectEqualStrings("optimize", failure.arg.?);
}

test "unknown flags are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const before_command = try expectFailure(try parse(alloc, &.{ "--fast", "scan" }));
    try std.testing.expectEqual(Failure.Kind.unknown_flag, before_command.kind);

    const after_command = try expectFailure(try parse(alloc, &.{ "scan", "--yes" }));
    try std.testing.expectEqual(Failure.Kind.unknown_flag, after_command.kind);
    try std.testing.expectEqualStrings("--yes", after_command.arg.?);
}

test "flags that need a value report when it is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const adb = try expectFailure(try parse(alloc, &.{"--adb"}));
    try std.testing.expectEqual(Failure.Kind.missing_value, adb.kind);
    try std.testing.expectEqualStrings("--adb", adb.arg.?);

    const skip = try expectFailure(try parse(alloc, &.{ "apply", "light", "--skip" }));
    try std.testing.expectEqual(Failure.Kind.missing_value, skip.kind);
    try std.testing.expectEqualStrings("--skip", skip.arg.?);
}

test "adb path is stored globally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const app = try expectCommand(try parse(
        arena.allocator(),
        &.{ "doctor", "--adb", "C:\\platform-tools\\adb.exe" },
    ));
    try std.testing.expectEqualStrings(
        "C:\\platform-tools\\adb.exe",
        app.global.adb_path.?,
    );
}

test "every command has a name" {
    try std.testing.expectEqualStrings("scan", commandName(.scan));
    try std.testing.expectEqualStrings("plan", commandName(.{ .plan = .{ .profile = "light" } }));
    try std.testing.expectEqualStrings("apply", commandName(.{ .apply = .{ .profile = "light" } }));
    try std.testing.expectEqualStrings("revert", commandName(.{ .revert = .{} }));
    try std.testing.expectEqualStrings("bench", commandName(.{ .bench = .{} }));
    try std.testing.expectEqualStrings("debloat", commandName(.{ .debloat = .{} }));
    try std.testing.expectEqualStrings("watch", commandName(.{ .watch = .{} }));
    try std.testing.expectEqualStrings("doctor", commandName(.doctor));
}
