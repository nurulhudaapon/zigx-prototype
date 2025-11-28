const std = @import("std");

pub const docsite = @import("doc.zig");
pub const rustlib = @import("rust.zig");

pub fn setup(b: *std.Build, options: std.Build.ExecutableOptions) void {
    const target = options.root_module.resolved_target;
    const optimize = options.root_module.optimize;

    const zx_dep = b.dependency("zx", .{ .target = target, .optimize = optimize });

    // --- ZX Transpilation ---
    const transpile_cmd = b.addRunArtifact(zx_dep.artifact("zx"));
    // const transpile_cmd = b.addSystemCommand(&.{"zx"}); // ZX CLI must installed and in the PATH
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
