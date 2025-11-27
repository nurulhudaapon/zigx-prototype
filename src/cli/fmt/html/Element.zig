const Element = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const root = @import("html.zig");
const Language = root.Language;
const Span = root.Span;
const Ast = @import("Ast.zig");
const Error = Ast.Error;
const Kind = Ast.Kind;
const Tokenizer = @import("Tokenizer.zig");
const Attribute = @import("Attribute.zig");

const log = std.log.scoped(.element);

tag: Kind,

/// The static model of this element. Static means the combination of
/// categories and content model that the element has without any change
/// that could be caused by the presence/absence of attributes or nested
/// content.
model: Model,

/// Support information used for computing completions and deriving reasons
/// behind errors caused by non-static model changes.
meta: struct {
    categories_superset: Categories,
    content_reject: Categories = .none,
    extra_reject: Extra = .none,
},

/// Strings used to explain reasons behind errors caused by non-static model
/// changes.
reasons: Reasons = .{},

/// Attribute validation.
attributes: union(enum) {
    /// Attribute validation will not be performed when adding the element to
    /// the AST. Used by:
    /// - `<source>`, validated by parent elements
    /// - `<optgroup>`, validated while validating children
    manual,
    static,
    /// Custom attribute validation. Has also access to the incomplete AST to
    /// navigate ancestry when necessary. Any constraint that requires knowledge
    /// of descendants must be evaluated in the content callback.
    /// NOTE: node_idx is not yet present in the AST, to navigate upwards use
    /// parent_idx directly.
    dynamic: *const fn (
        gpa: Allocator,
        errors: *std.ArrayListUnmanaged(Error),
        src: []const u8,
        nodes: []const Ast.Node,
        parent_idx: u32,
        node_idx: u32,
        vait: *Attribute.ValidatingIterator,
    ) error{OutOfMemory}!Model,
},

/// Content validation and completions.
content: union(enum) {
    model,
    anything,
    simple: Simple,
    custom: struct {
        validate: *const fn (
            gpa: Allocator,
            nodes: []const Ast.Node,
            seen_attrs: *std.StringHashMapUnmanaged(Span),
            seen_ids: *std.StringHashMapUnmanaged(Span),
            errors: *std.ArrayListUnmanaged(Ast.Error),
            src: []const u8,
            parent_idx: u32,
        ) error{OutOfMemory}!void,
        completions: *const fn (
            arena: Allocator,
            ast: Ast,
            src: []const u8,
            parent_idx: u32,
            offset: u32, // cursor position
        ) error{OutOfMemory}![]const Ast.Completion,
    },
},

desc: []const u8,

pub const Simple = struct {
    // Allowed tags that are not part of the allowed categories.
    extra_children: []const Kind = &.{},
    // Frobidden tags that are part of the allowed categories.
    forbidden_children: []const Kind = &.{},
    // Frobidden tags that are part of the allowed categories,
    // applies to all descendants, not just direct children.
    forbidden_descendants: ?std.EnumSet(Kind) = null,
    forbidden_descendants_extra: Extra = .none,
};

const Reasons = struct {
    categories: Reasons.Categories = .{},
    const Categories = struct {
        // metadata: []const u8 = "",
        flow: Reason = .{},
        // sectioning: []const u8 = "",
        // heading: []const u8 = "",
        phrasing: Reason = .{},
        // embedded: []const u8 = "",
        interactive: Reason = .{},
    };

    const Reason = struct {
        reject: []const u8 = "",
        accept: []const u8 = "",
    };
};

pub const CompletionMode = enum { content, attrs };

pub const Set = std.StaticStringMapWithEql(
    void,
    std.static_string_map.eqlAsciiIgnoreCase,
);

pub const Model = struct {
    categories: Categories,
    content: Categories,
    extra: Extra = .none,
};

pub const Extra = packed struct {
    // checked by `a`
    tabindex: bool = false,

    // set by img elements, used to validate source siblings
    autosizes_allowed: bool = false,

    pub const none: Extra = .{};

    const Tag = @typeInfo(Extra).@"struct".backing_integer.?;

    // TODO: remove once packed struct comparison works
    pub inline fn empty(e: Extra) bool {
        const int: Tag = @bitCast(e);
        return int == 0;
    }

    pub inline fn overlaps(lhs: Extra, rhs: Extra) bool {
        const l: Tag = @bitCast(lhs);
        const r: Tag = @bitCast(rhs);
        return (l & r) != 0;
    }

    pub inline fn intersect(lhs: Extra, rhs: Extra) Extra {
        const l: Tag = @bitCast(lhs);
        const r: Tag = @bitCast(rhs);
        return @bitCast(l & r);
    }
};

pub const Categories = packed struct {
    metadata: bool = false,
    flow: bool = false,
    phrasing: bool = false,
    text: bool = false,
    sectioning: bool = false,
    heading: bool = false,
    interactive: bool = false,
    // embedded: bool = false,

    pub const none: Categories = .{};
    pub const all: Categories = .{
        .metadata = true,
        .flow = true,
        .phrasing = true,
        .text = true,
        .sectioning = true,
        .heading = true,
        .interactive = true,
        // .embedded = true,
    };
    // Just for clarity
    pub const transparent: Categories = .all;

    const Tag = @typeInfo(Categories).@"struct".backing_integer.?;

    // TODO: remove once packed struct comparison works
    pub inline fn empty(cs: Categories) bool {
        const int: Tag = @bitCast(cs);
        return int == 0;
    }

    pub inline fn overlaps(lhs: Categories, rhs: Categories) bool {
        const l: Tag = @bitCast(lhs);
        const r: Tag = @bitCast(rhs);
        return (l & r) != 0;
    }

    pub inline fn intersect(lhs: Categories, rhs: Categories) Categories {
        const l: Tag = @bitCast(lhs);
        const r: Tag = @bitCast(rhs);
        return @bitCast(l & r);
    }

    pub inline fn merge(lhs: Categories, rhs: Categories) Categories {
        const l: Tag = @bitCast(lhs);
        const r: Tag = @bitCast(rhs);
        return @bitCast(l | r);
    }

    pub inline fn has(cs: Categories, cat: std.meta.FieldEnum(Categories)) bool {
        return switch (cat) {
            inline else => |f| @field(cs, @tagName(f)),
        };
    }
};

pub const Rejection = struct {
    reason: []const u8,
    span: Span,
};
pub inline fn modelRejects(
    parent_element: *const Element,
    nodes: []const Ast.Node,
    src: []const u8,
    parent_node: Ast.Node,
    parent_span: Span,
    descendant_element: *const Element,
    descendant_rt_model: Model,
) ?Rejection {
    log.debug("========== modelRejects {t} > {t}", .{
        parent_element.tag,
        descendant_element.tag,
    });

    if (!parent_node.model.content.overlaps(descendant_rt_model.categories)) {
        log.debug("========== no content - categories overlap {t} > {t}", .{
            parent_element.tag,
            descendant_element.tag,
        });

        if (!parent_element.model.content.overlaps(descendant_rt_model.categories)) {
            log.debug("========== no static overlap {t} > {t}", .{
                parent_element.tag,
                descendant_element.tag,
            });

            const intersection = parent_node.model.content.intersect(
                descendant_element.meta.categories_superset,
            );

            inline for (std.meta.fields(Categories)) |f| {
                if (@field(intersection, f.name) and @hasField(Reasons.Categories, f.name)) {
                    // if this is not a runtime property, report it as the reason
                    if (!@field(descendant_element.model.categories, f.name)) {
                        return .{
                            .reason = @field(descendant_element.reasons.categories, f.name).accept,
                            .span = parent_span,
                        };
                    }
                }
            }

            return .{ .reason = "", .span = parent_span };
        }

        // Check if the content model of the parent was changed because it's
        // transparent.
        log.debug("========== yes static overlap {t} > {t}", .{
            parent_element.tag,
            descendant_element.tag,
        });

        var ancestor_idx = parent_node.parent_idx;
        while (ancestor_idx != 0) {
            const ancestor = nodes[ancestor_idx];
            ancestor_idx = ancestor.parent_idx;

            assert(ancestor.kind.isElement());
            assert(ancestor.kind != .___);
            const element = Element.all.get(ancestor.kind);
            if (!element.model.content.overlaps(descendant_rt_model.categories)) {
                return .{
                    .reason = "",
                    .span = ancestor.span(src),
                };
            }
        }

        // if we reach here it means that we have transparent elements at the
        // top level of our tree.
        return .{
            .reason = "",
            .span = parent_span,
        };
    }

    if (parent_element.meta.content_reject.overlaps(descendant_rt_model.categories)) {
        const intersection = parent_element.meta.content_reject.intersect(
            descendant_rt_model.categories,
        );

        inline for (std.meta.fields(Categories)) |f| {
            if (@field(intersection, f.name) and @hasField(Reasons.Categories, f.name)) {
                // if this is not a runtime property, report it as the reason
                if (!@field(descendant_element.model.categories, f.name)) {
                    return .{
                        .reason = @field(descendant_element.reasons.categories, f.name).reject,
                        .span = parent_span,
                    };
                }
            }
        }

        return .{ .reason = "", .span = parent_span };
    }

    if (parent_element.meta.extra_reject.tabindex and descendant_rt_model.extra.tabindex) {
        return .{
            .span = parent_span,
            .reason = "presence of tabindex attribute",
        };
    }

    return null;
}

pub inline fn validateContent(
    parent_element: *const Element,
    gpa: Allocator,
    nodes: []const Ast.Node,
    seen_attrs: *std.StringHashMapUnmanaged(Span),
    seen_ids: *std.StringHashMapUnmanaged(Span),
    errors: *std.ArrayListUnmanaged(Ast.Error),
    src: []const u8,
    parent_idx: u32,
) !void {
    content: switch (parent_element.content) {
        .anything => {},
        .custom => |custom| try custom.validate(
            gpa,
            nodes,
            seen_attrs,
            seen_ids,
            errors,
            src,
            parent_idx,
        ),
        .model => continue :content .{ .simple = .{} },
        .simple => |simple| {
            const parent = nodes[parent_idx];
            const parent_span = parent.startTagIterator(src, .html).name_span;
            assert(parent.kind.isElement());
            assert(parent.kind != .___);
            const first_child_idx = nodes[parent_idx].first_child_idx;

            var child_idx = first_child_idx;
            outer: while (child_idx != 0) {
                const child = nodes[child_idx];
                defer child_idx = child.next_idx;

                switch (child.kind) {
                    else => {},
                    .doctype => continue,
                    .comment => continue,
                    .___ => continue,
                    .text => {
                        if (!parent.model.content.flow and
                            !parent.model.content.phrasing and
                            !parent.model.content.text)
                        {
                            try errors.append(gpa, .{
                                .tag = .{
                                    .invalid_nesting = .{
                                        .span = parent_span,
                                    },
                                },
                                .main_location = child.open,
                                .node_idx = child_idx,
                            });
                        }

                        continue;
                    },
                }

                assert(simple.extra_children.len < 10);
                for (simple.extra_children) |extra| {
                    if (child.kind == extra) continue :outer;
                }

                assert(simple.forbidden_children.len < 10);
                for (simple.forbidden_children) |forbidden| {
                    if (child.kind == forbidden) {
                        try errors.append(gpa, .{
                            .tag = .{
                                .invalid_nesting = .{
                                    .span = parent_span,
                                },
                            },
                            .main_location = child.span(src),
                            .node_idx = child_idx,
                        });
                        continue :outer;
                    }
                }

                if (parent_element.modelRejects(
                    nodes,
                    src,
                    parent,
                    parent_span,
                    &Element.all.get(child.kind),
                    child.model,
                )) |rejection| {
                    try errors.append(gpa, .{
                        .tag = .{
                            .invalid_nesting = .{
                                .span = rejection.span,
                                .reason = rejection.reason,
                            },
                        },
                        .main_location = child.span(src),
                        .node_idx = child_idx,
                    });
                }
            }

            if (simple.forbidden_descendants == null and
                simple.forbidden_descendants_extra.empty())
            {
                return;
            }

            // check descendants
            if (first_child_idx == 0) return;
            const stop_idx = parent.stop(nodes);

            var next_idx = first_child_idx;
            outer: while (next_idx != stop_idx) {
                assert(next_idx != 0);

                const node_idx = next_idx;
                const node = nodes[node_idx];

                if (node.kind == .___) {
                    next_idx = node.stop(nodes);
                    continue;
                } else if (node.kind == .svg or node.kind == .math) {
                    next_idx = node.stop(nodes);
                } else if (node.kind == .comment or node.kind == .text) {
                    next_idx += 1;
                    continue;
                } else {
                    next_idx += 1;
                }

                if (simple.forbidden_descendants) |forbidden| {
                    if (forbidden.contains(node.kind)) {
                        try errors.append(gpa, .{
                            .tag = .{
                                .invalid_nesting = .{
                                    .span = parent_span,
                                },
                            },
                            .main_location = node.span(src),
                            .node_idx = node_idx,
                        });
                        continue :outer;
                    }
                }

                if (simple.forbidden_descendants_extra.tabindex and
                    node.model.extra.tabindex)
                {
                    try errors.append(gpa, .{
                        .tag = .{
                            .invalid_nesting = .{
                                .span = parent_span,
                                .reason = "presence of [tabindex]",
                            },
                        },
                        .main_location = node.span(src),
                        .node_idx = node_idx,
                    });
                    continue :outer;
                }
            }
        },
    }
}

pub inline fn validateAttrs(
    element: *const Element,
    gpa: Allocator,
    lang: Language,
    errors: *std.ArrayListUnmanaged(Error),
    seen_attrs: *std.StringHashMapUnmanaged(Span),
    seen_ids: *std.StringHashMapUnmanaged(Span),
    nodes: []const Ast.Node,
    parent_idx: u32,
    src: []const u8,
    tag: Span,
    node_idx: u32,
) error{OutOfMemory}!Model {
    var vait: Attribute.ValidatingIterator = .init(
        errors,
        seen_attrs,
        seen_ids,
        lang,
        tag,
        src,
        node_idx,
    );

    return switch (element.attributes) {
        .manual => return element.model,
        .dynamic => |validate| validate(
            gpa,
            errors,
            src,
            nodes,
            parent_idx,
            node_idx,
            &vait,
        ),
        .static => blk: {
            // const max_len = comptime max: {
            //     var max: u32 = 0;
            //     for (Attribute.element_attrs.values[@intFromEnum(Ast.Kind.___) + 1 ..]) |set| {
            //         if (max < set.list.len) max = set.list.len;
            //     }
            //     break :max max;
            // };

            const attrs_set = Attribute.element_attrs.get(element.tag);
            var tabindex = false;

            while (try vait.next(gpa, src)) |attr| {
                const span = attr.name;
                const name = span.slice(src);

                const attr_model = model: {
                    if (attrs_set.index(name)) |idx| {
                        const model = attrs_set.list[idx].model;
                        break :model model;
                    } else if (Attribute.global.index(name)) |idx| {
                        tabindex |= idx == Attribute.global.comptimeIndex("tabindex");
                        break :model Attribute.global.list[idx].model;
                    } else {
                        if (Attribute.isData(name)) continue;
                        try errors.append(gpa, .{
                            .tag = .invalid_attr,
                            .main_location = span,
                            .node_idx = node_idx,
                        });
                    }
                    continue;
                };

                try attr_model.rule.validate(gpa, errors, src, node_idx, attr);
            }

            break :blk .{
                .content = element.model.content,
                .categories = element.model.categories,
                .extra = .{
                    .tabindex = tabindex,
                },
            };
        },
    };
}

const KindMap = std.StaticStringMapWithEql(
    Ast.Kind,
    std.static_string_map.eqlAsciiIgnoreCase,
);

pub const elements: KindMap = blk: {
    const fields = std.meta.fields(Ast.Kind)[8..];
    assert(std.mem.eql(u8, fields[0].name, "a"));

    const KV = struct { []const u8, Ast.Kind };
    var keys: []const KV = &.{};
    for (fields) |f| keys = keys ++ &[_]KV{.{
        f.name,
        @enumFromInt(f.value),
    }};

    break :blk .initComptime(keys);
};
