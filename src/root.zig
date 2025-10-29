//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const Ast = @import("zigx/Ast.zig");
pub const Allocator = std.mem.Allocator;

pub const ElementTag = enum { svg, path, img, html, base, head, link, meta, script, style, title, address, article, body, h1, h6, footer, header, h2, h3, h4, h5, hgroup, nav, section, dd, dl, dt, div, figcaption, figure, hr, li, ol, ul, menu, main, p, pre, a, abbr, b, bdi, bdo, br, cite, code, data, time, dfn, em, i, kbd, mark, q, blockquote, rp, ruby, rt, rtc, rb, s, del, ins, samp, small, span, strong, sub, sup, u, @"var", wbr, area, map, audio, source, track, video, embed, object, param, canvas, noscript, caption, table, col, colgroup, tbody, tr, thead, tfoot, td, th, button, datalist, option, fieldset, label, form, input, keygen, legend, meter, optgroup, select, output, progress, textarea, details, dialog, menuitem, summary, content, element, shadow, template, acronym, applet, basefont, font, big, blink, center, command, dir, frame, frameset, isindex, listing, marquee, noembed, plaintext, spacer, strike, tt, xmp };
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
        }
    }
};

pub const WhitespaceMode = enum {
    none,
    indent_1,
    indent_2,
    indent_3,
    indent_4,
};

pub const RenderOptions = struct {
    whitespace: WhitespaceMode = .none,
    current_depth: usize = 0,
    max_width: ?usize = null,

    fn getIndent(self: @This()) []const u8 {
        const spaces_per_level: usize = switch (self.whitespace) {
            .none => return "",
            .indent_1 => 1,
            .indent_2 => 2,
            .indent_3 => 3,
            .indent_4 => 4,
        };
        const total_spaces = spaces_per_level * self.current_depth;
        const indent_buffer = " " ** 100;
        return if (total_spaces <= 100) indent_buffer[0..total_spaces] else indent_buffer[0..100];
    }

    fn shouldIndent(self: @This()) bool {
        return self.whitespace != .none;
    }

    fn getIndentWidth(self: @This()) usize {
        const spaces_per_level: usize = switch (self.whitespace) {
            .none => 0,
            .indent_1 => 1,
            .indent_2 => 2,
            .indent_3 => 3,
            .indent_4 => 4,
        };
        return spaces_per_level * self.current_depth;
    }
};

pub const Element = struct {
    tag: ElementTag,
    children: ?[]const Component = null,
    attributes: ?[]const Attribute = null,

    pub fn render(self: @This(), writer: anytype, options: RenderOptions) !void {
        const indent = options.getIndent();
        const should_indent = options.shouldIndent();
        const indent_width = options.getIndentWidth();

        if (should_indent and options.current_depth > 0) {
            try writer.print("{s}", .{indent});
        }

        var current_line_width = indent_width;

        // Opening tag
        const tag_name = @tagName(self.tag);
        try writer.print("<{s}", .{tag_name});
        current_line_width += 1 + tag_name.len; // < + tag_name

        const is_self_closing = isSelfClosing(self.tag);
        const is_no_closing = isNoClosing(self.tag);

        // Handle attributes with width checking
        if (self.attributes) |attributes| {
            for (attributes, 0..) |attribute, i| {
                const attr_len = attribute.name.len + 1; // space + name
                const value_len = if (attribute.value) |v| 3 + v.len else 0; // ="value"
                const total_attr_len = attr_len + value_len;

                // Check if we need to break the line
                if (options.max_width) |max_w| {
                    if (i > 0 and current_line_width + total_attr_len > max_w) {
                        try writer.print("\n{s}", .{indent});
                        current_line_width = indent_width;
                    }
                }

                try writer.print(" {s}", .{attribute.name});
                current_line_width += attr_len;

                if (attribute.value) |value| {
                    try writer.print("=\"{s}\"", .{value});
                    current_line_width += value_len;
                }
            }
        }

        // Closing bracket
        if (!is_self_closing or is_no_closing) {
            try writer.print(">", .{});
            current_line_width += 1;
        } else {
            try writer.print(" />", .{});
            current_line_width += 3;
        }

        // Check if we should break after opening tag
        if (options.max_width) |max_w| {
            if (should_indent and self.children != null) {
                try writer.print("\n", .{});
            } else if (self.children != null and current_line_width > max_w * 7 / 10) {
                // If we're at 70% of max width and have children, break
                if (should_indent) {
                    try writer.print("\n", .{});
                }
            }
        } else {
            if (should_indent and self.children != null) {
                try writer.print("\n", .{});
            }
        }

        if (self.children) |children| {
            const child_options = RenderOptions{
                .whitespace = options.whitespace,
                .current_depth = options.current_depth + 1,
                .max_width = options.max_width,
            };

            for (children) |child| {
                switch (child) {
                    .text => |text| {
                        if (should_indent) {
                            const child_indent = child_options.getIndent();

                            // Handle text wrapping if max_width is set
                            if (options.max_width) |max_w| {
                                const child_indent_width = child_options.getIndentWidth();
                                var remaining = text;
                                var first_line = true;

                                while (remaining.len > 0) {
                                    const available_width = if (max_w > child_indent_width)
                                        max_w - child_indent_width
                                    else
                                        max_w;

                                    if (remaining.len <= available_width) {
                                        if (!first_line) {
                                            try writer.print("{s}", .{child_indent});
                                        } else {
                                            try writer.print("{s}", .{child_indent});
                                        }
                                        try writer.print("{s}\n", .{remaining});
                                        break;
                                    } else {
                                        // Find a good break point (space or just break at width)
                                        var break_at = available_width;
                                        if (break_at < remaining.len) {
                                            // Try to find last space before break point
                                            var found_space = false;
                                            var j = break_at;
                                            while (j > available_width / 2 and j > 0) : (j -= 1) {
                                                if (remaining[j] == ' ') {
                                                    break_at = j;
                                                    found_space = true;
                                                    break;
                                                }
                                            }
                                            if (!found_space) {
                                                break_at = available_width;
                                            }
                                        }

                                        if (!first_line) {
                                            try writer.print("{s}", .{child_indent});
                                        } else {
                                            try writer.print("{s}", .{child_indent});
                                        }

                                        try writer.print("{s}\n", .{remaining[0..break_at]});
                                        remaining = if (break_at < remaining.len and remaining[break_at] == ' ')
                                            remaining[break_at + 1 ..]
                                        else
                                            remaining[break_at..];
                                        first_line = false;
                                    }
                                }
                            } else {
                                try writer.print("{s}{s}", .{ child_indent, text });
                                try writer.print("\n", .{});
                            }
                        } else {
                            try writer.print("{s}", .{text});
                        }
                    },
                    .element => |element| {
                        try element.render(writer, child_options);
                        if (should_indent) {
                            try writer.print("\n", .{});
                        }
                    },
                }
            }
        }

        if (!is_self_closing and !is_no_closing) {
            if (should_indent and self.children != null) {
                try writer.print("{s}", .{indent});
            }
            try writer.print("</{s}>", .{@tagName(self.tag)});
        }
    }
};

pub const ZxOptions = struct {
    children: ?[]const Component = null,
    attributes: ?[]const Attribute = null,
};

pub const Attribute = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

pub fn zx(tag: ElementTag, options: ZxOptions) Component {
    return .{ .element = .{
        .tag = tag,
        .children = options.children,
        .attributes = options.attributes,
    } };
}

/// Context for creating components with allocator support
pub const ZxContext = struct {
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
            const copy = self.allocator.alloc(Attribute, attributes.len) catch @panic("OOM");
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
};

/// Initialize a ZxContext with an allocator
pub fn init(allocator: std.mem.Allocator) ZxContext {
    return .{ .allocator = allocator };
}
