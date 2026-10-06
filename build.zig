const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zmermaid", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = .Debug }) });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run native parser/layout/SVG tests").dependOn(&run_tests.step);
    const wasm = b.addExecutable(.{ .name = "zmermaid", .root_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSmall,
        .strip = true,
    }) });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.export_memory = true;
    // Compound flowcharts permit 16 nested frames. Their bounded layout
    // scratch state needs more than the linker's default 1 MiB WASM stack.
    wasm.stack_size = 4 * 1024 * 1024;
    b.getInstallStep().dependOn(&b.addInstallFile(wasm.getEmittedBin(), "zmermaid.wasm").step);
    const native = b.addLibrary(.{ .name = "zmermaid", .linkage = .static, .root_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.installArtifact(native);
    b.getInstallStep().dependOn(&run_tests.step);
    _ = module;
}
