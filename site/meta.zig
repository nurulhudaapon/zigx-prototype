pub const routes = [_]zx.App.Meta.Route{
    .{
        .path = "/",
        .page = @import("page.zig").Page,
        .layout = @import("layout.zig").Layout,
        .routes = &.{
            .{
                .path = "/about",
                .page = @import("about/page.zig").Page,
                .layout = @import("layout.zig").Layout,
                .routes = &.{
                    .{
                        .path = "/about/us",
                        .page = @import("about/page.zig").Page,
                        .layout = @import("layout.zig").Layout,
                        .routes = &.{
                            .{
                                .path = "/about/us/info",
                                .page = @import("about/page.zig").Page,
                                .layout = @import("layout.zig").Layout,
                            },
                        },
                    },
                },
            },
        },
    },
};

const zx = @import("zx");
