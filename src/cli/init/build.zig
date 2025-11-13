const std = @import("std");
const zx = @import("zx");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("root_mod", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

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
