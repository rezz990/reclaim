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
        return 0;
    }
    if (std.mem.eql(u8, command, "shell")) {
        const shell_args = rest[command_index + 1 ..];
        const joined = try std.mem.join(arena, " ", shell_args);
        const shell_command = if (std.mem.endsWith(u8, joined, exit_marker))
            joined[0 .. joined.len - exit_marker.len]
        else
            joined;

        if (std.mem.eql(u8, scenario, "unauthorized")) {
            try err.writeAll("error: device unauthorized\n");
            return 1;
        }
        if (std.mem.eql(u8, shell_command, "getprop")) {
            try out.writeAll(getpropFor(scenario));
            try out.writeAll("__RC=0\n");
        } else if (std.mem.eql(u8, shell_command, "cat /proc/meminfo")) {
            try out.writeAll(meminfoFor(scenario));
            try out.writeAll("__RC=0\n");
        } else if (std.mem.startsWith(u8, shell_command, "settings get ")) {
            const query = shell_command["settings get ".len..];
            if (std.mem.eql(u8, scenario, "deny_fail") and
                std.mem.eql(u8, query, "secure default_input_method"))
            {
                try out.writeAll("__RC=1\n");
            } else {
                try out.print("{s}\n__RC=0\n", .{settingValue(scenario, query)});
            }
        } else if (std.mem.startsWith(u8, shell_command, "device_config get ")) {
            const query = shell_command["device_config get ".len..];
            try out.print("{s}\n__RC=0\n", .{deviceConfigValue(scenario, query)});
        } else if (std.mem.startsWith(u8, shell_command, "cmd package resolve-activity")) {
            if (std.mem.eql(u8, scenario, "deny")) {
                if (std.mem.indexOf(u8, shell_command, "android.intent.category.HOME") != null) {
                    try out.writeAll("priority=0\n");
                    try out.writeAll(deny_components.launcher);
                } else if (std.mem.indexOf(u8, shell_command, "android.intent.action.DIAL") != null) {
                    try out.writeAll(deny_components.dialer);
                } else {
                    try out.writeAll(deny_components.sms);
                }
                try out.writeAll("\n__RC=0\n");
            } else if (std.mem.eql(u8, scenario, "resolve_fail")) {
                try out.writeAll("__RC=1\n");
            } else {
                try out.writeAll("__RC=0\n");
            }
        } else if (std.mem.startsWith(u8, shell_command, "sh ")) {
            try out.writeAll("__STEP=anim-window __RC=0\n");
            try out.writeAll("__STEP=dexopt __RC=1\n");
            try out.writeAll("__RC=0\n");
        } else if (std.mem.startsWith(u8, shell_command, "false")) {
            try out.writeAll("__RC=1\n");
        } else if (std.mem.startsWith(u8, shell_command, "echo ")) {
            try out.print("{s}\n__RC=0\n", .{shell_command["echo ".len..]});
        } else {
            try out.writeAll("__RC=0\n");
        }
        return 0;
    }
    if (std.mem.eql(u8, command, "exit-7")) {
        try err.writeAll("boom\n");
        return 7;
    }

    try err.print("fake adb: unknown command '{s}'\n", .{command});
    return 1;
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
