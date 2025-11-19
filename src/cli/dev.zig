pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "dev",
        .description = "Start the app in development mode with rebuild on change",
    }, dev);

    return cmd;
}

fn dev(ctx: zli.CommandContext) !void {
    var builder = std.process.Child.init(&.{ "zig", "build", "--watch" }, ctx.allocator);
    try builder.spawn();

    var runner = std.process.Child.init(&.{ "zig", "build", "serve" }, ctx.allocator);
    try runner.spawn();

    var bin_dir = try std.fs.cwd().openDir("zig-out/bin", .{});
    defer bin_dir.close();
    var bin_mtime: i128 = 0;

    while (true) {
        std.Thread.sleep(std.time.ms_per_s * 2);
        const stat = try bin_dir.stat();

        if (stat.mtime != bin_mtime) {
            std.debug.print("Change detected, restarting server...\n", .{});
            bin_mtime = stat.mtime;
            _ = try runner.kill();

            try runner.spawn();
            bin_mtime = stat.mtime;
        }

        std.debug.print("Old Mtim: {any}\n New mtime {any}\n", .{ bin_mtime, stat.mtime });
    }

    defer {
        _ = runner.kill() catch unreachable;
        _ = builder.kill() catch unreachable;
    }
}

const std = @import("std");
const zli = @import("zli");
