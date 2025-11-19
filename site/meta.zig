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
        .path = "/time",
        .page = @import(".zx/pages/time/page.zig").Page,
    },
    .{
        .path = "/doc",
        .page = @import(".zx/pages/doc/page.zig").Page,
    },
    .{
        .path = "/doc/example",
        .page = @import(".zx/pages/doc/example/page.zig").Page,
        .layout = @import(".zx/pages/doc/example/layout.zig").Layout,
    },
    .{
        .path = "/doc/example/form",
        .page = @import(".zx/pages/doc/example/form/page.zig").Page,
    },
};

pub const meta = zx.App.Meta{
    .routes = &routes,
    .outdir = "site/.zx",
};

const zx = @import("zx");
