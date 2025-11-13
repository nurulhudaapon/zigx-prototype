pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    return zli.Command.init(writer, reader, allocator, .{
        .name = "version",
        .shortcut = "v",
        .description = "Show CLI version",
    }, show);
}

fn show(ctx: zli.CommandContext) !void {
    try ctx.root.printVersion();
}

const std = @import("std");
const zli = @import("zli");
