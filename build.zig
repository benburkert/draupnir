const builtin = @import("builtin");
const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("draupnir", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (target.result.os.tag.isDarwin()) {
        const translate_c = b.dependency("translate_c", .{});
        const translator: Translator = .init(translate_c, .{
            .c_source_file = b.path("src/darwin.h"),
            .target = target,
            .optimize = optimize,
        });

        mod.addImport("darwin", translator.mod);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const exe_bench = b.addExecutable(.{
        .name = "draupnir-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "draupnir", .module = mod },
            },
        }),
    });
    b.installArtifact(exe_bench);

    const bench_step = b.step("bench", "Run the benchmarks");
    bench_step.dependOn(&exe_bench.step);
}
