pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "serve",
        .description = "Run the server",
    }, run);

    try cmd.addFlag(port_flag);

    return cmd;
}

fn run(ctx: zli.CommandContext) !void {
    const port = ctx.flag("port", u32); // type-safe flag access

    std.debug.print("○ Running server on port \x1b[90m{d}\x1b[0m\n", .{port});

    std.debug.print("TODO", .{});
}

const port_flag = zli.Flag{
    .name = "port",
    .shortcut = "p",
    .description = "Port to run the server on",
    .type = .Int,
    .default_value = .{ .Int = 3000 },
};

const std = @import("std");
const zli = @import("zli");
