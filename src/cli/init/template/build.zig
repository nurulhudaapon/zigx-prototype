const std = @import("std");
const zx = @import("zx");

pub fn build(b: *std.Build) void {
    // --- Target and Optimize from `zig build` arguments ---
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Root Module ---
    const mod = b.addModule("root_mod", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- ZX Setup (sets up ZX, dependencies, executables and `serve` step) ---
    zx.setup(b, .{
        .name = "zx_site",
        .root_module = b.createModule(.{
            .root_source_file = b.path("site/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "root_mod", .module = mod },
            },
        }),
    });
}
