pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "export",
        .description = "Export the site to a static HTML directory",
    }, @"export");

    try cmd.addFlag(outdir_flag);
    try cmd.addFlag(flag.binpath_flag);

    return cmd;
}

const outdir_flag = zli.Flag{
    .name = "outdir",
    .shortcut = "o",
    .description = "Output directory",
    .type = .String,
    .default_value = .{ .String = "dist" },
};

fn @"export"(ctx: zli.CommandContext) !void {
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

    const port = app_meta.config.server.port orelse 3000;
    const appoutdir = app_meta.rootdir orelse "site/.zx";
    const host = app_meta.config.server.address orelse "0.0.0.0";

    var app_child = std.process.Child.init(&.{app_meta.binpath.?}, ctx.allocator);
    app_child.stdout_behavior = .Ignore;
    app_child.stderr_behavior = .Ignore;
    try app_child.spawn();
    defer _ = app_child.kill() catch {};
    errdefer _ = app_child.kill() catch {};

    std.debug.print("\x1b[1m○ Building static ZX site!\x1b[0m\n\n", .{});
    std.debug.print("  - \x1b[90m{s}\x1b[0m\n", .{outdir});

    var aw = std.Io.Writer.Allocating.init(ctx.allocator);
    defer aw.deinit();
    try app_meta.serialize(&aw.writer);
    log.debug("Building static ZX site! {s}", .{aw.written()});

    var printer = zx.Printer.init(ctx.allocator, .{ .file_path_mode = .flat, .file_tree_max_depth = 1 });
    defer printer.deinit();

    log.debug("Port: {d}, Outdir: {s}", .{ port, appoutdir });

    log.debug("Processing routes! {d}", .{app_meta.routes.len});

    process_block: while (true) {
        for (app_meta.routes) |route| {
            log.debug("Processing route! {s}", .{route.path});
            processRoute(ctx.allocator, host, port, route, outdir, &printer) catch |err| {
                if (err == error.ConnectionRefused) {
                    continue :process_block;
                }
            };
        }
        break;
    }

    log.debug("Copying public directory! {s}", .{appoutdir});
    copydirs(ctx.allocator, appoutdir, &.{ "public", "assets" }, outdir, &printer) catch |err| {
        std.log.err("Failed to copy public directory: {any}", .{err});
        // return err;
    };

    // std.debug.print("\nNow run → \n\n\x1b[36mzig build serve\x1b[0m\n\n", .{});
    std.debug.print("\n", .{});
}

fn copydirs(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    source_dirs: []const []const u8,
    dest_dir: []const u8,
    printer: *zx.Printer,
) !void {
    for (source_dirs) |source_dir| {
        const source_path = try std.fs.path.join(allocator, &.{ base_dir, source_dir });
        defer allocator.free(source_path);

        var source = std.fs.cwd().openDir(source_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.NotDir => continue,
            else => return err,
        };
        defer source.close();

        // Create destination directory if it doesn't exist
        std.fs.cwd().makePath(dest_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var dest = try std.fs.cwd().openDir(dest_dir, .{});
        defer dest.close();

        var walker = try source.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            const src_path = try std.fs.path.join(allocator, &.{ source_path, entry.path });
            defer allocator.free(src_path);

            const dst_rel_path = try std.fs.path.join(allocator, &.{
                if (std.mem.eql(u8, source_dir, "public")) "" else source_dir,
                entry.path,
            });
            defer allocator.free(dst_rel_path);

            const dst_abs_path = try std.fs.path.join(allocator, &.{ dest_dir, dst_rel_path });
            defer allocator.free(dst_abs_path);

            switch (entry.kind) {
                .file => {
                    // Create parent directory if needed
                    if (std.fs.path.dirname(dst_abs_path)) |parent| {
                        std.fs.cwd().makePath(parent) catch |err| switch (err) {
                            error.PathAlreadyExists => {},
                            else => return err,
                        };
                    }

                    // Copy file
                    try std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_abs_path, .{});
                    printer.printFilePath(dst_rel_path);
                },
                .directory => {
                    // Create directory if needed
                    std.fs.cwd().makePath(dst_abs_path) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                },
                else => continue,
            }
        }
    }
}

fn processRoute(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    route: zx.App.SerilizableAppMeta.Route,
    outdir: []const u8,
    printer: *zx.Printer,
) !void {
    // Fetch the route's HTML content
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}{s}", .{ host, port, route.path });
    defer allocator.free(url);

    _ = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .headers = std.http.Client.Request.Headers{},
        .response_writer = &aw.writer,
    });

    const response_text = aw.written();

    // Determine the output file path
    // For root path "/", use "index.html", otherwise use the route path
    var file_path: []const u8 = undefined;
    var file_path_owned: ?[]u8 = null;
    defer if (file_path_owned) |fp| allocator.free(fp);

    if (std.mem.eql(u8, route.path, "/")) {
        file_path = "index.html";
    } else if (route.path[route.path.len - 1] == '/') {
        // For paths ending in "/", create directory/index.html structure
        const dir_path = route.path[1 .. route.path.len - 1]; // Remove leading "/" and trailing "/"
        file_path_owned = try std.fmt.allocPrint(allocator, "{s}/index.html", .{dir_path});
        file_path = file_path_owned.?;
    } else {
        const path_without_slash = route.path[1..]; // Remove leading "/"
        // Add .html extension if it doesn't have one
        if (std.fs.path.extension(path_without_slash).len == 0) {
            file_path_owned = try std.fmt.allocPrint(allocator, "{s}.html", .{path_without_slash});
            file_path = file_path_owned.?;
        } else {
            file_path = path_without_slash;
        }
    }

    const output_path = try std.fs.path.join(allocator, &.{ outdir, file_path });
    defer allocator.free(output_path);

    // Create parent directories if they don't exist
    const output_dir = std.fs.path.dirname(output_path);
    if (output_dir) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    try std.fs.cwd().writeFile(.{
        .sub_path = output_path,
        .data = response_text,
    });

    printer.printFilePath(file_path);
}

const std = @import("std");
const zli = @import("zli");
const util = @import("shared/util.zig");
const flag = @import("shared/flag.zig");
const zx = @import("zx");
const log = std.log.scoped(.cli);
