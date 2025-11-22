const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const zx_mod = b.createModule(.{
        .root_source_file = b.path("../../src/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const jsz_dep = b.dependency("zig_js", .{ .target = wasm_target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "zx_wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zx", .module = zx_mod },
                .{ .name = "js", .module = jsz_dep.module("zig-js") },
            },
        }),
    });
    exe.entry = .disabled;
    exe.export_memory = true;
    exe.rdynamic = true;

    const wasm_install = b.addInstallFileWithDir(
        exe.getEmittedBin(),
        .{ .custom = "../dist" },
        "main.wasm",
    );

    b.default_step.dependOn(&wasm_install.step);
}
