const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = blk: {
        const zon_content = b.build_root.handle.readFileAlloc(b.graph.io, "build.zig.zon", b.allocator, @enumFromInt(1024 * 1024)) catch break :blk "unknown";
        const needle = ".version = \"";
        const start_idx = std.mem.indexOf(u8, zon_content, needle) orelse break :blk "unknown";
        const start = start_idx + needle.len;
        const end = std.mem.indexOfPos(u8, zon_content, start, "\"") orelse break :blk "unknown";
        break :blk b.allocator.dupe(u8, zon_content[start..end]) catch "unknown";
    };

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.link_libc = true;
    exe_module.addImport("build_options", build_options.createModule());

    const exe = b.addExecutable(.{
        .name = "szn",
        .root_module = exe_module,
    });
    const is_darwin = target.result.os.tag.isDarwin();
    if (optimize != .Debug and !is_darwin) {
        exe.lto = .thin;
        exe.use_lld = true;
    }
    if (optimize != .Debug) exe.root_module.strip = true;
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
    test_module.addImport("build_options", build_options.createModule());

    const test_exe = b.addTest(.{
        .root_module = test_module,
    });
    if (optimize != .Debug and !is_darwin) {
        test_exe.lto = .thin;
        test_exe.use_lld = true;
    }
    const test_run = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&test_run.step);
}
