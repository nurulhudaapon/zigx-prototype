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

            for (self.meta.routes) |route| {
                const rendered = matchRoute(request_path, route, pagectx, layoutctx, null, self.meta.routes) catch {
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

        // Introspect the app, this will exit the program in some cases like --introspect flag
        try app.introspect();

        return app;
    }

    pub fn deinit(self: *App) void {
        const allocator = self.allocator;

        if (self._is_listening) {
            self.server.stop();
            self._is_listening = false;
        }
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

    pub fn introspect(self: *App) !void {
        var args = std.process.args();
        defer args.deinit();

        // --- Flags --- //
        // --introspect: Print the metadata to stdout and exit
        var is_introspect = false;
        var outdir: ?[]const u8 = null;

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--introspect")) is_introspect = true;
            if (std.mem.eql(u8, arg, "--outdir")) outdir = args.next() orelse return error.MissingOutdir;
        }

        var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
        var stdout = &stdout_writer.interface;

        if (is_introspect) {
            var aw = std.Io.Writer.Allocating.init(self.allocator);
            defer aw.deinit();

            var serilizable_meta = try SerilizableAppMeta.init(self.allocator, self);
            serilizable_meta.outdir = outdir;
            defer serilizable_meta.deinit(self.allocator);
            try serilizable_meta.serialize(&aw.writer);

            try stdout.print("{s}\n", .{aw.written()});
            std.process.exit(0);
        }

        try stdout.flush();
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
        pagectx: zx.PageContext,
        layoutctx: zx.LayoutContext,
        own_writer: ?*std.Io.Writer,
        all_routes: []const App.Meta.Route,
    ) !bool {
        const normalized_route_path = normalizePath(pagectx.arena, route.path) catch return false;

        // Check if this route matches the request path
        if (std.mem.eql(u8, request_path, normalized_route_path)) {
            var page = route.page(pagectx);

            // Find and apply parent layouts based on path hierarchy
            // Collect all parent layouts from root to this route
            var layouts_to_apply: [10]*const fn (ctx: zx.LayoutContext, component: Component) Component = undefined;
            var layouts_count: usize = 0;

            // Build the path segments to traverse from root to current route
            var path_segments = std.array_list.Managed([]const u8).init(pagectx.arena);
            var path_iter = std.mem.splitScalar(u8, request_path, '/');
            while (path_iter.next()) |segment| {
                if (segment.len > 0) {
                    try path_segments.append(segment);
                }
            }

            // First check root path "/"
            for (all_routes) |parent_route| {
                const normalized_parent = normalizePath(pagectx.arena, parent_route.path) catch continue;
                if (std.mem.eql(u8, normalized_parent, "/")) {
                    if (parent_route.layout) |layout_fn| {
                        if (layouts_count < layouts_to_apply.len) {
                            layouts_to_apply[layouts_count] = layout_fn;
                            layouts_count += 1;
                        }
                    }
                    break;
                }
            }

            // Traverse from root to current route, collecting layouts
            // Only iterate if there are path segments beyond root
            if (path_segments.items.len > 1) {
                for (1..path_segments.items.len) |depth| {
                    // Build the path up to this depth
                    var path_buf: [256]u8 = undefined;
                    var path_stream = std.io.fixedBufferStream(&path_buf);
                    const path_writer = path_stream.writer();
                    _ = path_writer.write("/") catch break;

                    for (0..depth) |i| {
                        _ = path_writer.write(path_segments.items[i]) catch break;
                        if (i < depth - 1) {
                            _ = path_writer.write("/") catch break;
                        }
                    }
                    const parent_path = path_buf[0 .. path_stream.getPos() catch break];

                    // Find route with matching path
                    for (all_routes) |parent_route| {
                        const normalized_parent = normalizePath(pagectx.arena, parent_route.path) catch continue;
                        if (std.mem.eql(u8, normalized_parent, parent_path)) {
                            if (parent_route.layout) |layout_fn| {
                                if (layouts_count < layouts_to_apply.len) {
                                    layouts_to_apply[layouts_count] = layout_fn;
                                    layouts_count += 1;
                                }
                            }
                            break;
                        }
                    }
                }
            }

            // Apply layouts in order (root to leaf)
            for (0..layouts_count) |i| {
                page = layouts_to_apply[i](layoutctx, page);
            }

            // Apply this route's own layout last
            if (route.layout) |layout_fn| {
                page = layout_fn(layoutctx, page);
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

        return false;
    }

    pub const SerilizableAppMeta = struct {
        const Route = struct {
            path: []const u8,
        };
        const Config = struct {
            server: httpz.Config,
        };

        outdir: ?[]const u8 = null,
        routes: []const Route,
        config: SerilizableAppMeta.Config,
        version: []const u8,

        pub fn init(allocator: std.mem.Allocator, app: *const App) !SerilizableAppMeta {
            var routes = try allocator.alloc(Route, app.meta.routes.len);

            for (app.meta.routes, 0..) |route, i| {
                routes[i] = Route{
                    .path = try allocator.dupe(u8, route.path),
                };
            }

            return SerilizableAppMeta{
                .routes = routes,
                .config = SerilizableAppMeta.Config{
                    .server = app.server.config,
                },
                .version = App.version,
            };
        }

        pub fn deinit(self: *SerilizableAppMeta, allocator: std.mem.Allocator) void {
            for (self.routes) |route| {
                allocator.free(route.path);
            }
            allocator.free(self.routes);
        }

        pub fn serialize(self: *const SerilizableAppMeta, writer: anytype) !void {
            try std.zon.stringify.serialize(self, .{
                .whitespace = true,
                .emit_default_optional_fields = true,
            }, writer);
        }
    };
};

const std = @import("std");
const zx = @import("root.zig");
const Allocator = std.mem.Allocator;
const Component = zx.Component;
const Printer = @import("Printer.zig");
