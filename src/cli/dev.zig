pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "dev",
        .description = "Start the app in development mode with rebuild on change",
    }, dev);

    try cmd.addFlag(flag.binpath_flag);

    return cmd;
}

const RESTART_INTERVAL = std.time.ns_per_s * 2;
const BIN_DIR = "zig-out/bin";

fn dev(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const binpath = ctx.flag("binpath", []const u8);

    var builder = std.process.Child.init(&.{ "zig", "build", "--watch" }, allocator);
    try builder.spawn();
    defer _ = builder.kill() catch unreachable;

    const program_meta = util.findprogram(allocator, binpath) catch {
        try ctx.writer.print("Error finding ZX executable!\n", .{});
        return;
    };

    const program_path = program_meta.binpath orelse {
        try ctx.writer.print("Error finding ZX executable!\n", .{});
        return;
    };

    var runner = std.process.Child.init(&.{program_path}, allocator);
    try runner.spawn();
    defer _ = runner.kill() catch unreachable;

    var bin_mtime: i128 = 0;
    while (true) {
        std.Thread.sleep(RESTART_INTERVAL);
        const stat = try std.fs.cwd().statFile(program_path);

        const should_restart = stat.mtime != bin_mtime and bin_mtime != 0;
        if (should_restart) {
            std.debug.print("\x1b[32mChange detected, restarting server...\x1b[0m\n", .{});

            _ = try runner.kill();
            try runner.spawn();
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
