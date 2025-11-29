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

pub const Event = struct {
    const EventTarget = struct {
        value: []const u8,
    };
    _count: i32,

    object: js.Object,
    target: EventTarget,
    data: ?[]const u8 = null,

    pub fn idxInit(allocator: std.mem.Allocator, idx: i64) !Event {
        const console = Console.init();
        defer console.deinit();

        const obj: js.Object = try js.global.get(js.Object, "_zx");
        defer obj.deinit();

        const ob_val: js.Object = try obj.get(js.Object, "events");
        defer ob_val.deinit();

        const count = try ob_val.get(i32, "length");

        const current_event: js.Object = try ob_val.call(js.Object, "at", .{idx});
        defer current_event.deinit();

        const target = try current_event.get(js.Object, "target");
        defer target.deinit();

        console.log(.{ js.string("Target: "), target });

        const target_value: []const u8 = target.getAlloc(js.String, allocator, "value") catch |err| {
            console.log(.{ js.string("Error: "), err });
            return err;
        };
        console.log(.{ js.string("Target Value: "), js.string(target_value) });

        const event_target: EventTarget = .{
            .value = target_value,
        };

        const event_data: ?[]const u8 = current_event.getAlloc(js.String, allocator, "data") catch null;

        return .{
            ._count = count,
            .target = event_target,
            .data = event_data,
            .object = current_event,
        };
    }
};

const std = @import("std");
const zx = @import("zx");
const js = @import("js");
