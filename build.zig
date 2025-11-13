const std = @import("std");
const zx_build_zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- ZX Core ---
    const mod = b.addModule("zx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    const httpz_dep = b.dependency("httpz", .{ .target = target, .optimize = optimize });
    mod.addImport("httpz", httpz_dep.module("httpz"));

    const options = b.addOptions();
    options.addOption([]const u8, "version_string", zx_build_zon.version);
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
    b.installArtifact(exe);

    // --- ZX LSP ---
    const lsp_dep = b.dependency("lsp_kit", .{ .target = target, .optimize = optimize });
    const zls_dep = b.dependency("zls", .{ .target = target, .optimize = optimize });
    const zxls_exe = b.addExecutable(.{
        .name = "zxls",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lsp", .module = lsp_dep.module("lsp") },
                .{ .name = "zls", .module = zls_dep.module("zls") },
            },
        }),
    });
    b.installArtifact(zxls_exe);

    // --- ZX Site (Docs, Example, sample) ---
    const site_exe = b.addExecutable(.{
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
    const site_step = b.step("site", "Build the site (docs, example, sample)");
    site_step.dependOn(&b.addInstallArtifact(site_exe, .{}).step);

    // --- Steps: Run ---
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // --- Steps: Run Docs ---
    const run_docs_step = b.step("run-site", "Run the site (docs, example, sample)");
    const run_docs_cmd = b.addRunArtifact(site_exe);
    run_docs_step.dependOn(&run_docs_cmd.step);
    run_docs_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_docs_cmd.addArgs(args);

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
}

pub fn setup(b: *std.Build, options: std.Build.ExecutableOptions) void {
    const target = options.root_module.resolved_target;
    const optimize = options.root_module.optimize;

    const zx_dep = b.dependency("zx", .{ .target = target, .optimize = optimize });

    // --- ZX Transpilation ---
    const zx_exe = zx_dep.artifact("zx");
    const transpile_cmd = b.addRunArtifact(zx_exe);
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

    // --- Steps: Transpile (Not used for now) ---
    const transpile_step = b.step("transpile", "Transpile Zx components before running");
    transpile_step.dependOn(&transpile_cmd.step);

    // --- Steps: Serve ---
    const serve_step = b.step("serve", "Run the Zx website");
    const serve_cmd = b.addRunArtifact(exe);
    serve_cmd.step.dependOn(&transpile_cmd.step);
    serve_cmd.step.dependOn(b.getInstallStep());
    serve_step.dependOn(&serve_cmd.step);
    if (b.args) |args| serve_cmd.addArgs(args);
}
