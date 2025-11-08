const httpz = @import("httpz");
const std = @import("std");

const BaseContext = struct {
    request: *httpz.Request,
    response: *httpz.Response,
    allocator: std.mem.Allocator,
    parent_ctx: ?*BaseContext = null,

    pub fn init(request: *httpz.Request, response: *httpz.Response, allocator: std.mem.Allocator) BaseContext {
        return .{
            .request = request,
            .response = response,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BaseContext) void {
        self.allocator.destroy(self);
    }
};

pub const PageContext = BaseContext;
pub const LayoutContext = BaseContext;
