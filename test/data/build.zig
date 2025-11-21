const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const zx_dep = b.dependency("zx", .{ .target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    }), .optimize = optimize });

    // --- ZX Setup (sets up ZX, dependencies, executables and `serve` step) ---
    const exe = b.addExecutable(.{
        .name = "zx_site",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main_wasm.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zx", .module = zx_dep.module("zx") },
            },
        }),
    });

    exe.entry = .disabled;
    exe.export_memory = true;
    exe.rdynamic = true;

    b.installArtifact(exe);
}
