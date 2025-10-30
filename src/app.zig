pub const App = struct {
    pub const Meta = struct {
        pub const Route = struct {
            path: []const u8,
            page: *const fn (allocator: Allocator) Component,
            layout: ?*const fn (allocator: Allocator, component: Component) Component = null,
            routes: ?[]const Route = null,
        };
        routes: []const Route,
    };

    meta: Meta,

    pub fn init(meta: Meta) App {
        return .{ .meta = meta };
    }

    // Generic handler that doesn't depend on httpz
    pub fn handle(
        self: App,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        path: []const u8,
    ) !?[]const u8 {
        const request_path = normalizePath(allocator, path) catch {
            return "Internal Server Error";
        };

        const empty_layouts: []const *const fn (allocator: Allocator, component: Component) Component = &.{};

        for (self.meta.routes) |route| {
            const rendered = try matchRoute(request_path, route, empty_layouts, allocator, writer);
            if (rendered) {
                return null; // Successfully rendered to writer
            }
        }

        return "Not found";
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
        parent_layouts: []const *const fn (allocator: Allocator, component: Component) Component,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
    ) !bool {
        const normalized_route_path = normalizePath(allocator, route.path) catch return false;

        // Check if this route matches the request path
        if (std.mem.eql(u8, request_path, normalized_route_path)) {
            var page = route.page(allocator);

            // Apply all parent layouts first (in order from root to here)
            for (parent_layouts) |layout| {
                page = layout(allocator, page);
            }

            // Apply this route's own layout last
            if (route.layout) |layout| {
                page = layout(allocator, page);
            }

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
            var layouts_buffer: [10]*const fn (allocator: Allocator, component: Component) Component = undefined;
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
                const matched = try matchRoute(request_path, sub_route, layouts_to_pass, allocator, writer);
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
