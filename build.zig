const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "reclaim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run reclaim");
    run_step.dependOn(&run_cmd.step);

    const fake_adb = b.addExecutable(.{
        .name = "fake_adb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fake_adb/adb.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_options = b.addOptions();
    test_options.addOptionPath("fake_adb", fake_adb.getEmittedBin());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", test_options);

    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(&fake_adb.step);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
