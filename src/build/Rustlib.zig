const std = @import("std");

/// Build the TransformJS Rust library as a C dynamic library
/// Returns a build step that must be completed before linking
pub fn build(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const transformjs_dir = "packages/transformjs";

    // Build the Rust library using cargo
    const cargo_build = b.addSystemCommand(&.{ "cargo", "build", "--lib" });
    cargo_build.setCwd(b.path(transformjs_dir));

    if (optimize == .ReleaseFast or optimize == .ReleaseSafe or optimize == .ReleaseSmall) {
        cargo_build.addArg("--release");
    }

    // Convert Zig target to Rust target triple for cross-compilation
    const rust_target = toRustTarget(target.result);
    if (rust_target) |triple| {
        cargo_build.addArg("--target");
        cargo_build.addArg(triple);
    }

    return &cargo_build.step;
}

/// Convert Zig target to Rust target triple
/// Returns null for native target (cargo default)
fn toRustTarget(target: std.Target) ?[]const u8 {
    const builtin = @import("builtin");
    const is_native = target.os.tag == builtin.target.os.tag and
        target.cpu.arch == builtin.target.cpu.arch;

    if (is_native) {
        return null; // Use cargo default (native target)
    }

    // Convert to Rust target triple format
    return switch (target.os.tag) {
        .linux => switch (target.cpu.arch) {
            .x86_64 => "x86_64-unknown-linux-gnu",
            .aarch64 => "aarch64-unknown-linux-gnu",
            else => null,
        },
        .macos => switch (target.cpu.arch) {
            .x86_64 => "x86_64-apple-darwin",
            .aarch64 => "aarch64-apple-darwin",
            else => null,
        },
        .windows => switch (target.cpu.arch) {
            .x86_64 => "x86_64-pc-windows-msvc",
            .aarch64 => "aarch64-pc-windows-msvc",
            else => null,
        },
        else => null, // Unsupported OS
    };
}

pub fn link(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    build_step: *std.Build.Step,
    optimize: std.builtin.OptimizeMode,
) void {
    const target = exe.root_module.resolved_target orelse return;
    const transformjs_dir = "packages/transformjs";

    exe.step.dependOn(build_step);
    exe.addIncludePath(b.path(transformjs_dir));

    // Determine library directory - cargo puts cross-compiled libs in target/<triple>/<profile>
    const rust_target_triple = toRustTarget(target.result);
    const lib_dir = if (optimize == .ReleaseFast or optimize == .ReleaseSafe or optimize == .ReleaseSmall)
        if (rust_target_triple) |triple|
            b.pathJoin(&.{ transformjs_dir, "target", triple, "release" })
        else
            b.pathJoin(&.{ transformjs_dir, "target", "release" })
    else if (rust_target_triple) |triple|
        b.pathJoin(&.{ transformjs_dir, "target", triple, "debug" })
    else
        b.pathJoin(&.{ transformjs_dir, "target", "debug" });

    exe.addLibraryPath(b.path(lib_dir));
    exe.linkSystemLibrary("transformjs");
    exe.linkSystemLibrary("c");

    if (target.result.os.tag != .windows) {
        exe.linkSystemLibrary("dl");
    }
}
