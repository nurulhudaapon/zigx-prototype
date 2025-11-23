pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "serve",
        .description = "Run the server",
    }, serve);

    try cmd.addFlag(port_flag);

    return cmd;
}

fn serve(ctx: zli.CommandContext) !void {
    const port = ctx.flag("port", u32);
    const port_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{port});
    defer ctx.allocator.free(port_str);
    var system = std.process.Child.init(&.{ "zig", "build", "serve", "--", "--port", port_str, "--cli-command", "serve" }, ctx.allocator);
    try system.spawn();
    const term = try system.wait();
    _ = term;
}

const port_flag = zli.Flag{
    .name = "port",
    .shortcut = "p",
    .description = "Port to run the server on",
    .type = .Int,
    .default_value = .{ .Int = 3000 },
    .hidden = true,
};

const std = @import("std");
const zli = @import("zli");
