const Metadata = @import("meta.zig");
const std = @import("std");
const zx = @import("zx");

const config = zx.App.Config{ .meta = Metadata.meta, .server = .{ .port = 5588 } };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const app = try zx.App.init(allocator, config);
    defer app.deinit();

    std.debug.print("{s} | http://localhost:{d}\n\n", .{ zx.App.info, app.server.config.port.? });
    try app.start();
}
