const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Error = error{
    AppDataNotSet,
    HomeNotSet,
    OutOfMemory,
};

pub fn configDir(alloc: Allocator, env: *const std.process.Environ.Map) Error![]u8 {
    return configDirFor(builtin.os.tag, alloc, env);
}

pub fn snapshotDir(alloc: Allocator, env: *const std.process.Environ.Map) Error![]u8 {
    return subdirFor(builtin.os.tag, alloc, env, "snapshots");
}

pub fn logDir(alloc: Allocator, env: *const std.process.Environ.Map) Error![]u8 {
    return subdirFor(builtin.os.tag, alloc, env, "logs");
}

fn subdirFor(
    os: std.Target.Os.Tag,
    alloc: Allocator,
    env: *const std.process.Environ.Map,
    name: []const u8,
) Error![]u8 {
    const base = try configDirFor(os, alloc, env);
    defer alloc.free(base);
    return std.fs.path.join(alloc, &.{ base, name });
}

fn configDirFor(
    os: std.Target.Os.Tag,
    alloc: Allocator,
    env: *const std.process.Environ.Map,
) Error![]u8 {
    switch (os) {
        .windows => {
            const appdata = env.get("APPDATA") orelse return error.AppDataNotSet;
            return std.fs.path.join(alloc, &.{ appdata, "reclaim" });
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            const home = env.get("HOME") orelse return error.HomeNotSet;
            return std.fs.path.join(alloc, &.{ home, "Library", "Application Support", "reclaim" });
        },
        else => {
            if (env.get("XDG_CONFIG_HOME")) |xdg| {
                if (xdg.len != 0) return std.fs.path.join(alloc, &.{ xdg, "reclaim" });
            }
            const home = env.get("HOME") orelse return error.HomeNotSet;
            return std.fs.path.join(alloc, &.{ home, ".config", "reclaim" });
        },
    }
}

const testing = std.testing;

fn testEnv(alloc: Allocator, entries: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(alloc);
    errdefer map.deinit();
    for (entries) |entry| try map.put(entry[0], entry[1]);
    return map;
}

test "windows stores everything under APPDATA" {
    var env = try testEnv(testing.allocator, &.{
        .{ "APPDATA", "C:\\Users\\raka\\AppData\\Roaming" },
    });
    defer env.deinit();
    const alloc = testing.allocator;

    const config = try configDirFor(.windows, alloc, &env);
    defer alloc.free(config);
    const expected_config = try std.fmt.allocPrint(
        alloc,
        "C:\\Users\\raka\\AppData\\Roaming{c}reclaim",
        .{std.fs.path.sep},
    );
    defer alloc.free(expected_config);
    try testing.expectEqualStrings(expected_config, config);

    const snapshots = try subdirFor(.windows, alloc, &env, "snapshots");
    defer alloc.free(snapshots);
    const expected_snapshots = try std.fmt.allocPrint(
        alloc,
        "C:\\Users\\raka\\AppData\\Roaming{c}reclaim{c}snapshots",
        .{ std.fs.path.sep, std.fs.path.sep },
    );
    defer alloc.free(expected_snapshots);
    try testing.expectEqualStrings(expected_snapshots, snapshots);

    const logs = try subdirFor(.windows, alloc, &env, "logs");
    defer alloc.free(logs);
    const expected_logs = try std.fmt.allocPrint(
        alloc,
        "C:\\Users\\raka\\AppData\\Roaming{c}reclaim{c}logs",
        .{ std.fs.path.sep, std.fs.path.sep },
    );
    defer alloc.free(expected_logs);
    try testing.expectEqualStrings(expected_logs, logs);
}

test "windows without APPDATA fails loudly" {
    var env = try testEnv(testing.allocator, &.{});
    defer env.deinit();

    try testing.expectError(error.AppDataNotSet, configDirFor(.windows, testing.allocator, &env));
}

test "linux prefers XDG_CONFIG_HOME" {
    var env = try testEnv(testing.allocator, &.{
        .{ "XDG_CONFIG_HOME", "/xdg" },
        .{ "HOME", "/home/raka" },
    });
    defer env.deinit();
    const alloc = testing.allocator;

    const config = try configDirFor(.linux, alloc, &env);
    defer alloc.free(config);
    const expected = try std.fmt.allocPrint(alloc, "/xdg{c}reclaim", .{std.fs.path.sep});
    defer alloc.free(expected);
    try testing.expectEqualStrings(expected, config);
}

test "linux falls back to HOME and empty XDG values are ignored" {
    var env = try testEnv(testing.allocator, &.{
        .{ "XDG_CONFIG_HOME", "" },
        .{ "HOME", "/home/raka" },
    });
    defer env.deinit();
    const alloc = testing.allocator;

    const config = try configDirFor(.linux, alloc, &env);
    defer alloc.free(config);
    const expected = try std.fmt.allocPrint(
        alloc,
        "/home/raka{c}.config{c}reclaim",
        .{ std.fs.path.sep, std.fs.path.sep },
    );
    defer alloc.free(expected);
    try testing.expectEqualStrings(expected, config);
}

test "linux without HOME fails loudly" {
    var env = try testEnv(testing.allocator, &.{});
    defer env.deinit();

    try testing.expectError(error.HomeNotSet, configDirFor(.linux, testing.allocator, &env));
}

test "macos uses Application Support" {
    var env = try testEnv(testing.allocator, &.{
        .{ "HOME", "/Users/raka" },
    });
    defer env.deinit();
    const alloc = testing.allocator;

    const config = try configDirFor(.macos, alloc, &env);
    defer alloc.free(config);
    const expected = try std.fmt.allocPrint(
        alloc,
        "/Users/raka{c}Library{c}Application Support{c}reclaim",
        .{ std.fs.path.sep, std.fs.path.sep, std.fs.path.sep },
    );
    defer alloc.free(expected);
    try testing.expectEqualStrings(expected, config);
}

test "public helpers follow the native OS layout" {
    var env = try testEnv(testing.allocator, &.{
        .{ "APPDATA", "C:\\Users\\raka\\AppData\\Roaming" },
        .{ "XDG_CONFIG_HOME", "/xdg" },
        .{ "HOME", "/home/raka" },
    });
    defer env.deinit();
    const alloc = testing.allocator;
    const sep = std.fs.path.sep;

    const expected_config = switch (builtin.os.tag) {
        .windows => try std.fmt.allocPrint(
            alloc,
            "C:\\Users\\raka\\AppData\\Roaming{c}reclaim",
            .{sep},
        ),
        .macos, .ios, .tvos, .watchos, .visionos => try std.fmt.allocPrint(
            alloc,
            "/home/raka{c}Library{c}Application Support{c}reclaim",
            .{ sep, sep, sep },
        ),
        else => try std.fmt.allocPrint(alloc, "/xdg{c}reclaim", .{sep}),
    };
    defer alloc.free(expected_config);

    const expected_snapshots = try std.fmt.allocPrint(alloc, "{s}{c}snapshots", .{ expected_config, sep });
    defer alloc.free(expected_snapshots);
    const expected_logs = try std.fmt.allocPrint(alloc, "{s}{c}logs", .{ expected_config, sep });
    defer alloc.free(expected_logs);

    const config = try configDir(alloc, &env);
    defer alloc.free(config);
    try testing.expectEqualStrings(expected_config, config);

    const snapshots = try snapshotDir(alloc, &env);
    defer alloc.free(snapshots);
    try testing.expectEqualStrings(expected_snapshots, snapshots);

    const logs = try logDir(alloc, &env);
    defer alloc.free(logs);
    try testing.expectEqualStrings(expected_logs, logs);
}
