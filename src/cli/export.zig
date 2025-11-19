pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "export",
        .description = "Export the site to a static HTML directory",
    }, @"export");

    try cmd.addFlag(outdir_flag);

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
    var system = std.process.Child.init(&.{ "zig", "build", "export", "--", "--outdir", outdir }, ctx.allocator);
    // var system = std.process.Child.init(&.{ "zig", "build", "run-site" }, ctx.allocator);
    // system.stdout_behavior = .Ignore;
    // system.stderr_behavior = .Ignore;
    try system.spawn();
    const term = try system.wait();
    _ = term;
}

const std = @import("std");
const zli = @import("zli");
