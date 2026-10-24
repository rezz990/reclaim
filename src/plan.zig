//! Builds the read-only plan for a profile: filters steps by SDK and RAM,
//! applies the denylist, and reads current values through adb.shell. Nothing
//! in this module changes device state.

const std = @import("std");
const adb = @import("adb.zig");
const denylist = @import("denylist.zig");
const device = @import("device.zig");
const profile = @import("profile.zig");

const Allocator = std.mem.Allocator;

pub const Status = enum {
    apply,
    skip,
    blocked,

    pub fn label(status: Status) []const u8 {
        return switch (status) {
            .apply => "apply",
            .skip => "skip",
            .blocked => "blocked",
        };
    }
};

pub const CurrentState = enum {
    value,
    unset,
    not_tracked,

    pub fn label(state: CurrentState) []const u8 {
        return switch (state) {
            .value => "value",
            .unset => "unset",
            .not_tracked => "not_tracked",
        };
    }
};

pub const Current = struct {
    state: CurrentState = .not_tracked,
    value: ?[]const u8 = null,

    pub fn deinit(current: *const Current, alloc: Allocator) void {
        if (current.value) |value| alloc.free(value);
    }

    pub fn describe(current: Current) []const u8 {
        return switch (current.state) {
            .value => current.value orelse "",
            .unset => "(unset)",
            .not_tracked => "(not tracked)",
        };
    }
};

pub const Step = struct {
    id: []const u8,
    kind: profile.Kind,
    risk: profile.Risk,
    target: []const u8,
    desired: ?[]const u8 = null,
    current: Current = .{},
    status: Status = .apply,
    reason: ?[]const u8 = null,
    changed: bool = true,

    pub fn deinit(step: *const Step, alloc: Allocator) void {
        alloc.free(step.id);
        alloc.free(step.target);
        if (step.desired) |desired| alloc.free(desired);
        if (step.reason) |reason| alloc.free(reason);
        step.current.deinit(alloc);
    }
};

pub const Plan = struct {
    profile: []const u8,
    serial: []const u8,
    sdk: ?u32,
    ram_total_mb: ?u64,
    steps: []Step,

    pub fn deinit(plan: *Plan, alloc: Allocator) void {
        alloc.free(plan.profile);
        alloc.free(plan.serial);
        for (plan.steps) |*step| step.deinit(alloc);
        alloc.free(plan.steps);
        plan.* = undefined;
    }

    pub fn count(plan: Plan, status: Status) usize {
        var total: usize = 0;
        for (plan.steps) |step| {
            if (step.status == status) total += 1;
        }
        return total;
    }
};

pub fn build(
    alloc: Allocator,
    adb_path: adb.AdbPath,
    fingerprint: device.Fingerprint,
    loaded: profile.Profile,
) Allocator.Error!Plan {
    const profile_copy = try alloc.dupe(u8, loaded.name);
    errdefer alloc.free(profile_copy);
    const serial_copy = try alloc.dupe(u8, fingerprint.serial);
    errdefer alloc.free(serial_copy);

    const gate_reason = try profileGateReason(alloc, loaded.requires, fingerprint);
    defer if (gate_reason) |reason| alloc.free(reason);

    var dynamic: denylist.Dynamic = .{};
    defer dynamic.deinit(alloc);
    var dynamic_failed = false;
    if (gate_reason == null and hasPackageStep(loaded)) {
        dynamic = denylist.readDynamic(alloc, adb_path, fingerprint.serial) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                dynamic_failed = true;
                break :blk .{};
            },
        };
    }

    var steps: std.ArrayList(Step) = .empty;
    errdefer {
        for (steps.items) |*step| step.deinit(alloc);
        steps.deinit(alloc);
    }

    for (loaded.steps) |source| {
        var step = try makeStep(alloc, source);
        steps.append(alloc, step) catch |err| {
            step.deinit(alloc);
            return err;
        };
        const built = &steps.items[steps.items.len - 1];

        if (gate_reason) |reason| {
            built.status = .skip;
            built.reason = try alloc.dupe(u8, reason);
            continue;
        }

        if (try stepGateReason(alloc, fingerprint.sdk, source)) |reason| {
            built.status = .skip;
            built.reason = reason;
            continue;
        }

        if (stepPackage(source)) |package| {
            if (denylist.check(package, dynamic)) |block| {
                built.status = .blocked;
                built.reason = try blockedReason(alloc, package, block);
                continue;
            }
            if (dynamic_failed) {
                built.status = .blocked;
                built.reason = try alloc.dupe(u8, "the dynamic denylist could not be read");
                continue;
            }
        }

        const current = readCurrent(alloc, adb_path, fingerprint.serial, source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                built.status = .skip;
                built.reason = try alloc.dupe(u8, "could not read the current value");
                continue;
            },
        };
        built.current = current;
        built.changed = isChanged(built.current, built.desired);
    }

    return .{
        .profile = profile_copy,
        .serial = serial_copy,
        .sdk = fingerprint.sdk,
        .ram_total_mb = fingerprint.ram_total_mb,
        .steps = try steps.toOwnedSlice(alloc),
    };
}

fn makeStep(alloc: Allocator, source: profile.Step) Allocator.Error!Step {
    const id = try alloc.dupe(u8, source.id);
    errdefer alloc.free(id);
    const target = try buildTarget(alloc, source);
    errdefer alloc.free(target);
    const desired = try buildDesired(alloc, source);
    return .{
        .id = id,
        .kind = source.kind(),
        .risk = source.risk,
        .target = target,
        .desired = desired,
    };
}

fn buildTarget(alloc: Allocator, source: profile.Step) Allocator.Error![]const u8 {
    return switch (source.target) {
        .setting => |target| std.fmt.allocPrint(
            alloc,
            "{s}/{s}",
            .{ target.namespace, target.key },
        ),
        .device_config => |target| std.fmt.allocPrint(
            alloc,
            "{s}/{s}",
            .{ target.namespace, target.key },
        ),
        .compile => |target| std.fmt.allocPrint(
            alloc,
            "compile {s} ({s})",
            .{ target.mode, target.scope },
        ),
        .appops => |target| std.fmt.allocPrint(
            alloc,
            "{s} {s}",
            .{ target.package, target.op },
        ),
        .standby_bucket => |target| alloc.dupe(u8, target.package),
        .wm => |target| std.fmt.allocPrint(alloc, "wm {s}", .{target.key.label()}),
        .package => |target| alloc.dupe(u8, target.package),
        .maintenance => alloc.dupe(u8, "idle maintenance"),
    };
}

fn buildDesired(alloc: Allocator, source: profile.Step) Allocator.Error!?[]const u8 {
    return switch (source.target) {
        .setting => |target| try alloc.dupe(u8, target.value),
        .device_config => |target| try alloc.dupe(u8, target.value),
        .compile, .maintenance => null,
        .appops => |target| try alloc.dupe(u8, target.mode),
        .standby_bucket => |target| try alloc.dupe(u8, target.bucket.label()),
        .wm => |target| try alloc.dupe(u8, target.value),
        .package => |target| try alloc.dupe(u8, target.action.label()),
    };
}

fn profileGateReason(
    alloc: Allocator,
    requires: profile.Requires,
    fingerprint: device.Fingerprint,
) Allocator.Error!?[]const u8 {
    if (requires.min_sdk) |minimum| {
        if (fingerprint.sdk) |sdk| {
            if (sdk < minimum) {
                return try std.fmt.allocPrint(
                    alloc,
                    "profile requires SDK >= {d} (device is {d})",
                    .{ minimum, sdk },
                );
            }
        } else {
            return try std.fmt.allocPrint(
                alloc,
                "profile requires SDK >= {d}, but the SDK level is unknown",
                .{minimum},
            );
        }
    }

    if (requires.max_sdk) |maximum| {
        if (fingerprint.sdk) |sdk| {
            if (sdk > maximum) {
                return try std.fmt.allocPrint(
                    alloc,
                    "profile requires SDK <= {d} (device is {d})",
                    .{ maximum, sdk },
                );
            }
        } else {
            return try std.fmt.allocPrint(
                alloc,
                "profile requires SDK <= {d}, but the SDK level is unknown",
                .{maximum},
            );
        }
    }

    if (requires.max_ram_mb) |maximum| {
        if (fingerprint.ram_total_mb) |ram| {
            if (ram > maximum) {
                return try std.fmt.allocPrint(
                    alloc,
                    "profile requires RAM <= {d} MB (device has {d} MB)",
                    .{ maximum, ram },
                );
            }
        } else {
            return try std.fmt.allocPrint(
                alloc,
                "profile requires RAM <= {d} MB, but the RAM total is unknown",
                .{maximum},
            );
        }
    }

    return null;
}

fn stepGateReason(
    alloc: Allocator,
    sdk: ?u32,
    source: profile.Step,
) Allocator.Error!?[]const u8 {
    if (source.min_sdk) |minimum| {
        if (sdk) |level| {
            if (level < minimum) {
                return try std.fmt.allocPrint(
                    alloc,
                    "requires SDK >= {d} (device is {d})",
                    .{ minimum, level },
                );
            }
        } else {
            return try std.fmt.allocPrint(
                alloc,
                "requires SDK >= {d}, but the SDK level is unknown",
                .{minimum},
            );
        }
    }

    if (source.max_sdk) |maximum| {
        if (sdk) |level| {
            if (level > maximum) {
                return try std.fmt.allocPrint(
                    alloc,
                    "requires SDK <= {d} (device is {d})",
                    .{ maximum, level },
                );
            }
        } else {
            return try std.fmt.allocPrint(
                alloc,
                "requires SDK <= {d}, but the SDK level is unknown",
                .{maximum},
            );
        }
    }

    return null;
}

fn hasPackageStep(loaded: profile.Profile) bool {
    for (loaded.steps) |step| {
        if (stepPackage(step) != null) return true;
    }
    return false;
}

fn stepPackage(step: profile.Step) ?[]const u8 {
    return switch (step.target) {
        .appops => |target| target.package,
        .standby_bucket => |target| target.package,
        .package => |target| target.package,
        else => null,
    };
}

fn blockedReason(alloc: Allocator, package: []const u8, block: denylist.Block) Allocator.Error![]const u8 {
    return switch (block) {
        .static => std.fmt.allocPrint(
            alloc,
            "package '{s}' is on the static denylist",
            .{package},
        ),
        .role => |role| std.fmt.allocPrint(
            alloc,
            "package '{s}' is the {s}",
            .{ package, role.label() },
        ),
    };
}

fn isChanged(current: Current, desired: ?[]const u8) bool {
    const wanted = desired orelse return true;
    if (current.state != .value) return true;
    const value = current.value orelse return true;
    return !std.mem.eql(u8, value, wanted);
}

fn readCurrent(
    alloc: Allocator,
    adb_path: adb.AdbPath,
    serial: []const u8,
    source: profile.Step,
) adb.Error!Current {
    return switch (source.target) {
        .setting => |target| readSetting(alloc, adb_path, serial, target.namespace, target.key),
        .device_config => |target| readDeviceConfig(
            alloc,
            adb_path,
            serial,
            target.namespace,
            target.key,
        ),
        .compile, .maintenance => .{ .state = .not_tracked },
        .appops => |target| readAppOps(alloc, adb_path, serial, target.package, target.op),
        .standby_bucket => |target| readBucket(alloc, adb_path, serial, target.package),
        .wm => |target| readWm(alloc, adb_path, serial, target.key),
        .package => |target| readPackage(alloc, adb_path, serial, target.package, target.action),
    };
}

fn runShell(
    alloc: Allocator,
    adb_path: adb.AdbPath,
    serial: []const u8,
    command: []const u8,
) adb.Error![]u8 {
    var result = try adb.shell(alloc, adb_path, serial, command);
    defer result.deinit(alloc);
    if (result.timed_out) return error.AdbFailed;
    if ((result.exit_code orelse return error.AdbFailed) != 0) return error.AdbFailed;
    return alloc.dupe(u8, result.stdout);
}

fn readSetting(
    alloc: Allocator,
    adb_path: adb.AdbPath,
    serial: []const u8,
    namespace: []const u8,
    key: []const u8,
) adb.Error!Current {
    const command = try std.fmt.allocPrint(alloc, "settings get {s} {s}", .{ namespace, key });
    defer alloc.free(command);
    const output = try runShell(alloc, adb_path, serial, command);
    defer alloc.free(output);
    return parseSettingOutput(alloc, output);
}

fn readDeviceConfig(
    alloc: Allocator,
    adb_path: adb.AdbPath,
    serial: []const u8,
    namespace: []const u8,
    key: []const u8,
) adb.Error!Current {
    const command = try std.fmt.allocPrint(alloc, "device_config get {s} {s}", .{ namespace, key });
    defer alloc.free(command);
    const output = try runShell(alloc, adb_path, serial, command);
    defer alloc.free(output);
    return parseSettingOutput(alloc, output);
}

fn readAppOps(
    alloc: Allocator,
    adb_path: adb.AdbPath,
    serial: []const u8,
    package: []const u8,
    op: []const u8,
) adb.Error!Current {
    const command = try std.fmt.allocPrint(alloc, "cmd appops get {s} {s}", .{ package, op });
    defer alloc.free(command);
    const output = try runShell(alloc, adb_path, serial, command);
    defer alloc.free(output);
    return parseAppOpsOutput(alloc, output, op);
}

fn readBucket(
    alloc: Allocator,
    adb_path: adb.AdbPath,
    serial: []const u8,
    package: []const u8,
) adb.Error!Current {
    const command = try std.fmt.allocPrint(alloc, "am get-standby-bucket {s}", .{package});
    defer alloc.free(command);
    const output = try runShell(alloc, adb_path, serial, command);
    defer alloc.free(output);
    return (try parseBucketOutput(alloc, output)) orelse error.AdbFailed;
}

fn readWm(
    alloc: Allocator,
    adb_path: adb.AdbPath,
    serial: []const u8,
    key: profile.WmKey,
) adb.Error!Current {
    const command = try std.fmt.allocPrint(alloc, "wm {s}", .{key.label()});
    defer alloc.free(command);
    const output = try runShell(alloc, adb_path, serial, command);
    defer alloc.free(output);
    return (try parseWmOutput(alloc, output, key)) orelse error.AdbFailed;
}

fn readPackage(
    alloc: Allocator,
    adb_path: adb.AdbPath,
    serial: []const u8,
    package: []const u8,
    action: profile.PackageAction,
) adb.Error!Current {
    const installed = try packageListed(
        alloc,
        adb_path,
        serial,
        "pm list packages --user 0",
        package,
    );
    switch (action) {
        .uninstall_user => return currentLiteral(
            alloc,
            if (installed) "installed" else "not installed",
        ),
        .disable => {
            if (!installed) return currentLiteral(alloc, "not installed");
            const disabled = try packageListed(
                alloc,
                adb_path,
                serial,
                "pm list packages -d --user 0",
                package,
            );
            return currentLiteral(alloc, if (disabled) "disabled" else "enabled");
        },
    }
}

fn packageListed(
    alloc: Allocator,
    adb_path: adb.AdbPath,
    serial: []const u8,
    prefix: []const u8,
    package: []const u8,
) adb.Error!bool {
    const command = try std.fmt.allocPrint(alloc, "{s} {s}", .{ prefix, package });
    defer alloc.free(command);
    const output = try runShell(alloc, adb_path, serial, command);
    defer alloc.free(output);
    return parsePackageList(output, package);
}

fn currentLiteral(alloc: Allocator, text: []const u8) Allocator.Error!Current {
    return .{ .state = .value, .value = try alloc.dupe(u8, text) };
}

pub fn parseSettingOutput(alloc: Allocator, text: []const u8) Allocator.Error!Current {
    const value = firstLine(text);
    if (value.len == 0 or std.mem.eql(u8, value, "null")) return .{ .state = .unset };
    return .{ .state = .value, .value = try alloc.dupe(u8, value) };
}

pub fn parseAppOpsOutput(
    alloc: Allocator,
    text: []const u8,
    op: []const u8,
) Allocator.Error!Current {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const position = std.mem.indexOf(u8, line, op) orelse continue;
        if (position > 0 and
            !std.ascii.isWhitespace(line[position - 1]) and
            line[position - 1] != ':')
        {
            continue;
        }
        const after = position + op.len;
        if (after >= line.len or line[after] != ':') continue;

        var value = std.mem.trim(u8, line[after + 1 ..], " \t");
        if (std.mem.indexOfScalar(u8, value, ';')) |semicolon| {
            value = std.mem.trim(u8, value[0..semicolon], " \t");
        }
        if (value.len == 0) return .{ .state = .unset };
        return .{ .state = .value, .value = try alloc.dupe(u8, value) };
    }
    return .{ .state = .unset };
}

pub fn parseBucketOutput(alloc: Allocator, text: []const u8) Allocator.Error!?Current {
    const value = firstLine(text);
    if (value.len == 0) return null;

    const number = std.fmt.parseInt(u32, value, 10) catch null;
    if (number) |bucket| {
        const name = bucketName(bucket);
        return .{
            .state = .value,
            .value = if (name) |known|
                try alloc.dupe(u8, known)
            else
                try std.fmt.allocPrint(alloc, "bucket {d}", .{bucket}),
        };
    }

    if (isBucketName(value)) {
        return .{ .state = .value, .value = try alloc.dupe(u8, value) };
    }
    return null;
}

pub fn parseWmOutput(
    alloc: Allocator,
    text: []const u8,
    key: profile.WmKey,
) Allocator.Error!?Current {
    const override_prefix = switch (key) {
        .density => "Override density:",
        .size => "Override size:",
    };
    const physical_prefix = switch (key) {
        .density => "Physical density:",
        .size => "Physical size:",
    };

    if (findAfterPrefix(text, override_prefix)) |value| {
        return .{ .state = .value, .value = try alloc.dupe(u8, value) };
    }
    if (findAfterPrefix(text, physical_prefix)) |value| {
        return .{
            .state = .value,
            .value = try std.fmt.allocPrint(alloc, "physical {s}", .{value}),
        };
    }
    return null;
}

pub fn parsePackageList(text: []const u8, package: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "package:")) continue;
        const name = std.mem.trim(u8, line["package:".len..], " \t\r");
        if (std.mem.eql(u8, name, package)) return true;
    }
    return false;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t\r");
}

fn findAfterPrefix(text: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const value = std.mem.trim(u8, line[prefix.len..], " \t");
        if (value.len == 0) continue;
        return value;
    }
    return null;
}

fn bucketName(bucket: u32) ?[]const u8 {
    return switch (bucket) {
        10 => "active",
        20 => "working_set",
        30 => "frequent",
        40 => "rare",
        45 => "restricted",
        50 => "never",
        else => null,
    };
}

fn isBucketName(text: []const u8) bool {
    const names = [_][]const u8{
        "active", "working_set", "frequent", "rare", "restricted", "never",
    };
    for (names) |name| {
        if (std.mem.eql(u8, text, name)) return true;
    }
    return false;
}

const testing = std.testing;

test "status and state labels stay stable" {
    try testing.expectEqualStrings("apply", Status.apply.label());
    try testing.expectEqualStrings("blocked", Status.blocked.label());
    try testing.expectEqualStrings("value", CurrentState.value.label());
    try testing.expectEqualStrings("not_tracked", CurrentState.not_tracked.label());
}

test "current values describe themselves" {
    const value: Current = .{ .state = .value, .value = "1.0" };
    try testing.expectEqualStrings("1.0", value.describe());
    try testing.expectEqualStrings("(unset)", (Current{ .state = .unset }).describe());
    try testing.expectEqualStrings("(not tracked)", (Current{}).describe());
}

test "parseSettingOutput handles values, null, and empty output" {
    const alloc = testing.allocator;

    var value = try parseSettingOutput(alloc, "1.0\n");
    defer value.deinit(alloc);
    try testing.expectEqual(CurrentState.value, value.state);
    try testing.expectEqualStrings("1.0", value.value.?);

    var padded = try parseSettingOutput(alloc, "  0.5  \r\n");
    defer padded.deinit(alloc);
    try testing.expectEqualStrings("0.5", padded.value.?);

    try testing.expectEqual(CurrentState.unset, (try parseSettingOutput(alloc, "null\n")).state);
    try testing.expectEqual(CurrentState.unset, (try parseSettingOutput(alloc, "")).state);
}

test "parseAppOpsOutput reads the mode and ignores noise" {
    const alloc = testing.allocator;

    var mode = try parseAppOpsOutput(alloc, "RUN_IN_BACKGROUND: ignore\n", "RUN_IN_BACKGROUND");
    defer mode.deinit(alloc);
    try testing.expectEqualStrings("ignore", mode.value.?);

    var timed = try parseAppOpsOutput(
        alloc,
        "Uid mode: RUN_IN_BACKGROUND: default; time=+1s\n",
        "RUN_IN_BACKGROUND",
    );
    defer timed.deinit(alloc);
    try testing.expectEqualStrings("default", timed.value.?);

    try testing.expectEqual(
        CurrentState.unset,
        (try parseAppOpsOutput(alloc, "No operations.\n", "RUN_IN_BACKGROUND")).state,
    );
    try testing.expectEqual(
        CurrentState.unset,
        (try parseAppOpsOutput(alloc, "OTHER_OP: ignore\n", "RUN_IN_BACKGROUND")).state,
    );
}

test "parseBucketOutput maps Android bucket numbers" {
    const alloc = testing.allocator;

    var active = (try parseBucketOutput(alloc, "10\n")).?;
    defer active.deinit(alloc);
    try testing.expectEqualStrings("active", active.value.?);

    var restricted = (try parseBucketOutput(alloc, "45\n")).?;
    defer restricted.deinit(alloc);
    try testing.expectEqualStrings("restricted", restricted.value.?);

    var unknown = (try parseBucketOutput(alloc, "33\n")).?;
    defer unknown.deinit(alloc);
    try testing.expectEqualStrings("bucket 33", unknown.value.?);

    var named = (try parseBucketOutput(alloc, "frequent\n")).?;
    defer named.deinit(alloc);
    try testing.expectEqualStrings("frequent", named.value.?);

    try testing.expect((try parseBucketOutput(alloc, "")) == null);
    try testing.expect((try parseBucketOutput(alloc, "Error: package not found\n")) == null);
}

test "parseWmOutput prefers overrides over physical values" {
    const alloc = testing.allocator;

    var density = (try parseWmOutput(
        alloc,
        "Physical density: 420\nOverride density: 480\n",
        .density,
    )).?;
    defer density.deinit(alloc);
    try testing.expectEqualStrings("480", density.value.?);

    var physical_density = (try parseWmOutput(alloc, "Physical density: 420\n", .density)).?;
    defer physical_density.deinit(alloc);
    try testing.expectEqualStrings("physical 420", physical_density.value.?);

    var size = (try parseWmOutput(
        alloc,
        "Physical size: 1080x1920\nOverride size: 720x1280\n",
        .size,
    )).?;
    defer size.deinit(alloc);
    try testing.expectEqualStrings("720x1280", size.value.?);

    var physical_size = (try parseWmOutput(alloc, "Physical size: 1080x1920\n", .size)).?;
    defer physical_size.deinit(alloc);
    try testing.expectEqualStrings("physical 1080x1920", physical_size.value.?);

    try testing.expect((try parseWmOutput(alloc, "garbage\n", .density)) == null);
}

test "parsePackageList matches the exact package" {
    const text =
        "package:com.example.app\n" ++
        "package:com.example.application\n";
    try testing.expect(parsePackageList(text, "com.example.app"));
    try testing.expect(!parsePackageList(text, "com.example"));
    try testing.expect(!parsePackageList("", "com.example.app"));
}

test "build skips every step when the profile RAM gate fails" {
    const alloc = testing.allocator;
    var diagnostic: profile.Diagnostic = .{};
    defer diagnostic.deinit(alloc);
    var loaded = try profile.load(alloc, testing.io, "light", &diagnostic);
    defer loaded.deinit(alloc);

    const fingerprint: device.Fingerprint = .{
        .serial = "FAKE123",
        .sdk = 29,
        .ram_total_mb = 3800,
    };
    var built = try build(
        alloc,
        .{ .path = "definitely-missing-adb", .io = testing.io },
        fingerprint,
        loaded,
    );
    defer built.deinit(alloc);

    try testing.expectEqual(@as(usize, 5), built.steps.len);
    try testing.expectEqual(@as(usize, 0), built.count(.apply));
    try testing.expectEqual(@as(usize, 5), built.count(.skip));
    for (built.steps) |step| {
        try testing.expect(std.mem.indexOf(u8, step.reason.?, "RAM <= 3072 MB") != null);
        try testing.expect(std.mem.indexOf(u8, step.reason.?, "3800") != null);
    }
}

test "build skips steps that need a newer SDK" {
    const alloc = testing.allocator;
    const steps = [_]profile.Step{
        .{
            .id = "phantom",
            .risk = .caution,
            .min_sdk = 31,
            .target = .{ .device_config = .{
                .namespace = "activity_manager",
                .key = "max_phantom_processes",
                .value = "2147483647",
            } },
        },
    };
    const loaded: profile.Profile = .{ .name = "custom", .steps = &steps };

    var built = try build(
        alloc,
        .{ .path = "definitely-missing-adb", .io = testing.io },
        .{ .serial = "FAKE123", .sdk = 29, .ram_total_mb = 3000 },
        loaded,
    );
    defer built.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), built.steps.len);
    try testing.expectEqual(Status.skip, built.steps[0].status);
    try testing.expectEqualStrings(
        "requires SDK >= 31 (device is 29)",
        built.steps[0].reason.?,
    );
}

test "build skips steps when the SDK or RAM is unknown" {
    const alloc = testing.allocator;
    const steps = [_]profile.Step{
        .{
            .id = "m",
            .risk = .safe,
            .min_sdk = 23,
            .target = .maintenance,
        },
    };
    const loaded: profile.Profile = .{
        .name = "custom",
        .requires = .{ .max_ram_mb = 3072 },
        .steps = &steps,
    };

    var built = try build(
        alloc,
        .{ .path = "definitely-missing-adb", .io = testing.io },
        .{ .serial = "FAKE123" },
        loaded,
    );
    defer built.deinit(alloc);

    try testing.expectEqual(Status.skip, built.steps[0].status);
    try testing.expect(std.mem.indexOf(u8, built.steps[0].reason.?, "RAM total is unknown") != null);
}

test "build blocks statically denied packages even without a device" {
    const alloc = testing.allocator;
    const steps = [_]profile.Step{
        .{
            .id = "disable-systemui",
            .risk = .dangerous,
            .target = .{ .package = .{
                .package = "com.android.systemui",
                .action = .disable,
            } },
        },
    };
    const loaded: profile.Profile = .{ .name = "custom", .steps = &steps };

    var built = try build(
        alloc,
        .{ .path = "definitely-missing-adb", .io = testing.io },
        .{ .serial = "FAKE123", .sdk = 29, .ram_total_mb = 3000 },
        loaded,
    );
    defer built.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), built.steps.len);
    try testing.expectEqual(Status.blocked, built.steps[0].status);
    try testing.expectEqualStrings(
        "package 'com.android.systemui' is on the static denylist",
        built.steps[0].reason.?,
    );
    try testing.expectEqual(@as(usize, 1), built.count(.blocked));
}

test "build fails closed when the dynamic denylist cannot be read" {
    const alloc = testing.allocator;
    const steps = [_]profile.Step{
        .{
            .id = "disable-app",
            .risk = .caution,
            .target = .{ .package = .{
                .package = "com.example.app",
                .action = .disable,
            } },
        },
    };
    const loaded: profile.Profile = .{ .name = "custom", .steps = &steps };

    var built = try build(
        alloc,
        .{ .path = "definitely-missing-adb", .io = testing.io },
        .{ .serial = "FAKE123", .sdk = 29, .ram_total_mb = 3000 },
        loaded,
    );
    defer built.deinit(alloc);

    try testing.expectEqual(Status.blocked, built.steps[0].status);
    try testing.expectEqualStrings(
        "the dynamic denylist could not be read",
        built.steps[0].reason.?,
    );
}

test "build degrades to a skip when a current value cannot be read" {
    const alloc = testing.allocator;
    const steps = [_]profile.Step{
        .{
            .id = "anim-window",
            .risk = .safe,
            .target = .{ .setting = .{
                .namespace = "global",
                .key = "window_animation_scale",
                .value = "0.5",
            } },
        },
    };
    const loaded: profile.Profile = .{ .name = "custom", .steps = &steps };

    var built = try build(
        alloc,
        .{ .path = "definitely-missing-adb", .io = testing.io },
        .{ .serial = "FAKE123", .sdk = 29, .ram_total_mb = 3000 },
        loaded,
    );
    defer built.deinit(alloc);

    try testing.expectEqual(Status.skip, built.steps[0].status);
    try testing.expectEqualStrings("could not read the current value", built.steps[0].reason.?);
}
