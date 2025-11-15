const outdir_flag = zli.Flag{
    .name = "outdir",
    .shortcut = "o",
    .description = "Output directory",
    .type = .String,
    .default_value = .{ .String = ".zx" },
};

pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "fmt",
        .description = "Format a .zx file or directory.",
    }, fmt);

    try cmd.addFlag(outdir_flag);
    try cmd.addPositionalArg(.{
        .name = "path",
        .description = "Path to .zx file or directory",
        .required = true,
    });
    return cmd;
}

fn fmt(ctx: zli.CommandContext) !void {
    const outdir = ctx.flag("outdir", []const u8); // type-safe flag access

    const path = ctx.getArg("path") orelse {
        try ctx.writer.print("Missing path arg\n", .{});
        return;
    };

    // Check if path is a file and outdir is default
    const default_outdir = ".zx";
    const is_default_outdir = std.mem.eql(u8, outdir, default_outdir);

    // Check if path is a file (not a directory)
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.IsDir => {
            // It's a directory, proceed with normal fmtCommand
            try fmtCommand(ctx.allocator, path, outdir, false);
            return;
        },
        else => {
            std.debug.print("Error: Could not access path '{s}': {}\n", .{ path, err });
            return err;
        },
    };

    // Path is a file
    if (stat.kind == .file) {
        const is_zx = std.mem.endsWith(u8, path, ".zx");

        if (is_zx) {
            // If outdir is default and path is a file, output to stdout
            if (is_default_outdir) {
                // Read the source file
                const source = try std.fs.cwd().readFileAlloc(
                    ctx.allocator,
                    path,
                    std.math.maxInt(usize),
                );
                defer ctx.allocator.free(source);

                const source_z = try ctx.allocator.dupeZ(u8, source);
                defer ctx.allocator.free(source_z);

                // Parse and fmt
                var format_result = try format(ctx.allocator, source_z);
                defer format_result.deinit(ctx.allocator);

                // Output to stdout
                try ctx.writer.writeAll(format_result.formatted_zx);
                return;
            }
        }
    }

    // Otherwise, proceed with normal fmtCommand
    try fmtCommand(ctx.allocator, path, outdir, false);
}

fn getBasename(path: []const u8) []const u8 {
    // Get the last component of the path (the final directory or filename)
    const sep = std.fs.path.sep;
    if (std.mem.lastIndexOfScalar(u8, path, sep)) |last_sep| {
        if (last_sep + 1 < path.len) {
            return path[last_sep + 1 ..];
        }
    }
    // If no separator found, return the original path
    return path;
}

/// Check if output_dir is a subdirectory of dir_path and return the relative path if so
/// Returns null if output_dir is not a subdirectory of dir_path
fn getOutputDirRelativePath(allocator: std.mem.Allocator, dir_path: []const u8, output_dir: []const u8) !?[]const u8 {
    const sep = std.fs.path.sep_str;

    // Normalize paths by removing trailing separators
    var normalized_dir = dir_path;
    if (std.mem.endsWith(u8, dir_path, sep)) {
        normalized_dir = dir_path[0 .. dir_path.len - sep.len];
    }

    var normalized_output = output_dir;
    if (std.mem.endsWith(u8, output_dir, sep)) {
        normalized_output = output_dir[0 .. output_dir.len - sep.len];
    }

    // Check if output_dir starts with dir_path
    if (!std.mem.startsWith(u8, normalized_output, normalized_dir)) {
        return null;
    }

    // If they're equal, output_dir is not a subdirectory
    if (std.mem.eql(u8, normalized_dir, normalized_output)) {
        return null;
    }

    // Check if the next character after dir_path is a separator
    const remaining = normalized_output[normalized_dir.len..];
    if (remaining.len == 0) {
        return null;
    }

    if (!std.mem.startsWith(u8, remaining, sep)) {
        return null;
    }

    // Return the relative path (without leading separator)
    const relative_path = remaining[sep.len..];
    if (relative_path.len == 0) {
        return null;
    }

    return try allocator.dupe(u8, relative_path);
}

const ExtractHtmlResult = struct {
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

// Input
// pub fn Page(allocator: zx.Allocator) zx.Component {
//     const is_logged_in = false;
//     return (
//         <main @allocator={allocator}>
//             <p>Hello</p>
//         </main>
//     );
// }

// pub fn PageTwo(allocator: zx.Allocator) zx.Component {
//     const is_logged_in = false;
//     return (
//         <main @allocator={allocator}>
//          <span>Hello</span>
//         </main>
//     );
// }

// const zx = @import("zx");

// Output: zig_source
// pub fn Page(allocator: zx.Allocator) zx.Component {
//     const is_logged_in = false;
//     return (@html(0));
// }

// pub fn PageTwo(allocator: zx.Allocator) zx.Component {
//     const is_logged_in = false;
//     return (@html(1));
// }

// const zx = @import("zx");

// Output: htmls
// [
//     "         <main @allocator={allocator}>
//          <span>Hello</span>
//         </main>",
//     "         <main @allocator={allocator}>
//          <span>Hello</span>
//         </main>",
// ]
fn extractHtml(allocator: std.mem.Allocator, zx_source: [:0]const u8) !ExtractHtmlResult {
    var html_segments = std.ArrayList([]const u8){};
    defer html_segments.deinit(allocator);

    var zx_cleaned_source = std.ArrayList(u8){};
    defer zx_cleaned_source.deinit(allocator);

    var i: usize = 0;
    while (i < zx_source.len) {
        // Look for JSX opening tag: < followed by identifier or /
        if (i < zx_source.len and zx_source[i] == '<') {
            // Check if it's a JSX tag (not a comparison operator)
            var j = i + 1;
            // Skip whitespace after '<'
            while (j < zx_source.len and std.ascii.isWhitespace(zx_source[j])) {
                j += 1;
            }

            if (j < zx_source.len) {
                const next_char = zx_source[j];
                // JSX tag starts with < followed by identifier, /, or !
                if (std.ascii.isAlphabetic(next_char) or next_char == '/' or next_char == '!') {
                    // Found JSX, extract it
                    // Look backwards to capture leading whitespace/newlines that should be preserved
                    var html_start = i;
                    var lookback = i;
                    var found_opening_paren = false;
                    // Look backwards to find leading whitespace/newlines
                    // Stop at non-whitespace or at opening paren (which is a common boundary)
                    while (lookback > 0) {
                        const prev_char = zx_source[lookback - 1];
                        if (std.ascii.isWhitespace(prev_char)) {
                            lookback -= 1;
                            html_start = lookback;
                        } else if (prev_char == '(') {
                            // Found opening paren - don't include it in HTML segment
                            // html_start is already set to position after the paren (whitespace)
                            found_opening_paren = true;
                            break;
                        } else {
                            // Not whitespace and not opening paren, stop
                            break;
                        }
                    }

                    const html_end = try parseJsxElement(zx_source, i);

                    // Look ahead to capture trailing whitespace/newlines that should be preserved
                    // This handles cases like: </span>\n    );
                    var html_end_extended = html_end;
                    var found_closing_paren = false;
                    while (html_end_extended < zx_source.len and std.ascii.isWhitespace(zx_source[html_end_extended])) {
                        html_end_extended += 1;
                    }
                    // Only include trailing whitespace if next char is ')' or ';'
                    // This preserves formatting like: </span>\n    );
                    // But we should NOT include the ')' or ';' itself in the HTML segment
                    if (html_end_extended < zx_source.len and (zx_source[html_end_extended] == ')' or zx_source[html_end_extended] == ';')) {
                        // Include the trailing whitespace in the HTML segment (but not the ')' or ';')
                        // The ')' or ';' will stay in the cleaned source
                        found_closing_paren = true;
                    } else {
                        // Don't include trailing whitespace if it's not before ) or ;
                        html_end_extended = html_end;
                    }

                    const html_segment = zx_source[html_start..html_end_extended];

                    // Store the HTML segment (includes leading and trailing whitespace/newlines)
                    const html_copy = try allocator.dupe(u8, html_segment);
                    try html_segments.append(allocator, html_copy);

                    // If html_start < i, we've already copied characters from html_start to i-1
                    // to the cleaned source. But we want those characters to be part of the HTML
                    // segment, not in the cleaned source. So we need to remove them.
                    if (html_start < i) {
                        const chars_to_remove = i - html_start;
                        if (zx_cleaned_source.items.len >= chars_to_remove) {
                            zx_cleaned_source.items.len -= chars_to_remove;
                        }
                    }

                    const placeholder = try std.fmt.allocPrint(allocator, "@html({d})", .{html_segments.items.len - 1});
                    defer allocator.free(placeholder);
                    try zx_cleaned_source.appendSlice(allocator, placeholder);

                    i = html_end_extended;
                    continue;
                }
            }
        }

        // Not JSX, copy character as-is
        try zx_cleaned_source.append(allocator, zx_source[i]);
        i += 1;
    }

    // Null-terminate the cleaned source
    try zx_cleaned_source.append(allocator, 0);
    const cleaned = try allocator.dupeZ(u8, zx_cleaned_source.items[0 .. zx_cleaned_source.items.len - 1]);

    return ExtractHtmlResult{
        .htmls = try html_segments.toOwnedSlice(allocator),
        .zig_source = cleaned,
    };
}

/// Parse a JSX element and return the end position
/// Handles nested tags, attributes, expressions, etc.
fn parseJsxElement(source: []const u8, start: usize) !usize {
    var i = start;
    if (i >= source.len or source[i] != '<') return error.InvalidJsx;
    i += 1; // skip '<'

    // Handle comment: <!-- ... -->
    if (i + 2 < source.len and std.mem.eql(u8, source[i .. i + 3], "!--")) {
        i += 3;
        // Find closing -->
        while (i + 2 < source.len) {
            if (source[i] == '-' and source[i + 1] == '-' and source[i + 2] == '>') {
                return i + 3;
            }
            i += 1;
        }
        return error.InvalidJsx;
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
    while (i < source.len) {
        // Skip whitespace
        while (i < source.len and std.ascii.isWhitespace(source[i])) {
            i += 1;
        }
        if (i >= source.len) break;

        // Check for self-closing tag: <tag />
        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '>') {
            return i + 2; // skip '/>'
        }

        // Check for closing bracket: <tag>
        if (source[i] == '>') {
            i += 1;
            break;
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
        if (i < source.len) {
            if (source[i] == '"') {
                // String literal
                i += 1; // skip opening quote
                while (i < source.len and source[i] != '"') {
                    if (source[i] == '\\' and i + 1 < source.len) {
                        i += 2; // skip escape sequence
                    } else {
                        i += 1;
                    }
                }
                if (i < source.len) i += 1; // skip closing quote
            } else if (source[i] == '{') {
                // Expression: {expr} or {(expr)} or {[expr:fmt]}
                i += 1; // skip '{'
                var brace_depth: i32 = 1;
                while (i < source.len and brace_depth > 0) {
                    if (source[i] == '{') brace_depth += 1;
                    if (source[i] == '}') brace_depth -= 1;
                    if (brace_depth > 0) i += 1;
                }
                if (i < source.len) i += 1; // skip '}'
            }
        }
    }

    // If we found '>', we need to parse the content and closing tag
    if (i > 0 and source[i - 1] == '>') {
        // Parse content until we find the matching closing tag
        var depth: i32 = 1; // depth of nested tags

        while (i < source.len and depth > 0) {
            // Look for opening tag
            if (source[i] == '<' and i + 1 < source.len) {
                const next = source[i + 1];
                if (std.ascii.isAlphabetic(next) or next == '/' or next == '!') {
                    if (next == '/') {
                        // Closing tag - decrease depth
                        depth -= 1;
                        if (depth == 0) {
                            // Found matching closing tag, parse it
                            const closing_start = i;
                            i = try parseJsxElement(source, i);
                            // Verify it matches our tag
                            const closing_tag = findTagName(source, closing_start);
                            if (!std.mem.eql(u8, closing_tag, tag_name)) {
                                // Tag mismatch, but continue anyway
                            }
                            break;
                        } else {
                            // Nested closing tag - just skip over it manually
                            // We don't need to parse it fully, just find the closing >
                            i += 1; // skip '<'
                            i += 1; // skip '/'
                            // Skip tag name
                            while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_' or source[i] == '-')) {
                                i += 1;
                            }
                            // Find closing >
                            while (i < source.len and source[i] != '>') {
                                i += 1;
                            }
                            if (i < source.len) i += 1; // skip '>'
                            continue;
                        }
                    } else {
                        // Opening tag - check if it's self-closing or a void element
                        const opening_tag_name = findTagName(source, i);
                        const is_void_element = isVoidElement(opening_tag_name);

                        // Skip over the tag to check if it's self-closing
                        var temp_i = i;
                        var is_self_closing = false;
                        while (temp_i < source.len and source[temp_i] != '>') {
                            // Check for self-closing: <tag />
                            if (source[temp_i] == '/' and temp_i + 1 < source.len and source[temp_i + 1] == '>') {
                                is_self_closing = true;
                                break;
                            }
                            if (source[temp_i] == '"') {
                                temp_i += 1;
                                while (temp_i < source.len and source[temp_i] != '"') {
                                    if (source[temp_i] == '\\' and temp_i + 1 < source.len) {
                                        temp_i += 2;
                                    } else {
                                        temp_i += 1;
                                    }
                                }
                                if (temp_i < source.len) temp_i += 1;
                            } else if (source[temp_i] == '{') {
                                temp_i += 1;
                                var brace_depth: i32 = 1;
                                while (temp_i < source.len and brace_depth > 0) {
                                    if (source[temp_i] == '{') brace_depth += 1;
                                    if (source[temp_i] == '}') brace_depth -= 1;
                                    if (brace_depth > 0) temp_i += 1;
                                }
                                if (temp_i < source.len) temp_i += 1;
                            } else {
                                temp_i += 1;
                            }
                        }

                        // Only increase depth if it's not a void/self-closing element
                        if (!is_void_element and !is_self_closing) {
                            depth += 1;
                        }

                        if (temp_i < source.len and source[temp_i] == '>') {
                            i = temp_i + 1;
                            continue;
                        }
                    }
                }
            }

            // Handle expressions in content: {expr}
            if (source[i] == '{') {
                i += 1;
                var brace_depth: i32 = 1;
                while (i < source.len and brace_depth > 0) {
                    if (source[i] == '{') brace_depth += 1;
                    if (source[i] == '}') brace_depth -= 1;
                    if (brace_depth > 0) i += 1;
                }
                if (i < source.len) i += 1; // skip '}'
                continue;
            }

            i += 1;
        }
    }

    return i;
}

/// Check if an element is a void element (no closing tag needed)
fn isVoidElement(tag_name: []const u8) bool {
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
fn findTagName(source: []const u8, start: usize) []const u8 {
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

/// Replace @html(n) placeholders with the corresponding HTML segments
fn patchInHtml(allocator: std.mem.Allocator, extract_html: ExtractHtmlResult) ![:0]const u8 {
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < extract_html.zig_source.len) {
        // Look for @html(n) pattern
        if (i < extract_html.zig_source.len and extract_html.zig_source[i] == '@') {
            if (i + 5 < extract_html.zig_source.len and
                std.mem.eql(u8, extract_html.zig_source[i .. i + 5], "@html"))
            {

                // Found @html, parse the number
                var j = i + 5; // skip "@html"

                // Skip whitespace
                while (j < extract_html.zig_source.len and std.ascii.isWhitespace(extract_html.zig_source[j])) {
                    j += 1;
                }

                // Expect opening parenthesis
                if (j >= extract_html.zig_source.len or extract_html.zig_source[j] != '(') {
                    // Not a valid @html(n), copy as-is
                    try result.append(allocator, extract_html.zig_source[i]);
                    i += 1;
                    continue;
                }

                j += 1; // skip '('

                // Parse number
                const num_start = j;
                while (j < extract_html.zig_source.len and std.ascii.isDigit(extract_html.zig_source[j])) {
                    j += 1;
                }

                if (j == num_start) {
                    // No number found, copy as-is
                    try result.append(allocator, extract_html.zig_source[i]);
                    i += 1;
                    continue;
                }

                // Parse the number
                const num_str = extract_html.zig_source[num_start..j];
                const html_index = std.fmt.parseInt(usize, num_str, 10) catch {
                    // Invalid number, copy as-is
                    try result.append(allocator, extract_html.zig_source[i]);
                    i += 1;
                    continue;
                };

                // Skip whitespace
                while (j < extract_html.zig_source.len and std.ascii.isWhitespace(extract_html.zig_source[j])) {
                    j += 1;
                }

                // Expect closing parenthesis
                if (j >= extract_html.zig_source.len or extract_html.zig_source[j] != ')') {
                    // Not a valid @html(n), copy as-is
                    try result.append(allocator, extract_html.zig_source[i]);
                    i += 1;
                    continue;
                }

                j += 1; // skip ')'

                // Check if HTML index is valid
                if (html_index >= extract_html.htmls.len) {
                    // Invalid index, copy as-is
                    try result.append(allocator, extract_html.zig_source[i]);
                    i += 1;
                    continue;
                }

                // Replace with the HTML segment
                try result.appendSlice(allocator, extract_html.htmls[html_index]);

                i = j;
                continue;
            }
        }

        // Not @html(n), copy character as-is
        try result.append(allocator, extract_html.zig_source[i]);
        i += 1;
    }

    // Null-terminate
    try result.append(allocator, 0);
    const result_slice = result.items[0 .. result.items.len - 1 :0];

    return try allocator.dupeZ(u8, result_slice);
}

const FormatResult = struct {
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

fn fmtFile(allocator: std.mem.Allocator, source_path: []const u8, output_path: []const u8, verbose: bool) !void {
    // Read the source file
    const source = try std.fs.cwd().readFileAlloc(
        allocator,
        source_path,
        std.math.maxInt(usize),
    );
    defer allocator.free(source);

    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    // Format
    var format_result = try format(allocator, source_z);
    defer format_result.deinit(allocator);

    // Create output directory if needed
    if (std.fs.path.dirname(output_path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Write the formatted zx source
    try std.fs.cwd().writeFile(.{
        .sub_path = output_path,
        .data = format_result.formatted_zx,
    });

    if (verbose) {
        std.debug.print("Fmtd: {s} -> {s}\n", .{ source_path, output_path });
    }
}

fn fmtDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    output_dir: []const u8,
    verbose: bool,
) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    // Check if output_dir is a subdirectory of dir_path
    const output_dir_relative = try getOutputDirRelativePath(allocator, dir_path, output_dir);
    defer if (output_dir_relative) |rel| allocator.free(rel);

    const sep = std.fs.path.sep_str;

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        // Skip files in output directory if output_dir is a subdirectory of dir_path
        if (output_dir_relative) |rel| {
            // Check if entry.path starts with rel followed by separator, or is exactly rel
            if (std.mem.startsWith(u8, entry.path, rel)) {
                // Check if it's exactly rel or followed by separator
                if (entry.path.len == rel.len) {
                    continue;
                }
                if (std.mem.startsWith(u8, entry.path[rel.len..], sep)) {
                    continue;
                }
            }
        }

        const is_zx = std.mem.endsWith(u8, entry.path, ".zx");

        // Skip files that aren't .zx
        if (!is_zx) continue;

        // Build input path
        const input_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(input_path);

        // Build output path - preserve .zx extension
        const output_rel_path = try allocator.dupe(u8, entry.path);
        defer allocator.free(output_rel_path);

        const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel_path });
        defer allocator.free(output_path);

        fmtFile(allocator, input_path, output_path, verbose) catch |err| {
            std.debug.print("Error formatting {s}: {}\n", .{ input_path, err });
            continue;
        };
    }
}

fn fmtCommand(
    allocator: std.mem.Allocator,
    path: []const u8,
    output_dir: []const u8,
    verbose: bool,
) !void {
    // Check if path is a file or directory
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.IsDir => std.fs.File.Stat{ .kind = .directory, .size = 0, .mode = 0, .atime = 0, .mtime = 0, .ctime = 0, .inode = 0 },
        else => {
            std.debug.print("Error: Could not access path '{s}': {}\n", .{ path, err });
            return err;
        },
    };

    if (stat.kind == .directory) {
        if (verbose) {
            std.debug.print("Formatting directory: {s}\n", .{path});
        }
        try fmtDirectory(allocator, path, output_dir, verbose);
    } else if (stat.kind == .file) {
        const is_zx = std.mem.endsWith(u8, path, ".zx");

        if (!is_zx) {
            std.debug.print("Error: Only .zx files can be formatted\n", .{});
            return error.InvalidPath;
        }

        // Get just the filename (basename)
        const basename = getBasename(path);

        // Build output path - preserve .zx extension
        const output_rel_path = try allocator.dupe(u8, basename);
        defer allocator.free(output_rel_path);

        const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel_path });
        defer allocator.free(output_path);

        try fmtFile(allocator, path, output_path, verbose);

        if (verbose) {
            std.debug.print("Done!\n", .{});
        }
    } else {
        std.debug.print("Error: Path must be a file or directory\n", .{});
        return error.InvalidPath;
    }
}

const std = @import("std");
const zli = @import("zli");
const zx = @import("zx");
