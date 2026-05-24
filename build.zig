// This repo ships a C ABI first until further notice.
// Keep build entrypoints aligned around the shipped header and exported symbols, not privileged Zig imports.
// The render build now targets one owner-true surface package path.

const std = @import("std");

fn addStbImage(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("src"));
    module.addCSourceFile(.{ .file = b.path("src/stb_image.c") });
}

const NonProdEntry = enum {
    unit,
    runtime_proof,
    benchmark,
};

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

    const unit_root_options = b.addOptions();
    unit_root_options.addOption(NonProdEntry, "entry", .unit);
    const runtime_proof_root_options = b.addOptions();
    runtime_proof_root_options.addOption(NonProdEntry, "entry", .runtime_proof);
    const benchmark_root_options = b.addOptions();
    benchmark_root_options.addOption(NonProdEntry, "entry", .benchmark);
    const test_font_options = b.addOptions();
    test_font_options.addOption([]const u8, "primary_path", test_font_primary_path);
    test_font_options.addOption([]const u8, "symbol_path", test_font_symbol_path);
    const internal_mod = b.createModule(.{
        .root_source_file = b.path("src/non_prod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    internal_mod.addImport("non_prod_options", unit_root_options.createModule());
    internal_mod.addImport("test_font_options", test_font_options.createModule());
    internal_mod.linkLibrary(freetype_lib);
    internal_mod.addIncludePath(freetype_lib.getEmittedIncludeTree());
    internal_mod.linkLibrary(harfbuzz_lib);
    internal_mod.addIncludePath(harfbuzz_lib.getEmittedIncludeTree());
    addStbImage(internal_mod, b);

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
    const mod_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = internal_mod,
        .filters = b.args orelse &.{},
    });
    mod_tests.use_llvm = true;
    const run_mod_tests = b.addRunArtifact(mod_tests);
    if (b.args != null) {
        run_mod_tests.has_side_effects = true;
    }

    const render_owner = b.createModule(.{
        .root_source_file = b.path("src/howl_render.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    render_owner.addImport("test_font_options", test_font_options.createModule());
    render_owner.linkLibrary(freetype_lib);
    render_owner.addIncludePath(freetype_lib.getEmittedIncludeTree());
    render_owner.linkLibrary(harfbuzz_lib);
    render_owner.addIncludePath(harfbuzz_lib.getEmittedIncludeTree());
    addStbImage(render_owner, b);
    const render_tests = b.addTest(.{
        .name = "test-render",
        .root_module = render_owner,
        .filters = b.args orelse &.{},
    });
    render_tests.use_llvm = true;
    const run_render_tests = b.addRunArtifact(render_tests);
    if (b.args != null) {
        run_render_tests.has_side_effects = true;
    }

    const runtime_proof_mod = b.createModule(.{
        .root_source_file = b.path("src/non_prod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime_proof_mod.addImport("non_prod_options", runtime_proof_root_options.createModule());
    runtime_proof_mod.addImport("test_font_options", test_font_options.createModule());
    runtime_proof_mod.linkLibrary(freetype_lib);
    runtime_proof_mod.addIncludePath(freetype_lib.getEmittedIncludeTree());
    runtime_proof_mod.linkLibrary(harfbuzz_lib);
    runtime_proof_mod.addIncludePath(harfbuzz_lib.getEmittedIncludeTree());
    addStbImage(runtime_proof_mod, b);
    const runtime_proof_tests = b.addTest(.{
        .name = "test-runtime-proof",
        .root_module = runtime_proof_mod,
        .filters = b.args orelse &.{},
    });
    runtime_proof_tests.use_llvm = true;
    const run_runtime_proof_tests = b.addRunArtifact(runtime_proof_tests);
    if (b.args != null) {
        run_runtime_proof_tests.has_side_effects = true;
    }

    const test_step = b.step("test", "Run all tests");
    const test_render_step = b.step("test:render", "Run repo-local render tests");
    const test_render_build_step = b.step("test:render:build", "Build repo-local render tests");
    const test_runtime_proof_step = b.step("test:runtime-proof", "Run runtime proof tests");
    const test_runtime_proof_build_step = b.step("test:runtime-proof:build", "Build runtime proof tests");
    const test_unit_step = b.step("test:unit", "Run unit tests");
    const test_unit_build_step = b.step("test:unit:build", "Build unit tests");
    test_render_build_step.dependOn(&b.addInstallArtifact(render_tests, .{}).step);
    test_render_step.dependOn(&run_render_tests.step);
    test_runtime_proof_build_step.dependOn(&b.addInstallArtifact(runtime_proof_tests, .{}).step);
    test_runtime_proof_step.dependOn(&run_runtime_proof_tests.step);
    test_unit_build_step.dependOn(&b.addInstallArtifact(mod_tests, .{}).step);
    test_unit_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(test_render_step);
    test_step.dependOn(test_runtime_proof_step);
    test_step.dependOn(test_unit_step);

    const ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/libhowl_render.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ffi_mod.linkLibrary(freetype_lib);
    ffi_mod.addIncludePath(freetype_lib.getEmittedIncludeTree());
    ffi_mod.linkLibrary(harfbuzz_lib);
    ffi_mod.addIncludePath(harfbuzz_lib.getEmittedIncludeTree());
    addStbImage(ffi_mod, b);
    const ffi_lib = b.addLibrary(.{
        .name = "howl_render",
        .linkage = .dynamic,
        .root_module = ffi_mod,
    });
    const ffi_build_step = b.step("ffi:build", "Build the howl-render C FFI library");
    ffi_build_step.dependOn(&b.addInstallArtifact(ffi_lib, .{}).step);
    b.installArtifact(ffi_lib);
    b.installFile("include/howl_render.h", "include/howl_render.h");

    const benchmark_mod = b.createModule(.{
        .root_source_file = b.path("src/non_prod.zig"),
        .target = target,
        .optimize = perf_optimize,
        .link_libc = true,
    });
    benchmark_mod.addImport("non_prod_options", benchmark_root_options.createModule());
    benchmark_mod.addImport("test_font_options", test_font_options.createModule());
    benchmark_mod.linkLibrary(perf_freetype_lib);
    benchmark_mod.addIncludePath(perf_freetype_lib.getEmittedIncludeTree());
    benchmark_mod.linkLibrary(perf_harfbuzz_lib);
    benchmark_mod.addIncludePath(perf_harfbuzz_lib.getEmittedIncludeTree());
    addStbImage(benchmark_mod, b);

    const benchmark_exe = b.addExecutable(.{
        .name = "render_benchmark",
        .root_module = benchmark_mod,
    });
    benchmark_exe.use_llvm = true;
    const run_benchmark = b.addRunArtifact(benchmark_exe);
    if (b.args) |args| run_benchmark.addArgs(args);
    const benchmark_build_step = b.step("render-benchmark:build", "Build render benchmark suite");
    benchmark_build_step.dependOn(&b.addInstallArtifact(benchmark_exe, .{}).step);
    const benchmark_step = b.step("render-benchmark", "Run render benchmark suite");
    benchmark_step.dependOn(&run_benchmark.step);
}
