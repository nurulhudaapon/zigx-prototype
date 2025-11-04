//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const Ast = @import("zx/Ast.zig");
pub const Allocator = std.mem.Allocator;

const ElementTag = enum { slot, svg, path, img, html, base, head, link, meta, script, style, title, address, article, body, h1, h6, footer, header, h2, h3, h4, h5, hgroup, nav, section, dd, dl, dt, div, figcaption, figure, hr, li, ol, ul, menu, main, p, pre, a, abbr, b, bdi, bdo, br, cite, code, data, time, dfn, em, i, kbd, mark, q, blockquote, rp, ruby, rt, rtc, rb, s, del, ins, samp, small, span, strong, sub, sup, u, @"var", wbr, area, map, audio, source, track, video, embed, object, param, canvas, noscript, caption, table, col, colgroup, tbody, tr, thead, tfoot, td, th, button, datalist, option, fieldset, label, form, input, keygen, legend, meter, optgroup, select, output, progress, textarea, details, dialog, menuitem, summary, content, element, shadow, template, acronym, applet, basefont, font, big, blink, center, command, dir, frame, frameset, isindex, listing, marquee, noembed, plaintext, spacer, strike, tt, xmp };
const SELF_CLOSING_ONLY: []const ElementTag = &.{ .br, .hr, .img, .input, .link, .source, .track, .wbr };
const NO_CHILDREN_ONLY: []const ElementTag = &.{ .meta, .link, .input };

fn isSelfClosing(tag: ElementTag) bool {
    return std.mem.indexOfScalar(ElementTag, SELF_CLOSING_ONLY, tag) != null;
}

fn isNoClosing(tag: ElementTag) bool {
    return std.mem.indexOfScalar(ElementTag, NO_CHILDREN_ONLY, tag) != null;
}

pub const Component = union(enum) {
    text: []const u8,
    element: Element,
    component_fn: ComponentFn,

    pub const ComponentFn = struct {
        propsPtr: *const anyopaque,
        callFn: *const fn (propsPtr: *const anyopaque, allocator: Allocator) Component,
        allocator: Allocator,
        deinitFn: ?*const fn (propsPtr: *const anyopaque, allocator: Allocator) void,

        pub fn init(comptime func: anytype, allocator: Allocator, props: anytype) ComponentFn {
            const FuncInfo = @typeInfo(@TypeOf(func));
            const PropsType = @TypeOf(props);

            // Allocate props on heap to persist
            const props_copy = allocator.create(PropsType) catch @panic("OOM");
            props_copy.* = props;

            const Wrapper = struct {
                fn call(propsPtr: *const anyopaque, alloc: Allocator) Component {
                    const p: *const PropsType = @ptrCast(@alignCast(propsPtr));

                    // Check function signature and call appropriately
                    if (FuncInfo.@"fn".params.len == 0) {
                        return func();
                    } else if (FuncInfo.@"fn".params.len == 1) {
                        return func(alloc);
                    } else if (FuncInfo.@"fn".params.len == 2) {
                        return func(alloc, p.*);
                    } else {
                        @compileError("Component function must have 0, 1 (allocator), or 2 (allocator, props) parameters");
                    }
                }

                fn deinit(propsPtr: *const anyopaque, alloc: Allocator) void {
                    const p: *const PropsType = @ptrCast(@alignCast(propsPtr));
                    alloc.destroy(p);
                }
            };

            return .{
                .propsPtr = props_copy,
                .callFn = Wrapper.call,
                .allocator = allocator,
                .deinitFn = Wrapper.deinit,
            };
        }

        pub fn call(self: ComponentFn) Component {
            return self.callFn(self.propsPtr, self.allocator);
        }

        pub fn deinit(self: ComponentFn) void {
            if (self.deinitFn) |deinit_fn| {
                deinit_fn(self.propsPtr, self.allocator);
            }
        }
    };

    /// Free allocated memory recursively
    /// Note: Only frees what was allocated by ZxContext.zx()
    /// Inline struct data is not freed (and will cause no issues as it's stack data)
    pub fn deinit(self: Component, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => {},
            .element => |elem| {
                if (elem.children) |children| {
                    // Recursively free children (e.g., Button() results)
                    for (children) |child| {
                        child.deinit(allocator);
                    }
                    // Free the children array itself
                    allocator.free(children);
                }
                if (elem.attributes) |attributes| {
                    allocator.free(attributes);
                }
            },
            .component_fn => |func| {
                // Free the props that were allocated
                func.deinit();
            },
        }
    }

    pub fn render(self: Component, writer: *std.Io.Writer) !void {
        try self.internalRender(writer, null);
    }

    /// Stream method that renders HTML while collecting elements with 'slot' attribute
    /// Returns an array of Component elements that have a 'slot' attribute
    pub fn stream(self: Component, allocator: std.mem.Allocator, writer: *std.Io.Writer) ![]Component {
        var slots = std.array_list.Managed(Component).init(allocator);
        errdefer slots.deinit();

        try self.internalRender(writer, &slots);
        return slots.toOwnedSlice();
    }

    fn internalRender(self: Component, writer: *std.Io.Writer, slots: ?*std.array_list.Managed(Component)) !void {
        switch (self) {
            .text => |text| {
                try writer.print("{s}", .{text});
            },
            .component_fn => |func| {
                // Lazily invoke the component function and render its result
                const component = func.call();
                try component.internalRender(writer, slots);
            },
            .element => |elem| {
                // Check if this element has a 'slot' attribute and we're collecting slots
                if (slots != null) {
                    var has_slot = false;
                    if (elem.attributes) |attributes| {
                        for (attributes) |attribute| {
                            if (std.mem.eql(u8, attribute.name, "slot")) {
                                has_slot = true;
                                break;
                            }
                        }
                    }

                    // If element has 'slot' attribute, accumulate it instead of rendering
                    if (has_slot) {
                        try slots.?.append(self);
                        return;
                    }
                }

                // Otherwise, render normally
                // Opening tag
                try writer.print("<{s}", .{@tagName(elem.tag)});

                const is_self_closing = isSelfClosing(elem.tag);
                const is_no_closing = isNoClosing(elem.tag);

                // Handle attributes
                if (elem.attributes) |attributes| {
                    for (attributes) |attribute| {
                        try writer.print(" {s}", .{attribute.name});
                        if (attribute.value) |value| {
                            try writer.print("=\"{s}\"", .{value});
                        }
                    }
                }

                // Closing bracket
                if (!is_self_closing or is_no_closing) {
                    try writer.print(">", .{});
                } else {
                    try writer.print(" />", .{});
                }

                // Render children (recursively collect slots if needed)
                if (elem.children) |children| {
                    for (children) |child| {
                        try child.internalRender(writer, slots);
                    }
                }

                // Closing tag
                if (!is_self_closing and !is_no_closing) {
                    try writer.print("</{s}>", .{@tagName(elem.tag)});
                }
            },
        }
    }

    pub fn action(self: @This(), _: anytype, _: anytype, res: anytype) !void {
        res.content_type = .HTML;
        try self.render(&res.buffer.writer);
    }
};

const Element = struct {
    const Attribute = struct {
        name: []const u8,
        value: ?[]const u8 = null,
    };

    tag: ElementTag,
    children: ?[]const Component = null,
    attributes: ?[]const Attribute = null,
};

const ZxOptions = struct {
    children: ?[]const Component = null,
    attributes: ?[]const Element.Attribute = null,
};

pub fn zx(tag: ElementTag, options: ZxOptions) Component {
    return .{ .element = .{
        .tag = tag,
        .children = options.children,
        .attributes = options.attributes,
    } };
}

/// Create a lazy component from a function
/// The function will be invoked during rendering, allowing for dynamic slot handling
/// Supports functions with 0 params (), 1 param (allocator), or 2 params (allocator, props)
pub fn lazy(allocator: Allocator, comptime func: anytype, props: anytype) Component {
    return .{ .component_fn = Component.ComponentFn.init(func, allocator, props) };
}

/// Context for creating components with allocator support
const ZxContext = struct {
    allocator: std.mem.Allocator,

    pub fn zx(self: ZxContext, tag: ElementTag, options: ZxOptions) Component {
        // Allocate and copy children if provided
        const children_copy = if (options.children) |children| blk: {
            const copy = self.allocator.alloc(Component, children.len) catch @panic("OOM");
            @memcpy(copy, children);
            break :blk copy;
        } else null;

        // Allocate and copy attributes if provided
        const attributes_copy = if (options.attributes) |attributes| blk: {
            const copy = self.allocator.alloc(Element.Attribute, attributes.len) catch @panic("OOM");
            @memcpy(copy, attributes);
            break :blk copy;
        } else null;

        return .{ .element = .{
            .tag = tag,
            .children = children_copy,
            .attributes = attributes_copy,
        } };
    }

    pub fn txt(self: ZxContext, text: []const u8) Component {
        const copy = self.allocator.alloc(u8, text.len) catch @panic("OOM");
        @memcpy(copy, text);
        return .{ .text = copy };
    }

    pub fn fmt(self: ZxContext, comptime format: []const u8, args: anytype) Component {
        const text = std.fmt.allocPrint(self.allocator, format, args) catch @panic("OOM");
        return .{ .text = text };
    }

    pub fn lazy(self: ZxContext, comptime func: anytype, props: anytype) Component {
        return .{ .component_fn = Component.ComponentFn.init(func, self.allocator, props) };
    }
};

/// Initialize a ZxContext with an allocator
pub fn init(allocator: std.mem.Allocator) ZxContext {
    return .{ .allocator = allocator };
}

pub const App = @import("app.zig").App;
