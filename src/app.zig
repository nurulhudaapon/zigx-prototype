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

    pub const version = module_config.version_string;
    pub const info = std.fmt.comptimePrint("\x1b[1mZX\x1b[0m \x1b[2m- v{s}\x1b[0m", .{version});

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
        app.handler = Handler{
            .meta = &app.meta,
            .allocator = allocator,
        };
        app.server = try httpz.Server(*Handler).init(allocator, config.server, &app.handler);

        var router = try app.server.router(.{});

        // Static assets
        router.get("/assets/*", Handler.assets, .{});
        router.get("/*", Handler.public, .{});

        // Routes
        for (config.meta.routes) |route| {
            const route_data = try allocator.create(App.Meta.Route);
            route_data.* = route;

            router.get(route.path, Handler.page, .{ .data = route_data });
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

    fn introspect(self: *App) !void {
        var args = try std.process.argsWithAllocator(self.allocator);
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

            // --rootdir: Override the configured/default root directory
            if (std.mem.eql(u8, arg, "--rootdir")) self.meta.rootdir = args.next() orelse return error.MissingRootdir;

            // --cli-command: Override the CLI command
            if (std.mem.eql(u8, arg, "--cli-command")) {
                const cli_command_str = args.next() orelse return error.MissingCliCommand;
                const cli_command = std.meta.stringToEnum(Meta.CliCommand, cli_command_str) orelse return error.InvalidCliCommand;
                self.meta.cli_command = cli_command;

                // log.debug("CLI command: {s}", .{cli_command_str});
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

        if (self.meta.cli_command == .dev) {
            var router = try self.server.router(.{});
            router.get("/_zx/devsocket", Handler.devsocket, .{});
        }

        try stdout.flush();
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
        cli_command: ?App.Meta.CliCommand = null,

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
const httpz = @import("httpz");
const module_config = @import("zx_info");
const log = std.log.scoped(.app);
const Handler = @import("./app/handler.zig").Handler;
