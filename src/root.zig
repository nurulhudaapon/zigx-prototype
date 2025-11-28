//! ZX - A Zig library for building web applications with JSX-like syntax.
//! This module provides the core component system, rendering engine, and utilities
//! for creating type-safe, high-performance web applications with server-side rendering.
const std = @import("std");

pub const Ast = @import("zx/Ast.zig");
pub const Allocator = std.mem.Allocator;

const ElementTag = enum { aside, fragment, polyline, iframe, slot, svg, path, img, html, base, head, link, meta, script, style, title, address, article, body, h1, h6, footer, header, h2, h3, h4, h5, hgroup, nav, section, dd, dl, dt, div, figcaption, figure, hr, li, ol, ul, menu, main, p, pre, a, abbr, b, bdi, bdo, br, cite, code, data, time, dfn, em, i, kbd, mark, q, blockquote, rp, ruby, rt, rtc, rb, s, del, ins, samp, small, span, strong, sub, sup, u, @"var", wbr, area, map, audio, source, track, video, embed, object, param, canvas, noscript, caption, table, col, colgroup, tbody, tr, thead, tfoot, td, th, button, datalist, option, fieldset, label, form, input, keygen, legend, meter, optgroup, select, output, progress, textarea, details, dialog, menuitem, summary, content, element, shadow, template, acronym, applet, basefont, font, big, blink, center, command, dir, frame, frameset, isindex, listing, marquee, noembed, plaintext, spacer, strike, tt, xmp };
const SELF_CLOSING_ONLY: []const ElementTag = &.{ .br, .hr, .img, .input, .link, .source, .track, .wbr };
const NO_CHILDREN_ONLY: []const ElementTag = &.{ .meta, .link, .input };

fn isSelfClosing(tag: ElementTag) bool {
    return std.mem.indexOfScalar(ElementTag, SELF_CLOSING_ONLY, tag) != null;
}

fn isNoClosing(tag: ElementTag) bool {
    return std.mem.indexOfScalar(ElementTag, NO_CHILDREN_ONLY, tag) != null;
}

/// Escape HTML attribute values to prevent XSS attacks
/// Escapes: & < > " '
fn escapeAttributeValueToWriter(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |char| {
        switch (char) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#x27;"),
            else => try writer.writeByte(char),
        }
    }
}

/// Coerce props to the target struct type, handling defaults
fn coerceProps(comptime TargetType: type, props: anytype) TargetType {
    const TargetInfo = @typeInfo(TargetType);
    if (TargetInfo != .@"struct") {
        @compileError("Target type must be a struct");
    }

    const fields = TargetInfo.@"struct".fields;
    var result: TargetType = undefined;

    inline for (fields) |field| {
        if (@hasField(@TypeOf(props), field.name)) {
            @field(result, field.name) = @field(props, field.name);
        } else if (field.defaultValue()) |default_value| {
            @field(result, field.name) = default_value;
        } else {
            @compileError(std.fmt.comptimePrint("Missing required field: {s}", .{field.name}));
        }
    }

    return result;
}

pub const Component = union(enum) {
    text: []const u8,
    element: Element,
    component_fn: ComponentFn,
    component_csr: ComponentCsr,

    pub const ComponentCsr = struct {
        name: []const u8,
        path: []const u8,
        id: []const u8,
        props_json: ?[]const u8 = null,
    };

    pub const ComponentFn = struct {
        propsPtr: ?*const anyopaque,
        callFn: *const fn (propsPtr: ?*const anyopaque, allocator: Allocator) Component,
        allocator: Allocator,
        deinitFn: ?*const fn (propsPtr: ?*const anyopaque, allocator: Allocator) void,

        pub fn init(comptime func: anytype, allocator: Allocator, props: anytype) ComponentFn {
            const FuncInfo = @typeInfo(@TypeOf(func));
            const param_count = FuncInfo.@"fn".params.len;
            const fn_name = @typeName(@TypeOf(func));

            // Validation of parameters
            if (param_count != 1 and param_count != 2)
                @compileError(std.fmt.comptimePrint("{s} must have 1 or 2 parameters found {d} parameters", .{ fn_name, param_count }));

            // Validation of props type
            const FirstPropType = FuncInfo.@"fn".params[0].type.?;

            if (FirstPropType != std.mem.Allocator)
                @compileError("Component" ++ fn_name ++ " must have allocator as the first parameter");

            // If two parameters are passed, the props type must be a struct
            if (param_count == 2) {
                const SecondPropType = FuncInfo.@"fn".params[1].type.?;

                if (@typeInfo(SecondPropType) != .@"struct")
                    @compileError("Component" ++ fn_name ++ "must have a struct as the second parameter, found " ++ @typeName(SecondPropType));
            }

            // Allocate props on heap to persist
            const props_copy = if (param_count == 2) blk: {
                const SecondPropType = FuncInfo.@"fn".params[1].type.?;
                const coerced = coerceProps(SecondPropType, props);
                const p = allocator.create(SecondPropType) catch @panic("OOM");
                p.* = coerced;
                break :blk p;
            } else null;

            const Wrapper = struct {
                fn call(propsPtr: ?*const anyopaque, alloc: Allocator) Component {
                    // Check function signature and call appropriately
                    if (param_count == 1) {
                        return func(alloc);
                    }
                    if (param_count == 2) {
                        const SecondPropType = FuncInfo.@"fn".params[1].type.?;
                        const p = propsPtr orelse @panic("propsPtr is null for function with props");
                        const typed_p: *const SecondPropType = @ptrCast(@alignCast(p));
                        return func(alloc, typed_p.*);
                    }
                    unreachable;
                }

                fn deinit(propsPtr: ?*const anyopaque, alloc: Allocator) void {
                    if (param_count == 2) {
                        const SecondPropType = FuncInfo.@"fn".params[1].type.?;
                        const p = propsPtr orelse @panic("propsPtr is null for function with props");
                        const typed_p: *const SecondPropType = @ptrCast(@alignCast(p));
                        alloc.destroy(typed_p);
                    }
                    // If param_count == 1, propsPtr is null, so nothing to destroy
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
            .component_csr => |component_csr| {
                // Free allocated strings
                allocator.free(component_csr.name);
                allocator.free(component_csr.path);
                allocator.free(component_csr.id);
                if (component_csr.props_json) |props_json| {
                    allocator.free(props_json);
                }
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
            .component_csr => |component_csr| {
                try writer.print("<{s} id=\"{s}\"", .{ "div", component_csr.id });
                if (component_csr.props_json) |props_json| {
                    try writer.print(" data-name=\"{s}\" data-props=\"", .{component_csr.name});
                    // Escape JSON for HTML attribute
                    try escapeAttributeValueToWriter(writer, props_json);
                    try writer.print("\"", .{});
                }
                try writer.print(">", .{});
                try writer.print("</{s}>", .{"div"});
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
                            try writer.writeAll("=\"");
                            if (attribute.format) |_| {
                                // Format field is present - value is already formatted, skip HTML escaping
                                try writer.writeAll(value);
                            } else {
                                // HTML escape attribute values to prevent XSS
                                // Escape quotes, ampersands, and other HTML special characters
                                try escapeAttributeValueToWriter(writer, value);
                            }
                            try writer.writeAll("\"");
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

    /// Recursively search for an element by tag name
    /// Returns a mutable pointer to the Component if found, null otherwise
    /// Note: Resolves component_fn lazily during search
    /// Note: Requires allocator to make children mutable if needed
    pub fn getElementByName(self: *Component, allocator: std.mem.Allocator, tag: ElementTag) ?*Component {
        switch (self.*) {
            .element => |*elem| {
                if (elem.tag == tag) {
                    return self;
                }
                // Search in children - need to make children mutable first if they're const
                if (elem.children) |children| {
                    // Allocate mutable copy of children for searching
                    const mutable_children = allocator.alloc(Component, children.len) catch return null;
                    @memcpy(mutable_children, children);
                    elem.children = mutable_children;

                    for (0..mutable_children.len) |i| {
                        var child_mut = &mutable_children[i];
                        if (child_mut.getElementByName(allocator, tag)) |found| {
                            return found;
                        }
                    }
                }
                return null;
            },
            .component_fn => |*func| {
                // Resolve the component function and replace self with the result
                const resolved = func.call();
                self.* = resolved;
                // Now search the resolved component
                return self.getElementByName(allocator, tag);
            },
            .text, .component_csr => return null,
        }
    }

    /// Append a child component to an element
    /// Only works if this Component is an element variant
    /// Note: Allocates a new array since children may be const
    pub fn appendChild(self: *Component, allocator: std.mem.Allocator, child: Component) !void {
        switch (self.*) {
            .element => |*elem| {
                if (elem.children) |existing_children| {
                    // Allocate new array and copy existing children + new child
                    const new_children = try allocator.alloc(Component, existing_children.len + 1);
                    @memcpy(new_children[0..existing_children.len], existing_children);
                    new_children[existing_children.len] = child;
                    elem.children = new_children;
                } else {
                    // Allocate new array
                    const new_children = try allocator.alloc(Component, 1);
                    new_children[0] = child;
                    elem.children = new_children;
                }
            },
            else => return error.NotAnElement,
        }
    }
};

pub const Element = struct {
    pub const Attribute = struct {
        name: []const u8,
        value: ?[]const u8 = null,
        format: ?[]const u8 = null, // Format specifier for value (e.g., "{s}", "{d}")
    };

    tag: ElementTag,
    children: ?[]const Component = null,
    attributes: ?[]const Attribute = null,
};

const ZxOptions = struct {
    children: ?[]const Component = null,
    attributes: ?[]const Element.Attribute = null,
    allocator: ?std.mem.Allocator = null,
};

pub fn zx(tag: ElementTag, options: ZxOptions) Component {
    std.debug.print("zx: Tag: {s}, allocator: {any}\n", .{ @tagName(tag), options.allocator });
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
    allocator: ?std.mem.Allocator = null,

    pub fn getAllocator(self: *ZxContext) std.mem.Allocator {
        return self.allocator orelse @panic("Allocator not set. Please provide @allocator attribute to the parent element.");
    }

    fn escapeHtml(self: *ZxContext, text: []const u8) []const u8 {
        const allocator = self.getAllocator();
        // Use a buffer writer to leverage the shared escaping logic
        var aw = std.io.Writer.Allocating.init(allocator);
        escapeAttributeValueToWriter(&aw.writer, text) catch @panic("OOM");
        return aw.written();
    }

    pub fn zx(self: *ZxContext, tag: ElementTag, options: ZxOptions) Component {
        // Set allocator from @allocator option if provided
        if (options.allocator) |allocator| {
            self.allocator = allocator;
        }

        const allocator = self.getAllocator();

        // Allocate and copy children if provided
        const children_copy = if (options.children) |children| blk: {
            const copy = allocator.alloc(Component, children.len) catch @panic("OOM");
            @memcpy(copy, children);
            break :blk copy;
        } else null;

        // Allocate and copy attributes if provided
        const attributes_copy = if (options.attributes) |attributes| blk: {
            const copy = allocator.alloc(Element.Attribute, attributes.len) catch @panic("OOM");
            @memcpy(copy, attributes);
            break :blk copy;
        } else null;

        return .{ .element = .{
            .tag = tag,
            .children = children_copy,
            .attributes = attributes_copy,
        } };
    }

    pub fn txt(self: *ZxContext, text: []const u8) Component {
        const escaped = self.escapeHtml(text);
        return .{ .text = escaped };
    }

    pub fn fmt(self: *ZxContext, comptime format: []const u8, args: anytype) Component {
        const allocator = self.getAllocator();
        const text = std.fmt.allocPrint(allocator, format, args) catch @panic("OOM");
        return .{ .text = text };
    }

    pub fn print(self: *ZxContext, comptime format: []const u8, args: anytype) []const u8 {
        const allocator = self.getAllocator();
        const text = std.fmt.allocPrint(allocator, format, args) catch @panic("OOM");
        return text;
    }

    pub fn lazy(self: *ZxContext, comptime func: anytype, props: anytype) Component {
        const allocator = self.getAllocator();
        const FuncInfo = @typeInfo(@TypeOf(func));
        const param_count = FuncInfo.@"fn".params.len;

        // If function has props parameter, coerce props to the expected type
        if (param_count == 2) {
            const PropsType = FuncInfo.@"fn".params[1].type.?;
            const coerced_props = coerceProps(PropsType, props);
            return .{ .component_fn = Component.ComponentFn.init(func, allocator, coerced_props) };
        } else {
            return .{ .component_fn = Component.ComponentFn.init(func, allocator, props) };
        }
    }

    pub fn client(self: *ZxContext, options: ClientComponentOptions, props: anytype) Component {
        const allocator = self.getAllocator();

        const name_copy = allocator.alloc(u8, options.name.len) catch @panic("OOM");
        @memcpy(name_copy, options.name);
        const path_copy = allocator.alloc(u8, options.path.len) catch @panic("OOM");
        @memcpy(path_copy, options.path);
        const id_copy = allocator.alloc(u8, options.id.len) catch @panic("OOM");
        @memcpy(id_copy, options.id);

        const props_json = std.json.Stringify.valueAlloc(allocator, props, .{}) catch @panic("OOM");

        return .{ .component_csr = .{
            .name = name_copy,
            .path = path_copy,
            .id = id_copy,
            .props_json = props_json,
        } };
    }
};

const ClientComponentOptions = struct {
    name: []const u8,
    path: []const u8,
    id: []const u8,
};
/// Initialize a ZxContext without an allocator
/// The allocator must be provided via @allocator attribute on the parent element
pub fn init() ZxContext {
    return .{ .allocator = null };
}

/// Initialize a ZxContext with an allocator (for backward compatibility with direct API usage)
pub fn initWithAllocator(allocator: std.mem.Allocator) ZxContext {
    return .{ .allocator = allocator };
}

const routing = @import("routing.zig");

pub const App = @import("app.zig").App;
pub const PageContext = routing.PageContext;
pub const LayoutContext = routing.LayoutContext;
pub const info = @import("zx_info");
