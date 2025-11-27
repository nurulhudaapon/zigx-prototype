const std = @import("std");
const fmtlog = std.log.scoped(.cli);
const Writer = std.Io.Writer;

/// AST node for control flow expressions
pub const ExpressionAst = struct {
    kind: Kind,
    source: []const u8,
    start: usize,
    end: usize,

    const Span = struct {
        start: usize,
        end: usize,

        pub fn slice(self: Span, source: []const u8) []const u8 {
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
        condition: Span,
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
        capture: Span,
        body: Span,
    };

    const WhileExpr = struct {
        condition: Span,
        body: Span,
    };

    /// Parse a control flow expression from text
    fn parseOne(allocator: std.mem.Allocator, text: []const u8, start_pos: usize) !?ExpressionAst {
        var i = start_pos;

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
        var i = keyword_end;
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

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
        i += 1;

        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '{') return null;

        i += 1;
        var cases = std.array_list.Managed(SwitchExpr.Case).init(allocator);
        defer cases.deinit();

        var brace_depth: i32 = 1;
        var case_start = i;

        while (i < text.len and brace_depth > 0) {
            if (text[i] == '{') brace_depth += 1;
            if (text[i] == '}') {
                brace_depth -= 1;
                if (brace_depth == 0) break;
            }

            if (text[i] == '=' and i + 1 < text.len and text[i + 1] == '>') {
                const pattern_start = case_start;
                const pattern_end = i;
                i += 2;

                while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;

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
                        value_end = i + 1;
                        i += 1;
                    }
                } else {
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

                if (i < text.len and text[i] == ',') i += 1;
                while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
                case_start = i;
            } else {
                i += 1;
            }
        }

        if (i >= text.len) return null;
        const expr_end = i + 1;

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
        var i = keyword_end;
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

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
        i += 1;

        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

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
        i += 1;

        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        var else_branch: ?Span = null;
        if (i + 4 < text.len and std.mem.eql(u8, text[i .. i + 4], "else")) {
            i += 4;
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
                    i += 1;
                }
            }
        }

        while (i < text.len and text[i] != '}') i += 1;
        if (i >= text.len) return null;
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
        var i = keyword_end;
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

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
        i += 1;

        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '|') return null;
        i += 1;
        const capture_start = i;
        while (i < text.len and text[i] != '|') i += 1;
        if (i >= text.len) return null;
        const capture_end = i;
        i += 1;

        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

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
        i += 1;

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
        var i = keyword_end;
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

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
        i += 1;

        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len or text[i] != '(') return null;

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
        i += 1;

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
};

/// Parse the full HTML and return an array of expression nodes
pub fn parse(allocator: std.mem.Allocator, html: []const u8) ![]ExpressionAst {
    var expressions = std.ArrayList(ExpressionAst){};
    const expr_count = html.len / 10;
    try expressions.ensureTotalCapacity(allocator, expr_count);

    var i: usize = 0;
    while (i < html.len) {
        if (try ExpressionAst.parseOne(allocator, html, i)) |expr| {
            fmtlog.debug("parsed expression {s}: \n```\n{s}\n```", .{ @tagName(expr.kind), expr.source[expr.start..expr.end] });
            try expressions.append(allocator, expr);
            i = expr.end;
        } else {
            i += 1;
        }
    }

    return try expressions.toOwnedSlice(allocator);
}
