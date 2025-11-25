const meta = @import("zx_meta").meta;
const std = @import("std");
const zx = @import("zx");

const config = zx.App.Config{ .server = .{}, .meta = meta };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const app = try zx.App.init(allocator, config);
    defer app.deinit();

    std.debug.print("{s} | http://localhost:{d}\n", .{ zx.App.info, app.server.config.port.? });
    try app.start();
}
