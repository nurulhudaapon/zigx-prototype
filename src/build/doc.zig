const std = @import("std");

pub fn setup(b: *std.Build, zx_exe: *std.Build.Step.Compile, zx_mod: *std.Build.Module, options: std.Build.ExecutableOptions) void {
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
    b.installArtifact(exe);

    // --- Steps: Run Docs ---
    const run_docs_step = b.step("serve", "Run the site (docs, example, sample)");
    const run_docs_cmd = b.addRunArtifact(exe);
    run_docs_step.dependOn(&run_docs_cmd.step);
    run_docs_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_docs_cmd.addArgs(args);
}
