const Metadata = @import("meta.zig");
const std = @import("std");
const zx = @import("zx");

const config = zx.App.Config{
    .server = .{
        .port = 49152, // uncommon but valid port (highest dynamic/private port)
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

fn inspect() void {
    var args = std.process.args();
    defer args.deinit();

    // --- Flags --- //
    // --introspect: Print the metadata to stdout and exit
    var is_introspect = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--introspect")) is_introspect = true;
    }

    var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
    var stdout = &stdout_writer.interface;

    if (is_introspect) {
        try stdout.print("{any}\n", .{Metadata.meta});
        std.process.exit(0);
    }

    try stdout.flush();
}
