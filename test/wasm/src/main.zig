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

var count: i32 = 0;
export fn onclick(n: i32) void {
    const console = Console.init();
    defer console.deinit();

    count += n;

    console.log(.{js.string("Button clicked")});
    console.log(.{n});
    console.log(.{count});

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

    console.log(.{ js.string(cmp.id), js.string(cmp.name), js.string(cmp.path) });

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

// Exploration of the DOM API, we may not need this if we can use the JS API directly
pub const Console = struct {
    object: js.Object,

    pub fn init() Console {
        return .{
            .object = js.global.get(js.Object, "console") catch @panic("Console not found"),
        };
    }

    pub fn deinit(self: Console) void {
        self.object.deinit();
    }

    pub fn log(self: Console, args: anytype) void {
        self.object.call(void, "log", args) catch @panic("Failed to call console.log");
    }
};

pub const Document = struct {
    const HTMLElement = struct {
        object: js.Object,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, object: js.Object) !HTMLElement {
            return .{
                .object = object,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: HTMLElement) void {
            self.object.deinit();
        }

        pub fn setInnerHTML(self: HTMLElement, html: []const u8) !void {
            return try self.object.set("innerHTML", js.string(html));
        }
    };

    object: js.Object,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Document {
        const obj = try js.global.get(js.Object, "document");
        return .{
            .object = obj,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Document) void {
        self.object.deinit();
    }

    pub fn getElementById(self: Document, id: []const u8) error{ElementNotFound}!HTMLElement {
        const obj: js.Object = self.object.call(js.Object, "getElementById", .{js.string(id)}) catch {
            return error.ElementNotFound;
        };

        return try HTMLElement.init(self.allocator, obj);
    }
};

const std = @import("std");
const zx = @import("zx");
const js = @import("js");
