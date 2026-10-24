//! Device fingerprint and profile recommendation for `reclaim scan`.
//! Read-only: every device access goes through adb.shell.

const std = @import("std");
const adb = @import("adb.zig");

const Allocator = std.mem.Allocator;

pub const Profile = enum {
    light,
    balanced,

    pub fn label(profile: Profile) []const u8 {
        return switch (profile) {
            .light => "light",
            .balanced => "balanced",
        };
    }
};

pub const Fingerprint = struct {
    serial: []const u8,
    sdk: ?u32 = null,
    release: ?[]const u8 = null,
    manufacturer: ?[]const u8 = null,
    model: ?[]const u8 = null,
    abi: ?[]const u8 = null,
    low_ram: ?bool = null,
    ram_total_mb: ?u64 = null,

    pub fn deinit(fingerprint: *Fingerprint, alloc: Allocator) void {
        alloc.free(fingerprint.serial);
        if (fingerprint.release) |value| alloc.free(value);
        if (fingerprint.manufacturer) |value| alloc.free(value);
        if (fingerprint.model) |value| alloc.free(value);
        if (fingerprint.abi) |value| alloc.free(value);
        fingerprint.* = undefined;
    }
};

pub const Recommendation = struct {
    profile: ?Profile = null,
    reason: []const u8,

    pub fn deinit(recommendation: *Recommendation, alloc: Allocator) void {
        alloc.free(recommendation.reason);
        recommendation.* = undefined;
    }
};

pub const SelectionError = error{
    NoDevices,
    MultipleDevices,
    SerialNotFound,
    DeviceNotReady,
};

/// Picks the device to work on. One attached device is selected automatically;
/// with more than one, `--serial` is required.
pub fn select(entries: []const adb.DeviceEntry, serial: ?[]const u8) SelectionError!adb.DeviceEntry {
    if (serial) |wanted| {
        for (entries) |entry| {
            if (!std.mem.eql(u8, entry.serial, wanted)) continue;
            if (entry.state != .device) return error.DeviceNotReady;
            return entry;
        }
        return error.SerialNotFound;
    }

    if (entries.len == 0) return error.NoDevices;
    if (entries.len > 1) return error.MultipleDevices;
    if (entries[0].state != .device) return error.DeviceNotReady;
    return entries[0];
}

pub fn probe(alloc: Allocator, adb_path: adb.AdbPath, serial: []const u8) adb.Error!Fingerprint {
    var properties = try adb.shell(alloc, adb_path, serial, "getprop");
    defer properties.deinit(alloc);
    if (properties.timed_out) return error.AdbFailed;
    if ((properties.exit_code orelse return error.AdbFailed) != 0) return error.AdbFailed;

    var meminfo = try adb.shell(alloc, adb_path, serial, "cat /proc/meminfo");
    defer meminfo.deinit(alloc);
    if (meminfo.timed_out) return error.AdbFailed;
    if ((meminfo.exit_code orelse return error.AdbFailed) != 0) return error.AdbFailed;

    return parseFingerprint(alloc, serial, properties.stdout, meminfo.stdout);
}

pub fn parseFingerprint(
    alloc: Allocator,
    serial: []const u8,
    getprop: []const u8,
    meminfo: []const u8,
) Allocator.Error!Fingerprint {
    var props = try parseGetprop(alloc, getprop);
    defer props.deinit(alloc);

    var fingerprint: Fingerprint = .{
        .serial = try alloc.dupe(u8, serial),
        .sdk = props.sdk,
        .ram_total_mb = parseMemTotal(meminfo),
    };
    fingerprint.release = props.release;
    props.release = null;
    fingerprint.manufacturer = props.manufacturer;
    props.manufacturer = null;
    fingerprint.model = props.model;
    props.model = null;
    fingerprint.abi = props.abi;
    props.abi = null;
    fingerprint.low_ram = props.low_ram;
    return fingerprint;
}

pub fn parseMemTotal(text: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "MemTotal:")) continue;

        const rest = std.mem.trim(u8, line["MemTotal:".len..], " \t");
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        if (end == 0) return null;
        const kilobytes = std.fmt.parseInt(u64, rest[0..end], 10) catch return null;
        if (kilobytes == 0) return null;
        return kilobytes / 1024;
    }
    return null;
}

pub fn recommend(alloc: Allocator, fingerprint: Fingerprint) Allocator.Error!Recommendation {
    const ram = fingerprint.ram_total_mb orelse return .{
        .reason = try alloc.dupe(u8, "RAM total is unavailable"),
    };

    if (ram > 4096) {
        return .{
            .reason = try std.fmt.allocPrint(
                alloc,
                "RAM {d} MB > 4096 MB: the device is comfortable as is",
                .{ram},
            ),
        };
    }

    if (fingerprint.sdk) |sdk| {
        if (ram <= 3072 and sdk < 31) {
            return .{
                .profile = .light,
                .reason = try std.fmt.allocPrint(
                    alloc,
                    "RAM {d} MB <= 3072 MB and SDK {d} < 31",
                    .{ ram, sdk },
                ),
            };
        }
        return .{
            .profile = .balanced,
            .reason = try std.fmt.allocPrint(alloc, "RAM {d} MB <= 4096 MB", .{ram}),
        };
    }

    return .{
        .profile = .balanced,
        .reason = try std.fmt.allocPrint(
            alloc,
            "RAM {d} MB <= 4096 MB; SDK level is unavailable",
            .{ram},
        ),
    };
}

const Properties = struct {
    sdk: ?u32 = null,
    release: ?[]u8 = null,
    manufacturer: ?[]u8 = null,
    model: ?[]u8 = null,
    abi: ?[]u8 = null,
    low_ram: ?bool = null,

    fn deinit(props: *Properties, alloc: Allocator) void {
        if (props.release) |value| alloc.free(value);
        if (props.manufacturer) |value| alloc.free(value);
        if (props.model) |value| alloc.free(value);
        if (props.abi) |value| alloc.free(value);
        props.* = .{};
    }
};

fn parseGetprop(alloc: Allocator, text: []const u8) Allocator.Error!Properties {
    var props: Properties = .{};
    errdefer props.deinit(alloc);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len < 5 or line[0] != '[' or line[line.len - 1] != ']') continue;
        const separator = std.mem.indexOf(u8, line, "]: [") orelse continue;
        const value_start = separator + "]: [".len;
        if (value_start > line.len - 1) continue;
        const key = line[1..separator];
        if (key.len == 0) continue;
        try applyProperty(alloc, &props, key, line[value_start .. line.len - 1]);
    }
    return props;
}

fn applyProperty(
    alloc: Allocator,
    props: *Properties,
    key: []const u8,
    value: []const u8,
) Allocator.Error!void {
    if (std.mem.eql(u8, key, "ro.build.version.sdk")) {
        props.sdk = std.fmt.parseInt(u32, value, 10) catch null;
    } else if (std.mem.eql(u8, key, "ro.build.version.release")) {
        try setString(alloc, &props.release, value);
    } else if (std.mem.eql(u8, key, "ro.product.manufacturer")) {
        try setString(alloc, &props.manufacturer, value);
    } else if (std.mem.eql(u8, key, "ro.product.model")) {
        try setString(alloc, &props.model, value);
    } else if (std.mem.eql(u8, key, "ro.product.cpu.abi")) {
        try setString(alloc, &props.abi, value);
    } else if (std.mem.eql(u8, key, "ro.config.low_ram")) {
        props.low_ram = parseBool(value);
    }
}

fn setString(alloc: Allocator, destination: *?[]u8, value: []const u8) Allocator.Error!void {
    if (destination.*) |old| alloc.free(old);
    destination.* = null;
    if (value.len == 0) return;
    destination.* = try alloc.dupe(u8, value);
}

fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) return false;
    return null;
}

fn readFixture(alloc: Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, "tests/fixtures/{s}", .{name});
    defer alloc.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, alloc, .limited(64 * 1024));
}

test "profile labels are stable" {
    try std.testing.expectEqualStrings("light", Profile.light.label());
    try std.testing.expectEqualStrings("balanced", Profile.balanced.label());
}

test "parseFingerprint reads the full getprop and meminfo fixtures" {
    const alloc = std.testing.allocator;
    const getprop = try readFixture(alloc, "getprop_android10.txt");
    defer alloc.free(getprop);
    const meminfo = try readFixture(alloc, "meminfo_3gb.txt");
    defer alloc.free(meminfo);

    var fingerprint = try parseFingerprint(alloc, "FIXTURE123", getprop, meminfo);
    defer fingerprint.deinit(alloc);

    try std.testing.expectEqualStrings("FIXTURE123", fingerprint.serial);
    try std.testing.expectEqual(@as(?u32, 29), fingerprint.sdk);
    try std.testing.expectEqualStrings("10", fingerprint.release.?);
    try std.testing.expectEqualStrings("Xiaomi", fingerprint.manufacturer.?);
    try std.testing.expectEqualStrings("Redmi Note 5", fingerprint.model.?);
    try std.testing.expectEqualStrings("arm64-v8a", fingerprint.abi.?);
    try std.testing.expectEqual(@as(?bool, false), fingerprint.low_ram);
    try std.testing.expectEqual(@as(?u64, 2947), fingerprint.ram_total_mb);
}

test "parseFingerprint leaves missing fields null" {
    const alloc = std.testing.allocator;
    const getprop = try readFixture(alloc, "getprop_partial.txt");
    defer alloc.free(getprop);
    const meminfo = try readFixture(alloc, "meminfo_4gb.txt");
    defer alloc.free(meminfo);

    var fingerprint = try parseFingerprint(alloc, "FIXTURE456", getprop, meminfo);
    defer fingerprint.deinit(alloc);

    try std.testing.expectEqual(@as(?u32, 30), fingerprint.sdk);
    try std.testing.expect(fingerprint.release == null);
    try std.testing.expect(fingerprint.manufacturer == null);
    try std.testing.expect(fingerprint.model == null);
    try std.testing.expect(fingerprint.abi == null);
    try std.testing.expect(fingerprint.low_ram == null);
    try std.testing.expectEqual(@as(?u64, 3840), fingerprint.ram_total_mb);
}

test "parseFingerprint tolerates empty and malformed input" {
    var fingerprint = try parseFingerprint(
        std.testing.allocator,
        "EMPTY",
        "",
        "",
    );
    defer fingerprint.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("EMPTY", fingerprint.serial);
    try std.testing.expect(fingerprint.sdk == null);
    try std.testing.expect(fingerprint.release == null);
    try std.testing.expect(fingerprint.ram_total_mb == null);
}

test "parseFingerprint keeps the last value of a repeated property" {
    const getprop =
        "[ro.product.model]: [First]\n" ++
        "[ro.product.model]: [Second]\n" ++
        "[ro.product.model]: []\n";

    var fingerprint = try parseFingerprint(std.testing.allocator, "DUP", getprop, "");
    defer fingerprint.deinit(std.testing.allocator);

    try std.testing.expect(fingerprint.model == null);
}

test "parseMemTotal converts kilobytes to megabytes" {
    try std.testing.expectEqual(
        @as(?u64, 3840),
        parseMemTotal("MemTotal:        3932160 kB\nMemFree: 1 kB\n"),
    );
    try std.testing.expectEqual(@as(?u64, 1), parseMemTotal("MemTotal: 1024 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), parseMemTotal("MemFree: 1 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), parseMemTotal("MemTotal: not-a-number kB\n"));
    try std.testing.expectEqual(@as(?u64, null), parseMemTotal("MemTotal: 0 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), parseMemTotal(""));
}

test "recommend light for small RAM on an older SDK" {
    const alloc = std.testing.allocator;
    var recommendation = try recommend(alloc, .{ .serial = "A", .sdk = 29, .ram_total_mb = 2947 });
    defer recommendation.deinit(alloc);

    try std.testing.expectEqual(Profile.light, recommendation.profile.?);
    try std.testing.expect(std.mem.indexOf(u8, recommendation.reason, "3072") != null);
}

test "recommend applies the RAM and SDK boundaries" {
    const alloc = std.testing.allocator;

    const cases = [_]struct {
        ram: u64,
        sdk: u32,
        expected: ?Profile,
    }{
        .{ .ram = 3072, .sdk = 30, .expected = .light },
        .{ .ram = 3072, .sdk = 31, .expected = .balanced },
        .{ .ram = 3073, .sdk = 20, .expected = .balanced },
        .{ .ram = 4096, .sdk = 10, .expected = .balanced },
        .{ .ram = 4097, .sdk = 10, .expected = null },
    };

    for (cases) |case| {
        var recommendation = try recommend(alloc, .{
            .serial = "A",
            .sdk = case.sdk,
            .ram_total_mb = case.ram,
        });
        defer recommendation.deinit(alloc);
        try std.testing.expectEqual(case.expected, recommendation.profile);
    }
}

test "recommend balanced when the SDK is unknown" {
    const alloc = std.testing.allocator;
    var recommendation = try recommend(alloc, .{ .serial = "A", .ram_total_mb = 3000 });
    defer recommendation.deinit(alloc);

    try std.testing.expectEqual(Profile.balanced, recommendation.profile.?);
    try std.testing.expect(std.mem.indexOf(u8, recommendation.reason, "unavailable") != null);
}

test "recommend nothing when RAM is unknown" {
    const alloc = std.testing.allocator;
    var recommendation = try recommend(alloc, .{ .serial = "A", .sdk = 29 });
    defer recommendation.deinit(alloc);

    try std.testing.expect(recommendation.profile == null);
    try std.testing.expect(std.mem.indexOf(u8, recommendation.reason, "RAM") != null);
}

test "select takes the only ready device" {
    const entries = [_]adb.DeviceEntry{
        .{ .serial = "A", .state = .device, .detail = "device" },
    };
    const entry = try select(&entries, null);
    try std.testing.expectEqualStrings("A", entry.serial);
}

test "select fails without devices" {
    try std.testing.expectError(error.NoDevices, select(&.{}, null));
}

test "select requires a serial when several devices are attached" {
    const entries = [_]adb.DeviceEntry{
        .{ .serial = "A", .state = .device, .detail = "device" },
        .{ .serial = "B", .state = .device, .detail = "device" },
    };
    try std.testing.expectError(error.MultipleDevices, select(&entries, null));
}

test "select honors an explicit serial" {
    const entries = [_]adb.DeviceEntry{
        .{ .serial = "A", .state = .device, .detail = "device" },
        .{ .serial = "B", .state = .device, .detail = "device" },
    };
    const entry = try select(&entries, "B");
    try std.testing.expectEqualStrings("B", entry.serial);

    try std.testing.expectError(error.SerialNotFound, select(&entries, "C"));
}

test "select rejects devices that are not ready" {
    const single = [_]adb.DeviceEntry{
        .{ .serial = "A", .state = .unauthorized, .detail = "unauthorized" },
    };
    try std.testing.expectError(error.DeviceNotReady, select(&single, null));

    const offline = [_]adb.DeviceEntry{
        .{ .serial = "A", .state = .device, .detail = "device" },
        .{ .serial = "B", .state = .offline, .detail = "offline" },
    };
    try std.testing.expectError(error.DeviceNotReady, select(&offline, "B"));
}
