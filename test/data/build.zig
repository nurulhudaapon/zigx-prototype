const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Create WASM target with no libc
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const zx_root_ast_mod = b.createModule(.{
        .root_source_file = b.path("../../src/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const zx_minimal_mod = b.createModule(.{
        .root_source_file = b.path("zx.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zx_root", .module = zx_root_ast_mod },
        },
    });

    // --- ZX Setup (sets up ZX, dependencies, executables and `serve` step) ---
    const jsz = b.dependency("zig_js", .{ .target = wasm_target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "zx_wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zx", .module = zx_minimal_mod },
                .{ .name = "zx_root", .module = zx_root_ast_mod },
                .{ .name = "js", .module = jsz.module("zig-js") },
            },
        }),
    });

    exe.entry = .disabled;
    exe.export_memory = true;
    exe.rdynamic = true;

    b.installArtifact(exe);

    // custom's path is relative to zig-out
    const wasm_install = b.addInstallFileWithDir(
        exe.getEmittedBin(),
        .{ .custom = "../../wasm/dist" },
        "main.wasm",
    );

    const step = b.step("example", "Build the example project (Zig only)");
    step.dependOn(&wasm_install.step);
}
