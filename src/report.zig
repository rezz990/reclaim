const std = @import("std");
const cli = @import("cli.zig");
const adb = @import("adb.zig");
const apply = @import("apply.zig");
const device = @import("device.zig");
const doctor = @import("doctor.zig");
const plan = @import("plan.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub fn printHelp(writer: *Writer) Writer.Error!void {
    try writer.writeAll(cli.help_text);
}

pub fn printVersion(writer: *Writer) Writer.Error!void {
    try writer.print("reclaim {s}\n", .{cli.version});
}

pub fn notImplemented(writer: *Writer, command: []const u8) Writer.Error!void {
    try writer.print("reclaim: '{s}' is not implemented in this phase\n", .{command});
}

pub fn usageError(writer: *Writer, failure: cli.Failure) Writer.Error!void {
    const arg = failure.arg orelse "";
    try writer.writeAll("reclaim: error: ");
    switch (failure.kind) {
        .missing_command => try writer.writeAll("missing command"),
        .unknown_command => try writer.print("unknown command '{s}'", .{arg}),
        .unknown_flag => try writer.print("unknown option '{s}'", .{arg}),
        .missing_value => try writer.print("option '{s}' requires a value", .{arg}),
        .invalid_value => try writer.print("invalid value for option '{s}'", .{arg}),
        .missing_argument => try writer.print("missing required argument for '{s}'", .{arg}),
        .unexpected_argument => try writer.print("unexpected argument '{s}'", .{arg}),
    }
    try writer.writeAll("\nRun 'reclaim --help' for usage.\n");
}

pub fn printDoctor(writer: *Writer, diagnosis: doctor.Diagnosis) Writer.Error!void {
    const path = diagnosis.adb_path orelse {
        try writer.writeAll("adb: not found\n");
        if (diagnosis.resolve_error) |message| try writer.print("error: {s}\n", .{message});
        return;
    };
    try writer.print("adb: {s}\n", .{path});

    if (diagnosis.version) |version| {
        try writer.print("version: {s}\n", .{version});
    } else if (diagnosis.version_error) |message| {
        try writer.print("version: unavailable ({s})\n", .{message});
    }

    if (diagnosis.server_ok orelse false) {
        try writer.writeAll("server: running\n");
    } else if (diagnosis.server_error) |message| {
        try writer.print("server: unavailable ({s})\n", .{message});
    }

    if (diagnosis.devices_error) |message| {
        try writer.print("devices: unavailable ({s})\n", .{message});
        return;
    }
    try writer.print("devices: {d}\n", .{diagnosis.devices.len});
    for (diagnosis.devices) |entry| {
        try writer.print("  {s}  {s}\n", .{ entry.serial, entry.state.label() });
    }

    var hint_header = false;
    for (diagnosis.devices) |entry| {
        const hint = hintFor(entry.state) orelse continue;
        if (!hint_header) {
            try writer.writeAll("hints:\n");
            hint_header = true;
        }
        try writer.print("  {s} ({s}): {s}\n", .{ entry.serial, entry.state.label(), hint });
    }
}

fn hintFor(state: adb.DeviceState) ?[]const u8 {
    return switch (state) {
        .device => null,
        .unauthorized => "accept the USB debugging prompt on the device, then run doctor again",
        .offline => "reconnect the device or restart the adb server",
        .no_permissions => "fix USB permissions: add your user to the plugdev group on Linux, or install the OEM USB driver on Windows",
        .unknown => "unexpected device state; reconnect the device",
    };
}

pub fn printDoctorJson(
    alloc: Allocator,
    writer: *Writer,
    diagnosis: doctor.Diagnosis,
) (Allocator.Error || Writer.Error)!void {
    const devices = try alloc.alloc(DeviceJson, diagnosis.devices.len);
    defer alloc.free(devices);
    for (diagnosis.devices, 0..) |entry, index| {
        devices[index] = .{
            .serial = entry.serial,
            .state = entry.state.label(),
            .detail = entry.detail,
        };
    }

    const view: DoctorJson = .{
        .adb = .{
            .path = diagnosis.adb_path,
            .version = diagnosis.version,
            .error_message = diagnosis.resolve_error orelse diagnosis.version_error,
        },
        .server = .{
            .ok = diagnosis.server_ok,
            .error_message = diagnosis.server_error,
        },
        .devices = devices,
        .devices_error = diagnosis.devices_error,
    };
    try std.json.Stringify.value(view, .{}, writer);
    try writer.writeAll("\n");
}

const DeviceJson = struct {
    serial: []const u8,
    state: []const u8,
    detail: []const u8,
};

const AdbJson = struct {
    path: ?[]const u8 = null,
    version: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

const ServerJson = struct {
    ok: ?bool = null,
    error_message: ?[]const u8 = null,
};

const DoctorJson = struct {
    adb: AdbJson,
    server: ServerJson,
    devices: []const DeviceJson,
    devices_error: ?[]const u8 = null,
};

pub fn printError(writer: *Writer, message: []const u8) Writer.Error!void {
    try writer.print("reclaim: {s}\n", .{message});
}

pub fn printScan(
    writer: *Writer,
    fingerprint: device.Fingerprint,
    recommendation: device.Recommendation,
) Writer.Error!void {
    try writer.print("device: {s}\n", .{fingerprint.serial});
    try writer.print("model: {s}\n", .{fingerprint.model orelse "unknown"});
    try writer.print("manufacturer: {s}\n", .{fingerprint.manufacturer orelse "unknown"});
    try printAndroid(writer, fingerprint.release, fingerprint.sdk);
    try writer.print("abi: {s}\n", .{fingerprint.abi orelse "unknown"});
    if (fingerprint.ram_total_mb) |ram| {
        try writer.print("ram: {d} MB\n", .{ram});
    } else {
        try writer.writeAll("ram: unknown\n");
    }
    if (fingerprint.low_ram) |low| {
        try writer.print("low ram: {s}\n", .{if (low) "true" else "false"});
    } else {
        try writer.writeAll("low ram: unknown\n");
    }

    const profile = if (recommendation.profile) |value| value.label() else "none";
    try writer.print("recommendation: {s} ({s})\n", .{ profile, recommendation.reason });
}

pub fn printScanJson(
    writer: *Writer,
    fingerprint: device.Fingerprint,
    recommendation: device.Recommendation,
) Writer.Error!void {
    const view: ScanJson = .{
        .device = .{
            .serial = fingerprint.serial,
            .sdk = fingerprint.sdk,
            .release = fingerprint.release,
            .manufacturer = fingerprint.manufacturer,
            .model = fingerprint.model,
            .abi = fingerprint.abi,
            .low_ram = fingerprint.low_ram,
            .ram_total_mb = fingerprint.ram_total_mb,
        },
        .recommendation = .{
            .profile = if (recommendation.profile) |value| value.label() else null,
            .reason = recommendation.reason,
        },
    };
    try std.json.Stringify.value(view, .{}, writer);
    try writer.writeAll("\n");
}

pub fn printSelectionError(
    writer: *Writer,
    failure: device.SelectionError,
    requested_serial: ?[]const u8,
    entries: []const adb.DeviceEntry,
) Writer.Error!void {
    switch (failure) {
        error.NoDevices => try writer.writeAll(
            "reclaim: no device connected; connect a device over USB and enable USB debugging\n",
        ),
        error.MultipleDevices => try writer.writeAll(
            "reclaim: multiple devices connected; choose one with -s <serial>\n",
        ),
        error.SerialNotFound => try writer.print(
            "reclaim: device '{s}' not found; run 'reclaim doctor' to list devices\n",
            .{requested_serial orelse ""},
        ),
        error.DeviceNotReady => {
            const entry = selectedEntry(entries, requested_serial) orelse {
                try writer.writeAll("reclaim: the selected device is not ready\n");
                return;
            };
            try writer.print(
                "reclaim: device '{s}' is {s}; {s}\n",
                .{ entry.serial, entry.state.label(), scanStateHint(entry.state) },
            );
        },
    }
}

fn printAndroid(writer: *Writer, release: ?[]const u8, sdk: ?u32) Writer.Error!void {
    if (release) |value| {
        if (sdk) |level| {
            try writer.print("android: {s} (SDK {d})\n", .{ value, level });
        } else {
            try writer.print("android: {s}\n", .{value});
        }
        return;
    }
    if (sdk) |level| {
        try writer.print("android: SDK {d}\n", .{level});
        return;
    }
    try writer.writeAll("android: unknown\n");
}

fn selectedEntry(entries: []const adb.DeviceEntry, serial: ?[]const u8) ?adb.DeviceEntry {
    if (serial) |wanted| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.serial, wanted)) return entry;
        }
        return null;
    }
    return if (entries.len == 1) entries[0] else null;
}

fn scanStateHint(state: adb.DeviceState) []const u8 {
    return switch (state) {
        .device => "the device is ready",
        .unauthorized => "accept the USB debugging prompt on the device, then run scan again",
        .offline => "reconnect the device or restart the adb server",
        .no_permissions => "fix USB permissions: add your user to the plugdev group on Linux, or install the OEM USB driver on Windows",
        .unknown => "unexpected device state; reconnect the device",
    };
}

const ScanJson = struct {
    device: ScanDeviceJson,
    recommendation: ScanRecommendationJson,
};

const ScanDeviceJson = struct {
    serial: []const u8,
    sdk: ?u32 = null,
    release: ?[]const u8 = null,
    manufacturer: ?[]const u8 = null,
    model: ?[]const u8 = null,
    abi: ?[]const u8 = null,
    low_ram: ?bool = null,
    ram_total_mb: ?u64 = null,
};

const ScanRecommendationJson = struct {
    profile: ?[]const u8 = null,
    reason: []const u8,
};

pub fn printPlan(writer: *Writer, plan_value: plan.Plan) Writer.Error!void {
    try writer.print("profile: {s}\n", .{plan_value.profile});
    try writer.print("device: {s}\n", .{plan_value.serial});
    if (plan_value.sdk) |sdk| {
        try writer.print("android: SDK {d}\n", .{sdk});
    } else {
        try writer.writeAll("android: unknown\n");
    }
    if (plan_value.ram_total_mb) |ram| {
        try writer.print("ram: {d} MB\n", .{ram});
    } else {
        try writer.writeAll("ram: unknown\n");
    }
    try writer.print(
        "steps: {d} (apply {d}, skip {d}, blocked {d})\n\n",
        .{
            plan_value.steps.len,
            plan_value.count(.apply),
            plan_value.count(.skip),
            plan_value.count(.blocked),
        },
    );

    for (plan_value.steps) |step| {
        try writer.print("  {s:<7} {s:<16} {s}", .{
            step.status.label(),
            step.id,
            step.target,
        });
        if (step.desired) |desired| {
            try writer.print("  {s} -> {s}", .{ step.current.describe(), desired });
        } else {
            try writer.print("  {s}", .{step.current.describe()});
        }
        if (!step.changed and step.status == .apply) try writer.writeAll("  (unchanged)");
        try writer.print("  [{s}]", .{step.risk.label()});
        if (step.reason) |reason| try writer.print("  ({s})", .{reason});
        try writer.writeAll("\n");
    }

    if (plan_value.count(.blocked) > 0) {
        try writer.writeAll(
            "\nblocked steps touch protected packages and are never applied.\n",
        );
    }
}

pub fn printPlanJson(
    alloc: Allocator,
    writer: *Writer,
    plan_value: plan.Plan,
) (Allocator.Error || Writer.Error)!void {
    const steps = try alloc.alloc(PlanStepJson, plan_value.steps.len);
    defer alloc.free(steps);
    for (plan_value.steps, 0..) |step, index| {
        steps[index] = .{
            .id = step.id,
            .kind = step.kind.label(),
            .risk = step.risk.label(),
            .target = step.target,
            .current = .{
                .state = step.current.state.label(),
                .value = step.current.value,
            },
            .desired = step.desired,
            .status = step.status.label(),
            .changed = step.changed,
            .reason = step.reason,
        };
    }

    const view: PlanJson = .{
        .profile = plan_value.profile,
        .device = plan_value.serial,
        .sdk = plan_value.sdk,
        .ram_total_mb = plan_value.ram_total_mb,
        .steps = steps,
        .summary = .{
            .apply = plan_value.count(.apply),
            .skip = plan_value.count(.skip),
            .blocked = plan_value.count(.blocked),
        },
    };
    try std.json.Stringify.value(view, .{}, writer);
    try writer.writeAll("\n");
}

const PlanJson = struct {
    profile: []const u8,
    device: []const u8,
    sdk: ?u32 = null,
    ram_total_mb: ?u64 = null,
    steps: []const PlanStepJson,
    summary: PlanSummaryJson,
};

const PlanStepJson = struct {
    id: []const u8,
    kind: []const u8,
    risk: []const u8,
    target: []const u8,
    current: PlanCurrentJson,
    desired: ?[]const u8 = null,
    status: []const u8,
    changed: bool,
    reason: ?[]const u8 = null,
};

const PlanCurrentJson = struct {
    state: []const u8,
    value: ?[]const u8 = null,
};

const PlanSummaryJson = struct {
    apply: usize,
    skip: usize,
    blocked: usize,
};

pub fn printApply(writer: *Writer, outcome: apply.Outcome) Writer.Error!void {
    try printOutcome(writer, outcome);
}

pub fn printRevert(writer: *Writer, outcome: apply.Outcome) Writer.Error!void {
    try printOutcome(writer, outcome);
}

fn printOutcome(writer: *Writer, outcome: apply.Outcome) Writer.Error!void {
    try writer.print("mode: {s}\n", .{outcome.mode.label()});
    try writer.print("profile: {s}\n", .{outcome.profile});
    try writer.print("device: {s}\n", .{outcome.device});
    if (outcome.sdk) |sdk| {
        try writer.print("android: SDK {d}\n", .{sdk});
    } else {
        try writer.writeAll("android: unknown\n");
    }
    if (outcome.ram_total_mb) |ram| {
        try writer.print("ram: {d} MB\n", .{ram});
    } else {
        try writer.writeAll("ram: unknown\n");
    }
    if (outcome.created) |created| {
        try writer.print("created: {s}\n", .{created});
    }
    if (outcome.snapshot_path) |path| {
        try writer.print("snapshot: {s}\n", .{path});
    } else if (outcome.dry_run) {
        try writer.writeAll("snapshot: (dry run, nothing written)\n");
    }
    if (outcome.log_path) |path| try writer.print("log: {s}\n", .{path});
    try writer.print("dry run: {s}\n\n", .{if (outcome.dry_run) "yes" else "no"});

    try writer.print(
        "steps: {d} (planned {d}, applied {d}, reverted {d}, unchanged {d}, skipped {d}, failed {d})\n\n",
        .{
            outcome.steps.len,
            outcome.count(.planned),
            outcome.count(.applied),
            outcome.count(.reverted),
            outcome.count(.unchanged),
            outcome.count(.skipped),
            outcome.count(.failed),
        },
    );

    for (outcome.steps) |step| {
        try writer.print("  {s:<9} {s:<16} {s}", .{
            step.status.label(),
            step.id,
            step.target,
        });
        if (step.kind == .maintenance) {
            try writer.writeAll("  run idle maintenance");
        } else {
            try writer.print("  {s} -> {s}", .{
                valueText(step, if (outcome.mode == .apply) step.before else step.after),
                valueText(step, if (outcome.mode == .apply) step.after else step.before),
            });
        }
        if (step.risk) |risk| try writer.print("  [{s}]", .{risk.label()});
        if (step.verified) |verified| {
            if (verified) try writer.writeAll("  verified");
        }
        if (step.reason) |reason| try writer.print("  ({s})", .{reason});
        try writer.writeAll("\n");
    }

    if (outcome.dry_run) {
        try writer.print(
            "\ndry run: nothing was written or changed; pass --yes to {s}.\n",
            .{switch (outcome.mode) {
                .apply => "apply the plan",
                .revert => "restore the snapshot",
            }},
        );
        return;
    }

    if (outcome.aborted) {
        try writer.writeAll("\nmore than half of the steps failed; check the device state.\n");
    }
    if (outcome.mode == .apply) {
        if (outcome.snapshot_path) |path| {
            try writer.print("\nto undo: reclaim revert --snapshot \"{s}\" --yes\n", .{path});
        }
    }
}

fn valueText(step: apply.Step, value: ?[]const u8) []const u8 {
    if (value) |text| return text;
    return switch (step.kind) {
        .compile, .maintenance, .package => "(not tracked)",
        else => "(unset)",
    };
}

pub fn printApplyJson(
    alloc: Allocator,
    writer: *Writer,
    outcome: apply.Outcome,
) (Allocator.Error || Writer.Error)!void {
    try printOutcomeJson(alloc, writer, outcome);
}

pub fn printRevertJson(
    alloc: Allocator,
    writer: *Writer,
    outcome: apply.Outcome,
) (Allocator.Error || Writer.Error)!void {
    try printOutcomeJson(alloc, writer, outcome);
}

fn printOutcomeJson(
    alloc: Allocator,
    writer: *Writer,
    outcome: apply.Outcome,
) (Allocator.Error || Writer.Error)!void {
    const steps = try alloc.alloc(OutcomeStepJson, outcome.steps.len);
    defer alloc.free(steps);
    for (outcome.steps, 0..) |step, index| {
        steps[index] = .{
            .id = step.id,
            .kind = step.kind.label(),
            .risk = if (step.risk) |risk| risk.label() else null,
            .target = step.target,
            .before = step.before,
            .after = step.after,
            .status = step.status.label(),
            .verified = step.verified,
            .exit_code = step.exit_code,
            .reason = step.reason,
        };
    }

    const view: OutcomeJson = .{
        .mode = outcome.mode.label(),
        .profile = outcome.profile,
        .device = outcome.device,
        .sdk = outcome.sdk,
        .ram_total_mb = outcome.ram_total_mb,
        .created = outcome.created,
        .dry_run = outcome.dry_run,
        .snapshot_path = outcome.snapshot_path,
        .log_path = outcome.log_path,
        .aborted = outcome.aborted,
        .steps = steps,
        .summary = .{
            .planned = outcome.count(.planned),
            .applied = outcome.count(.applied),
            .reverted = outcome.count(.reverted),
            .unchanged = outcome.count(.unchanged),
            .skipped = outcome.count(.skipped),
            .failed = outcome.count(.failed),
        },
    };
    try std.json.Stringify.value(view, .{}, writer);
    try writer.writeAll("\n");
}

const OutcomeJson = struct {
    mode: []const u8,
    profile: []const u8,
    device: []const u8,
    sdk: ?u32 = null,
    ram_total_mb: ?u64 = null,
    created: ?[]const u8 = null,
    dry_run: bool,
    snapshot_path: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    aborted: bool,
    steps: []const OutcomeStepJson,
    summary: OutcomeSummaryJson,
};

const OutcomeStepJson = struct {
    id: []const u8,
    kind: []const u8,
    risk: ?[]const u8 = null,
    target: []const u8,
    before: ?[]const u8 = null,
    after: ?[]const u8 = null,
    status: []const u8,
    verified: ?bool = null,
    exit_code: ?u8 = null,
    reason: ?[]const u8 = null,
};

const OutcomeSummaryJson = struct {
    planned: usize,
    applied: usize,
    reverted: usize,
    unchanged: usize,
    skipped: usize,
    failed: usize,
};

const Render = struct {
    allocating: std.Io.Writer.Allocating,

    fn init() Render {
        return .{ .allocating = .init(std.testing.allocator) };
    }

    fn writer(r: *Render) *Writer {
        return &r.allocating.writer;
    }

    fn output(r: *const Render) []const u8 {
        return r.allocating.writer.buffered();
    }

    fn deinit(r: *Render) void {
        r.allocating.deinit();
    }
};

test "version line" {
    var render: Render = .init();
    defer render.deinit();

    try printVersion(render.writer());
    try std.testing.expectEqualStrings("reclaim 0.1.0\n", render.output());
}

test "help lists every command and the exit codes" {
    var render: Render = .init();
    defer render.deinit();

    try printHelp(render.writer());
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "Usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Exit codes:") != null);
    const commands = [_][]const u8{
        "scan", "plan", "apply", "revert", "bench", "debloat", "watch", "doctor",
    };
    for (commands) |command| {
        try std.testing.expect(std.mem.indexOf(u8, text, command) != null);
    }
}

test "not implemented message names the command" {
    var render: Render = .init();
    defer render.deinit();

    try notImplemented(render.writer(), "watch");
    try std.testing.expectEqualStrings(
        "reclaim: 'watch' is not implemented in this phase\n",
        render.output(),
    );
}

test "doctor report lists devices and hints" {
    const devices = [_]adb.DeviceEntry{
        .{ .serial = "FAKE123", .state = .unauthorized, .detail = "unauthorized" },
        .{ .serial = "FAKE456", .state = .device, .detail = "device" },
    };
    const diagnosis: doctor.Diagnosis = .{
        .adb_path = "/platform-tools/adb",
        .version = "Android Debug Bridge version 1.0.41",
        .server_ok = true,
        .devices = &devices,
    };

    var render: Render = .init();
    defer render.deinit();
    try printDoctor(render.writer(), diagnosis);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "adb: /platform-tools/adb\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "version: Android Debug Bridge version 1.0.41\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "server: running\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "devices: 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  FAKE123  unauthorized\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hints:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "accept the USB debugging prompt") != null);
}

test "doctor report handles a missing adb" {
    const diagnosis: doctor.Diagnosis = .{
        .resolve_error = "adb was not found next to the executable, via --adb, or on PATH",
    };

    var render: Render = .init();
    defer render.deinit();
    try printDoctor(render.writer(), diagnosis);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "adb: not found\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "adb was not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hints:") == null);
}

test "doctor report handles server and device failures" {
    const diagnosis: doctor.Diagnosis = .{
        .adb_path = "/platform-tools/adb",
        .version = "Android Debug Bridge version 1.0.41",
        .server_error = "could not start the adb server",
        .devices_error = "could not list devices",
    };

    var render: Render = .init();
    defer render.deinit();
    try printDoctor(render.writer(), diagnosis);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "server: unavailable (could not start the adb server)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "devices: unavailable (could not list devices)\n") != null);
}

test "doctor JSON is machine readable" {
    const devices = [_]adb.DeviceEntry{
        .{ .serial = "FAKE123", .state = .unauthorized, .detail = "unauthorized" },
    };
    const diagnosis: doctor.Diagnosis = .{
        .adb_path = "/usr/bin/adb",
        .version = "Android Debug Bridge version 1.0.41",
        .server_ok = true,
        .devices = &devices,
    };

    var render: Render = .init();
    defer render.deinit();
    try printDoctorJson(std.testing.allocator, render.writer(), diagnosis);
    const text = render.output();

    try std.testing.expect(std.mem.startsWith(u8, text, "{\"adb\":{"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"path\":\"/usr/bin/adb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"state\":\"unauthorized\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"serial\":\"FAKE123\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
}

test "scan report shows the fingerprint and recommendation" {
    const fingerprint: device.Fingerprint = .{
        .serial = "FAKE123",
        .sdk = 29,
        .release = "10",
        .manufacturer = "Xiaomi",
        .model = "Redmi Note 5",
        .abi = "arm64-v8a",
        .low_ram = false,
        .ram_total_mb = 2947,
    };
    const recommendation: device.Recommendation = .{
        .profile = .light,
        .reason = "RAM 2947 MB <= 3072 MB and SDK 29 < 31",
    };

    var render: Render = .init();
    defer render.deinit();
    try printScan(render.writer(), fingerprint, recommendation);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "device: FAKE123\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "model: Redmi Note 5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "manufacturer: Xiaomi\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "android: 10 (SDK 29)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "abi: arm64-v8a\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ram: 2947 MB\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "low ram: false\n") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "recommendation: light (RAM 2947 MB <= 3072 MB and SDK 29 < 31)\n") != null,
    );
}

test "scan report marks missing fields as unknown" {
    const fingerprint: device.Fingerprint = .{ .serial = "EMPTY" };
    const recommendation: device.Recommendation = .{ .reason = "RAM total is unavailable" };

    var render: Render = .init();
    defer render.deinit();
    try printScan(render.writer(), fingerprint, recommendation);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "model: unknown\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "manufacturer: unknown\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "android: unknown\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "abi: unknown\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ram: unknown\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "low ram: unknown\n") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "recommendation: none (RAM total is unavailable)\n") != null,
    );
}

test "scan report prints partial Android versions" {
    var render: Render = .init();
    defer render.deinit();
    const recommendation: device.Recommendation = .{ .reason = "none" };

    try printScan(render.writer(), .{ .serial = "A", .sdk = 30 }, recommendation);
    try std.testing.expect(std.mem.indexOf(u8, render.output(), "android: SDK 30\n") != null);

    try printScan(render.writer(), .{ .serial = "B", .release = "11" }, recommendation);
    try std.testing.expect(std.mem.indexOf(u8, render.output(), "android: 11\n") != null);
}

test "scan JSON is machine readable" {
    const fingerprint: device.Fingerprint = .{
        .serial = "FAKE123",
        .sdk = 29,
        .release = "10",
        .manufacturer = "Xiaomi",
        .model = "Redmi Note 5",
        .abi = "arm64-v8a",
        .low_ram = false,
        .ram_total_mb = 2947,
    };
    const recommendation: device.Recommendation = .{
        .profile = .light,
        .reason = "RAM 2947 MB <= 3072 MB and SDK 29 < 31",
    };

    var render: Render = .init();
    defer render.deinit();
    try printScanJson(render.writer(), fingerprint, recommendation);
    const text = render.output();

    try std.testing.expect(std.mem.startsWith(u8, text, "{\"device\":{"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"serial\":\"FAKE123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"sdk\":29") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"low_ram\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"ram_total_mb\":2947") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"profile\":\"light\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
}

test "scan JSON emits null for missing fields" {
    const fingerprint: device.Fingerprint = .{ .serial = "EMPTY" };
    const recommendation: device.Recommendation = .{ .reason = "RAM total is unavailable" };

    var render: Render = .init();
    defer render.deinit();
    try printScanJson(render.writer(), fingerprint, recommendation);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "\"sdk\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"model\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"profile\":null") != null);
}

test "plan report shows status, diffs, risk, and reasons" {
    var steps = [_]plan.Step{
        .{
            .id = "anim-window",
            .kind = .setting,
            .risk = .safe,
            .target = "global/window_animation_scale",
            .desired = "0.5",
            .current = .{ .state = .value, .value = "1.0" },
        },
        .{
            .id = "transition",
            .kind = .setting,
            .risk = .safe,
            .target = "global/transition_animation_scale",
            .desired = "0.5",
            .current = .{ .state = .value, .value = "0.5" },
            .changed = false,
        },
        .{
            .id = "idle-maint",
            .kind = .maintenance,
            .risk = .safe,
            .target = "idle maintenance",
            .current = .{ .state = .not_tracked },
        },
        .{
            .id = "dexopt",
            .kind = .compile,
            .risk = .safe,
            .target = "compile speed-profile (all)",
            .current = .{ .state = .not_tracked },
            .status = .skip,
            .reason = "requires SDK >= 30 (device is 29)",
        },
        .{
            .id = "disable-pkg",
            .kind = .package,
            .risk = .caution,
            .target = "com.example.app",
            .desired = "disable",
            .current = .{ .state = .not_tracked },
            .status = .blocked,
            .reason = "package 'com.example.app' is the default launcher",
        },
    };
    const plan_value: plan.Plan = .{
        .profile = "light",
        .serial = "FAKE123",
        .sdk = 29,
        .ram_total_mb = 2947,
        .steps = &steps,
    };

    var render: Render = .init();
    defer render.deinit();
    try printPlan(render.writer(), plan_value);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "profile: light\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "device: FAKE123\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "android: SDK 29\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ram: 2947 MB\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "steps: 5 (apply 3, skip 1, blocked 1)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "global/window_animation_scale  1.0 -> 0.5  [safe]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(unchanged)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "idle maintenance  (not tracked)  [safe]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(requires SDK >= 30 (device is 29))") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocked steps touch protected packages") != null);
}

test "plan report marks unknown device data" {
    var steps = [_]plan.Step{
        .{
            .id = "anim-window",
            .kind = .setting,
            .risk = .safe,
            .target = "global/window_animation_scale",
            .desired = "0.5",
            .current = .{ .state = .unset },
            .reason = "profile requires RAM <= 3072 MB, but the RAM total is unknown",
            .status = .skip,
        },
    };
    const plan_value: plan.Plan = .{
        .profile = "light",
        .serial = "EMPTY",
        .sdk = null,
        .ram_total_mb = null,
        .steps = &steps,
    };

    var render: Render = .init();
    defer render.deinit();
    try printPlan(render.writer(), plan_value);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "android: unknown\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ram: unknown\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "(unset) -> 0.5") != null);
}

test "plan JSON is machine readable" {
    var steps = [_]plan.Step{
        .{
            .id = "anim-window",
            .kind = .setting,
            .risk = .safe,
            .target = "global/window_animation_scale",
            .desired = "0.5",
            .current = .{ .state = .value, .value = "1.0" },
        },
        .{
            .id = "idle-maint",
            .kind = .maintenance,
            .risk = .safe,
            .target = "idle maintenance",
            .current = .{ .state = .not_tracked },
        },
        .{
            .id = "disable-pkg",
            .kind = .package,
            .risk = .caution,
            .target = "com.example.app",
            .desired = "disable",
            .current = .{ .state = .not_tracked },
            .status = .blocked,
            .reason = "package 'com.example.app' is the default launcher",
        },
    };
    const plan_value: plan.Plan = .{
        .profile = "light",
        .serial = "FAKE123",
        .sdk = 29,
        .ram_total_mb = 2947,
        .steps = &steps,
    };

    var render: Render = .init();
    defer render.deinit();
    try printPlanJson(std.testing.allocator, render.writer(), plan_value);
    const text = render.output();

    try std.testing.expect(std.mem.startsWith(u8, text, "{\"profile\":\"light\",\"device\":\"FAKE123\""));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"sdk\":29") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"state\":\"value\",\"value\":\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"desired\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"status\":\"blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"reason\":null") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "\"summary\":{\"apply\":2,\"skip\":0,\"blocked\":1}") != null,
    );
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
}

test "scan selection errors explain missing and multiple devices" {
    var missing: Render = .init();
    defer missing.deinit();
    try printSelectionError(missing.writer(), error.NoDevices, null, &.{});
    try std.testing.expect(
        std.mem.indexOf(u8, missing.output(), "no device connected") != null,
    );

    var multiple: Render = .init();
    defer multiple.deinit();
    try printSelectionError(multiple.writer(), error.MultipleDevices, null, &.{});
    try std.testing.expect(
        std.mem.indexOf(u8, multiple.output(), "multiple devices connected; choose one with -s") != null,
    );
}

test "scan selection errors name the serial and its state" {
    const entries = [_]adb.DeviceEntry{
        .{ .serial = "FAKE123", .state = .unauthorized, .detail = "unauthorized" },
    };

    var not_ready: Render = .init();
    defer not_ready.deinit();
    try printSelectionError(not_ready.writer(), error.DeviceNotReady, "FAKE123", &entries);
    const text = not_ready.output();
    try std.testing.expect(std.mem.indexOf(u8, text, "device 'FAKE123' is unauthorized") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "accept the USB debugging prompt") != null);

    var not_found: Render = .init();
    defer not_found.deinit();
    try printSelectionError(not_found.writer(), error.SerialNotFound, "NOPE", &entries);
    try std.testing.expect(
        std.mem.indexOf(u8, not_found.output(), "device 'NOPE' not found") != null,
    );
}

test "printError prefixes the message" {
    var render: Render = .init();
    defer render.deinit();
    try printError(render.writer(), "could not list devices");
    try std.testing.expectEqualStrings("reclaim: could not list devices\n", render.output());
}

test "apply report shows a dry run without writing a snapshot" {
    var steps = [_]apply.Step{
        .{
            .id = "anim-window",
            .kind = .setting,
            .risk = .safe,
            .target = "global/window_animation_scale",
            .before = "1.0",
            .after = "0.5",
            .status = .planned,
        },
        .{
            .id = "anim-transition",
            .kind = .setting,
            .risk = .safe,
            .target = "global/transition_animation_scale",
            .before = "1.0",
            .after = "1.0",
            .status = .unchanged,
        },
        .{
            .id = "dexopt",
            .kind = .compile,
            .risk = .safe,
            .target = "compile speed-profile (all)",
            .after = "speed-profile",
            .status = .skipped,
            .reason = "requires SDK >= 30 (device is 29)",
        },
    };
    const outcome: apply.Outcome = .{
        .mode = .apply,
        .profile = "light",
        .device = "FAKE123",
        .sdk = 29,
        .ram_total_mb = 2947,
        .dry_run = true,
        .steps = &steps,
    };

    var render: Render = .init();
    defer render.deinit();
    try printApply(render.writer(), outcome);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "mode: apply\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "snapshot: (dry run, nothing written)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dry run: yes\n") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "steps: 3 (planned 1, applied 0, reverted 0, unchanged 1, skipped 1, failed 0)\n") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "  planned   anim-window      global/window_animation_scale  1.0 -> 0.5  [safe]\n") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "compile speed-profile (all)  (not tracked) -> speed-profile") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "pass --yes to apply the plan.\n") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "to undo:") == null);
}

test "apply report lists applied and failed steps with the undo hint" {
    var steps = [_]apply.Step{
        .{
            .id = "anim-window",
            .kind = .setting,
            .risk = .safe,
            .target = "global/window_animation_scale",
            .before = "1.0",
            .after = "0.5",
            .status = .applied,
            .verified = true,
        },
        .{
            .id = "dexopt",
            .kind = .compile,
            .risk = .safe,
            .target = "compile speed-profile (all)",
            .after = "speed-profile",
            .status = .failed,
            .verified = false,
            .exit_code = 1,
            .reason = "the command exited with code 1",
        },
    };
    const outcome: apply.Outcome = .{
        .mode = .apply,
        .profile = "light",
        .device = "FAKE123",
        .sdk = 29,
        .ram_total_mb = 2947,
        .created = "2026-10-25T10:00:00Z",
        .dry_run = false,
        .snapshot_path = "/snapshots/FAKE123_20261025T100000.json",
        .log_path = "/logs/apply_FAKE123_20261025T100000.log",
        .aborted = true,
        .steps = &steps,
    };

    var render: Render = .init();
    defer render.deinit();
    try printApply(render.writer(), outcome);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "created: 2026-10-25T10:00:00Z\n") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "snapshot: /snapshots/FAKE123_20261025T100000.json\n") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "log: /logs/apply_FAKE123_20261025T100000.log\n") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "dry run: no\n") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "applied   anim-window      global/window_animation_scale  1.0 -> 0.5  [safe]  verified") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "failed    dexopt           compile speed-profile (all)  (not tracked) -> speed-profile  [safe]  (the command exited with code 1)") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "more than half of the steps failed") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "to undo: reclaim revert --snapshot \"/snapshots/FAKE123_20261025T100000.json\" --yes\n") != null,
    );
}

test "revert report reverses the direction and names the snapshot" {
    var steps = [_]apply.Step{
        .{
            .id = "anim-window",
            .kind = .setting,
            .target = "global/window_animation_scale",
            .before = "1.0",
            .after = "0.5",
            .status = .reverted,
            .verified = true,
        },
        .{
            .id = "anim-transition",
            .kind = .setting,
            .target = "global/transition_animation_scale",
            .before = null,
            .after = "0.5",
            .status = .planned,
        },
    };
    const outcome: apply.Outcome = .{
        .mode = .revert,
        .profile = "light",
        .device = "FAKE123",
        .created = "2026-10-25T10:00:00Z",
        .dry_run = true,
        .snapshot_path = "/snapshots/snap.json",
        .steps = &steps,
    };

    var render: Render = .init();
    defer render.deinit();
    try printRevert(render.writer(), outcome);
    const text = render.output();

    try std.testing.expect(std.mem.indexOf(u8, text, "mode: revert\n") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "0.5 -> 1.0") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "0.5 -> (unset)") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, text, "pass --yes to restore the snapshot.\n") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "to undo:") == null);
}

test "apply JSON is machine readable" {
    var steps = [_]apply.Step{
        .{
            .id = "anim-window",
            .kind = .setting,
            .risk = .safe,
            .target = "global/window_animation_scale",
            .before = "1.0",
            .after = "0.5",
            .status = .applied,
            .verified = true,
            .exit_code = 0,
        },
        .{
            .id = "dexopt",
            .kind = .compile,
            .risk = .safe,
            .target = "compile speed-profile (all)",
            .after = "speed-profile",
            .status = .failed,
            .verified = false,
            .exit_code = 1,
            .reason = "the command exited with code 1",
        },
    };
    const outcome: apply.Outcome = .{
        .mode = .apply,
        .profile = "light",
        .device = "FAKE123",
        .sdk = 29,
        .ram_total_mb = 2947,
        .created = "2026-10-25T10:00:00Z",
        .dry_run = false,
        .snapshot_path = "/snapshots/snap.json",
        .log_path = "/logs/apply.log",
        .steps = &steps,
    };

    var render: Render = .init();
    defer render.deinit();
    try printApplyJson(std.testing.allocator, render.writer(), outcome);
    const text = render.output();

    try std.testing.expect(std.mem.startsWith(u8, text, "{\"mode\":\"apply\",\"profile\":\"light\",\"device\":\"FAKE123\""));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"dry_run\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"snapshot_path\":\"/snapshots/snap.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"verified\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"exit_code\":1") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, text, "\"summary\":{\"planned\":0,\"applied\":1,\"reverted\":0,\"unchanged\":0,\"skipped\":0,\"failed\":1}") != null,
    );
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
}

test "revert JSON is machine readable" {
    var steps = [_]apply.Step{
        .{
            .id = "anim-window",
            .kind = .setting,
            .target = "global/window_animation_scale",
            .before = "1.0",
            .after = "0.5",
            .status = .reverted,
            .verified = true,
        },
    };
    const outcome: apply.Outcome = .{
        .mode = .revert,
        .profile = "light",
        .device = "FAKE123",
        .created = "2026-10-25T10:00:00Z",
        .dry_run = true,
        .snapshot_path = "/snapshots/snap.json",
        .steps = &steps,
    };

    var render: Render = .init();
    defer render.deinit();
    try printRevertJson(std.testing.allocator, render.writer(), outcome);
    const text = render.output();

    try std.testing.expect(std.mem.startsWith(u8, text, "{\"mode\":\"revert\""));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"dry_run\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"status\":\"reverted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"risk\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"log_path\":null") != null);
}

test "usage errors explain the failure" {
    const cases = [_]struct {
        failure: cli.Failure,
        expected: []const u8,
    }{
        .{
            .failure = .{ .kind = .missing_command },
            .expected = "reclaim: error: missing command\n",
        },
        .{
            .failure = .{ .kind = .unknown_command, .arg = "optimize" },
            .expected = "reclaim: error: unknown command 'optimize'\n",
        },
        .{
            .failure = .{ .kind = .unknown_flag, .arg = "--fast" },
            .expected = "reclaim: error: unknown option '--fast'\n",
        },
        .{
            .failure = .{ .kind = .missing_value, .arg = "--adb" },
            .expected = "reclaim: error: option '--adb' requires a value\n",
        },
        .{
            .failure = .{ .kind = .invalid_value, .arg = "--runs" },
            .expected = "reclaim: error: invalid value for option '--runs'\n",
        },
        .{
            .failure = .{ .kind = .missing_argument, .arg = "plan" },
            .expected = "reclaim: error: missing required argument for 'plan'\n",
        },
        .{
            .failure = .{ .kind = .unexpected_argument, .arg = "extra" },
            .expected = "reclaim: error: unexpected argument 'extra'\n",
        },
    };

    for (cases) |case| {
        var render: Render = .init();
        defer render.deinit();

        try usageError(render.writer(), case.failure);
        try std.testing.expect(std.mem.startsWith(u8, render.output(), case.expected));
        try std.testing.expect(
            std.mem.endsWith(u8, render.output(), "Run 'reclaim --help' for usage.\n"),
        );
    }
}
