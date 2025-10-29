pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const render_options = zx.RenderOptions{
        .whitespace = .indent_2,
        .current_depth = 0,
        .max_width = 80,
    };

    // Use arena allocator for component tree - frees everything at once
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const page_allocator = arena.allocator();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // const pageComponent = Page(page_allocator);
    try Layout(page_allocator).element.render(&aw.writer, render_options);
    std.debug.print("{s}\n", .{aw.written()});
    aw.clearRetainingCapacity();

    try Page(page_allocator).element.render(&aw.writer, render_options);
    std.debug.print("{s}\n", .{aw.written()});
    aw.clearRetainingCapacity();

    try AboutPage(page_allocator).element.render(&aw.writer, render_options);
    std.debug.print("{s}\n", .{aw.written()});
    aw.clearRetainingCapacity();
}

const std = @import("std");
const zx = @import("zx");
const Layout = @import("layout.zig").Layout;
const Page = @import("page.zig").Page;
const AboutPage = @import("about/page.zig").Page;
