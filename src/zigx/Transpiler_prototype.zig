const std = @import("std");

const Ast = std.zig.Ast;
const Token = std.zig.Token;
const Tokenizer = std.zig.Tokenizer;

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
const ZigxElement = struct {
    tag: []const u8,
    attributes: std.ArrayList(Attribute),
    children: std.ArrayList(Child),
    allocator: std.mem.Allocator,

    const Attribute = struct {
        name: []const u8,
        value: AttributeValue,
    };

    const AttributeValue = union(enum) {
        static: []const u8, // "string value"
        dynamic: []const u8, // .{expression}
    };

    const Child = union(enum) {
        text: []const u8,
        text_expr: []const u8,
        component_expr: []const u8, // For {(expression)} - already a Component
        format_expr: struct { expr: []const u8, format: []const u8 }, // For {[expr:fmt]}
        element: *ZigxElement,
    };

    fn init(allocator: std.mem.Allocator, tag: []const u8) !*ZigxElement {
        const elem = try allocator.create(ZigxElement);
        elem.* = .{
            .tag = tag,
            .attributes = std.ArrayList(Attribute){},
            .children = std.ArrayList(Child){},
            .allocator = allocator,
        };
        return elem;
    }

    fn deinit(self: *ZigxElement) void {
        for (self.children.items) |child| {
            if (child == .element) {
                child.element.deinit();
                self.allocator.destroy(child.element);
            }
        }
        self.children.deinit(self.allocator);
        self.attributes.deinit(self.allocator);
    }
};

/// Transpile a .zigx file to .zig by transforming JSX syntax
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
                        try output.addToken(.keyword_const, "const");
                        try output.addToken(.identifier, "_zx");
                        try output.addToken(.equal, "=");
                        try output.addToken(.identifier, "zx");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "init");
                        try output.addToken(.l_paren, "(");
                        try output.addToken(.identifier, "allocator");
                        try output.addToken(.r_paren, ")");
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

/// Parse JSX syntax into a JsxElement
fn parseJsx(allocator: std.mem.Allocator, content: []const u8) error{ InvalidJsx, OutOfMemory }!*ZigxElement {
    var i: usize = 0;

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

    const elem = try ZigxElement.init(allocator, tag_name);
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

        // Skip whitespace and =
        while (i < content.len and (std.ascii.isWhitespace(content[i]) or content[i] == '=')) i += 1;

        // Parse attribute value - either quoted string or dynamic expression
        if (i < content.len and content[i] == '"') {
            // Static string value: "value"
            i += 1; // skip opening quote
            const val_start = i;
            while (i < content.len and content[i] != '"') i += 1;
            const attr_value = content[val_start..i];
            i += 1; // skip closing quote

            try elem.attributes.append(allocator, .{ .name = attr_name, .value = .{ .static = attr_value } });
        } else if (i + 1 < content.len and content[i] == '{') {
            // Dynamic expression: .{expression}
            i += 1; // skip {
            const expr_start = i;
            var brace_depth: i32 = 1;
            while (i < content.len and brace_depth > 0) {
                if (content[i] == '{') brace_depth += 1;
                if (content[i] == '}') brace_depth -= 1;
                if (brace_depth > 0) i += 1;
            }
            const expr = content[expr_start..i];
            i += 1; // skip closing }

            try elem.attributes.append(allocator, .{ .name = attr_name, .value = .{ .dynamic = expr } });
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
    try parseJsxChildren(allocator, elem, inner_content);

    return elem;
}

/// Parse JSX children (text, expressions, nested elements)
fn parseJsxChildren(allocator: std.mem.Allocator, parent: *ZigxElement, content: []const u8) error{ InvalidJsx, OutOfMemory }!void {
    var i: usize = 0;

    while (i < content.len) {
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
fn renderJsxAsTokens(allocator: std.mem.Allocator, output: *TokenBuilder, elem: *ZigxElement, indent: usize) !void {
    // Check if this is a custom component
    if (isCustomComponent(elem.tag)) {
        // For custom components, wrap in lazy: _zx.lazy(Component, props)
        try output.addToken(.identifier, "_zx");
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "lazy");
        try output.addToken(.l_paren, "(");
        try output.addToken(.identifier, elem.tag);
        try output.addToken(.comma, ",");

        // Generate props type name (ComponentName + "Props")
        const props_type_name = try std.fmt.allocPrint(allocator, "{s}Props", .{elem.tag});
        defer allocator.free(props_type_name);

        // Build props struct from attributes with explicit type
        if (elem.attributes.items.len > 0) {
            try output.addToken(.identifier, props_type_name);
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
                }
                if (i < elem.attributes.items.len - 1) {
                    try output.addToken(.comma, ",");
                }
            }
            try output.addToken(.r_brace, "}");
        } else {
            // Empty props struct with explicit type
            try output.addToken(.identifier, props_type_name);
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
                    try output.addToken(.period, ".");
                    try output.addToken(.l_brace, "{");
                    try output.addToken(.identifier, fmt.expr);
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

                        // Generate props type name (ComponentName + "Props")
                        const props_type_name = try std.fmt.allocPrint(allocator, "{s}Props", .{child_elem.tag});
                        defer allocator.free(props_type_name);

                        // Build props struct from attributes with explicit type
                        if (child_elem.attributes.items.len > 0) {
                            try output.addToken(.identifier, props_type_name);
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
                                }
                                if (i < child_elem.attributes.items.len - 1) {
                                    try output.addToken(.comma, ",");
                                }
                            }
                            try output.addToken(.r_brace, "}");
                        } else {
                            // Empty props struct with explicit type
                            try output.addToken(.identifier, props_type_name);
                            try output.addToken(.l_brace, "{");
                            try output.addToken(.r_brace, "}");
                        }

                        try output.addToken(.r_paren, ")");
                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, "\n");
                    } else {
                        // Use _zx.zx(.tag, .{ ... }) for nested elements
                        try output.addToken(.identifier, "_zx");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, "zx");
                        try output.addToken(.l_paren, "(");
                        try output.addToken(.period, ".");
                        try output.addToken(.identifier, child_elem.tag);
                        try output.addToken(.comma, ",");

                        // Options struct
                        try output.addToken(.period, ".");
                        try output.addToken(.l_brace, "{");
                        try output.addToken(.invalid, "\n");

                        // Attributes for nested element
                        if (child_elem.attributes.items.len > 0) {
                            try addIndentTokens(output, indent + 4);
                            try output.addToken(.period, ".");
                            try output.addToken(.identifier, "attributes");
                            try output.addToken(.equal, "=");
                            try output.addToken(.ampersand, "&");
                            try output.addToken(.period, ".");
                            try output.addToken(.l_brace, "{");
                            try output.addToken(.invalid, "\n");

                            for (child_elem.attributes.items) |attr| {
                                try addIndentTokens(output, indent + 5);
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
                                }

                                try output.addToken(.r_brace, "}");
                                try output.addToken(.comma, ",");
                                try output.addToken(.invalid, "\n");
                            }

                            try addIndentTokens(output, indent + 4);
                            try output.addToken(.r_brace, "}");
                            try output.addToken(.comma, ",");
                            try output.addToken(.invalid, "\n");
                        }

                        // Children for nested element
                        if (child_elem.children.items.len > 0) {
                            try addIndentTokens(output, indent + 4);
                            try output.addToken(.period, ".");
                            try output.addToken(.identifier, "children");
                            try output.addToken(.equal, "=");
                            try output.addToken(.ampersand, "&");
                            try output.addToken(.period, ".");
                            try output.addToken(.l_brace, "{");
                            try output.addToken(.invalid, "\n");

                            for (child_elem.children.items) |nested_child| {
                                try addIndentTokens(output, indent + 5);
                                switch (nested_child) {
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
                                        try output.addToken(.invalid, "\n");
                                    },
                                    .text_expr => |expr| {
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
                                        try output.addToken(.invalid, "\n");
                                    },
                                    .component_expr => |expr| {
                                        // Component expression: {(expr)} - use directly without wrapping
                                        try output.addToken(.identifier, expr);
                                        try output.addToken(.comma, ",");
                                        try output.addToken(.invalid, "\n");
                                    },
                                    .element => |nested_elem| {
                                        // For deeply nested elements, recursively render using renderNestedElement
                                        try renderNestedElementAsCall(allocator, output, nested_elem, indent + 5);
                                        try output.addToken(.comma, ",");
                                        try output.addToken(.invalid, "\n");
                                    },
                                }
                            }

                            try addIndentTokens(output, indent + 4);
                            try output.addToken(.r_brace, "}");
                            try output.addToken(.comma, ",");
                            try output.addToken(.invalid, "\n");
                        }

                        try addIndentTokens(output, indent + 3);
                        try output.addToken(.r_brace, "}");
                        try output.addToken(.r_paren, ")");
                        try output.addToken(.comma, ",");
                        try output.addToken(.invalid, "\n");
                    }
                },
            }
        }

        try addIndentTokens(output, indent + 2);
        try output.addToken(.r_brace, "}");
        try output.addToken(.comma, ",");
        try output.addToken(.invalid, "\n");
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
fn renderNestedElementAsCall(allocator: std.mem.Allocator, output: *TokenBuilder, elem: *ZigxElement, indent: usize) !void {
    // Check if this is a custom component
    if (isCustomComponent(elem.tag)) {
        // For custom components, wrap in lazy: _zx.lazy(Component, props)
        try output.addToken(.identifier, "_zx");
        try output.addToken(.period, ".");
        try output.addToken(.identifier, "lazy");
        try output.addToken(.l_paren, "(");
        try output.addToken(.identifier, elem.tag);
        try output.addToken(.comma, ",");

        // Generate props type name (ComponentName + "Props")
        const props_type_name = try std.fmt.allocPrint(allocator, "{s}Props", .{elem.tag});
        defer allocator.free(props_type_name);

        // Build props struct from attributes with explicit type
        if (elem.attributes.items.len > 0) {
            try output.addToken(.identifier, props_type_name);
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
                }
                if (i < elem.attributes.items.len - 1) {
                    try output.addToken(.comma, ",");
                }
            }
            try output.addToken(.r_brace, "}");
        } else {
            // Empty props struct with explicit type
            try output.addToken(.identifier, props_type_name);
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
                .element => |nested_elem| {
                    // Recursively render nested elements
                    try renderNestedElementAsCall(allocator, output, nested_elem, indent);
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
fn renderElementAsStruct(allocator: std.mem.Allocator, output: *TokenBuilder, elem: *ZigxElement, indent: usize) !void {
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
