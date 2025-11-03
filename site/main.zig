const Metadata = @import("meta.zig");
const std = @import("std");
const zx = @import("zx");
const PORT = 5882;
const VERSION = "0.0.1";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var app = try zx.App.init(allocator, .{
        .server = .{ .port = PORT },
        .meta = &Metadata.meta,
    });

    defer {
        app.server.stop();
        app.server.deinit();
    }

    std.debug.print("ZigX {s}\n  - Local: http://localhost:{d}\n", .{ VERSION, PORT });
    try app.server.listen();
}
