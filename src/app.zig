const httpz = @import("httpz");
const module_config = @import("zx_info");

pub const App = struct {
    pub const ExportType = enum { static };
    pub const ExportOptions = struct {
        type: ExportType,
        outdir: ?[]const u8 = "dist",
    };

    pub const Meta = struct {
        pub const Route = struct {
            path: []const u8,
            page: *const fn (ctx: zx.PageContext) Component,
            layout: ?*const fn (ctx: zx.LayoutContext, component: Component) Component = null,
            routes: ?[]const Route = null,
        };
        routes: []const Route,
    };
    pub const Config = struct {
        server: httpz.Config,
        meta: *const Meta,
    };

    const Handler = struct {
        meta: *const App.Meta,
        allocator: std.mem.Allocator,

        pub fn handle(self: *Handler, req: *httpz.Request, res: *httpz.Response) void {
            const allocator = self.allocator;
            const path = req.url.path;

            const request_path = normalizePath(req.arena, path) catch {
                res.body = "Internal Server Error";
                res.status = 500;
                return;
            };

            const pagectx = zx.PageContext.init(req, res, allocator);
            const layoutctx = zx.LayoutContext.init(req, res, allocator);

            const empty_layouts: []const *const fn (ctx: zx.LayoutContext, component: Component) Component = &.{};

            for (self.meta.routes) |route| {
                const rendered = matchRoute(request_path, route, empty_layouts, pagectx, layoutctx, null) catch {
                    res.body = "Internal Server Error";
                    res.status = 500;
                    return;
                };
                if (rendered) {
                    res.content_type = .HTML;
                    return;
                }
            }

            const public_path = std.fs.path.join(allocator, &.{ "site", "public", request_path }) catch return;
            defer allocator.free(public_path);

            const file_content = std.fs.cwd().readFileAlloc(allocator, public_path, std.math.maxInt(usize)) catch {
                res.status = 404;
                return;
            };
            res.content_type = httpz.ContentType.forFile(request_path);
            // res.header("Cache-Control", "max-age=31536000, public");
            res.body = file_content;
            return;
        }
    };

    pub const version = module_config.version_string;
    pub const info = std.fmt.comptimePrint("\x1b[1mZX\x1b[0m \x1b[2m· {s}\x1b[0m", .{version});

    allocator: std.mem.Allocator,
    meta: *const Meta,
    handler: Handler,
    server: httpz.Server(*Handler),

    _is_listening: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: Config) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        app.allocator = allocator;
        app.meta = config.meta;
        app.handler = Handler{ .meta = config.meta, .allocator = allocator };
        app.server = try httpz.Server(*Handler).init(allocator, config.server, &app.handler);

        return app;
    }

    pub fn deinit(self: *App) void {
        const allocator = self.allocator;

        if (self._is_listening) self.server.stop();
        self.server.deinit();
        allocator.destroy(self);
    }

    pub fn start(self: *App) !void {
        if (self._is_listening) return;
        self._is_listening = true;
        self.server.listen() catch |err| {
            self._is_listening = false;
            return err;
        };
    }

    pub fn build(self: *App, options: ExportOptions) !void {
        const outdir = options.outdir.?;
        const port = self.server.config.port.?;
        std.debug.print("\x1b[1m○ Building static ZX site!\x1b[0m\n\n", .{});
        std.debug.print("  - \x1b[90m{s}\x1b[0m\n", .{outdir});

        var printer = Printer.init(self.allocator, .{ .file_path_mode = .tree, .file_tree_max_depth = 1 });
        defer printer.deinit();

        const thrd = try self.server.listenInNewThread();

        for (self.meta.routes) |route| {
            try processRoute(self.allocator, port, route, options, &printer);
        }

        copyDirectory(self.allocator, "site/public", outdir, &printer) catch |err| {
            std.log.err("Failed to copy public directory: {any}", .{err});
            return err;
        };

        self.server.stop();
        self._is_listening = false;
        thrd.join();
    }

    fn copyDirectory(
        allocator: std.mem.Allocator,
        source_dir: []const u8,
        dest_dir: []const u8,
        printer: *Printer,
    ) !void {
        var source = try std.fs.cwd().openDir(source_dir, .{ .iterate = true });
        defer source.close();

        // Create destination directory if it doesn't exist
        std.fs.cwd().makePath(dest_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var dest = try std.fs.cwd().openDir(dest_dir, .{});
        defer dest.close();

        var walker = try source.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            const src_path = try std.fs.path.join(allocator, &.{ source_dir, entry.path });
            defer allocator.free(src_path);

            const dst_path = try std.fs.path.join(allocator, &.{ dest_dir, entry.path });
            defer allocator.free(dst_path);

            switch (entry.kind) {
                .file => {
                    // Create parent directory if needed
                    if (std.fs.path.dirname(dst_path)) |parent| {
                        std.fs.cwd().makePath(parent) catch |err| switch (err) {
                            error.PathAlreadyExists => {},
                            else => return err,
                        };
                    }

                    // Copy file
                    try std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{});
                    printer.printFilePath(entry.path);
                },
                .directory => {
                    // Create directory if needed
                    std.fs.cwd().makePath(dst_path) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                },
                else => continue,
            }
        }
    }

    fn processRoute(allocator: std.mem.Allocator, port: u16, route: zx.App.Meta.Route, options: ExportOptions, printer: *Printer) !void {
        const outdir = options.outdir.?;
        // Fetch the route's HTML content
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();

        const url = try std.fmt.allocPrint(allocator, "http://0.0.0.0:{d}{s}", .{ port, route.path });
        defer allocator.free(url);

        _ = client.fetch(.{
            .method = .GET,
            .location = .{ .url = url },
            .headers = std.http.Client.Request.Headers{},
            .response_writer = &aw.writer,
        }) catch |err| {
            std.log.err("Failed to fetch route {s}: {any}", .{ route.path, err });
            return error.FailedToFetchRoute;
        };

        const response_text = aw.written();

        // Determine the output file path
        // For root path "/", use "index.html", otherwise use the route path
        var file_path: []const u8 = undefined;
        var file_path_owned: ?[]u8 = null;
        defer if (file_path_owned) |fp| allocator.free(fp);

        if (std.mem.eql(u8, route.path, "/")) {
            file_path = "index.html";
        } else if (route.path[route.path.len - 1] == '/') {
            // For paths ending in "/", create directory/index.html structure
            const dir_path = route.path[1 .. route.path.len - 1]; // Remove leading "/" and trailing "/"
            file_path_owned = try std.fmt.allocPrint(allocator, "{s}/index.html", .{dir_path});
            file_path = file_path_owned.?;
        } else {
            const path_without_slash = route.path[1..]; // Remove leading "/"
            // Add .html extension if it doesn't have one
            if (std.fs.path.extension(path_without_slash).len == 0) {
                file_path_owned = try std.fmt.allocPrint(allocator, "{s}.html", .{path_without_slash});
                file_path = file_path_owned.?;
            } else {
                file_path = path_without_slash;
            }
        }

        const output_path = try std.fs.path.join(allocator, &.{ outdir, file_path });
        defer allocator.free(output_path);

        // Create parent directories if they don't exist
        const output_dir = std.fs.path.dirname(output_path);
        if (output_dir) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        try std.fs.cwd().writeFile(.{
            .sub_path = output_path,
            .data = response_text,
        });

        printer.printFilePath(file_path);

        // Recursively process nested routes
        if (route.routes) |nested_routes| {
            for (nested_routes) |nested_route| {
                try processRoute(allocator, port, nested_route, options, printer);
            }
        }
    }

    fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        // Remove trailing slash unless it's the root path
        if (path.len > 1 and path[path.len - 1] == '/') {
            return try allocator.dupe(u8, path[0 .. path.len - 1]);
        }
        return path;
    }

    fn matchRoute(
        request_path: []const u8,
        route: App.Meta.Route,
        parent_layouts: []const *const fn (ctx: zx.LayoutContext, component: Component) Component,
        pagectx: zx.PageContext,
        layoutctx: zx.LayoutContext,
        own_writer: ?*std.Io.Writer,
    ) !bool {
        const normalized_route_path = normalizePath(pagectx.arena, route.path) catch return false;

        // Check if this route matches the request path
        if (std.mem.eql(u8, request_path, normalized_route_path)) {
            var page = route.page(pagectx);

            // Apply all parent layouts first (in order from root to here)
            for (parent_layouts) |layout| {
                page = layout(layoutctx, page);
            }

            // Apply this route's own layout last
            if (route.layout) |layout| {
                page = layout(layoutctx, page);
            }

            const writer = own_writer orelse &layoutctx.response.buffer.writer;
            _ = writer.write("<!DOCTYPE html>\n") catch |err| {
                std.debug.print("Error writing HTML: {}\n", .{err});
                return true;
            };
            page.render(writer) catch |err| {
                std.debug.print("Error rendering page: {}\n", .{err});
                return true;
            };
            return true;
        }

        // Check sub-routes if they exist
        if (route.routes) |sub_routes| {
            // Build the layout chain for sub-routes
            // We need to accumulate parent_layouts + current route's layout (if it exists)
            var layouts_buffer: [10]*const fn (ctx: zx.LayoutContext, component: Component) Component = undefined;
            var layouts_count: usize = 0;

            // Copy all parent layouts
            for (parent_layouts) |layout| {
                layouts_buffer[layouts_count] = layout;
                layouts_count += 1;
            }

            // Add current route's layout if it exists
            if (route.layout) |layout| {
                layouts_buffer[layouts_count] = layout;
                layouts_count += 1;
            }

            const layouts_to_pass = layouts_buffer[0..layouts_count];

            for (sub_routes) |sub_route| {
                const matched = try matchRoute(request_path, sub_route, layouts_to_pass, pagectx, layoutctx, null);
                if (matched) {
                    return true;
                }
            }
        }

        return false;
    }
};

const std = @import("std");
const zx = @import("root.zig");
const Allocator = std.mem.Allocator;
const Component = zx.Component;
const Printer = @import("Printer.zig");
