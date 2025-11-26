pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "bundle",
        .description = "Bundle the site into deployable directory",
    }, bundle);

    try cmd.addFlag(outdir_flag);
    try cmd.addFlag(flag.binpath_flag);

    return cmd;
}

const outdir_flag = zli.Flag{
    .name = "outdir",
    .shortcut = "o",
    .description = "Output directory",
    .type = .String,
    .default_value = .{ .String = "bundle" },
};

fn bundle(ctx: zli.CommandContext) !void {
    const outdir = ctx.flag("outdir", []const u8);
    const binpath = ctx.flag("binpath", []const u8);

    var app_meta = util.findprogram(ctx.allocator, binpath) catch |err| {
        if (err == error.FileNotFound) {
            try ctx.writer.print("Run \x1b[34mzig build\x1b[0m to build the ZX executable first!\n", .{});
            return;
        }
        try ctx.writer.print("Error finding ZX executable! {any}\n", .{err});
        return;
    };
    defer std.zon.parse.free(ctx.allocator, app_meta);

    const appoutdir = app_meta.rootdir orelse "site/.zx";
    const final_binpath = app_meta.binpath orelse binpath;

    std.debug.print("\x1b[1m○ Bundling ZX site!\x1b[0m\n\n", .{});
    std.debug.print("  - \x1b[90m{s}\x1b[0m\n", .{outdir});

    var aw = std.Io.Writer.Allocating.init(ctx.allocator);
    defer aw.deinit();
    try app_meta.serialize(&aw.writer);
    log.debug("Bundling ZX site! {s}", .{aw.written()});

    var printer = zx.Printer.init(ctx.allocator, .{ .file_path_mode = .flat, .file_tree_max_depth = 1 });
    defer printer.deinit();

    log.debug("Outdir: {s}", .{outdir});

    const bin_name = std.fs.path.basename(final_binpath);
    const dest_binpath = try std.fs.path.join(ctx.allocator, &.{ outdir, bin_name });
    defer ctx.allocator.free(dest_binpath);
    log.debug("Copying bin from {s} to outdir {s}", .{ final_binpath, dest_binpath });

    // Delete the outdir if it exists
    std.fs.cwd().deleteTree(outdir) catch |err| switch (err) {
        else => {},
    };
    std.fs.cwd().makePath(outdir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try std.fs.cwd().copyFile(final_binpath, std.fs.cwd(), dest_binpath, .{});

    printer.printFilePath(bin_name);

    log.debug("Copying public directory! {s}", .{appoutdir});
    util.copydirs(ctx.allocator, appoutdir, &.{ "public", "assets" }, outdir, false, &printer) catch |err| {
        std.log.err("Failed to copy public directory: {any}", .{err});
        // return err;
    };

    // Delete {outdir}/assets/_zx if it exists
    const assets_zx_path = try std.fs.path.join(ctx.allocator, &.{ outdir, "assets", "_zx" });
    defer ctx.allocator.free(assets_zx_path);
    std.fs.cwd().deleteTree(assets_zx_path) catch |err| switch (err) {
        else => {},
    };

    std.debug.print("\nNow run → \n\n\x1b[36m(cd {s} && ./{s} --rootdir ./)\x1b[0m\n\n", .{ outdir, bin_name });
    std.debug.print("\n", .{});
}

const std = @import("std");
const zli = @import("zli");
const util = @import("shared/util.zig");
const flag = @import("shared/flag.zig");
const zx = @import("zx");
const log = std.log.scoped(.cli);
