const httpz = @import("httpz");
const std = @import("std");

/// Base context structure that provides access to request/response objects and allocators.
/// This is the foundation for both PageContext and LayoutContext, providing common functionality
/// for handling HTTP requests and managing memory allocation.
const BaseContext = struct {
    /// The HTTP request object containing all request data (headers, body, query params, form data, etc.)
    request: *httpz.Request,
    /// The HTTP response object used to write the response body and set headers
    response: *httpz.Response,
    /// Global allocator passed from the app, only cleared when the app is deinitialized.
    /// Should be used for allocating memory that needs to persist across requests.
    /// Make sure to free the memory on your own that is allocated with this allocator.
    allocator: std.mem.Allocator,
    /// Allocator for allocating memory that needs to be freed after the request is processed.
    /// This allocator is cleared automatically when the request is processed, so you don't need
    /// to manually free memory allocated with this allocator. Use this for temporary allocations
    /// that are only needed during request processing.
    arena: std.mem.Allocator,
    /// Optional parent context, used for nested layouts or hierarchical context passing
    parent_ctx: ?*BaseContext = null,

    /// Initialize a new BaseContext with the given request, response, and allocator.
    /// The arena allocator is automatically set from the request's arena.
    pub fn init(request: *httpz.Request, response: *httpz.Response, allocator: std.mem.Allocator) BaseContext {
        return .{
            .request = request,
            .response = response,
            .allocator = allocator,
            .arena = request.arena,
        };
    }

    /// Deinitialize the context, freeing any resources allocated with the global allocator.
    /// Note: The arena allocator is automatically cleaned up by the request handler.
    pub fn deinit(self: *BaseContext) void {
        self.allocator.destroy(self);
    }
};

/// Context passed to page components. Provides access to the current HTTP request and response,
/// as well as allocators for memory management.
///
/// Usage in a page component:
/// ```zig
/// pub fn Page(ctx: zx.PageContext) zx.Component {
///     const allocator = ctx.arena; // Use arena for temporary allocations
///     // Access request data
///     const query = ctx.request.query() catch unreachable;
///     // Render component
///     return <div>Hello</div>;
/// }
/// ```
pub const PageContext = BaseContext;

/// Context passed to layout components. Provides access to the current HTTP request and response,
/// as well as allocators for memory management. Layouts wrap page components and can be nested.
///
/// Usage in a layout component:
/// ```zig
/// pub fn Layout(ctx: zx.LayoutContext, children: zx.Component) zx.Component {
///     return (
///         <html>
///             <head><title>My App</title></head>
///             <body>{children}</body>
///         </html>
///     );
/// }
/// ```
pub const LayoutContext = BaseContext;
