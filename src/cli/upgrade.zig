pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "upgrade",
        .description = "Upgrade the version of ZX CLI",
    }, upgrade);

    // try cmd.addFlag(version_flag);

    return cmd;
}

fn upgrade(ctx: zli.CommandContext) !void {
    // const version = ctx.flag("version", []const u8);
    // const version_str = if (std.mem.eql(u8, version, "latest")) "" else try std.fmt.allocPrint(ctx.allocator, "#v{s}", .{version});
    // defer ctx.allocator.free(version_str);

    // const fetch_uri = try std.fmt.allocPrint(ctx.allocator, "git+{s}{s}", .{ zx.info.repository, version_str });
    // defer ctx.allocator.free(fetch_uri);

    const install_cmd = switch (builtin.os.tag) {
        .windows => &.{ "powershell", "-c", "irm ziex.dev/install.ps1 | iex" },
        .linux, .macos => [_][:0]const u8{ "bash", "-c", "curl -fsSL https://ziex.dev/install | bash" },
        else => return error.UnsupportedOS,
    };

    var system = std.process.Child.init(&install_cmd, ctx.allocator);
    try system.spawn();

    const term = try system.wait();
    _ = term;

    try ctx.writer.print("Version: ", .{});
    var zx_version = std.process.Child.init(&.{ "zx", "version" }, ctx.allocator);
    try zx_version.spawn();
    _ = try zx_version.wait();
}

// const version_flag = zli.Flag{
//     .name = "version",
//     .shortcut = "v",
//     .description = "Version to update to",
//     .type = .String,
//     .default_value = .{ .String = "latest" },
// };

const std = @import("std");
const zli = @import("zli");
const zx = @import("zx");
const builtin = @import("builtin");
