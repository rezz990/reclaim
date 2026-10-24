//! Package denylist rules. Static entries are compiled in and can never be
//! overridden by a profile; dynamic entries are read from the running device.

const std = @import("std");
const adb = @import("adb.zig");

const Allocator = std.mem.Allocator;

pub const static_exact = [_][]const u8{
    "android",
    "com.android.systemui",
    "com.android.settings",
    "com.android.phone",
    "com.android.shell",
    "com.android.bluetooth",
    "com.android.nfc",
    "com.android.packageinstaller",
    "com.google.android.permissioncontroller",
};

pub const static_prefixes = [_][]const u8{
    "com.android.providers.",
    "com.android.inputmethod.",
};

pub const Role = enum {
    launcher,
    keyboard,
    dialer,
    sms,

    pub fn label(role: Role) []const u8 {
        return switch (role) {
            .launcher => "default launcher",
            .keyboard => "active keyboard",
            .dialer => "default dialer",
            .sms => "default SMS app",
        };
    }
};

pub const Entry = struct {
    package: []const u8,
    role: Role,
};

pub const Dynamic = struct {
    entries: []const Entry = &.{},

    pub fn deinit(dynamic: *Dynamic, alloc: Allocator) void {
        for (dynamic.entries) |entry| alloc.free(entry.package);
        alloc.free(dynamic.entries);
        dynamic.* = .{};
    }

    pub fn roleOf(dynamic: Dynamic, package: []const u8) ?Role {
        for (dynamic.entries) |entry| {
            if (std.mem.eql(u8, entry.package, package)) return entry.role;
        }
        return null;
    }
};

pub const Block = union(enum) {
    static,
    role: Role,
};

pub fn isStaticallyBlocked(package: []const u8) bool {
    for (static_exact) |blocked| {
        if (std.mem.eql(u8, package, blocked)) return true;
    }
    for (static_prefixes) |prefix| {
        if (std.mem.startsWith(u8, package, prefix)) return true;
    }
    return false;
}

pub fn check(package: []const u8, dynamic: Dynamic) ?Block {
    if (isStaticallyBlocked(package)) return .static;
    if (dynamic.roleOf(package)) |role| return .{ .role = role };
    return null;
}

pub fn isBlocked(package: []const u8, dynamic: Dynamic) bool {
    return check(package, dynamic) != null;
}

/// Reads the default launcher, active keyboard, default dialer, and default SMS
/// app. Any failed query aborts the read so callers can fail closed.
pub fn readDynamic(alloc: Allocator, adb_path: adb.AdbPath, serial: []const u8) adb.Error!Dynamic {
    const queries = [_]struct {
        role: Role,
        command: []const u8,
    }{
        .{
            .role = .launcher,
            .command = "cmd package resolve-activity --brief -c android.intent.category.HOME",
        },
        .{
            .role = .keyboard,
            .command = "settings get secure default_input_method",
        },
        .{
            .role = .dialer,
            .command = "cmd package resolve-activity --brief -a android.intent.action.DIAL",
        },
        .{
            .role = .sms,
            .command = "cmd package resolve-activity --brief -a android.intent.action.SENDTO -d sms:",
        },
    };

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| alloc.free(entry.package);
        entries.deinit(alloc);
    }

    for (queries) |query| {
        var result = try adb.shell(alloc, adb_path, serial, query.command);
        defer result.deinit(alloc);
        if (result.timed_out) return error.AdbFailed;
        if ((result.exit_code orelse return error.AdbFailed) != 0) return error.AdbFailed;

        const package = parseComponentPackage(result.stdout) orelse continue;
        const copy = try alloc.dupe(u8, package);
        entries.append(alloc, .{ .package = copy, .role = query.role }) catch |err| {
            alloc.free(copy);
            return err;
        };
    }

    return .{ .entries = try entries.toOwnedSlice(alloc) };
}

/// Picks the last component package from `resolve-activity --brief` or
/// `settings get secure default_input_method` output.
pub fn parseComponentPackage(text: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or std.mem.eql(u8, line, "null")) continue;
        const separator = std.mem.indexOfScalar(u8, line, '/') orelse continue;
        const package = std.mem.trim(u8, line[0..separator], " \t");
        if (!isPackageName(package)) continue;
        found = package;
    }
    return found;
}

fn isPackageName(text: []const u8) bool {
    if (text.len == 0) return false;
    var has_dot = false;
    for (text) |char| {
        if (char == '.') {
            has_dot = true;
            continue;
        }
        if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    }
    return has_dot;
}

const testing = std.testing;

test "static denylist blocks every documented package" {
    const blocked = [_][]const u8{
        "android",
        "com.android.systemui",
        "com.android.settings",
        "com.android.phone",
        "com.android.shell",
        "com.android.bluetooth",
        "com.android.nfc",
        "com.android.packageinstaller",
        "com.google.android.permissioncontroller",
        "com.android.providers.contacts",
        "com.android.inputmethod.latin",
    };
    for (blocked) |package| {
        try testing.expect(isStaticallyBlocked(package));
    }
}

test "static denylist allows ordinary packages" {
    const allowed = [_][]const u8{
        "com.example.app",
        "com.android.chrome",
        "com.android.providersx",
        "com.android.inputmethodx",
        "com.google.android.gms",
        "androidx.core",
    };
    for (allowed) |package| {
        try testing.expect(!isStaticallyBlocked(package));
    }
}

test "dynamic denylist matches packages by role" {
    const entries = [_]Entry{
        .{ .package = "com.example.launcher", .role = .launcher },
        .{ .package = "com.example.keyboard", .role = .keyboard },
        .{ .package = "com.example.dialer", .role = .dialer },
        .{ .package = "com.example.sms", .role = .sms },
    };
    const dynamic: Dynamic = .{ .entries = &entries };

    try testing.expectEqual(Role.launcher, dynamic.roleOf("com.example.launcher").?);
    try testing.expectEqual(Role.keyboard, dynamic.roleOf("com.example.keyboard").?);
    try testing.expect(dynamic.roleOf("com.example.other") == null);
    try testing.expect(isBlocked("com.example.launcher", dynamic));
    try testing.expect(!isBlocked("com.example.other", dynamic));
}

test "static rules win over dynamic rules" {
    const entries = [_]Entry{
        .{ .package = "com.android.systemui", .role = .launcher },
    };
    const blocked = check("com.android.systemui", .{ .entries = &entries });
    try testing.expect(blocked != null);
    try testing.expectEqual(Block.static, std.meta.activeTag(blocked.?));
}

test "parseComponentPackage reads resolve-activity output" {
    try testing.expectEqualStrings(
        "com.example.launcher",
        parseComponentPackage(
            "priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true\n" ++
                "com.example.launcher/.Home\n",
        ).?,
    );
    try testing.expectEqualStrings(
        "com.example.keyboard",
        parseComponentPackage("com.example.keyboard/.Ime\n").?,
    );
    try testing.expectEqualStrings(
        "com.example.sms",
        parseComponentPackage("com.example.sms/.Sms\n").?,
    );
}

test "parseComponentPackage ignores missing and malformed components" {
    try testing.expect(parseComponentPackage("null\n") == null);
    try testing.expect(parseComponentPackage("No activity found\n") == null);
    try testing.expect(parseComponentPackage("") == null);
    try testing.expect(parseComponentPackage("/.Home\n") == null);
    try testing.expect(parseComponentPackage("nodot/.Main\n") == null);
    try testing.expect(parseComponentPackage("com.example.app\n") == null);
}

test "parseComponentPackage keeps the last valid component" {
    try testing.expectEqualStrings(
        "com.example.second",
        parseComponentPackage(
            "com.example.first/.One\n" ++
                "noise without a slash\n" ++
                "com.example.second/.Two\n",
        ).?,
    );
}

test "role labels are readable" {
    try testing.expectEqualStrings("default launcher", Role.launcher.label());
    try testing.expectEqualStrings("active keyboard", Role.keyboard.label());
    try testing.expectEqualStrings("default dialer", Role.dialer.label());
    try testing.expectEqualStrings("default SMS app", Role.sms.label());
}
