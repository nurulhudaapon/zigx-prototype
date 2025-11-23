const Metadata = @import("meta.zig");
const std = @import("std");
const zx = @import("zx");

const config = zx.App.Config{ .meta = Metadata.meta, .server = .{} };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const app = try zx.App.init(allocator, config);
    defer app.deinit();

    std.debug.print("{s}\n  - Local: http://localhost:{d}\n", .{ zx.App.info, app.server.config.port.? });
    try app.start();
}
