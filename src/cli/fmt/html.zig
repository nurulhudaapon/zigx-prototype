const std = @import("std");
const htmlz = @import("htmlz");
// const tracy = @import("tracy");
const fmtlog = std.log.scoped(.fmt);
const Writer = std.Io.Writer;
const assert = std.debug.assert;

pub fn render(ast: htmlz.html.Ast, src: []const u8, w: *Writer) !void {
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
                if (pre > 0) {
                    try w.writeAll(maybe_ws);
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

                        for (0..indentation) |_| {
                            try w.writeAll("\t");
                        }
                    } else if ((last_was_text or current.kind == .text) and maybe_ws.len > 0) {
                        try w.writeAll(" ");
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
                    var tt: htmlz.html.Tokenizer = .{ .language = ast.language };
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
                            var tt: htmlz.html.Tokenizer = .{
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
