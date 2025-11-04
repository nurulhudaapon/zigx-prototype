const zx = @import("zx");

pub const routes = [_]zx.App.Meta.Route{
    .{
        .path = "/",
        .page = @import("pages/page.zig").Page,
        .layout = @import("pages/layout.zig").Layout,
        .routes = &.{
            .{
                .path = "/about",
                .page = @import("pages/about/page.zig").Page,
                .routes = &.{
                    .{
                        .path = "/about/us",
                        .page = @import("pages/about/page.zig").Page,
                        .routes = &.{
                            .{
                                .path = "/about/us/info",
                                .page = @import("pages/about/page.zig").Page,
                            },
                        },
                    },
                    .{
                        .path = "/time",
                        .page = @import("pages/time/page.zig").Page,
                    },
                },
            },
        },
    },
};

pub const meta = zx.App.Meta{
    .routes = &routes,
};
