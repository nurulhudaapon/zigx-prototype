const std = @import("std");
const htmlz = @import("htmlz");
// const tracy = @import("tracy");
const fmtlog = std.log.scoped(.fmt);
const Writer = std.Io.Writer;
const assert = std.debug.assert;

/// AST node for control flow expressions
const ExpressionAst = struct {
    kind: Kind,
    source: []const u8,
    start: usize,
    end: usize,

    const Kind = union(enum) {
        switch_expr: SwitchExpr,
        if_expr: IfExpr,
        for_expr: ForExpr,
        while_expr: WhileExpr,
        text_expr: void, // Regular {expr}
    };

    const SwitchExpr = struct {
        condition: []const u8, // Text between switch and opening brace
        cases: []Case,
        const Case = struct {
            pattern: []const u8,
            value: []const u8,
        };
    };

    const IfExpr = struct {
        condition: []const u8,
        then_branch: []const u8,
        else_branch: ?[]const u8,
    };

    const ForExpr = struct {
        iterable: []const u8,
        capture: []const u8, // e.g., "|name|"
        body: []const u8,
    };

    const WhileExpr = struct {
        condition: []const u8,
        body: []const u8,
    };

    /// Parse a control flow expression from text
    fn parse(allocator: std.mem.Allocator, text: []const u8) !?ExpressionAst {
        var i: usize = 0;

        // Find opening brace
        while (i < text.len and text[i] != '{') i += 1;
        if (i >= text.len) return null;

        const expr_start = i;
        i += 1; // Skip '{'

        // Skip whitespace
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len) return null;

        // Check for control flow keywords
        const remaining = text[i..];
        if (std.mem.startsWith(u8, remaining, "switch")) {
            return try parseSwitch(allocator, text, expr_start, i + 6);
        } else if (std.mem.startsWith(u8, remaining, "if")) {
            return try parseIf(allocator, text, expr_start, i + 2);
        } else if (std.mem.startsWith(u8, remaining, "for")) {
            return try parseFor(allocator, text, expr_start, i + 3);
        } else if (std.mem.startsWith(u8, remaining, "while")) {
            return try parseWhile(allocator, text, expr_start, i + 5);
        }

        return null;
    }

    fn parseSwitch(allocator: std.mem.Allocator, text: []const u8, start: usize, keyword_end: usize) !?ExpressionAst {
        var i = keyword_end;
        // Skip whitespace
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

        // Find condition: (expr)
        var paren_depth: i32 = 1;
        i += 1;
        const condition_start = i;
        while (i < text.len and paren_depth > 0) {
            if (text[i] == '(') paren_depth += 1;
            if (text[i] == ')') paren_depth -= 1;
            if (paren_depth > 0) i += 1;
        }
        if (i >= text.len) return null;
        const condition_end = i;
        i += 1; // Skip ')'

        // Skip whitespace
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '{') return null;

        // Find cases: { case => value, ... }
        i += 1; // Skip '{'
        var cases = std.array_list.Managed(SwitchExpr.Case).init(allocator);
        defer cases.deinit();

        var brace_depth: i32 = 1;
        var case_start = i;

        while (i < text.len and brace_depth > 0) {
            if (text[i] == '{') brace_depth += 1;
            if (text[i] == '}') {
                brace_depth -= 1;
                if (brace_depth == 0) {
                    // End of switch block
                    break;
                }
            }

            // Look for case pattern => value
            if (text[i] == '=' and i + 1 < text.len and text[i + 1] == '>') {
                const pattern = std.mem.trim(u8, text[case_start..i], &std.ascii.whitespace);
                i += 2; // Skip '=>'

                // Skip whitespace
                while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;

                // Find value (could be in parens or just text)
                const value_start = i;
                var temp_paren_depth: i32 = 0;
                var value_end = i;
                if (i < text.len and text[i] == '(') {
                    temp_paren_depth = 1;
                    i += 1;
                    while (i < text.len and temp_paren_depth > 0) {
                        if (text[i] == '(') temp_paren_depth += 1;
                        if (text[i] == ')') temp_paren_depth -= 1;
                        if (temp_paren_depth > 0) i += 1;
                    }
                    if (i < text.len) {
                        value_end = i + 1; // Include ')'
                        i += 1;
                    }
                } else {
                    // Find end of value (comma or closing brace)
                    while (i < text.len) {
                        if (text[i] == ',' or text[i] == '}') {
                            value_end = i;
                            break;
                        }
                        i += 1;
                    }
                    if (i >= text.len) value_end = text.len;
                }
                // Extract value without outer parentheses if present
                var value = std.mem.trim(u8, text[value_start..value_end], &std.ascii.whitespace);
                // Remove outer parentheses if they wrap the entire value
                if (value.len >= 2 and value[0] == '(' and value[value.len - 1] == ')') {
                    // Check if it's balanced parentheses
                    var depth: i32 = 0;
                    var is_balanced = true;
                    for (value, 0..) |c, idx| {
                        if (c == '(') depth += 1;
                        if (c == ')') depth -= 1;
                        if (idx < value.len - 1 and depth == 0) {
                            is_balanced = false;
                            break;
                        }
                    }
                    if (is_balanced and depth == 0) {
                        value = value[1 .. value.len - 1]; // Remove outer parentheses
                    }
                }

                try cases.append(.{
                    .pattern = pattern,
                    .value = value,
                });

                // Skip comma if present
                if (i < text.len and text[i] == ',') i += 1;
                // Skip whitespace
                while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
                case_start = i;
            } else {
                i += 1;
            }
        }

        if (i >= text.len) return null;
        const expr_end = i + 1; // Include '}'

        return ExpressionAst{
            .kind = .{ .switch_expr = .{
                .condition = text[condition_start..condition_end],
                .cases = try cases.toOwnedSlice(),
            } },
            .source = text,
            .start = start,
            .end = expr_end,
        };
    }

    fn parseIf(allocator: std.mem.Allocator, text: []const u8, start: usize, keyword_end: usize) !?ExpressionAst {
        _ = allocator;
        var i = keyword_end;
        // Skip whitespace
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

        // Find condition: (expr)
        var paren_depth: i32 = 1;
        i += 1;
        const condition_start = i;
        while (i < text.len and paren_depth > 0) {
            if (text[i] == '(') paren_depth += 1;
            if (text[i] == ')') paren_depth -= 1;
            if (paren_depth > 0) i += 1;
        }
        if (i >= text.len) return null;
        const condition_end = i;
        i += 1; // Skip ')'

        // Skip whitespace
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

        // Find then branch: (value)
        paren_depth = 1;
        i += 1;
        const then_start = i;
        while (i < text.len and paren_depth > 0) {
            if (text[i] == '(') paren_depth += 1;
            if (text[i] == ')') paren_depth -= 1;
            if (paren_depth > 0) i += 1;
        }
        if (i >= text.len) return null;
        const then_end = i;
        i += 1; // Skip ')'

        // Check for else
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        var else_branch: ?[]const u8 = null;
        if (i + 4 < text.len and std.mem.eql(u8, text[i .. i + 4], "else")) {
            i += 4; // Skip "else"
            while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
            if (i < text.len and text[i] == '(') {
                paren_depth = 1;
                i += 1;
                const else_start = i;
                while (i < text.len and paren_depth > 0) {
                    if (text[i] == '(') paren_depth += 1;
                    if (text[i] == ')') paren_depth -= 1;
                    if (paren_depth > 0) i += 1;
                }
                if (i < text.len) {
                    const else_end = i;
                    else_branch = text[else_start..else_end];
                    i += 1; // Skip ')'
                }
            }
        }

        // Find closing brace
        while (i < text.len and text[i] != '}') i += 1;
        const expr_end = if (i < text.len) i + 1 else text.len;

        return ExpressionAst{
            .kind = .{ .if_expr = .{
                .condition = text[condition_start..condition_end],
                .then_branch = text[then_start..then_end],
                .else_branch = else_branch,
            } },
            .source = text,
            .start = start,
            .end = expr_end,
        };
    }

    fn parseFor(allocator: std.mem.Allocator, text: []const u8, start: usize, keyword_end: usize) !?ExpressionAst {
        _ = allocator;
        var i = keyword_end;
        // Skip whitespace
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

        // Find iterable: (expr)
        var paren_depth: i32 = 1;
        i += 1;
        const iterable_start = i;
        while (i < text.len and paren_depth > 0) {
            if (text[i] == '(') paren_depth += 1;
            if (text[i] == ')') paren_depth -= 1;
            if (paren_depth > 0) i += 1;
        }
        if (i >= text.len) return null;
        const iterable_end = i;
        i += 1; // Skip ')'

        // Find capture: |name|
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '|') return null;
        i += 1; // Skip '|'
        const capture_start = i;
        while (i < text.len and text[i] != '|') i += 1;
        if (i >= text.len) return null;
        const capture_end = i;
        i += 1; // Skip '|'

        // Skip whitespace
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

        // Find body: (value)
        paren_depth = 1;
        i += 1;
        const body_start = i;
        while (i < text.len and paren_depth > 0) {
            if (text[i] == '(') paren_depth += 1;
            if (text[i] == ')') paren_depth -= 1;
            if (paren_depth > 0) i += 1;
        }
        if (i >= text.len) return null;
        const body_end = i;
        i += 1; // Skip ')'

        // Find closing brace
        while (i < text.len and text[i] != '}') i += 1;
        const expr_end = if (i < text.len) i + 1 else text.len;

        return ExpressionAst{
            .kind = .{ .for_expr = .{
                .iterable = text[iterable_start..iterable_end],
                .capture = text[capture_start..capture_end],
                .body = text[body_start..body_end],
            } },
            .source = text,
            .start = start,
            .end = expr_end,
        };
    }

    fn parseWhile(allocator: std.mem.Allocator, text: []const u8, start: usize, keyword_end: usize) !?ExpressionAst {
        _ = allocator;
        var i = keyword_end;
        // Skip whitespace
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

        // Find condition: (expr)
        var paren_depth: i32 = 1;
        i += 1;
        const condition_start = i;
        while (i < text.len and paren_depth > 0) {
            if (text[i] == '(') paren_depth += 1;
            if (text[i] == ')') paren_depth -= 1;
            if (paren_depth > 0) i += 1;
        }
        if (i >= text.len) return null;
        const condition_end = i;
        i += 1; // Skip ')'

        // Skip whitespace
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

        // Find body: (value)
        paren_depth = 1;
        i += 1;
        const body_start = i;
        while (i < text.len and paren_depth > 0) {
            if (text[i] == '(') paren_depth += 1;
            if (text[i] == ')') paren_depth -= 1;
            if (paren_depth > 0) i += 1;
        }
        if (i >= text.len) return null;
        const body_end = i;
        i += 1; // Skip ')'

        // Find closing brace
        while (i < text.len and text[i] != '}') i += 1;
        const expr_end = if (i < text.len) i + 1 else text.len;

        return ExpressionAst{
            .kind = .{ .while_expr = .{
                .condition = text[condition_start..condition_end],
                .body = text[body_start..body_end],
            } },
            .source = text,
            .start = start,
            .end = expr_end,
        };
    }

    /// Render the expression with proper formatting
    fn render(self: ExpressionAst, base_indent: u32, w: *Writer) !void {
        switch (self.kind) {
            .switch_expr => |switch_expr| {
                try w.writeAll("{switch (");
                try w.writeAll(switch_expr.condition);
                try w.writeAll(") {\n");

                for (switch_expr.cases) |case| {
                    for (0..base_indent + 2) |_| {
                        try w.writeAll("\t");
                    }
                    try w.writeAll(case.pattern);
                    try w.writeAll(" => (");
                    try formatBlockContent(case.value, base_indent + 2, w);
                    try w.writeAll("),\n");
                }

                for (0..base_indent + 1) |_| {
                    try w.writeAll("\t");
                }
                try w.writeAll("}}");
            },
            .if_expr => |if_expr| {
                try w.writeAll("{if (");
                try w.writeAll(if_expr.condition);
                try w.writeAll(") (\n");
                try formatBlockContent(if_expr.then_branch, base_indent + 2, w);
                try w.writeAll("\n");
                for (0..base_indent + 1) |_| {
                    try w.writeAll("\t");
                }
                if (if_expr.else_branch) |else_branch| {
                    try w.writeAll(") else (\n");
                    try formatBlockContent(else_branch, base_indent + 2, w);
                    try w.writeAll("\n");
                    for (0..base_indent + 1) |_| {
                        try w.writeAll("\t");
                    }
                }
                try w.writeAll(")}");
            },
            .for_expr => |for_expr| {
                try w.writeAll("{for (");
                try w.writeAll(for_expr.iterable);
                try w.writeAll(") |");
                try w.writeAll(for_expr.capture);
                try w.writeAll("| (\n");
                try formatBlockContent(for_expr.body, base_indent + 2, w);
                try w.writeAll("\n");
                for (0..base_indent + 1) |_| {
                    try w.writeAll("\t");
                }
                try w.writeAll(")}");
            },
            .while_expr => |while_expr| {
                try w.writeAll("{while (");
                try w.writeAll(while_expr.condition);
                try w.writeAll(") (\n");
                try formatBlockContent(while_expr.body, base_indent + 2, w);
                try w.writeAll("\n");
                for (0..base_indent + 1) |_| {
                    try w.writeAll("\t");
                }
                try w.writeAll(")}");
            },
            .text_expr => {
                try w.writeAll(self.source[self.start..self.end]);
            },
        }
    }
};

/// Format content inside a block with proper indentation
fn formatBlockContent(content: []const u8, indent_level: u32, w: *Writer) !void {
    var it = std.mem.splitScalar(u8, content, '\n');
    var first = true;

    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            if (!first) {
                try w.writeAll("\n");
            }
            first = false;
            continue;
        }

        if (!first) {
            try w.writeAll("\n");
        }
        for (0..indent_level) |_| {
            try w.writeAll("\t");
        }
        try w.writeAll(trimmed);
        first = false;
    }
}

/// Check if text contains a control flow expression
fn hasControlFlow(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '{') {
            var j = i + 1;
            // Skip whitespace
            while (j < text.len and std.ascii.isWhitespace(text[j])) {
                j += 1;
            }
            // Check for control flow keywords
            const remaining = text[j..];
            if (std.mem.startsWith(u8, remaining, "switch") or
                std.mem.startsWith(u8, remaining, "if") or
                std.mem.startsWith(u8, remaining, "for") or
                std.mem.startsWith(u8, remaining, "while"))
            {
                return true;
            }
        }
        i += 1;
    }
    return false;
}

/// Format text that may contain control flow expressions (switch, if, for, while)
/// by applying proper indentation to the content inside them.
fn formatControlFlowText(
    allocator: std.mem.Allocator,
    text: []const u8,
    base_indent: u32,
    w: *Writer,
) !void {
    fmtlog.debug("formatControlFlowText: text length = {}, base_indent = {}", .{ text.len, base_indent });
    fmtlog.debug("formatControlFlowText: text content = '{s}'", .{text});

    if (!hasControlFlow(text)) {
        // No control flow, just write as-is
        try w.writeAll(text);
        return;
    }

    // Try to parse as control flow expression
    if (try ExpressionAst.parse(allocator, text)) |expr_ast| {
        // Successfully parsed, render it
        try expr_ast.render(base_indent, w);
        // Free allocated memory
        switch (expr_ast.kind) {
            .switch_expr => |switch_expr| {
                allocator.free(switch_expr.cases);
            },
            else => {},
        }
    } else {
        // Failed to parse, write as-is
        try w.writeAll(text);
    }
}

pub fn render(allocator: std.mem.Allocator, ast: htmlz.html.Ast, src: []const u8, w: *Writer) !void {
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
                        // Check if text contains control flow expressions
                        if (hasControlFlow(txt)) {
                            fmtlog.debug("text contains control flow, using formatControlFlowText", .{});
                            try formatControlFlowText(allocator, txt, indentation, w);
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
