//! The only module allowed to change device state. Apply writes and verifies a
//! snapshot before sending anything, executes every step as one adb batch, and
//! checks the result afterwards. Revert reads a snapshot and restores the
//! recorded values. Nothing here prints.

const std = @import("std");
const adb = @import("adb.zig");
const device = @import("device.zig");
const plan = @import("plan.zig");
const profile = @import("profile.zig");
const snapshot = @import("snapshot.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Mode = enum {
    apply,
    revert,

    pub fn label(mode: Mode) []const u8 {
        return switch (mode) {
            .apply => "apply",
            .revert => "revert",
        };
    }
};

pub const Status = enum {
    planned,
    applied,
    unchanged,
    reverted,
    skipped,
    failed,

    pub fn label(status: Status) []const u8 {
        return switch (status) {
            .planned => "planned",
            .applied => "applied",
            .unchanged => "unchanged",
            .reverted => "reverted",
            .skipped => "skipped",
            .failed => "failed",
        };
    }
};

pub const Dirs = struct {
    snapshot_dir: []const u8,
    log_dir: []const u8,
};

pub const ApplyOptions = struct {
    yes: bool = false,
    skip: []const []const u8 = &.{},
    only: ?[]const u8 = null,
};

pub const RevertOptions = struct {
    yes: bool = false,
};

pub const Step = struct {
    id: []const u8,
    kind: profile.Kind,
    risk: ?profile.Risk = null,
    target: []const u8,
    before: ?[]const u8 = null,
    after: ?[]const u8 = null,
    status: Status = .planned,
    verified: ?bool = null,
    exit_code: ?u8 = null,
    reason: ?[]const u8 = null,

    pub fn deinit(step: *Step, alloc: Allocator) void {
        alloc.free(step.id);
        alloc.free(step.target);
        if (step.before) |before| alloc.free(before);
        if (step.after) |after| alloc.free(after);
        if (step.reason) |reason| alloc.free(reason);
        step.* = undefined;
    }
};

pub const Outcome = struct {
    mode: Mode,
    profile: []const u8,
    device: []const u8,
    sdk: ?u32 = null,
    ram_total_mb: ?u64 = null,
    created: ?[]const u8 = null,
    dry_run: bool,
    snapshot_path: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    aborted: bool = false,
    steps: []Step,

    pub fn deinit(outcome: *Outcome, alloc: Allocator) void {
        alloc.free(outcome.profile);
        alloc.free(outcome.device);
        if (outcome.created) |created| alloc.free(created);
        if (outcome.snapshot_path) |path| alloc.free(path);
        if (outcome.log_path) |path| alloc.free(path);
        for (outcome.steps) |*step| step.deinit(alloc);
        alloc.free(outcome.steps);
        outcome.* = undefined;
    }

    pub fn count(outcome: Outcome, status: Status) usize {
        var total: usize = 0;
        for (outcome.steps) |step| {
            if (step.status == status) total += 1;
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

pub const Error = error{
    BlockedByDenylist,
    UnknownSelection,
    SnapshotMismatch,
    InvalidTarget,
    SnapshotWriteFailed,
    LogFailed,
    AdbFailed,
    OutOfMemory,
};

const Candidate = struct {
    step_index: usize,
    command: ?[]u8 = null,

    fn deinit(candidate: *Candidate, alloc: Allocator) void {
        if (candidate.command) |command| alloc.free(command);
        candidate.* = undefined;
    }
};

pub fn apply(
    alloc: Allocator,
    io: Io,
    adb_path: adb.AdbPath,
    fingerprint: device.Fingerprint,
    built: plan.Plan,
    options: ApplyOptions,
    dirs: Dirs,
    diagnostic: *Diagnostic,
) Error!Outcome {
    diagnostic.* = .{};
    try validateSelection(alloc, built, options, diagnostic);
    try refuseBlocked(alloc, built, options, diagnostic);

    var outcome = try outcomeFromPlan(alloc, fingerprint, built);
    errdefer outcome.deinit(alloc);
    outcome.dry_run = !options.yes;

    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |*candidate| candidate.deinit(alloc);
        candidates.deinit(alloc);
    }

    var entries: std.ArrayList(snapshot.Entry) = .empty;
    var entries_moved = false;
    defer if (!entries_moved) {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    };

    try classify(
        alloc,
        built,
        options,
        &outcome,
        &candidates,
        &entries,
    );

    if (candidates.items.len == 0 or !options.yes) return outcome;

    const seconds = snapshot.nowSeconds(io);
    const created = try snapshot.formatCreated(alloc, seconds);
    defer alloc.free(created);
    outcome.created = try alloc.dupe(u8, created);

    var snap = try makeSnapshot(alloc, fingerprint, built.profile, created, &entries);
    entries_moved = true;
    defer snap.deinit(alloc);

    var snap_diagnostic: snapshot.Diagnostic = .{};
    defer snap_diagnostic.deinit(alloc);

    const snapshot_path = snapshot.save(
        alloc,
        io,
        dirs.snapshot_dir,
        snap,
        seconds,
        &snap_diagnostic,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSnapshot, error.SnapshotWriteFailed => {
            adoptSnapshotMessage(alloc, diagnostic, snap_diagnostic.message);
            return error.SnapshotWriteFailed;
        },
    };
    outcome.snapshot_path = snapshot_path;

    for (candidates.items) |*candidate| {
        const step = outcome.steps[candidate.step_index];
        candidate.command = try commandFor(alloc, step, .apply);
    }

    try runBatch(
        alloc,
        io,
        adb_path,
        dirs,
        seconds,
        created,
        &outcome,
        candidates.items,
        diagnostic,
    );

    return outcome;
}

pub fn revert(
    alloc: Allocator,
    io: Io,
    adb_path: adb.AdbPath,
    fingerprint: device.Fingerprint,
    snap: snapshot.Snapshot,
    snapshot_path: []const u8,
    options: RevertOptions,
    dirs: Dirs,
    diagnostic: *Diagnostic,
) Error!Outcome {
    diagnostic.* = .{};

    if (!std.mem.eql(u8, snap.device.serial, fingerprint.serial)) {
        diagnostic.fail(
            alloc,
            "snapshot was taken on device '{s}', but the selected device is '{s}'",
            .{ snap.device.serial, fingerprint.serial },
        );
        return error.SnapshotMismatch;
    }

    var outcome = try outcomeFromSnapshot(alloc, fingerprint, snap, snapshot_path);
    errdefer outcome.deinit(alloc);
    outcome.dry_run = !options.yes;

    if (outcome.steps.len == 0 or !options.yes) return outcome;

    const seconds = snapshot.nowSeconds(io);
    const created = snap.created;

    var candidates = try alloc.alloc(Candidate, outcome.steps.len);
    defer {
        for (candidates) |*candidate| candidate.deinit(alloc);
        alloc.free(candidates);
    }

    for (outcome.steps, 0..) |step, index| {
        candidates[index] = .{
            .step_index = index,
            .command = try commandFor(alloc, step, .revert),
        };
    }

    try runBatch(
        alloc,
        io,
        adb_path,
        dirs,
        seconds,
        created,
        &outcome,
        candidates,
        diagnostic,
    );

    return outcome;
}

fn validateSelection(
    alloc: Allocator,
    built: plan.Plan,
    options: ApplyOptions,
    diagnostic: *Diagnostic,
) Error!void {
    if (options.only) |only| {
        if (!hasStep(built.steps, only)) {
            diagnostic.fail(alloc, "unknown step id '{s}' in --only", .{only});
            return error.UnknownSelection;
        }
    }
    for (options.skip) |skip| {
        if (!hasStep(built.steps, skip)) {
            diagnostic.fail(alloc, "unknown step id '{s}' in --skip", .{skip});
            return error.UnknownSelection;
        }
    }
}

fn hasStep(steps: []const plan.Step, id: []const u8) bool {
    for (steps) |step| {
        if (std.mem.eql(u8, step.id, id)) return true;
    }
    return false;
}

fn refuseBlocked(
    alloc: Allocator,
    built: plan.Plan,
    options: ApplyOptions,
    diagnostic: *Diagnostic,
) Error!void {
    for (built.steps) |step| {
        if (step.status != .blocked) continue;
        if (selectionReason(options, step.id) != null) continue;
        diagnostic.fail(
            alloc,
            "refusing to apply: step '{s}' is blocked ({s})",
            .{ step.id, step.reason orelse "denylist" },
        );
        return error.BlockedByDenylist;
    }
}

fn selectionReason(options: ApplyOptions, id: []const u8) ?[]const u8 {
    if (options.only) |only| {
        if (!std.mem.eql(u8, only, id)) return "not selected by --only";
    }
    for (options.skip) |skip| {
        if (std.mem.eql(u8, skip, id)) return "skipped by --skip";
    }
    return null;
}

fn classify(
    alloc: Allocator,
    built: plan.Plan,
    options: ApplyOptions,
    outcome: *Outcome,
    candidates: *std.ArrayList(Candidate),
    entries: *std.ArrayList(snapshot.Entry),
) Error!void {
    for (built.steps, 0..) |source, index| {
        const step = &outcome.steps[index];
        if (source.status != .apply) continue;

        if (selectionReason(options, source.id)) |reason| {
            step.status = .skipped;
            try setReason(alloc, step, reason);
            continue;
        }

        if (source.kind == .package) {
            const action = packageActionFromDesired(source.desired);
            const current = source.current.value orelse "";
            switch (action) {
                .disable => {
                    if (std.mem.eql(u8, current, "disabled")) {
                        step.status = .unchanged;
                        try setReason(alloc, step, "the package is already disabled");
                        continue;
                    }
                    if (std.mem.eql(u8, current, "not installed")) {
                        step.status = .skipped;
                        try setReason(alloc, step, "the package is not installed");
                        continue;
                    }
                },
                .uninstall_user => {
                    if (std.mem.eql(u8, current, "not installed")) {
                        step.status = .unchanged;
                        try setReason(alloc, step, "the package is already uninstalled for this user");
                        continue;
                    }
                },
            }
        } else if (!source.changed) {
            step.status = .unchanged;
            try setReason(alloc, step, "already at the desired value");
            continue;
        }

        if (source.kind != .maintenance) {
            const entry = try entryFromPlanStep(alloc, source);
            entries.append(alloc, entry) catch |err| {
                var discarded = entry;
                discarded.deinit(alloc);
                return err;
            };
        }
        try candidates.append(alloc, .{ .step_index = index });
    }
}

fn setReason(alloc: Allocator, step: *Step, text: []const u8) Allocator.Error!void {
    if (step.reason) |reason| alloc.free(reason);
    step.reason = try alloc.dupe(u8, text);
}

fn packageActionFromDesired(desired: ?[]const u8) profile.PackageAction {
    const value = desired orelse return .disable;
    if (std.mem.eql(u8, value, "uninstall-user")) return .uninstall_user;
    return .disable;
}

fn outcomeFromPlan(
    alloc: Allocator,
    fingerprint: device.Fingerprint,
    built: plan.Plan,
) Error!Outcome {
    const profile_copy = try alloc.dupe(u8, built.profile);
    errdefer alloc.free(profile_copy);
    const serial_copy = try alloc.dupe(u8, fingerprint.serial);
    errdefer alloc.free(serial_copy);

    const steps = try alloc.alloc(Step, built.steps.len);
    errdefer alloc.free(steps);
    var initialized: usize = 0;
    errdefer for (steps[0..initialized]) |*step| step.deinit(alloc);

    for (built.steps, 0..) |source, index| {
        steps[index] = try stepFromPlan(alloc, source);
        initialized = index + 1;
    }

    return .{
        .mode = .apply,
        .profile = profile_copy,
        .device = serial_copy,
        .sdk = fingerprint.sdk,
        .ram_total_mb = fingerprint.ram_total_mb,
        .dry_run = true,
        .steps = steps,
    };
}

fn stepFromPlan(alloc: Allocator, source: plan.Step) Allocator.Error!Step {
    const id = try alloc.dupe(u8, source.id);
    errdefer alloc.free(id);
    const target = try alloc.dupe(u8, source.target);
    errdefer alloc.free(target);
    const before = if (source.current.value) |value| try alloc.dupe(u8, value) else null;
    errdefer if (before) |value| alloc.free(value);
    const after = if (source.desired) |value| try alloc.dupe(u8, value) else null;
    errdefer if (after) |value| alloc.free(value);
    const reason = if (source.reason) |value| try alloc.dupe(u8, value) else null;

    return .{
        .id = id,
        .kind = source.kind,
        .risk = source.risk,
        .target = target,
        .before = before,
        .after = after,
        .status = switch (source.status) {
            .apply => .planned,
            .skip, .blocked => .skipped,
        },
        .reason = reason,
    };
}

fn entryFromPlanStep(alloc: Allocator, source: plan.Step) Error!snapshot.Entry {
    const step_id = try alloc.dupe(u8, source.id);
    errdefer alloc.free(step_id);
    const target = try alloc.dupe(u8, source.target);
    errdefer alloc.free(target);

    const before = try beforeForPlanStep(alloc, source);
    errdefer if (before) |value| alloc.free(value);
    const after = if (source.desired) |value| try alloc.dupe(u8, value) else null;
    errdefer if (after) |value| alloc.free(value);

    return .{
        .step_id = step_id,
        .kind = source.kind,
        .target = target,
        .before = before,
        .after = after,
        .status = .planned,
    };
}

fn beforeForPlanStep(alloc: Allocator, source: plan.Step) Allocator.Error!?[]const u8 {
    switch (source.kind) {
        .compile => return null,
        .package => {
            const action = packageActionFromDesired(source.desired);
            return try alloc.dupe(
                u8,
                switch (action) {
                    .disable => "enabled",
                    .uninstall_user => "installed",
                },
            );
        },
        else => {
            const value = source.current.value orelse return null;
            return try alloc.dupe(u8, value);
        },
    }
}

fn makeSnapshot(
    alloc: Allocator,
    fingerprint: device.Fingerprint,
    profile_name: []const u8,
    created: []const u8,
    entries: *std.ArrayList(snapshot.Entry),
) Error!snapshot.Snapshot {
    const created_copy = try alloc.dupe(u8, created);
    errdefer alloc.free(created_copy);
    const serial_copy = try alloc.dupe(u8, fingerprint.serial);
    errdefer alloc.free(serial_copy);
    const model_copy: ?[]const u8 = if (fingerprint.model) |model|
        try alloc.dupe(u8, model)
    else
        null;
    errdefer if (model_copy) |model| alloc.free(model);
    const profile_copy = try alloc.dupe(u8, profile_name);
    errdefer alloc.free(profile_copy);
    const entry_slice = try entries.toOwnedSlice(alloc);

    return .{
        .created = created_copy,
        .device = .{
            .serial = serial_copy,
            .model = model_copy,
            .sdk = fingerprint.sdk,
        },
        .profile = profile_copy,
        .entries = entry_slice,
    };
}

fn outcomeFromSnapshot(
    alloc: Allocator,
    fingerprint: device.Fingerprint,
    snap: snapshot.Snapshot,
    snapshot_path: []const u8,
) Error!Outcome {
    const profile_copy = try alloc.dupe(u8, snap.profile);
    errdefer alloc.free(profile_copy);
    const serial_copy = try alloc.dupe(u8, snap.device.serial);
    errdefer alloc.free(serial_copy);
    const created_copy = try alloc.dupe(u8, snap.created);
    errdefer alloc.free(created_copy);
    const path_copy = try alloc.dupe(u8, snapshot_path);
    errdefer alloc.free(path_copy);

    const steps = try alloc.alloc(Step, snap.entries.len);
    errdefer alloc.free(steps);
    var initialized: usize = 0;
    errdefer for (steps[0..initialized]) |*step| step.deinit(alloc);

    for (snap.entries, 0..) |entry, index| {
        steps[index] = try stepFromEntry(alloc, entry);
        initialized = index + 1;
    }

    return .{
        .mode = .revert,
        .profile = profile_copy,
        .device = serial_copy,
        .sdk = snap.device.sdk,
        .ram_total_mb = fingerprint.ram_total_mb,
        .created = created_copy,
        .dry_run = true,
        .snapshot_path = path_copy,
        .steps = steps,
    };
}

fn stepFromEntry(alloc: Allocator, entry: snapshot.Entry) Allocator.Error!Step {
    const id = try alloc.dupe(u8, entry.step_id);
    errdefer alloc.free(id);
    const target = try alloc.dupe(u8, entry.target);
    errdefer alloc.free(target);
    const before = if (entry.before) |value| try alloc.dupe(u8, value) else null;
    errdefer if (before) |value| alloc.free(value);
    const after = if (entry.after) |value| try alloc.dupe(u8, value) else null;
    errdefer if (after) |value| alloc.free(value);

    return .{
        .id = id,
        .kind = entry.kind,
        .target = target,
        .before = before,
        .after = after,
    };
}

const CommandBuilder = struct {
    alloc: Allocator,
    buffer: std.ArrayList(u8) = .empty,

    fn init(alloc: Allocator) CommandBuilder {
        return .{ .alloc = alloc };
    }

    fn deinit(builder: *CommandBuilder) void {
        builder.buffer.deinit(builder.alloc);
    }

    fn raw(builder: *CommandBuilder, text: []const u8) Allocator.Error!void {
        try builder.buffer.appendSlice(builder.alloc, text);
    }

    fn quoted(builder: *CommandBuilder, text: []const u8) Allocator.Error!void {
        try builder.buffer.append(builder.alloc, '\'');
        for (text) |char| {
            if (char == '\'') {
                try builder.buffer.appendSlice(builder.alloc, "'\\''");
            } else {
                try builder.buffer.append(builder.alloc, char);
            }
        }
        try builder.buffer.append(builder.alloc, '\'');
    }

    fn finish(builder: *CommandBuilder) Allocator.Error![]u8 {
        return builder.buffer.toOwnedSlice(builder.alloc);
    }
};

fn shellQuote(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var builder = CommandBuilder.init(alloc);
    errdefer builder.deinit();
    try builder.quoted(text);
    return builder.finish();
}

fn commandFor(alloc: Allocator, step: Step, mode: Mode) Error![]u8 {
    var builder = CommandBuilder.init(alloc);
    errdefer builder.deinit();

    var parsed = snapshot.parseTarget(alloc, step.kind, step.target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidTarget => return error.InvalidTarget,
    };
    defer profile.freeTarget(&parsed, alloc);

    switch (step.kind) {
        .setting => {
            if (mode == .apply) {
                try builder.raw("settings put ");
            } else if (step.before == null) {
                try builder.raw("settings delete ");
            } else {
                try builder.raw("settings put ");
            }
            try builder.quoted(parsed.setting.namespace);
            try builder.raw(" ");
            try builder.quoted(parsed.setting.key);
            if (mode == .apply) {
                try builder.raw(" ");
                try builder.quoted(step.after orelse return error.InvalidTarget);
            } else if (step.before) |before| {
                try builder.raw(" ");
                try builder.quoted(before);
            }
        },
        .device_config => {
            if (mode == .apply) {
                try builder.raw("device_config put ");
            } else if (step.before == null) {
                try builder.raw("device_config delete ");
            } else {
                try builder.raw("device_config put ");
            }
            try builder.quoted(parsed.device_config.namespace);
            try builder.raw(" ");
            try builder.quoted(parsed.device_config.key);
            if (mode == .apply) {
                try builder.raw(" ");
                try builder.quoted(step.after orelse return error.InvalidTarget);
            } else if (step.before) |before| {
                try builder.raw(" ");
                try builder.quoted(before);
            }
        },
        .compile => {
            if (mode == .apply) {
                try builder.raw("cmd package compile -m ");
                try builder.quoted(parsed.compile.mode);
                try builder.raw(" ");
            } else {
                try builder.raw("cmd package compile --reset ");
            }
            if (std.mem.eql(u8, parsed.compile.scope, "all")) {
                try builder.raw("-a");
            } else {
                try builder.quoted(parsed.compile.scope);
            }
        },
        .appops => {
            try builder.raw("cmd appops set ");
            try builder.quoted(parsed.appops.package);
            try builder.raw(" ");
            try builder.quoted(parsed.appops.op);
            try builder.raw(" ");
            if (mode == .apply) {
                try builder.quoted(step.after orelse return error.InvalidTarget);
            } else {
                try builder.quoted(step.before orelse "default");
            }
        },
        .standby_bucket => {
            try builder.raw("am set-standby-bucket ");
            try builder.quoted(parsed.standby_bucket.package);
            try builder.raw(" ");
            if (mode == .apply) {
                try builder.quoted(step.after orelse return error.InvalidTarget);
            } else {
                const before = step.before orelse return error.InvalidTarget;
                try builder.quoted(bucketArgument(before));
            }
        },
        .wm => {
            try builder.raw("wm ");
            try builder.raw(parsed.wm.key.label());
            try builder.raw(" ");
            if (mode == .apply) {
                try builder.quoted(step.after orelse return error.InvalidTarget);
            } else {
                const before = step.before orelse return error.InvalidTarget;
                if (std.mem.startsWith(u8, before, "physical ")) {
                    try builder.raw("reset");
                } else {
                    try builder.quoted(before);
                }
            }
        },
        .package => {
            const action = packageActionFromDesired(step.after);
            if (mode == .apply) {
                switch (action) {
                    .disable => try builder.raw("pm disable-user --user 0 "),
                    .uninstall_user => try builder.raw("pm uninstall -k --user 0 "),
                }
                try builder.quoted(parsed.package.package);
            } else {
                switch (action) {
                    .disable => {
                        try builder.raw("pm enable ");
                        try builder.quoted(parsed.package.package);
                    },
                    .uninstall_user => {
                        try builder.raw("cmd package install-existing ");
                        try builder.quoted(parsed.package.package);
                    },
                }
            }
        },
        .maintenance => {
            if (mode == .revert) return error.InvalidTarget;
            try builder.raw("sm idle-maint run");
        },
    }

    return builder.finish() catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn bucketArgument(before: []const u8) []const u8 {
    const prefix = "bucket ";
    if (std.mem.startsWith(u8, before, prefix)) return before[prefix.len..];
    return before;
}

fn runBatch(
    alloc: Allocator,
    io: Io,
    adb_path: adb.AdbPath,
    dirs: Dirs,
    seconds: u64,
    created: []const u8,
    outcome: *Outcome,
    candidates: []const Candidate,
    diagnostic: *Diagnostic,
) Error!void {
    const script = try buildScript(alloc, outcome.steps, candidates);
    defer alloc.free(script);

    const log = buildLog(alloc, outcome, candidates, created) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagnostic.fail(alloc, "could not render the log", .{});
            return error.LogFailed;
        },
    };
    defer alloc.free(log);

    const log_path = try writeLog(
        alloc,
        io,
        dirs.log_dir,
        outcome.mode.label(),
        outcome.device,
        seconds,
        log,
        diagnostic,
    );
    outcome.log_path = log_path;

    var scratch = std.Io.Dir.cwd().openDir(io, dirs.log_dir, .{}) catch {
        diagnostic.fail(alloc, "could not open the log directory '{s}'", .{dirs.log_dir});
        return error.LogFailed;
    };
    defer scratch.close(io);

    const lines = adb.runScript(alloc, adb_path, outcome.device, script, scratch) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try markAllFailed(alloc, outcome, candidates, "the batch could not be executed");
            outcome.aborted = true;
            return;
        },
    };
    defer adb.freeScriptLines(alloc, lines);

    for (candidates) |candidate| {
        const step = &outcome.steps[candidate.step_index];
        const line = findLine(lines, step.id) orelse {
            step.status = .failed;
            step.verified = false;
            try setReason(alloc, step, "the step did not report a result");
            continue;
        };
        step.exit_code = line.exit_code;
        if (line.exit_code != 0) {
            step.status = .failed;
            step.verified = false;
            const reason = try std.fmt.allocPrint(
                alloc,
                "the command exited with code {d}",
                .{line.exit_code},
            );
            try setReason(alloc, step, reason);
            alloc.free(reason);
            continue;
        }

        switch (try verifyStep(alloc, adb_path, outcome.device, step.*, outcome.mode)) {
            .not_tracked => {
                step.status = successStatus(outcome.mode);
            },
            .passed => {
                step.status = successStatus(outcome.mode);
                step.verified = true;
            },
            .failed => |reason| {
                step.status = .failed;
                step.verified = false;
                try setReason(alloc, step, reason);
                alloc.free(reason);
            },
        }
    }

    if (outcome.count(.failed) * 2 > candidates.len) outcome.aborted = true;
}

fn markAllFailed(
    alloc: Allocator,
    outcome: *Outcome,
    candidates: []const Candidate,
    text: []const u8,
) Allocator.Error!void {
    for (candidates) |candidate| {
        const step = &outcome.steps[candidate.step_index];
        step.status = .failed;
        step.verified = false;
        try setReason(alloc, step, text);
    }
}

fn successStatus(mode: Mode) Status {
    return switch (mode) {
        .apply => .applied,
        .revert => .reverted,
    };
}

fn findLine(lines: []const adb.ScriptLine, id: []const u8) ?adb.ScriptLine {
    for (lines) |line| {
        if (std.mem.eql(u8, line.step_id, id)) return line;
    }
    return null;
}

fn verifyStep(
    alloc: Allocator,
    adb_path: adb.AdbPath,
    serial: []const u8,
    step: Step,
    mode: Mode,
) Error!Verification {
    const expectation = expectedFor(step, mode) orelse return .not_tracked;

    var target = snapshot.parseTarget(alloc, step.kind, step.target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidTarget => {
            return .{ .failed = try alloc.dupe(u8, "the step target could not be parsed") };
        },
    };
    defer profile.freeTarget(&target, alloc);

    if (step.kind == .package) {
        target.package.action = packageActionFromDesired(step.after);
    }

    const source: profile.Step = .{
        .id = step.id,
        .risk = step.risk orelse .safe,
        .target = target,
    };

    var current = plan.readCurrent(alloc, adb_path, serial, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            return .{ .failed = try alloc.dupe(u8, "could not read the value back from the device") };
        },
    };
    defer current.deinit(alloc);

    const matched = switch (expectation) {
        .unset => current.state == .unset,
        .value => |expected| current.state == .value and
            std.mem.eql(u8, current.value orelse "", expected),
    };
    if (matched) return .passed;

    const expected_text = switch (expectation) {
        .unset => "(unset)",
        .value => |expected| expected,
    };
    return .{ .failed = try std.fmt.allocPrint(
        alloc,
        "verification failed: expected '{s}', found '{s}'",
        .{ expected_text, current.describe() },
    ) };
}

const Verification = union(enum) {
    not_tracked,
    passed,
    failed: []u8,
};

const Expectation = union(enum) {
    unset,
    value: []const u8,
};

fn expectedFor(step: Step, mode: Mode) ?Expectation {
    switch (mode) {
        .apply => switch (step.kind) {
            .compile, .maintenance => return null,
            .package => {
                const action = packageActionFromDesired(step.after);
                return Expectation{ .value = switch (action) {
                    .disable => "disabled",
                    .uninstall_user => "not installed",
                } };
            },
            else => return Expectation{ .value = step.after orelse return null },
        },
        .revert => switch (step.kind) {
            .compile => return null,
            .package => {
                const action = packageActionFromDesired(step.after);
                return Expectation{ .value = switch (action) {
                    .disable => "enabled",
                    .uninstall_user => "installed",
                } };
            },
            .setting, .device_config => {
                if (step.before) |before| return Expectation{ .value = before };
                return Expectation.unset;
            },
            .appops => return Expectation{ .value = step.before orelse "default" },
            else => return Expectation{ .value = step.before orelse return null },
        },
    }
}

fn buildScript(
    alloc: Allocator,
    steps: []const Step,
    candidates: []const Candidate,
) Error![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(alloc);

    for (candidates) |candidate| {
        const step = steps[candidate.step_index];
        try buffer.appendSlice(alloc, candidate.command orelse return error.InvalidTarget);
        try buffer.append(alloc, '\n');
        try buffer.appendSlice(alloc, "echo \"__STEP=");
        try buffer.appendSlice(alloc, step.id);
        try buffer.appendSlice(alloc, " __RC=$?\"\n");
    }
    return buffer.toOwnedSlice(alloc);
}

fn buildLog(
    alloc: Allocator,
    outcome: *const Outcome,
    candidates: []const Candidate,
    created: []const u8,
) (Allocator.Error || std.Io.Writer.Error)![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.print(
        "# reclaim {s} log\n# created: {s}\n# device: {s}\n# profile: {s}\n# snapshot: {s}\n",
        .{
            outcome.mode.label(),
            created,
            outcome.device,
            outcome.profile,
            outcome.snapshot_path orelse "-",
        },
    );
    for (candidates) |candidate| {
        const step = outcome.steps[candidate.step_index];
        try out.writer.print(
            "\n# [{s}]\n{s}\necho \"__STEP={s} __RC=$?\"\n",
            .{ step.id, candidate.command orelse "", step.id },
        );
    }
    return out.toOwnedSlice();
}

fn writeLog(
    alloc: Allocator,
    io: Io,
    dir_path: []const u8,
    mode_label: []const u8,
    serial: []const u8,
    seconds: u64,
    content: []const u8,
    diagnostic: *Diagnostic,
) Error![]u8 {
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| {
        diagnostic.fail(
            alloc,
            "could not create the log directory '{s}': {s}",
            .{ dir_path, @errorName(err) },
        );
        return error.LogFailed;
    };

    const slug = snapshot.serialSlug(alloc, serial) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer alloc.free(slug);
    const stamp = snapshot.compactTimestamp(alloc, seconds) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer alloc.free(stamp);

    var attempt: u8 = 1;
    while (attempt <= 99) : (attempt += 1) {
        const name = if (attempt == 1)
            std.fmt.allocPrint(
                alloc,
                "{s}_{s}_{s}.log",
                .{ mode_label, slug, stamp },
            ) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(
                alloc,
                "{s}_{s}_{s}_{d}.log",
                .{ mode_label, slug, stamp, attempt },
            ) catch return error.OutOfMemory;
        defer alloc.free(name);
        const path = std.fs.path.join(alloc, &.{ dir_path, name }) catch
            return error.OutOfMemory;
        if (pathExists(io, path)) {
            alloc.free(path);
            continue;
        }

        writeFile(io, path, content) catch |err| {
            diagnostic.fail(
                alloc,
                "could not write the log '{s}': {s}",
                .{ path, @errorName(err) },
            );
            alloc.free(path);
            return error.LogFailed;
        };
        return path;
    }

    diagnostic.fail(alloc, "could not choose a log file name in '{s}'", .{dir_path});
    return error.LogFailed;
}

fn pathExists(io: Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

fn adoptSnapshotMessage(
    alloc: Allocator,
    diagnostic: *Diagnostic,
    message: ?[]const u8,
) void {
    if (message) |text| {
        diagnostic.message = alloc.dupe(u8, text) catch null;
    }
}

const testing = std.testing;

fn testPlanStep(source: plan.Step) plan.Step {
    return source;
}

fn testOutcomeStep(
    alloc: Allocator,
    id: []const u8,
    kind: profile.Kind,
    target: []const u8,
    before: ?[]const u8,
    after: ?[]const u8,
) !Step {
    return .{
        .id = try alloc.dupe(u8, id),
        .kind = kind,
        .risk = .safe,
        .target = try alloc.dupe(u8, target),
        .before = if (before) |value| try alloc.dupe(u8, value) else null,
        .after = if (after) |value| try alloc.dupe(u8, value) else null,
    };
}

test "shell quoting survives spaces and quotes" {
    const alloc = testing.allocator;
    const quoted = try shellQuote(alloc, "it's a test");
    defer alloc.free(quoted);
    try testing.expectEqualStrings("'it'\\''s a test'", quoted);
}

test "apply commands cover the catalog" {
    const alloc = testing.allocator;
    var step = try testOutcomeStep(
        alloc,
        "anim-window",
        .setting,
        "global/window_animation_scale",
        "1.0",
        "0.5",
    );
    defer step.deinit(alloc);
    const setting = try commandFor(alloc, step, .apply);
    defer alloc.free(setting);
    try testing.expectEqualStrings(
        "settings put 'global' 'window_animation_scale' '0.5'",
        setting,
    );

    var compile = try testOutcomeStep(
        alloc,
        "dexopt",
        .compile,
        "compile speed-profile (all)",
        null,
        null,
    );
    defer compile.deinit(alloc);
    const compile_command = try commandFor(alloc, compile, .apply);
    defer alloc.free(compile_command);
    try testing.expectEqualStrings("cmd package compile -m 'speed-profile' -a", compile_command);

    var bucket = try testOutcomeStep(
        alloc,
        "bucket",
        .standby_bucket,
        "com.example.app",
        "active",
        "restricted",
    );
    defer bucket.deinit(alloc);
    const bucket_command = try commandFor(alloc, bucket, .apply);
    defer alloc.free(bucket_command);
    try testing.expectEqualStrings(
        "am set-standby-bucket 'com.example.app' 'restricted'",
        bucket_command,
    );

    var density = try testOutcomeStep(alloc, "density", .wm, "wm density", "physical 420", "480");
    defer density.deinit(alloc);
    const density_command = try commandFor(alloc, density, .apply);
    defer alloc.free(density_command);
    try testing.expectEqualStrings("wm density '480'", density_command);

    var disable = try testOutcomeStep(
        alloc,
        "disable",
        .package,
        "com.example.app",
        "enabled",
        "disable",
    );
    defer disable.deinit(alloc);
    const disable_command = try commandFor(alloc, disable, .apply);
    defer alloc.free(disable_command);
    try testing.expectEqualStrings(
        "pm disable-user --user 0 'com.example.app'",
        disable_command,
    );

    var maintenance = try testOutcomeStep(
        alloc,
        "idle-maint",
        .maintenance,
        "idle maintenance",
        null,
        null,
    );
    defer maintenance.deinit(alloc);
    const maintenance_command = try commandFor(alloc, maintenance, .apply);
    defer alloc.free(maintenance_command);
    try testing.expectEqualStrings("sm idle-maint run", maintenance_command);
}

test "revert commands restore original values" {
    const alloc = testing.allocator;

    var unset = try testOutcomeStep(
        alloc,
        "anim-window",
        .setting,
        "global/window_animation_scale",
        null,
        "0.5",
    );
    defer unset.deinit(alloc);
    const unset_command = try commandFor(alloc, unset, .revert);
    defer alloc.free(unset_command);
    try testing.expectEqualStrings(
        "settings delete 'global' 'window_animation_scale'",
        unset_command,
    );

    var physical = try testOutcomeStep(
        alloc,
        "density",
        .wm,
        "wm density",
        "physical 420",
        "480",
    );
    defer physical.deinit(alloc);
    const physical_command = try commandFor(alloc, physical, .revert);
    defer alloc.free(physical_command);
    try testing.expectEqualStrings("wm density reset", physical_command);

    var uninstall = try testOutcomeStep(
        alloc,
        "uninstall",
        .package,
        "com.example.app",
        "installed",
        "uninstall-user",
    );
    defer uninstall.deinit(alloc);
    const uninstall_command = try commandFor(alloc, uninstall, .revert);
    defer alloc.free(uninstall_command);
    try testing.expectEqualStrings(
        "cmd package install-existing 'com.example.app'",
        uninstall_command,
    );

    var bucket = try testOutcomeStep(
        alloc,
        "bucket",
        .standby_bucket,
        "com.example.app",
        "bucket 33",
        "restricted",
    );
    defer bucket.deinit(alloc);
    const bucket_command = try commandFor(alloc, bucket, .revert);
    defer alloc.free(bucket_command);
    try testing.expectEqualStrings("am set-standby-bucket 'com.example.app' '33'", bucket_command);

    var appops = try testOutcomeStep(
        alloc,
        "appops",
        .appops,
        "com.example.app RUN_IN_BACKGROUND",
        null,
        "ignore",
    );
    defer appops.deinit(alloc);
    const appops_command = try commandFor(alloc, appops, .revert);
    defer alloc.free(appops_command);
    try testing.expectEqualStrings(
        "cmd appops set 'com.example.app' 'RUN_IN_BACKGROUND' 'default'",
        appops_command,
    );
}

test "expected values follow the mode and kind" {
    const apply_step: Step = .{
        .id = "anim-window",
        .kind = .setting,
        .target = "global/window_animation_scale",
        .before = "1.0",
        .after = "0.5",
    };
    try testing.expectEqualStrings("0.5", expectedFor(apply_step, .apply).?.value);
    try testing.expectEqualStrings("1.0", expectedFor(apply_step, .revert).?.value);

    const deleted: Step = .{
        .id = "anim-window",
        .kind = .setting,
        .target = "global/window_animation_scale",
        .before = null,
        .after = "0.5",
    };
    try testing.expect(std.meta.activeTag(expectedFor(deleted, .revert).?) == .unset);

    const disable: Step = .{
        .id = "pkg",
        .kind = .package,
        .target = "com.example.app",
        .before = "enabled",
        .after = "disable",
    };
    try testing.expectEqualStrings("disabled", expectedFor(disable, .apply).?.value);
    try testing.expectEqualStrings("enabled", expectedFor(disable, .revert).?.value);

    const uninstall: Step = .{
        .id = "pkg",
        .kind = .package,
        .target = "com.example.app",
        .before = "installed",
        .after = "uninstall-user",
    };
    try testing.expectEqualStrings("not installed", expectedFor(uninstall, .apply).?.value);
    try testing.expectEqualStrings("installed", expectedFor(uninstall, .revert).?.value);
}

test "selection rejects unknown ids and keeps known ones" {
    const alloc = testing.allocator;
    var steps = [_]plan.Step{
        testPlanStep(.{
            .id = "anim-window",
            .kind = .setting,
            .risk = .safe,
            .target = "global/window_animation_scale",
            .desired = "0.5",
        }),
    };
    const built: plan.Plan = .{
        .profile = "light",
        .serial = "FAKE123",
        .sdk = 29,
        .ram_total_mb = 2947,
        .steps = &steps,
    };

    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(alloc);

    try validateSelection(alloc, built, .{ .only = "anim-window" }, &diagnostic);
    try testing.expectError(
        error.UnknownSelection,
        validateSelection(alloc, built, .{ .only = "nope" }, &diagnostic),
    );
    try testing.expect(std.mem.indexOf(u8, diagnostic.message.?, "nope") != null);
    diagnostic.deinit(alloc);

    try testing.expectError(
        error.UnknownSelection,
        validateSelection(alloc, built, .{ .skip = &.{"nope"} }, &diagnostic),
    );
}

test "apply refuses a blocked step unless it is excluded" {
    const alloc = testing.allocator;
    var steps = [_]plan.Step{
        testPlanStep(.{
            .id = "disable-systemui",
            .kind = .package,
            .risk = .dangerous,
            .target = "com.android.systemui",
            .desired = "disable",
            .current = .{ .state = .value, .value = "enabled" },
            .status = .blocked,
            .reason = "the package is on the static denylist",
        }),
    };
    const built: plan.Plan = .{
        .profile = "custom",
        .serial = "FAKE123",
        .sdk = 29,
        .ram_total_mb = null,
        .steps = &steps,
    };
    const fingerprint: device.Fingerprint = .{ .serial = "FAKE123" };
    const dirs: Dirs = .{ .snapshot_dir = "unused", .log_dir = "unused" };

    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(alloc);

    try testing.expectError(
        error.BlockedByDenylist,
        apply(
            alloc,
            testing.io,
            .{ .path = "definitely-missing-adb", .io = testing.io },
            fingerprint,
            built,
            .{ .yes = true },
            dirs,
            &diagnostic,
        ),
    );
    try testing.expect(std.mem.indexOf(u8, diagnostic.message.?, "blocked") != null);
    diagnostic.deinit(alloc);

    const outcome = try apply(
        alloc,
        testing.io,
        .{ .path = "definitely-missing-adb", .io = testing.io },
        fingerprint,
        built,
        .{ .yes = true, .skip = &.{"disable-systemui"} },
        dirs,
        &diagnostic,
    );
    var mutable_outcome = outcome;
    defer mutable_outcome.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), mutable_outcome.steps.len);
    try testing.expectEqual(Status.skipped, mutable_outcome.steps[0].status);
    try testing.expect(mutable_outcome.snapshot_path == null);
}

test "a dry run never writes or changes anything" {
    const alloc = testing.allocator;
    var steps = [_]plan.Step{
        testPlanStep(.{
            .id = "anim-window",
            .kind = .setting,
            .risk = .safe,
            .target = "global/window_animation_scale",
            .desired = "0.5",
            .current = .{ .state = .value, .value = "1.0" },
            .changed = true,
        }),
        testPlanStep(.{
            .id = "anim-transition",
            .kind = .setting,
            .risk = .safe,
            .target = "global/transition_animation_scale",
            .desired = "1.0",
            .current = .{ .state = .value, .value = "1.0" },
            .changed = false,
        }),
    };
    const built: plan.Plan = .{
        .profile = "light",
        .serial = "FAKE123",
        .sdk = 29,
        .ram_total_mb = 2947,
        .steps = &steps,
    };
    const fingerprint: device.Fingerprint = .{
        .serial = "FAKE123",
        .sdk = 29,
        .ram_total_mb = 2947,
    };

    var diagnostic: Diagnostic = .{};
    defer diagnostic.deinit(alloc);

    var outcome = try apply(
        alloc,
        testing.io,
        .{ .path = "definitely-missing-adb", .io = testing.io },
        fingerprint,
        built,
        .{},
        .{ .snapshot_dir = "unused", .log_dir = "unused" },
        &diagnostic,
    );
    defer outcome.deinit(alloc);

    try testing.expectEqual(Status.planned, outcome.steps[0].status);
    try testing.expectEqual(Status.unchanged, outcome.steps[1].status);
    try testing.expect(outcome.snapshot_path == null);
    try testing.expect(outcome.log_path == null);
    try testing.expect(outcome.dry_run);
    try testing.expect(!outcome.aborted);
}
