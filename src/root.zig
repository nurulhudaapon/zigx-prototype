//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const Ast = @import("zigx/Ast.zig");

pub const ElementTag = enum { img, html, base, head, link, meta, script, style, title, address, article, body, h1, h6, footer, header, h2, h3, h4, h5, hgroup, nav, section, dd, dl, dt, div, figcaption, figure, hr, li, ol, ul, menu, main, p, pre, a, abbr, b, bdi, bdo, br, cite, code, data, time, dfn, em, i, kbd, mark, q, blockquote, rp, ruby, rt, rtc, rb, s, del, ins, samp, small, span, strong, sub, sup, u, @"var", wbr, area, map, audio, source, track, video, embed, object, param, canvas, noscript, caption, table, col, colgroup, tbody, tr, thead, tfoot, td, th, button, datalist, option, fieldset, label, form, input, keygen, legend, meter, optgroup, select, output, progress, textarea, details, dialog, menuitem, summary, content, element, shadow, template, acronym, applet, basefont, font, big, blink, center, command, dir, frame, frameset, isindex, listing, marquee, noembed, plaintext, spacer, strike, tt, xmp };
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
};

pub const Element = struct {
    tag: ElementTag,
    children: ?[]const Component = null,
    attributes: ?[]const Attribute = null,

    pub fn render(self: @This(), writer: anytype) !void {
        try writer.print("<{s}", .{@tagName(self.tag)});
        const is_self_closing = isSelfClosing(self.tag);
        const is_no_closing = isNoClosing(self.tag);

        if (self.attributes) |attributes| {
            for (attributes) |attribute| {
                try writer.print(" {s}", .{attribute.name});
                if (attribute.value) |value| {
                    try writer.print("=\"{s}\"", .{value});
                }
            }
        }
        if (!is_self_closing or is_no_closing) {
            try writer.print(">", .{});
        } else {
            try writer.print(" />", .{});
        }

        if (self.children) |children| {
            for (children) |child| {
                switch (child) {
                    .text => |text| {
                        try writer.print("{s}", .{text});
                    },
                    .element => |element| {
                        try element.render(writer);
                    },
                }
            }
        }
        if (!is_self_closing and !is_no_closing) {
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
