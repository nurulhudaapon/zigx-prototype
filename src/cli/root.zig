pub fn build(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const root = try zli.Command.init(writer, reader, allocator, .{
        .name = "zx",
        .description = "ZX is a framework for building web applications with Zig.",
        // .version = .{ .major = 0, .minor = 0, .patch = 1, .pre = null, .build = null },
    }, showHelp);

    try root.addCommands(&.{
        try version.register(writer, reader, allocator),
        try init.register(writer, reader, allocator),
        try serve.register(writer, reader, allocator),
        try transpile.register(writer, reader, allocator),
    });

    return root;
}

fn showHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}

const serve = @import("serve.zig");
const init = @import("init.zig");
const version = @import("version.zig");
const transpile = @import("transpile.zig");

const std = @import("std");
const zli = @import("zli");
