//! Fake adb used by the test suite. The scenario is selected by the name the
//! binary was copied to: `fake_<scenario>[.exe]`. Any other name (for example a
//! copy called `adb.exe`) behaves like the healthy `ok` scenario.

const std = @import("std");

const exit_marker = "; echo __RC=$?";
const track_payloads = [_][]const u8{
    "FAKE123\tdevice\n",
    "FAKE123\tdevice\nFAKE456\toffline\n",
    "FAKE456\toffline\n",
    "",
};

const getprop_android10 =
    \\[ro.build.version.sdk]: [29]
    \\[ro.build.version.release]: [10]
    \\[ro.product.manufacturer]: [Xiaomi]
    \\[ro.product.model]: [Redmi Note 5]
    \\[ro.product.cpu.abi]: [arm64-v8a]
    \\[ro.config.low_ram]: [false]
    \\[ro.serialno]: [FAKE123]
    \\
;

const getprop_android14 =
    \\[ro.build.version.sdk]: [34]
    \\[ro.build.version.release]: [14]
    \\[ro.product.manufacturer]: [Google]
    \\[ro.product.model]: [Pixel 7]
    \\[ro.product.cpu.abi]: [arm64-v8a]
    \\[ro.config.low_ram]: [false]
    \\[ro.serialno]: [FAKE123]
    \\
;

const getprop_partial =
    \\[ro.build.version.sdk]: [30]
    \\[ro.build.version.release]: []
    \\[ro.product.manufacturer]: []
    \\[ro.product.model]: []
    \\[ro.product.cpu.abi]: []
    \\[ro.config.low_ram]: [sometimes]
    \\
;

const getprop_plan_balanced =
    \\[ro.build.version.sdk]: [33]
    \\[ro.build.version.release]: [13]
    \\[ro.product.manufacturer]: [Google]
    \\[ro.product.model]: [Pixel 6a]
    \\[ro.product.cpu.abi]: [arm64-v8a]
    \\[ro.config.low_ram]: [false]
    \\[ro.serialno]: [FAKE123]
    \\
;

const meminfo_light =
    \\MemTotal:        3018420 kB
    \\MemFree:          204800 kB
    \\MemAvailable:     812340 kB
    \\
;

const meminfo_default =
    \\MemTotal:        3891200 kB
    \\MemFree:          512000 kB
    \\MemAvailable:    1290000 kB
    \\
;

const meminfo_roomy =
    \\MemTotal:        8100000 kB
    \\MemFree:         2048000 kB
    \\MemAvailable:    4100000 kB
    \\
;

const meminfo_plan_balanced =
    \\MemTotal:        3900000 kB
    \\MemFree:          512000 kB
    \\MemAvailable:    1290000 kB
    \\
;

const meminfo_partial =
    \\MemFree:          204800 kB
    \\SwapTotal:             0 kB
    \\
;

const SettingPair = struct {
    query: []const u8,
    value: []const u8,
};

const settings_light = [_]SettingPair{
    .{ .query = "global window_animation_scale", .value = "1.0" },
    .{ .query = "global transition_animation_scale", .value = "0.5" },
    .{ .query = "global animator_duration_scale", .value = "null" },
};

const settings_balanced = [_]SettingPair{
    .{ .query = "global window_animation_scale", .value = "1.0" },
    .{ .query = "global transition_animation_scale", .value = "0.5" },
    .{ .query = "global animator_duration_scale", .value = "null" },
    .{ .query = "global settings_enable_monitor_phantom_procs", .value = "true" },
};

const deny_components = struct {
    const launcher = "com.example.launcher/.Home";
    const keyboard = "com.example.keyboard/.Ime";
    const dialer = "com.example.dialer/.Dial";
    const sms = "com.example.sms/.Sms";
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const self_path = try std.process.executablePathAlloc(init.io, arena);
    const scenario = scenarioFromPath(self_path);
    const args = try init.minimal.args.toSlice(arena);
    const rest: []const []const u8 = if (args.len > 1) args[1..] else args[0..0];

    var out_buffer: [4096]u8 = undefined;
    var out_file: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    defer out_file.interface.flush() catch {};
    var err_buffer: [4096]u8 = undefined;
    var err_file: std.Io.File.Writer = .init(.stderr(), init.io, &err_buffer);
    defer err_file.interface.flush() catch {};

    const out = &out_file.interface;
    const err = &err_file.interface;

    if (std.mem.eql(u8, scenario, "slow")) {
        std.Io.sleep(init.io, std.Io.Duration.fromMilliseconds(10_000), .awake) catch {};
    }

    const command_index = commandArgIndex(rest);
    const command = if (command_index < rest.len) rest[command_index] else "";
    if (std.mem.eql(u8, command, "version")) {
        try out.print(
            "Android Debug Bridge version 1.0.41\nVersion 36.0.0-reclaim-fake\nInstalled as {s}\n",
            .{self_path},
        );
        return 0;
    }
    if (std.mem.eql(u8, command, "start-server")) {
        if (std.mem.eql(u8, scenario, "serverfail")) {
            try err.writeAll("error: could not start the adb server\n");
            return 1;
        }
        return 0;
    }
    if (std.mem.eql(u8, command, "devices")) {
        try out.writeAll("List of devices attached\n");
        if (std.mem.eql(u8, scenario, "unauthorized")) {
            try out.writeAll("FAKE123\tunauthorized\n");
        } else if (std.mem.eql(u8, scenario, "multi")) {
            try out.writeAll("FAKE123\tdevice\nFAKE456\toffline\n");
        } else if (std.mem.eql(u8, scenario, "none")) {
            // Header only: no devices attached.
        } else {
            try out.writeAll("FAKE123\tdevice\n");
        }
        return 0;
    }
    if (std.mem.eql(u8, command, "track-devices")) {
        if (std.mem.eql(u8, scenario, "track")) {
            for (track_payloads) |payload| try writeTrackMessage(out, payload);
        } else {
            try writeTrackMessage(out, "FAKE123\tdevice\n");
        }
        return 0;
    }
    if (std.mem.eql(u8, command, "push")) {
        if (std.mem.eql(u8, scenario, "pushfail")) {
            try err.writeAll("error: failed to copy the script to the device\n");
            return 1;
        }
        const push_args = rest[command_index + 1 ..];
        if (push_args.len >= 2) {
            try storeScript(
                arena,
                init.io,
                self_path,
                push_args[push_args.len - 2],
                push_args[push_args.len - 1],
            );
        }
        return 0;
    }
    if (std.mem.eql(u8, command, "shell")) {
        if (std.mem.eql(u8, scenario, "unauthorized")) {
            try err.writeAll("error: device unauthorized\n");
            return 1;
        }
        return runShell(
            arena,
            init.io,
            scenario,
            self_path,
            rest[command_index + 1 ..],
            out,
        );
    }
    if (std.mem.eql(u8, command, "exit-7")) {
        try err.writeAll("boom\n");
        return 7;
    }

    try err.print("fake adb: unknown command '{s}'\n", .{command});
    return 1;
}

const max_state_bytes = 1 << 20;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn runShell(
    alloc: std.mem.Allocator,
    io: std.Io,
    scenario: []const u8,
    self_path: []const u8,
    args: []const []const u8,
    out: *std.Io.Writer,
) !u8 {
    if (args.len == 2 and eql(args[0], "sh")) {
        return runStoredScript(alloc, io, scenario, self_path, args[1], out);
    }
    if (args.len >= 3 and eql(args[0], "rm") and eql(args[1], "-f")) {
        const path = try scriptPath(alloc, self_path, args[2]);
        defer alloc.free(path);
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        return 0;
    }

    const joined = try std.mem.join(alloc, " ", args);
    defer alloc.free(joined);
    const marked = std.mem.endsWith(u8, joined, exit_marker);
    const command = if (marked) joined[0 .. joined.len - exit_marker.len] else joined;

    const rc = try runDeviceCommand(alloc, io, scenario, self_path, command, out);
    if (marked) try out.print("__RC={d}\n", .{rc});
    return 0;
}

fn runStoredScript(
    alloc: std.mem.Allocator,
    io: std.Io,
    scenario: []const u8,
    self_path: []const u8,
    remote: []const u8,
    out: *std.Io.Writer,
) !u8 {
    const path = try scriptPath(alloc, self_path, remote);
    defer alloc.free(path);

    const script = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_state_bytes)) catch {
        try out.writeAll("__RC=1\n");
        return 0;
    };
    defer alloc.free(script);

    var rc: u8 = 0;
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "echo \"__STEP=")) {
            const rest_line = line["echo \"__STEP=".len..];
            const id_end = std.mem.indexOf(u8, rest_line, " __RC=") orelse rest_line.len;
            try out.print("__STEP={s} __RC={d}\n", .{ rest_line[0..id_end], rc });
            rc = 0;
            continue;
        }
        rc = try runDeviceCommand(alloc, io, scenario, self_path, line, out);
    }
    try out.print("__RC={d}\n", .{rc});
    return 0;
}

fn runDeviceCommand(
    alloc: std.mem.Allocator,
    io: std.Io,
    scenario: []const u8,
    self_path: []const u8,
    command: []const u8,
    out: *std.Io.Writer,
) !u8 {
    const tokens = try tokenize(alloc, command);
    if (tokens.len == 0) return 0;

    if (eql(tokens[0], "getprop")) {
        try out.writeAll(getpropFor(scenario));
        return 0;
    }
    if (eql(tokens[0], "cat") and tokens.len >= 2 and eql(tokens[1], "/proc/meminfo")) {
        try out.writeAll(meminfoFor(scenario));
        return 0;
    }

    if (eql(tokens[0], "settings") and tokens.len >= 4) {
        const state_path = try statePath(alloc, self_path);
        defer alloc.free(state_path);
        if (eql(tokens[1], "get")) {
            if (eql(scenario, "deny_fail") and
                eql(tokens[2], "secure") and eql(tokens[3], "default_input_method"))
            {
                return 1;
            }
            try printSetting(alloc, io, state_path, "setting", scenario, tokens[2], tokens[3], out);
            return 0;
        }
        if (eql(tokens[1], "put") and tokens.len >= 5) {
            if (mutationFails(scenario)) return 1;
            if (eql(scenario, "apply_liar")) return 0;
            try rewriteState(alloc, io, state_path, &.{ "setting", tokens[2], tokens[3] }, tokens[4]);
            return 0;
        }
        if (eql(tokens[1], "delete")) {
            if (mutationFails(scenario)) return 1;
            try rewriteState(alloc, io, state_path, &.{ "setting", tokens[2], tokens[3] }, null);
            return 0;
        }
    }

    if (eql(tokens[0], "device_config") and tokens.len >= 4) {
        const state_path = try statePath(alloc, self_path);
        defer alloc.free(state_path);
        if (eql(tokens[1], "get")) {
            const stored = try getStateValue(
                alloc,
                io,
                state_path,
                &.{ "device_config", tokens[2], tokens[3] },
            );
            if (stored) |value| {
                defer alloc.free(value);
                try out.print("{s}\n", .{value});
            } else {
                const query = try std.mem.join(alloc, " ", &.{ tokens[2], tokens[3] });
                defer alloc.free(query);
                try out.print("{s}\n", .{deviceConfigValue(scenario, query)});
            }
            return 0;
        }
        if (eql(tokens[1], "put") and tokens.len >= 5) {
            if (mutationFails(scenario)) return 1;
            try rewriteState(
                alloc,
                io,
                state_path,
                &.{ "device_config", tokens[2], tokens[3] },
                tokens[4],
            );
            return 0;
        }
        if (eql(tokens[1], "delete")) {
            if (mutationFails(scenario)) return 1;
            try rewriteState(alloc, io, state_path, &.{ "device_config", tokens[2], tokens[3] }, null);
            return 0;
        }
    }

    if (eql(tokens[0], "cmd") and tokens.len >= 3) {
        if (eql(tokens[1], "package") and eql(tokens[2], "resolve-activity")) {
            if (eql(scenario, "deny")) {
                if (std.mem.indexOf(u8, command, "android.intent.category.HOME") != null) {
                    try out.writeAll("priority=0\n");
                    try out.writeAll(deny_components.launcher);
                } else if (std.mem.indexOf(u8, command, "android.intent.action.DIAL") != null) {
                    try out.writeAll(deny_components.dialer);
                } else {
                    try out.writeAll(deny_components.sms);
                }
                try out.writeAll("\n");
            } else if (eql(scenario, "resolve_fail")) {
                return 1;
            }
            return 0;
        }
        if (eql(tokens[1], "package") and eql(tokens[2], "compile")) {
            if (mutationFails(scenario)) return 1;
            if (eql(scenario, "apply_fail") and std.mem.indexOf(u8, command, "--reset") == null) {
                return 1;
            }
            return 0;
        }
        if (eql(tokens[1], "package") and eql(tokens[2], "install-existing") and tokens.len >= 4) {
            if (mutationFails(scenario)) return 1;
            const state_path = try statePath(alloc, self_path);
            defer alloc.free(state_path);
            try rewriteState(alloc, io, state_path, &.{ "package", tokens[3] }, "installed");
            return 0;
        }
        if (eql(tokens[1], "appops") and eql(tokens[2], "set") and tokens.len >= 6) {
            if (mutationFails(scenario)) return 1;
            const state_path = try statePath(alloc, self_path);
            defer alloc.free(state_path);
            try rewriteState(alloc, io, state_path, &.{ "appops", tokens[3], tokens[4] }, tokens[5]);
            return 0;
        }
        return 0;
    }

    if (eql(tokens[0], "pm") and tokens.len >= 2) {
        if (eql(tokens[1], "list")) return 0;
        if (eql(tokens[1], "disable-user") or eql(tokens[1], "enable") or eql(tokens[1], "uninstall")) {
            if (mutationFails(scenario)) return 1;
            const state_path = try statePath(alloc, self_path);
            defer alloc.free(state_path);
            const value = if (eql(tokens[1], "disable-user"))
                "disabled"
            else if (eql(tokens[1], "enable"))
                "enabled"
            else
                "uninstalled";
            try rewriteState(alloc, io, state_path, &.{ "package", tokens[tokens.len - 1] }, value);
            return 0;
        }
    }

    if (eql(tokens[0], "am") and tokens.len >= 3 and eql(tokens[1], "set-standby-bucket")) {
        if (mutationFails(scenario)) return 1;
        const state_path = try statePath(alloc, self_path);
        defer alloc.free(state_path);
        try rewriteState(alloc, io, state_path, &.{ "bucket", tokens[2] }, tokens[3]);
        return 0;
    }

    if (eql(tokens[0], "wm")) {
        if (tokens.len >= 3) {
            if (mutationFails(scenario)) return 1;
            const state_path = try statePath(alloc, self_path);
            defer alloc.free(state_path);
            if (eql(tokens[2], "reset")) {
                try rewriteState(alloc, io, state_path, &.{ "wm", tokens[1] }, null);
            } else {
                try rewriteState(alloc, io, state_path, &.{ "wm", tokens[1] }, tokens[2]);
            }
        }
        return 0;
    }

    if (eql(tokens[0], "sm") and tokens.len >= 2 and eql(tokens[1], "idle-maint")) {
        if (mutationFails(scenario)) return 1;
        return 0;
    }
    if (eql(tokens[0], "false")) return 1;
    if (eql(tokens[0], "echo")) {
        try out.print("{s}\n", .{command["echo ".len..]});
        return 0;
    }
    return 0;
}

fn tokenize(alloc: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < command.len) {
        while (index < command.len and (command[index] == ' ' or command[index] == '\t')) {
            index += 1;
        }
        if (index >= command.len) break;

        var token: std.ArrayList(u8) = .empty;
        var single = false;
        var double = false;
        while (index < command.len) {
            const char = command[index];
            if (single) {
                if (char == '\'') {
                    single = false;
                } else {
                    try token.append(alloc, char);
                }
                index += 1;
            } else if (double) {
                if (char == '"') {
                    double = false;
                } else {
                    try token.append(alloc, char);
                }
                index += 1;
            } else if (char == '\'') {
                single = true;
                index += 1;
            } else if (char == '"') {
                double = true;
                index += 1;
            } else if (char == ' ' or char == '\t') {
                break;
            } else {
                try token.append(alloc, char);
                index += 1;
            }
        }
        try tokens.append(alloc, try token.toOwnedSlice(alloc));
    }
    return tokens.toOwnedSlice(alloc);
}

fn printSetting(
    alloc: std.mem.Allocator,
    io: std.Io,
    state_path: []const u8,
    kind: []const u8,
    scenario: []const u8,
    namespace: []const u8,
    key: []const u8,
    out: *std.Io.Writer,
) !void {
    const stored = try getStateValue(alloc, io, state_path, &.{ kind, namespace, key });
    if (stored) |value| {
        defer alloc.free(value);
        try out.print("{s}\n", .{value});
        return;
    }
    const query = try std.mem.join(alloc, " ", &.{ namespace, key });
    defer alloc.free(query);
    try out.print("{s}\n", .{settingValue(scenario, query)});
}

fn statePath(alloc: std.mem.Allocator, self_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(self_path) orelse ".";
    return std.fs.path.join(alloc, &.{ dir, ".fake_adb_state" });
}

fn scriptPath(alloc: std.mem.Allocator, self_path: []const u8, remote: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(self_path) orelse ".";
    return std.fs.path.join(alloc, &.{ dir, std.fs.path.basename(remote) });
}

fn storeScript(
    alloc: std.mem.Allocator,
    io: std.Io,
    self_path: []const u8,
    local: []const u8,
    remote: []const u8,
) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, local, alloc, .limited(max_state_bytes));
    defer alloc.free(data);
    const path = try scriptPath(alloc, self_path, remote);
    defer alloc.free(path);
    try writeAbsolute(io, path, data);
}

fn mutationFails(scenario: []const u8) bool {
    return eql(scenario, "apply_broken");
}

fn writeAbsolute(io: std.Io, path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

fn joinKey(alloc: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (parts, 0..) |part, index| {
        if (index != 0) try out.append(alloc, '\t');
        try out.appendSlice(alloc, part);
    }
    return out.toOwnedSlice(alloc);
}

fn getStateValue(
    alloc: std.mem.Allocator,
    io: std.Io,
    state_path: []const u8,
    parts: []const []const u8,
) !?[]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(
        io,
        state_path,
        alloc,
        .limited(max_state_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(text);

    const key = try joinKey(alloc, parts);
    defer alloc.free(key);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse continue;
        if (!eql(line[0..tab], key)) continue;
        return try alloc.dupe(u8, line[tab + 1 ..]);
    }
    return null;
}

fn rewriteState(
    alloc: std.mem.Allocator,
    io: std.Io,
    state_path: []const u8,
    parts: []const []const u8,
    value: ?[]const u8,
) !void {
    const existing = std.Io.Dir.cwd().readFileAlloc(
        io,
        state_path,
        alloc,
        .limited(max_state_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => try alloc.dupe(u8, ""),
        else => return err,
    };
    defer alloc.free(existing);

    const key = try joinKey(alloc, parts);
    defer alloc.free(key);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var found = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse {
            try out.appendSlice(alloc, line);
            try out.append(alloc, '\n');
            continue;
        };
        if (!eql(line[0..tab], key)) {
            try out.appendSlice(alloc, line);
            try out.append(alloc, '\n');
            continue;
        }
        found = true;
        if (value) |text| {
            try out.appendSlice(alloc, key);
            try out.append(alloc, '\t');
            try out.appendSlice(alloc, text);
            try out.append(alloc, '\n');
        }
    }
    if (!found) {
        if (value) |text| {
            try out.appendSlice(alloc, key);
            try out.append(alloc, '\t');
            try out.appendSlice(alloc, text);
            try out.append(alloc, '\n');
        }
    }
    try writeAbsolute(io, state_path, out.items);
}

fn getpropFor(scenario: []const u8) []const u8 {
    if (std.mem.eql(u8, scenario, "scan_roomy")) return getprop_android14;
    if (std.mem.eql(u8, scenario, "scan_partial")) return getprop_partial;
    if (std.mem.eql(u8, scenario, "plan_balanced")) return getprop_plan_balanced;
    return getprop_android10;
}

fn meminfoFor(scenario: []const u8) []const u8 {
    if (std.mem.eql(u8, scenario, "scan_light")) return meminfo_light;
    if (std.mem.eql(u8, scenario, "scan_roomy")) return meminfo_roomy;
    if (std.mem.eql(u8, scenario, "scan_partial")) return meminfo_light;
    if (std.mem.eql(u8, scenario, "scan_no_ram")) return meminfo_partial;
    if (std.mem.eql(u8, scenario, "plan_balanced")) return meminfo_plan_balanced;
    if (std.mem.eql(u8, scenario, "apply_fail")) return meminfo_light;
    if (std.mem.eql(u8, scenario, "apply_broken")) return meminfo_light;
    if (std.mem.eql(u8, scenario, "apply_liar")) return meminfo_light;
    return meminfo_default;
}

fn settingValue(scenario: []const u8, query: []const u8) []const u8 {
    if (std.mem.eql(u8, scenario, "scan_light")) return lookupSetting(&settings_light, query);
    if (std.mem.eql(u8, scenario, "plan_balanced")) return lookupSetting(&settings_balanced, query);
    if (std.mem.eql(u8, scenario, "deny") and
        std.mem.eql(u8, query, "secure default_input_method"))
    {
        return deny_components.keyboard;
    }
    return "null";
}

fn lookupSetting(table: []const SettingPair, query: []const u8) []const u8 {
    for (table) |pair| {
        if (std.mem.eql(u8, pair.query, query)) return pair.value;
    }
    return "null";
}

fn deviceConfigValue(scenario: []const u8, query: []const u8) []const u8 {
    if (std.mem.eql(u8, scenario, "plan_balanced") and
        std.mem.eql(u8, query, "activity_manager max_phantom_processes"))
    {
        return "32";
    }
    return "null";
}

fn commandArgIndex(args: []const []const u8) usize {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-s")) {
            index += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') continue;
        break;
    }
    return index;
}

fn scenarioFromPath(path: []const u8) []const u8 {
    var name = std.fs.path.basename(path);
    if (std.ascii.endsWithIgnoreCase(name, ".exe")) name = name[0 .. name.len - ".exe".len];
    const prefix = "fake_";
    if (std.mem.startsWith(u8, name, prefix)) return name[prefix.len..];
    return "ok";
}

fn writeTrackMessage(writer: *std.Io.Writer, payload: []const u8) !void {
    try writer.print("{x:0>4}", .{payload.len});
    try writer.writeAll(payload);
}

test "scenario comes from the copied name" {
    try std.testing.expectEqualStrings("ok", scenarioFromPath("/tmp/adb"));
    try std.testing.expectEqualStrings("ok", scenarioFromPath("C:\\tools\\adb.exe"));
    try std.testing.expectEqualStrings("unauthorized", scenarioFromPath("/tmp/fake_unauthorized"));
    try std.testing.expectEqualStrings("track", scenarioFromPath("/tmp/fake_track.exe"));
}
