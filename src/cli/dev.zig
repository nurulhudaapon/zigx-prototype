pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "dev",
        .description = "Start the app in development mode with rebuild on change",
    }, dev);

    try cmd.addFlag(flag.binpath_flag);
    try cmd.addFlag(flag.build_args);

    return cmd;
}

const RESTART_INTERVAL_NS = std.time.ns_per_ms * 100; // 100ms
const BIN_DIR = "zig-out/bin";

fn dev(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const binpath = ctx.flag("binpath", []const u8);
    const build_args_str = ctx.flag("build-args", []const u8);
    var build_args = std.mem.splitSequence(u8, build_args_str, " ");

    var build_args_array = std.ArrayList([]const u8).empty;
    try build_args_array.append(allocator, "zig");
    try build_args_array.append(allocator, "build");
    while (build_args.next()) |arg| {
        const trimmed_arg = std.mem.trim(u8, arg, " ");
        if (std.mem.eql(u8, trimmed_arg, "")) continue;
        try build_args_array.append(allocator, trimmed_arg);
    }

    jsutil.buildjs(ctx, binpath, false) catch |err| {
        log.debug("Error building TS! {any}", .{err});
    };

    log.debug("First time building, we will run `{s}`", .{try std.mem.join(allocator, " ", build_args_array.items)});
    var build_builder = std.process.Child.init(build_args_array.items, allocator);
    try build_builder.spawn();
    _ = try build_builder.wait();

    log.debug("Building complete, finding ZX executable", .{});

    try build_args_array.append(allocator, "--watch");
    var builder = std.process.Child.init(build_args_array.items, allocator);
    try builder.spawn();
    defer _ = builder.kill() catch unreachable;
    log.debug("Building with watch mode `{s}`", .{try std.mem.join(allocator, " ", build_args_array.items)});

    var program_meta = util.findprogram(allocator, binpath) catch |err| {
        try ctx.writer.print("Error finding ZX executable! {any}\n", .{err});
        return err;
    };
    defer program_meta.deinit(allocator);

    const program_path = program_meta.binpath orelse {
        try ctx.writer.print("Error finding ZX executable!\n", .{});
        return;
    };

    jsutil.buildjs(ctx, binpath, true) catch |err| {
        log.debug("Error building TS! {any}", .{err});
    };

    var runner = std.process.Child.init(&.{ program_path, "--cli-command", "dev" }, allocator);
    try runner.spawn();
    defer _ = runner.kill() catch unreachable;

    var bin_mtime: i128 = 0;
    while (true) {
        std.Thread.sleep(RESTART_INTERVAL_NS);
        const stat = try std.fs.cwd().statFile(program_path);

        const should_restart = stat.mtime != bin_mtime and bin_mtime != 0;
        if (should_restart) {
            std.debug.print("Change detected, restarting server...\n", .{});

            _ = try runner.kill();
            try runner.spawn();

            std.debug.print("\n", .{});

            jsutil.buildjs(ctx, binpath, true) catch |err| {
                log.debug("Error watching TS! {any}", .{err});
            };
        }
        if (should_restart or bin_mtime == 0) bin_mtime = stat.mtime;
    }

    errdefer {
        // _ = builder.kill() catch unreachable;
        _ = if (runner.id != 0) runner.kill() catch unreachable;
    }
}

const std = @import("std");
const zli = @import("zli");
const util = @import("shared/util.zig");
const flag = @import("shared/flag.zig");
const log = std.log.scoped(.cli);
const zx = @import("zx");
const jsutil = @import("shared/js.zig");
