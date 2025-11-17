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

    const Span = struct {
        start: usize,
        end: usize,

        fn slice(self: Span, source: []const u8) []const u8 {
            return source[self.start..self.end];
        }
    };

    const Kind = union(enum) {
        switch_expr: SwitchExpr,
        if_expr: IfExpr,
        for_expr: ForExpr,
        while_expr: WhileExpr,
        text_expr: void, // Regular {expr}
    };

    const SwitchExpr = struct {
        condition: Span, // Text between switch and opening brace
        cases: []Case,
        const Case = struct {
            pattern: Span,
            value: Span,
        };
    };

    const IfExpr = struct {
        condition: Span,
        then_branch: Span,
        else_branch: ?Span,
    };

    const ForExpr = struct {
        iterable: Span,
        capture: Span, // e.g., "|name|"
        body: Span,
    };

    const WhileExpr = struct {
        condition: Span,
        body: Span,
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
            return try parseIf(text, expr_start, i + 2);
        } else if (std.mem.startsWith(u8, remaining, "for")) {
            return try parseFor(text, expr_start, i + 3);
        } else if (std.mem.startsWith(u8, remaining, "while")) {
            return try parseWhile(text, expr_start, i + 5);
        }

        return null;
    }

    fn parseSwitch(allocator: std.mem.Allocator, text: []const u8, start: usize, keyword_end: usize) !?ExpressionAst {
        fmtlog.debug("parseSwitch: text = '{s}'", .{text});
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
                // Store pattern span (before trimming)
                const pattern_start = case_start;
                const pattern_end = i;
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

                try cases.append(.{
                    .pattern = .{ .start = pattern_start, .end = pattern_end },
                    .value = .{ .start = value_start, .end = value_end },
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
                .condition = .{ .start = condition_start, .end = condition_end },
                .cases = try cases.toOwnedSlice(),
            } },
            .source = text,
            .start = start,
            .end = expr_end,
        };
    }

    fn parseIf(text: []const u8, start: usize, keyword_end: usize) !?ExpressionAst {
        fmtlog.debug("parseIf: text = '{s}', start = {}, keyword_end = {}", .{ text, start, keyword_end });
        var i = keyword_end;
        // Skip whitespace
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len) {
            fmtlog.debug("parseIf: failed at check 1: i >= text.len (i={}, text.len={})", .{ i, text.len });
            return null;
        }
        if (text[i] != '(') {
            fmtlog.debug("parseIf: failed at check 2: text[i] != '(', text[i] = '{c}'", .{text[i]});
            return null;
        }

        // Find condition: (expr)
        var paren_depth: i32 = 1;
        i += 1;
        const condition_start = i;
        while (i < text.len and paren_depth > 0) {
            if (text[i] == '(') paren_depth += 1;
            if (text[i] == ')') paren_depth -= 1;
            if (paren_depth > 0) i += 1;
        }
        if (i >= text.len) {
            fmtlog.debug("parseIf: failed at check 3: condition not closed (i={}, text.len={})", .{ i, text.len });
            return null;
        }
        const condition_end = i;
        i += 1; // Skip ')'
        fmtlog.debug("parseIf: condition found: '{s}'", .{text[condition_start..condition_end]});

        // Skip whitespace
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len) {
            fmtlog.debug("parseIf: failed at check 4: i >= text.len after condition (i={}, text.len={})", .{ i, text.len });
            return null;
        }
        if (text[i] != '(') {
            const remaining_text = if (i < text.len) text[i..] else "";
            fmtlog.debug("parseIf: failed at check 5: then branch doesn't start with '(', text[i] = '{c}', remaining = '{s}'", .{ text[i], remaining_text });
            return null;
        }

        // Find then branch: (value)
        paren_depth = 1;
        i += 1;
        const then_start = i;
        while (i < text.len and paren_depth > 0) {
            if (text[i] == '(') paren_depth += 1;
            if (text[i] == ')') paren_depth -= 1;
            if (paren_depth > 0) i += 1;
        }
        if (i >= text.len) {
            fmtlog.debug("parseIf: failed at check 6: then branch not closed (i={}, text.len={}, paren_depth={})", .{ i, text.len, paren_depth });
            return null;
        }
        const then_end = i;
        i += 1; // Skip ')'
        fmtlog.debug("parseIf: then_branch found: '{s}'", .{text[then_start..then_end]});

        // Check for else
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        var else_branch: ?Span = null;
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
                    else_branch = .{ .start = else_start, .end = else_end };
                    i += 1; // Skip ')'
                    fmtlog.debug("parseIf: else_branch found: '{s}'", .{text[else_start..else_end]});
                }
            }
        }

        // Find closing brace
        while (i < text.len and text[i] != '}') i += 1;
        if (i >= text.len) {
            fmtlog.debug("parseIf: failed at check 7: closing brace not found (i={}, text.len={})", .{ i, text.len });
            return null;
        }
        const expr_end = i + 1;

        return ExpressionAst{
            .kind = .{ .if_expr = .{
                .condition = .{ .start = condition_start, .end = condition_end },
                .then_branch = .{ .start = then_start, .end = then_end },
                .else_branch = else_branch,
            } },
            .source = text,
            .start = start,
            .end = expr_end,
        };
    }

    fn parseFor(text: []const u8, start: usize, keyword_end: usize) !?ExpressionAst {
        fmtlog.debug("parseFor: text = '{s}'", .{text});
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
                .iterable = .{ .start = iterable_start, .end = iterable_end },
                .capture = .{ .start = capture_start, .end = capture_end },
                .body = .{ .start = body_start, .end = body_end },
            } },
            .source = text,
            .start = start,
            .end = expr_end,
        };
    }

    fn parseWhile(text: []const u8, start: usize, keyword_end: usize) !?ExpressionAst {
        fmtlog.debug("parseWhile: text = '{s}'", .{text});
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
                .condition = .{ .start = condition_start, .end = condition_end },
                .body = .{ .start = body_start, .end = body_end },
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
                try w.writeAll(switch_expr.condition.slice(self.source));
                try w.writeAll(") {\n");

                for (switch_expr.cases) |case| {
                    for (0..base_indent + 1) |_| {
                        try w.writeAll("\t");
                    }
                    // Trim pattern from original source
                    const pattern_text = std.mem.trim(u8, case.pattern.slice(self.source), &std.ascii.whitespace);
                    try w.writeAll(pattern_text);
                    try w.writeAll(" => (");
                    // Extract value from original source
                    var value_text = case.value.slice(self.source);
                    // Trim and remove outer parentheses if present (matching original logic)
                    value_text = std.mem.trim(u8, value_text, &std.ascii.whitespace);
                    if (value_text.len >= 2 and value_text[0] == '(' and value_text[value_text.len - 1] == ')') {
                        // Check if it's balanced parentheses
                        var depth: i32 = 0;
                        var is_balanced = true;
                        for (value_text, 0..) |c, idx| {
                            if (c == '(') depth += 1;
                            if (c == ')') depth -= 1;
                            if (idx < value_text.len - 1 and depth == 0) {
                                is_balanced = false;
                                break;
                            }
                        }
                        if (is_balanced and depth == 0) {
                            value_text = value_text[1 .. value_text.len - 1]; // Remove outer parentheses
                        }
                    }
                    // Check if value is a simple single-line value (no newlines)
                    const trimmed_value = std.mem.trim(u8, value_text, &std.ascii.whitespace);
                    if (std.mem.indexOfScalar(u8, trimmed_value, '\n') == null) {
                        // Simple single-line value, write directly without extra indentation
                        try w.writeAll(trimmed_value);
                    } else {
                        // Multi-line value, format with indentation
                        try formatBlockContent(value_text, base_indent + 2, w);
                    }
                    try w.writeAll("),\n");
                }

                for (0..base_indent) |_| {
                    try w.writeAll("\t");
                }
                try w.writeAll("}}");
            },
            .if_expr => |if_expr| {
                try w.writeAll("{if (");
                try w.writeAll(if_expr.condition.slice(self.source));
                try w.writeAll(") (\n");
                try formatBlockContent(if_expr.then_branch.slice(self.source), base_indent + 2, w);
                try w.writeAll("\n");
                for (0..base_indent + 1) |_| {
                    try w.writeAll("\t");
                }
                if (if_expr.else_branch) |else_branch| {
                    try w.writeAll(") else (\n");
                    try formatBlockContent(else_branch.slice(self.source), base_indent + 2, w);
                    try w.writeAll("\n");
                    for (0..base_indent + 1) |_| {
                        try w.writeAll("\t");
                    }
                }
                try w.writeAll(")}");
            },
            .for_expr => |for_expr| {
                try w.writeAll("{for (");
                try w.writeAll(for_expr.iterable.slice(self.source));
                try w.writeAll(") |");
                try w.writeAll(for_expr.capture.slice(self.source));
                try w.writeAll("| (\n");
                try formatBlockContent(for_expr.body.slice(self.source), base_indent + 2, w);
                try w.writeAll("\n");
                for (0..base_indent + 1) |_| {
                    try w.writeAll("\t");
                }
                try w.writeAll(")}");
            },
            .while_expr => |while_expr| {
                try w.writeAll("{while (");
                try w.writeAll(while_expr.condition.slice(self.source));
                try w.writeAll(") (\n");
                try formatBlockContent(while_expr.body.slice(self.source), base_indent + 2, w);
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

    fmtlog.debug("formatBlockContent: content = '{s}'", .{content});
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
                fmtlog.debug("hasControlFlow: found control flow keyword: {s}", .{remaining});
                return true;
            }
        }
        i += 1;
    }
    return false;
}

/// Find the full expression span in the source, starting from a given position
/// Returns the start and end positions of the complete expression (including the closing '}')
fn findFullExpressionSpan(src: []const u8, start_pos: usize) ?struct { start: usize, end: usize } {
    if (start_pos >= src.len or src[start_pos] != '{') return null;

    var i = start_pos + 1; // Skip opening '{'
    var brace_depth: i32 = 1;

    while (i < src.len and brace_depth > 0) {
        if (src[i] == '{') brace_depth += 1;
        if (src[i] == '}') brace_depth -= 1;
        if (brace_depth > 0) i += 1;
    }

    if (brace_depth == 0 and i < src.len) {
        return .{ .start = start_pos, .end = i + 1 }; // Include closing '}'
    }

    return null;
}

/// Format text that may contain control flow expressions (switch, if, for, while)
/// by applying proper indentation to the content inside them.
/// Note: This function may receive partial content when expressions span multiple text nodes
/// (e.g., when HTML elements are inside the expression).
/// If full_source and text_start_pos are provided, it will try to reconstruct the full expression.
fn formatControlFlowText(
    allocator: std.mem.Allocator,
    text: []const u8,
    base_indent: u32,
    w: *Writer,
    full_source: ?[]const u8,
    text_start_pos: ?usize,
) !void {
    fmtlog.debug("formatControlFlowText: text length = {}, base_indent = {}", .{ text.len, base_indent });
    fmtlog.debug("formatControlFlowText: text content = '{s}'", .{text});

    // Analyze the text to understand its structure
    const trimmed = std.mem.trimRight(u8, text, &std.ascii.whitespace);
    const starts_with_brace = text.len > 0 and text[0] == '{';
    const ends_with_brace = trimmed.len > 0 and trimmed[trimmed.len - 1] == '}';
    const has_opening_brace = std.mem.indexOfScalar(u8, text, '{') != null;
    const has_closing_brace = std.mem.indexOfScalar(u8, text, '}') != null;
    const brace_count = std.mem.count(u8, text, "{");
    const closing_brace_count = std.mem.count(u8, text, "}");

    fmtlog.debug("formatControlFlowText: analysis - starts_with_brace={}, ends_with_brace={}, has_opening={}, has_closing={}, brace_count={}, closing_count={}", .{
        starts_with_brace,
        ends_with_brace,
        has_opening_brace,
        has_closing_brace,
        brace_count,
        closing_brace_count,
    });

    // Check if this looks like part of a control flow expression even without keywords
    const looks_like_control_flow_part =
        std.mem.startsWith(u8, std.mem.trimLeft(u8, text, &std.ascii.whitespace), ") else (") or
        std.mem.startsWith(u8, std.mem.trimLeft(u8, text, &std.ascii.whitespace), ") }") or
        (!starts_with_brace and ends_with_brace and !has_opening_brace); // ends with } but no {

    if (!hasControlFlow(text) and !looks_like_control_flow_part) {
        // No control flow, just write as-is
        fmtlog.debug("formatControlFlowText: no control flow detected and doesn't look like part of expression, writing as-is", .{});
        try w.writeAll(text);
        return;
    }

    if (!hasControlFlow(text) and looks_like_control_flow_part) {
        fmtlog.debug("formatControlFlowText: looks like part of control flow expression but no keywords, treating as partial", .{});
        // Fall through to handle as partial
    }

    // Strategy: Handle different cases of partial/complete expressions
    // Case 1: Complete expression (starts with { and ends with })
    if (starts_with_brace and ends_with_brace) {
        fmtlog.debug("formatControlFlowText: appears to be complete expression, attempting to parse", .{});
        if (try ExpressionAst.parse(allocator, text)) |expr_ast| {
            fmtlog.debug("formatControlFlowText: successfully parsed as control flow expression {s}", .{@tagName(expr_ast.kind)});
            try expr_ast.render(base_indent, w);
            switch (expr_ast.kind) {
                .switch_expr => |switch_expr| {
                    fmtlog.debug("formatControlFlowText: freeing switch_expr.cases", .{});
                    allocator.free(switch_expr.cases);
                },
                else => {},
            }
            return;
        } else {
            fmtlog.debug("formatControlFlowText: failed to parse complete expression, writing as-is", .{});
            try w.writeAll(text);
            return;
        }
    }

    // Case 2: Starts with { but doesn't end with } - likely start of expression
    // Try to reconstruct the full expression from the source
    if (starts_with_brace and !ends_with_brace) {
        fmtlog.debug("formatControlFlowText: starts with brace but doesn't end with brace - attempting to reconstruct full expression", .{});

        if (full_source) |src| {
            if (text_start_pos) |start_pos| {
                if (findFullExpressionSpan(src, start_pos)) |span| {
                    const full_expr = src[span.start..span.end];
                    fmtlog.debug("formatControlFlowText: found full expression in source: '{s}'", .{full_expr});

                    // Try to parse the full expression
                    if (try ExpressionAst.parse(allocator, full_expr)) |expr_ast| {
                        fmtlog.debug("formatControlFlowText: successfully parsed full expression {s}", .{@tagName(expr_ast.kind)});
                        try expr_ast.render(base_indent, w);
                        switch (expr_ast.kind) {
                            .switch_expr => |switch_expr| {
                                fmtlog.debug("formatControlFlowText: freeing switch_expr.cases", .{});
                                allocator.free(switch_expr.cases);
                            },
                            else => {},
                        }
                        return;
                    } else {
                        fmtlog.debug("formatControlFlowText: failed to parse full expression, writing partial as-is", .{});
                    }
                } else {
                    fmtlog.debug("formatControlFlowText: couldn't find full expression span in source", .{});
                }
            }
        }

        // Fallback: write as-is if we can't reconstruct
        fmtlog.debug("formatControlFlowText: writing partial expression as-is", .{});
        try w.writeAll(text);
        return;
    }

    // Case 3: Doesn't start with { but ends with } - likely end of expression
    if (!starts_with_brace and ends_with_brace) {
        fmtlog.debug("formatControlFlowText: ends with brace but doesn't start with brace - likely end of expression split across nodes", .{});
        // This is the closing part of an expression, write it as-is
        fmtlog.debug("formatControlFlowText: writing closing part as-is", .{});
        try w.writeAll(text);
        return;
    }

    // Case 4: Looks like middle part of control flow (e.g., ") else (")
    const trimmed_left = std.mem.trimLeft(u8, text, &std.ascii.whitespace);
    if (std.mem.startsWith(u8, trimmed_left, ") else (") or
        std.mem.startsWith(u8, trimmed_left, ") }"))
    {
        fmtlog.debug("formatControlFlowText: appears to be middle part of control flow expression (e.g., ') else (')", .{});
        fmtlog.debug("formatControlFlowText: writing as-is", .{});
        try w.writeAll(text);
        return;
    }

    // Case 5: Contains braces but neither starts nor ends with them - middle part of expression
    if (has_opening_brace or has_closing_brace) {
        fmtlog.debug("formatControlFlowText: contains braces but is partial - middle part of expression", .{});
        fmtlog.debug("formatControlFlowText: writing as-is", .{});
        try w.writeAll(text);
        return;
    }

    // Case 6: Has control flow keyword but no braces visible - might be in the middle
    fmtlog.debug("formatControlFlowText: has control flow keyword but unclear structure, writing as-is", .{});
    try w.writeAll(text);
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
    // Track the end position of the last processed control flow expression
    // Text nodes that start before this position are part of an already-processed expression
    var last_processed_expr_end: ?usize = null;
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
                fmtlog.debug("processing text node: txt = '{s}' (len={}), start={}, end={}", .{ txt, txt.len, current.open.start, current.open.end });

                // Skip if this text node is part of an already-processed expression
                if (last_processed_expr_end) |expr_end| {
                    if (current.open.start < expr_end) {
                        fmtlog.debug("skipping text node - part of already-processed expression (start={} < expr_end={})", .{ current.open.start, expr_end });
                        last_rbracket = current.open.end;
                        if (current.next_idx != 0) {
                            current = ast.nodes[current.next_idx];
                        } else {
                            current = ast.nodes[current.parent_idx];
                            direction = .exit;
                        }
                        continue;
                    } else {
                        // We've passed the processed expression, reset
                        last_processed_expr_end = null;
                    }
                }

                const parent_kind = ast.nodes[current.parent_idx].kind;
                switch (parent_kind) {
                    else => blk: {
                        if (pre > 0) {
                            try w.writeAll(txt);
                            break :blk;
                        }
                        // Check if text contains control flow expressions or is part of one
                        // This includes:
                        // 1. Text that starts with { and has control flow keywords (complete or partial)
                        // 2. Text that looks like part of a control flow expression (e.g., ") else (", ")}")
                        const txt_trimmed_left = std.mem.trimLeft(u8, txt, &std.ascii.whitespace);
                        const txt_trimmed_right = std.mem.trimRight(u8, txt, &std.ascii.whitespace);
                        const is_control_flow = hasControlFlow(txt) or
                            std.mem.startsWith(u8, txt_trimmed_left, ") else (") or
                            std.mem.startsWith(u8, txt_trimmed_left, ") }") or
                            (txt_trimmed_right.len > 0 and
                                txt_trimmed_right[txt_trimmed_right.len - 1] == '}' and
                                std.mem.indexOfScalar(u8, txt, '{') == null); // ends with } but doesn't contain {

                        // Only process if it's the start of an expression (has control flow keyword and starts with {)
                        // Other parts will be handled when we process the start
                        const starts_with_brace_after_trim = txt_trimmed_left.len > 0 and txt_trimmed_left[0] == '{';
                        if (is_control_flow and hasControlFlow(txt) and starts_with_brace_after_trim) {
                            fmtlog.debug("text appears to be start of control flow expression, using formatControlFlowText txt = '{s}'", .{txt});
                            // Try to find and process the full expression
                            if (findFullExpressionSpan(src, current.open.start)) |span| {
                                const full_expr = src[span.start..span.end];
                                fmtlog.debug("found full expression span: start={}, end={}, expr='{s}'", .{ span.start, span.end, full_expr });

                                if (try ExpressionAst.parse(allocator, full_expr)) |expr_ast| {
                                    fmtlog.debug("successfully parsed full expression {s}", .{@tagName(expr_ast.kind)});
                                    try expr_ast.render(indentation, w);
                                    // Mark that we've processed this expression
                                    last_processed_expr_end = span.end;
                                    switch (expr_ast.kind) {
                                        .switch_expr => |switch_expr| {
                                            allocator.free(switch_expr.cases);
                                        },
                                        else => {},
                                    }
                                    break :blk;
                                }
                            }
                            // Fallback: try formatControlFlowText
                            try formatControlFlowText(allocator, txt, indentation, w, src, current.open.start);
                            break :blk;
                        } else if (is_control_flow and !hasControlFlow(txt)) {
                            // This is a middle/end part - should be skipped if we processed the start
                            // But if we didn't process the start, write it as-is
                            fmtlog.debug("text is middle/end part of control flow expression", .{});
                            try w.writeAll(txt);
                            break :blk;
                        }
                        fmtlog.debug("text node doesn't contain control flow, processing normally", .{});
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
