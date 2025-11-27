const std = @import("std");
const zx_build_zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- TransformJS Rust Library ---
    // const transformjs_build_step = buildTransformJs(b, target, optimize);

    // --- ZX Core ---
    const mod = b.addModule("zx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const httpz_dep = b.dependency("httpz", .{ .target = target, .optimize = optimize });
    mod.addImport("httpz", httpz_dep.module("httpz"));

    const options = b.addOptions();
    options.addOption([]const u8, "version_string", zx_build_zon.version);
    options.addOption([]const u8, "description", zx_build_zon.description);
    options.addOption([]const u8, "repository", zx_build_zon.repository);
    mod.addOptions("zx_info", options);

    // --- ZX CLI (Transpiler, Exporter, Dev Server) ---
    const zli_dep = b.dependency("zli", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "zx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zx", .module = mod },
                .{ .name = "httpz", .module = httpz_dep.module("httpz") },
                .{ .name = "zli", .module = zli_dep.module("zli") },
            },
        }),
    });

    // Link TransformJS Rust library
    // linkTransformJs(b, exe, transformjs_build_step, optimize);

    b.installArtifact(exe);

    // --- ZX LSP ---
    const zls_dep = b.dependency("zls", .{ .target = target, .optimize = optimize });
    const zxls_exe = b.addExecutable(.{
        .name = "zxls",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zls", .module = zls_dep.module("zls") },
            },
        }),
    });
    _ = zxls_exe;
    // b.installArtifact(zxls_exe);

    // --- Steps: Run ---
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // --- ZX Site (Docs, Example, sample) ---
    setupZxDocSite(b, exe, mod, .{
        .name = "zx_site",
        .root_module = b.createModule(.{
            .root_source_file = b.path("site/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zx", .module = mod },
            },
        }),
    });

    // --- Steps: Test ---
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Create transpiler test module and test executable
    const testing_mod = b.createModule(.{
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zx", .module = mod },
        },
    });
    const testing_mod_tests = b.addTest(.{
        .root_module = testing_mod,
        .test_runner = .{ .path = b.path("test/runner.zig"), .mode = .simple },
    });
    const run_transpiler_tests = b.addRunArtifact(testing_mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_transpiler_tests.step);

    // --- Cross-compilation targets for releases ---
    const release_targets = [_]struct {
        name: []const u8,
        target: std.Target.Query,
    }{
        .{ .name = "linux-x64", .target = .{ .cpu_arch = .x86_64, .os_tag = .linux } },
        .{ .name = "linux-aarch64", .target = .{ .cpu_arch = .aarch64, .os_tag = .linux } },
        .{ .name = "macos-x64", .target = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        .{ .name = "macos-aarch64", .target = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .name = "windows-x64", .target = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
        .{ .name = "windows-aarch64", .target = .{ .cpu_arch = .aarch64, .os_tag = .windows } },
    };

    const release_step = b.step("release", "Build release binaries for all targets");

    for (release_targets) |release_target| {
        const resolved_target = b.resolveTargetQuery(release_target.target);
        const release_exe = b.addExecutable(.{
            .name = "zx",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved_target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "zx", .module = mod },
                    .{ .name = "httpz", .module = httpz_dep.module("httpz") },
                    .{ .name = "zli", .module = zli_dep.module("zli") },
                },
            }),
        });

        // Link TransformJS Rust library for release builds
        // const release_transformjs_build_step = buildTransformJs(b, resolved_target, .ReleaseFast);
        // linkTransformJs(b, release_exe, release_transformjs_build_step, .ReleaseFast);

        const exe_ext = if (resolved_target.result.os.tag == .windows) ".exe" else "";
        const install_release = b.addInstallArtifact(release_exe, .{
            .dest_sub_path = b.fmt("release/zx-{s}{s}", .{ release_target.name, exe_ext }),
        });

        const target_step = b.step(b.fmt("release-{s}", .{release_target.name}), b.fmt("Build release binary for {s}", .{release_target.name}));
        target_step.dependOn(&install_release.step);
        release_step.dependOn(&install_release.step);
    }
}

pub fn setup(b: *std.Build, options: std.Build.ExecutableOptions) void {
    const target = options.root_module.resolved_target;
    const optimize = options.root_module.optimize;

    const zx_dep = b.dependency("zx", .{ .target = target, .optimize = optimize });

    // --- ZX Transpilation ---
    const transpile_cmd = b.addSystemCommand(&.{"zx"}); // ZX CLI must installed and in the PATH
    transpile_cmd.addArg("transpile");
    transpile_cmd.addArg(b.pathJoin(&.{"site"}));
    transpile_cmd.addArg("--outdir");
    const outdir = transpile_cmd.addOutputDirectoryArg("site");
    transpile_cmd.expectExitCode(0);

    // --- ZX File Cache Invalidator ---
    const site_path = b.path("site").getPath3(b, &transpile_cmd.step);
    var site_dir = site_path.root_dir.handle.openDir(site_path.subPathOrDot(), .{ .iterate = true }) catch @panic("OOM");
    var itd = site_dir.walk(transpile_cmd.step.owner.allocator) catch @panic("OOM");
    defer itd.deinit();
    while (itd.next() catch @panic("OOM")) |entry| {
        switch (entry.kind) {
            .directory => {},
            .file => {
                const entry_path = site_path.join(transpile_cmd.step.owner.allocator, entry.path) catch @panic("OOM");
                transpile_cmd.addFileInput(b.path(entry_path.sub_path));
            },
            else => continue,
        }
    }

    // --- ZX Site Main Executable ---
    const exe = b.addExecutable(options);

    exe.root_module.addImport("zx", zx_dep.module("zx"));
    var imports = std.array_list.Managed(std.Build.Module.Import).init(b.allocator);
    var import_it = exe.root_module.import_table.iterator();
    while (import_it.next()) |entry| {
        imports.append(.{ .name = entry.key_ptr.*, .module = entry.value_ptr.* }) catch @panic("OOM");
    }
    exe.root_module.addAnonymousImport("zx_meta", .{
        .root_source_file = outdir.path(b, "meta.zig"),
        .imports = imports.items,
    });

    exe.step.dependOn(&transpile_cmd.step);
    b.installArtifact(exe);

    // --- Steps: Serve ---
    const serve_step = b.step("serve", "Run the Zx website");
    const serve_cmd = b.addRunArtifact(exe);
    serve_cmd.step.dependOn(&transpile_cmd.step);
    serve_cmd.step.dependOn(b.getInstallStep());
    serve_step.dependOn(&serve_cmd.step);
    if (b.args) |args| serve_cmd.addArgs(args);
}

fn setupZxDocSite(b: *std.Build, zx_exe: *std.Build.Step.Compile, zx_mod: *std.Build.Module, options: std.Build.ExecutableOptions) void {
    var site_outdir = std.fs.cwd().openDir("site/.zx", .{}) catch null;
    if (site_outdir == null) return;
    site_outdir.?.close();

    // --- ZX Transpilation ---
    const transpile_cmd = b.addRunArtifact(zx_exe);
    transpile_cmd.addArg("transpile");
    transpile_cmd.addArg(b.pathJoin(&.{"site"}));
    transpile_cmd.addArg("--outdir");
    const outdir = b.path("site/.zx");
    transpile_cmd.addArg("site/.zx");
    transpile_cmd.expectExitCode(0);

    // --- ZX File Cache Invalidator ---
    const site_path = b.path("site").getPath3(b, &transpile_cmd.step);
    var site_dir = site_path.root_dir.handle.openDir(site_path.subPathOrDot(), .{ .iterate = true }) catch @panic("OOM");
    var itd = site_dir.walk(transpile_cmd.step.owner.allocator) catch @panic("OOM");
    defer itd.deinit();
    while (itd.next() catch @panic("OOM")) |entry| {
        switch (entry.kind) {
            .directory => {},
            .file => {
                const entry_path = site_path.join(transpile_cmd.step.owner.allocator, entry.path) catch @panic("OOM");
                transpile_cmd.addFileInput(b.path(entry_path.sub_path));
            },
            else => continue,
        }
    }

    // --- ZX Site Main Executable ---
    const exe = b.addExecutable(options);

    exe.root_module.addImport("zx", zx_mod);
    var imports = std.array_list.Managed(std.Build.Module.Import).init(b.allocator);
    var import_it = exe.root_module.import_table.iterator();
    while (import_it.next()) |entry| {
        imports.append(.{ .name = entry.key_ptr.*, .module = entry.value_ptr.* }) catch @panic("OOM");
    }
    exe.root_module.addAnonymousImport("zx_meta", .{
        .root_source_file = outdir.path(b, "meta.zig"),
        .imports = imports.items,
    });

    exe.step.dependOn(&transpile_cmd.step);

    // --- Steps: Site Build ---
    const site_step = b.step("site", "Build the site (docs, example, sample)");
    site_step.dependOn(&transpile_cmd.step);
    site_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    // --- Steps: Run Docs ---
    const run_docs_step = b.step("serve", "Run the site (docs, example, sample)");
    const run_docs_cmd = b.addRunArtifact(exe);
    run_docs_step.dependOn(&run_docs_cmd.step);
    run_docs_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_docs_cmd.addArgs(args);
}

/// Build the TransformJS Rust library as a C dynamic library
/// Returns a build step that must be completed before linking
fn buildTransformJs(
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
    const rust_target = zigTargetToRustTarget(target.result);
    if (rust_target) |triple| {
        cargo_build.addArg("--target");
        cargo_build.addArg(triple);
    }

    return &cargo_build.step;
}

/// Convert Zig target to Rust target triple
/// Returns null for native target (cargo default)
fn zigTargetToRustTarget(target: std.Target) ?[]const u8 {
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

/// Link TransformJS Rust library to an executable
fn linkTransformJs(
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
    const rust_target_triple = zigTargetToRustTarget(target.result);
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
    // Only link 'dl' on Unix-like systems (not Windows)
    if (target.result.os.tag != .windows) {
        exe.linkSystemLibrary("dl");
    }
}
