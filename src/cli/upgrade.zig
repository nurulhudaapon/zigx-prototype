pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "upgrade",
        .description = "Upgrade the version of ZX CLI",
    }, upgrade);

    try cmd.addFlag(version_flag);

    return cmd;
}

fn upgrade(ctx: zli.CommandContext) !void {
    const version = ctx.flag("version", []const u8);

    var maybe_cmd_str: ?[:0]u8 = null;
    defer if (maybe_cmd_str) |s| ctx.allocator.free(s);

    const install_cmd = switch (builtin.os.tag) {
        .windows => blk: {
            if (std.mem.eql(u8, version, "latest")) {
                break :blk [_][:0]const u8{ "powershell", "-c", "irm ziex.dev/install.ps1 | iex" };
            } else {
                const prefix = if (std.mem.startsWith(u8, version, "v")) "" else "v";
                maybe_cmd_str = try std.fmt.allocPrintSentinel(ctx.allocator, "& ([scriptblock]::Create((irm ziex.dev/install.ps1))) -Version '{s}{s}'", .{ prefix, version }, 0);
                break :blk [_][:0]const u8{ "powershell", "-c", maybe_cmd_str.? };
            }
        },
        .linux, .macos => blk: {
            if (std.mem.eql(u8, version, "latest")) {
                break :blk [_][:0]const u8{ "bash", "-c", "curl -fsSL https://ziex.dev/install | bash" };
            } else {
                const prefix = if (std.mem.startsWith(u8, version, "v")) "" else "v";
                maybe_cmd_str = try std.fmt.allocPrintSentinel(ctx.allocator, "curl -fsSL https://ziex.dev/install | bash -s -- {s}{s}", .{ prefix, version }, 0);
                break :blk [_][:0]const u8{ "bash", "-c", maybe_cmd_str.? };
            }
        },
        else => return error.UnsupportedOS,
    };

    var system = std.process.Child.init(&install_cmd, ctx.allocator);
    try system.spawn();

    const term = try system.wait();
    _ = term;

    try ctx.writer.print("Upgraded to: ", .{});
    var zx_version = std.process.Child.init(&.{ "zx", "version" }, ctx.allocator);
    try zx_version.spawn();
    _ = try zx_version.wait();
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
const builtin = @import("builtin");
