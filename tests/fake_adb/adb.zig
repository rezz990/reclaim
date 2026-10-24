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
        if (std.mem.startsWith(u8, shell_command, "sh ")) {
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
