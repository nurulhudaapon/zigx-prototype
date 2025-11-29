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

    var app_child = std.process.Child.init(&.{ app_meta.binpath.?, "--cli-command", "export" }, ctx.allocator);
    app_child.stdout_behavior = .Ignore;
    app_child.stderr_behavior = .Ignore;
    try app_child.spawn();
    defer _ = app_child.kill() catch {};
    errdefer _ = app_child.kill() catch {};

    var printer = tui.Printer.init(ctx.allocator, .{ .file_path_mode = .flat, .file_tree_max_depth = 1 });
    defer printer.deinit();

    printer.header("{s} Building static ZX site!", .{tui.Printer.emoji("○")});
    printer.info("{s}", .{outdir});
    // delete the outdir if it exists
    std.fs.cwd().deleteTree(outdir) catch |err| switch (err) {
        else => {},
    };

    var aw = std.Io.Writer.Allocating.init(ctx.allocator);
    defer aw.deinit();
    try app_meta.serialize(&aw.writer);
    log.debug("Building static ZX site! {s}", .{aw.written()});

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

    util.copydirs(ctx.allocator, appoutdir, &.{ "public", "assets" }, outdir, true, &printer) catch |err| {
        std.log.err("Failed to copy public directory: {any}", .{err});
        // return err;
    };

    // Delete {outdir}/assets/_zx if it exists
    const assets_zx_path = try std.fs.path.join(ctx.allocator, &.{ outdir, "assets", "_zx" });
    defer ctx.allocator.free(assets_zx_path);
    std.fs.cwd().deleteTree(assets_zx_path) catch |err| switch (err) {
        else => {},
    };

    // printer.footer("", .{});
}

fn processRoute(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    route: zx.App.SerilizableAppMeta.Route,
    outdir: []const u8,
    printer: *tui.Printer,
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
    } else {
        // Split the URL path by "/" to get path components
        // Skip the first empty component (from leading "/")
        var path_components = std.ArrayList([]const u8).empty;
        defer path_components.deinit(allocator);

        var path_iter = std.mem.splitScalar(u8, route.path, '/');
        while (path_iter.next()) |component| {
            if (component.len > 0) {
                try path_components.append(allocator, component);
            }
        }

        if (route.path[route.path.len - 1] == '/') {
            // For paths ending in "/", create directory/index.html structure
            try path_components.append(allocator, "index.html");
            file_path_owned = try std.fs.path.join(allocator, path_components.items);
            file_path = file_path_owned.?;
        } else {
            // Get the last component (filename)
            const last_component = path_components.items[path_components.items.len - 1];
            // Add .html extension if it doesn't have one
            if (std.fs.path.extension(last_component).len == 0) {
                const last_with_ext = try std.fmt.allocPrint(allocator, "{s}.html", .{last_component});
                defer allocator.free(last_with_ext);

                // Replace the last component with the one that has .html extension
                _ = path_components.pop();
                try path_components.append(allocator, last_with_ext);
                file_path_owned = try std.fs.path.join(allocator, path_components.items);
                file_path = file_path_owned.?;
            } else {
                // Path already has an extension, join all components
                file_path_owned = try std.fs.path.join(allocator, path_components.items);
                file_path = file_path_owned.?;
            }
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

    printer.filepath(file_path);
}

const std = @import("std");
const zli = @import("zli");
const util = @import("shared/util.zig");
const flag = @import("shared/flag.zig");
const zx = @import("zx");
const tui = @import("../tui/main.zig");
const log = std.log.scoped(.cli);
