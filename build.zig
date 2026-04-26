const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize_option = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)");
    const optimize = optimize_option orelse .ReleaseFast;

    // ============================================================
    // Main executable (nom)
    // ============================================================
    const exe = b.addExecutable(.{
        .name = "nom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ============================================================
    // Tests
    // ============================================================
    // Test the main executable module. Since `nom` imports `fd/main.zig`,
    // which imports the rest of the fd module tree, this single test step
    // exercises both the fzf/tui side and the fd side.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // ============================================================
    // Benchmarks
    // ============================================================
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    b.installArtifact(bench_exe);

    const bench_step = b.step("bench", "Run benchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);

    // ============================================================
    // Install to ~/bin
    // ============================================================
    const home_install_step = b.step("home", "Install nom to ~/bin");
    const home = b.graph.environ_map.get("HOME") orelse "/tmp";
    const dest_path = b.fmt("{s}/bin/nom", .{home});
    // `install` preserves the binary's ad-hoc code signature across the write;
    // `cp` can invalidate it on macOS and cause SIGKILL at exec.
    const copy_step = b.addSystemCommand(&.{ "install", "-m", "755" });
    copy_step.addArtifactArg(exe);
    copy_step.addArg(dest_path);
    home_install_step.dependOn(&copy_step.step);
}
