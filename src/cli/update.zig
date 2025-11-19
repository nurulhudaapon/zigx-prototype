pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "update",
        .description = "Update the version of ZX dependency",
    }, update);

    try cmd.addFlag(version_flag);

    return cmd;
}

fn update(ctx: zli.CommandContext) !void {
    const version = ctx.flag("version", []const u8);
    const version_str = if (std.mem.eql(u8, version, "latest")) "" else try std.fmt.allocPrint(ctx.allocator, "#v{s}", .{version});
    defer ctx.allocator.free(version_str);

    const fetch_uri = try std.fmt.allocPrint(ctx.allocator, "git+{s}{s}", .{ zx.info.repository, version_str });
    defer ctx.allocator.free(fetch_uri);

    var system = std.process.Child.init(&.{ "zig", "fetch", "--save", fetch_uri }, ctx.allocator);
    try system.spawn();

    const term = try system.wait();
    _ = term;
}

const version_flag = zli.Flag{
    .name = "version",
    .shortcut = "v",
    .description = "Version to update to",
    .type = .String,
    .default_value = .{ .String = "latest" },
};

const std = @import("std");
const zli = @import("zli");
const zx = @import("zx");
