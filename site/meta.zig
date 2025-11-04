const zx = @import("zx");

pub const routes = [_]zx.App.Meta.Route{
    .{
        .path = "/",
        .page = @import(".zx/pages/page.zig").Page,
        .layout = @import(".zx/pages/layout.zig").Layout,
        .routes = &.{
            .{
                .path = "/about",
                .page = @import(".zx/pages/about/page.zig").Page,
                .routes = &.{
                    .{
                        .path = "/about/us",
                        .page = @import(".zx/pages/about/page.zig").Page,
                        .routes = &.{
                            .{
                                .path = "/about/us/info",
                                .page = @import(".zx/pages/about/page.zig").Page,
                            },
                        },
                    },
                    .{
                        .path = "/time",
                        .page = @import(".zx/pages/time/page.zig").Page,
                    },
                },
            },
            .{
                .path = "/example",
                .page = @import(".zx/pages/doc/example/page.zig").Page,
            },
        },
    },
    .{
        .path = "/doc",
        .page = @import(".zx/pages/doc/page.zig").Page,
    },
};

pub const meta = zx.App.Meta{
    .routes = &routes,
};
