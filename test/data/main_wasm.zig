pub const components = [_]ComponentMetadata{
.{
    .type = .csz,
    .id = "zx-3badae80b344e955a3048888ed2aae42",
    .name = "CounterComponent",
    .path = "component/csr_zig.zig",
    .import = @import("component/csr_zig.zig").CounterComponent,
}};

export fn main() void {
    const allocator = std.heap.wasm_allocator;

    for (components) |component| {
        renderToContainer(allocator, component) catch unreachable;
    }
}

fn renderToContainer(allocator: std.mem.Allocator, cmp: ComponentMetadata) !void {
    const document: js.Object = try js.global.get(js.Object, "document");
    defer document.deinit();

    const console: js.Object = try js.global.get(js.Object, "console");
    defer console.deinit();

    try console.call(void, "log", .{ js.string(cmp.id), js.string(cmp.name), js.string(cmp.path) });

    const buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);

    const Component = cmp.import(allocator, 0);
    try Component.render(&writer);

    const container: js.Object = document.call(js.Object, "getElementById", .{js.string(cmp.id)}) catch {
        try console.call(void, "log", .{js.string(cmp.id)});
        try console.call(void, "log", .{js.string("Container not found")});
        return;
    };
    defer container.deinit();

    try container.set("innerHTML", js.string(buffer[0..writer.end]));
}

pub const ComponentMetadata = struct {
    type: zx.Ast.ClientComponentMetadata.Type,
    id: []const u8,
    name: []const u8,
    path: []const u8,
    import: *const fn (allocator: std.mem.Allocator, count: i32) zx.Component,
};

const std = @import("std");
const zx = @import("zx");
const js = @import("js");
