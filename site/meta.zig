pub const routes = [_]zx.App.Meta.Route{
    .{
        .path = "/",
        .page = @import(".zx/pages/page.zig").Page,
        .layout = @import(".zx/pages/layout.zig").Layout,
    },
    .{
        .path = "/about",
        .page = @import(".zx/pages/about/page.zig").Page,
    },
    .{
        .path = "/docs",
        .page = @import(".zx/pages/docs/page.zig").Page,
        .layout = @import(".zx/pages/docs/layout.zig").Layout,
    },
    .{
        .path = "/docs/example",
        .page = @import(".zx/pages/docs/example/page.zig").Page,
        .layout = @import(".zx/pages/docs/example/layout.zig").Layout,
    },
    .{
        .path = "/docs/example/form",
        .page = @import(".zx/pages/docs/example/form/page.zig").Page,
    },
    .{
        .path = "/docs/cli",
        .page = @import(".zx/pages/docs/cli/page.zig").Page,
    },
    .{
        .path = "/time",
        .page = @import(".zx/pages/time/page.zig").Page,
    },
    .{
        .path = "/doc",
        .page = @import(".zx/pages/docs/page.zig").Page,
    },
    .{
        .path = "/doc/example",
        .page = @import(".zx/pages/docs/example/page.zig").Page,
        .layout = @import(".zx/pages/docs/example/layout.zig").Layout,
    },
    .{
        .path = "/doc/example/form",
        .page = @import(".zx/pages/docs/example/form/page.zig").Page,
    },
};

pub const meta = zx.App.Meta{
    .routes = &routes,
    .rootdir = "site/.zx",
};

const zx = @import("zx");
