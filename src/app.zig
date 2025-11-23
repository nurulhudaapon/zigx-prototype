const httpz = @import("httpz");
const module_config = @import("zx_info");
const log = std.log.scoped(.app);

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
        pub const CliCommand = enum { dev, serve, @"export" };

        routes: []const Route,
        rootdir: []const u8,
        cli_command: ?CliCommand = null,
    };
    pub const Config = struct {
        server: httpz.Config,
        meta: Meta,
    };

    pub const Handler = struct {
        meta: App.Meta,
        allocator: std.mem.Allocator,

        pub fn handlePageRequest(self: *Handler, req: *httpz.Request, res: *httpz.Response) void {
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

            // log.debug("requst_path: {s}", .{request_path});
            const assets_path = std.fs.path.join(allocator, &.{
                self.meta.rootdir,
                if (std.mem.startsWith(u8, request_path, "/assets/")) "" else "public",
                request_path,
            }) catch return;
            defer allocator.free(assets_path);

            // log.debug("trying to read assets from {s}", .{assets_path});
            const file_content = std.fs.cwd().readFileAlloc(allocator, assets_path, std.math.maxInt(usize)) catch {
                res.status = 404;
                return;
            };

            // log.debug("found asset serving {s}", .{assets_path});
            res.content_type = httpz.ContentType.forFile(request_path);
            // res.header("Cache-Control", "max-age=31536000, public");
            res.body = file_content;
            return;
        }
    };

    pub const version = module_config.version_string;
    pub const info = std.fmt.comptimePrint("\x1b[1mZX\x1b[0m \x1b[2m· {s}\x1b[0m", .{version});

    allocator: std.mem.Allocator,
    meta: Meta,
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

        var router = try app.server.router(.{});

        // Static assets
        router.get("/assets/*", handlePageRequestWrapper, .{});
        router.get("/", handlePageRequestWrapper, .{});

        // Routes
        for (config.meta.routes) |route| {
            router.get(route.path, handlePageRequestWrapper, .{});
        }

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
        var port = self.server.config.port orelse Constant.default_port;
        var address = self.server.config.address orelse Constant.default_address;

        while (args.next()) |arg| {
            // --introspect: Print the metadata to stdout and exit
            if (std.mem.eql(u8, arg, "--introspect")) is_introspect = true;

            // --port: Override the configured/default port
            if (std.mem.eql(u8, arg, "--port")) {
                const port_str = args.next() orelse return error.MissingPort;
                const port_int = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
                port = port_int;
            }

            // --address: Override the configured/default address
            if (std.mem.eql(u8, arg, "--address")) address = args.next() orelse return error.MissingAddress;

            // --cli-command: Override the CLI command
            if (std.mem.eql(u8, arg, "--cli-command")) {
                const cli_command_str = args.next() orelse return error.MissingCliCommand;
                const cli_command = std.meta.stringToEnum(Meta.CliCommand, cli_command_str) orelse return error.InvalidCliCommand;
                self.meta.cli_command = cli_command;
            }
        }

        var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
        var stdout = &stdout_writer.interface;

        // Overriding or setting default configs
        self.server.config.port = port;
        self.server.config.address = address;
        self.server.config.request.max_form_count = self.server.config.request.max_form_count orelse Constant.default_max_form_count;

        if (is_introspect) {
            var aw = std.Io.Writer.Allocating.init(self.allocator);
            defer aw.deinit();

            var serilizable_meta = try SerilizableAppMeta.init(self.allocator, self);
            defer serilizable_meta.deinit(self.allocator);
            try serilizable_meta.serialize(&aw.writer);

            try stdout.print("{s}\n", .{aw.written()});
            std.process.exit(0);
        }

        // if (self.meta.cli_command == .dev) {
        var router = try self.server.router(.{});
        router.get("/_zx/devsocket", devsocket, .{});
        // }

        try stdout.flush();
    }

    fn handlePageRequestWrapper(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        handler.handlePageRequest(req, res);
    }

    fn devsocket(handler: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        _ = handler;
        _ = req;
        res.status = 200;
        res.header("Content-Type", "text/event-stream");
        res.header("Cache-Control", "no-cache");
        res.header("Connection", "keep-alive");

        try res.chunk(":connected\n\n");

        const interval_ns = 1 * std.time.ns_per_s; // 15 seconds
        while (true) {
            std.Thread.sleep(interval_ns);
            try res.chunk(":heartbeat\n\n");
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
            // Only add root layout if current route is NOT the root route
            // (root route's layout will be applied later as route.layout)
            const is_root_route = std.mem.eql(u8, normalized_route_path, "/");
            if (!is_root_route) {
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
                    // Skip if this parent path matches the current route (avoid double application)
                    if (std.mem.eql(u8, parent_path, normalized_route_path)) {
                        continue;
                    }
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
        pub const Route = struct {
            path: []const u8,
        };
        pub const Config = struct {
            server: httpz.Config,
        };

        binpath: ?[]const u8 = null,
        rootdir: ?[]const u8 = null,
        routes: []const Route,
        config: SerilizableAppMeta.Config,
        version: []const u8,
        cli_command: ?Meta.CliCommand = null,

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
                .rootdir = app.meta.rootdir,
                .cli_command = app.meta.cli_command,
            };
        }

        pub fn deinit(self: *SerilizableAppMeta, allocator: std.mem.Allocator) void {
            for (self.routes) |route| {
                allocator.free(route.path);
            }
            allocator.free(self.routes);

            allocator.free(self.version);
            if (self.rootdir) |rootdir| allocator.free(rootdir);
            if (self.binpath) |binpath| allocator.free(binpath);
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
const Printer = zx.Printer;
const Constant = @import("./constant.zig");
