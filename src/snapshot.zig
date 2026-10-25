//! Snapshots record the original values of every step an apply will change.
//! Files are written and read back before apply sends anything to the device.
//! Everything in this module is local: no adb process is spawned here.

const std = @import("std");
const profile = @import("profile.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const schema = 1;
pub const max_snapshot_bytes = 1024 * 1024;
pub const max_value_bytes = 512;

pub const Status = enum {
    planned,
    applied,
    failed,
    skipped,

    pub fn label(status: Status) []const u8 {
        return switch (status) {
            .planned => "planned",
            .applied => "applied",
            .failed => "failed",
            .skipped => "skipped",
        };
    }
};

pub const Device = struct {
    serial: []const u8,
    model: ?[]const u8 = null,
    sdk: ?u32 = null,

    pub fn deinit(device: *Device, alloc: Allocator) void {
        alloc.free(device.serial);
        if (device.model) |model| alloc.free(model);
        device.* = undefined;
    }
};

pub const Entry = struct {
    step_id: []const u8,
    kind: profile.Kind,
    target: []const u8,
    before: ?[]const u8 = null,
    after: ?[]const u8 = null,
    status: Status = .planned,

    pub fn deinit(entry: *Entry, alloc: Allocator) void {
        alloc.free(entry.step_id);
        alloc.free(entry.target);
        if (entry.before) |before| alloc.free(before);
        if (entry.after) |after| alloc.free(after);
        entry.* = undefined;
    }
};

pub const Snapshot = struct {
    created: []const u8,
    device: Device,
    profile: []const u8,
    entries: []Entry,

    pub fn deinit(snapshot: *Snapshot, alloc: Allocator) void {
        alloc.free(snapshot.created);
        snapshot.device.deinit(alloc);
        alloc.free(snapshot.profile);
        for (snapshot.entries) |*entry| entry.deinit(alloc);
        alloc.free(snapshot.entries);
        snapshot.* = undefined;
    }

    pub fn count(snapshot: Snapshot, status: Status) usize {
        var total: usize = 0;
        for (snapshot.entries) |entry| {
            if (entry.status == status) total += 1;
        }
        return total;
    }
};

pub const Diagnostic = struct {
    message: ?[]const u8 = null,

    pub fn deinit(diagnostic: *Diagnostic, alloc: Allocator) void {
        if (diagnostic.message) |message| alloc.free(message);
        diagnostic.* = .{};
    }

    fn fail(diagnostic: *Diagnostic, alloc: Allocator, comptime format: []const u8, args: anytype) void {
        diagnostic.message = std.fmt.allocPrint(alloc, format, args) catch null;
    }
};

pub const LoadError = error{
    SnapshotReadFailed,
    InvalidSnapshot,
    OutOfMemory,
};

pub const SaveError = error{
    SnapshotWriteFailed,
    InvalidSnapshot,
    OutOfMemory,
};

pub const TargetError = error{
    InvalidTarget,
    OutOfMemory,
};

/// Current wall-clock time in whole seconds since the Unix epoch. Clock jumps
/// before 1970 are clamped to zero so filename and JSON formatting always work.
pub fn nowSeconds(io: Io) u64 {
    const seconds = Io.Clock.real.now(io).toSeconds();
    if (seconds <= 0) return 0;
    return @intCast(seconds);
}

pub fn formatCreated(alloc: Allocator, seconds: u64) Allocator.Error![]u8 {
    const parts = splitTimestamp(seconds);
    return std.fmt.allocPrint(
        alloc,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second },
    );
}

pub fn compactTimestamp(alloc: Allocator, seconds: u64) Allocator.Error![]u8 {
    const parts = splitTimestamp(seconds);
    return std.fmt.allocPrint(
        alloc,
        "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z",
        .{ parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second },
    );
}

const TimestampParts = struct {
    year: u16,
    month: u4,
    day: u5,
    hour: u5,
    minute: u6,
    second: u6,
};

fn splitTimestamp(seconds: u64) TimestampParts {
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
        .second = day_seconds.getSecondsIntoMinute(),
    };
}

/// Keeps serials usable as filenames on every supported OS.
pub fn serialSlug(alloc: Allocator, serial: []const u8) Allocator.Error![]u8 {
    const length = @min(serial.len, 64);
    const slug = try alloc.alloc(u8, length);
    for (serial[0..length], 0..) |char, index| {
        slug[index] = if (std.ascii.isAlphanumeric(char) or
            char == '.' or char == '_' or char == '-')
            char
        else
            '_';
    }
    return slug;
}

/// Writes the snapshot, reads it back, and only reports success when the
/// persisted copy is identical to what was requested. Returns the file path.
pub fn save(
    alloc: Allocator,
    io: Io,
    dir_path: []const u8,
    snapshot: Snapshot,
    seconds: u64,
    diagnostic: *Diagnostic,
) SaveError![]u8 {
    diagnostic.* = .{};

    if (snapshot.entries.len > 0 and snapshot.profile.len == 0) {
        diagnostic.fail(alloc, "the snapshot has no profile name", .{});
        return error.InvalidSnapshot;
    }

    const json = render(alloc, snapshot) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SnapshotWriteFailed,
    };
    defer alloc.free(json);

    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| {
        diagnostic.fail(
            alloc,
            "could not create the snapshot directory '{s}': {s}",
            .{ dir_path, @errorName(err) },
        );
        return error.SnapshotWriteFailed;
    };

    const path = uniquePath(alloc, io, dir_path, snapshot.device.serial, seconds) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagnostic.fail(
                alloc,
                "could not choose a snapshot file name in '{s}'",
                .{dir_path},
            );
            return error.SnapshotWriteFailed;
        },
    };
    errdefer alloc.free(path);

    writeAbsolute(io, path, json) catch |err| {
        diagnostic.fail(
            alloc,
            "could not write the snapshot '{s}': {s}",
            .{ path, @errorName(err) },
        );
        return error.SnapshotWriteFailed;
    };

    var loaded = load(alloc, io, path, diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (diagnostic.message == null) {
                diagnostic.fail(
                    alloc,
                    "could not read the snapshot '{s}' back",
                    .{path},
                );
            }
            return error.SnapshotWriteFailed;
        },
    };
    defer loaded.deinit(alloc);

    if (!equals(snapshot, loaded)) {
        diagnostic.fail(
            alloc,
            "snapshot '{s}' did not read back identically",
            .{path},
        );
        return error.SnapshotWriteFailed;
    }

    return path;
}

fn render(alloc: Allocator, snapshot: Snapshot) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    const json_entries = try alloc.alloc(EntryJson, snapshot.entries.len);
    defer alloc.free(json_entries);
    for (snapshot.entries, 0..) |entry, index| {
        json_entries[index] = .{
            .step_id = entry.step_id,
            .kind = entry.kind.label(),
            .target = entry.target,
            .before = entry.before,
            .after = entry.after,
            .status = entry.status.label(),
        };
    }

    const view: SnapshotJson = .{
        .schema = schema,
        .created = snapshot.created,
        .device = .{
            .serial = snapshot.device.serial,
            .model = snapshot.device.model,
            .sdk = snapshot.device.sdk,
        },
        .profile = snapshot.profile,
        .entries = json_entries,
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(view, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeAll("\n");
    return out.toOwnedSlice();
}

fn uniquePath(
    alloc: Allocator,
    io: Io,
    dir_path: []const u8,
    serial: []const u8,
    seconds: u64,
) (Allocator.Error || std.Io.Dir.CreateDirPathError)![]u8 {
    const slug = try serialSlug(alloc, serial);
    defer alloc.free(slug);
    const stamp = try compactTimestamp(alloc, seconds);
    defer alloc.free(stamp);

    var attempt: u8 = 1;
    while (attempt <= 99) : (attempt += 1) {
        const name = if (attempt == 1)
            try std.fmt.allocPrint(alloc, "{s}_{s}.json", .{ slug, stamp })
        else
            try std.fmt.allocPrint(alloc, "{s}_{s}_{d}.json", .{ slug, stamp, attempt });
        defer alloc.free(name);
        const path = try std.fs.path.join(alloc, &.{ dir_path, name });
        if (!pathExists(io, path)) return path;
        alloc.free(path);
    }
    return error.PathAlreadyExists;
}

fn pathExists(io: Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn writeAbsolute(io: Io, path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

/// Reads and validates one snapshot file. The path may be absolute or relative.
pub fn load(
    alloc: Allocator,
    io: Io,
    path: []const u8,
    diagnostic: *Diagnostic,
) LoadError!Snapshot {
    diagnostic.* = .{};

    const text = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        alloc,
        .limited(max_snapshot_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagnostic.fail(
                alloc,
                "could not read the snapshot '{s}': {s}",
                .{ path, @errorName(err) },
            );
            return error.SnapshotReadFailed;
        },
    };
    defer alloc.free(text);

    return parse(alloc, path, text, diagnostic);
}

pub fn parse(
    alloc: Allocator,
    source: []const u8,
    text: []const u8,
    diagnostic: *Diagnostic,
) LoadError!Snapshot {
    diagnostic.* = .{};
    var ctx: Context = .{ .alloc = alloc, .diagnostic = diagnostic, .source = source };

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ctx.fail("invalid JSON: {s}", .{@errorName(err)}),
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return ctx.fail("the root must be a JSON object", .{}),
    };
    try rejectUnknown(&ctx, root, &.{ "schema", "created", "device", "profile", "entries" }, null);

    const schema_value = switch (root.get("schema") orelse
        return ctx.fail("field 'schema' is required", .{})) {
        .integer => |value| value,
        else => return ctx.fail("field 'schema' must be an integer", .{}),
    };
    if (schema_value != schema) {
        return ctx.fail(
            "unsupported schema {d}; this build understands schema {d}",
            .{ schema_value, schema },
        );
    }

    const created = try requiredString(&ctx, root, "created", null, 32);
    errdefer alloc.free(created);
    if (!isIsoTimestamp(created)) {
        return ctx.fail("field 'created' is not an ISO-8601 UTC timestamp", .{});
    }

    const device_object = switch (root.get("device") orelse
        return ctx.fail("field 'device' is required", .{})) {
        .object => |object| object,
        else => return ctx.fail("field 'device' must be an object", .{}),
    };
    try rejectUnknown(&ctx, device_object, &.{ "serial", "model", "sdk" }, null);

    const serial = try requiredString(&ctx, device_object, "serial", null, 128);
    errdefer alloc.free(serial);
    const model = try optionalString(&ctx, device_object, "model", null, 128);
    errdefer if (model) |value| alloc.free(value);
    const sdk = try optionalU32(&ctx, device_object, "sdk", null);

    const profile_name = try requiredString(&ctx, root, "profile", null, 64);
    errdefer alloc.free(profile_name);
    if (!isPlainName(profile_name)) {
        return ctx.fail("field 'profile' is not a plain profile name", .{});
    }

    const entries_value = switch (root.get("entries") orelse
        return ctx.fail("field 'entries' is required", .{})) {
        .array => |array| array.items,
        else => return ctx.fail("field 'entries' must be an array", .{}),
    };

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }

    for (entries_value, 0..) |item, index| {
        const entry = try parseEntry(&ctx, alloc, item, index);
        entries.append(alloc, entry) catch |err| {
            var discarded = entry;
            discarded.deinit(alloc);
            return err;
        };
    }

    for (entries.items, 0..) |entry, index| {
        for (entries.items[index + 1 ..]) |other| {
            if (std.mem.eql(u8, entry.step_id, other.step_id)) {
                return ctx.fail("step {d} (id '{s}'): duplicate step_id", .{ index + 1, entry.step_id });
            }
        }
    }

    return .{
        .created = created,
        .device = .{ .serial = serial, .model = model, .sdk = sdk },
        .profile = profile_name,
        .entries = try entries.toOwnedSlice(alloc),
    };
}

const Context = struct {
    alloc: Allocator,
    diagnostic: *Diagnostic,
    source: []const u8,

    fn fail(ctx: *Context, comptime format: []const u8, args: anytype) LoadError {
        const detail = std.fmt.allocPrint(ctx.alloc, format, args) catch
            return error.OutOfMemory;
        defer ctx.alloc.free(detail);
        ctx.diagnostic.message = std.fmt.allocPrint(
            ctx.alloc,
            "invalid snapshot '{s}': {s}",
            .{ ctx.source, detail },
        ) catch return error.OutOfMemory;
        return error.InvalidSnapshot;
    }
};

const Where = struct {
    index: usize,
    id: []const u8 = "",

    fn fail(where: Where, ctx: *Context, comptime format: []const u8, args: anytype) LoadError {
        const detail = std.fmt.allocPrint(ctx.alloc, format, args) catch
            return error.OutOfMemory;
        defer ctx.alloc.free(detail);
        if (where.id.len > 0) {
            return ctx.fail("step {d} (id '{s}'): {s}", .{ where.index + 1, where.id, detail });
        }
        return ctx.fail("step {d}: {s}", .{ where.index + 1, detail });
    }
};

fn parseEntry(
    ctx: *Context,
    alloc: Allocator,
    item: std.json.Value,
    index: usize,
) LoadError!Entry {
    var where: Where = .{ .index = index };
    const object = switch (item) {
        .object => |value| value,
        else => return where.fail(ctx, "must be a JSON object", .{}),
    };
    try rejectUnknown(
        ctx,
        object,
        &.{ "step_id", "kind", "target", "before", "after", "status" },
        where,
    );

    const step_id = try requiredString(ctx, object, "step_id", where, 64);
    errdefer alloc.free(step_id);
    if (!isToken(step_id)) {
        return where.fail(ctx, "field 'step_id' contains unsupported characters", .{});
    }
    where.id = step_id;

    const kind_text = try requiredString(ctx, object, "kind", where, 32);
    defer alloc.free(kind_text);
    const kind = kindFromLabel(kind_text) orelse
        return where.fail(ctx, "unknown kind '{s}'", .{kind_text});

    const target = try requiredString(ctx, object, "target", where, 256);
    errdefer alloc.free(target);
    var parsed_target = parseTarget(alloc, kind, target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidTarget => return where.fail(
            ctx,
            "field 'target' is not valid for kind '{s}'",
            .{kind.label()},
        ),
    };
    profile.freeTarget(&parsed_target, alloc);

    const before = try optionalString(ctx, object, "before", where, max_value_bytes);
    errdefer if (before) |value| alloc.free(value);
    const after = try optionalString(ctx, object, "after", where, max_value_bytes);
    errdefer if (after) |value| alloc.free(value);

    const status_text = try requiredString(ctx, object, "status", where, 16);
    defer alloc.free(status_text);
    const status = statusFromLabel(status_text) orelse
        return where.fail(ctx, "unknown status '{s}'", .{status_text});

    try validateEntry(where, ctx, kind, target, before, after);

    return .{
        .step_id = step_id,
        .kind = kind,
        .target = target,
        .before = before,
        .after = after,
        .status = status,
    };
}

fn validateEntry(
    where: Where,
    ctx: *Context,
    kind: profile.Kind,
    target: []const u8,
    before: ?[]const u8,
    after: ?[]const u8,
) LoadError!void {
    switch (kind) {
        .maintenance => return where.fail(
            ctx,
            "maintenance steps have nothing to revert and are not recorded",
            .{},
        ),
        .setting, .device_config => {
            if (after == null) {
                return where.fail(ctx, "field 'after' is required for kind '{s}'", .{kind.label()});
            }
        },
        .compile => {
            if (before != null or after != null) {
                return where.fail(ctx, "fields 'before' and 'after' must be null for kind 'compile'", .{});
            }
        },
        .appops => {
            if (after == null) {
                return where.fail(ctx, "field 'after' is required for kind 'appops'", .{});
            }
        },
        .standby_bucket => {
            const value = before orelse
                return where.fail(ctx, "field 'before' is required for kind 'standby_bucket'", .{});
            if (!isBucketBefore(value)) {
                return where.fail(ctx, "field 'before' is not a standby bucket", .{});
            }
            const desired = after orelse
                return where.fail(ctx, "field 'after' is required for kind 'standby_bucket'", .{});
            if (bucketFromLabel(desired) == null) {
                return where.fail(ctx, "field 'after' is not a standby bucket", .{});
            }
        },
        .wm => {
            const value = before orelse
                return where.fail(ctx, "field 'before' is required for kind 'wm'", .{});
            const key = wmKeyFromTarget(target) orelse
                return where.fail(ctx, "field 'target' is not a wm key", .{});
            if (!isWmBefore(key, value)) {
                return where.fail(ctx, "field 'before' is not a wm value", .{});
            }
            const desired = after orelse
                return where.fail(ctx, "field 'after' is required for kind 'wm'", .{});
            if (!isWmValue(key, desired)) {
                return where.fail(ctx, "field 'after' is not a wm value", .{});
            }
        },
        .package => {
            const desired = after orelse
                return where.fail(ctx, "field 'after' is required for kind 'package'", .{});
            const original = before orelse
                return where.fail(ctx, "field 'before' is required for kind 'package'", .{});
            if (std.mem.eql(u8, desired, "disable")) {
                if (!std.mem.eql(u8, original, "enabled")) {
                    return where.fail(
                        ctx,
                        "only an enabled package can be restored after disable",
                        .{},
                    );
                }
            } else if (std.mem.eql(u8, desired, "uninstall-user")) {
                if (!std.mem.eql(u8, original, "installed")) {
                    return where.fail(
                        ctx,
                        "only an installed package can be restored after uninstall-user",
                        .{},
                    );
                }
            } else {
                return where.fail(
                    ctx,
                    "field 'after' must be disable or uninstall-user for kind 'package'",
                    .{},
                );
            }
        },
    }
}

pub fn equals(a: Snapshot, b: Snapshot) bool {
    if (!std.mem.eql(u8, a.created, b.created)) return false;
    if (!std.mem.eql(u8, a.device.serial, b.device.serial)) return false;
    if (!optionalEql(a.device.model, b.device.model)) return false;
    if (a.device.sdk != b.device.sdk) return false;
    if (!std.mem.eql(u8, a.profile, b.profile)) return false;
    if (a.entries.len != b.entries.len) return false;
    for (a.entries, b.entries) |left, right| {
        if (!std.mem.eql(u8, left.step_id, right.step_id)) return false;
        if (left.kind != right.kind) return false;
        if (!std.mem.eql(u8, left.target, right.target)) return false;
        if (!optionalEql(left.before, right.before)) return false;
        if (!optionalEql(left.after, right.after)) return false;
        if (left.status != right.status) return false;
    }
    return true;
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Finds the newest snapshot file for a serial. Returns null when the
/// directory or a matching file does not exist.
pub fn latestPath(
    alloc: Allocator,
    io: Io,
    dir_path: []const u8,
    serial: []const u8,
    diagnostic: *Diagnostic,
) LoadError!?[]u8 {
    diagnostic.* = .{};

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => {
            diagnostic.fail(
                alloc,
                "could not open the snapshot directory '{s}': {s}",
                .{ dir_path, @errorName(err) },
            );
            return error.SnapshotReadFailed;
        },
    };
    defer dir.close(io);

    const slug = try serialSlug(alloc, serial);
    defer alloc.free(slug);
    const prefix = try std.fmt.allocPrint(alloc, "{s}_", .{slug});
    defer alloc.free(prefix);

    var best: ?[]u8 = null;
    errdefer if (best) |name| alloc.free(name);

    var iterator = dir.iterate();
    while (iterator.next(io) catch |err| {
        diagnostic.fail(
            alloc,
            "could not list the snapshot directory '{s}': {s}",
            .{ dir_path, @errorName(err) },
        );
        return error.SnapshotReadFailed;
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (best) |current| {
            if (std.mem.order(u8, entry.name, current) == .gt) {
                alloc.free(current);
                best = try alloc.dupe(u8, entry.name);
            }
        } else {
            best = try alloc.dupe(u8, entry.name);
        }
    }

    if (best) |name| {
        defer alloc.free(name);
        return try std.fs.path.join(alloc, &.{ dir_path, name });
    }
    return null;
}

/// Rebuilds just enough of a profile target to read or rebuild a command.
/// Values that only exist in the entry (before/after) are deliberately empty.
pub fn parseTarget(alloc: Allocator, kind: profile.Kind, target: []const u8) TargetError!profile.Target {
    switch (kind) {
        .setting => {
            const separator = std.mem.indexOfScalar(u8, target, '/') orelse
                return error.InvalidTarget;
            const namespace = target[0..separator];
            const key = target[separator + 1 ..];
            if (!isSettingNamespace(namespace) or !isToken(key)) return error.InvalidTarget;
            const namespace_copy = try alloc.dupe(u8, namespace);
            errdefer alloc.free(namespace_copy);
            const key_copy = try alloc.dupe(u8, key);
            errdefer alloc.free(key_copy);
            const value_copy = try alloc.dupe(u8, "");
            return .{ .setting = .{
                .namespace = namespace_copy,
                .key = key_copy,
                .value = value_copy,
            } };
        },
        .device_config => {
            const separator = std.mem.indexOfScalar(u8, target, '/') orelse
                return error.InvalidTarget;
            const namespace = target[0..separator];
            const key = target[separator + 1 ..];
            if (!isToken(namespace) or !isToken(key)) return error.InvalidTarget;
            const namespace_copy = try alloc.dupe(u8, namespace);
            errdefer alloc.free(namespace_copy);
            const key_copy = try alloc.dupe(u8, key);
            errdefer alloc.free(key_copy);
            const value_copy = try alloc.dupe(u8, "");
            return .{ .device_config = .{
                .namespace = namespace_copy,
                .key = key_copy,
                .value = value_copy,
            } };
        },
        .compile => {
            const prefix = "compile ";
            if (!std.mem.startsWith(u8, target, prefix)) return error.InvalidTarget;
            const rest = target[prefix.len..];
            const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidTarget;
            const mode = rest[0..space];
            if (!isCompileMode(mode)) return error.InvalidTarget;
            const scope_part = rest[space + 1 ..];
            if (scope_part.len < 3 or scope_part[0] != '(' or
                scope_part[scope_part.len - 1] != ')')
            {
                return error.InvalidTarget;
            }
            const scope = scope_part[1 .. scope_part.len - 1];
            if (!isToken(scope)) return error.InvalidTarget;
            const mode_copy = try alloc.dupe(u8, mode);
            errdefer alloc.free(mode_copy);
            const scope_copy = try alloc.dupe(u8, scope);
            return .{ .compile = .{ .mode = mode_copy, .scope = scope_copy } };
        },
        .appops => {
            const space = std.mem.indexOfScalar(u8, target, ' ') orelse
                return error.InvalidTarget;
            const package = target[0..space];
            const op = target[space + 1 ..];
            if (!isPackageName(package) or !isToken(op)) return error.InvalidTarget;
            if (std.mem.indexOfScalar(u8, op, ' ') != null) return error.InvalidTarget;
            const package_copy = try alloc.dupe(u8, package);
            errdefer alloc.free(package_copy);
            const op_copy = try alloc.dupe(u8, op);
            errdefer alloc.free(op_copy);
            const mode_copy = try alloc.dupe(u8, "");
            return .{ .appops = .{
                .package = package_copy,
                .op = op_copy,
                .mode = mode_copy,
            } };
        },
        .standby_bucket => {
            if (!isPackageName(target)) return error.InvalidTarget;
            const package_copy = try alloc.dupe(u8, target);
            return .{ .standby_bucket = .{ .package = package_copy, .bucket = .active } };
        },
        .wm => {
            const key: profile.WmKey = if (std.mem.eql(u8, target, "wm density"))
                .density
            else if (std.mem.eql(u8, target, "wm size"))
                .size
            else
                return error.InvalidTarget;
            const value_copy = try alloc.dupe(u8, "");
            return .{ .wm = .{ .key = key, .value = value_copy } };
        },
        .package => {
            if (!isPackageName(target)) return error.InvalidTarget;
            const package_copy = try alloc.dupe(u8, target);
            return .{ .package = .{ .package = package_copy, .action = .disable } };
        },
        .maintenance => {
            if (!std.mem.eql(u8, target, "idle maintenance")) return error.InvalidTarget;
            return .{ .maintenance = {} };
        },
    }
}

fn rejectUnknown(
    ctx: *Context,
    object: std.json.ObjectMap,
    allowed: []const []const u8,
    where: ?Where,
) LoadError!void {
    for (object.keys()) |key| {
        if (!contains(allowed, key)) {
            if (where) |where_value| {
                return where_value.fail(ctx, "unknown field '{s}'", .{key});
            }
            return ctx.fail("unknown field '{s}'", .{key});
        }
    }
}

fn requiredString(
    ctx: *Context,
    object: std.json.ObjectMap,
    field: []const u8,
    where: ?Where,
    max_len: usize,
) LoadError![]u8 {
    const value = object.get(field) orelse return missingField(ctx, where, field);
    const text = switch (value) {
        .string => |string| string,
        else => return wrongFieldType(ctx, where, field, "a string"),
    };
    return copyString(ctx, text, field, where, max_len, false);
}

fn optionalString(
    ctx: *Context,
    object: std.json.ObjectMap,
    field: []const u8,
    where: ?Where,
    max_len: usize,
) LoadError!?[]u8 {
    const value = object.get(field) orelse return null;
    const text = switch (value) {
        .null => return null,
        .string => |string| string,
        else => return wrongFieldType(ctx, where, field, "a string or null"),
    };
    return try copyString(ctx, text, field, where, max_len, true);
}

fn copyString(
    ctx: *Context,
    text: []const u8,
    field: []const u8,
    where: ?Where,
    max_len: usize,
    allow_empty: bool,
) LoadError![]u8 {
    if (text.len == 0 and !allow_empty) {
        return failField(ctx, where, field, "must not be empty");
    }
    if (text.len > max_len) {
        return failField(ctx, where, field, "is too long");
    }
    if (hasControlChars(text)) {
        return failField(ctx, where, field, "contains control characters");
    }
    return ctx.alloc.dupe(u8, text) catch error.OutOfMemory;
}

fn optionalU32(
    ctx: *Context,
    object: std.json.ObjectMap,
    field: []const u8,
    where: ?Where,
) LoadError!?u32 {
    const value = object.get(field) orelse return null;
    const number = switch (value) {
        .null => return null,
        .integer => |integer| integer,
        else => return wrongFieldType(ctx, where, field, "an integer or null"),
    };
    if (number < 0) return failField(ctx, where, field, "must not be negative");
    if (number > std.math.maxInt(u32)) return failField(ctx, where, field, "is out of range");
    return @intCast(number);
}

fn missingField(ctx: *Context, where: ?Where, field: []const u8) LoadError {
    if (where) |where_value| {
        return where_value.fail(ctx, "field '{s}' is required", .{field});
    }
    return ctx.fail("field '{s}' is required", .{field});
}

fn wrongFieldType(
    ctx: *Context,
    where: ?Where,
    field: []const u8,
    expected: []const u8,
) LoadError {
    if (where) |where_value| {
        return where_value.fail(ctx, "field '{s}' must be {s}", .{ field, expected });
    }
    return ctx.fail("field '{s}' must be {s}", .{ field, expected });
}

fn failField(
    ctx: *Context,
    where: ?Where,
    field: []const u8,
    detail: []const u8,
) LoadError {
    if (where) |where_value| {
        return where_value.fail(ctx, "field '{s}' {s}", .{ field, detail });
    }
    return ctx.fail("field '{s}' {s}", .{ field, detail });
}

fn kindFromLabel(text: []const u8) ?profile.Kind {
    const kinds = [_]profile.Kind{
        .setting,        .device_config, .compile, .appops,
        .standby_bucket, .wm,            .package, .maintenance,
    };
    for (kinds) |kind| {
        if (std.mem.eql(u8, kind.label(), text)) return kind;
    }
    return null;
}

fn statusFromLabel(text: []const u8) ?Status {
    const statuses = [_]Status{ .planned, .applied, .failed, .skipped };
    for (statuses) |status| {
        if (std.mem.eql(u8, status.label(), text)) return status;
    }
    return null;
}

fn bucketFromLabel(text: []const u8) ?profile.Bucket {
    const buckets = [_]profile.Bucket{
        .active, .working_set, .frequent, .rare, .restricted, .never,
    };
    for (buckets) |bucket| {
        if (std.mem.eql(u8, bucket.label(), text)) return bucket;
    }
    return null;
}

fn isBucketBefore(text: []const u8) bool {
    if (bucketFromLabel(text) != null) return true;
    const prefix = "bucket ";
    if (!std.mem.startsWith(u8, text, prefix)) return false;
    const number = std.fmt.parseInt(u32, text[prefix.len..], 10) catch return false;
    return number > 0;
}

fn wmKeyFromTarget(target: []const u8) ?profile.WmKey {
    if (std.mem.eql(u8, target, "wm density")) return .density;
    if (std.mem.eql(u8, target, "wm size")) return .size;
    return null;
}

fn isWmBefore(key: profile.WmKey, text: []const u8) bool {
    const physical = "physical ";
    if (std.mem.startsWith(u8, text, physical)) {
        return isWmValue(key, text[physical.len..]);
    }
    return isWmValue(key, text);
}

fn isWmValue(key: profile.WmKey, text: []const u8) bool {
    switch (key) {
        .density => {
            const density = std.fmt.parseInt(u32, text, 10) catch return false;
            return density > 0;
        },
        .size => {
            const separator = std.mem.indexOfScalar(u8, text, 'x') orelse return false;
            const width = std.fmt.parseInt(u32, text[0..separator], 10) catch return false;
            const height = std.fmt.parseInt(u32, text[separator + 1 ..], 10) catch return false;
            return width > 0 and height > 0;
        },
    }
}

fn isIsoTimestamp(text: []const u8) bool {
    if (text.len != 20) return false;
    if (text[4] != '-' or text[7] != '-' or text[10] != 'T' or
        text[13] != ':' or text[16] != ':' or text[19] != 'Z')
    {
        return false;
    }
    const year = std.fmt.parseInt(u16, text[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return false;
    const hour = std.fmt.parseInt(u8, text[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u8, text[14..16], 10) catch return false;
    const second = std.fmt.parseInt(u8, text[17..19], 10) catch return false;
    _ = year;
    return month >= 1 and month <= 12 and
        day >= 1 and day <= 31 and
        hour < 24 and minute < 60 and second < 60;
}

fn isPlainName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    if (std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "..")) return false;
    if (text[0] == '.') return false;
    for (text) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_' and char != '.') {
            return false;
        }
    }
    return true;
}

fn isToken(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |char| {
        if (!std.ascii.isAlphanumeric(char) and
            char != '.' and char != '_' and char != '-' and
            char != ':' and char != '/' and char != ',' and char != '+')
        {
            return false;
        }
    }
    return true;
}

fn isPackageName(text: []const u8) bool {
    if (text.len == 0 or text.len > 128) return false;
    for (text) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '.' and char != '_') return false;
    }
    return true;
}

fn isSettingNamespace(text: []const u8) bool {
    return std.mem.eql(u8, text, "global") or
        std.mem.eql(u8, text, "system") or
        std.mem.eql(u8, text, "secure");
}

fn isCompileMode(text: []const u8) bool {
    return std.mem.eql(u8, text, "speed") or
        std.mem.eql(u8, text, "speed-profile") or
        std.mem.eql(u8, text, "verify");
}

fn hasControlChars(text: []const u8) bool {
    for (text) |char| {
        if (char < 0x20 or char == 0x7f) return true;
    }
    return false;
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

const SnapshotJson = struct {
    schema: u32,
    created: []const u8,
    device: DeviceJson,
    profile: []const u8,
    entries: []const EntryJson,
};

const DeviceJson = struct {
    serial: []const u8,
    model: ?[]const u8 = null,
    sdk: ?u32 = null,
};

const EntryJson = struct {
    step_id: []const u8,
    kind: []const u8,
    target: []const u8,
    before: ?[]const u8 = null,
    after: ?[]const u8 = null,
    status: []const u8,
};

const testing = std.testing;

fn testDir() !struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn deinit(self: *@This()) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
} {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &buffer);
    const path = try testing.allocator.dupe(u8, buffer[0..length]);
    return .{ .tmp = tmp, .path = path };
}

fn sampleSnapshot(alloc: Allocator) !Snapshot {
    const entries = try alloc.alloc(Entry, 2);
    errdefer alloc.free(entries);
    entries[0] = .{
        .step_id = try alloc.dupe(u8, "anim-window"),
        .kind = .setting,
        .target = try alloc.dupe(u8, "global/window_animation_scale"),
        .before = try alloc.dupe(u8, "1.0"),
        .after = try alloc.dupe(u8, "0.5"),
        .status = .planned,
    };
    entries[1] = .{
        .step_id = try alloc.dupe(u8, "dexopt"),
        .kind = .compile,
        .target = try alloc.dupe(u8, "compile speed-profile (all)"),
        .status = .planned,
    };
    return .{
        .created = try alloc.dupe(u8, "2026-10-25T06:30:00Z"),
        .device = .{
            .serial = try alloc.dupe(u8, "FAKE123"),
            .model = try alloc.dupe(u8, "Redmi Note 5"),
            .sdk = 29,
        },
        .profile = try alloc.dupe(u8, "light"),
        .entries = entries,
    };
}

test "timestamps format as UTC ISO and compact file names" {
    const alloc = testing.allocator;
    const created_zero = try formatCreated(alloc, 0);
    defer alloc.free(created_zero);
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", created_zero);

    const created_epoch = try formatCreated(alloc, 1_700_000_000);
    defer alloc.free(created_epoch);
    try testing.expectEqualStrings("2023-11-14T22:13:20Z", created_epoch);

    const created_leap = try formatCreated(alloc, 951_782_400);
    defer alloc.free(created_leap);
    try testing.expectEqualStrings("2000-02-29T00:00:00Z", created_leap);

    const compact = try compactTimestamp(alloc, 1_698_215_400);
    defer alloc.free(compact);
    try testing.expectEqualStrings("20231025T063000Z", compact);

    try testing.expect(nowSeconds(testing.io) > 0);
}

test "serial slugs are filename safe" {
    const slug = try serialSlug(testing.allocator, "ABC:123/xy z");
    defer testing.allocator.free(slug);
    try testing.expectEqualStrings("ABC_123_xy_z", slug);
}

test "save writes, reads back, and latest finds the file" {
    const alloc = testing.allocator;
    var dir = try testDir();
    defer dir.deinit();

    var snapshot = try sampleSnapshot(alloc);
    defer snapshot.deinit(alloc);

    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(alloc);

    const path = try save(alloc, testing.io, dir.path, snapshot, 1_700_000_000, &diagnostic);
    defer alloc.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "FAKE123_20231114T221320Z.json"));

    var loaded = try load(alloc, testing.io, path, &diagnostic);
    defer loaded.deinit(alloc);
    try testing.expect(equals(snapshot, loaded));
    try testing.expectEqual(@as(usize, 2), loaded.entries.len);
    try testing.expectEqual(Status.planned, loaded.entries[0].status);
    try testing.expectEqualStrings("1.0", loaded.entries[0].before.?);
    try testing.expect(loaded.entries[1].before == null);

    const latest = (try latestPath(alloc, testing.io, dir.path, "FAKE123", &diagnostic)).?;
    defer alloc.free(latest);
    try testing.expectEqualStrings(path, latest);

    try testing.expect((try latestPath(alloc, testing.io, dir.path, "OTHER", &diagnostic)) == null);
}

test "save never overwrites an existing snapshot from the same second" {
    const alloc = testing.allocator;
    var dir = try testDir();
    defer dir.deinit();

    var snapshot = try sampleSnapshot(alloc);
    defer snapshot.deinit(alloc);

    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(alloc);

    const first = try save(alloc, testing.io, dir.path, snapshot, 1_700_000_000, &diagnostic);
    defer alloc.free(first);
    const second = try save(alloc, testing.io, dir.path, snapshot, 1_700_000_000, &diagnostic);
    defer alloc.free(second);

    try testing.expect(!std.mem.eql(u8, first, second));
    try testing.expect(std.mem.endsWith(u8, second, "_2.json"));

    const latest = (try latestPath(alloc, testing.io, dir.path, "FAKE123", &diagnostic)).?;
    defer alloc.free(latest);
    try testing.expectEqualStrings(second, latest);
}

test "latestPath returns null for a missing directory" {
    const dir_path = "definitely missing snapshot directory";
    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(testing.allocator);
    try testing.expect(
        (try latestPath(testing.allocator, testing.io, dir_path, "FAKE123", &diagnostic)) == null,
    );
}

test "parseTarget rebuilds readable targets" {
    const alloc = testing.allocator;
    var setting = try parseTarget(alloc, .setting, "global/window_animation_scale");
    defer profile.freeTarget(&setting, alloc);
    try testing.expectEqualStrings("global", setting.setting.namespace);
    try testing.expectEqualStrings("window_animation_scale", setting.setting.key);

    var compile = try parseTarget(alloc, .compile, "compile speed-profile (all)");
    defer profile.freeTarget(&compile, alloc);
    try testing.expectEqualStrings("speed-profile", compile.compile.mode);
    try testing.expectEqualStrings("all", compile.compile.scope);

    var appops = try parseTarget(alloc, .appops, "com.example.app RUN_IN_BACKGROUND");
    defer profile.freeTarget(&appops, alloc);
    try testing.expectEqualStrings("com.example.app", appops.appops.package);
    try testing.expectEqualStrings("RUN_IN_BACKGROUND", appops.appops.op);

    var wm = try parseTarget(alloc, .wm, "wm density");
    defer profile.freeTarget(&wm, alloc);
    try testing.expectEqual(profile.WmKey.density, wm.wm.key);

    try testing.expectError(
        error.InvalidTarget,
        parseTarget(alloc, .setting, "global/key; reboot"),
    );
    try testing.expectError(
        error.InvalidTarget,
        parseTarget(alloc, .package, "com.example/app"),
    );
    try testing.expectError(
        error.InvalidTarget,
        parseTarget(alloc, .wm, "wm fonts"),
    );
}

test "parse rejects unsafe or inconsistent snapshots" {
    const base =
        \\{
        \\  "schema": 1,
        \\  "created": "2026-10-25T06:30:00Z",
        \\  "device": { "serial": "FAKE123", "model": "Redmi", "sdk": 29 },
        \\  "profile": "light",
        \\  "entries": [
        \\    { "step_id": "anim-window", "kind": "setting",
        \\      "target": "global/window_animation_scale",
        \\      "before": "1.0", "after": "0.5", "status": "planned" }
        \\  ]
        \\}
    ;

    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(testing.allocator);
    var parsed = try parse(testing.allocator, "ok.json", base, &diagnostic);
    parsed.deinit(testing.allocator);

    const cases = [_]struct { text: []const u8, needle: []const u8 }{
        .{
            .text =
            \\{ "schema": 2, "created": "2026-10-25T06:30:00Z",
            \\  "device": { "serial": "A" }, "profile": "light", "entries": [] }
            ,
            .needle = "unsupported schema 2",
        },
        .{
            .text =
            \\{ "schema": 1, "created": "yesterday",
            \\  "device": { "serial": "A" }, "profile": "light", "entries": [] }
            ,
            .needle = "not an ISO-8601",
        },
        .{
            .text =
            \\{ "schema": 1, "created": "2026-10-25T06:30:00Z",
            \\  "device": { "serial": "A" }, "profile": "light",
            \\  "entries": [ { "step_id": "x", "kind": "setting",
            \\    "target": "global/k; reboot", "before": null, "after": "1",
            \\    "status": "planned" } ] }
            ,
            .needle = "not valid for kind 'setting'",
        },
        .{
            .text =
            \\{ "schema": 1, "created": "2026-10-25T06:30:00Z",
            \\  "device": { "serial": "A" }, "profile": "light",
            \\  "entries": [ { "step_id": "x", "kind": "maintenance",
            \\    "target": "idle maintenance", "before": null, "after": null,
            \\    "status": "planned" } ] }
            ,
            .needle = "maintenance steps have nothing to revert",
        },
        .{
            .text =
            \\{ "schema": 1, "created": "2026-10-25T06:30:00Z",
            \\  "device": { "serial": "A" }, "profile": "light",
            \\  "entries": [ { "step_id": "x", "kind": "package",
            \\    "target": "com.example.app", "before": "not installed",
            \\    "after": "disable", "status": "planned" } ] }
            ,
            .needle = "only an enabled package",
        },
        .{
            .text =
            \\{ "schema": 1, "created": "2026-10-25T06:30:00Z",
            \\  "device": { "serial": "A" }, "profile": "light",
            \\  "entries": [ { "step_id": "x", "kind": "wm",
            \\    "target": "wm density", "before": "480", "after": "wide",
            \\    "status": "planned" } ] }
            ,
            .needle = "field 'after' is not a wm value",
        },
        .{
            .text =
            \\{ "schema": 1, "created": "2026-10-25T06:30:00Z",
            \\  "device": { "serial": "A" }, "profile": "light",
            \\  "entries": [ { "step_id": "x", "kind": "compile",
            \\    "target": "compile speed-profile (all)", "before": "a",
            \\    "after": null, "status": "planned" } ] }
            ,
            .needle = "must be null for kind 'compile'",
        },
        .{
            .text =
            \\{ "schema": 1, "created": "2026-10-25T06:30:00Z",
            \\  "device": { "serial": "A" }, "profile": "light",
            \\  "entries": [ { "step_id": "x", "kind": "setting",
            \\    "target": "global/a", "before": null, "after": "1",
            \\    "status": "planned" },
            \\  { "step_id": "x", "kind": "setting",
            \\    "target": "global/b", "before": null, "after": "1",
            \\    "status": "planned" } ] }
            ,
            .needle = "duplicate step_id",
        },
        .{
            .text =
            \\{ "schema": 1, "created": "2026-10-25T06:30:00Z",
            \\  "device": { "serial": "A" }, "profile": "light",
            \\  "entries": [], "extra": true }
            ,
            .needle = "unknown field 'extra'",
        },
    };

    for (cases) |case| {
        var case_diagnostic: Diagnostic = .{};
        defer case_diagnostic.deinit(testing.allocator);
        try testing.expectError(
            error.InvalidSnapshot,
            parse(testing.allocator, "bad.json", case.text, &case_diagnostic),
        );
        try testing.expect(case_diagnostic.message != null);
        try testing.expect(std.mem.indexOf(u8, case_diagnostic.message.?, case.needle) != null);
    }
}

test "parse accepts a snapshot without entries and null before values" {
    const text =
        \\{
        \\  "schema": 1,
        \\  "created": "2026-10-25T06:30:00Z",
        \\  "device": { "serial": "FAKE123", "model": null, "sdk": null },
        \\  "profile": "light",
        \\  "entries": [
        \\    { "step_id": "anim-animator", "kind": "setting",
        \\      "target": "global/animator_duration_scale",
        \\      "before": null, "after": "0.5", "status": "applied" }
        \\  ]
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(testing.allocator);
    var snapshot = try parse(testing.allocator, "nulls.json", text, &diagnostic);
    defer snapshot.deinit(testing.allocator);

    try testing.expect(snapshot.device.model == null);
    try testing.expect(snapshot.device.sdk == null);
    try testing.expect(snapshot.entries[0].before == null);
    try testing.expectEqual(Status.applied, snapshot.entries[0].status);
}
