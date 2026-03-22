const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zcs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const example = b.addExecutable(.{
        .name = "zcs-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zcs", .module = mod },
            },
        }),
    });

    b.installArtifact(example);

    const example_run = b.addRunArtifact(example);
    example_run.step.dependOn(b.getInstallStep());
    const example_step = b.step("example", "Run the example");
    example_step.dependOn(&example_run.step);

    const bench = b.addExecutable(.{
        .name = "zcs-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zcs", .module = mod },
            },
        }),
    });

    b.installArtifact(bench);

    const bench_run = b.addRunArtifact(bench);
    bench_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_run.addArgs(args);
    }
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_run.step);
}
