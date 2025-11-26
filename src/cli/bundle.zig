pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "bundle",
        .description = "Bundle the site into deployable directory",
    }, bundle);

    try cmd.addFlag(outdir_flag);
    try cmd.addFlag(flag.binpath_flag);
    try cmd.addFlag(flag.build_args);
    try cmd.addFlag(docker_flag);
    try cmd.addFlag(docker_compose_flag);

    return cmd;
}

const outdir_flag = zli.Flag{
    .name = "outdir",
    .shortcut = "o",
    .description = "Output directory",
    .type = .String,
    .default_value = .{ .String = "bundle" },
};

const docker_flag = zli.Flag{
    .name = "docker",
    .shortcut = "d",
    .description = "Include Dockerfile in the bundle",
    .type = .Bool,
    .hidden = true,
    .default_value = .{ .Bool = false },
};

const docker_compose_flag = zli.Flag{
    .name = "docker-compose",
    .shortcut = "dc",
    .description = "Include docker-compose.yml and Dockerfile in the bundle",
    .type = .Bool,
    .hidden = true,
    .default_value = .{ .Bool = false },
};

fn bundle(ctx: zli.CommandContext) !void {
    const outdir = ctx.flag("outdir", []const u8);
    const binpath = ctx.flag("binpath", []const u8);
    const docker = ctx.flag("docker", bool);
    const docker_compose = ctx.flag("docker-compose", bool);
    const build_args = ctx.flag("build-args", []const u8);

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
    const port = app_meta.config.server.port orelse 3000;
    const port_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{port});
    defer ctx.allocator.free(port_str);
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

    if (!(docker or docker_compose)) {
        try std.fs.cwd().copyFile(final_binpath, std.fs.cwd(), dest_binpath, .{});
        printer.printFilePath(bin_name);
    }

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

    const compose_content = @embedFile("bundle/template/compose.yml");
    const dockerfile_content = @embedFile("bundle/template/Dockerfile");

    if (docker or docker_compose) {

        // Replace $BIN_NAME
        const dockerfile_content_with_bin_name = try std.mem.replaceOwned(u8, ctx.allocator, dockerfile_content, "$BIN_NAME", bin_name);
        const compose_content_with_bin_name = try std.mem.replaceOwned(u8, ctx.allocator, compose_content, "$BIN_NAME", bin_name);
        defer ctx.allocator.free(dockerfile_content_with_bin_name);
        defer ctx.allocator.free(compose_content_with_bin_name);

        // Replace $BUILD_ARGS in template/Dockerfile and template/compose.yml with build_args
        const dockerfile_content_with_build_args = try std.mem.replaceOwned(u8, ctx.allocator, dockerfile_content_with_bin_name, "$BUILD_ARGS", build_args);
        const compose_content_with_build_args = try std.mem.replaceOwned(u8, ctx.allocator, compose_content_with_bin_name, "$BUILD_ARGS", build_args);
        defer ctx.allocator.free(dockerfile_content_with_build_args);
        defer ctx.allocator.free(compose_content_with_build_args);

        // Replace $PORT in template/compose.yml with port
        const compose_content_with_port = try std.mem.replaceOwned(u8, ctx.allocator, compose_content_with_build_args, "$PORT", port_str);
        defer ctx.allocator.free(compose_content_with_port);

        const dockerfile_path = try std.fs.path.join(ctx.allocator, &.{ outdir, "Dockerfile" });
        const compose_path = try std.fs.path.join(ctx.allocator, &.{ outdir, "compose.yml" });
        defer ctx.allocator.free(dockerfile_path);
        defer ctx.allocator.free(compose_path);

        try std.fs.cwd().writeFile(.{ .sub_path = dockerfile_path, .data = dockerfile_content_with_build_args });
        printer.printFilePath(dockerfile_path);
        if (docker_compose) {
            try std.fs.cwd().writeFile(.{ .sub_path = compose_path, .data = compose_content_with_port });
            printer.printFilePath(compose_path);
        }
    }

    if (docker or docker_compose) {
        if (docker_compose) {
            std.debug.print("\nNow run → \n\n\x1b[36m(cd {s} && docker compose up --build)\x1b[0m\n\n", .{outdir});
        } else {
            std.debug.print("\nNow run → \n\n\x1b[36mdocker build -t {s} . -f {s}/Dockerfile \ndocker run -p {s}:{s} {s}\x1b[0m\n\n", .{ bin_name, outdir, port_str, port_str, bin_name });
        }
    } else {
        std.debug.print("\nNow run → \n\n\x1b[36m(cd {s} && ./{s} --rootdir ./)\x1b[0m\n\n", .{ outdir, bin_name });
    }

    std.debug.print("\n", .{});
}

const std = @import("std");
const zli = @import("zli");
const util = @import("shared/util.zig");
const flag = @import("shared/flag.zig");
const zx = @import("zx");
const log = std.log.scoped(.cli);
