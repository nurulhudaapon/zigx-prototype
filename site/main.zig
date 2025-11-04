const Metadata = @import("meta.zig");
const std = @import("std");
const zx = @import("zx");

const config = zx.App.Config{
    .server = .{ .port = 5882, .address = "0.0.0.0" },
    .meta = &Metadata.meta,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const app = try zx.App.init(allocator, config);
    defer app.deinit();

    std.debug.print("{s}\n  - Local: http://localhost:{d}\n", .{ zx.App.info, config.server.port.? });
    try app.start();
}
