pub const components = [_]ComponentMetadata{
    .{
        .type = .csz,
        .id = "zx-3badae80b344e955a3048888ed2aae42",
        .name = "CounterComponent",
        .path = "component/csr_zig.zig",
        .import = @import("component.zig").CounterComponent,
    },
};

export fn main() void {
    const allocator = std.heap.wasm_allocator;

    for (components) |component| {
        renderToContainer(allocator, component) catch unreachable;
    }
}

export var count: i32 = 0;

export fn onclick(value: i32) void {
    const allocator = std.heap.wasm_allocator;

    const console = Console.init();
    defer console.deinit();

    count += 1;

    const event = Event.idxInit(allocator, value) catch @panic("Failed to get event");

    console.log(.{
        js.string("Value: "),
        value,
        js.string("Count: "),
        event._count,
        js.string("Data: "),
        js.string(event.target.value),
    });

    main();
}

fn renderToContainer(allocator: std.mem.Allocator, cmp: ComponentMetadata) !void {
    const document = try Document.init(allocator);
    defer document.deinit();

    const console = Console.init();
    defer console.deinit();

    const buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(buffer);

    var writer = std.Io.Writer.fixed(buffer);

    const Component = cmp.import(allocator, count);
    try Component.render(&writer);

    const container = document.getElementById(cmp.id) catch {
        console.log(.{js.string(cmp.id)});
        console.log(.{js.string("Container not found")});
        return;
    };
    defer container.deinit();

    try container.setInnerHTML(buffer[0..writer.end]);
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
const Console = @import("dom.zig").Console;
const Document = @import("dom.zig").Document;
const Event = @import("dom.zig").Event;
