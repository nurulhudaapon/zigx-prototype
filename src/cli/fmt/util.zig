const std = @import("std");
// const htmlz = @import("htmlz");
const expr = @import("expr.zig");
const fmtlog = std.log.scoped(.cli);
const htmlz_ast = @import("html/Ast.zig");

const stderr_buffer_size = 4096;
var stderr_buffer: [stderr_buffer_size]u8 = undefined;

pub const ExtractHtmlResult = struct {
    htmls: []const []const u8,
    zig_source: [:0]const u8,

    pub fn deinit(self: *ExtractHtmlResult, allocator: std.mem.Allocator) void {
        for (self.htmls) |h| {
            allocator.free(h);
        }
        allocator.free(self.htmls); // Free the array itself
        allocator.free(self.zig_source);
    }
};

pub fn formatHtml(
    arena: std.mem.Allocator,
    stderr: *std.Io.Writer,
    path: ?[]const u8,
    src: [:0]const u8,
    syntax_only: bool,
) !?[]const u8 {
    const html_ast = try htmlz_ast.init(arena, src, .html, syntax_only);
    try html_ast.printErrors(src, path, stderr);
    if (html_ast.has_syntax_errors) {
        return null;
    }

    var w: std.io.Writer.Allocating = .init(arena);
    try html_ast.render(src, &w.writer);
    const fmtted_html = w.written();

    fmtlog.debug("fmtted_html: \n```\n{s}\n```", .{fmtted_html});
    // Parse expressions from the formatted HTML
    const expressions = try expr.parse(arena, fmtted_html);

    // Render with expressions formatted
    const formatted = try expr.render(arena, fmtted_html, expressions);
    return formatted;
}

fn findLeadingWhitespaceStart(source: []const u8, jsx_start: usize) usize {
    var html_start = jsx_start;
    var lookback = jsx_start;

    while (lookback > 0) {
        const prev_char = source[lookback - 1];
        if (std.ascii.isWhitespace(prev_char)) {
            lookback -= 1;
            html_start = lookback;
        } else if (prev_char == '(') {
            break;
        } else {
            break;
        }
    }

    return html_start;
}

fn findTrailingWhitespaceEnd(source: []const u8, html_end: usize) usize {
    var html_end_extended = html_end;

    while (html_end_extended < source.len and std.ascii.isWhitespace(source[html_end_extended])) {
        html_end_extended += 1;
    }

    // Only include trailing whitespace if next char is ')' or ';'
    if (html_end_extended < source.len and (source[html_end_extended] == ')' or source[html_end_extended] == ';')) {
        return html_end_extended;
    }

    return html_end;
}

fn isJsxTagStart(source: []const u8, pos: usize) bool {
    if (pos >= source.len or source[pos] != '<') return false;

    var j = pos + 1;
    while (j < source.len and std.ascii.isWhitespace(source[j])) {
        j += 1;
    }

    if (j >= source.len) return false;

    const next_char = source[j];
    return std.ascii.isAlphabetic(next_char) or next_char == '/' or next_char == '!';
}

fn extractAndFormatJsxSegment(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    stderr: *std.Io.Writer,
    source: []const u8,
    jsx_start: usize,
    html_segments: *std.ArrayList([]const u8),
    cleaned_source: *std.ArrayList(u8),
) !usize {
    const html_start = findLeadingWhitespaceStart(source, jsx_start);
    const html_end = try parseJsxElement(source, jsx_start);
    const html_end_extended = findTrailingWhitespaceEnd(source, html_end);

    const html_segment = source[html_start..html_end_extended];
    const html_segment_z = try allocator.dupeZ(u8, html_segment);
    defer allocator.free(html_segment_z);

    const formatted_html = formatHtml(arena, stderr, null, html_segment_z, true) catch {
        // If HTML formatting fails, use the original JSX segment
        const html_copy = try allocator.dupe(u8, html_segment);
        try html_segments.append(allocator, html_copy);
        // Remove leading whitespace that was added to cleaned_source
        if (html_start < jsx_start) {
            const chars_to_remove = jsx_start - html_start;
            if (cleaned_source.items.len >= chars_to_remove) {
                cleaned_source.items.len -= chars_to_remove;
            }
        }
        const placeholder = try std.fmt.allocPrint(allocator, "@html({d})", .{html_segments.items.len - 1});
        defer allocator.free(placeholder);
        try cleaned_source.appendSlice(allocator, placeholder);
        return html_end_extended;
    };

    // If formatted_html is null (syntax errors), use original JSX
    const html_copy = try allocator.dupe(u8, formatted_html orelse html_segment);
    try html_segments.append(allocator, html_copy);

    // Remove leading whitespace that was added to cleaned_source
    if (html_start < jsx_start) {
        const chars_to_remove = jsx_start - html_start;
        if (cleaned_source.items.len >= chars_to_remove) {
            cleaned_source.items.len -= chars_to_remove;
        }
    }

    const placeholder = try std.fmt.allocPrint(allocator, "@html({d})", .{html_segments.items.len - 1});
    defer allocator.free(placeholder);
    try cleaned_source.appendSlice(allocator, placeholder);

    return html_end_extended;
}

pub fn extractHtml(allocator: std.mem.Allocator, zx_source: [:0]const u8) !ExtractHtmlResult {
    var html_segments = std.ArrayList([]const u8){};
    defer html_segments.deinit(allocator);

    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var cleaned_source = std.ArrayList(u8){};
    defer cleaned_source.deinit(allocator);

    var i: usize = 0;
    while (i < zx_source.len) {
        if (isJsxTagStart(zx_source, i)) {
            i = try extractAndFormatJsxSegment(
                allocator,
                arena,
                stderr,
                zx_source,
                i,
                &html_segments,
                &cleaned_source,
            );
            continue;
        }

        try cleaned_source.append(allocator, zx_source[i]);
        i += 1;
    }

    try cleaned_source.append(allocator, 0);
    const cleaned = try allocator.dupeZ(u8, cleaned_source.items[0 .. cleaned_source.items.len - 1]);

    return ExtractHtmlResult{
        .htmls = try html_segments.toOwnedSlice(allocator),
        .zig_source = cleaned,
    };
}

fn parseJsxComment(source: []const u8, start: usize) !usize {
    var i = start;
    if (i + 2 >= source.len or !std.mem.eql(u8, source[i .. i + 3], "!--")) {
        return error.InvalidJsx;
    }
    i += 3;

    while (i + 2 < source.len) {
        if (source[i] == '-' and source[i + 1] == '-' and source[i + 2] == '>') {
            return i + 3;
        }
        i += 1;
    }
    return error.InvalidJsx;
}

fn skipBraceExpression(source: []const u8, start: usize) usize {
    var i = start;
    if (i >= source.len or source[i] != '{') return start;

    i += 1;
    var depth: i32 = 1;
    while (i < source.len and depth > 0) {
        if (source[i] == '{') depth += 1;
        if (source[i] == '}') depth -= 1;
        if (depth > 0) i += 1;
    }
    if (i < source.len) i += 1; // skip '}'
    return i;
}

fn skipStringLiteral(source: []const u8, start: usize) usize {
    var i = start;
    if (i >= source.len or source[i] != '"') return start;

    i += 1;
    while (i < source.len and source[i] != '"') {
        if (source[i] == '\\' and i + 1 < source.len) {
            i += 2; // skip escape sequence
        } else {
            i += 1;
        }
    }
    if (i < source.len) i += 1; // skip closing quote
    return i;
}

fn parseAttributeValue(source: []const u8, start: usize) usize {
    if (start >= source.len) return start;

    if (source[start] == '"') {
        return skipStringLiteral(source, start);
    } else if (source[start] == '{') {
        return skipBraceExpression(source, start);
    }
    return start;
}

fn parseAttributes(source: []const u8, start: usize) usize {
    var i = start;

    while (i < source.len) {
        // Skip whitespace
        while (i < source.len and std.ascii.isWhitespace(source[i])) {
            i += 1;
        }
        if (i >= source.len) break;

        // Check for self-closing tag: <tag />
        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '>') {
            return i + 2;
        }

        // Check for closing bracket: <tag>
        if (source[i] == '>') {
            return i + 1;
        }

        // Parse attribute name
        while (i < source.len and source[i] != '=' and !std.ascii.isWhitespace(source[i]) and source[i] != '>' and source[i] != '/') {
            i += 1;
        }

        // Skip whitespace and =
        while (i < source.len and (std.ascii.isWhitespace(source[i]) or source[i] == '=')) {
            i += 1;
        }

        // Parse attribute value
        i = parseAttributeValue(source, i);
    }

    return i;
}

fn isSelfClosingTag(source: []const u8, tag_start: usize) bool {
    var i = tag_start;
    while (i < source.len and source[i] != '>') {
        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '>') {
            return true;
        }
        if (source[i] == '"') {
            i = skipStringLiteral(source, i);
        } else if (source[i] == '{') {
            i = skipBraceExpression(source, i);
        } else {
            i += 1;
        }
    }
    return false;
}

fn parseJsxContent(source: []const u8, start: usize, tag_name: []const u8) error{InvalidJsx}!usize {
    var i = start;
    var depth: i32 = 1;

    while (i < source.len and depth > 0) {
        if (source[i] == '<' and i + 1 < source.len) {
            const next = source[i + 1];
            if (std.ascii.isAlphabetic(next) or next == '/' or next == '!') {
                if (next == '/') {
                    depth -= 1;
                    if (depth == 0) {
                        const closing_start = i;
                        i = try parseJsxElement(source, i);
                        const closing_tag = findTagName(source, closing_start);
                        if (!std.mem.eql(u8, closing_tag, tag_name)) {
                            // Tag mismatch, but continue anyway
                        }
                        break;
                    } else {
                        // Nested closing tag - skip over it
                        i += 1; // skip '<'
                        i += 1; // skip '/'
                        while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_' or source[i] == '-')) {
                            i += 1;
                        }
                        while (i < source.len and source[i] != '>') {
                            i += 1;
                        }
                        if (i < source.len) i += 1; // skip '>'
                        continue;
                    }
                } else {
                    // Opening tag
                    const opening_tag_name = findTagName(source, i);
                    const is_void = isVoidElement(opening_tag_name);
                    const is_self_closing = isSelfClosingTag(source, i);

                    if (!is_void and !is_self_closing) {
                        depth += 1;
                    }

                    // Skip to end of tag
                    var temp_i = i;
                    while (temp_i < source.len and source[temp_i] != '>') {
                        if (source[temp_i] == '"') {
                            temp_i = skipStringLiteral(source, temp_i);
                        } else if (source[temp_i] == '{') {
                            temp_i = skipBraceExpression(source, temp_i);
                        } else {
                            temp_i += 1;
                        }
                    }
                    if (temp_i < source.len) {
                        i = temp_i + 1;
                        continue;
                    }
                }
            }
        }

        if (source[i] == '{') {
            i = skipBraceExpression(source, i);
            continue;
        }

        i += 1;
    }

    return i;
}

/// Parse a JSX element and return the end position
/// Handles nested tags, attributes, expressions, etc.
pub fn parseJsxElement(source: []const u8, start: usize) !usize {
    var i = start;
    if (i >= source.len or source[i] != '<') return error.InvalidJsx;
    i += 1; // skip '<'

    // Handle comment: <!-- ... -->
    if (i + 2 < source.len and std.mem.eql(u8, source[i .. i + 3], "!--")) {
        return parseJsxComment(source, i);
    }

    // Check if it's a closing tag: </tag>
    const is_closing = i < source.len and source[i] == '/';
    if (is_closing) i += 1;

    // Parse tag name
    const tag_start = i;
    while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_' or source[i] == '-')) {
        i += 1;
    }
    const tag_name = source[tag_start..i];

    if (is_closing) {
        // For closing tag, just find the matching >
        while (i < source.len and source[i] != '>') {
            i += 1;
        }
        if (i < source.len) i += 1; // skip '>'
        return i;
    }

    // Parse attributes
    i = parseAttributes(source, i);

    // If we found '>', we need to parse the content and closing tag
    if (i > 0 and source[i - 1] == '>') {
        i = try parseJsxContent(source, i, tag_name);
    }

    return i;
}

/// Check if an element is a void element (no closing tag needed)
pub fn isVoidElement(tag_name: []const u8) bool {
    const void_elements = [_][]const u8{
        "area", "base", "br",    "col",    "embed", "hr",  "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    };
    for (void_elements) |void_tag| {
        if (std.mem.eql(u8, tag_name, void_tag)) {
            return true;
        }
    }
    return false;
}

/// Find tag name from a JSX tag start position
pub fn findTagName(source: []const u8, start: usize) []const u8 {
    var i = start;
    if (i >= source.len or source[i] != '<') return "";
    i += 1;

    // Skip / if closing tag
    if (i < source.len and source[i] == '/') i += 1;

    const tag_start = i;
    while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_' or source[i] == '-')) {
        i += 1;
    }
    return source[tag_start..i];
}

fn parseHtmlPlaceholder(source: []const u8, start: usize) struct { index: usize, end: usize } {
    var i = start;
    if (i + 5 >= source.len or !std.mem.eql(u8, source[i .. i + 5], "@html")) {
        return .{ .index = 0, .end = start };
    }

    i += 5; // skip "@html"

    // Skip whitespace
    while (i < source.len and std.ascii.isWhitespace(source[i])) {
        i += 1;
    }

    // Expect opening parenthesis
    if (i >= source.len or source[i] != '(') {
        return .{ .index = 0, .end = start };
    }

    i += 1; // skip '('

    // Parse number
    const num_start = i;
    while (i < source.len and std.ascii.isDigit(source[i])) {
        i += 1;
    }

    if (i == num_start) {
        return .{ .index = 0, .end = start };
    }

    const num_str = source[num_start..i];
    const html_index = std.fmt.parseInt(usize, num_str, 10) catch {
        return .{ .index = 0, .end = start };
    };

    // Skip whitespace
    while (i < source.len and std.ascii.isWhitespace(source[i])) {
        i += 1;
    }

    // Expect closing parenthesis
    if (i >= source.len or source[i] != ')') {
        return .{ .index = 0, .end = start };
    }

    i += 1; // skip ')'

    return .{ .index = html_index, .end = i };
}

fn trimLeadingTrailingNewlines(allocator: std.mem.Allocator, h: []const u8) ![]const u8 {
    if (h.len == 0) return try allocator.dupe(u8, h);

    var start: usize = 0;
    var end: usize = h.len;

    // Trim leading newlines/whitespace
    while (start < end and (h[start] == '\n' or h[start] == '\r' or std.ascii.isWhitespace(h[start]))) {
        start += 1;
    }

    // Trim trailing newlines/whitespace
    while (end > start and (h[end - 1] == '\n' or h[end - 1] == '\r' or std.ascii.isWhitespace(h[end - 1]))) {
        end -= 1;
    }

    return try allocator.dupe(u8, h[start..end]);
}

fn containsNewline(text: []const u8) bool {
    for (text) |c| {
        if (c == '\n' or c == '\r') return true;
    }
    return false;
}

fn getIndentationLevel(source: []const u8, pos: usize) usize {
    // Find the start of the line containing pos
    var line_start = pos;
    while (line_start > 0 and source[line_start - 1] != '\n') {
        line_start -= 1;
    }

    // Count leading spaces/tabs
    var indent: usize = 0;
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
    return indent;
}

fn indentMultilineText(allocator: std.mem.Allocator, text: []const u8, indent_level: usize) ![]const u8 {
    if (text.len == 0) return try allocator.dupe(u8, text);

    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    // Create indent string (spaces)
    const indent_spaces = try allocator.alloc(u8, indent_level);
    defer allocator.free(indent_spaces);
    @memset(indent_spaces, ' ');

    var i: usize = 0;
    var line_start = true;

    while (i < text.len) {
        if (line_start and i < text.len and text[i] != '\n' and text[i] != '\r') {
            try result.appendSlice(allocator, indent_spaces);
            line_start = false;
        }

        if (text[i] == '\n') {
            try result.append(allocator, text[i]);
            line_start = true;
        } else {
            try result.append(allocator, text[i]);
        }
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

fn findOpeningParenBefore(source: []const u8, pos: usize) ?usize {
    var i = pos;
    while (i > 0) {
        i -= 1;
        if (source[i] == '(') {
            return i;
        }
        if (!std.ascii.isWhitespace(source[i])) {
            return null;
        }
    }
    return null;
}

fn findClosingParenAfter(source: []const u8, pos: usize) ?usize {
    var i = pos;
    // Skip whitespace (including newlines)
    while (i < source.len and std.ascii.isWhitespace(source[i])) {
        i += 1;
    }
    // If we find a closing paren right after whitespace, return it
    if (i < source.len and source[i] == ')') {
        return i;
    }
    // Otherwise, look for the next closing paren (might be on a different line)
    var depth: i32 = 0;
    while (i < source.len) {
        if (source[i] == '(') {
            depth += 1;
        } else if (source[i] == ')') {
            if (depth == 0) {
                return i;
            }
            depth -= 1;
        }
        i += 1;
    }
    return null;
}

/// Replace @html(n) placeholders with the corresponding HTML segments
pub fn patchInHtml(allocator: std.mem.Allocator, extract_html: ExtractHtmlResult) ![:0]const u8 {
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    var last_copied: usize = 0;
    var i: usize = 0;
    while (i < extract_html.zig_source.len) {
        if (extract_html.zig_source[i] == '@') {
            const parsed = parseHtmlPlaceholder(extract_html.zig_source, i);
            if (parsed.end > i and parsed.index < extract_html.htmls.len) {
                const html = extract_html.htmls[parsed.index];

                // Trim leading and trailing newlines/whitespace
                const trimmed_html = try trimLeadingTrailingNewlines(allocator, html);
                defer allocator.free(trimmed_html);

                const is_multiline = containsNewline(trimmed_html);

                // Find opening parenthesis before @html(n)
                const open_paren_pos = findOpeningParenBefore(extract_html.zig_source, i);

                // Find closing parenthesis after @html(n)
                const close_paren_pos = findClosingParenAfter(extract_html.zig_source, parsed.end);

                if (is_multiline) {
                    if (open_paren_pos) |open_pos| {
                        // Get indentation level of opening parenthesis
                        const open_paren_indent = getIndentationLevel(extract_html.zig_source, open_pos);
                        // HTML block should be indented one level more (assuming 4 spaces per level)
                        const html_indent = open_paren_indent + 4;
                        // Closing paren should match opening paren indentation
                        const close_paren_indent = open_paren_indent;

                        // Copy everything from last_copied up to (but not including) the opening paren
                        try result.appendSlice(allocator, extract_html.zig_source[last_copied..open_pos]);

                        // Copy the opening paren
                        try result.append(allocator, '(');

                        // Add newline after opening paren
                        try result.append(allocator, '\n');

                        // Indent and add the trimmed HTML
                        const indented_html = try indentMultilineText(allocator, trimmed_html, html_indent);
                        defer allocator.free(indented_html);
                        try result.appendSlice(allocator, indented_html);

                        // Skip the @html(n) placeholder in source
                        last_copied = parsed.end;
                        i = parsed.end;

                        // Look for closing paren after the placeholder
                        if (close_paren_pos) |close_pos| {
                            // Skip any whitespace between placeholder and closing paren
                            var j = parsed.end;
                            while (j < close_pos and std.ascii.isWhitespace(extract_html.zig_source[j])) {
                                j += 1;
                            }

                            // Add newline before closing paren (for multiline HTML)
                            try result.append(allocator, '\n');

                            // Add indentation for closing paren
                            var indent_idx: usize = 0;
                            while (indent_idx < close_paren_indent) {
                                try result.append(allocator, ' ');
                                indent_idx += 1;
                            }

                            // Copy the closing paren
                            try result.append(allocator, ')');

                            last_copied = close_pos + 1;
                            i = close_pos + 1;
                        } else {
                            // No closing paren found immediately, but for multiline HTML
                            // we should still look ahead for a closing paren
                            var j = parsed.end;
                            while (j < extract_html.zig_source.len and std.ascii.isWhitespace(extract_html.zig_source[j])) {
                                j += 1;
                            }
                            if (j < extract_html.zig_source.len and extract_html.zig_source[j] == ')') {
                                // Found closing paren after whitespace, add newline and indentation before it
                                try result.append(allocator, '\n');

                                // Add indentation for closing paren
                                var indent_idx: usize = 0;
                                while (indent_idx < close_paren_indent) {
                                    try result.append(allocator, ' ');
                                    indent_idx += 1;
                                }

                                try result.append(allocator, ')');
                                last_copied = j + 1;
                                i = j + 1;
                            } else {
                                // No closing paren found, continue normally
                                i = parsed.end;
                            }
                        }
                        continue;
                    } else {
                        // Multiline but no opening paren, just insert trimmed HTML
                        try result.appendSlice(allocator, extract_html.zig_source[last_copied..i]);
                        try result.appendSlice(allocator, trimmed_html);
                        last_copied = parsed.end;
                        i = parsed.end;
                        continue;
                    }
                } else {
                    // Single line or no parens found, copy everything up to @html(n) and insert trimmed HTML
                    try result.appendSlice(allocator, extract_html.zig_source[last_copied..i]);
                    try result.appendSlice(allocator, trimmed_html);
                    last_copied = parsed.end;
                    i = parsed.end;
                    continue;
                }
            }
        }

        i += 1;
    }

    // Copy remaining source
    try result.appendSlice(allocator, extract_html.zig_source[last_copied..]);

    try result.append(allocator, 0);
    const result_slice = result.items[0 .. result.items.len - 1 :0];
    return try allocator.dupeZ(u8, result_slice);
}

pub const FormatResult = struct {
    formatted_zx: [:0]const u8,
    zx_source: [:0]const u8,

    pub fn deinit(self: *FormatResult, allocator: std.mem.Allocator) void {
        allocator.free(self.formatted_zx);
        allocator.free(self.zx_source);
    }
};

pub fn format(allocator: std.mem.Allocator, zx_source: [:0]const u8) !FormatResult {
    var extract_html = try extractHtml(allocator, zx_source);
    defer extract_html.deinit(allocator);

    var ast = try std.zig.Ast.parse(allocator, extract_html.zig_source, .zig);
    defer ast.deinit(allocator);

    if (ast.errors.len > 0) {
        for (ast.errors) |err| {
            var w: std.io.Writer.Allocating = .init(allocator);
            defer w.deinit();
            try ast.renderError(err, &w.writer);
            std.debug.print("{s}\n", .{w.written()});
        }
        return error.ParseError;
    }

    const rendered_zig_source = try ast.renderAlloc(allocator);
    defer allocator.free(rendered_zig_source);
    // Free old zig_source before reassigning
    allocator.free(extract_html.zig_source);
    extract_html.zig_source = try allocator.dupeZ(u8, rendered_zig_source);
    const patched_in_html = try patchInHtml(allocator, extract_html);
    // Note: patched_in_html is owned by FormatResult, don't free it here

    const zx_source_copy = try allocator.dupeZ(u8, zx_source);

    return FormatResult{
        .formatted_zx = patched_in_html,
        .zx_source = zx_source_copy,
    };
}
