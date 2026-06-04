// This repo ships a C ABI first until further notice.
// Keep build entrypoints aligned around the shipped header and exported symbols, not privileged Zig imports.
// The render build now targets one owner-true surface package path.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const perf_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const test_font_primary_path = b.option([]const u8, "test-font-primary-path", "Explicit render proof primary font path") orelse "";
    const test_font_symbol_path = b.option([]const u8, "test-font-symbol-path", "Explicit render proof symbol fallback font path") orelse "";
    const freetype_dep = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
    });
    const freetype_lib = freetype_dep.artifact("freetype");
    const harfbuzz_dep = b.dependency("harfbuzz", .{
        .target = target,
        .optimize = optimize,
    });
    const harfbuzz_lib = harfbuzz_dep.artifact("harfbuzz");

    const test_font_options = b.addOptions();
    test_font_options.addOption([]const u8, "primary_path", test_font_primary_path);
    test_font_options.addOption([]const u8, "symbol_path", test_font_symbol_path);
    const perf_freetype_dep = b.dependency("freetype", .{
        .target = target,
        .optimize = perf_optimize,
    });
    const perf_freetype_lib = perf_freetype_dep.artifact("freetype");
    const perf_harfbuzz_dep = b.dependency("harfbuzz", .{
        .target = target,
        .optimize = perf_optimize,
    });
    const perf_harfbuzz_lib = perf_harfbuzz_dep.artifact("harfbuzz");
    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_unit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_test_mod.addIncludePath(b.path("include"));
    unit_test_mod.addIncludePath(b.path("../howl-vt/include"));
    unit_test_mod.addImport("test_font_options", test_font_options.createModule());
    unit_test_mod.linkLibrary(freetype_lib);
    unit_test_mod.addIncludePath(freetype_lib.getEmittedIncludeTree());
    unit_test_mod.linkLibrary(harfbuzz_lib);
    unit_test_mod.addIncludePath(harfbuzz_lib.getEmittedIncludeTree());
    const unit_tests = add_test_artifact(b, "test-unit", unit_test_mod);
    const run_unit_tests = add_test_run_artifact(b, unit_tests);

    const abi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_test_mod.addIncludePath(b.path("include"));
    abi_test_mod.addIncludePath(b.path("../howl-vt/include"));
    abi_test_mod.addImport("test_font_options", test_font_options.createModule());
    abi_test_mod.linkLibrary(freetype_lib);
    abi_test_mod.addIncludePath(freetype_lib.getEmittedIncludeTree());
    abi_test_mod.linkLibrary(harfbuzz_lib);
    abi_test_mod.addIncludePath(harfbuzz_lib.getEmittedIncludeTree());
    const abi_tests = add_test_artifact(b, "test-abi", abi_test_mod);
    const run_abi_tests = add_test_run_artifact(b, abi_tests);

    const check_step = b.step("check", "Compile owner surfaces without installing or running");
    const test_step = b.step("test", "Run all tests");
    const test_build_step = b.step("test:build", "Build render tests");
    const unit_test_step = b.step("test:unit", "Run render unit tests");
    const unit_test_build_step = b.step("test:unit:build", "Build render unit tests");
    const abi_test_step = b.step("test:abi", "Run shipped render ABI contract tests");
    const abi_test_build_step = b.step("test:abi:build", "Build shipped render ABI contract tests");
    unit_test_build_step.dependOn(&unit_tests.step);
    unit_test_step.dependOn(&run_unit_tests.step);
    abi_test_build_step.dependOn(&abi_tests.step);
    abi_test_step.dependOn(&run_abi_tests.step);
    test_build_step.dependOn(unit_test_build_step);
    test_build_step.dependOn(abi_test_build_step);
    test_step.dependOn(unit_test_step);
    test_step.dependOn(abi_test_step);

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/libhowl_render.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ffi_mod.addIncludePath(b.path("include"));
    ffi_mod.addIncludePath(b.path("../howl-vt/include"));
    ffi_mod.linkLibrary(freetype_lib);
    ffi_mod.addIncludePath(freetype_lib.getEmittedIncludeTree());
    ffi_mod.linkLibrary(harfbuzz_lib);
    ffi_mod.addIncludePath(harfbuzz_lib.getEmittedIncludeTree());
    const ffi_lib = b.addLibrary(.{
        .name = "howl_render",
        .linkage = .dynamic,
        .root_module = ffi_mod,
    });
    b.installArtifact(ffi_lib);
    b.installFile("include/howl_render.h", "include/howl_render.h");
    check_step.dependOn(&ffi_lib.step);
    check_step.dependOn(test_build_step);

    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark_main.zig"),
        .target = target,
        .optimize = perf_optimize,
        .link_libc = true,
    });
    benchmark_mod.addIncludePath(b.path("include"));
    benchmark_mod.addIncludePath(b.path("../howl-vt/include"));
    benchmark_mod.addImport("test_font_options", test_font_options.createModule());
    benchmark_mod.linkLibrary(perf_freetype_lib);
    benchmark_mod.addIncludePath(perf_freetype_lib.getEmittedIncludeTree());
    benchmark_mod.linkLibrary(perf_harfbuzz_lib);
    benchmark_mod.addIncludePath(perf_harfbuzz_lib.getEmittedIncludeTree());

    const benchmark_exe = b.addExecutable(.{
        .name = "render_benchmark",
        .root_module = benchmark_mod,
    });
    benchmark_exe.use_llvm = true;
    const run_benchmark = b.addRunArtifact(benchmark_exe);
    if (b.args) |args| run_benchmark.addArgs(args);
    const benchmark_build_step = b.step("benchmark:render:build", "Build the render measurement benchmark");
    benchmark_build_step.dependOn(&benchmark_exe.step);
    const benchmark_step = b.step("benchmark:render", "Run the render measurement benchmark");
    benchmark_step.dependOn(&run_benchmark.step);
    check_step.dependOn(benchmark_build_step);
}

fn add_test_artifact(b: *std.Build, name: []const u8, root_module: *std.Build.Module) *std.Build.Step.Compile {
    const tests = b.addTest(.{
        .name = name,
        .root_module = root_module,
        .filters = b.args orelse &.{},
    });
    tests.use_llvm = true;
    return tests;
}

fn add_test_run_artifact(b: *std.Build, tests: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run_tests = b.addRunArtifact(tests);
    if (b.args != null) {
        run_tests.has_side_effects = true;
    }
    return run_tests;
}
