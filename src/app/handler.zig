const httpz = @import("httpz");
const module_config = @import("zx_info");
const log = std.log.scoped(.app);

/// ElementInjector handles injecting elements into component trees
const ElementInjector = struct {
    allocator: std.mem.Allocator,

    /// Inject a script element into the body of a component
    /// Returns true if injection was successful, false if body element not found
    pub fn injectScriptIntoBody(self: ElementInjector, page: *Component, script_src: []const u8) bool {
        if (page.getElementByName(self.allocator, .body)) |body_element| {
            // Allocate attributes array properly (not a pointer to stack memory)
            const attributes = self.allocator.alloc(zx.Element.Attribute, 1) catch {
                std.debug.print("Error allocating attributes: OOM\n", .{});
                return false;
            };
            attributes[0] = .{
                .name = "src",
                .value = script_src,
            };

            const script_element = Component{
                .element = .{
                    .tag = .script,
                    .attributes = attributes,
                },
            };

            body_element.appendChild(self.allocator, script_element) catch |err| {
                std.debug.print("Error appending script to body: {}\n", .{err});
                self.allocator.free(attributes);
                return false;
            };
            return true;
        }
        return false;
    }
};

pub const Handler = struct {
    meta: *App.Meta,
    allocator: std.mem.Allocator,

    pub fn page(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        const allocator = self.allocator;

        const pagectx = zx.PageContext.init(req, res, allocator);
        const layoutctx = zx.LayoutContext.init(req, res, allocator);

        const is_dev_mode = self.meta.cli_command == .dev;
        // log.debug("cli command: {s}", .{@tagName(meta.cli_command orelse .serve)});

        if (req.route_data) |rd| {
            const route: *const App.Meta.Route = @ptrCast(@alignCast(rd));

            // Handle route rendering with error handling
            blk: {
                const normalized_route_path = route.path;

                var page_component = route.page(pagectx);

                // Find and apply parent layouts based on path hierarchy
                // Collect all parent layouts from root to this route
                var layouts_to_apply: [10]*const fn (ctx: zx.LayoutContext, component: Component) Component = undefined;
                var layouts_count: usize = 0;

                // Build the path segments to traverse from root to current route
                var path_segments = std.array_list.Managed([]const u8).init(pagectx.arena);
                var path_iter = std.mem.splitScalar(u8, req.url.path, '/');
                while (path_iter.next()) |segment| {
                    if (segment.len > 0) {
                        path_segments.append(segment) catch break :blk;
                    }
                }

                // First check root path "/"
                // Only add root layout if current route is NOT the root route
                // (root route's layout will be applied later as route.layout)
                const is_root_route = std.mem.eql(u8, normalized_route_path, "/");
                if (!is_root_route) {
                    for (self.meta.routes) |parent_route| {
                        const normalized_parent = parent_route.path;
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
                        for (self.meta.routes) |parent_route| {
                            const normalized_parent = parent_route.path;
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
                var injector: ?ElementInjector = null;
                if (is_dev_mode) {
                    // log.debug("Injecting dev script into body element of most parent layout (first one)", .{});
                    injector = ElementInjector{ .allocator = pagectx.arena };
                }

                for (0..layouts_count) |i| {
                    page_component = layouts_to_apply[i](layoutctx, page_component);
                    // In dev mode, inject dev script into body element of most parent layout (first one)
                    if (injector) |*inj| {
                        if (i == 0) {
                            // log.debug("Injecting dev script into body element of most parent layout (first one)", .{});
                            _ = inj.injectScriptIntoBody(&page_component, "/assets/_zx/devscript.js");
                            injector = null; // Only inject once
                        }
                    }
                }

                // Apply this route's own layout last
                if (route.layout) |layout_fn| {
                    page_component = layout_fn(layoutctx, page_component);
                    // In dev mode, inject into root route's layout if this is the root route (most parent)
                    if (injector) |*inj| {
                        if (is_root_route) {
                            _ = inj.injectScriptIntoBody(&page_component, "/assets/_zx/devscript.js");
                        }
                    }
                }

                const writer = &layoutctx.response.buffer.writer;
                _ = writer.write("<!DOCTYPE html>\n") catch |err| {
                    std.debug.print("Error writing HTML: {}\n", .{err});
                    break :blk;
                };
                page_component.render(writer) catch |err| {
                    std.debug.print("Error rendering page: {}\n", .{err});
                    break :blk;
                };
            }

            res.content_type = .HTML;
            return;
        }
    }

    pub fn assets(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        const allocator = self.allocator;

        const assets_path = try std.fs.path.join(allocator, &.{ self.meta.rootdir, req.url.path });
        defer allocator.free(assets_path);

        res.content_type = httpz.ContentType.forFile(req.url.path);
        res.body = std.fs.cwd().readFileAlloc(allocator, assets_path, std.math.maxInt(usize)) catch {
            res.setStatus(.not_found);
            return;
        };
    }

    pub fn public(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        const allocator = self.allocator;

        const assets_path = try std.fs.path.join(allocator, &.{ self.meta.rootdir, "public", req.url.path });
        defer allocator.free(assets_path);

        res.content_type = httpz.ContentType.forFile(req.url.path);
        res.body = std.fs.cwd().readFileAlloc(allocator, assets_path, std.math.maxInt(usize)) catch {
            res.setStatus(.not_found);
            return;
        };
    }

    const DevSocketContext = struct {
        fn handle(self: DevSocketContext, stream: std.net.Stream) void {
            _ = self;
            // Set retry interval to 100ms for fast reconnection when server restarts
            stream.writeAll("retry: 100\n\n") catch return;

            // Send periodic heartbeats to keep connection alive
            const heartbeat_interval_ns = 30 * std.time.ns_per_s; // 30 seconds
            while (true) {
                std.Thread.sleep(heartbeat_interval_ns);
                // Send heartbeat as a comment (doesn't trigger events)
                stream.writeAll(":heartbeat\n\n") catch return;
            }
        }
    };

    pub fn devsocket(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        _ = self;
        _ = req;

        // Add optional header to disable nginx buffering
        res.header("X-Accel-Buffering", "no");

        // Start the event stream (automatically sets Content-Type, Cache-Control, Connection)
        // When server restarts, connection drops and client will reconnect automatically
        try res.startEventStream(DevSocketContext{}, DevSocketContext.handle);
    }
};

const std = @import("std");
const zx = @import("../root.zig");
const Allocator = std.mem.Allocator;
const Component = zx.Component;
const Printer = zx.Printer;
const App = zx.App;
