const std = @import("std");

const Ast = std.zig.Ast;
const Token = std.zig.Token;
const Tokenizer = std.zig.Tokenizer;

const log = std.log.scoped(.zx_transpiler);

/// Escapes text content for use in Zig string literals
fn escapeTextForStringLiteral(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    for (text) |c| {
        switch (c) {
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '"' => try result.appendSlice(allocator, "\\\""),
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Token builder for constructing output
const TokenBuilder = struct {
    tokens: std.ArrayList(OutputToken),
    allocator: std.mem.Allocator,

    const OutputToken = struct {
        tag: Token.Tag,
        value: []const u8,
    };

    fn init(allocator: std.mem.Allocator) TokenBuilder {
        return .{
            .tokens = std.ArrayList(OutputToken){},
            .allocator = allocator,
        };
    }

    fn deinit(self: *TokenBuilder) void {
        for (self.tokens.items) |token| {
            self.allocator.free(token.value);
        }
        self.tokens.deinit(self.allocator);
    }

    fn addToken(self: *TokenBuilder, tag: Token.Tag, value: []const u8) !void {
        const owned_value = try self.allocator.dupe(u8, value);
        try self.tokens.append(self.allocator, .{ .tag = tag, .value = owned_value });
    }

    fn toString(self: *TokenBuilder) ![]const u8 {
        var result = std.ArrayList(u8){};
        errdefer result.deinit(self.allocator);

        for (self.tokens.items, 0..) |token, i| {
            try result.appendSlice(self.allocator, token.value);

            // Add spacing between tokens
            if (i + 1 < self.tokens.items.len) {
                const next_token = self.tokens.items[i + 1];
                // Don't add space before newlines/whitespace (invalid tokens contain formatting)
                if (next_token.tag != .invalid and shouldAddSpace(token.tag, next_token.tag)) {
                    try result.append(self.allocator, ' ');
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn shouldAddSpace(current: Token.Tag, next: Token.Tag) bool {
        return switch (current) {
            // Keywords always need space after
            .keyword_pub, .keyword_fn, .keyword_const, .keyword_return => true,

            // Identifiers need space before certain tokens
            .identifier => switch (next) {
                .identifier, .l_paren => true,
                else => false,
            },

            // Right paren needs space before certain tokens
            .r_paren => switch (next) {
                .identifier, .l_brace => true,
                else => false,
            },

            // Comma needs space after (for readability)
            .comma => true,

            // Equal signs are handled contextually - in this case, we want
            // space after = for assignments, but the exact formatting depends
            // on whether it's preceded by something that would make it look better
            .equal => switch (next) {
                .ampersand => false, // No space between = and &
                else => true,
            },

            // Ampersand (reference) - no space after, it should be &.
            .ampersand => false,

            else => false,
        };
    }
};

/// JSX Element representation
const ZXElement = struct {
    tag: []const u8,
    attributes: std.ArrayList(Attribute),
    children: std.ArrayList(Child),
    allocator: std.mem.Allocator,
    builtin_allocator: ?[]const u8 = null, // Builtin @allocator attribute value (expression)

    const Attribute = struct {
        name: []const u8,
        value: AttributeValue,
    };

    const AttributeValue = union(enum) {
        static: []const u8, // "string value"
        dynamic: []const u8, // .{expression}
        format: struct { expr: []const u8, format: []const u8 }, // {[expr:fmt]}
    };

    const SwitchCase = struct {
        pattern: []const u8, // e.g., ".admin"
        value: SwitchCaseValue,

        const SwitchCaseValue = union(enum) {
            string_literal: []const u8, // For ("Admin")
            jsx_element: *ZXElement, // For (<p>Admin</p>)
            conditional_expr: struct { condition: []const u8, if_branch: *ZXElement, else_branch: *ZXElement }, // For if (cond) (<JSX>) else (<JSX>)
        };
    };

    const Child = union(enum) {
        text: []const u8,
        text_expr: []const u8,
        component_expr: []const u8, // For {(expression)} - already a Component
        format_expr: struct { expr: []const u8, format: []const u8 }, // For {[expr:fmt]}
        conditional_expr: struct { condition: []const u8, if_branch: *ZXElement, else_branch: *ZXElement }, // For {if (cond) (<JSX>) else (<JSX>)}
        for_loop_expr: struct { iterable: []const u8, item_name: []const u8, body: *ZXElement }, // For {for (iterable) |item| (<JSX>)}
        switch_expr: struct { expr: []const u8, cases: std.ArrayList(SwitchCase) }, // For {switch (expr) { case => value, ... }}
        element: *ZXElement,
        raw_svg_content: []const u8, // For SVG tags - raw unescaped content
    };

    fn init(allocator: std.mem.Allocator, tag: []const u8) !*ZXElement {
        const elem = try allocator.create(ZXElement);
        elem.* = .{
            .tag = tag,
            .attributes = std.ArrayList(Attribute){},
            .children = std.ArrayList(Child){},
            .allocator = allocator,
        };
        return elem;
    }

    fn deinit(self: *ZXElement) void {
        // Free builtin_allocator if allocated
        if (self.builtin_allocator) |allocator_expr| {
            self.allocator.free(allocator_expr);
        }

        for (self.children.items) |child| {
            if (child == .element) {
                child.element.deinit();
                self.allocator.destroy(child.element);
            } else if (child == .conditional_expr) {
                child.conditional_expr.if_branch.deinit();
                self.allocator.destroy(child.conditional_expr.if_branch);
                child.conditional_expr.else_branch.deinit();
                self.allocator.destroy(child.conditional_expr.else_branch);
            } else if (child == .for_loop_expr) {
                child.for_loop_expr.body.deinit();
                self.allocator.destroy(child.for_loop_expr.body);
            } else if (child == .switch_expr) {
                var switch_expr = child.switch_expr;
                for (switch_expr.cases.items) |switch_case| {
                    switch (switch_case.value) {
                        .jsx_element => |jsx_elem| {
                            jsx_elem.deinit();
                            self.allocator.destroy(jsx_elem);
                        },
                        .conditional_expr => |cond| {
                            cond.if_branch.deinit();
                            self.allocator.destroy(cond.if_branch);
                            cond.else_branch.deinit();
                            self.allocator.destroy(cond.else_branch);
                        },
                        .string_literal => {},
                    }
                }
                switch_expr.cases.deinit(self.allocator);
            } else if (child == .raw_svg_content) {
                // Free the allocated raw SVG content
                self.allocator.free(child.raw_svg_content);
            }
        }
        self.children.deinit(self.allocator);
        self.attributes.deinit(self.allocator);
    }
};

/// Transpile a .zx file to .zig by transforming JSX syntax
pub fn transpile(allocator: std.mem.Allocator, source: [:0]const u8) ![:0]const u8 {
    var result = std.ArrayList(u8){};
    try result.ensureTotalCapacity(allocator, source.len);
    errdefer result.deinit(allocator);
    defer result.deinit(allocator);
    // defer allocator.free(result.items);

    // Use tokenizer to parse the source
    var tokenizer = Tokenizer.init(source);
    var last_pos: usize = 0; // Track last position we've written to result

    while (true) {
        const token = tokenizer.next();

        // If we hit EOF, break
        if (token.tag == .eof) {
            // Append any remaining content from last_pos to end
            if (last_pos < source.len) {
                try result.appendSlice(allocator, source[last_pos..]);
            }
            break;
        }

        // Check if this is a return statement followed by JSX
        if (token.tag == .keyword_return) {
            // Store the return token
            const return_start = token.loc.start;

            // Look ahead for ( and then <
            const saved_index = tokenizer.index;
            var next_token = tokenizer.next();

            // Skip any whitespace/comments by checking multiple tokens
            while (next_token.tag == .invalid or next_token.tag == .doc_comment or next_token.tag == .container_doc_comment) {
                next_token = tokenizer.next();
            }

            // Check if next meaningful token is (
            if (next_token.tag == .l_paren) {
                // Look for JSX opening tag by scanning ahead
                const paren_start = next_token.loc.end;
                const jsx_start = findJsxStart(source, paren_start);

                if (jsx_start) |jsx_pos| {
                    // Find the matching closing paren for the JSX block
                    const jsx_end = findMatchingCloseParen(source, next_token.loc.end);

                    if (jsx_end > jsx_pos) {
                        // Append everything from last_pos up to (not including) return keyword
                        if (last_pos < return_start) {
                            try result.appendSlice(allocator, source[last_pos..return_start]);
                        }

                        // Extract JSX content (between < and closing ))
                        const jsx_content = source[jsx_pos .. jsx_end - 1];

                        // Parse JSX
                        const jsx_elem = try parseJsx(allocator, jsx_content);
                        defer {
                            jsx_elem.deinit();
                            allocator.destroy(jsx_elem);
                        }

                        // Build as tokens and convert to string
                        var output = TokenBuilder.init(allocator);
                        defer output.deinit();

                        // Add allocator context initialization
                        // If root element has @allocator, pass it to init; otherwise use init() without allocator
                        try output.addToken(.keyword_const, "var");
                        try output.addToken(.identifier, "_zx");
                        try output.addToken(.equal, "=");
                        try output.addToken(.identifier, "zx");
                        try output.addToken(.period, ".");
                        if (jsx_elem.builtin_allocator) |allocator_expr| {
                            try output.addToken(.identifier, "initWithAllocator");
                            try output.addToken(.l_paren, "(");
                            try output.addToken(.identifier, allocator_expr);
                            try output.addToken(.r_paren, ")");
                        } else {
                            try output.addToken(.identifier, "init");
                            try output.addToken(.l_paren, "(");
                            try output.addToken(.r_paren, ")");
                        }
                        try output.addToken(.semicolon, ";");
                        try output.addToken(.invalid, "\n");

                        try output.addToken(.keyword_return, "return");
                        try renderJsxAsTokens(allocator, &output, jsx_elem, 1);

                        const jsx_output = try output.toString();
                        defer allocator.free(jsx_output);
                        try result.appendSlice(allocator, jsx_output);

                        // Move tokenizer and last_pos forward past the JSX block
                        tokenizer.index = jsx_end;
                        last_pos = jsx_end;
                        continue;
                    }
                }
            }

            // Not JSX, restore tokenizer position and continue normal processing
            tokenizer.index = saved_index;
        }

        // Check if this is a const declaration followed by JSX
        if (token.tag == .keyword_const) {
            // Store the const token start
            const const_start = token.loc.start;

            // Look ahead for identifier, =, and then (
            const saved_index = tokenizer.index;
            var next_token = tokenizer.next();

            // Skip any whitespace/comments
            while (next_token.tag == .invalid or next_token.tag == .doc_comment or next_token.tag == .container_doc_comment) {
                next_token = tokenizer.next();
            }

            // Check if next meaningful token is an identifier (variable name)
            if (next_token.tag == .identifier) {
                const var_name_start = next_token.loc.start;
                const var_name_end = next_token.loc.end;
                const var_name = source[var_name_start..var_name_end];

                // Skip whitespace and look for =
                next_token = tokenizer.next();
                while (next_token.tag == .invalid or next_token.tag == .doc_comment or next_token.tag == .container_doc_comment) {
                    next_token = tokenizer.next();
                }

                if (next_token.tag == .equal) {
                    // Skip whitespace and look for (
                    next_token = tokenizer.next();
                    while (next_token.tag == .invalid or next_token.tag == .doc_comment or next_token.tag == .container_doc_comment) {
                        next_token = tokenizer.next();
                    }

                    // Check if next meaningful token is (
                    if (next_token.tag == .l_paren) {
                        // Look for JSX opening tag by scanning ahead
                        const paren_start = next_token.loc.end;
                        const jsx_start = findJsxStart(source, paren_start);

                        if (jsx_start) |jsx_pos| {
                            // Find the matching closing paren for the JSX block
                            const jsx_end = findMatchingCloseParen(source, next_token.loc.end);

                            if (jsx_end > jsx_pos) {
                                // Append everything from last_pos up to (not including) const keyword
                                if (last_pos < const_start) {
                                    try result.appendSlice(allocator, source[last_pos..const_start]);
                                }

                                // Extract JSX content (between < and closing ))
                                const jsx_content = source[jsx_pos .. jsx_end - 1];

                                // Parse JSX
                                const jsx_elem = try parseJsx(allocator, jsx_content);
                                defer {
                                    jsx_elem.deinit();
                                    allocator.destroy(jsx_elem);
                                }

                                // Build as tokens and convert to string
                                var output = TokenBuilder.init(allocator);
                                defer output.deinit();

                                // Add allocator context initialization
                                // If root element has @allocator, pass it to init; otherwise use init() without allocator
                                try output.addToken(.keyword_const, "var");
                                try output.addToken(.identifier, "_zx");
                                try output.addToken(.equal, "=");
                                try output.addToken(.identifier, "zx");
                                try output.addToken(.period, ".");
                                if (jsx_elem.builtin_allocator) |allocator_expr| {
                                    try output.addToken(.identifier, "initWithAllocator");
                                    try output.addToken(.l_paren, "(");
                                    try output.addToken(.identifier, allocator_expr);
                                    try output.addToken(.r_paren, ")");
                                } else {
                                    try output.addToken(.identifier, "init");
                                    try output.addToken(.l_paren, "(");
                                    try output.addToken(.r_paren, ")");
                                }
                                try output.addToken(.semicolon, ";");
                                try output.addToken(.invalid, "\n");

                                // const var_name = _zx.zx(...)
                                try output.addToken(.keyword_const, "const");
                                try output.addToken(.identifier, var_name);
                                try output.addToken(.equal, "=");
                                try renderJsxAsTokens(allocator, &output, jsx_elem, 1);

                                const jsx_output = try output.toString();
                                defer allocator.free(jsx_output);
                                try result.appendSlice(allocator, jsx_output);

                                // Move tokenizer and last_pos forward past the JSX block
                                tokenizer.index = jsx_end;
                                last_pos = jsx_end;
                                continue;
                            }
                        }
                    }
                }
            }

            // Not JSX, restore tokenizer position and continue normal processing
            tokenizer.index = saved_index;
        }

        // For all non-JSX tokens, we don't update last_pos
        // This allows the original source to be preserved
    }

    const result_z = try allocator.dupeZ(u8, result.items);

    return result_z;
}

/// Find the start of JSX content after a position (looks for <)
fn findJsxStart(source: []const u8, start_pos: usize) ?usize {
    var i = start_pos;
    while (i < source.len) {
        if (source[i] == '<') {
            // Make sure it's not a comparison operator
            // Check if it's followed by an identifier character or /
            if (i + 1 < source.len) {
                const next_char = source[i + 1];
                if (std.ascii.isAlphabetic(next_char) or next_char == '/') {
                    return i;
                }
            }
        }
        // Skip whitespace
        if (!std.ascii.isWhitespace(source[i])) {
            // If we hit a non-whitespace, non-< character, there's no JSX
            return null;
        }
        i += 1;
    }
    return null;
}

/// Find the matching closing paren for a JSX block
fn findMatchingCloseParen(source: []const u8, start_pos: usize) usize {
    var depth: i32 = 1;
    var i = start_pos;

    while (i < source.len and depth > 0) {
        if (source[i] == '(') depth += 1;
        if (source[i] == ')') depth -= 1;
        i += 1;
    }

    return i;
}

/// Check if a tag is a void element (doesn't need closing tag in HTML)
fn isVoidElement(tag: []const u8) bool {
    const void_elements = [_][]const u8{
        "input", "br",   "hr",  "img",   "meta",  "link",
        "area",  "base", "col", "embed", "param", "source",
        "track", "wbr",
    };
    for (void_elements) |void_elem| {
        if (std.mem.eql(u8, tag, void_elem)) {
            return true;
        }
    }
    return false;
}

/// Parse JSX content, wrapping in fragment if it doesn't start with <
fn parseJsxOrFragment(allocator: std.mem.Allocator, content: []const u8) error{ InvalidJsx, OutOfMemory }!*ZXElement {
    // Skip whitespace
    var i: usize = 0;
    while (i < content.len and std.ascii.isWhitespace(content[i])) i += 1;

    // If content doesn't start with <, wrap it in a fragment
    if (i >= content.len or content[i] != '<') {
        log.debug("JSX content doesn't start with <, wrapping in fragment", .{});
        const fragment = try ZXElement.init(allocator, "fragment");
        try parseJsxChildren(allocator, fragment, content);
        return fragment;
    }

    // Otherwise parse as normal JSX
    return parseJsx(allocator, content);
}

/// Parse JSX syntax into a JsxElement
fn parseJsx(allocator: std.mem.Allocator, content: []const u8) error{ InvalidJsx, OutOfMemory }!*ZXElement {
    var i: usize = 0;
    log.debug("parseJsx called with content length: {d}, content: '{s}'", .{ content.len, content });

    // Skip whitespace
    while (i < content.len and std.ascii.isWhitespace(content[i])) i += 1;

    if (i >= content.len or content[i] != '<') {
        return error.InvalidJsx;
    }
    i += 1; // skip <

    // Parse tag name
    const tag_start = i;
    while (i < content.len and !std.ascii.isWhitespace(content[i]) and content[i] != '>' and content[i] != '/') {
        i += 1;
    }
    const tag_name = content[tag_start..i];

    const elem = try ZXElement.init(allocator, tag_name);
    errdefer {
        elem.deinit();
        allocator.destroy(elem);
    }

    // Parse attributes
    while (i < content.len) {
        // Skip whitespace
        while (i < content.len and std.ascii.isWhitespace(content[i])) i += 1;

        if (i >= content.len) break;
        if (content[i] == '>' or content[i] == '/') break;

        // Parse attribute name
        const attr_start = i;
        while (i < content.len and content[i] != '=' and !std.ascii.isWhitespace(content[i])) {
            i += 1;
        }
        const attr_name = content[attr_start..i];

        // Check if this is a builtin attribute (@allocator)
        const is_builtin = std.mem.startsWith(u8, attr_name, "@");
        const builtin_name: ?[]const u8 = if (is_builtin) attr_name[1..] else null;

        // Skip whitespace and =
        while (i < content.len and (std.ascii.isWhitespace(content[i]) or content[i] == '=')) i += 1;

        // Parse attribute value - either quoted string, dynamic expression, or format expression
        if (i < content.len and content[i] == '"') {
            // Static string value: "value"
            i += 1; // skip opening quote
            const val_start = i;
            while (i < content.len and content[i] != '"') i += 1;
            const attr_value = content[val_start..i];
            i += 1; // skip closing quote

            // Handle builtin attributes
            if (builtin_name) |name| {
                if (std.mem.eql(u8, name, "allocator")) {
                    // @allocator with static value - not supported, must be dynamic expression
                    // For now, treat static string as identifier (variable name)
                    const expr = try allocator.dupe(u8, attr_value);
                    elem.builtin_allocator = expr;
                } else {
                    // Other builtin attributes - add to regular attributes for now
                    try elem.attributes.append(allocator, .{ .name = attr_name, .value = .{ .static = attr_value } });
                }
            } else {
                try elem.attributes.append(allocator, .{ .name = attr_name, .value = .{ .static = attr_value } });
            }
        } else if (i + 1 < content.len and content[i] == '{') {
            // Check for format expression: {[expr:fmt]} or dynamic expression: {expr}
            i += 1; // skip {
            const expr_start = i;
            var brace_depth: i32 = 1;
            while (i < content.len and brace_depth > 0) {
                if (content[i] == '{') brace_depth += 1;
                if (content[i] == '}') brace_depth -= 1;
                if (brace_depth > 0) i += 1;
            }
            var expr = content[expr_start..i];
            i += 1; // skip closing }

            // Trim whitespace first
            while (expr.len > 0 and std.ascii.isWhitespace(expr[0])) expr = expr[1..];
            while (expr.len > 0 and std.ascii.isWhitespace(expr[expr.len - 1])) expr = expr[0 .. expr.len - 1];

            // Handle builtin @allocator attribute
            if (builtin_name) |name| {
                if (std.mem.eql(u8, name, "allocator")) {
                    // Store the expression for @allocator
                    const expr_copy = try allocator.dupe(u8, expr);
                    elem.builtin_allocator = expr_copy;
                    continue; // Skip adding to regular attributes
                }
            }

            // Check for format expression: {[expr:fmt]} or {[expr]}
            if (expr.len >= 2 and expr[0] == '[' and expr[expr.len - 1] == ']') {
                // Remove the brackets
                var inner = expr[1 .. expr.len - 1];

                // Trim whitespace from inner content
                while (inner.len > 0 and std.ascii.isWhitespace(inner[0])) inner = inner[1..];
                while (inner.len > 0 and std.ascii.isWhitespace(inner[inner.len - 1])) inner = inner[0 .. inner.len - 1];

                // Check for format specifier after colon
                if (std.mem.indexOfScalar(u8, inner, ':')) |colon_pos| {
                    // Split at colon: expr:format
                    const expr_part = inner[0..colon_pos];
                    var format_part = inner[colon_pos + 1 ..];

                    // Trim whitespace from both parts
                    var trimmed_expr = expr_part;
                    while (trimmed_expr.len > 0 and std.ascii.isWhitespace(trimmed_expr[0])) trimmed_expr = trimmed_expr[1..];
                    while (trimmed_expr.len > 0 and std.ascii.isWhitespace(trimmed_expr[trimmed_expr.len - 1])) trimmed_expr = trimmed_expr[0 .. trimmed_expr.len - 1];

                    while (format_part.len > 0 and std.ascii.isWhitespace(format_part[0])) format_part = format_part[1..];
                    while (format_part.len > 0 and std.ascii.isWhitespace(format_part[format_part.len - 1])) format_part = format_part[0 .. format_part.len - 1];

                    try elem.attributes.append(allocator, .{ .name = attr_name, .value = .{ .format = .{ .expr = trimmed_expr, .format = format_part } } });
                } else {
                    // No format specifier, default to "d" for decimal
                    try elem.attributes.append(allocator, .{ .name = attr_name, .value = .{ .format = .{ .expr = inner, .format = "d" } } });
                }
            } else {
                // Regular dynamic expression: {expr}
                try elem.attributes.append(allocator, .{ .name = attr_name, .value = .{ .dynamic = expr } });
            }
        }
    }

    // Check for self-closing tag (/>)
    var is_self_closing = false;
    while (i < content.len and content[i] != '>') {
        if (content[i] == '/' and i + 1 < content.len and content[i + 1] == '>') {
            is_self_closing = true;
            i += 1; // skip /
            break;
        }
        i += 1;
    }
    if (i < content.len) i += 1; // skip >

    // Check if this is a void element or self-closing tag (no children/closing tag)
    if (isVoidElement(tag_name) or is_self_closing) {
        // Void elements and self-closing tags don't have children or closing tags
        return elem;
    }

    // Parse children until closing tag
    const inner_start = i;
    var depth: i32 = 1;
    var inner_end = i;

    while (inner_end < content.len and depth > 0) {
        if (content[inner_end] == '<') {
            if (inner_end + 1 < content.len and content[inner_end + 1] == '/') {
                depth -= 1;
                if (depth == 0) break;
            } else if (inner_end + 1 < content.len and content[inner_end + 1] != '!') {
                // Check if it's a void element before incrementing depth
                const check_start = inner_end + 1;
                var check_i = check_start;
                while (check_i < content.len and !std.ascii.isWhitespace(content[check_i]) and content[check_i] != '>' and content[check_i] != '/') {
                    check_i += 1;
                }
                const check_tag = content[check_start..check_i];
                if (!isVoidElement(check_tag)) {
                    depth += 1;
                }
            }
        }
        inner_end += 1;
    }

    const inner_content = content[inner_start..inner_end];

    // Special handling for SVG tags: store raw content as unescaped text
    if (std.mem.eql(u8, tag_name, "svg")) {
        const raw_content = try allocator.dupe(u8, inner_content);
        try elem.children.append(allocator, .{ .raw_svg_content = raw_content });
    } else {
        try parseJsxChildren(allocator, elem, inner_content);
    }

    return elem;
}

/// Parse JSX children (text, expressions, nested elements)
fn parseJsxChildren(allocator: std.mem.Allocator, parent: *ZXElement, content: []const u8) error{ InvalidJsx, OutOfMemory }!void {
    var i: usize = 0;
    log.debug("parseJsxChildren called with content length: {d}, content: '{s}'", .{ content.len, content });

    while (i < content.len) {
        log.debug("parseJsxChildren: i={d}, content[i..]='{s}'", .{ i, if (i < content.len) content[i..] else "" });
        // Check for closing tag
        if (content[i] == '<' and i + 1 < content.len and content[i + 1] == '/') {
            break;
        }

        // Text expression: {expr}, component: {(expr)}, or format: {[expr:fmt]}
        if (i + 1 < content.len and content[i] == '{') {
            i += 1;
            const expr_start = i;

            // Find the matching closing brace, accounting for nested braces/parens
            var brace_depth: i32 = 1;
            while (i < content.len and brace_depth > 0) {
                if (content[i] == '{') brace_depth += 1;
                if (content[i] == '}') brace_depth -= 1;
                if (brace_depth > 0) i += 1;
            }

            var expr = content[expr_start..i];
            i += 1; // skip }

            // Trim whitespace first
            while (expr.len > 0 and std.ascii.isWhitespace(expr[0])) expr = expr[1..];
            while (expr.len > 0 and std.ascii.isWhitespace(expr[expr.len - 1])) expr = expr[0 .. expr.len - 1];

            // Check for component expression: {(expr)}
            if (expr.len >= 2 and expr[0] == '(' and expr[expr.len - 1] == ')') {
                const component_expr = expr[1 .. expr.len - 1];
                try parent.children.append(allocator, .{ .component_expr = component_expr });
            }
            // Check for format expression: {[expr:format]} or {[expr]}
            else if (expr.len >= 2 and expr[0] == '[' and expr[expr.len - 1] == ']') {
                // Remove the brackets
                var inner = expr[1 .. expr.len - 1];

                // Trim whitespace from inner content
                while (inner.len > 0 and std.ascii.isWhitespace(inner[0])) inner = inner[1..];
                while (inner.len > 0 and std.ascii.isWhitespace(inner[inner.len - 1])) inner = inner[0 .. inner.len - 1];

                // Check for format specifier after colon
                if (std.mem.indexOfScalar(u8, inner, ':')) |colon_pos| {
                    // Split at colon: expr:format
                    const expr_part = inner[0..colon_pos];
                    var format_part = inner[colon_pos + 1 ..];

                    // Trim whitespace from both parts
                    var trimmed_expr = expr_part;
                    while (trimmed_expr.len > 0 and std.ascii.isWhitespace(trimmed_expr[0])) trimmed_expr = trimmed_expr[1..];
                    while (trimmed_expr.len > 0 and std.ascii.isWhitespace(trimmed_expr[trimmed_expr.len - 1])) trimmed_expr = trimmed_expr[0 .. trimmed_expr.len - 1];

                    while (format_part.len > 0 and std.ascii.isWhitespace(format_part[0])) format_part = format_part[1..];
                    while (format_part.len > 0 and std.ascii.isWhitespace(format_part[format_part.len - 1])) format_part = format_part[0 .. format_part.len - 1];

                    try parent.children.append(allocator, .{ .format_expr = .{ .expr = trimmed_expr, .format = format_part } });
                } else {
                    // No format specifier, default to "d" for decimal
                    try parent.children.append(allocator, .{ .format_expr = .{ .expr = inner, .format = "d" } });
                }
            }
            // Check for conditional expression with JSX: {if (cond) (<JSX>) else (<JSX>)}
            else if (std.mem.startsWith(u8, expr, "if")) {
                var parsed_conditional = true;
                if (std.mem.indexOf(u8, expr, "else")) |else_pos| {
                    // Extract condition: everything from "if" to "else"
                    var condition_start: usize = 2; // Skip "if"
                    // Skip whitespace after "if"
                    while (condition_start < else_pos and std.ascii.isWhitespace(expr[condition_start])) condition_start += 1;
                    // Find the start of the condition (usually a '(')
                    // Actually, the condition might be "(condition)" or just "condition"
                    // For now, we'll take everything up to the first ')' or to the space before "else"
                    var condition_end = condition_start;
                    var paren_depth: i32 = 0;
                    while (condition_end < else_pos) {
                        if (expr[condition_end] == '(') paren_depth += 1;
                        if (expr[condition_end] == ')') {
                            paren_depth -= 1;
                            if (paren_depth == 0) {
                                condition_end += 1;
                                break;
                            }
                        }
                        condition_end += 1;
                    }
                    // If no parens found, take up to "else"
                    if (condition_end == condition_start) {
                        condition_end = else_pos;
                        // Trim whitespace at end
                        while (condition_end > condition_start and std.ascii.isWhitespace(expr[condition_end - 1])) condition_end -= 1;
                    }

                    const condition = expr[condition_start..condition_end];

                    // Extract if branch: after condition, skip whitespace, find opening paren
                    var if_start = condition_end;
                    while (if_start < expr.len and (std.ascii.isWhitespace(expr[if_start]) or expr[if_start] == ')')) if_start += 1;
                    // Find opening paren for JSX
                    while (if_start < expr.len and expr[if_start] != '(') if_start += 1;
                    if (if_start < expr.len and expr[if_start] == '(') {
                        if_start += 1; // Skip opening paren
                        // Find matching closing paren, accounting for nested conditionals and braces
                        // Don't stop at else_pos - we need to find the matching closing paren for the outer conditional's if branch
                        var if_end = if_start;
                        paren_depth = 1;
                        var if_brace_depth: i32 = 0;
                        while (if_end < expr.len and paren_depth > 0) {
                            if (expr[if_end] == '(') paren_depth += 1;
                            if (expr[if_end] == ')') paren_depth -= 1;
                            if (expr[if_end] == '{') if_brace_depth += 1;
                            if (expr[if_end] == '}') if_brace_depth -= 1;
                            if (paren_depth > 0) if_end += 1;
                        }
                        const if_jsx_content = expr[if_start..if_end];

                        // Extract else branch: after "else", skip whitespace, find opening paren
                        var else_start = else_pos + 4; // Skip "else"
                        while (else_start < expr.len and std.ascii.isWhitespace(expr[else_start])) else_start += 1;
                        // Find opening paren
                        while (else_start < expr.len and expr[else_start] != '(') else_start += 1;
                        if (else_start < expr.len and expr[else_start] == '(') {
                            else_start += 1; // Skip opening paren
                            // Find matching closing paren, accounting for nested braces from expressions like {switch ...}
                            var else_end = else_start;
                            paren_depth = 1;
                            var else_brace_depth: i32 = 0;
                            while (else_end < expr.len and paren_depth > 0) {
                                if (expr[else_end] == '(') paren_depth += 1;
                                if (expr[else_end] == ')') paren_depth -= 1;
                                if (expr[else_end] == '{') else_brace_depth += 1;
                                if (expr[else_end] == '}') else_brace_depth -= 1;
                                if (paren_depth > 0) else_end += 1;
                            }
                            const else_jsx_content = expr[else_start..else_end];

                            // Parse both JSX branches (wrap in fragment if needed)
                            if (parseJsxOrFragment(allocator, if_jsx_content)) |if_elem| {
                                if (parseJsxOrFragment(allocator, else_jsx_content)) |else_elem| {
                                    try parent.children.append(allocator, .{ .conditional_expr = .{
                                        .condition = condition,
                                        .if_branch = if_elem,
                                        .else_branch = else_elem,
                                    } });
                                    continue;
                                } else |_| {
                                    // Cleanup if branch on error
                                    if_elem.deinit();
                                    allocator.destroy(if_elem);
                                    parsed_conditional = false;
                                }
                            } else |_| {
                                parsed_conditional = false;
                            }
                        }
                    }
                }
                // If we couldn't parse as conditional with JSX, fall through to regular text expression
                if (!parsed_conditional) {
                    try parent.children.append(allocator, .{ .text_expr = expr });
                }
            }
            // Check for for loop expression: {for (iterable) |item| (<JSX>)}
            else if (std.mem.startsWith(u8, expr, "for")) {
                // Pattern: for (iterable) |item| (<JSX>)
                var parsed_for_loop = true;

                // Find opening paren after "for"
                var for_pos: usize = 3; // Skip "for"
                while (for_pos < expr.len and std.ascii.isWhitespace(expr[for_pos])) for_pos += 1;

                if (for_pos < expr.len and expr[for_pos] == '(') {
                    for_pos += 1; // Skip opening paren
                    // Find iterable (text between ( and ))
                    const iterable_start = for_pos;
                    var iterable_end = iterable_start;
                    var paren_depth: i32 = 1;
                    while (iterable_end < expr.len and paren_depth > 0) {
                        if (expr[iterable_end] == '(') paren_depth += 1;
                        if (expr[iterable_end] == ')') paren_depth -= 1;
                        if (paren_depth > 0) iterable_end += 1;
                    }
                    const iterable = expr[iterable_start..iterable_end];

                    // Skip closing paren and whitespace
                    var pipe_pos = iterable_end + 1;
                    while (pipe_pos < expr.len and std.ascii.isWhitespace(expr[pipe_pos])) pipe_pos += 1;

                    // Find |item| pattern
                    if (pipe_pos < expr.len and expr[pipe_pos] == '|') {
                        pipe_pos += 1; // Skip opening |
                        const item_start = pipe_pos;
                        while (pipe_pos < expr.len and expr[pipe_pos] != '|') pipe_pos += 1;

                        if (pipe_pos < expr.len and expr[pipe_pos] == '|') {
                            const item_name = expr[item_start..pipe_pos];
                            pipe_pos += 1; // Skip closing |

                            // Skip whitespace after |
                            while (pipe_pos < expr.len and std.ascii.isWhitespace(expr[pipe_pos])) pipe_pos += 1;

                            var jsx_content_start = pipe_pos;
                            var jsx_content_end: usize = undefined;
                            var found_jsx = false;

                            // Check for opening paren: {for (iterable) |item| (<JSX>)}
                            if (pipe_pos < expr.len and expr[pipe_pos] == '(') {
                                pipe_pos += 1; // Skip opening paren
                                // Find matching closing paren, accounting for nested braces from expressions like {switch ...}
                                jsx_content_start = pipe_pos;
                                jsx_content_end = pipe_pos;
                                paren_depth = 1;
                                var for_brace_depth: i32 = 0;
                                while (jsx_content_end < expr.len and paren_depth > 0) {
                                    if (expr[jsx_content_end] == '(') paren_depth += 1;
                                    if (expr[jsx_content_end] == ')') paren_depth -= 1;
                                    if (expr[jsx_content_end] == '{') for_brace_depth += 1;
                                    if (expr[jsx_content_end] == '}') for_brace_depth -= 1;
                                    if (paren_depth > 0) jsx_content_end += 1;
                                }
                                found_jsx = true;
                            }

                            if (found_jsx) {
                                const jsx_content = expr[jsx_content_start..jsx_content_end];
                                log.debug("For loop extracted JSX content: '{s}'", .{jsx_content});

                                // Parse JSX body - wrap in a fragment if it doesn't start with <
                                var body_elem: *ZXElement = undefined;
                                if (parseJsx(allocator, jsx_content)) |parsed_elem| {
                                    log.debug("Successfully parsed for loop JSX body as JSX element", .{});
                                    body_elem = parsed_elem;
                                } else |_| {
                                    // Content doesn't start with <, so wrap it in a fragment and parse as children
                                    log.debug("JSX content doesn't start with <, wrapping in fragment", .{});
                                    body_elem = try ZXElement.init(allocator, "fragment");
                                    try parseJsxChildren(allocator, body_elem, jsx_content);
                                }
                                try parent.children.append(allocator, .{ .for_loop_expr = .{
                                    .iterable = iterable,
                                    .item_name = item_name,
                                    .body = body_elem,
                                } });
                                continue;
                            } else {
                                parsed_for_loop = false;
                            }
                        } else {
                            parsed_for_loop = false;
                        }
                    } else {
                        parsed_for_loop = false;
                    }
                } else {
                    parsed_for_loop = false;
                }

                // If we couldn't parse as for loop, treat as regular expression
                if (!parsed_for_loop) {
                    try parent.children.append(allocator, .{ .text_expr = expr });
                }
            }
            // Check for switch expression: {switch (expr) { case => value, ... }}
            else if (std.mem.startsWith(u8, expr, "switch")) {
                var parsed_switch = true;

                // Find opening paren after "switch"
                var switch_pos: usize = 6; // Skip "switch"
                while (switch_pos < expr.len and std.ascii.isWhitespace(expr[switch_pos])) switch_pos += 1;

                if (switch_pos < expr.len and expr[switch_pos] == '(') {
                    switch_pos += 1; // Skip opening paren
                    // Find switch expression (text between ( and ))
                    const switch_expr_start = switch_pos;
                    var switch_expr_end = switch_expr_start;
                    var paren_depth: i32 = 1;
                    while (switch_expr_end < expr.len and paren_depth > 0) {
                        if (expr[switch_expr_end] == '(') paren_depth += 1;
                        if (expr[switch_expr_end] == ')') paren_depth -= 1;
                        if (paren_depth > 0) switch_expr_end += 1;
                    }
                    const switch_expr = expr[switch_expr_start..switch_expr_end];

                    // Skip closing paren and whitespace
                    var brace_pos = switch_expr_end + 1;
                    while (brace_pos < expr.len and std.ascii.isWhitespace(expr[brace_pos])) brace_pos += 1;

                    // Find opening brace
                    if (brace_pos < expr.len and expr[brace_pos] == '{') {
                        brace_pos += 1; // Skip opening brace

                        // Parse cases
                        var cases = std.ArrayList(ZXElement.SwitchCase){};
                        defer cases.deinit(allocator);

                        var case_start = brace_pos;
                        while (case_start < expr.len) {
                            // Skip whitespace
                            while (case_start < expr.len and std.ascii.isWhitespace(expr[case_start])) case_start += 1;
                            if (case_start >= expr.len) break;

                            // Check for closing brace
                            if (expr[case_start] == '}') break;

                            // Parse pattern (e.g., ".admin")
                            const pattern_start = case_start;
                            var pattern_end = pattern_start;
                            while (pattern_end < expr.len and expr[pattern_end] != '=' and !std.ascii.isWhitespace(expr[pattern_end])) {
                                pattern_end += 1;
                            }
                            const pattern = expr[pattern_start..pattern_end];

                            // Skip whitespace and =>
                            var arrow_pos = pattern_end;
                            while (arrow_pos < expr.len and std.ascii.isWhitespace(expr[arrow_pos])) arrow_pos += 1;
                            if (arrow_pos + 1 < expr.len and expr[arrow_pos] == '=' and expr[arrow_pos + 1] == '>') {
                                arrow_pos += 2; // Skip =>
                            } else {
                                parsed_switch = false;
                                break;
                            }

                            // Skip whitespace after =>
                            while (arrow_pos < expr.len and std.ascii.isWhitespace(expr[arrow_pos])) arrow_pos += 1;

                            // Check for conditional expression: if (cond) (<JSX>) else (<JSX>)
                            var check_pos = arrow_pos;
                            while (check_pos < expr.len and std.ascii.isWhitespace(expr[check_pos])) check_pos += 1;

                            if (check_pos + 2 < expr.len and std.mem.startsWith(u8, expr[check_pos..], "if")) {
                                // Parse conditional expression
                                log.debug("Found conditional expression in switch case value", .{});
                                var cond_pos = check_pos + 2; // Skip "if"

                                // Skip whitespace
                                while (cond_pos < expr.len and std.ascii.isWhitespace(expr[cond_pos])) cond_pos += 1;

                                // Check for opening paren for condition
                                if (cond_pos < expr.len and expr[cond_pos] == '(') {
                                    cond_pos += 1;
                                    const cond_start = cond_pos;
                                    // Find matching closing paren for condition
                                    var cond_paren_depth: i32 = 1;
                                    var cond_brace_depth: i32 = 0;
                                    while (cond_pos < expr.len and cond_paren_depth > 0) {
                                        if (expr[cond_pos] == '(') cond_paren_depth += 1;
                                        if (expr[cond_pos] == ')') cond_paren_depth -= 1;
                                        if (expr[cond_pos] == '{') cond_brace_depth += 1;
                                        if (expr[cond_pos] == '}') cond_brace_depth -= 1;
                                        if (cond_paren_depth > 0) cond_pos += 1;
                                    }
                                    // Advance past closing paren
                                    if (cond_pos < expr.len and expr[cond_pos] == ')') cond_pos += 1;
                                    const condition_str = expr[cond_start .. cond_pos - 1];

                                    // Skip whitespace
                                    while (cond_pos < expr.len and std.ascii.isWhitespace(expr[cond_pos])) cond_pos += 1;

                                    // Parse if branch
                                    if (cond_pos < expr.len and expr[cond_pos] == '(') {
                                        cond_pos += 1;
                                        const if_start = cond_pos;
                                        var if_paren_depth: i32 = 1;
                                        var if_brace_depth: i32 = 0;
                                        while (cond_pos < expr.len and if_paren_depth > 0) {
                                            if (expr[cond_pos] == '(') if_paren_depth += 1;
                                            if (expr[cond_pos] == ')') if_paren_depth -= 1;
                                            if (expr[cond_pos] == '{') if_brace_depth += 1;
                                            if (expr[cond_pos] == '}') if_brace_depth -= 1;
                                            if (if_paren_depth > 0) cond_pos += 1;
                                        }
                                        const if_end = cond_pos;
                                        if (cond_pos < expr.len and expr[cond_pos] == ')') cond_pos += 1;

                                        // Skip whitespace
                                        while (cond_pos < expr.len and std.ascii.isWhitespace(expr[cond_pos])) cond_pos += 1;

                                        // Check for "else"
                                        if (cond_pos + 4 <= expr.len and std.mem.eql(u8, expr[cond_pos .. cond_pos + 4], "else")) {
                                            cond_pos += 4; // Skip "else"

                                            // Skip whitespace
                                            while (cond_pos < expr.len and std.ascii.isWhitespace(expr[cond_pos])) cond_pos += 1;

                                            // Parse else branch
                                            if (cond_pos < expr.len and expr[cond_pos] == '(') {
                                                cond_pos += 1;
                                                const else_start = cond_pos;
                                                var else_paren_depth: i32 = 1;
                                                var else_brace_depth: i32 = 0;
                                                while (cond_pos < expr.len and else_paren_depth > 0) {
                                                    if (expr[cond_pos] == '(') else_paren_depth += 1;
                                                    if (expr[cond_pos] == ')') else_paren_depth -= 1;
                                                    if (expr[cond_pos] == '{') else_brace_depth += 1;
                                                    if (expr[cond_pos] == '}') else_brace_depth -= 1;
                                                    if (else_paren_depth > 0) cond_pos += 1;
                                                }
                                                const else_end = cond_pos;
                                                if (cond_pos < expr.len and expr[cond_pos] == ')') cond_pos += 1;

                                                const if_jsx_content = expr[if_start..if_end];
                                                const else_jsx_content = expr[else_start..else_end];

                                                // Parse both JSX branches (wrap in fragment if needed)
                                                if (parseJsxOrFragment(allocator, if_jsx_content)) |if_elem| {
                                                    if (parseJsxOrFragment(allocator, else_jsx_content)) |else_elem| {
                                                        try cases.append(allocator, .{
                                                            .pattern = pattern,
                                                            .value = .{ .conditional_expr = .{
                                                                .condition = condition_str,
                                                                .if_branch = if_elem,
                                                                .else_branch = else_elem,
                                                            } },
                                                        });
                                                        arrow_pos = cond_pos; // Update arrow_pos to end of conditional
                                                        // Skip whitespace and comma
                                                        while (arrow_pos < expr.len and (std.ascii.isWhitespace(expr[arrow_pos]) or expr[arrow_pos] == ',')) {
                                                            arrow_pos += 1;
                                                        }
                                                        case_start = arrow_pos;
                                                        continue;
                                                    } else |_| {
                                                        if_elem.deinit();
                                                        allocator.destroy(if_elem);
                                                        parsed_switch = false;
                                                        break;
                                                    }
                                                } else |_| {
                                                    parsed_switch = false;
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Parse value - either ("string") or (<JSX>)
                            if (arrow_pos < expr.len and expr[arrow_pos] == '(') {
                                arrow_pos += 1; // Skip opening paren
                                const value_start = arrow_pos;

                                // Check if it's a string literal or JSX
                                if (arrow_pos < expr.len and expr[arrow_pos] == '"') {
                                    // String literal: ("Admin")
                                    arrow_pos += 1; // Skip opening quote
                                    const str_start = arrow_pos;
                                    while (arrow_pos < expr.len and expr[arrow_pos] != '"') arrow_pos += 1;
                                    const str_value = expr[str_start..arrow_pos];
                                    arrow_pos += 1; // Skip closing quote
                                    // Find closing paren
                                    while (arrow_pos < expr.len and expr[arrow_pos] != ')') arrow_pos += 1;
                                    arrow_pos += 1; // Skip closing paren

                                    try cases.append(allocator, .{
                                        .pattern = pattern,
                                        .value = .{ .string_literal = str_value },
                                    });
                                } else {
                                    // JSX element: (<p>Admin</p>)
                                    var jsx_paren_depth: i32 = 1;
                                    var jsx_brace_depth: i32 = 0;
                                    var jsx_end = arrow_pos;
                                    while (jsx_end < expr.len and jsx_paren_depth > 0) {
                                        if (expr[jsx_end] == '(') jsx_paren_depth += 1;
                                        if (expr[jsx_end] == ')') jsx_paren_depth -= 1;
                                        if (expr[jsx_end] == '{') jsx_brace_depth += 1;
                                        if (expr[jsx_end] == '}') jsx_brace_depth -= 1;
                                        if (jsx_paren_depth > 0) jsx_end += 1;
                                    }
                                    const jsx_content = expr[value_start..jsx_end];

                                    if (parseJsx(allocator, jsx_content)) |jsx_elem| {
                                        try cases.append(allocator, .{
                                            .pattern = pattern,
                                            .value = .{ .jsx_element = jsx_elem },
                                        });
                                    } else |_| {
                                        parsed_switch = false;
                                        break;
                                    }
                                    arrow_pos = jsx_end + 1; // Skip closing paren
                                }
                            } else {
                                parsed_switch = false;
                                break;
                            }

                            // Skip whitespace and comma if present
                            while (arrow_pos < expr.len and (std.ascii.isWhitespace(expr[arrow_pos]) or expr[arrow_pos] == ',')) {
                                arrow_pos += 1;
                            }

                            case_start = arrow_pos;
                        }

                        if (parsed_switch and cases.items.len > 0) {
                            // Create switch_expr child
                            var cases_owned = std.ArrayList(ZXElement.SwitchCase){};
                            try cases_owned.appendSlice(allocator, cases.items);
                            try parent.children.append(allocator, .{ .switch_expr = .{
                                .expr = switch_expr,
                                .cases = cases_owned,
                            } });
                            continue;
                        }
                    } else {
                        parsed_switch = false;
                    }
                } else {
                    parsed_switch = false;
                }

                // If we couldn't parse as switch, treat as regular expression
                if (!parsed_switch) {
                    try parent.children.append(allocator, .{ .text_expr = expr });
                }
            }
            // Regular text expression: {expr}
            else {
                try parent.children.append(allocator, .{ .text_expr = expr });
            }
            continue;
        }

        // Nested element
        if (content[i] == '<' and i + 1 < content.len and content[i + 1] != '/') {
            // Find matching closing tag or self-closing tag
            var depth: i32 = 1; // Start at 1 for the current opening tag
            const elem_start = i;
            var j = i + 1; // Skip the initial <

            // Get the tag name to check if it's a void element
            const tag_start = j;
            while (j < content.len and !std.ascii.isWhitespace(content[j]) and content[j] != '>' and content[j] != '/') {
                j += 1;
            }
            const check_tag_name = content[tag_start..j];
            j = i + 1; // Reset j

            // Check if this is a void element or self-closing tag
            const is_void = isVoidElement(check_tag_name);
            var is_self_closing = false;
            var temp_j = j;
            while (temp_j < content.len and content[temp_j] != '>') {
                if (content[temp_j] == '/' and temp_j + 1 < content.len and content[temp_j + 1] == '>') {
                    is_self_closing = true;
                    break;
                }
                temp_j += 1;
            }

            if (is_void or is_self_closing) {
                // Void elements or self-closing tags, just find the >
                while (j < content.len and content[j] != '>') {
                    j += 1;
                }
                j += 1; // skip >
            } else {
                // Regular tag with closing tag
                while (j < content.len) {
                    if (content[j] == '<') {
                        if (j + 1 < content.len and content[j + 1] == '/') {
                            depth -= 1;
                            if (depth == 0) {
                                // Find the end of closing tag
                                while (j < content.len and content[j] != '>') j += 1;
                                j += 1; // include >
                                break;
                            }
                        } else if (j + 1 < content.len and content[j + 1] != '!') {
                            // Check if it's not a self-closing tag or void element before incrementing
                            const check_start = j + 1;
                            var check_end = check_start;
                            while (check_end < content.len and !std.ascii.isWhitespace(content[check_end]) and content[check_end] != '>' and content[check_end] != '/') {
                                check_end += 1;
                            }
                            const nested_tag = content[check_start..check_end];

                            var is_nested_self_closing = false;
                            var check_self_close = check_end;
                            while (check_self_close < content.len and content[check_self_close] != '>') {
                                if (content[check_self_close] == '/' and check_self_close + 1 < content.len and content[check_self_close + 1] == '>') {
                                    is_nested_self_closing = true;
                                    break;
                                }
                                check_self_close += 1;
                            }

                            // Only increment depth if it's not self-closing and not a void element
                            if (!is_nested_self_closing and !isVoidElement(nested_tag)) {
                                depth += 1;
                            }
                        }
                    }
                    j += 1;
                }
            }

            const child_elem = try parseJsx(allocator, content[elem_start..j]);
            try parent.children.append(allocator, .{ .element = child_elem });
            i = j;
            continue;
        }

        // Skip whitespace before checking for conditional expression
        var check_pos = i;
        while (check_pos < content.len and std.ascii.isWhitespace(content[check_pos])) check_pos += 1;

        // Check for conditional expression directly in JSX content: if (cond) (JSX) else (JSX)
        if (check_pos + 2 < content.len and std.mem.startsWith(u8, content[check_pos..], "if")) {
            log.debug("Found potential conditional expression at position {d} (after whitespace at {d})", .{ check_pos, i });
            const cond_start = check_pos;
            var cond_pos = check_pos + 2; // Skip "if"

            // Skip whitespace
            while (cond_pos < content.len and std.ascii.isWhitespace(content[cond_pos])) cond_pos += 1;

            // Check for opening paren
            if (cond_pos < content.len and content[cond_pos] == '(') {
                log.debug("Found opening paren for condition at position {d}", .{cond_pos});
                cond_pos += 1;
                // Find matching closing paren for condition
                var cond_paren_depth: i32 = 1;
                var cond_brace_depth: i32 = 0;
                while (cond_pos < content.len and cond_paren_depth > 0) {
                    if (content[cond_pos] == '(') cond_paren_depth += 1;
                    if (content[cond_pos] == ')') cond_paren_depth -= 1;
                    if (content[cond_pos] == '{') cond_brace_depth += 1;
                    if (content[cond_pos] == '}') cond_brace_depth -= 1;
                    if (cond_paren_depth > 0) cond_pos += 1;
                }
                // cond_pos is now at the closing paren, advance past it
                if (cond_pos < content.len and content[cond_pos] == ')') cond_pos += 1;
                log.debug("Found closing paren for condition, now at position {d}", .{cond_pos});

                // Skip whitespace after condition
                while (cond_pos < content.len and std.ascii.isWhitespace(content[cond_pos])) cond_pos += 1;
                log.debug("After skipping whitespace, cond_pos={d}, content[cond_pos..]='{s}'", .{ cond_pos, if (cond_pos < content.len) content[cond_pos..] else "" });

                // Check for opening paren for if branch
                if (cond_pos < content.len and content[cond_pos] == '(') {
                    log.debug("Found opening paren for if branch at position {d}", .{cond_pos});
                    cond_pos += 1;
                    const if_start = cond_pos;
                    // Find matching closing paren for if branch
                    var if_paren_depth: i32 = 1;
                    var if_brace_depth: i32 = 0;
                    while (cond_pos < content.len and if_paren_depth > 0) {
                        if (content[cond_pos] == '(') if_paren_depth += 1;
                        if (content[cond_pos] == ')') if_paren_depth -= 1;
                        if (content[cond_pos] == '{') if_brace_depth += 1;
                        if (content[cond_pos] == '}') if_brace_depth -= 1;
                        if (if_paren_depth > 0) cond_pos += 1;
                    }
                    const if_end = cond_pos;
                    // cond_pos is at the closing paren, advance past it
                    if (cond_pos < content.len and content[cond_pos] == ')') cond_pos += 1;
                    log.debug("After if branch, cond_pos={d}, content[cond_pos..]='{s}'", .{ cond_pos, if (cond_pos < content.len) content[cond_pos..] else "" });

                    // Skip whitespace
                    while (cond_pos < content.len and std.ascii.isWhitespace(content[cond_pos])) cond_pos += 1;

                    // Check for "else"
                    if (cond_pos + 4 <= content.len and std.mem.eql(u8, content[cond_pos .. cond_pos + 4], "else")) {
                        log.debug("Found 'else' at position {d}", .{cond_pos});
                        cond_pos += 4; // Skip "else"

                        // Skip whitespace
                        while (cond_pos < content.len and std.ascii.isWhitespace(content[cond_pos])) cond_pos += 1;

                        // Check for opening paren for else branch
                        if (cond_pos < content.len and content[cond_pos] == '(') {
                            log.debug("Found opening paren for else branch at position {d}", .{cond_pos});
                            cond_pos += 1;
                            const else_start = cond_pos;
                            // Find matching closing paren for else branch
                            var else_paren_depth: i32 = 1;
                            var else_brace_depth: i32 = 0;
                            while (cond_pos < content.len and else_paren_depth > 0) {
                                if (content[cond_pos] == '(') else_paren_depth += 1;
                                if (content[cond_pos] == ')') else_paren_depth -= 1;
                                if (content[cond_pos] == '{') else_brace_depth += 1;
                                if (content[cond_pos] == '}') else_brace_depth -= 1;
                                if (else_paren_depth > 0) cond_pos += 1;
                            }
                            const else_end = cond_pos;
                            log.debug("Found closing paren for else branch at position {d}", .{cond_pos});
                            cond_pos += 1; // Advance past the closing paren of else branch

                            // Extract condition properly
                            var cond_start2 = cond_start + 2; // Skip "if"
                            while (cond_start2 < content.len and std.ascii.isWhitespace(content[cond_start2])) cond_start2 += 1;
                            if (cond_start2 < content.len and content[cond_start2] == '(') {
                                cond_start2 += 1;
                                var cond_end2 = cond_start2;
                                var cond_paren_depth3: i32 = 1;
                                var cond_brace_depth3: i32 = 0;
                                while (cond_end2 < content.len and cond_paren_depth3 > 0) {
                                    if (content[cond_end2] == '(') cond_paren_depth3 += 1;
                                    if (content[cond_end2] == ')') cond_paren_depth3 -= 1;
                                    if (content[cond_end2] == '{') cond_brace_depth3 += 1;
                                    if (content[cond_end2] == '}') cond_brace_depth3 -= 1;
                                    if (cond_paren_depth3 > 0) cond_end2 += 1;
                                }
                                // cond_end2 is now at the closing paren, so the condition is from cond_start2 to cond_end2 (exclusive)
                                const condition_str = content[cond_start2..cond_end2];
                                const if_jsx_content = content[if_start..if_end];
                                const else_jsx_content = content[else_start..else_end];

                                log.debug("Extracted condition: '{s}'", .{condition_str});
                                log.debug("Extracted if branch JSX: '{s}'", .{if_jsx_content});
                                log.debug("Extracted else branch JSX: '{s}'", .{else_jsx_content});

                                // Parse both JSX branches (wrap in fragment if needed)
                                if (parseJsxOrFragment(allocator, if_jsx_content)) |if_elem| {
                                    log.debug("Successfully parsed if branch", .{});
                                    if (parseJsxOrFragment(allocator, else_jsx_content)) |else_elem| {
                                        log.debug("Successfully parsed else branch, adding conditional_expr", .{});
                                        try parent.children.append(allocator, .{ .conditional_expr = .{
                                            .condition = condition_str,
                                            .if_branch = if_elem,
                                            .else_branch = else_elem,
                                        } });
                                        log.debug("Setting i from {d} to {d} (cond_pos), remaining content: '{s}'", .{ i, cond_pos, if (cond_pos < content.len) content[cond_pos..] else "" });
                                        i = cond_pos;
                                        continue;
                                    } else |err| {
                                        log.err("Failed to parse else branch JSX: {any}", .{err});
                                        if_elem.deinit();
                                        allocator.destroy(if_elem);
                                    }
                                } else |err| {
                                    log.err("Failed to parse if branch JSX: {any}", .{err});
                                }
                            }
                        }
                    }
                }
            }
        }

        // Check for for loop expression directly in JSX content: for (iterable) |item| (<JSX>)
        var for_check_pos = i;
        while (for_check_pos < content.len and std.ascii.isWhitespace(content[for_check_pos])) for_check_pos += 1;

        if (for_check_pos + 3 < content.len and std.mem.startsWith(u8, content[for_check_pos..], "for")) {
            log.debug("Found potential for loop expression at position {d} (after whitespace at {d})", .{ for_check_pos, i });
            var for_pos = for_check_pos + 3; // Skip "for"

            // Skip whitespace
            while (for_pos < content.len and std.ascii.isWhitespace(content[for_pos])) for_pos += 1;

            // Check for opening paren
            if (for_pos < content.len and content[for_pos] == '(') {
                for_pos += 1;
                // Find iterable (text between ( and ))
                const iterable_start = for_pos;
                var iterable_end = iterable_start;
                var for_paren_depth: i32 = 1;
                var for_brace_depth: i32 = 0;
                while (iterable_end < content.len and for_paren_depth > 0) {
                    if (content[iterable_end] == '(') for_paren_depth += 1;
                    if (content[iterable_end] == ')') for_paren_depth -= 1;
                    if (content[iterable_end] == '{') for_brace_depth += 1;
                    if (content[iterable_end] == '}') for_brace_depth -= 1;
                    if (for_paren_depth > 0) iterable_end += 1;
                }
                const iterable = content[iterable_start..iterable_end];

                // Skip closing paren and whitespace
                var pipe_pos = iterable_end + 1;
                while (pipe_pos < content.len and std.ascii.isWhitespace(content[pipe_pos])) pipe_pos += 1;

                // Find |item| pattern
                if (pipe_pos < content.len and content[pipe_pos] == '|') {
                    pipe_pos += 1; // Skip opening |
                    const item_start = pipe_pos;
                    while (pipe_pos < content.len and content[pipe_pos] != '|') pipe_pos += 1;

                    if (pipe_pos < content.len and content[pipe_pos] == '|') {
                        const item_name = content[item_start..pipe_pos];
                        pipe_pos += 1; // Skip closing |

                        // Skip whitespace after |
                        while (pipe_pos < content.len and std.ascii.isWhitespace(content[pipe_pos])) pipe_pos += 1;

                        // Check for opening paren: for (iterable) |item| (<JSX>)
                        if (pipe_pos < content.len and content[pipe_pos] == '(') {
                            pipe_pos += 1; // Skip opening paren
                            // Find matching closing paren, accounting for nested braces from expressions like {switch ...}
                            const jsx_content_start = pipe_pos;
                            var jsx_content_end = pipe_pos;
                            for_paren_depth = 1;
                            for_brace_depth = 0;
                            while (jsx_content_end < content.len and for_paren_depth > 0) {
                                if (content[jsx_content_end] == '(') for_paren_depth += 1;
                                if (content[jsx_content_end] == ')') for_paren_depth -= 1;
                                if (content[jsx_content_end] == '{') for_brace_depth += 1;
                                if (content[jsx_content_end] == '}') for_brace_depth -= 1;
                                if (for_paren_depth > 0) jsx_content_end += 1;
                            }
                            const jsx_content = content[jsx_content_start..jsx_content_end];

                            // Parse JSX body - wrap in fragment if needed
                            var body_elem: *ZXElement = undefined;
                            if (parseJsx(allocator, jsx_content)) |parsed_elem| {
                                log.debug("Successfully parsed for loop JSX body as JSX element", .{});
                                body_elem = parsed_elem;
                            } else |_| {
                                // Content doesn't start with <, so wrap it in a fragment and parse as children
                                log.debug("JSX content doesn't start with <, wrapping in fragment", .{});
                                body_elem = try ZXElement.init(allocator, "fragment");
                                try parseJsxChildren(allocator, body_elem, jsx_content);
                            }

                            try parent.children.append(allocator, .{ .for_loop_expr = .{
                                .iterable = iterable,
                                .item_name = item_name,
                                .body = body_elem,
                            } });

                            // Advance past the closing paren
                            if (jsx_content_end < content.len and content[jsx_content_end] == ')') jsx_content_end += 1;
                            i = jsx_content_end;
                            continue;
                        }
                    }
                }
            }
        }

        // Regular text
        const text_start = i;
        while (i < content.len and content[i] != '<' and content[i] != '{') {
            i += 1;
        }

        if (i > text_start) {
            const text = content[text_start..i];

            // Check if text has any non-whitespace content
            var has_content = false;
            for (text) |c| {
                if (!std.ascii.isWhitespace(c)) {
                    has_content = true;
                    break;
                }
            }

            // Only add if it has non-whitespace content
            // Preserve spaces as they may be meaningful (e.g., " #" should keep the space)
            if (has_content) {
                try parent.children.append(allocator, .{ .text = text });
            }
        }
    }
}

/// Check if a tag name is a custom component (starts with uppercase)
fn isCustomComponent(tag: []const u8) bool {
    if (tag.len == 0) return false;
    return std.ascii.isUpper(tag[0]);
}

/// Render JSX element as zx.zx() function call using tokens
fn renderJsxAsTokens(allocator: std.mem.Allocator, output: *TokenBuilder, elem: *ZXElement, indent: usize) !void {
    try renderJsxAsTokensWithLoopContext(allocator, output, elem, indent, null, null);
}

/// Render JSX element with optional loop context for variable substitution
fn renderJsxAsTokensWithLoopContext(allocator: std.mem.Allocator, output: *TokenBuilder, elem: *ZXElement, indent: usize, loop_iterable: ?[]const u8, loop_item: ?[]const u8) !void {
    // Check if this is a custom component
    if (isCustomComponent(elem.tag)) {
        // For custom components, wrap in lazy: _zx.lazy(Component, props)
        try output.addToken(.identifier, "_zx");
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "lazy");
        try output.addToken(.l_paren, "(");
        try output.addToken(.identifier, elem.tag);
        try output.addToken(.comma, ",");

        // Build props struct from attributes with explicit type
        if (elem.attributes.items.len > 0) {
            try output.addToken(.period, ".");
            try output.addToken(.l_brace, "{");
            for (elem.attributes.items, 0..) |attr, i| {
                try output.addToken(.period, ".");
                try output.addToken(.identifier, attr.name);
                try output.addToken(.equal, "=");
                switch (attr.value) {
                    .static => |val| {
                        const value_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{val});
                        defer allocator.free(value_buf);
                        try output.addToken(.string_literal, value_buf);
                    },
                    .dynamic => |expr| {
                        try output.addToken(.identifier, expr);
                    },
                    .format => |fmt| {
                        // Format expression: use std.fmt.allocPrint(allocator, "{format}", .{expr}) for attribute values
                        try output.addToken(.identifier, "std");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "fmt");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "allocPrint");
                        try output.addToken(.l_paren, "(");
                        try output.addToken(.identifier, "allocator");
                        try output.addToken(.comma, ",");

                        // Format string: "{format}"
                        const format_str = try std.fmt.allocPrint(allocator, "\"{{{s}}}\"", .{fmt.format});
                        defer allocator.free(format_str);
                        try output.addToken(.string_literal, format_str);
                        try output.addToken(.comma, ",");

                        // Expression wrapped in tuple: .{expr}
                        try output.addToken(.invalid, " ");
                        try output.addToken(.period, ".");
                        try output.addToken(.l_brace, "{");
                        try output.addToken(.identifier, fmt.expr);
                        try output.addToken(.r_brace, "}");
                        try output.addToken(.r_paren, ")");
                    },
                }
                if (i < elem.attributes.items.len - 1) {
                    try output.addToken(.comma, ",");
                }
            }
            try output.addToken(.r_brace, "}");
        } else {
            // Empty props struct with explicit type
            try output.addToken(.period, ".");
            try output.addToken(.l_brace, "{");
            try output.addToken(.r_brace, "}");
        }

        try output.addToken(.r_paren, ")");
        return;
    }

    // _zx.zx(
    try output.addToken(.identifier, "_zx");
    try output.addToken(.period, ".");
    try output.addToken(.identifier, "zx");
    try output.addToken(.l_paren, "(");
    try output.addToken(.invalid, "\n");

    // Tag: .button,
    try addIndentTokens(output, indent + 1);
    try output.addToken(.period, ".");
    try output.addToken(.identifier, elem.tag);
    try output.addToken(.comma, ",");
    try output.addToken(.invalid, "\n");

    // Options struct: .{
    try addIndentTokens(output, indent + 1);
    try output.addToken(.period, ".");
    try output.addToken(.l_brace, "{");
    try output.addToken(.invalid, "\n");

    // Options.allocator = allocator;
    if (elem.builtin_allocator) |allocator_expr| {
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "allocator");
        try output.addToken(.equal, "=");
        try output.addToken(.identifier, allocator_expr);
        try output.addToken(.comma, ",");
        try output.addToken(.invalid, "\n");
    }

    // Attributes
    if (elem.attributes.items.len > 0) {
        try addIndentTokens(output, indent + 2);
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "attributes");
        try output.addToken(.equal, "=");
        try output.addToken(.ampersand, "&");
        try output.addToken(.period, ".");
        try output.addToken(.l_brace, "{");
        try output.addToken(.invalid, "\n");

        for (elem.attributes.items) |attr| {
            try addIndentTokens(output, indent + 3);
            try output.addToken(.period, ".");
            try output.addToken(.l_brace, "{");

            try output.addToken(.period, ".");
            try output.addToken(.identifier, "name");
            try output.addToken(.equal, "=");

            const name_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{attr.name});
            defer allocator.free(name_buf);
            try output.addToken(.string_literal, name_buf);
            try output.addToken(.comma, ",");

            try output.addToken(.period, ".");
            try output.addToken(.identifier, "value");
            try output.addToken(.equal, "=");

            switch (attr.value) {
                .static => |val| {
                    // Static string value
                    const value_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{val});
                    defer allocator.free(value_buf);
                    try output.addToken(.string_literal, value_buf);
                },
                .dynamic => |expr| {
                    // Dynamic expression - output as-is
                    try output.addToken(.identifier, expr);
                },
                .format => |fmt| {
                    // Format expression: pass expression directly and set format field
                    // .value = expr (expression as-is)
                    try output.addToken(.identifier, fmt.expr);
                    try output.addToken(.comma, ",");
                    try output.addToken(.invalid, "\n");

                    // .format = "{format}"
                    try addIndentTokens(output, indent + 3);
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "format");
                    try output.addToken(.equal, "=");
                    const format_str = try std.fmt.allocPrint(allocator, "\"{{{s}}}\"", .{fmt.format});
                    defer allocator.free(format_str);
                    try output.addToken(.string_literal, format_str);
                },
            }

            try output.addToken(.r_brace, "}");
            try output.addToken(.comma, ",");
            try output.addToken(.invalid, "\n");
        }

        try addIndentTokens(output, indent + 2);
        try output.addToken(.r_brace, "}");
        try output.addToken(.comma, ",");
        try output.addToken(.invalid, "\n");
    }

    // Children
    if (elem.children.items.len > 0) {
        try addIndentTokens(output, indent + 2);
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "children");
        try output.addToken(.equal, "=");

        // Special case: if the only child is a for_loop_expr, assign it directly (blk returns an array)
        if (elem.children.items.len == 1 and elem.children.items[0] == .for_loop_expr) {
            const for_loop = elem.children.items[0].for_loop_expr;

            // Render the blk directly without &.{ ... } wrapper
            try output.addToken(.invalid, " ");
            try output.addToken(.identifier, "blk");
            try output.addToken(.colon, ":");
            try output.addToken(.invalid, " ");
            try output.addToken(.l_brace, "{");
            try output.addToken(.invalid, "\n");

            // const __zx_children = _zx.getAllocator().alloc(zx.Component, iterable.len) catch unreachable;
            try addIndentTokens(output, indent + 3);
            try output.addToken(.keyword_const, "const");
            try output.addToken(.invalid, " ");
            try output.addToken(.identifier, "__zx_children");
            try output.addToken(.invalid, " ");
            try output.addToken(.equal, "=");
            try output.addToken(.invalid, " ");
            try output.addToken(.identifier, "_zx");
            try output.addToken(.period, ".");
            try output.addToken(.identifier, "getAllocator");
            try output.addToken(.l_paren, "(");
            try output.addToken(.r_paren, ")");
            try output.addToken(.period, ".");
            try output.addToken(.identifier, "alloc");
            try output.addToken(.l_paren, "(");
            try output.addToken(.identifier, "zx");
            try output.addToken(.period, ".");
            try output.addToken(.identifier, "Component");
            try output.addToken(.comma, ",");
            try output.addToken(.invalid, " ");
            try output.addToken(.identifier, for_loop.iterable);
            try output.addToken(.period, ".");
            try output.addToken(.identifier, "len");
            try output.addToken(.r_paren, ")");
            try output.addToken(.invalid, " ");
            try output.addToken(.keyword_catch, "catch");
            try output.addToken(.invalid, " ");
            try output.addToken(.keyword_unreachable, "unreachable");
            try output.addToken(.semicolon, ";");
            try output.addToken(.invalid, "\n");

            // for (iterable, 0..) |item, i| {
            try addIndentTokens(output, indent + 3);
            try output.addToken(.keyword_for, "for");
            try output.addToken(.invalid, " ");
            try output.addToken(.l_paren, "(");
            try output.addToken(.identifier, for_loop.iterable);
            try output.addToken(.comma, ",");
            try output.addToken(.invalid, " ");
            try output.addToken(.identifier, "0");
            try output.addToken(.period, ".");
            try output.addToken(.period, ".");
            try output.addToken(.r_paren, ")");
            try output.addToken(.invalid, " ");
            try output.addToken(.pipe, "|");
            try output.addToken(.identifier, for_loop.item_name);
            try output.addToken(.comma, ",");
            try output.addToken(.invalid, " ");
            try output.addToken(.identifier, "i");
            try output.addToken(.pipe, "|");
            try output.addToken(.invalid, " ");
            try output.addToken(.l_brace, "{");
            try output.addToken(.invalid, "\n");

            // __zx_children[i] = _zx.zx(...);
            try addIndentTokens(output, indent + 4);
            try output.addToken(.identifier, "__zx_children");
            try output.addToken(.l_bracket, "[");
            try output.addToken(.identifier, "i");
            try output.addToken(.r_bracket, "]");
            try output.addToken(.invalid, " ");
            try output.addToken(.equal, "=");
            try output.addToken(.invalid, " ");
            try renderJsxAsTokensWithLoopContext(allocator, output, for_loop.body, indent + 4, for_loop.iterable, for_loop.item_name);
            try output.addToken(.semicolon, ";");
            try output.addToken(.invalid, "\n");

            // }
            try addIndentTokens(output, indent + 3);
            try output.addToken(.r_brace, "}");
            try output.addToken(.invalid, "\n");

            // break :blk __zx_children;
            try addIndentTokens(output, indent + 3);
            try output.addToken(.keyword_break, "break");
            try output.addToken(.invalid, " ");
            try output.addToken(.colon, ":");
            try output.addToken(.identifier, "blk");
            try output.addToken(.invalid, " ");
            try output.addToken(.identifier, "__zx_children");
            try output.addToken(.semicolon, ";");
            try output.addToken(.invalid, "\n");

            // }
            try addIndentTokens(output, indent + 2);
            try output.addToken(.r_brace, "}");
            try output.addToken(.comma, ",");
            try output.addToken(.invalid, "\n");
        } else {
            // Multiple children or non-for-loop child: use array syntax
            try output.addToken(.ampersand, "&");
            try output.addToken(.period, ".");
            try output.addToken(.l_brace, "{");
            try output.addToken(.invalid, "\n");

            for (elem.children.items) |child| {
                try addIndentTokens(output, indent + 3);
                switch (child) {
                    .text => |text| {
                        // Use _zx.txt("text")
                        try output.addToken(.identifier, "_zx");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "txt");
                        try output.addToken(.l_paren, "(");

                        const escaped_text = try escapeTextForStringLiteral(allocator, text);
                        defer allocator.free(escaped_text);
                        const text_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_text});
                        defer allocator.free(text_buf);
                        try output.addToken(.string_literal, text_buf);

                        try output.addToken(.r_paren, ")");
                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, "\n");
                    },
                    .text_expr => |expr| {
                        // Use _zx.txt(expr)
                        try output.addToken(.identifier, "_zx");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "txt");
                        try output.addToken(.l_paren, "(");
                        try output.addToken(.identifier, expr);
                        try output.addToken(.r_paren, ")");
                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, "\n");
                    },
                    .format_expr => |fmt| {
                        // Use _zx.fmt("{format}", .{expr})
                        try output.addToken(.identifier, "_zx");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "fmt");
                        try output.addToken(.l_paren, "(");

                        // Format string: "{format}"
                        const format_str = try std.fmt.allocPrint(allocator, "\"{{{s}}}\"", .{fmt.format});
                        defer allocator.free(format_str);
                        try output.addToken(.string_literal, format_str);
                        try output.addToken(.comma, ",");

                        // Expression wrapped in tuple: .{expr}
                        // If we're in a loop and expr matches loop item, use the loop item directly
                        try output.addToken(.period, ".");
                        try output.addToken(.l_brace, "{");
                        if (loop_item) |item| {
                            if (std.mem.eql(u8, fmt.expr, item)) {
                                // Use the loop item directly (already captured in the loop)
                                try output.addToken(.identifier, item);
                            } else {
                                try output.addToken(.identifier, fmt.expr);
                            }
                        } else {
                            try output.addToken(.identifier, fmt.expr);
                        }
                        try output.addToken(.r_brace, "}");
                        try output.addToken(.r_paren, ")");
                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, "\n");
                    },
                    .component_expr => |expr| {
                        // Component expression: {(expr)} - use directly without wrapping
                        try output.addToken(.identifier, expr);
                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, "\n");
                    },
                    .conditional_expr => |cond| {
                        // Conditional expression: {if (cond) (<JSX>) else (<JSX>)}
                        // Render as: if (condition) <render if_branch> else <render else_branch>
                        log.debug("Rendering conditional_expr with condition: '{s}'", .{cond.condition});
                        try output.addToken(.keyword_if, "if");
                        try output.addToken(.l_paren, "(");
                        // Render condition as raw text (may contain dots, function calls, etc.)
                        try output.addToken(.invalid, cond.condition);
                        try output.addToken(.r_paren, ")");
                        try output.addToken(.invalid, " ");

                        // Render if branch
                        try renderJsxAsTokensWithLoopContext(allocator, output, cond.if_branch, indent + 3, loop_iterable, loop_item);

                        try output.addToken(.invalid, " ");
                        try output.addToken(.keyword_else, "else");
                        try output.addToken(.invalid, " ");

                        // Render else branch
                        try renderJsxAsTokensWithLoopContext(allocator, output, cond.else_branch, indent + 3, loop_iterable, loop_item);

                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, "\n");
                    },
                    .for_loop_expr => |for_loop| {
                        // For loop expression: {for (iterable) |item| (<JSX>)}
                        // Render as: blk: { const children = allocator.alloc(...); for (...) { ... }; break :blk children; }
                        try output.addToken(.identifier, "blk");
                        try output.addToken(.colon, ":");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.l_brace, "{");
                        try output.addToken(.invalid, "\n");

                        // const __zx_children = _zx.getAllocator().alloc(zx.Component, iterable.len) catch unreachable;
                        try addIndentTokens(output, indent + 4);
                        try output.addToken(.keyword_const, "const");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.identifier, "__zx_children");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.equal, "=");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.identifier, "_zx");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "getAllocator");
                        try output.addToken(.l_paren, "(");
                        try output.addToken(.r_paren, ")");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "alloc");
                        try output.addToken(.l_paren, "(");
                        try output.addToken(.identifier, "zx");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "Component");
                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.identifier, for_loop.iterable);
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "len");
                        try output.addToken(.r_paren, ")");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.keyword_catch, "catch");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.keyword_unreachable, "unreachable");
                        try output.addToken(.semicolon, ";");
                        try output.addToken(.invalid, "\n");

                        // for (__zx_children, 0..) |*__zx_child, i| {
                        try addIndentTokens(output, indent + 4);
                        try output.addToken(.keyword_for, "for");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.l_paren, "(");
                        try output.addToken(.identifier, "__zx_children");
                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.identifier, "0");
                        try output.addToken(.period, ".");
                        try output.addToken(.period, ".");
                        try output.addToken(.r_paren, ")");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.pipe, "|");
                        try output.addToken(.asterisk, "*");
                        try output.addToken(.identifier, "__zx_child");
                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.identifier, "i");
                        try output.addToken(.pipe, "|");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.l_brace, "{");
                        try output.addToken(.invalid, "\n");

                        // __zx_child.* = _zx.zx(...);
                        try addIndentTokens(output, indent + 5);
                        try output.addToken(.identifier, "__zx_child");
                        try output.addToken(.period, ".");
                        try output.addToken(.asterisk, "*");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.equal, "=");
                        try output.addToken(.invalid, " ");
                        try renderJsxAsTokensWithLoopContext(allocator, output, for_loop.body, indent + 5, for_loop.iterable, for_loop.item_name);
                        try output.addToken(.semicolon, ";");
                        try output.addToken(.invalid, "\n");

                        // }
                        try addIndentTokens(output, indent + 3);
                        try output.addToken(.r_brace, "}");
                        try output.addToken(.invalid, "\n");

                        // break :blk __zx_children;
                        try addIndentTokens(output, indent + 3);
                        try output.addToken(.keyword_break, "break");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.colon, ":");
                        try output.addToken(.identifier, "blk");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.identifier, "__zx_children");
                        try output.addToken(.semicolon, ";");
                        try output.addToken(.invalid, "\n");

                        // }
                        try addIndentTokens(output, indent + 2);
                        try output.addToken(.r_brace, "}");
                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, "\n");
                    },
                    .switch_expr => |switch_expr| {
                        // Switch expression: {switch (expr) { case => value, ... }}
                        // Render as: switch (expr) { case => value, ... }
                        try output.addToken(.invalid, "switch");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.l_paren, "(");
                        try output.addToken(.identifier, switch_expr.expr);
                        try output.addToken(.r_paren, ")");
                        try output.addToken(.invalid, " ");
                        try output.addToken(.l_brace, "{");
                        try output.addToken(.invalid, "\n");

                        for (switch_expr.cases.items) |switch_case| {
                            try addIndentTokens(output, indent + 4);
                            // Pattern (e.g., .admin)
                            // Patterns start with a period, so output it
                            if (switch_case.pattern.len > 0 and switch_case.pattern[0] == '.') {
                                try output.addToken(.period, ".");
                                if (switch_case.pattern.len > 1) {
                                    try output.addToken(.identifier, switch_case.pattern[1..]);
                                }
                            } else {
                                try output.addToken(.identifier, switch_case.pattern);
                            }
                            try output.addToken(.invalid, " ");
                            try output.addToken(.invalid, "=>");
                            try output.addToken(.invalid, " ");

                            switch (switch_case.value) {
                                .string_literal => |str| {
                                    // String literal: _zx.txt("Admin")
                                    try output.addToken(.identifier, "_zx");
                                    try output.addToken(.period, ".");
                                    try output.addToken(.identifier, "txt");
                                    try output.addToken(.l_paren, "(");
                                    const str_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{str});
                                    defer allocator.free(str_buf);
                                    try output.addToken(.string_literal, str_buf);
                                    try output.addToken(.r_paren, ")");
                                },
                                .jsx_element => |jsx_elem| {
                                    // JSX element: _zx.zx(.p, .{ ... })
                                    try renderJsxAsTokensWithLoopContext(allocator, output, jsx_elem, indent + 4, loop_iterable, loop_item);
                                },
                                .conditional_expr => |cond| {
                                    // Conditional expression: if (condition) <render if_branch> else <render else_branch>
                                    try output.addToken(.keyword_if, "if");
                                    try output.addToken(.l_paren, "(");
                                    // Render condition as raw text (may contain dots, function calls, etc.)
                                    try output.addToken(.invalid, cond.condition);
                                    try output.addToken(.r_paren, ")");
                                    try output.addToken(.invalid, " ");

                                    // Render if branch
                                    try renderJsxAsTokensWithLoopContext(allocator, output, cond.if_branch, indent + 4, loop_iterable, loop_item);

                                    try output.addToken(.invalid, " ");
                                    try output.addToken(.keyword_else, "else");
                                    try output.addToken(.invalid, " ");

                                    // Render else branch
                                    try renderJsxAsTokensWithLoopContext(allocator, output, cond.else_branch, indent + 4, loop_iterable, loop_item);
                                },
                            }

                            try output.addToken(.comma, ",");
                            try output.addToken(.invalid, "\n");
                        }

                        try addIndentTokens(output, indent + 3);
                        try output.addToken(.r_brace, "}");
                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, "\n");
                    },
                    .element => |child_elem| {
                        // Check if this is a custom component
                        if (isCustomComponent(child_elem.tag)) {
                            // For custom components, wrap in lazy: _zx.lazy(Component, props)
                            try output.addToken(.identifier, "_zx");
                            try output.addToken(.period, ".");
                            try output.addToken(.identifier, "lazy");
                            try output.addToken(.l_paren, "(");
                            try output.addToken(.identifier, child_elem.tag);
                            try output.addToken(.comma, ",");

                            // Build props struct from attributes with explicit type
                            if (child_elem.attributes.items.len > 0) {
                                try output.addToken(.period, ".");
                                try output.addToken(.l_brace, "{");
                                for (child_elem.attributes.items, 0..) |attr, i| {
                                    try output.addToken(.period, ".");
                                    try output.addToken(.identifier, attr.name);
                                    try output.addToken(.equal, "=");
                                    switch (attr.value) {
                                        .static => |val| {
                                            const value_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{val});
                                            defer allocator.free(value_buf);
                                            try output.addToken(.string_literal, value_buf);
                                        },
                                        .dynamic => |expr| {
                                            try output.addToken(.identifier, expr);
                                        },
                                        .format => |fmt| {
                                            // Format expression: pass expression directly and set format field
                                            // .value = expr (expression as-is)
                                            try output.addToken(.identifier, fmt.expr);
                                            try output.addToken(.comma, ",");
                                            try output.addToken(.invalid, "\n");

                                            // .format = "{format}"
                                            try addIndentTokens(output, indent + 4);
                                            try output.addToken(.period, ".");
                                            try output.addToken(.identifier, "format");
                                            try output.addToken(.equal, "=");
                                            const format_str = try std.fmt.allocPrint(allocator, "\"{{{s}}}\"", .{fmt.format});
                                            defer allocator.free(format_str);
                                            try output.addToken(.string_literal, format_str);
                                        },
                                    }
                                    if (i < child_elem.attributes.items.len - 1) {
                                        try output.addToken(.comma, ",");
                                    }
                                }
                                try output.addToken(.r_brace, "}");
                            } else {
                                // Empty props struct with explicit type
                                try output.addToken(.period, ".");
                                try output.addToken(.l_brace, "{");
                                try output.addToken(.r_brace, "}");
                            }

                            try output.addToken(.r_paren, ")");
                            try output.addToken(.comma, ",");
                            try output.addToken(.invalid, "\n");
                        } else {
                            // Use _zx.zx(.tag, .{ ... }) for nested elements - recursively call with loop context
                            try renderJsxAsTokensWithLoopContext(allocator, output, child_elem, indent + 3, loop_iterable, loop_item);
                            try output.addToken(.comma, ",");
                            try output.addToken(.invalid, "\n");
                        }
                    },
                    .raw_svg_content => |raw_content| {
                        // For SVG tags: use _zx.fmt("{s}", .{raw_content}) to output unescaped content
                        try output.addToken(.identifier, "_zx");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "fmt");
                        try output.addToken(.l_paren, "(");

                        // Format string: "{s}"
                        try output.addToken(.string_literal, "\"{s}\"");
                        try output.addToken(.comma, ",");

                        // Expression wrapped in tuple: .{raw_content}
                        try output.addToken(.period, ".");
                        try output.addToken(.l_brace, "{");

                        // Create a variable name for the raw content
                        // We need to escape the string for use in a string literal
                        const escaped_content = try escapeTextForStringLiteral(allocator, raw_content);
                        defer allocator.free(escaped_content);
                        const content_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_content});
                        defer allocator.free(content_buf);
                        try output.addToken(.string_literal, content_buf);

                        try output.addToken(.r_brace, "}");
                        try output.addToken(.r_paren, ")");
                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, "\n");
                    },
                }
            }

            try addIndentTokens(output, indent + 2);
            try output.addToken(.r_brace, "}");
            try output.addToken(.comma, ",");
            try output.addToken(.invalid, "\n");
        }
    }

    // Close options struct
    try addIndentTokens(output, indent + 1);
    try output.addToken(.r_brace, "}");
    try output.addToken(.comma, ",");
    try output.addToken(.invalid, "\n");

    try addIndentTokens(output, indent);
    try output.addToken(.r_paren, ")");
}

/// Render nested elements recursively using _zx.zx() calls
fn renderNestedElementAsCall(allocator: std.mem.Allocator, output: *TokenBuilder, elem: *ZXElement, indent: usize) !void {
    // Check if this is a custom component
    if (isCustomComponent(elem.tag)) {
        // For custom components, wrap in lazy: _zx.lazy(Component, props)
        try output.addToken(.identifier, "_zx");
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "lazy");
        try output.addToken(.l_paren, "(");
        try output.addToken(.identifier, elem.tag);
        try output.addToken(.comma, ",");

        // Build props struct from attributes with explicit type
        if (elem.attributes.items.len > 0) {
            try output.addToken(.period, ".");
            try output.addToken(.l_brace, "{");
            for (elem.attributes.items, 0..) |attr, i| {
                try output.addToken(.period, ".");
                try output.addToken(.identifier, attr.name);
                try output.addToken(.equal, "=");
                switch (attr.value) {
                    .static => |val| {
                        const value_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{val});
                        defer allocator.free(value_buf);
                        try output.addToken(.string_literal, value_buf);
                    },
                    .dynamic => |expr| {
                        try output.addToken(.identifier, expr);
                    },
                    .format => |fmt| {
                        // Format expression: use std.fmt.allocPrint(allocator, "{format}", .{expr}) for attribute values
                        try output.addToken(.identifier, "std");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "fmt");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "allocPrint");
                        try output.addToken(.l_paren, "(");
                        try output.addToken(.identifier, "allocator");
                        try output.addToken(.comma, ",");

                        // Format string: "{format}"
                        const format_str = try std.fmt.allocPrint(allocator, "\"{{{s}}}\"", .{fmt.format});
                        defer allocator.free(format_str);
                        try output.addToken(.string_literal, format_str);
                        try output.addToken(.comma, ",");

                        // Expression wrapped in tuple: .{expr}
                        try output.addToken(.invalid, " ");
                        try output.addToken(.period, ".");
                        try output.addToken(.l_brace, "{");
                        try output.addToken(.identifier, fmt.expr);
                        try output.addToken(.r_brace, "}");
                        try output.addToken(.r_paren, ")");
                    },
                }
                if (i < elem.attributes.items.len - 1) {
                    try output.addToken(.comma, ",");
                }
            }
            try output.addToken(.r_brace, "}");
        } else {
            // Empty props struct with explicit type
            try output.addToken(.period, ".");
            try output.addToken(.l_brace, "{");
            try output.addToken(.r_brace, "}");
        }

        try output.addToken(.r_paren, ")");
        return;
    }

    // For regular elements, use _zx.zx()
    try output.addToken(.identifier, "_zx");
    try output.addToken(.period, ".");
    try output.addToken(.identifier, "zx");
    try output.addToken(.l_paren, "(");
    try output.addToken(.period, ".");
    try output.addToken(.identifier, elem.tag);
    try output.addToken(.comma, ",");
    try output.addToken(.period, ".");
    try output.addToken(.l_brace, "{");
    try output.addToken(.invalid, "\n");

    // Options.allocator = allocator;
    if (elem.builtin_allocator) |allocator_expr| {
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "allocator");
        try output.addToken(.equal, "=");
        try output.addToken(.identifier, allocator_expr);
        try output.addToken(.comma, ",");
        try output.addToken(.invalid, "\n");
    }

    // Attributes
    if (elem.attributes.items.len > 0) {
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "attributes");
        try output.addToken(.equal, "=");
        try output.addToken(.ampersand, "&");
        try output.addToken(.period, ".");
        try output.addToken(.l_brace, "{");

        for (elem.attributes.items) |attr| {
            try output.addToken(.period, ".");
            try output.addToken(.l_brace, "{");
            try output.addToken(.period, ".");
            try output.addToken(.identifier, "name");
            try output.addToken(.equal, "=");

            const name_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{attr.name});
            defer allocator.free(name_buf);
            try output.addToken(.string_literal, name_buf);
            try output.addToken(.comma, ",");

            try output.addToken(.period, ".");
            try output.addToken(.identifier, "value");
            try output.addToken(.equal, "=");

            switch (attr.value) {
                .static => |val| {
                    const value_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{val});
                    defer allocator.free(value_buf);
                    try output.addToken(.string_literal, value_buf);
                },
                .dynamic => |expr| {
                    try output.addToken(.identifier, expr);
                },
                .format => |fmt| {
                    // Format expression: pass expression directly and set format field
                    // .value = expr (expression as-is)
                    try output.addToken(.identifier, fmt.expr);
                    try output.addToken(.comma, ",");
                    try output.addToken(.invalid, "\n");

                    // .format = "{format}"
                    try addIndentTokens(output, indent + 3);
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "format");
                    try output.addToken(.equal, "=");
                    const format_str = try std.fmt.allocPrint(allocator, "\"{{{s}}}\"", .{fmt.format});
                    defer allocator.free(format_str);
                    try output.addToken(.string_literal, format_str);
                },
            }

            try output.addToken(.r_brace, "}");
            try output.addToken(.comma, ",");
        }

        try output.addToken(.r_brace, "}");
        try output.addToken(.comma, ",");
    }

    // Children
    if (elem.children.items.len > 0) {
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "children");
        try output.addToken(.equal, "=");
        try output.addToken(.ampersand, "&");
        try output.addToken(.period, ".");
        try output.addToken(.l_brace, "{");

        for (elem.children.items) |child| {
            switch (child) {
                .text => |text| {
                    try output.addToken(.identifier, "_zx");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "txt");
                    try output.addToken(.l_paren, "(");

                    const escaped_text = try escapeTextForStringLiteral(allocator, text);
                    defer allocator.free(escaped_text);
                    const text_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_text});
                    defer allocator.free(text_buf);
                    try output.addToken(.string_literal, text_buf);

                    try output.addToken(.r_paren, ")");
                    try output.addToken(.comma, ",");
                },
                .text_expr => |expr| {
                    try output.addToken(.identifier, "_zx");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "txt");
                    try output.addToken(.l_paren, "(");
                    try output.addToken(.identifier, expr);
                    try output.addToken(.r_paren, ")");
                    try output.addToken(.comma, ",");
                },
                .format_expr => |fmt| {
                    try output.addToken(.identifier, "_zx");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "fmt");
                    try output.addToken(.l_paren, "(");

                    const format_str = try std.fmt.allocPrint(allocator, "\"{{{s}}}\"", .{fmt.format});
                    defer allocator.free(format_str);
                    try output.addToken(.string_literal, format_str);
                    try output.addToken(.comma, ",");

                    // Expression wrapped in tuple: .{expr}
                    try output.addToken(.period, ".");
                    try output.addToken(.l_brace, "{");
                    try output.addToken(.identifier, fmt.expr);
                    try output.addToken(.r_brace, "}");
                    try output.addToken(.r_paren, ")");
                    try output.addToken(.comma, ",");
                },
                .component_expr => |expr| {
                    // Component expression: {(expr)} - use directly without wrapping
                    try output.addToken(.identifier, expr);
                    try output.addToken(.comma, ",");
                },
                .conditional_expr => |cond| {
                    // Conditional expression: {if (cond) (<JSX>) else (<JSX>)}
                    try output.addToken(.keyword_if, "if");
                    try output.addToken(.l_paren, "(");
                    // Render condition as raw text (may contain dots, function calls, etc.)
                    try output.addToken(.invalid, cond.condition);
                    try output.addToken(.r_paren, ")");
                    try output.addToken(.invalid, " ");

                    // Render if branch
                    try renderNestedElementAsCall(allocator, output, cond.if_branch, indent);

                    try output.addToken(.invalid, " ");
                    try output.addToken(.keyword_else, "else");
                    try output.addToken(.invalid, " ");

                    // Render else branch
                    try renderNestedElementAsCall(allocator, output, cond.else_branch, indent);

                    try output.addToken(.comma, ",");
                },
                .for_loop_expr => |for_loop| {
                    // For loop expression - same structure but adjust indentation
                    try output.addToken(.identifier, "blk");
                    try output.addToken(.colon, ":");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.l_brace, "{");

                    try output.addToken(.keyword_const, "const");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.identifier, "children");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.equal, "=");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.identifier, "allocator");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "alloc");
                    try output.addToken(.l_paren, "(");
                    try output.addToken(.identifier, "zx");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "Component");
                    try output.addToken(.comma, ",");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.identifier, for_loop.iterable);
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "len");
                    try output.addToken(.r_paren, ")");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.keyword_catch, "catch");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.keyword_unreachable, "unreachable");
                    try output.addToken(.semicolon, ";");

                    try output.addToken(.keyword_for, "for");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.l_paren, "(");
                    try output.addToken(.identifier, "children");
                    try output.addToken(.comma, ",");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.identifier, "0");
                    try output.addToken(.period, ".");
                    try output.addToken(.period, ".");
                    try output.addToken(.r_paren, ")");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.pipe, "|");
                    try output.addToken(.asterisk, "*");
                    try output.addToken(.identifier, "child");
                    try output.addToken(.comma, ",");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.identifier, "i");
                    try output.addToken(.pipe, "|");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.l_brace, "{");

                    try output.addToken(.identifier, "child");
                    try output.addToken(.period, ".");
                    try output.addToken(.asterisk, "*");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.equal, "=");
                    try output.addToken(.invalid, " ");
                    try renderNestedElementAsCall(allocator, output, for_loop.body, indent);
                    try output.addToken(.semicolon, ";");

                    try output.addToken(.r_brace, "}");

                    try output.addToken(.keyword_break, "break");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.colon, ":");
                    try output.addToken(.identifier, "blk");
                    try output.addToken(.invalid, " ");
                    try output.addToken(.identifier, "children");
                    try output.addToken(.semicolon, ";");

                    try output.addToken(.r_brace, "}");
                    try output.addToken(.comma, ",");
                },
                .element => |nested_elem| {
                    // Recursively render nested elements
                    try renderNestedElementAsCall(allocator, output, nested_elem, indent);
                    try output.addToken(.comma, ",");
                },
                .raw_svg_content => |raw_content| {
                    // For SVG tags: use _zx.fmt("{s}", .{raw_content}) to output unescaped content
                    try output.addToken(.identifier, "_zx");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "fmt");
                    try output.addToken(.l_paren, "(");

                    // Format string: "{s}"
                    try output.addToken(.string_literal, "\"{s}\"");
                    try output.addToken(.comma, ",");

                    // Expression wrapped in tuple: .{raw_content}
                    try output.addToken(.period, ".");
                    try output.addToken(.l_brace, "{");

                    // Escape the string for use in a string literal
                    const escaped_content = try escapeTextForStringLiteral(allocator, raw_content);
                    defer allocator.free(escaped_content);
                    const content_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_content});
                    defer allocator.free(content_buf);
                    try output.addToken(.string_literal, content_buf);

                    try output.addToken(.r_brace, "}");
                    try output.addToken(.r_paren, ")");
                    try output.addToken(.comma, ",");
                },
            }
        }

        try output.addToken(.r_brace, "}");
        try output.addToken(.comma, ",");
    }

    try output.addToken(.r_brace, "}");
    try output.addToken(.r_paren, ")");
}

/// Render an element as a struct (for nested elements)
fn renderElementAsStruct(allocator: std.mem.Allocator, output: *TokenBuilder, elem: *ZXElement, indent: usize) !void {
    // Check if this is a custom component
    if (isCustomComponent(elem.tag)) {
        // For custom components, call the function and get its .element
        try output.addToken(.identifier, elem.tag);
        try output.addToken(.l_paren, "(");
        try output.addToken(.r_paren, ")");
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "element");
        return;
    }

    try output.addToken(.period, ".");
    try output.addToken(.l_brace, "{");
    try output.addToken(.invalid, "\n");

    // Tag
    try addIndentTokens(output, indent + 1);
    try output.addToken(.period, ".");
    try output.addToken(.identifier, "tag");
    try output.addToken(.equal, "=");
    try output.addToken(.period, ".");
    try output.addToken(.identifier, elem.tag);
    try output.addToken(.comma, ",");
    try output.addToken(.invalid, "\n");

    // Attributes
    if (elem.attributes.items.len > 0) {
        try addIndentTokens(output, indent + 1);
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "attributes");
        try output.addToken(.equal, "=");
        try output.addToken(.ampersand, "&");
        try output.addToken(.period, ".");
        try output.addToken(.l_brace, "{");

        for (elem.attributes.items) |attr| {
            try output.addToken(.period, ".");
            try output.addToken(.l_brace, "{");
            try output.addToken(.period, ".");
            try output.addToken(.identifier, "name");
            try output.addToken(.equal, "=");

            const name_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{attr.name});
            defer allocator.free(name_buf);
            try output.addToken(.string_literal, name_buf);
            try output.addToken(.comma, ",");

            try output.addToken(.period, ".");
            try output.addToken(.identifier, "value");
            try output.addToken(.equal, "=");

            switch (attr.value) {
                .static => |val| {
                    // Static string value
                    const value_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{val});
                    defer allocator.free(value_buf);
                    try output.addToken(.string_literal, value_buf);
                },
                .dynamic => |expr| {
                    // Dynamic expression - output as-is
                    try output.addToken(.identifier, expr);
                },
                .format => |fmt| {
                    // Format expression: pass expression directly and set format field
                    // .value = expr (expression as-is)
                    try output.addToken(.identifier, fmt.expr);
                    try output.addToken(.comma, ",");
                    try output.addToken(.invalid, "\n");

                    // .format = "{format}"
                    try addIndentTokens(output, indent + 3);
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "format");
                    try output.addToken(.equal, "=");
                    const format_str = try std.fmt.allocPrint(allocator, "\"{{{s}}}\"", .{fmt.format});
                    defer allocator.free(format_str);
                    try output.addToken(.string_literal, format_str);
                },
            }
            try output.addToken(.r_brace, "}");
            try output.addToken(.comma, ",");
        }

        try output.addToken(.r_brace, "}");
        try output.addToken(.comma, ",");
        try output.addToken(.invalid, "\n");
    }

    // Children
    if (elem.children.items.len > 0) {
        try addIndentTokens(output, indent + 1);
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "children");
        try output.addToken(.equal, "=");
        try output.addToken(.ampersand, "&");
        try output.addToken(.period, ".");
        try output.addToken(.l_brace, "{");

        for (elem.children.items) |child| {
            switch (child) {
                .text => |text| {
                    try output.addToken(.period, ".");
                    try output.addToken(.l_brace, "{");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "text");
                    try output.addToken(.equal, "=");

                    const escaped_text = try escapeTextForStringLiteral(allocator, text);
                    defer allocator.free(escaped_text);
                    const text_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_text});
                    defer allocator.free(text_buf);
                    try output.addToken(.string_literal, text_buf);

                    try output.addToken(.r_brace, "}");
                    try output.addToken(.comma, ",");
                },
                .text_expr => |expr| {
                    try output.addToken(.period, ".");
                    try output.addToken(.l_brace, "{");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "text");
                    try output.addToken(.equal, "=");
                    try output.addToken(.identifier, expr);
                    try output.addToken(.r_brace, "}");
                    try output.addToken(.comma, ",");
                },
                .format_expr => |fmt| {
                    try output.addToken(.period, ".");
                    try output.addToken(.l_brace, "{");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "text");
                    try output.addToken(.equal, "=");

                    // Generate: std.fmt.allocPrint(allocator, "{format}", .{expr})
                    try output.addToken(.identifier, "std");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "fmt");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "allocPrint");
                    try output.addToken(.l_paren, "(");
                    try output.addToken(.identifier, "allocator");
                    try output.addToken(.comma, ",");

                    const format_str = try std.fmt.allocPrint(allocator, "\"{{{s}}}\"", .{fmt.format});
                    defer allocator.free(format_str);
                    try output.addToken(.string_literal, format_str);
                    try output.addToken(.comma, ",");

                    try output.addToken(.period, ".");
                    try output.addToken(.l_brace, "{");
                    try output.addToken(.identifier, fmt.expr);
                    try output.addToken(.r_brace, "}");
                    try output.addToken(.r_paren, ")");

                    try output.addToken(.r_brace, "}");
                    try output.addToken(.comma, ",");
                },
                .component_expr => |expr| {
                    // Component expression: {(expr)} - use directly without wrapping
                    try output.addToken(.identifier, expr);
                    try output.addToken(.comma, ",");
                },
                .element => |nested_elem| {
                    try output.addToken(.period, ".");
                    try output.addToken(.l_brace, "{");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "element");
                    try output.addToken(.equal, "=");
                    // Recursively render the nested element
                    try renderElementAsStruct(allocator, output, nested_elem, indent + 1);
                    try output.addToken(.r_brace, "}");
                    try output.addToken(.comma, ",");
                },
                .raw_svg_content => |raw_content| {
                    // For SVG tags: use _zx.fmt("{s}", .{raw_content}) to output unescaped content
                    try output.addToken(.period, ".");
                    try output.addToken(.l_brace, "{");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "text");
                    try output.addToken(.equal, "=");

                    // Generate: std.fmt.allocPrint(allocator, "{s}", .{raw_content})
                    try output.addToken(.identifier, "std");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "fmt");
                    try output.addToken(.period, ".");
                    try output.addToken(.identifier, "allocPrint");
                    try output.addToken(.l_paren, "(");
                    try output.addToken(.identifier, "allocator");
                    try output.addToken(.comma, ",");

                    // Format string: "{s}"
                    try output.addToken(.string_literal, "\"{s}\"");
                    try output.addToken(.comma, ",");

                    // Expression wrapped in tuple: .{raw_content}
                    try output.addToken(.period, ".");
                    try output.addToken(.l_brace, "{");

                    // Escape the string for use in a string literal
                    const escaped_content = try escapeTextForStringLiteral(allocator, raw_content);
                    defer allocator.free(escaped_content);
                    const content_buf = try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped_content});
                    defer allocator.free(content_buf);
                    try output.addToken(.string_literal, content_buf);

                    try output.addToken(.r_brace, "}");
                    try output.addToken(.r_paren, ")");

                    try output.addToken(.r_brace, "}");
                    try output.addToken(.comma, ",");
                },
            }
        }

        try output.addToken(.r_brace, "}");
        try output.addToken(.comma, ",");
        try output.addToken(.invalid, "\n");
    }

    try addIndentTokens(output, indent);
    try output.addToken(.r_brace, "}");
}

fn addIndentTokens(output: *TokenBuilder, indent: usize) !void {
    const spaces = indent * 4;
    if (spaces > 0) {
        var buf: [256]u8 = undefined;
        @memset(buf[0..spaces], ' ');
        try output.addToken(.invalid, buf[0..spaces]);
    }
}
