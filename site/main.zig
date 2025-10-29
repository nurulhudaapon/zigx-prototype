pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var handler = Handler{ .allocator = allocator };
    try handler.users.ensureTotalCapacity(allocator, 1000000);
    var server = try httpz.Server(*Handler).init(allocator, .{ .port = 5882 }, &handler);
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/users", users, .{});
    router.get("/", index, .{});
    router.get("/about", about, .{});

    std.debug.print("Server is running on port 5882\n", .{});
    try server.listen();
}

const std = @import("std");
const zx = @import("zx");
const Layout = @import("layout.zig").Layout;
const Page = @import("page.zig").Page;
const AboutPage = @import("about/page.zig").Page;
const httpz = @import("httpz");

const Handler = struct {
    _hits: usize = 0,

    allocator: std.mem.Allocator,

    users: std.ArrayList(User) = undefined,

    pub const User = struct {
        name: []const u8,
        age: u32,
    };

    pub fn addUser(self: *Handler, name: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.users.append(self.allocator, .{ .name = name_copy, .age = 20 });
    }

    pub fn getUsers(self: *Handler) []const User {
        return self.users.items;
    }

    pub fn notFound(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
        res.status = 404;
        res.body = "NOPE!";
    }

    pub fn uncaughtError(_: *Handler, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        std.debug.print("uncaught http error at {s}: {}\n", .{ req.url.path, err });
        res.headers.add("content-type", "text/html; charset=utf-8");
        res.status = 505;
        res.body = "<!DOCTYPE html>(╯°□°)╯︵ ┻━┻";
    }
};

fn users(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    res.status = 200;
    try res.json(handler.users.items, .{});
}

fn index(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    const qs = try req.query();
    if (qs.get("name")) |n| try handler.addUser(n);

    var aw: std.Io.Writer.Allocating = .init(req.arena);
    for (handler.users.items) |user| aw.writer.print("{s}, ", .{user.name}) catch unreachable;
    const user_str = aw.written();

    const pageComponent = Page(req.arena, user_str);
    try Layout(req.arena, pageComponent).render(&res.buffer.writer);
}

fn about(_: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    try Layout(req.arena, AboutPage(req.arena)).render(&res.buffer.writer);
}
