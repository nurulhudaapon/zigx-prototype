const Ast = @This();

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
// const tracy = @import("tracy");
const root = @import("html.zig");
const Language = root.Language;
const Span = root.Span;
const Tokenizer = @import("Tokenizer.zig");
const Element = @import("Element.zig");
// const elements = Element.all;
const kinds = Element.elements;
const expr = @import("../expr.zig");

const log = std.log.scoped(.@"html/ast");
const fmtlog = std.log.scoped(.@"html/ast/fmt");
const cpllog = std.log.scoped(.@"html/ast/completions");

has_syntax_errors: bool,
language: Language,
nodes: []const Node,
errors: []const Error,

pub const Kind = enum {
    // zig fmt: off
    // Basic nodes
    root, doctype, comment, text,

    // Expressions
    switch_expr, if_expr, for_expr, while_expr, text_expr,

    // superhtml
    extend, super, ctx,
    
    ___, // invalid or web component (or superhtml if not in shtml mode)
    
    // Begin of html tags
    a, abbr, address, area, article, aside, audio, b, base, bdi, bdo,
    blockquote, body, br, button, canvas, caption, cite, code, col, colgroup,
    data, datalist, dd, del, details, dfn, dialog, div, dl, dt, em, embed,
    fencedframe, fieldset, figcaption, figure, footer, form, h1, h2, h3, h4, h5,
    h6, head, header, hgroup, hr, html, i, iframe, img, input, ins, kbd, label,
    legend, li, link, main, map, math, mark, menu, meta, meter, nav, noscript,
    object, ol, optgroup, option, output, p, picture, pre, progress, q, rp,
    rt, ruby, s, samp, script, search, section, select, selectedcontent, slot,
    small, source, span, strong, style, sub, summary, sup, svg,  table, tbody,
    td, template, textarea, tfoot, th, thead, time, title, tr, track, u, ul,
    @"var", video, wbr,
    // zig fmt: on

    pub fn isElement(k: Kind) bool {
        return @intFromEnum(k) > @intFromEnum(Kind.text);
    }

    pub fn isVoid(k: Kind) bool {
        return switch (k) {
            .root,
            .doctype,
            .comment,
            .text,
            => unreachable,
            // shtml
            .extend,
            .super,
            // html
            .area,
            .base,
            .br,
            .col,
            .embed,
            .hr,
            .img,
            .input,
            .link,
            .meta,
            .source,
            .track,
            .wbr,
            => true,
            else => false,
        };
    }
};

pub const Set = std.StaticStringMapWithEql(
    void,
    std.static_string_map.eqlAsciiIgnoreCase,
);

pub const rcdata_names = Set.initComptime(.{
    .{ "title", {} },
    .{ "textarea", {} },
});

pub const rawtext_names = Set.initComptime(.{
    .{ "style", {} },
    .{ "xmp", {} },
    .{ "iframe", {} },
    .{ "noembed", {} },
    .{ "noframes", {} },
    .{ "noscript", {} },
});

pub const unsupported_names = Set.initComptime(.{
    .{ "applet", {} },
    .{ "acronym", {} },
    .{ "bgsound", {} },
    .{ "dir", {} },
    .{ "frame", {} },
    .{ "frameset", {} },
    .{ "noframes", {} },
    .{ "isindex", {} },
    .{ "keygen", {} },
    .{ "listing", {} },
    .{ "menuitem", {} },
    .{ "nextid", {} },
    .{ "noembed", {} },
    .{ "param", {} },
    .{ "plaintext", {} },
    .{ "rb", {} },
    .{ "rtc", {} },
    .{ "strike", {} },
    .{ "xmp", {} },
    .{ "basefont", {} },
    .{ "big", {} },
    .{ "blink", {} },
    .{ "center", {} },
    .{ "font", {} },
    .{ "marquee", {} },
    .{ "multicol", {} },
    .{ "nobr", {} },
    .{ "spacer", {} },
    .{ "tt", {} },
});

pub const Node = struct {
    /// Span covering start_tag, diamond brackets included
    open: Span,
    /// Span covering end_tag, diamond brackets included
    /// Unset status is represented by .start = 0
    /// not set for doctype, element_void and element_self_closing
    close: Span = .{ .start = 0, .end = 0 },

    parent_idx: u32 = 0,
    first_child_idx: u32 = 0,
    next_idx: u32 = 0,

    kind: Kind,
    self_closing: bool,
    model: Element.Model,

    pub fn isClosed(n: Node) bool {
        return switch (n.kind) {
            .root => unreachable,
            .doctype, .text, .comment, .switch_expr, .if_expr, .for_expr, .while_expr, .text_expr => true,
            else => if (n.kind.isVoid() or n.self_closing) true else n.close.start > 0,
        };
    }

    pub const Direction = enum { in, after };
    pub fn direction(n: Node) Direction {
        switch (n.kind) {
            .root => {
                std.debug.assert(n.first_child_idx == 0);
                return .in;
            },
            .doctype, .text, .comment, .switch_expr, .if_expr, .for_expr, .while_expr, .text_expr => return .after,
            else => {
                if (n.kind.isVoid() or n.self_closing) return .after;
                if (n.close.start == 0) {
                    return .in;
                }
                return .after;
            },
        }
    }

    pub const TagIterator = struct {
        end: u32,
        name_span: Span,
        tokenizer: Tokenizer,

        pub fn next(ti: *TagIterator, src: []const u8) ?Tokenizer.Attr {
            while (ti.tokenizer.next(src[0..ti.end])) |maybe_attr| switch (maybe_attr) {
                .attr => |attr| return attr,
                else => {},
            } else return null;
        }
    };

    pub fn startTagIterator(n: Node, src: []const u8, language: Language) TagIterator {
        // const zone = tracy.trace(@src());
        // defer zone.end();

        var t: Tokenizer = .{
            .language = language,
            .idx = n.open.start,
            .return_attrs = true,
        };
        // TODO: depending on how we deal with errors with might
        //       need more sophisticated logic here than a yolo
        //       union access.
        const name = t.next(src[0..n.open.end]).?.tag_name;
        return .{
            .end = n.open.end,
            .tokenizer = t,
            .name_span = name,
        };
    }

    pub fn span(n: Node, src: []const u8) Span {
        if (n.kind.isElement()) {
            return n.startTagIterator(src, .html).name_span;
        }

        return n.open;
    }

    /// Calulates the stop index when iterating all descendants of a node
    /// it either equals the index of the next node after this one, or
    /// nodes.len in case there are no other nodes.
    pub fn stop(n: Node, nodes: []const Node) u32 {
        var cur = n;
        const result = while (true) {
            if (cur.next_idx != 0) break cur.next_idx;
            if (cur.parent_idx == 0) break nodes.len;
            cur = nodes[cur.parent_idx];
        };
        assert(result > n.first_child_idx);
        return @intCast(result);
    }

    pub fn debug(n: Node, src: []const u8) void {
        std.debug.print("{s}", .{n.open.slice(src)});
    }
};

pub const Error = struct {
    tag: union(enum) {
        token: Tokenizer.TokenError,
        unsupported_doctype,
        invalid_attr,
        invalid_attr_nesting: struct {
            kind: Kind,
            reason: []const u8 = "",
        },
        invalid_attr_value: struct {
            reason: []const u8 = "",
        },

        /// Only use for static limits
        int_out_of_bounds: struct { min: usize, max: usize },
        missing_attr_value,
        boolean_attr,
        invalid_attr_combination: []const u8, // reason
        duplicate_class: Span, // original
        missing_required_attr: []const u8,
        wrong_position: enum { first, second, first_or_last },
        missing_ancestor: Kind,
        missing_child: Kind,
        duplicate_child: struct {
            span: Span, // original child
            reason: []const u8 = "",
        },
        wrong_sibling_sequence: struct {
            span: ?Span = null, // previous sibling
            reason: []const u8 = "",
        },
        // Contains a span to the tag name of the ancestor that forbids this
        // nesting. Usually the parent, but not always. In the case of
        // elements with a transparent content model, the non-transparent
        // ancestor that forbits the node will be used.
        invalid_nesting: struct {
            span: Span, // parent node that caused this error
            reason: []const u8 = "",
        },
        invalid_html_tag_name,
        html_elements_cant_self_close,
        missing_end_tag,
        erroneous_end_tag,
        void_end_tag,
        duplicate_attribute_name: Span, // original attribute
        duplicate_sibling_attr: Span, // original attribute in another element
        duplicate_id: Span, // original location
        deprecated_and_unsupported,

        const Tag = @This();
        pub fn fmt(tag: Tag, src: []const u8) Tag.Formatter {
            return .{ .tag = tag, .src = src };
        }
        const Formatter = struct {
            tag: Tag,
            src: []const u8,
            pub fn format(tf: Tag.Formatter, w: *std.Io.Writer) !void {
                return switch (tf.tag) {
                    .token => |terr| try w.print("syntax error: {t}", .{terr}),
                    .unsupported_doctype => w.print(
                        "unsupported doctype: superhtml only supports the 'html' doctype",
                        .{},
                    ),
                    .invalid_attr => w.print(
                        "invalid attribute for this element",
                        .{},
                    ),
                    .invalid_attr_nesting => |nest| w.print(
                        "invalid attribute for this element when nested under '{t}' {s}",
                        .{ nest.kind, nest.reason },
                    ),
                    .invalid_attr_value => |iav| {
                        try w.print("invalid value for this attribute", .{});
                        if (iav.reason.len > 0) {
                            try w.print(": {s}", .{iav.reason});
                        }
                    },
                    .int_out_of_bounds => |ioob| {
                        try w.print(
                            "integer value out of bounds (min: {}, max: {})",
                            .{ ioob.min, ioob.max },
                        );
                    },
                    .invalid_attr_combination => |iac| w.print(
                        "invalid attribute combination: {s}",
                        .{iac},
                    ),
                    .missing_required_attr => |attr| w.print(
                        "missing required attribute(s): {s}",
                        .{attr},
                    ),
                    .missing_attr_value => w.print(
                        "missing attribute value",
                        .{},
                    ),
                    .boolean_attr => w.print(
                        "this attribute cannot have a value",
                        .{},
                    ),
                    .duplicate_class => w.print(
                        "duplicate class",
                        .{},
                    ),
                    .wrong_position => |p| w.print(
                        "element in wrong position, should be {s}",
                        .{switch (p) {
                            .first, .second => @tagName(p),
                            .first_or_last => "first or last",
                        }},
                    ),
                    .missing_ancestor => |e| w.print("missing ancestor: <{t}>", .{e}),
                    .missing_child => |e| w.print("missing child: <{t}>", .{e}),
                    .duplicate_child => |dc| {
                        try w.print("duplicate child", .{});
                        if (dc.reason.len > 0) {
                            try w.print(": {s}", .{dc.reason});
                        }
                    },
                    .wrong_sibling_sequence => |dc| {
                        try w.print("wrong sibling sequence", .{});
                        if (dc.reason.len > 0) {
                            try w.print(": {s}", .{dc.reason});
                        }
                    },
                    .invalid_nesting => |in| {
                        try w.print("invalid nesting under <{s}>", .{
                            in.span.slice(tf.src),
                        });
                        if (in.reason.len > 0) {
                            try w.print(": {s}", .{in.reason});
                        }
                    },
                    .invalid_html_tag_name => w.print(
                        "not a valid html element",
                        .{},
                    ),
                    .html_elements_cant_self_close => w.print(
                        "html elements can't self-close",
                        .{},
                    ),
                    .missing_end_tag => w.print("missing end tag", .{}),
                    .erroneous_end_tag => w.print("erroneous end tag", .{}),
                    .void_end_tag => w.print("void elements have no end tag", .{}),
                    .duplicate_attribute_name => w.print("duplicate attribute name", .{}),
                    .duplicate_sibling_attr => w.print(
                        "duplicate attribute name across sibling elements",
                        .{},
                    ),
                    .duplicate_id => w.print(
                        "duplicate id value",
                        .{},
                    ),
                    .deprecated_and_unsupported => w.print("deprecated and unsupported", .{}),
                };
            }
        };
    },
    main_location: Span,
    node_idx: u32, // 0 = missing node
};

pub fn cursor(ast: Ast, idx: u32) Cursor {
    return .{ .ast = ast, .idx = idx, .dir = .in };
}

pub fn printErrors(
    ast: Ast,
    src: []const u8,
    path: ?[]const u8,
    w: *Writer,
) !void {
    for (ast.errors) |err| {
        const range = err.main_location.range(src);
        try w.print("{s}:{}:{}: {f}\n", .{
            path orelse "<stdin>",
            range.start.row,
            range.start.col,
            err.tag.fmt(src),
        });

        try printSourceLine(src, err.main_location, w);
    }
}

fn printSourceLine(src: []const u8, span: Span, w: *Writer) !void {
    // test.html:3:7: invalid attribute for this element
    //         <div foo bar baz>
    //              ^^^

    // If the error starts on a newline (eg `foo="bar\n`), we want to consider
    // it ast part of the previous line.
    var idx = span.start -| 1;
    var spaces_left: u32 = 0;
    const line_start = while (idx > 0) : (idx -= 1) switch (src[idx]) {
        '\n' => break idx + 1,
        ' ', '\t', ('\n' + 1)...'\r' => spaces_left += 1,
        else => spaces_left = 0,
    } else 0;

    idx = span.start;
    var last_non_space = idx -| 1; // if span.start is a newline don't print it
    while (idx < src.len) : (idx += 1) switch (src[idx]) {
        '\n' => break,
        ' ', '\t', ('\n' + 1)...'\r' => {},
        else => last_non_space = idx,
    };

    const line = src[line_start + spaces_left .. last_non_space + 1];
    try w.print("   {s}\n", .{line});
    try w.splatByteAll(' ', span.start - (line_start + spaces_left) + 3);
    try w.splatByteAll('^', @max(1, span.end - span.start));
    try w.print("\n", .{});
}

pub fn deinit(ast: Ast, gpa: Allocator) void {
    gpa.free(ast.nodes);
    gpa.free(ast.errors);
}

pub fn init(
    gpa: Allocator,
    src: []const u8,
    language: Language,
    syntax_only: bool,
) error{OutOfMemory}!Ast {
    log.debug("INIT ---- syntax only: {}", .{syntax_only});
    if (src.len > std.math.maxInt(u32)) @panic("too long");

    var nodes = std.array_list.Managed(Node).init(gpa);
    errdefer nodes.deinit();

    var errors: std.ArrayListUnmanaged(Error) = .empty;
    errdefer errors.deinit(gpa);

    var seen_attrs: std.StringHashMapUnmanaged(Span) = .empty;
    defer seen_attrs.deinit(gpa);

    // It's a stack because of <template> (which can also be nested)
    var seen_ids_stack: std.ArrayList(std.StringHashMapUnmanaged(Span)) = .empty;
    try seen_ids_stack.append(gpa, .empty);
    defer {
        for (seen_ids_stack.items) |*seen_ids| seen_ids.deinit(gpa);
        seen_ids_stack.deinit(gpa);
    }

    var has_syntax_errors = false;

    try nodes.append(.{
        .open = .{
            .start = 0,
            .end = 0,
        },
        .close = .{
            .start = @intCast(src.len),
            .end = @intCast(src.len),
        },
        .parent_idx = 0,
        .first_child_idx = 0,
        .next_idx = 0,

        .kind = .root,
        .model = .{
            .categories = .none,
            .content = .all,
        },
        .self_closing = false,
    });

    var tokenizer: Tokenizer = .{ .language = language };

    var current: *Node = &nodes.items[0];
    var current_idx: u32 = 0;
    var svg_lvl: u32 = 0;
    var math_lvl: u32 = 0;
    while (tokenizer.next(src)) |t| {
        log.debug("cur_idx: {} cur_kind: {s} tok: {any}", .{
            current_idx,
            @tagName(current.kind),
            t,
        });
        switch (t) {
            .tag_name, .attr => unreachable,
            .expression => |expr_token| {
                log.debug("AST: processing expression token: kind={s}, span.start={}, span.end={}", .{
                    @tagName(expr_token.kind),
                    expr_token.span.start,
                    expr_token.span.end,
                });
                const expr_kind: Kind = switch (expr_token.kind) {
                    .switch_expr => .switch_expr,
                    .if_expr => .if_expr,
                    .for_expr => .for_expr,
                    .while_expr => .while_expr,
                    .text_expr => .text_expr,
                };

                var new: Node = .{
                    .kind = expr_kind,
                    .open = expr_token.span,
                    .model = .{
                        .categories = .{
                            .flow = true,
                            .phrasing = true,
                        },
                        .content = .none,
                    },
                    .self_closing = false,
                };

                log.debug("AST: created expression node: kind={s}, open.start={}, open.end={}", .{
                    @tagName(new.kind),
                    new.open.start,
                    new.open.end,
                });

                switch (current.direction()) {
                    .in => {
                        new.parent_idx = current_idx;
                        std.debug.assert(current.first_child_idx == 0);
                        current_idx = @intCast(nodes.items.len);
                        current.first_child_idx = current_idx;
                    },
                    .after => {
                        new.parent_idx = current.parent_idx;
                        current_idx = @intCast(nodes.items.len);
                        current.next_idx = current_idx;
                    },
                }

                try nodes.append(new);
                current = &nodes.items[current_idx];
                continue;
            },
            .doctype => |dt| {
                var new: Node = .{
                    .kind = .doctype,
                    .open = dt.span,
                    .model = .{
                        .categories = .none,
                        .content = .none,
                    },
                    .self_closing = false,
                };

                switch (current.direction()) {
                    .in => {
                        new.parent_idx = current_idx;
                        std.debug.assert(current.first_child_idx == 0);
                        current_idx = @intCast(nodes.items.len);
                        current.first_child_idx = current_idx;
                    },
                    .after => {
                        new.parent_idx = current.parent_idx;
                        current_idx = @intCast(nodes.items.len);
                        current.next_idx = current_idx;
                    },
                }

                try nodes.append(new);
                current = &nodes.items[current_idx];
            },
            .tag => |tag| switch (tag.kind) {
                .start,
                .start_self,
                => {
                    const name = tag.name.slice(src);
                    const self_closing = tag.kind == .start_self;
                    var new: Node = node: switch (tag.kind) {
                        else => unreachable,
                        .start_self => {
                            const is_starting_with_uppercase = std.ascii.isUpper(name[0]);
                            if (svg_lvl != 0 or math_lvl != 0 or language == .xml or is_starting_with_uppercase) {
                                break :node .{
                                    .kind = .___,
                                    .open = tag.span,
                                    .model = .{
                                        .categories = .all,
                                        .content = .all,
                                    },
                                    .self_closing = true,
                                };
                            }
                            try errors.append(gpa, .{
                                .tag = .html_elements_cant_self_close,
                                .main_location = tag.name,
                                .node_idx = current_idx + 1,
                            });
                            continue :node .start;
                        },
                        .start => switch (language) {
                            .superhtml => {
                                const kind: Ast.Kind = if (std.ascii.eqlIgnoreCase("ctx", name))
                                    .ctx
                                else if (std.ascii.eqlIgnoreCase("super", name))
                                    .super
                                else if (std.ascii.eqlIgnoreCase("extend", name))
                                    .extend
                                else
                                    kinds.get(name) orelse .___;

                                break :node .{
                                    .open = tag.span,
                                    .kind = kind,
                                    .model = .{
                                        .categories = .all,
                                        .content = .all,
                                    },
                                    .self_closing = self_closing,
                                };
                            },
                            .html => {
                                if (svg_lvl == 0 and math_lvl == 0) {
                                    if (kinds.get(name)) |kind| {
                                        const model =
                                            undefined;

                                        if (kind == .template) {
                                            try seen_ids_stack.append(gpa, .empty);
                                        }

                                        break :node .{
                                            .open = tag.span,
                                            .kind = kind,
                                            .model = model,
                                            .self_closing = self_closing,
                                        };
                                    } else if (std.mem.indexOfScalar(u8, name, '-') == null and !syntax_only) {
                                        try errors.append(gpa, .{
                                            .tag = .invalid_html_tag_name,
                                            .main_location = tag.name,
                                            .node_idx = @intCast(nodes.items.len),
                                        });
                                    }
                                }

                                break :node .{
                                    .kind = .___,
                                    .open = tag.span,
                                    .model = .{
                                        .categories = .all,
                                        .content = .all,
                                    },
                                    .self_closing = self_closing,
                                };
                            },
                            .xml => break :node .{
                                .kind = .___,
                                .open = tag.span,
                                .model = .{
                                    .categories = .all,
                                    .content = .all,
                                },
                                .self_closing = self_closing,
                            },
                        },
                    };

                    // This comparison is done via strings instead of kinds
                    // because we will not attempt to match the kind of an
                    // svg nested inside another svg, and same for math.
                    if (std.ascii.eqlIgnoreCase("svg", name)) {
                        svg_lvl += 1;
                    }
                    if (std.ascii.eqlIgnoreCase("math", name)) {
                        math_lvl += 1;
                    }

                    switch (current.direction()) {
                        .in => {
                            new.parent_idx = current_idx;
                            std.debug.assert(current.first_child_idx == 0);
                            current_idx = @intCast(nodes.items.len);
                            current.first_child_idx = current_idx;
                        },
                        .after => {
                            new.parent_idx = current.parent_idx;
                            current_idx = @intCast(nodes.items.len);
                            current.next_idx = current_idx;
                        },
                    }

                    try nodes.append(new);
                    current = &nodes.items[current_idx];

                    if (!syntax_only and current.kind == .main) {
                        var ancestor_idx = current.parent_idx;
                        while (ancestor_idx != 0) {
                            const ancestor = nodes.items[ancestor_idx];
                            defer ancestor_idx = ancestor.parent_idx;

                            switch (ancestor.kind) {
                                .html,
                                .body,
                                .div,
                                .___,
                                => {},
                                .form => {
                                    // TODO: check accessible name
                                },
                                else => {
                                    try errors.append(gpa, .{
                                        .tag = .{
                                            .invalid_nesting = .{
                                                .span = ancestor.span(src),
                                                .reason = "main can only nest under html, body, div and form",
                                            },
                                        },
                                        .main_location = tag.name,
                                        .node_idx = current_idx,
                                    });
                                },
                            }
                        }
                    }

                    if (std.ascii.eqlIgnoreCase("script", name)) {
                        tokenizer.gotoScriptData();
                    } else if (rawtext_names.has(name)) {
                        tokenizer.gotoRawText(name);
                    } else if (unsupported_names.has(name)) {
                        try errors.append(gpa, .{
                            .tag = .deprecated_and_unsupported,
                            .main_location = tag.name,
                            .node_idx = current_idx,
                        });
                    }
                },
                .end, .end_self => {
                    if (current.kind == .root) {
                        has_syntax_errors = true;
                        try errors.append(gpa, .{
                            .tag = .erroneous_end_tag,
                            .main_location = tag.name,
                            .node_idx = 0,
                        });
                        continue;
                    }

                    const original_current = current;
                    const original_current_idx = current_idx;

                    if (current.isClosed()) {
                        log.debug("current {} is closed, going up to {}", .{
                            current_idx,
                            current.parent_idx,
                        });
                        current_idx = current.parent_idx;
                        current = &nodes.items[current.parent_idx];
                    }

                    const name = tag.name.slice(src);
                    const end_kind = if (svg_lvl == 1 and std.ascii.eqlIgnoreCase(name, "svg"))
                        .svg
                    else if (math_lvl == 1 and std.ascii.eqlIgnoreCase(name, "math"))
                        .math
                    else if (svg_lvl != 0 or math_lvl != 0) .___ else switch (language) {
                        .superhtml => if (std.ascii.eqlIgnoreCase("ctx", name))
                            .ctx
                        else if (std.ascii.eqlIgnoreCase("super", name))
                            .super
                        else if (std.ascii.eqlIgnoreCase("extend", name))
                            .extend
                        else
                            kinds.get(name) orelse .___,
                        .html => kinds.get(name) orelse .___,
                        .xml => .___,
                    };

                    while (true) {
                        if (current.kind == .root) {
                            current = original_current;
                            current_idx = original_current_idx;

                            const is_void = blk: {
                                const k = Element.elements.get(
                                    tag.name.slice(src),
                                ) orelse break :blk false;
                                assert(k.isElement());
                                break :blk k.isVoid() and
                                    original_current.kind.isElement() and
                                    original_current.kind.isVoid();
                            };

                            has_syntax_errors = true;
                            try errors.append(gpa, .{
                                .tag = if (is_void) .void_end_tag else .erroneous_end_tag,
                                .main_location = tag.name,
                                .node_idx = 0,
                            });
                            break;
                        }

                        assert(!current.isClosed());
                        const current_name = blk: {
                            var temp_tok: Tokenizer = .{
                                .language = language,
                                .return_attrs = true,
                            };
                            const tag_src = current.open.slice(src);
                            // all early exit branches are in the case of
                            // malformed HTML and we also expect in all of
                            // those cases that errors were already emitted
                            // by the tokenizer
                            const name_span = temp_tok.getName(tag_src) orelse {
                                current = original_current;
                                current_idx = original_current_idx;
                                break;
                            };
                            break :blk name_span.slice(tag_src);
                        };

                        const same_name = end_kind == current.kind and
                            (end_kind != .___ or std.ascii.eqlIgnoreCase(
                                current_name,
                                tag.name.slice(src),
                            ));

                        if (same_name) {
                            if (std.ascii.eqlIgnoreCase(current_name, "svg")) {
                                svg_lvl -= 1;
                            }
                            if (std.ascii.eqlIgnoreCase(current_name, "math")) {
                                math_lvl -= 1;
                            }
                            if (current.kind == .template) {
                                var map = seen_ids_stack.pop().?;
                                map.deinit(gpa);
                            }

                            current.close = tag.span;

                            var cur = original_current;
                            while (cur != current) {
                                if (!cur.isClosed()) {
                                    const cur_name: Span = blk: {
                                        var temp_tok: Tokenizer = .{
                                            .language = language,
                                            .return_attrs = true,
                                        };
                                        const tag_src = cur.open.slice(src);
                                        const rel_name = temp_tok.getName(tag_src).?;
                                        break :blk .{
                                            .start = rel_name.start + cur.open.start,
                                            .end = rel_name.end + cur.open.start,
                                        };
                                    };
                                    has_syntax_errors = true;
                                    try errors.append(gpa, .{
                                        .tag = .missing_end_tag,
                                        .main_location = cur_name,
                                        .node_idx = current_idx,
                                    });
                                }

                                cur = &nodes.items[cur.parent_idx];
                            }

                            log.debug("----- closing '{s}' cur: {} par: {}", .{
                                tag.name.slice(src),
                                current_idx,
                                current.parent_idx,
                            });

                            break;
                        }

                        current_idx = current.parent_idx;
                        current = &nodes.items[current.parent_idx];
                    }
                },
            },
            .text => |txt| {
                var new: Node = .{
                    .kind = .text,
                    .open = txt,
                    .model = .{
                        .categories = .{
                            .flow = true,
                            .phrasing = true,
                        },
                        .content = .none,
                    },
                    .self_closing = false,
                };

                switch (current.direction()) {
                    .in => {
                        new.parent_idx = current_idx;
                        if (current.first_child_idx != 0) {
                            debugNodes(nodes.items, src);
                        }
                        std.debug.assert(current.first_child_idx == 0);
                        current_idx = @intCast(nodes.items.len);
                        current.first_child_idx = current_idx;
                    },
                    .after => {
                        new.parent_idx = current.parent_idx;
                        current_idx = @intCast(nodes.items.len);
                        current.next_idx = current_idx;
                    },
                }

                try nodes.append(new);
                current = &nodes.items[current_idx];
            },
            .comment => |c| {
                var new: Node = .{
                    .kind = .comment,
                    .open = c,
                    .model = .{
                        .categories = .all,
                        .content = .none,
                    },
                    .self_closing = false,
                };

                log.debug("comment => current ({any})", .{current.*});

                switch (current.direction()) {
                    .in => {
                        new.parent_idx = current_idx;
                        std.debug.assert(current.first_child_idx == 0);
                        current_idx = @intCast(nodes.items.len);
                        current.first_child_idx = current_idx;
                    },
                    .after => {
                        new.parent_idx = current.parent_idx;
                        current_idx = @intCast(nodes.items.len);
                        current.next_idx = current_idx;
                    },
                }

                try nodes.append(new);
                current = &nodes.items[current_idx];
            },
            .parse_error => |pe| {
                has_syntax_errors = true;
                log.debug("================= parse error: {any} {}", .{ pe, current_idx });

                // TODO: finalize ast when EOF?
                try errors.append(gpa, .{
                    .tag = .{
                        .token = pe.tag,
                    },
                    .main_location = pe.span,
                    .node_idx = switch (current.direction()) {
                        .in => current_idx,
                        .after => current.parent_idx,
                    },
                });
            },
        }
    }

    // finalize tree
    while (current.kind != .root) {
        if (!current.isClosed()) {
            has_syntax_errors = true;
            try errors.append(gpa, .{
                .tag = .missing_end_tag,
                .main_location = current.open,
                .node_idx = current_idx,
            });
        }

        current_idx = current.parent_idx;
        current = &nodes.items[current.parent_idx];
    }

    return .{
        .has_syntax_errors = has_syntax_errors,
        .language = language,
        .nodes = try nodes.toOwnedSlice(),
        .errors = try errors.toOwnedSlice(gpa),
    };
}

/// Normalize whitespace by converting tabs to spaces
fn normalizeWhitespace(ws: []const u8, w: *Writer) !void {
    for (ws) |c| {
        if (c == '\t') {
            // Convert tab to 4 spaces
            for (0..4) |_| try w.writeAll(" ");
        } else {
            // Preserve spaces, newlines, etc.
            try w.writeAll(&.{c});
        }
    }
}

/// Render text content with expression formatting
fn renderTextWithExpressions(
    arena: std.mem.Allocator,
    text: []const u8,
    indentation: u32,
    w: *Writer,
) !void {
    // Parse expressions from text
    const expressions = expr.parse(arena, text) catch {
        // If parsing fails, just write the text as-is
        try w.writeAll(text);
        return;
    };
    defer {
        for (expressions) |expr_ast| {
            if (expr_ast.kind == .switch_expr) {
                arena.free(expr_ast.kind.switch_expr.cases);
            }
        }
        arena.free(expressions);
    }

    if (expressions.len == 0) {
        // No expressions, just write the text
        try w.writeAll(text);
        return;
    }

    // Render text with expressions formatted
    var last_pos: usize = 0;
    for (expressions) |expr_ast| {
        // Write everything before this expression
        if (expr_ast.start > last_pos) {
            const before = text[last_pos..expr_ast.start];
            // Normalize whitespace: convert tabs to spaces while preserving indentation level
            // If the before text is all whitespace, normalize it
            const trimmed = std.mem.trim(u8, before, &std.ascii.whitespace);
            if (trimmed.len == 0) {
                // All whitespace - normalize tabs to spaces
                try normalizeWhitespace(before, w);
            } else {
                // Has non-whitespace content, write as-is
                try w.writeAll(before);
            }
        }

        // Render the expression with proper indentation
        try renderExpression(expr_ast, indentation, arena, w);

        last_pos = expr_ast.end;
    }

    // Write remaining content
    if (last_pos < text.len) {
        try w.writeAll(text[last_pos..]);
    }
}

/// Render an expression with proper indentation using tabs
fn renderExpression(expr_ast: expr.ExpressionAst, base_indent: u32, arena: Allocator, w: *Writer) !void {
    fmtlog.debug("renderExpression: kind={s}, start={}, end={}, source_len={}", .{
        @tagName(expr_ast.kind),
        expr_ast.start,
        expr_ast.end,
        expr_ast.source.len,
    });
    switch (expr_ast.kind) {
        .switch_expr => |switch_expr| {
            fmtlog.debug("rendering switch_expr, condition.end={}", .{switch_expr.condition.end});
            // Find the opening brace after condition
            var i = switch_expr.condition.end;
            while (i < expr_ast.source.len and expr_ast.source[i] != '{') {
                i += 1;
            }
            const brace_start = i;
            fmtlog.debug("found brace_start at {}", .{brace_start});

            // Write opening: {switch (...) {
            const opening_text = expr_ast.source[expr_ast.start .. brace_start + 1];
            fmtlog.debug("writing opening: '{s}'", .{if (opening_text.len > 50) opening_text[0..50] else opening_text});
            try w.writeAll(opening_text);
            try w.writeAll("\n");

            // Render each case
            for (switch_expr.cases) |case| {
                const case_pattern_raw = case.pattern.slice(expr_ast.source);
                // Trim leading/trailing whitespace from pattern
                const case_pattern = std.mem.trim(u8, case_pattern_raw, &std.ascii.whitespace);
                const case_value_span = case.value;
                const case_value_full = case_value_span.slice(expr_ast.source);

                // Check if value is wrapped in parentheses
                const is_paren_wrapped = case_value_full.len >= 2 and
                    case_value_full[0] == '(' and
                    case_value_full[case_value_full.len - 1] == ')';

                const case_content = if (is_paren_wrapped)
                    case_value_full[1 .. case_value_full.len - 1]
                else
                    case_value_full;

                const is_multiline = std.mem.count(u8, case_content, "\n") > 0;

                // Indent case pattern - cases are one level deeper than the switch
                // base_indent is the indentation of the switch expression itself
                for (0..(base_indent + 1) * 4) |_| try w.writeAll(" ");
                try w.writeAll(case_pattern);
                try w.writeAll(" => ");

                if (is_multiline) {
                    // Multiline case: pattern => (\n content \n),
                    // try w.writeAll("(\n");
                    // The content should be indented one more level than the case
                    // base_indent + 1 is for the case itself, so content should be base_indent + 2
                    try renderMultilineContent(case_content, base_indent + 2, arena, w);
                    for (0..(base_indent + 1) * 4) |_| try w.writeAll(" ");
                    try w.writeAll("),\n");
                } else {
                    // Single line case: pattern => value,
                    try w.writeAll(case_value_full);
                    try w.writeAll(",\n");
                }
            }

            // Closing brace
            for (0..base_indent * 4) |_| try w.writeAll(" ");
            try w.writeAll("}}");
        },
        .if_expr => |if_expr| {
            // Write: {if (...) (
            const before_then = expr_ast.source[expr_ast.start..if_expr.then_branch.start];
            // Normalize before_then: remove leading and trailing whitespace
            // The indentation is handled by the text before the expression, so we just write the normalized content
            const trimmed_before = std.mem.trim(u8, before_then, &std.ascii.whitespace);
            try w.writeAll(trimmed_before);

            // Render then branch
            const then_content = if_expr.then_branch.slice(expr_ast.source);
            const is_multiline_then = std.mem.count(u8, then_content, "\n") > 0;
            if (is_multiline_then) {
                // Check if content starts with whitespace/newlines - if so, we already have the newline
                const starts_with_newline = then_content.len > 0 and then_content[0] == '\n';
                if (!starts_with_newline) {
                    try w.writeAll("\n");
                }
                fmtlog.debug("renderMultilineContent: base_indent={}, then_content len={}", .{ base_indent + 1, then_content.len });
                try renderMultilineContent(then_content, base_indent + 1, arena, w);
            } else {
                try w.writeAll(" ");
                try w.writeAll(std.mem.trim(u8, then_content, &std.ascii.whitespace));
            }

            // Closing paren for then
            for (0..base_indent * 4) |_| try w.writeAll(" ");
            try w.writeAll(")");

            // Else branch if present
            if (if_expr.else_branch) |else_branch| {
                try w.writeAll(" else (");

                const else_content = else_branch.slice(expr_ast.source);
                const is_multiline_else = std.mem.count(u8, else_content, "\n") > 0;
                if (is_multiline_else) {
                    // Check if content starts with whitespace/newlines - if so, we already have the newline
                    const starts_with_newline = else_content.len > 0 and else_content[0] == '\n';
                    if (!starts_with_newline) {
                        try w.writeAll("\n");
                    }
                    try renderMultilineContent(else_content, base_indent + 1, arena, w);
                } else {
                    try w.writeAll(" ");
                    try w.writeAll(std.mem.trim(u8, else_content, &std.ascii.whitespace));
                }

                for (0..base_indent * 4) |_| try w.writeAll(" ");
                try w.writeAll(")");
            }

            try w.writeAll("}");
        },
        .for_expr => |for_expr| {
            // Write: {for (...) |...| (
            const before_body = expr_ast.source[expr_ast.start..for_expr.body.start];
            try w.writeAll(before_body);
            const body_content = for_expr.body.slice(expr_ast.source);
            const is_multiline = std.mem.count(u8, body_content, "\n") > 0;

            if (is_multiline) {
                // try w.writeAll("\n");
                try renderMultilineContent(body_content, base_indent + 1, arena, w);
                for (0..base_indent * 4) |_| try w.writeAll(" ");
                // try w.writeAll(")");
            } else {
                try w.writeAll(body_content);
            }

            // Closing }
            const after_body = expr_ast.source[for_expr.body.end..expr_ast.end];
            try w.writeAll(after_body);
        },
        .while_expr => |while_expr| {
            // Write: {while (...) (
            const before_body = expr_ast.source[expr_ast.start..while_expr.body.start];
            try w.writeAll(before_body);
            try w.writeAll("\n");

            const body_content = while_expr.body.slice(expr_ast.source);
            const is_multiline = std.mem.count(u8, body_content, "\n") > 0;
            if (is_multiline) {
                try renderMultilineContent(body_content, base_indent + 1, arena, w);
            } else {
                for (0..(base_indent + 1) * 4) |_| try w.writeAll(" ");
                try w.writeAll(body_content);
            }

            // Closing ) }
            for (0..base_indent * 4) |_| try w.writeAll(" ");
            const after_body = expr_ast.source[while_expr.body.end..expr_ast.end];
            try w.writeAll(after_body);
        },
        .text_expr => {
            // Regular expression, just write as-is
            try w.writeAll(expr_ast.source[expr_ast.start..expr_ast.end]);
        },
    }
}

/// Render multiline content with proper indentation, normalizing to base_indent level
/// Normalizes consecutive blank lines to at most one blank line
/// If content contains HTML elements, renders them using the HTML AST renderer
fn renderMultilineContent(content: []const u8, base_indent: u32, arena: Allocator, w: *Writer) !void {
    if (content.len == 0) return;

    fmtlog.debug("renderMultilineContent called: base_indent={}, will write {} spaces", .{ base_indent, base_indent * 4 });

    // Check if content contains HTML tags
    const has_html_tags = blk: {
        var i: usize = 0;
        while (i < content.len) {
            if (content[i] == '<') {
                i += 1;
                // Skip whitespace after <
                while (i < content.len and std.ascii.isWhitespace(content[i])) i += 1;
                if (i < content.len) {
                    const c = content[i];
                    // Check if it's a tag name character (letter, /, or !)
                    if (std.ascii.isAlphabetic(c) or c == '/' or c == '!') {
                        break :blk true;
                    }
                }
            }
            i += 1;
        }
        break :blk false;
    };

    if (has_html_tags) {
        // Content contains HTML - parse and render using HTML AST renderer
        // Create a temporary wrapper source with root element, parse it, then render
        // We'll extract just the content part (without the wrapper)
        const wrapper_prefix = "<i>";
        const wrapper_suffix = "</i>";
        var wrapped_content = try arena.alloc(u8, wrapper_prefix.len + content.len + wrapper_suffix.len);
        @memcpy(wrapped_content[0..wrapper_prefix.len], wrapper_prefix);
        @memcpy(wrapped_content[wrapper_prefix.len .. wrapper_prefix.len + content.len], content);
        @memcpy(wrapped_content[wrapper_prefix.len + content.len ..], wrapper_suffix);

        const wrapped_ast = Ast.init(arena, wrapped_content, .html, false) catch |e| {
            fmtlog.debug("Failed to parse wrapped HTML: {}, falling back to text rendering", .{e});
            return renderMultilineContentAsText(content, base_indent, w);
        };

        // Render to a buffer at indentation 0 (HTML renderer will add its own indentation)
        var buffer_writer: std.io.Writer.Allocating = .init(arena);
        defer buffer_writer.deinit();
        const buffer_writer_ptr: *Writer = @ptrCast(&buffer_writer.writer);
        const render_result: anyerror!void = wrapped_ast.render(arena, wrapped_content, buffer_writer_ptr);
        render_result catch |e| {
            fmtlog.debug("Failed to render HTML AST: {}, falling back to text rendering", .{e});
            return renderMultilineContentAsText(content, base_indent, w);
        };
        var rendered = buffer_writer.written();

        // Extract the content between <i> and </i>, skipping the wrapper tags
        // Find the start of content (after <i>)
        const content_start = std.mem.indexOf(u8, rendered, ">") orelse {
            return renderMultilineContentAsText(content, base_indent, w);
        };
        const after_root_tag = content_start + 1;
        // Find the end of content (before </i>)
        const root_end_tag = std.mem.lastIndexOf(u8, rendered, "</i>") orelse {
            return renderMultilineContentAsText(content, base_indent, w);
        };
        const inner_content = rendered[after_root_tag..root_end_tag];

        // The HTML renderer renders at indentation 0, so we need to:
        // 1. Detect the minimum indentation in the rendered content
        // 2. Preserve relative indentation between lines
        // 3. Add our base_indent to each line

        // First, find the minimum indentation (in spaces, treating tabs as 4 spaces)
        var min_indent: u32 = std.math.maxInt(u32);
        var content_it = std.mem.splitScalar(u8, inner_content, '\n');
        while (content_it.next()) |line| {
            if (line.len == 0) continue;
            var line_indent: u32 = 0;
            for (line) |c| {
                if (c == ' ') {
                    line_indent += 1;
                } else if (c == '\t') {
                    line_indent += 4;
                } else {
                    break;
                }
            }
            // Only consider lines with actual content
            const trimmed = std.mem.trimLeft(u8, line, &std.ascii.whitespace);
            if (trimmed.len > 0 and line_indent < min_indent) {
                min_indent = line_indent;
            }
        }
        if (min_indent == std.math.maxInt(u32)) min_indent = 0;

        // Now render each line, preserving relative indentation
        var buffer_it = std.mem.splitScalar(u8, inner_content, '\n');
        var first_line = true;
        while (buffer_it.next()) |line| {
            if (!first_line) try w.writeAll("\n");

            const trimmed_line = std.mem.trimLeft(u8, line, &std.ascii.whitespace);
            if (trimmed_line.len > 0) {
                // Calculate current line's indentation
                var line_indent: u32 = 0;
                for (line) |c| {
                    if (c == ' ') {
                        line_indent += 1;
                    } else if (c == '\t') {
                        line_indent += 4;
                    } else {
                        break;
                    }
                }

                // Calculate relative indentation (how much more than minimum)
                const relative_indent = if (line_indent >= min_indent) line_indent - min_indent else 0;

                // Write: base_indent + relative_indent
                const total_indent = base_indent * 4 + relative_indent;
                for (0..total_indent) |_| try w.writeAll(" ");
                try w.writeAll(trimmed_line);
            }
            first_line = false;
        }
    } else {
        // No HTML tags - render as plain text
        try renderMultilineContentAsText(content, base_indent, w);
    }
}

/// Render multiline content as plain text with proper indentation
fn renderMultilineContentAsText(content: []const u8, base_indent: u32, w: *Writer) !void {
    if (content.len == 0) return;

    // Render lines with normalized indentation (4 spaces per level)
    // Normalize consecutive blank lines to at most one
    var it = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    var last_was_empty = false;
    while (it.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, &std.ascii.whitespace);
        const is_empty = trimmed.len == 0;

        // Skip consecutive empty lines (keep at most one)
        if (is_empty and last_was_empty) {
            continue;
        }

        if (!first) try w.writeAll("\n");

        if (trimmed.len > 0) {
            // Write base indentation (4 spaces per level)
            // Normalize content to start at base_indent level, ignoring original indentation
            const spaces_to_write = base_indent * 4;
            fmtlog.debug("writing {} spaces for line starting with: '{s}'", .{ spaces_to_write, if (trimmed.len > 20) trimmed[0..20] else trimmed });
            for (0..spaces_to_write) |_| try w.writeAll(" ");

            try w.writeAll(trimmed);
        }
        // Empty lines are preserved (just newline, no indentation) but consecutive ones are normalized

        last_was_empty = is_empty;
        first = false;
    }
}

/// Writer wrapper that adds base indentation at the start of each line
const LineIndentWriter = struct {
    base_indent: u32,
    inner: *Writer,
    at_line_start: bool,

    const Self = @This();

    fn write(context: *anyopaque, bytes: []const u8) !usize {
        const self: *Self = @ptrCast(@alignCast(context));
        var written: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            if (self.at_line_start) {
                // Write base indentation
                for (0..self.base_indent * 4) |_| {
                    _ = try self.inner.writeAll(" ");
                }
                self.at_line_start = false;
            }

            // Find the next newline
            const newline_idx = std.mem.indexOfScalar(u8, bytes[i..], '\n');
            if (newline_idx) |idx| {
                // Write up to and including the newline
                const chunk = bytes[i .. i + idx + 1];
                _ = try self.inner.writeAll(chunk);
                written += chunk.len;
                i += idx + 1;
                self.at_line_start = true;
            } else {
                // Write the rest
                const chunk = bytes[i..];
                _ = try self.inner.writeAll(chunk);
                written += chunk.len;
                break;
            }
        }
        return written;
    }
};

pub fn render(ast: Ast, arena: Allocator, src: []const u8, w: *Writer) !void {
    var aw = std.io.Writer.Allocating.init(arena);
    defer aw.deinit();
    try ast.printErrors(src, null, &aw.writer);
    const errors = aw.written();
    if (errors.len > 0) {
        // std.debug.print("{s}\n", .{errors});
        return error.SyntaxError;
    }
    assert(!ast.has_syntax_errors);

    if (ast.nodes.len < 2) return;

    var indentation: u32 = 0;
    var current = ast.nodes[1];
    var direction: enum { enter, exit } = .enter;
    var last_rbracket: u32 = 0;
    var last_was_text = false;
    var pre: u32 = 0;
    while (true) {
        // const zone_outer = tracy.trace(@src());
        // defer zone_outer.end();
        fmtlog.debug("looping, ind: {}, dir: {s}", .{
            indentation,
            @tagName(direction),
        });

        const crt = current;
        defer last_was_text = crt.kind == .text;
        switch (direction) {
            .enter => {
                // const zone = tracy.trace(@src());
                // defer zone.end();
                fmtlog.debug("rendering enter ({}): {t} lwt: {}", .{
                    indentation,
                    current.kind,
                    last_was_text,
                });

                const maybe_ws = src[last_rbracket..current.open.start];
                fmtlog.debug("maybe_ws = '{s}'", .{maybe_ws});
                // Normalize whitespace in maybe_ws if it's all whitespace (convert tabs to spaces)
                const trimmed_ws = std.mem.trim(u8, maybe_ws, &std.ascii.whitespace);
                const is_all_whitespace = trimmed_ws.len == 0;
                const is_expression = switch (current.kind) {
                    .switch_expr, .if_expr, .for_expr, .while_expr, .text_expr => true,
                    else => false,
                };

                if (pre > 0) {
                    if (is_all_whitespace) {
                        // All whitespace - normalize tabs to spaces
                        try normalizeWhitespace(maybe_ws, w);
                    } else {
                        // Has non-whitespace content, write as-is
                        try w.writeAll(maybe_ws);
                    }
                } else {
                    const vertical = if (last_was_text and current.kind != .text)
                        std.mem.indexOfScalar(u8, maybe_ws, '\n') != null
                    else
                        maybe_ws.len > 0;

                    if (vertical) {
                        fmtlog.debug("adding a newline", .{});
                        const lines = std.mem.count(u8, maybe_ws, "\n");
                        if (last_rbracket > 0) {
                            if (lines >= 2) {
                                try w.writeAll("\n\n");
                            } else {
                                try w.writeAll("\n");
                            }
                        }

                        // Write indentation (convert tabs to spaces for consistency)
                        for (0..indentation * 4) |_| {
                            try w.writeAll(" ");
                        }
                    } else if ((last_was_text or current.kind == .text) and maybe_ws.len > 0) {
                        if (is_expression and is_all_whitespace) {
                            // Normalize whitespace for expression nodes (convert tabs to spaces)
                            try normalizeWhitespace(maybe_ws, w);
                        } else {
                            try w.writeAll(" ");
                        }
                    }
                }

                const child_is_vertical = if (ast.child(current)) |c|
                    (c.kind == .text or c.open.start - current.open.end > 0)
                else
                    false;
                if (!current.self_closing and
                    current.kind.isElement() and
                    !current.kind.isVoid() and
                    child_is_vertical)
                {
                    indentation += 1;
                }
            },
            .exit => {
                // const zone = tracy.trace(@src());
                // defer zone.end();
                assert(current.kind != .text);
                assert(!current.kind.isElement() or !current.kind.isVoid());
                assert(!current.self_closing);

                if (current.kind == .root) {
                    try w.writeAll("\n");
                    return;
                }

                fmtlog.debug("rendering exit ({}): {s} {any}", .{
                    indentation,
                    current.open.slice(src),
                    current,
                });

                const child_was_vertical = if (ast.child(current)) |c|
                    (c.kind == .text or c.open.start - current.open.end > 0)
                else
                    false;
                if (!current.self_closing and
                    current.kind.isElement() and
                    !current.kind.isVoid() and
                    child_was_vertical)
                {
                    indentation -= 1;
                }

                if (pre > 0) {
                    const maybe_ws = src[last_rbracket..current.close.start];
                    try w.writeAll(maybe_ws);
                } else {
                    // const first_child_is_text = if (ast.child(current)) |ch|
                    //     ch.kind == .text
                    // else
                    //     false;
                    // const open_was_vertical = if (first_child_is_text)
                    //     std.mem.indexOfScalar(
                    //         u8,
                    //         src[current.open.end..ast.nodes[current.first_child_idx].open.start],
                    //         '\n',
                    //     ) != null
                    // else
                    // std.ascii.isWhitespace(src[current.open.end]);

                    const open_was_vertical = current.open.end < src.len and
                        std.ascii.isWhitespace(src[current.open.end]);
                    if (open_was_vertical) {
                        try w.writeAll("\n");
                        for (0..indentation) |_| {
                            try w.writeAll("\t");
                        }
                    }
                }
            },
        }

        switch (current.kind) {
            .root => switch (direction) {
                .enter => {
                    // const zone = tracy.trace(@src());
                    // defer zone.end();
                    if (current.first_child_idx == 0) break;
                    current = ast.nodes[current.first_child_idx];
                },
                .exit => break,
            },

            .text => {
                // const zone = tracy.trace(@src());
                // defer zone.end();
                std.debug.assert(direction == .enter);

                const txt = current.open.slice(src);
                const parent_kind = ast.nodes[current.parent_idx].kind;
                switch (parent_kind) {
                    else => blk: {
                        if (pre > 0) {
                            try w.writeAll(txt);
                            break :blk;
                        }
                        // Regular text rendering (expressions are now separate nodes)
                        var it = std.mem.splitScalar(u8, txt, '\n');
                        var first = true;
                        var empty_line = false;
                        while (it.next()) |raw_line| {
                            const line = std.mem.trim(
                                u8,
                                raw_line,
                                &std.ascii.whitespace,
                            );
                            if (line.len == 0) {
                                if (empty_line) continue;
                                empty_line = true;
                                if (!first) for (0..indentation) |_| try w.print("\t", .{});
                                try w.print("\n", .{});
                                continue;
                            } else empty_line = false;
                            if (!first) for (0..indentation) |_| try w.print("\t", .{});
                            try w.print("{s}", .{line});
                            if (it.peek() != null) try w.print("\n", .{});
                            first = false;
                        }
                    },
                    .style, .script => {
                        var css_indent = indentation;
                        var it = std.mem.splitScalar(u8, txt, '\n');
                        var first = true;
                        var empty_line = false;
                        while (it.next()) |raw_line| {
                            const line = std.mem.trim(
                                u8,
                                raw_line,
                                &std.ascii.whitespace,
                            );
                            if (line.len == 0) {
                                if (empty_line) continue;
                                empty_line = true;
                                if (!first) for (0..css_indent) |_| try w.print("\t", .{});
                                try w.print("\n", .{});
                                continue;
                            } else empty_line = false;
                            if (std.mem.endsWith(u8, line, "{")) {
                                if (!first) for (0..css_indent) |_| try w.print("\t", .{});
                                try w.print("{s}", .{line});
                                css_indent += 1;
                            } else if (std.mem.eql(u8, line, "}")) {
                                css_indent -|= 1;
                                if (!first) for (0..css_indent) |_| try w.print("\t", .{});
                                try w.print("{s}", .{line});
                            } else {
                                if (!first) for (0..css_indent) |_| try w.print("\t", .{});
                                try w.print("{s}", .{line});
                            }

                            if (it.peek() != null) try w.print("\n", .{});

                            first = false;
                        }
                    },
                }
                last_rbracket = current.open.end;

                if (current.next_idx != 0) {
                    fmtlog.debug("text next: {}", .{current.next_idx});
                    current = ast.nodes[current.next_idx];
                } else {
                    current = ast.nodes[current.parent_idx];
                    direction = .exit;
                }
            },

            .switch_expr, .if_expr, .for_expr, .while_expr, .text_expr => {
                std.debug.assert(direction == .enter);

                const expr_text = current.open.slice(src);
                fmtlog.debug("rendering expression node: kind={s}, span=[{}..{}], text='{s}'", .{
                    @tagName(current.kind),
                    current.open.start,
                    current.open.end,
                    if (expr_text.len > 50) expr_text[0..50] else expr_text,
                });

                // Parse the expression to get detailed structure
                fmtlog.debug("calling expr.parse...", .{});
                const expressions = expr.parse(arena, expr_text) catch |e| {
                    fmtlog.debug("expr.parse failed: {}, writing as-is", .{e});
                    // If parsing fails, just write as-is
                    try w.writeAll(expr_text);
                    last_rbracket = current.open.end;
                    if (current.next_idx != 0) {
                        current = ast.nodes[current.next_idx];
                    } else {
                        current = ast.nodes[current.parent_idx];
                        direction = .exit;
                    }
                    continue;
                };
                fmtlog.debug("expr.parse succeeded, got {} expressions", .{expressions.len});
                defer {
                    for (expressions) |expr_ast| {
                        if (expr_ast.kind == .switch_expr) {
                            arena.free(expr_ast.kind.switch_expr.cases);
                        }
                    }
                    arena.free(expressions);
                }

                if (expressions.len > 0) {
                    // Render the expression with proper formatting
                    fmtlog.debug("calling renderExpression with kind={s}, indentation={}", .{ @tagName(expressions[0].kind), indentation });
                    try renderExpression(expressions[0], indentation, arena, w);
                    fmtlog.debug("renderExpression completed", .{});
                } else {
                    fmtlog.debug("no expressions, writing as-is", .{});
                    try w.writeAll(expr_text);
                }

                last_rbracket = current.open.end;

                if (current.next_idx != 0) {
                    current = ast.nodes[current.next_idx];
                } else {
                    current = ast.nodes[current.parent_idx];
                    direction = .exit;
                }
            },

            .comment => {
                // const zone = tracy.trace(@src());
                // defer zone.end();
                std.debug.assert(direction == .enter);

                try w.writeAll(current.open.slice(src));
                last_rbracket = current.open.end;

                if (current.next_idx != 0) {
                    current = ast.nodes[current.next_idx];
                } else {
                    current = ast.nodes[current.parent_idx];
                    direction = .exit;
                }
            },

            .doctype => {
                // const zone = tracy.trace(@src());
                // defer zone.end();
                last_rbracket = current.open.end;
                const maybe_name, const maybe_extra = blk: {
                    var tt: Tokenizer = .{ .language = ast.language };
                    const tag = current.open.slice(src);
                    fmtlog.debug("doctype tag: {s} {any}", .{ tag, current });
                    const dt = tt.next(tag).?.doctype;
                    const maybe_name: ?[]const u8 = if (dt.name) |name|
                        name.slice(tag)
                    else
                        null;
                    const maybe_extra: ?[]const u8 = if (dt.extra.start > 0)
                        dt.extra.slice(tag)
                    else
                        null;

                    break :blk .{ maybe_name, maybe_extra };
                };

                if (maybe_name) |n| {
                    try w.print("<!DOCTYPE {s}", .{n});
                } else {
                    try w.print("<!DOCTYPE", .{});
                }

                if (maybe_extra) |e| {
                    try w.print(" {s}>", .{e});
                } else {
                    try w.print(">", .{});
                }

                if (current.next_idx != 0) {
                    current = ast.nodes[current.next_idx];
                } else {
                    current = ast.nodes[current.parent_idx];
                    direction = .exit;
                }
            },

            else => switch (direction) {
                .enter => {
                    // const zone = tracy.trace(@src());
                    // defer zone.end();
                    last_rbracket = current.open.end;

                    var sti = current.startTagIterator(src, ast.language);
                    const name = sti.name_span.slice(src);

                    if (current.kind == .pre and !current.self_closing) {
                        pre += 1;
                    }

                    try w.print("<{s}", .{name});

                    const vertical = std.ascii.isWhitespace(
                        // <div arst="arst" >
                        //                 ^
                        src[current.open.end - 2],
                    ) and blk: {
                        // Don't do vertical alignment if we don't have
                        // at least 2 attributes.
                        var temp_sti = sti;
                        _ = temp_sti.next(src) orelse break :blk false;
                        _ = temp_sti.next(src) orelse break :blk false;
                        break :blk true;
                    };

                    fmtlog.debug("element <{s}> vertical = {}", .{ name, vertical });

                    // if (std.mem.eql(u8, name, "path")) @breakpoint();

                    const child_is_vertical = if (ast.child(current)) |c|
                        (c.kind == .text or c.open.start - current.open.end > 0)
                    else
                        false;
                    const attr_indent = indentation - @intFromBool(!current.kind.isVoid() and !current.self_closing and child_is_vertical);
                    const extra = blk: {
                        if (current.kind == .doctype) break :blk 1;
                        assert(current.kind.isElement());
                        break :blk name.len + 2;
                    };

                    var first = true;
                    while (sti.next(src)) |attr| {
                        if (vertical) {
                            if (first) {
                                first = false;
                                try w.print(" ", .{});
                            } else {
                                try w.print("\n", .{});
                                for (0..attr_indent) |_| {
                                    try w.print("\t", .{});
                                }
                                for (0..extra) |_| {
                                    try w.print(" ", .{});
                                }
                            }
                        } else {
                            try w.print(" ", .{});
                        }
                        try w.print("{s}", .{
                            attr.name.slice(src),
                        });
                        if (attr.value) |val| {
                            const q = switch (val.quote) {
                                .none => "",
                                .single => "'",
                                .double => "\"",
                            };
                            try w.print("={s}{s}{s}", .{
                                q,
                                val.span.slice(src),
                                q,
                            });
                        }
                    }
                    if (vertical) {
                        try w.print("\n", .{});
                        for (0..attr_indent) |_| {
                            try w.print("\t", .{});
                        }
                    }

                    if (current.self_closing and !current.kind.isVoid()) {
                        try w.print("/", .{});
                    }
                    try w.print(">", .{});

                    assert(current.kind.isElement());

                    if (current.self_closing or current.kind.isVoid()) {
                        if (current.next_idx != 0) {
                            current = ast.nodes[current.next_idx];
                        } else {
                            direction = .exit;
                            current = ast.nodes[current.parent_idx];
                        }
                    } else {
                        if (current.first_child_idx == 0) {
                            direction = .exit;
                        } else {
                            current = ast.nodes[current.first_child_idx];
                        }
                    }
                },
                .exit => {
                    // const zone = tracy.trace(@src());
                    // defer zone.end();
                    std.debug.assert(!current.kind.isVoid());
                    std.debug.assert(!current.self_closing);
                    last_rbracket = current.close.end;
                    if (current.close.start != 0) {
                        const name = blk: {
                            var tt: Tokenizer = .{
                                .language = ast.language,
                                .return_attrs = true,
                            };
                            const tag = current.open.slice(src);
                            fmtlog.debug("retokenize {s}\n", .{tag});
                            break :blk tt.getName(tag).?.slice(tag);
                        };

                        if (std.ascii.eqlIgnoreCase("pre", name)) {
                            pre -= 1;
                        }
                        try w.print("</{s}>", .{name});
                    }
                    if (current.next_idx != 0) {
                        direction = .enter;
                        current = ast.nodes[current.next_idx];
                    } else {
                        current = ast.nodes[current.parent_idx];
                    }
                },
            },
        }
    }
}

pub const Completion = struct {
    label: []const u8,
    desc: []const u8,
    value: ?[]const u8 = null,
    // This value is used by the lsp to know how to interpret
    // the value field of this list of suggestions.
    kind: enum { attribute, element_open, element_close } = .attribute,
};

pub fn completions(
    ast: Ast,
    arena: Allocator,
    src: []const u8,
    offset: u32,
) ![]const Completion {
    for (ast.errors) |err| {
        if (err.tag != .token or
            offset < err.main_location.start or
            offset > err.main_location.end) continue;

        var idx = offset;
        while (idx > 0) {
            idx -= 1;
            switch (src[idx]) {
                '<', '/' => break,
                ' ', '\n', '\t', '\r' => continue,
                else => return &.{},
            }
        } else return &.{};

        cpllog.debug("completions before check", .{});
        const parent_idx = err.node_idx;
        const parent_node = ast.nodes[parent_idx];
        if ((!parent_node.kind.isElement() and
            parent_node.kind != .root) or
            parent_node.kind == .svg or
            parent_node.kind == .math) return &.{};

        cpllog.debug("completions past check", .{});

        const e = Element.all.get(parent_node.kind);
        cpllog.debug("===== completions content: {t}", .{parent_node.kind});
        return e.completions(arena, ast, src, parent_idx, offset, .content);
    }

    const node_idx = ast.findNodeTagsIdx(offset);
    cpllog.debug("===== completions: attrs node: {}", .{node_idx});
    if (node_idx == 0) return &.{};

    const n = ast.nodes[node_idx];
    cpllog.debug("===== node: {any}", .{n});
    if (!n.kind.isElement()) return &.{};
    if (offset >= n.open.end) return &.{};

    const e = Element.all.get(n.kind);
    return e.completions(arena, ast, src, node_idx, offset, .attrs);
}

/// Returns the node index whose start or end tag overlaps the provided offset.
/// Returns zero if the offset is outside of a start/end tag.
pub fn findNodeTagsIdx(ast: *const Ast, offset: u32) u32 {
    if (ast.nodes.len < 2) return 0;
    var cur_idx: u32 = 1;
    while (cur_idx != 0) {
        const n = ast.nodes[cur_idx];
        if (!n.kind.isElement()) cur_idx = 0;

        if (n.open.start <= offset and n.open.end > offset) {
            break;
        }
        if (n.close.end != 0 and n.close.start <= offset and n.close.end > offset) {
            break;
        }

        if (n.open.end <= offset and n.close.start > offset) {
            cur_idx = n.first_child_idx;
        } else {
            cur_idx = n.next_idx;
        }
    }

    return cur_idx;
}

// pub fn transparentAncestorRule(
//     nodes: []const Node,
//     src: []const u8,
//     language: Language,
//     parent_idx: u32,
// ) ?struct {
//     tag: tags.RuleEnum,
//     span: Span,
//     idx: u32,
// } {
//     var ancestor_idx = parent_idx;
//     while (ancestor_idx != 0) {
//         const ancestor = nodes[ancestor_idx];
//         var ptt: Tokenizer = .{
//             .idx = ancestor.open.start,
//             .return_attrs = true,
//             .language = language,
//         };

//         const ancestor_span = ptt.next(
//             src[0..ancestor.open.end],
//         ).?.tag_name;
//         const ancestor_name = ancestor_span.slice(src);

//         const ancestor_rule = tags.all.get(
//             ancestor_name,
//         ) orelse return null;

//         if (ancestor_rule == .transparent) {
//             ancestor_idx = ancestor.parent_idx;
//             continue;
//         }

//         return .{
//             .tag = ancestor_rule,
//             .span = ancestor_span,
//             .idx = ancestor_idx,
//         };
//     }
//     return null;
// }

fn at(ast: Ast, idx: u32) ?Node {
    if (idx == 0) return null;
    return ast.nodes[idx];
}

pub fn parent(ast: Ast, n: Node) ?Node {
    if (n.parent_idx == 0) return null;
    return ast.nodes[n.parent_idx];
}

pub fn nextSibling(ast: Ast, n: Node) ?Node {
    return ast.at(n.next_idx);
}

pub fn lastChild(ast: Ast, n: Node) ?Node {
    _ = ast;
    _ = n;
    @panic("TODO");
}

pub fn child(ast: Ast, n: Node) ?Node {
    return ast.at(n.first_child_idx);
}

pub fn formatter(ast: Ast, arena: Allocator, src: []const u8) Formatter {
    return .{ .ast = ast, .arena = arena, .src = src };
}
const Formatter = struct {
    ast: Ast,
    arena: Allocator,
    src: []const u8,

    pub fn format(f: Formatter, w: *Writer) !void {
        try f.ast.render(f.arena, f.src, w);
    }
};

pub fn debug(ast: Ast, src: []const u8) void {
    var c = ast.cursor(0);
    var last_depth: u32 = 0;
    std.debug.print(" \n node count: {}\n", .{ast.nodes.len});
    while (c.next()) |n| {
        if (c.dir == .out) {
            std.debug.print("\n", .{});
            while (last_depth > c.depth) : (last_depth -= 1) {
                for (0..last_depth - 2) |_| std.debug.print("    ", .{});
                std.debug.print(")", .{});
                if (last_depth - c.depth > 1) {
                    std.debug.print("\n", .{});
                }
            }
            last_depth = c.depth;
            continue;
        }
        std.debug.print("\n", .{});
        for (0..c.depth - 1) |_| std.debug.print("    ", .{});
        const range = n.open.range(src);
        std.debug.print("({s} #{} @{} [{}, {}] - [{}, {}]", .{
            @tagName(n.kind),
            c.idx,
            c.depth,
            range.start.row,
            range.start.col,
            range.end.row,
            range.end.col,
        });
        if (n.first_child_idx == 0) {
            std.debug.print(")", .{});
        }
        last_depth = c.depth;
    }
    std.debug.print("\n", .{});
    while (last_depth > 1) : (last_depth -= 1) {
        for (0..last_depth - 2) |_| std.debug.print("    ", .{});
        std.debug.print(")\n", .{});
    }
}

fn debugNodes(nodes: []const Node, src: []const u8) void {
    const ast = Ast{
        .language = .html,
        .nodes = nodes,
        .errors = &.{},
        .has_syntax_errors = false,
    };
    ast.debug(src);
}

test "basics" {
    const case = "<html><head></head><body><div><br></div></body></html>\n";

    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(case, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "basics - attributes" {
    const case = "<html><head></head><body>" ++
        \\<div id="foo" class="bar">
    ++ "<link></div></body></html>\n";

    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(case, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "newlines" {
    const case =
        \\<!DOCTYPE html>
        \\<html>
        \\  <head></head>
        \\  <body>
        \\    <div><link></div>
        \\  </body>
        \\</html>
        \\
    ;
    const expected = comptime std.fmt.comptimePrint(
        \\<!DOCTYPE html>
        \\<html>
        \\{0c}<head></head>
        \\{0c}<body>
        \\{0c}{0c}<div><link></div>
        \\{0c}</body>
        \\</html>
        \\
    , .{'\t'});
    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(expected, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "tight tags inner indentation" {
    const case = comptime std.fmt.comptimePrint(
        \\<!DOCTYPE html>
        \\<html>
        \\{0c}<head></head>
        \\{0c}<body>
        \\{0c}{0c}<div><nav><ul>
        \\{0c}{0c}{0c}<li></li>
        \\{0c}{0c}</ul></nav></div>
        \\{0c}</body>
        \\</html>
        \\
    , .{'\t'});
    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(case, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "bad html" {
    // TODO: handle ast.errors.len != 0
    if (true) return error.SkipZigTest;

    const case =
        \\<html>
        \\<body>
        \\<p $class=" arst>Foo</p>
        \\
        \\</html>
    ;
    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(case, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "formatting - simple" {
    const case =
        \\<!DOCTYPE html>   <html>
        \\<head></head>               <body> <div><link></div>
        \\  </body>               </html>
    ;
    const expected = comptime std.fmt.comptimePrint(
        \\<!DOCTYPE html>
        \\<html>
        \\{0c}<head></head>
        \\{0c}<body>
        \\{0c}{0c}<div><link></div>
        \\{0c}</body>
        \\</html>
        \\
    , .{'\t'});
    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(expected, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "formatting - attributes" {
    const case =
        \\<html>
        \\  <body>
        \\    <div>
        \\      <link>
        \\      <div id="foo" class="bar" style="tarstarstarstarstarstarstarst"
        \\      ></div>
        \\    </div>
        \\  </body>
        \\</html>
    ;
    const expected = comptime std.fmt.comptimePrint(
        \\<html>
        \\{0c}<body>
        \\{0c}{0c}<div>
        \\{0c}{0c}{0c}<link>
        \\{0c}{0c}{0c}<div id="foo"
        \\{0c}{0c}{0c}     class="bar"
        \\{0c}{0c}{0c}     style="tarstarstarstarstarstarstarst"
        \\{0c}{0c}{0c}></div>
        \\{0c}{0c}</div>
        \\{0c}</body>
        \\</html>
        \\
    , .{'\t'});
    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(expected, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "pre" {
    const case =
        \\<b>    </b>
        \\<pre>      </pre>
    ;
    const expected =
        \\<b>
        \\</b>
        \\<pre>      </pre>
        \\
    ;

    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(expected, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "pre text" {
    const case =
        \\<b> banana</b>
        \\<pre>   banana   </pre>
    ;
    const expected = comptime std.fmt.comptimePrint(
        \\<b>
        \\{0c}banana
        \\</b>
        \\<pre>   banana   </pre>
        \\
    , .{'\t'});

    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(expected, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "what" {
    const case =
        \\<html>
        \\  <body>
        \\    <a href="#" foo="bar" banana="peach">
        \\      <b><link>
        \\      </b>
        \\      <b></b>
        \\      <pre></pre>
        \\    </a>
        \\  </body>
        \\</html>
        \\
        \\
        \\<a href="#">foo </a>
    ;

    const expected = comptime std.fmt.comptimePrint(
        \\<html>
        \\{0c}<body>
        \\{0c}{0c}<a href="#" foo="bar" banana="peach">
        \\{0c}{0c}{0c}<b><link></b>
        \\{0c}{0c}{0c}<b></b>
        \\{0c}{0c}{0c}<pre></pre>
        \\{0c}{0c}</a>
        \\{0c}</body>
        \\</html>
        \\
        \\<a href="#">foo</a>
        \\
    , .{'\t'});

    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(expected, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "spans" {
    const case =
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\  <head>
        \\    <meta charset="UTF-8">
        \\  </head>
        \\  <body>
        \\    <span>Hello</span><span>World</span>
        \\    <br>
        \\    <span>Hello</span> <span>World</span>
        \\  </body>
        \\</html>
    ;

    const expected = comptime std.fmt.comptimePrint(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\{0c}<head>
        \\{0c}{0c}<meta charset="UTF-8">
        \\{0c}</head>
        \\{0c}<body>
        \\{0c}{0c}<span>Hello</span><span>World</span>
        \\{0c}{0c}<br>
        \\{0c}{0c}<span>Hello</span>
        \\{0c}{0c}<span>World</span>
        \\{0c}</body>
        \\</html>
        \\
    , .{'\t'});

    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(expected, "{f}", .{ast.formatter(std.testing.allocator, case)});
}
test "arrow span" {
    const case =
        \\<a href="$if.permalink()">← <span var="$if.title"></span></a>
        \\
    ;

    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(case, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "self-closing tag complex example" {
    const case =
        \\extend template="base.html"/>
        \\
        \\<div id="content">
        \\<svg viewBox="0 0 24 24">
        \\<path d="M14.4,6H20V16H13L12.6,14H7V21H5V4H14L14.4,6M14,14H16V12H18V10H16V8H14V10L13,8V6H11V8H9V6H7V8H9V10H7V12H9V10H11V12H13V10L14,12V14M11,10V8H13V10H11M14,10H16V12H14V10Z" />
        \\</svg>
        \\</div>
    ;
    const expected = comptime std.fmt.comptimePrint(
        \\extend template="base.html"/>
        \\
        \\<div id="content">
        \\{0c}<svg viewBox="0 0 24 24">
        \\{0c}{0c}<path d="M14.4,6H20V16H13L12.6,14H7V21H5V4H14L14.4,6M14,14H16V12H18V10H16V8H14V10L13,8V6H11V8H9V6H7V8H9V10H7V12H9V10H11V12H13V10L14,12V14M11,10V8H13V10H11M14,10H16V12H14V10Z"/>
        \\{0c}</svg>
        \\</div>
        \\
    , .{'\t'});
    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(expected, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "respect empty lines" {
    const case =
        \\
        \\<div> a
        \\</div>
        \\
        \\<div></div>
        \\
        \\<div></div>
        \\<div></div>
        \\
        \\
        \\<div></div>
        \\
        \\
        \\
        \\<div></div>
        \\<div> a
        \\</div>
        \\
        \\
        \\
        \\<div> a
        \\</div>
    ;
    const expected = comptime std.fmt.comptimePrint(
        \\<div>
        \\{0c}a
        \\</div>
        \\
        \\<div></div>
        \\
        \\<div></div>
        \\<div></div>
        \\
        \\<div></div>
        \\
        \\<div></div>
        \\<div>
        \\{0c}a
        \\</div>
        \\
        \\<div>
        \\{0c}a
        \\</div>
        \\
    , .{'\t'});
    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);

    try std.testing.expectFmt(expected, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

test "pre formatting" {
    const case = comptime std.fmt.comptimePrint(
        \\<!DOCTYPE html>
        \\<html>
        \\{0c}<head>
        \\{0c}{0c}<title>Test</title>
        \\{0c}</head>
        \\{0c}<body>
        \\{0c}{0c}<pre>Line 1
        \\Line 2
        \\Line 3
        \\</pre>
        \\{0c}</body>
        \\</html>
        \\
    , .{'\t'});

    const ast = try Ast.init(std.testing.allocator, case, .html, false);
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectFmt(case, "{f}", .{ast.formatter(std.testing.allocator, case)});
}

pub const Cursor = struct {
    ast: Ast,
    idx: u32,
    depth: u32 = 0,
    dir: enum { in, next, out } = .in,

    pub fn reset(c: *Cursor, n: Node) void {
        _ = c;
        _ = n;
        @panic("TODO");
    }

    pub fn node(c: Cursor) Node {
        return c.ast.nodes[c.idx];
    }

    pub fn next(c: *Cursor) ?Node {
        if (c.idx == 0 and c.dir == .out) return null;

        var n = c.node();
        if (c.ast.child(n)) |ch| {
            c.idx = n.first_child_idx;
            c.dir = .in;
            c.depth += 1;
            return ch;
        }

        if (c.ast.nextSibling(n)) |s| {
            c.idx = n.next_idx;
            c.dir = .next;
            return s;
        }

        return while (c.ast.parent(n)) |p| {
            n = p;
            c.depth -= 1;
            const uncle = c.ast.nextSibling(p) orelse continue;
            c.idx = p.next_idx;
            c.dir = .out;
            break uncle;
        } else blk: {
            c.idx = 0;
            c.dir = .out;
            break :blk null;
        };
    }
};
