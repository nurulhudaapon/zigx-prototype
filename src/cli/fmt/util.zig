const std = @import("std");
const htmlz = @import("htmlz");

const stderr_buffer_size = 4096;
var stderr_buffer: [stderr_buffer_size]u8 = undefined;

pub const ExtractHtmlResult = struct {
    htmls: []const []const u8,
    zig_source: [:0]const u8,

    pub fn deinit(self: *ExtractHtmlResult, allocator: std.mem.Allocator) void {
        for (self.htmls) |html| {
            allocator.free(html);
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
    const html_ast = try htmlz.html.Ast.init(arena, src, .html, syntax_only);
    try html_ast.printErrors(src, path, stderr);
    if (html_ast.has_syntax_errors) {
        return null;
    }

    return try std.fmt.allocPrint(arena, "{f}", .{
        html_ast.formatter(src),
    });
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

    const formatted_html = try formatHtml(arena, stderr, null, html_segment_z, true);
    const html_copy = try allocator.dupe(u8, formatted_html orelse "");
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

/// Replace @html(n) placeholders with the corresponding HTML segments
pub fn patchInHtml(allocator: std.mem.Allocator, extract_html: ExtractHtmlResult) ![:0]const u8 {
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < extract_html.zig_source.len) {
        if (extract_html.zig_source[i] == '@') {
            const parsed = parseHtmlPlaceholder(extract_html.zig_source, i);
            if (parsed.end > i and parsed.index < extract_html.htmls.len) {
                try result.appendSlice(allocator, extract_html.htmls[parsed.index]);
                i = parsed.end;
                continue;
            }
        }

        try result.append(allocator, extract_html.zig_source[i]);
        i += 1;
    }

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
