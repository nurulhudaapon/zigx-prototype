const Metadata = @import("meta.zig");
const std = @import("std");
const zx = @import("zx");

const config = zx.App.Config{
    .server = .{
        .port = 5588,
        .address = "0.0.0.0",
        .request = .{
            .max_form_count = 100,
        },
    },
    .meta = &Metadata.meta,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const app = try zx.App.init(allocator, config);
    defer app.deinit();
    errdefer app.deinit();

    try app.build(.{ .type = .static });
}

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .websocket, .level = .err },
    },
};
