const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "szn",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run szn");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.link_libc = true;

    const test_exe = b.addTest(.{
        .root_module = test_module,
    });
    const test_run = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&test_run.step);
}
