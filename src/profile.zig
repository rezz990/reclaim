//! Loads and validates profile JSON. Everything here is read-only: profiles
//! are data, and no device command is built or sent in this module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const max_profile_bytes = 256 * 1024;

pub const Kind = enum {
    setting,
    device_config,
    compile,
    appops,
    standby_bucket,
    wm,
    package,
    maintenance,

    pub fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .setting => "setting",
            .device_config => "device_config",
            .compile => "compile",
            .appops => "appops",
            .standby_bucket => "standby_bucket",
            .wm => "wm",
            .package => "package",
            .maintenance => "maintenance",
        };
    }
};

pub const Risk = enum {
    safe,
    caution,
    dangerous,

    pub fn label(risk: Risk) []const u8 {
        return switch (risk) {
            .safe => "safe",
            .caution => "caution",
            .dangerous => "dangerous",
        };
    }
};

pub const WmKey = enum {
    density,
    size,

    pub fn label(key: WmKey) []const u8 {
        return switch (key) {
            .density => "density",
            .size => "size",
        };
    }
};

pub const PackageAction = enum {
    disable,
    uninstall_user,

    pub fn label(action: PackageAction) []const u8 {
        return switch (action) {
            .disable => "disable",
            .uninstall_user => "uninstall-user",
        };
    }
};

pub const Bucket = enum {
    active,
    working_set,
    frequent,
    rare,
    restricted,
    never,

    pub fn label(bucket: Bucket) []const u8 {
        return switch (bucket) {
            .active => "active",
            .working_set => "working_set",
            .frequent => "frequent",
            .rare => "rare",
            .restricted => "restricted",
            .never => "never",
        };
    }
};

pub const Target = union(Kind) {
    setting: struct {
        namespace: []const u8,
        key: []const u8,
        value: []const u8,
    },
    device_config: struct {
        namespace: []const u8,
        key: []const u8,
        value: []const u8,
    },
    compile: struct {
        mode: []const u8,
        scope: []const u8,
    },
    appops: struct {
        package: []const u8,
        op: []const u8,
        mode: []const u8,
    },
    standby_bucket: struct {
        package: []const u8,
        bucket: Bucket,
    },
    wm: struct {
        key: WmKey,
        value: []const u8,
    },
    package: struct {
        package: []const u8,
        action: PackageAction,
    },
    maintenance: void,
};

pub const Step = struct {
    id: []const u8,
    risk: Risk,
    min_sdk: ?u32 = null,
    max_sdk: ?u32 = null,
    target: Target,

    pub fn kind(step: Step) Kind {
        return std.meta.activeTag(step.target);
    }

    pub fn deinit(step: *const Step, alloc: Allocator) void {
        alloc.free(step.id);
        freeTarget(&step.target, alloc);
    }
};

pub const Requires = struct {
    min_sdk: ?u32 = null,
    max_sdk: ?u32 = null,
    max_ram_mb: ?u64 = null,
};

pub const Profile = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    requires: Requires = .{},
    steps: []const Step,

    pub fn deinit(profile: *Profile, alloc: Allocator) void {
        alloc.free(profile.name);
        if (profile.description) |description| alloc.free(description);
        for (profile.steps) |*step| step.deinit(alloc);
        alloc.free(profile.steps);
        profile.* = undefined;
    }
};

pub const Diagnostic = struct {
    message: ?[]const u8 = null,

    pub fn deinit(diagnostic: *Diagnostic, alloc: Allocator) void {
        if (diagnostic.message) |message| alloc.free(message);
        diagnostic.* = .{};
    }
};

pub const LoadError = error{
    ProfileNotFound,
    InvalidProfile,
    OutOfMemory,
};

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
            "invalid profile '{s}': {s}",
            .{ ctx.source, detail },
        ) catch return error.OutOfMemory;
        return error.InvalidProfile;
    }
};

const Where = struct {
    index: ?usize = null,
    id: []const u8 = "",

    fn fail(where: Where, ctx: *Context, comptime format: []const u8, args: anytype) LoadError {
        const detail = std.fmt.allocPrint(ctx.alloc, format, args) catch
            return error.OutOfMemory;
        defer ctx.alloc.free(detail);
        if (where.index) |index| {
            if (where.id.len > 0) {
                return ctx.fail("step {d} (id '{s}'): {s}", .{ index + 1, where.id, detail });
            }
            return ctx.fail("step {d}: {s}", .{ index + 1, detail });
        }
        return ctx.fail("{s}", .{detail});
    }
};

/// Loads `profiles/<name>.json` from the working directory, then from the
/// directory that holds the executable.
pub fn load(
    alloc: Allocator,
    io: Io,
    name: []const u8,
    diagnostic: *Diagnostic,
) LoadError!Profile {
    diagnostic.* = .{};
    if (!isPlainName(name)) {
        diagnostic.message = std.fmt.allocPrint(
            alloc,
            "invalid profile name '{s}': use a plain name such as 'light'",
            .{name},
        ) catch return error.OutOfMemory;
        return error.InvalidProfile;
    }

    const file_name = std.fmt.allocPrint(alloc, "{s}.json", .{name}) catch
        return error.OutOfMemory;
    defer alloc.free(file_name);
    const relative = std.fs.path.join(alloc, &.{ "profiles", file_name }) catch
        return error.OutOfMemory;
    defer alloc.free(relative);

    switch (try readCandidate(alloc, io, std.Io.Dir.cwd(), relative)) {
        .text => |text| {
            defer alloc.free(text);
            return parse(alloc, relative, text, diagnostic);
        },
        .unreadable => |read_error| {
            diagnostic.message = std.fmt.allocPrint(
                alloc,
                "could not read '{s}': {s}",
                .{ relative, @errorName(read_error) },
            ) catch return error.OutOfMemory;
            return error.InvalidProfile;
        },
        .missing => {},
    }

    switch (try readNextToExecutable(alloc, io, relative)) {
        .text => |text| {
            defer alloc.free(text);
            return parse(alloc, relative, text, diagnostic);
        },
        .unreadable => |read_error| {
            diagnostic.message = std.fmt.allocPrint(
                alloc,
                "could not read '{s}' next to the executable: {s}",
                .{ relative, @errorName(read_error) },
            ) catch return error.OutOfMemory;
            return error.InvalidProfile;
        },
        .missing => {},
    }

    diagnostic.message = std.fmt.allocPrint(
        alloc,
        "profile '{s}' was not found in profiles/ next to the working directory or the executable",
        .{name},
    ) catch return error.OutOfMemory;
    return error.ProfileNotFound;
}

const Candidate = union(enum) {
    text: []u8,
    missing,
    unreadable: anyerror,
};

fn readCandidate(
    alloc: Allocator,
    io: Io,
    dir: std.Io.Dir,
    path: []const u8,
) Allocator.Error!Candidate {
    const text = dir.readFileAlloc(io, path, alloc, .limited(max_profile_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotDir => return .missing,
        else => return .{ .unreadable = err },
    };
    return .{ .text = text };
}

fn readNextToExecutable(
    alloc: Allocator,
    io: Io,
    relative: []const u8,
) Allocator.Error!Candidate {
    const executable = std.process.executablePathAlloc(io, alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .missing,
    };
    defer alloc.free(executable);

    const directory_path = std.fs.path.dirname(executable) orelse return .missing;
    var directory = std.Io.Dir.openDirAbsolute(io, directory_path, .{}) catch
        return .missing;
    defer directory.close(io);

    return readCandidate(alloc, io, directory, relative);
}

pub fn parse(
    alloc: Allocator,
    source: []const u8,
    text: []const u8,
    diagnostic: *Diagnostic,
) LoadError!Profile {
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
    try rejectUnknown(
        &ctx,
        root,
        &.{ "schema", "name", "description", "requires", "steps" },
        .{},
    );

    const schema = switch (root.get("schema") orelse
        return ctx.fail("field 'schema' is required", .{})) {
        .integer => |value| value,
        else => return ctx.fail("field 'schema' must be an integer", .{}),
    };
    if (schema != 1) {
        return ctx.fail("unsupported schema {d}; this build understands schema 1", .{schema});
    }

    const name = try requiredText(&ctx, root, "name", .{}, 64, false);
    if (name.len == 0) {
        alloc.free(name);
        return ctx.fail("field 'name' must not be empty", .{});
    }
    errdefer alloc.free(name);

    const description = try optionalDescription(&ctx, root, .{});
    errdefer if (description) |value| alloc.free(value);

    const requires = try parseRequires(&ctx, root);
    const steps = try parseSteps(&ctx, root);

    return .{
        .name = name,
        .description = description,
        .requires = requires,
        .steps = steps,
    };
}

fn parseSteps(ctx: *Context, root: std.json.ObjectMap) LoadError![]Step {
    const steps_value = root.get("steps") orelse
        return ctx.fail("field 'steps' is required", .{});
    const items = switch (steps_value) {
        .array => |array| array.items,
        else => return ctx.fail("field 'steps' must be an array", .{}),
    };
    if (items.len == 0) {
        return ctx.fail("field 'steps' must contain at least one step", .{});
    }

    var steps: std.ArrayList(Step) = .empty;
    errdefer {
        for (steps.items) |*step| step.deinit(ctx.alloc);
        steps.deinit(ctx.alloc);
    }

    for (items, 0..) |item, index| {
        const step = try parseStep(ctx, item, index);
        steps.append(ctx.alloc, step) catch |err| {
            var discarded = step;
            discarded.deinit(ctx.alloc);
            return err;
        };
    }

    for (steps.items, 0..) |step, index| {
        for (steps.items[index + 1 ..]) |other| {
            if (std.mem.eql(u8, step.id, other.id)) {
                return ctx.fail(
                    "step {d} (id '{s}'): duplicate id",
                    .{ index + 1, step.id },
                );
            }
        }
    }

    return steps.toOwnedSlice(ctx.alloc);
}

fn parseStep(ctx: *Context, item: std.json.Value, index: usize) LoadError!Step {
    var where: Where = .{ .index = index };
    const object = switch (item) {
        .object => |value| value,
        else => return where.fail(ctx, "must be a JSON object", .{}),
    };

    const id = try requiredText(ctx, object, "id", where, 64, true);
    errdefer ctx.alloc.free(id);
    where.id = id;

    const kind = try parseKind(ctx, object, where);
    const risk = try parseRisk(ctx, object, where);
    try rejectUnknownStep(ctx, object, kind, where);

    const min_sdk = try optionalU32(ctx, object, "min_sdk", where);
    const max_sdk = try optionalU32(ctx, object, "max_sdk", where);
    if (min_sdk != null and max_sdk != null and min_sdk.? > max_sdk.?) {
        return where.fail(ctx, "field 'min_sdk' must not be greater than 'max_sdk'", .{});
    }

    const target = try parseTarget(ctx, object, kind, where);
    errdefer freeTarget(&target, ctx.alloc);

    return .{
        .id = id,
        .risk = risk,
        .min_sdk = min_sdk,
        .max_sdk = max_sdk,
        .target = target,
    };
}

fn parseKind(ctx: *Context, object: std.json.ObjectMap, where: Where) LoadError!Kind {
    const value = object.get("kind") orelse
        return where.fail(ctx, "field 'kind' is required", .{});
    const text = switch (value) {
        .string => |string| string,
        else => return where.fail(ctx, "field 'kind' must be a string", .{}),
    };
    if (std.mem.eql(u8, text, "setting")) return .setting;
    if (std.mem.eql(u8, text, "device_config")) return .device_config;
    if (std.mem.eql(u8, text, "compile")) return .compile;
    if (std.mem.eql(u8, text, "appops")) return .appops;
    if (std.mem.eql(u8, text, "standby_bucket")) return .standby_bucket;
    if (std.mem.eql(u8, text, "wm")) return .wm;
    if (std.mem.eql(u8, text, "package")) return .package;
    if (std.mem.eql(u8, text, "maintenance")) return .maintenance;
    return where.fail(ctx, "unknown kind '{s}'", .{text});
}

fn parseRisk(ctx: *Context, object: std.json.ObjectMap, where: Where) LoadError!Risk {
    const value = object.get("risk") orelse
        return where.fail(ctx, "field 'risk' is required", .{});
    const text = switch (value) {
        .string => |string| string,
        else => return where.fail(ctx, "field 'risk' must be a string", .{}),
    };
    if (std.mem.eql(u8, text, "safe")) return .safe;
    if (std.mem.eql(u8, text, "caution")) return .caution;
    if (std.mem.eql(u8, text, "dangerous")) return .dangerous;
    return where.fail(ctx, "field 'risk' must be safe, caution, or dangerous", .{});
}

fn parseTarget(
    ctx: *Context,
    object: std.json.ObjectMap,
    kind: Kind,
    where: Where,
) LoadError!Target {
    switch (kind) {
        .setting => {
            const namespace = try requiredToken(ctx, object, "namespace", where, 32);
            errdefer ctx.alloc.free(namespace);
            const key = try requiredToken(ctx, object, "key", where, 128);
            errdefer ctx.alloc.free(key);
            const value = try requiredToken(ctx, object, "value", where, 128);
            errdefer ctx.alloc.free(value);
            if (!isSettingNamespace(namespace)) {
                return where.fail(
                    ctx,
                    "field 'namespace' must be global, system, or secure",
                    .{},
                );
            }
            return .{ .setting = .{
                .namespace = namespace,
                .key = key,
                .value = value,
            } };
        },
        .device_config => {
            const namespace = try requiredToken(ctx, object, "namespace", where, 64);
            errdefer ctx.alloc.free(namespace);
            const key = try requiredToken(ctx, object, "key", where, 128);
            errdefer ctx.alloc.free(key);
            const value = try requiredToken(ctx, object, "value", where, 128);
            errdefer ctx.alloc.free(value);
            return .{ .device_config = .{
                .namespace = namespace,
                .key = key,
                .value = value,
            } };
        },
        .compile => {
            const mode = try requiredToken(ctx, object, "mode", where, 32);
            errdefer ctx.alloc.free(mode);
            const scope = try requiredToken(ctx, object, "scope", where, 128);
            errdefer ctx.alloc.free(scope);
            if (!isCompileMode(mode)) {
                return where.fail(
                    ctx,
                    "field 'mode' must be speed, speed-profile, or verify",
                    .{},
                );
            }
            return .{ .compile = .{ .mode = mode, .scope = scope } };
        },
        .appops => {
            const package = try requiredPackage(ctx, object, "package", where, 128);
            errdefer ctx.alloc.free(package);
            const op = try requiredToken(ctx, object, "op", where, 64);
            errdefer ctx.alloc.free(op);
            const mode = try requiredToken(ctx, object, "mode", where, 32);
            errdefer ctx.alloc.free(mode);
            return .{ .appops = .{ .package = package, .op = op, .mode = mode } };
        },
        .standby_bucket => {
            const package = try requiredPackage(ctx, object, "package", where, 128);
            errdefer ctx.alloc.free(package);
            const bucket_text = try requiredToken(ctx, object, "bucket", where, 16);
            errdefer ctx.alloc.free(bucket_text);
            const bucket = parseBucket(bucket_text) orelse
                return where.fail(ctx, "field 'bucket' is not a known standby bucket", .{});
            ctx.alloc.free(bucket_text);
            return .{ .standby_bucket = .{ .package = package, .bucket = bucket } };
        },
        .wm => {
            const key_text = try requiredToken(ctx, object, "key", where, 16);
            errdefer ctx.alloc.free(key_text);
            const value = try requiredToken(ctx, object, "value", where, 32);
            errdefer ctx.alloc.free(value);
            const key: WmKey = if (std.mem.eql(u8, key_text, "density"))
                .density
            else if (std.mem.eql(u8, key_text, "size"))
                .size
            else
                return where.fail(ctx, "field 'key' must be density or size", .{});
            if (!validWmValue(key, value)) {
                return where.fail(
                    ctx,
                    "field 'value' must be a positive density or a WIDTHxHEIGHT size",
                    .{},
                );
            }
            ctx.alloc.free(key_text);
            return .{ .wm = .{ .key = key, .value = value } };
        },
        .package => {
            const package = try requiredPackage(ctx, object, "package", where, 128);
            errdefer ctx.alloc.free(package);
            const action_text = try requiredToken(ctx, object, "action", where, 32);
            errdefer ctx.alloc.free(action_text);
            const action: PackageAction = if (std.mem.eql(u8, action_text, "disable"))
                .disable
            else if (std.mem.eql(u8, action_text, "uninstall-user"))
                .uninstall_user
            else
                return where.fail(ctx, "field 'action' must be disable or uninstall-user", .{});
            ctx.alloc.free(action_text);
            return .{ .package = .{ .package = package, .action = action } };
        },
        .maintenance => return .{ .maintenance = {} },
    }
}

fn parseRequires(ctx: *Context, root: std.json.ObjectMap) LoadError!Requires {
    const value = root.get("requires") orelse return .{};
    const object = switch (value) {
        .object => |map| map,
        else => return ctx.fail("field 'requires' must be an object", .{}),
    };
    try rejectUnknown(ctx, object, &.{ "min_sdk", "max_sdk", "max_ram_mb" }, .{});

    const min_sdk = try optionalU32(ctx, object, "min_sdk", .{});
    const max_sdk = try optionalU32(ctx, object, "max_sdk", .{});
    if (min_sdk != null and max_sdk != null and min_sdk.? > max_sdk.?) {
        return ctx.fail("field 'requires.min_sdk' must not be greater than 'requires.max_sdk'", .{});
    }

    const max_ram_mb: ?u64 = if (object.get("max_ram_mb")) |raw| switch (raw) {
        .integer => |number| blk: {
            if (number <= 0) {
                return ctx.fail(
                    "field 'requires.max_ram_mb' must be greater than zero",
                    .{},
                );
            }
            break :blk @as(u64, @intCast(number));
        },
        else => return ctx.fail("field 'requires.max_ram_mb' must be an integer", .{}),
    } else null;

    return .{
        .min_sdk = min_sdk,
        .max_sdk = max_sdk,
        .max_ram_mb = max_ram_mb,
    };
}

fn rejectUnknownStep(
    ctx: *Context,
    object: std.json.ObjectMap,
    kind: Kind,
    where: Where,
) LoadError!void {
    const allowed: []const []const u8 = switch (kind) {
        .setting => &.{
            "id", "kind", "risk", "min_sdk", "max_sdk", "namespace", "key", "value",
        },
        .device_config => &.{
            "id", "kind", "risk", "min_sdk", "max_sdk", "namespace", "key", "value",
        },
        .compile => &.{
            "id", "kind", "risk", "min_sdk", "max_sdk", "mode", "scope",
        },
        .appops => &.{
            "id", "kind", "risk", "min_sdk", "max_sdk", "package", "op", "mode",
        },
        .standby_bucket => &.{
            "id", "kind", "risk", "min_sdk", "max_sdk", "package", "bucket",
        },
        .wm => &.{
            "id", "kind", "risk", "min_sdk", "max_sdk", "key", "value",
        },
        .package => &.{
            "id", "kind", "risk", "min_sdk", "max_sdk", "package", "action",
        },
        .maintenance => &.{
            "id", "kind", "risk", "min_sdk", "max_sdk",
        },
    };
    try rejectUnknown(ctx, object, allowed, where);
}

fn rejectUnknown(
    ctx: *Context,
    object: std.json.ObjectMap,
    allowed: []const []const u8,
    where: Where,
) LoadError!void {
    for (object.keys()) |key| {
        if (!contains(allowed, key)) {
            return where.fail(ctx, "unknown field '{s}'", .{key});
        }
    }
}

fn requiredText(
    ctx: *Context,
    object: std.json.ObjectMap,
    field: []const u8,
    where: Where,
    max_len: usize,
    token: bool,
) LoadError![]const u8 {
    const value = object.get(field) orelse
        return where.fail(ctx, "field '{s}' is required", .{field});
    const text = switch (value) {
        .string => |string| string,
        else => return where.fail(ctx, "field '{s}' must be a string", .{field}),
    };
    if (text.len == 0) {
        return where.fail(ctx, "field '{s}' must not be empty", .{field});
    }
    if (text.len > max_len) {
        return where.fail(
            ctx,
            "field '{s}' must be at most {d} bytes",
            .{ field, max_len },
        );
    }
    if (hasControlChars(text)) {
        return where.fail(ctx, "field '{s}' contains control characters", .{field});
    }
    if (token and !isSafeToken(text)) {
        return where.fail(ctx, "field '{s}' contains unsupported characters", .{field});
    }
    return ctx.alloc.dupe(u8, text) catch error.OutOfMemory;
}

fn requiredToken(
    ctx: *Context,
    object: std.json.ObjectMap,
    field: []const u8,
    where: Where,
    max_len: usize,
) LoadError![]const u8 {
    return requiredText(ctx, object, field, where, max_len, true);
}

fn requiredPackage(
    ctx: *Context,
    object: std.json.ObjectMap,
    field: []const u8,
    where: Where,
    max_len: usize,
) LoadError![]const u8 {
    const text = try requiredText(ctx, object, field, where, max_len, false);
    if (!isPackageName(text)) {
        ctx.alloc.free(text);
        return where.fail(ctx, "field '{s}' is not a valid package name", .{field});
    }
    return text;
}

fn optionalDescription(
    ctx: *Context,
    object: std.json.ObjectMap,
    where: Where,
) LoadError!?[]const u8 {
    const value = object.get("description") orelse return null;
    const text = switch (value) {
        .string => |string| string,
        else => return where.fail(ctx, "field 'description' must be a string", .{}),
    };
    if (text.len > 512) {
        return where.fail(ctx, "field 'description' must be at most 512 bytes", .{});
    }
    if (hasControlChars(text)) {
        return where.fail(ctx, "field 'description' contains control characters", .{});
    }
    return ctx.alloc.dupe(u8, text) catch error.OutOfMemory;
}

fn optionalU32(
    ctx: *Context,
    object: std.json.ObjectMap,
    field: []const u8,
    where: Where,
) LoadError!?u32 {
    const value = object.get(field) orelse return null;
    const number = switch (value) {
        .integer => |integer| integer,
        else => return where.fail(ctx, "field '{s}' must be an integer", .{field}),
    };
    if (number < 0) {
        return where.fail(ctx, "field '{s}' must not be negative", .{field});
    }
    if (number > std.math.maxInt(u32)) {
        return where.fail(ctx, "field '{s}' is out of range", .{field});
    }
    return @intCast(number);
}

fn freeTarget(target: *const Target, alloc: Allocator) void {
    switch (target.*) {
        .setting => |value| {
            alloc.free(value.namespace);
            alloc.free(value.key);
            alloc.free(value.value);
        },
        .device_config => |value| {
            alloc.free(value.namespace);
            alloc.free(value.key);
            alloc.free(value.value);
        },
        .compile => |value| {
            alloc.free(value.mode);
            alloc.free(value.scope);
        },
        .appops => |value| {
            alloc.free(value.package);
            alloc.free(value.op);
            alloc.free(value.mode);
        },
        .standby_bucket => |value| alloc.free(value.package),
        .wm => |value| alloc.free(value.value),
        .package => |value| alloc.free(value.package),
        .maintenance => {},
    }
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn isPlainName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (name[0] == '.') return false;
    for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_' and char != '.') {
            return false;
        }
    }
    return true;
}

fn hasControlChars(text: []const u8) bool {
    for (text) |char| {
        if (char < 0x20 or char == 0x7f) return true;
    }
    return false;
}

/// Profile strings become adb shell arguments in later phases, so values are
/// limited to characters that never need shell quoting.
fn isSafeToken(text: []const u8) bool {
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
    if (text.len == 0) return false;
    for (text) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '.' and char != '_') {
            return false;
        }
    }
    return true;
}

fn isSettingNamespace(namespace: []const u8) bool {
    return std.mem.eql(u8, namespace, "global") or
        std.mem.eql(u8, namespace, "system") or
        std.mem.eql(u8, namespace, "secure");
}

fn isCompileMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "speed") or
        std.mem.eql(u8, mode, "speed-profile") or
        std.mem.eql(u8, mode, "verify");
}

fn parseBucket(text: []const u8) ?Bucket {
    if (std.mem.eql(u8, text, "active")) return .active;
    if (std.mem.eql(u8, text, "working_set")) return .working_set;
    if (std.mem.eql(u8, text, "frequent")) return .frequent;
    if (std.mem.eql(u8, text, "rare")) return .rare;
    if (std.mem.eql(u8, text, "restricted")) return .restricted;
    if (std.mem.eql(u8, text, "never")) return .never;
    return null;
}

fn validWmValue(key: WmKey, value: []const u8) bool {
    switch (key) {
        .density => {
            const density = std.fmt.parseInt(u32, value, 10) catch return false;
            return density > 0;
        },
        .size => {
            const separator = std.mem.indexOfScalar(u8, value, 'x') orelse return false;
            const width = std.fmt.parseInt(u32, value[0..separator], 10) catch return false;
            const height = std.fmt.parseInt(u32, value[separator + 1 ..], 10) catch return false;
            return width > 0 and height > 0;
        },
    }
}

const testing = std.testing;

fn expectInvalid(text: []const u8, needle: []const u8) !void {
    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(testing.allocator);

    try testing.expectError(
        error.InvalidProfile,
        parse(testing.allocator, "test.json", text, &diagnostic),
    );
    try testing.expect(diagnostic.message != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message.?, needle) != null);
}

test "kind, risk, and label names stay stable" {
    try testing.expectEqualStrings("setting", Kind.setting.label());
    try testing.expectEqualStrings("device_config", Kind.device_config.label());
    try testing.expectEqualStrings("standby_bucket", Kind.standby_bucket.label());
    try testing.expectEqualStrings("maintenance", Kind.maintenance.label());
    try testing.expectEqualStrings("dangerous", Risk.dangerous.label());
    try testing.expectEqualStrings("uninstall-user", PackageAction.uninstall_user.label());
    try testing.expectEqualStrings("working_set", Bucket.working_set.label());
    try testing.expectEqualStrings("density", WmKey.density.label());
}

test "parse accepts every step kind" {
    const text =
        \\{
        \\  "schema": 1,
        \\  "name": "kitchen-sink",
        \\  "description": "Every kind",
        \\  "requires": { "min_sdk": 21, "max_sdk": 34, "max_ram_mb": 4096 },
        \\  "steps": [
        \\    { "id": "s", "kind": "setting", "namespace": "global", "key": "window_animation_scale", "value": "0.5", "risk": "safe", "min_sdk": 17 },
        \\    { "id": "d", "kind": "device_config", "namespace": "activity_manager", "key": "max_phantom_processes", "value": "2147483647", "risk": "caution", "min_sdk": 31 },
        \\    { "id": "c", "kind": "compile", "mode": "speed-profile", "scope": "all", "risk": "safe", "min_sdk": 24 },
        \\    { "id": "a", "kind": "appops", "package": "com.example.app", "op": "RUN_IN_BACKGROUND", "mode": "ignore", "risk": "caution", "min_sdk": 26 },
        \\    { "id": "b", "kind": "standby_bucket", "package": "com.example.app", "bucket": "restricted", "risk": "caution", "min_sdk": 28 },
        \\    { "id": "w", "kind": "wm", "key": "density", "value": "480", "risk": "caution", "min_sdk": 17 },
        \\    { "id": "p", "kind": "package", "package": "com.example.app", "action": "uninstall-user", "risk": "caution", "min_sdk": 24 },
        \\    { "id": "m", "kind": "maintenance", "risk": "safe", "min_sdk": 23 }
        \\  ]
        \\}
    ;

    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(testing.allocator);
    var parsed = try parse(testing.allocator, "kitchen.json", text, &diagnostic);
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("kitchen-sink", parsed.name);
    try testing.expectEqualStrings("Every kind", parsed.description.?);
    try testing.expectEqual(@as(?u32, 21), parsed.requires.min_sdk);
    try testing.expectEqual(@as(?u32, 34), parsed.requires.max_sdk);
    try testing.expectEqual(@as(?u64, 4096), parsed.requires.max_ram_mb);
    try testing.expectEqual(@as(usize, 8), parsed.steps.len);

    try testing.expectEqual(Kind.setting, parsed.steps[0].kind());
    try testing.expectEqualStrings("global", parsed.steps[0].target.setting.namespace);
    try testing.expectEqualStrings("window_animation_scale", parsed.steps[0].target.setting.key);
    try testing.expectEqualStrings("0.5", parsed.steps[0].target.setting.value);
    try testing.expectEqual(Risk.caution, parsed.steps[1].risk);
    try testing.expectEqualStrings("speed-profile", parsed.steps[2].target.compile.mode);
    try testing.expectEqualStrings("all", parsed.steps[2].target.compile.scope);
    try testing.expectEqualStrings("RUN_IN_BACKGROUND", parsed.steps[3].target.appops.op);
    try testing.expectEqual(Bucket.restricted, parsed.steps[4].target.standby_bucket.bucket);
    try testing.expectEqual(WmKey.density, parsed.steps[5].target.wm.key);
    try testing.expectEqual(PackageAction.uninstall_user, parsed.steps[6].target.package.action);
    try testing.expectEqual(Kind.maintenance, parsed.steps[7].kind());
}

test "parse accepts a profile without optional fields" {
    const text =
        \\{
        \\  "schema": 1,
        \\  "name": "minimal",
        \\  "steps": [
        \\    { "id": "m", "kind": "maintenance", "risk": "safe" }
        \\  ]
        \\}
    ;
    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(testing.allocator);
    var parsed = try parse(testing.allocator, "minimal.json", text, &diagnostic);
    defer parsed.deinit(testing.allocator);

    try testing.expect(parsed.description == null);
    try testing.expectEqual(Requires{}, parsed.requires);
    try testing.expectEqual(@as(usize, 1), parsed.steps.len);
}

test "parse rejects an unsupported schema" {
    const text =
        \\{ "schema": 2, "name": "x", "steps": [
        \\  { "id": "m", "kind": "maintenance", "risk": "safe" } ] }
    ;
    try expectInvalid(text, "unsupported schema 2");
}

test "parse rejects malformed JSON and a non-object root" {
    try expectInvalid("{", "invalid JSON");
    try expectInvalid("[]", "root must be a JSON object");
}

test "parse names the field and step in diagnostics" {
    const missing_namespace =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "anim-window", "kind": "setting", "key": "window_animation_scale", "value": "0.5", "risk": "safe" } ] }
    ;
    try expectInvalid(missing_namespace, "step 1 (id 'anim-window'): field 'namespace' is required");

    const bad_risk =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "m", "kind": "maintenance", "risk": "spicy" } ] }
    ;
    try expectInvalid(bad_risk, "step 1 (id 'm'): field 'risk' must be safe, caution, or dangerous");

    const bad_kind =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "m", "kind": "reboot", "risk": "safe" } ] }
    ;
    try expectInvalid(bad_kind, "unknown kind 'reboot'");
}

test "parse rejects duplicate and unsafe step ids" {
    const duplicate =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "m", "kind": "maintenance", "risk": "safe" },
        \\  { "id": "m", "kind": "maintenance", "risk": "safe" } ] }
    ;
    try expectInvalid(duplicate, "duplicate id");

    const unsafe =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "bad id", "kind": "maintenance", "risk": "safe" } ] }
    ;
    try expectInvalid(unsafe, "field 'id' contains unsupported characters");
}

test "parse rejects missing required fields" {
    const no_schema =
        \\{ "name": "x", "steps": [{ "id": "m", "kind": "maintenance", "risk": "safe" }] }
    ;
    try expectInvalid(no_schema, "field 'schema' is required");

    const no_name =
        \\{ "schema": 1, "steps": [{ "id": "m", "kind": "maintenance", "risk": "safe" }] }
    ;
    try expectInvalid(no_name, "field 'name' is required");

    const no_steps =
        \\{ "schema": 1, "name": "x" }
    ;
    try expectInvalid(no_steps, "field 'steps' is required");

    const empty_steps =
        \\{ "schema": 1, "name": "x", "steps": [] }
    ;
    try expectInvalid(empty_steps, "must contain at least one step");
}

test "parse rejects unknown fields so typos are not ignored" {
    const unknown_step =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "m", "kind": "maintenance", "risk": "safe", "min-sdk": 23 } ] }
    ;
    try expectInvalid(unknown_step, "unknown field 'min-sdk'");

    const unknown_top =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "m", "kind": "maintenance", "risk": "safe" } ], "extra": true }
    ;
    try expectInvalid(unknown_top, "unknown field 'extra'");
}

test "parse validates per-kind fields" {
    const bad_namespace =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "s", "kind": "setting", "namespace": "hidden", "key": "k", "value": "v", "risk": "safe" } ] }
    ;
    try expectInvalid(bad_namespace, "field 'namespace' must be global, system, or secure");

    const bad_mode =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "c", "kind": "compile", "mode": "fast", "scope": "all", "risk": "safe" } ] }
    ;
    try expectInvalid(bad_mode, "field 'mode' must be speed, speed-profile, or verify");

    const bad_bucket =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "b", "kind": "standby_bucket", "package": "com.example.app", "bucket": "warm", "risk": "caution" } ] }
    ;
    try expectInvalid(bad_bucket, "field 'bucket' is not a known standby bucket");

    const bad_action =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "p", "kind": "package", "package": "com.example.app", "action": "remove", "risk": "caution" } ] }
    ;
    try expectInvalid(bad_action, "field 'action' must be disable or uninstall-user");

    const bad_package =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "p", "kind": "package", "package": "com.example/app", "action": "disable", "risk": "caution" } ] }
    ;
    try expectInvalid(bad_package, "field 'package' is not a valid package name");

    const bad_wm =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "w", "kind": "wm", "key": "size", "value": "wide", "risk": "caution" } ] }
    ;
    try expectInvalid(bad_wm, "field 'value' must be a positive density or a WIDTHxHEIGHT size");
}

test "parse validates step and profile SDK ranges" {
    const step_range =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "m", "kind": "maintenance", "risk": "safe", "min_sdk": 30, "max_sdk": 29 } ] }
    ;
    try expectInvalid(step_range, "field 'min_sdk' must not be greater than 'max_sdk'");

    const profile_range =
        \\{ "schema": 1, "name": "x", "requires": { "min_sdk": 30, "max_sdk": 29 }, "steps": [
        \\  { "id": "m", "kind": "maintenance", "risk": "safe" } ] }
    ;
    try expectInvalid(profile_range, "field 'requires.min_sdk' must not be greater than 'requires.max_sdk'");

    const bad_ram =
        \\{ "schema": 1, "name": "x", "requires": { "max_ram_mb": 0 }, "steps": [
        \\  { "id": "m", "kind": "maintenance", "risk": "safe" } ] }
    ;
    try expectInvalid(bad_ram, "field 'requires.max_ram_mb' must be greater than zero");
}

test "parse rejects shell metacharacters in values" {
    const text =
        \\{ "schema": 1, "name": "x", "steps": [
        \\  { "id": "s", "kind": "setting", "namespace": "global", "key": "k", "value": "0.5; reboot", "risk": "safe" } ] }
    ;
    try expectInvalid(text, "field 'value' contains unsupported characters");
}

test "load reads the built-in light profile from the working directory" {
    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(testing.allocator);

    var loaded = try load(testing.allocator, std.testing.io, "light", &diagnostic);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualStrings("light", loaded.name);
    try testing.expectEqual(@as(?u32, 21), loaded.requires.min_sdk);
    try testing.expectEqual(@as(?u64, 3072), loaded.requires.max_ram_mb);
    try testing.expectEqual(@as(usize, 5), loaded.steps.len);
    try testing.expectEqualStrings("anim-window", loaded.steps[0].id);
    try testing.expectEqualStrings("idle-maint", loaded.steps[4].id);
}

test "load reads the built-in balanced profile with phantom steps" {
    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(testing.allocator);

    var loaded = try load(testing.allocator, std.testing.io, "balanced", &diagnostic);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(?u64, 4096), loaded.requires.max_ram_mb);
    try testing.expectEqual(@as(usize, 7), loaded.steps.len);
    try testing.expectEqual(Kind.device_config, loaded.steps[5].kind());
    try testing.expectEqual(@as(?u32, 31), loaded.steps[5].min_sdk);
    try testing.expectEqualStrings("phantom-monitor", loaded.steps[6].id);
}

test "load rejects unsafe names and missing profiles" {
    var unsafe: Diagnostic = .{};
    defer unsafe.deinit(testing.allocator);
    try testing.expectError(
        error.InvalidProfile,
        load(testing.allocator, std.testing.io, "../light", &unsafe),
    );
    try testing.expect(std.mem.indexOf(u8, unsafe.message.?, "invalid profile name") != null);

    var missing: Diagnostic = .{};
    defer missing.deinit(testing.allocator);
    try testing.expectError(
        error.ProfileNotFound,
        load(testing.allocator, std.testing.io, "definitely-not-a-profile", &missing),
    );
    try testing.expect(std.mem.indexOf(u8, missing.message.?, "was not found") != null);
}
