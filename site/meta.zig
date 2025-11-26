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
        .path = "/examples",
        .page = @import(".zx/pages/examples/page.zig").Page,
        .layout = @import(".zx/pages/examples/layout.zig").Layout,
    },
    .{
        .path = "/examples/form",
        .page = @import(".zx/pages/examples/form/page.zig").Page,
    },
    .{
        .path = "/cli",
        .page = @import(".zx/pages/cli/page.zig").Page,
        .layout = @import(".zx/pages/cli/layout.zig").Layout,
    },
    .{
        .path = "/cli/:id/command",
        .page = @import(".zx/pages/cli/page.zig").Page,
        .layout = @import(".zx/pages/cli/layout.zig").Layout,
    },
    .{
        .path = "/time",
        .page = @import(".zx/pages/time/page.zig").Page,
    },
};

pub const meta = zx.App.Meta{
    .routes = &routes,
    .rootdir = "site/.zx",
};

const zx = @import("zx");
