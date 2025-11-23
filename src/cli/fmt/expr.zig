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

    /// Detect indentation level at a given position in source
    fn detectIndentAt(source: []const u8, pos: usize) u32 {
        if (pos == 0) return 0;

        // Find start of line
        var line_start = pos;
        while (line_start > 0 and source[line_start - 1] != '\n') {
            line_start -= 1;
        }

        // Count indentation from line start
        var indent: u32 = 0;
        var i = line_start;
        while (i < pos and i < source.len) {
            if (source[i] == ' ') {
                indent += 1;
            } else if (source[i] == '\t') {
                indent += 4; // Treat tab as 4 spaces
            } else {
                break;
            }
            i += 1;
        }

        return @divTrunc(indent, 4);
    }

    /// Render the expression with proper formatting
    pub fn render(self: ExpressionAst, w: *Writer) !void {
        fmtlog.debug("rendering expression {s}: \n```\n{s}\n```", .{ @tagName(self.kind), self.source[self.start..self.end] });
        switch (self.kind) {
            .switch_expr => |switch_expr| {
                var i = switch_expr.condition.end;
                while (i < self.source.len and self.source[i] != '{') {
                    i += 1;
                }
                const brace_start = i;

                try w.writeAll(self.source[self.start .. brace_start + 1]);
                try w.writeAll("\n");

                for (switch_expr.cases) |case| {
                    const case_content_raw = case.value.slice(self.source);
                    const is_multiline_case = std.mem.count(u8, case_content_raw, "\n") > 0;
                    const case_pattern = case.pattern.slice(self.source);
                    const case_content = self.source[case.value.start + 1 .. case.value.end - 1];
                    const case_full_content = self.source[case.value.start..case.value.end];

                    if (is_multiline_case) {
                        fmtlog.debug("case: '{s}'", .{case.value.slice(self.source)});

                        try indentContent(case_pattern, 3, w);
                        try w.writeAll(" => ");

                        try w.writeAll("(\n");

                        try indentContent(case_content, 4, w);
                        try indentContent(")", 3, w);
                    } else {
                        try indentContent(case_pattern, 3, w);
                        try w.writeAll(" => ");
                        try w.writeAll(case_full_content);
                    }
                    try w.writeAll("\n");
                }

                try indentContent("}", 2, w);
            },
            .if_expr => |if_expr| {
                const before_then = self.source[self.start..if_expr.then_branch.start];
                fmtlog.debug("before_then: '{s}'", .{before_then});
                try w.writeAll(before_then);
                try w.writeAll("\n");

                const then_content = if_expr.then_branch.slice(self.source);
                fmtlog.debug("then_content: '{s}'", .{then_content});
                try indentContent(then_content, 2, w);

                const indent = detectIndentAt(self.source, self.start);
                for (0..indent) |_| {
                    try w.writeAll(" ");
                }
                try w.writeAll(")");

                if (if_expr.else_branch) |else_branch| {
                    // Write " else (" with proper formatting
                    try w.writeAll(" else (");
                    try w.writeAll("\n");

                    const else_content = else_branch.slice(self.source);
                    try indentContent(else_content, 2, w);

                    for (0..indent) |_| {
                        try w.writeAll(" ");
                    }
                    try w.writeAll(")");
                }

                try w.writeAll("}");
            },
            .for_expr => |for_expr| {
                const base_indent = detectIndentAt(self.source, self.start);
                fmtlog.debug("base_indent: {d}", .{base_indent});
                const before_body = self.source[self.start..for_expr.body.start];
                const body_content = for_expr.body.slice(self.source);
                const after_body = self.source[for_expr.body.end..self.end];

                const is_multiline_body = std.mem.count(u8, body_content, "\n") > 0;

                if (is_multiline_body) {
                    fmtlog.debug("before_body: '{s}'", .{before_body});
                    try w.writeAll(before_body);
                    try w.writeAll("\n");

                    try indentContent(body_content, base_indent + 2, w);

                    // Write closing ) and } with proper indentation
                    try w.writeAll("\n");
                    const indent = detectIndentAt(self.source, self.start);
                    for (0..indent) |_| {
                        try w.writeAll(" ");
                    }
                    try indentContent(after_body, 1, w);
                } else {
                    try w.writeAll(before_body);
                    try w.writeAll(body_content);
                    try w.writeAll(after_body);
                }
            },
            .while_expr => |while_expr| {
                const before_body = self.source[self.start..while_expr.body.start];
                try w.writeAll(before_body);
                try w.writeAll("\n");

                const body_content = while_expr.body.slice(self.source);
                try indentContent(body_content, 1, w);

                const after_body = self.source[while_expr.body.end..self.end];
                // Write closing ) and } with proper indentation
                try w.writeAll("\n");
                const indent = detectIndentAt(self.source, self.start);
                for (0..indent) |_| {
                    try w.writeAll(" ");
                }
                try w.writeAll(after_body);
            },
            .text_expr => {
                try w.writeAll(self.source[self.start..self.end]);
            },
        }
    }

    /// Detect the minimum indentation level in the content (in spaces, treating tabs as 4 spaces)
    fn detectBaseIndent(content: []const u8) u32 {
        if (content.len == 0) return 0;

        var min_indent: u32 = std.math.maxInt(u32);
        var it = std.mem.splitScalar(u8, content, '\n');

        while (it.next()) |line| {
            const trimmed = std.mem.trimLeft(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue; // Skip empty lines

            // Calculate indentation for this line
            var indent: u32 = 0;
            for (line) |c| {
                if (c == ' ') {
                    indent += 1;
                } else if (c == '\t') {
                    indent += 4; // Treat tab as 4 spaces
                } else {
                    break; // Stop at first non-whitespace
                }
            }

            if (indent < min_indent) {
                min_indent = indent;
            }
        }

        return if (min_indent == std.math.maxInt(u32)) 0 else min_indent;
    }

    /// Indent content by detecting base indentation and adding one level (4 spaces)
    /// Preserves relative indentation between lines and empty lines
    fn indentContent(content: []const u8, indent_level: u32, w: *Writer) !void {
        if (content.len == 0) return;

        // Trim only leading and trailing newlines (not all whitespace)
        const trimmed = std.mem.trim(u8, content, "\n\r");
        if (trimmed.len == 0) return;

        // Detect the base indentation level
        const base_indent = detectBaseIndent(trimmed);
        const additional_indent = 4 * indent_level; // One level = 4 spaces

        var it = std.mem.splitScalar(u8, trimmed, '\n');
        var first = true;

        while (it.next()) |line| {
            if (!first) {
                try w.writeAll("\n");
            }

            const trimmed_line = std.mem.trimLeft(u8, line, &std.ascii.whitespace);
            if (trimmed_line.len > 0) {
                // Calculate current line's indentation
                var current_indent: u32 = 0;
                for (line) |c| {
                    if (c == ' ') {
                        current_indent += 1;
                    } else if (c == '\t') {
                        current_indent += 4;
                    } else {
                        break;
                    }
                }

                // Calculate relative indentation (how much more than base)
                const relative_indent = if (current_indent >= base_indent) current_indent - base_indent else 0;

                // Write new indentation: additional_indent + relative_indent
                const total_indent = additional_indent + relative_indent;
                for (0..total_indent) |_| {
                    try w.writeAll(" ");
                }
                try w.writeAll(trimmed_line);
            }
            // Empty lines are preserved (just the newline, no indentation)

            first = false;
        }
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

/// Render the full HTML with expressions formatted
pub fn render(allocator: std.mem.Allocator, html: []const u8, expressions: []ExpressionAst) ![]const u8 {
    var w: std.io.Writer.Allocating = .init(allocator);
    defer w.deinit();

    var last_pos: usize = 0;
    for (expressions) |expr| {
        // Write everything before this expression
        if (expr.start > last_pos) {
            try w.writer.writeAll(html[last_pos..expr.start]);
        }

        // Render the expression
        try expr.render(&w.writer);

        last_pos = expr.end;
    }

    // Write remaining content
    if (last_pos < html.len) {
        try w.writer.writeAll(html[last_pos..]);
    }

    const result = w.written();
    const owned = try allocator.dupe(u8, result);
    return owned;
}
