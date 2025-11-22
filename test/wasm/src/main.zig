const std = @import("std");
const zx = @import("zx");
const js = @import("js");

export fn main() void {
    const allocator = std.heap.wasm_allocator;

    const buffer = allocator.alloc(u8, 102400000) catch unreachable;
    var writer = std.Io.Writer.fixed(buffer);

    for (components) |component| {
        for (0..1000) |i| {
            writer.end = 0;
            const count: i32 = @intCast(i);
            const cmp = component.import(allocator, count);
            cmp.render(&writer) catch unreachable;
        }
        renderToBody(buffer[0..writer.end]) catch unreachable;
    }
}

fn renderToBody(html: []const u8) !void {
    const doc = try js.global.get(js.Object, "document");
    defer doc.deinit();

    const body = try doc.get(js.Object, "body");
    defer body.deinit();

    try body.set("innerHTML", js.string(html));
}

pub const ComponentMetadata = struct {
    type: zx.Ast.ClientComponentMetadata.Type,
    id: []const u8,
    name: []const u8,
    path: []const u8,
    import: *const fn (allocator: std.mem.Allocator, count: i32) zx.Component,
};

pub const components = [_]ComponentMetadata{
    .{
        .type = .csz,
        .id = "zx-3badae80b344e955a3048888ed2aae42",
        .name = "CounterComponent",
        .path = "component/csr_zig.zig",
        .import = @import("component.zig").CounterComponent,
    },
};
