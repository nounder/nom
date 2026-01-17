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
    // fd executable (nom-fd)
    // ============================================================
    const fd_exe = b.addExecutable(.{
        .name = "nom-fd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fd/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(fd_exe);

    const fd_run_step = b.step("fd", "Run the fd-like file finder");
    const fd_run_cmd = b.addRunArtifact(fd_exe);
    fd_run_step.dependOn(&fd_run_cmd.step);
    fd_run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        fd_run_cmd.addArgs(args);
    }

    // ============================================================
    // Tests
    // ============================================================
    // Test the main executable module
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Test the fd module
    const fd_tests = b.addTest(.{
        .root_module = fd_exe.root_module,
    });
    const run_fd_tests = b.addRunArtifact(fd_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_fd_tests.step);

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
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const dest_path = b.fmt("{s}/bin/nom", .{home});
    const copy_step = b.addSystemCommand(&.{ "cp", "-f" });
    copy_step.addArtifactArg(exe);
    copy_step.addArg(dest_path);
    home_install_step.dependOn(&copy_step.step);
}
