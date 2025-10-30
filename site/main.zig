const Metadata = @import("meta.zig");
const std = @import("std");
const zx = @import("zx");
const httpz = @import("httpz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var handler = Handler{};
    var server = try httpz.Server(*Handler).init(allocator, .{ .port = 5882 }, &handler);
    defer {
        server.stop();
        server.deinit();
    }
    std.debug.print("Server is running on port 5882\n", .{});
    try server.listen();
}

const Handler = struct {
    pub fn handle(_: *Handler, req: *httpz.Request, res: *httpz.Response) void {
        const app = zx.App.init(.{ .routes = &Metadata.routes });
        const error_body = app.handle(req.arena, &res.buffer.writer, req.url.path) catch {
            res.body = "Internal Server Error";
            return;
        };

        if (error_body) |body| {
            res.body = body;
        }
    }
};
