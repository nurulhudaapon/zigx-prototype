/// Helper function to find minimum indentation in non-empty lines
pub fn findMinIndent(lines: []const []const u8, first_non_empty: usize, last_non_empty: usize) usize {
    var min_indent: usize = std.math.maxInt(usize);
    for (lines[first_non_empty .. last_non_empty + 1]) |line| {
        if (std.mem.trim(u8, line, " \t").len > 0) {
            var indent: usize = 0;
            for (line) |char| {
                if (char == ' ' or char == '\t') {
                    indent += 1;
                } else {
                    break;
                }
            }
            if (indent < min_indent) {
                min_indent = indent;
            }
        }
    }
    return if (min_indent == std.math.maxInt(usize)) 0 else min_indent;
}

/// Helper function to remove common leading indentation
pub fn removeCommonIndentation(allocator: zx.Allocator, content: []const u8) []const u8 {
    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        lines.append(line) catch unreachable;
    }

    if (lines.items.len == 0) {
        return allocator.dupe(u8, "") catch unreachable;
    }

    // Find first and last non-empty lines
    var first_non_empty: ?usize = null;
    var last_non_empty: ?usize = null;
    for (lines.items, 0..) |line, i| {
        if (std.mem.trim(u8, line, " \t").len > 0) {
            if (first_non_empty == null) {
                first_non_empty = i;
            }
            last_non_empty = i;
        }
    }

    if (first_non_empty == null) {
        return allocator.dupe(u8, "") catch unreachable;
    }

    const first = first_non_empty.?;
    const last = last_non_empty.?;

    // Find minimum indentation
    const min_indent = findMinIndent(lines.items, first, last);

    // Build result with indentation removed
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    for (lines.items[first .. last + 1], 0..) |line, i| {
        if (i > 0) {
            result.append('\n') catch unreachable;
        }
        if (std.mem.trim(u8, line, " \t").len > 0) {
            const start = @min(min_indent, line.len);
            result.appendSlice(line[start..]) catch unreachable;
        } else {
            result.appendSlice(line) catch unreachable;
        }
    }

    return allocator.dupe(u8, result.items) catch unreachable;
}

/// Extract content inside return (...) for ZX code
pub fn extractZxReturnContent(allocator: zx.Allocator, content: []const u8) []const u8 {
    const return_pattern = "return (";
    if (std.mem.indexOf(u8, content, return_pattern)) |start_idx| {
        var depth: usize = 1;
        var i = start_idx + return_pattern.len;
        while (i < content.len and depth > 0) {
            if (content[i] == '(') {
                depth += 1;
            } else if (content[i] == ')') {
                depth -= 1;
                if (depth == 0) {
                    return allocator.dupe(u8, content[start_idx + return_pattern.len .. i]) catch unreachable;
                }
            }
            i += 1;
        }
    }
    return allocator.dupe(u8, content) catch unreachable;
}

/// Extract content after return statement for Zig code (until semicolon)
pub fn extractZigReturnContent(allocator: zx.Allocator, content: []const u8) []const u8 {
    const return_pattern = "return ";
    if (std.mem.indexOf(u8, content, return_pattern)) |start_idx| {
        var depth: usize = 0;
        var in_string = false;
        var string_char: ?u8 = null;
        var i = start_idx + return_pattern.len;

        while (i < content.len) {
            const char = content[i];

            // Handle string literals
            if (char == '"' or char == '\'') {
                // Check if previous character is not a backslash (or if backslash is escaped)
                var is_escaped = false;
                if (i > start_idx + return_pattern.len) {
                    var backslash_count: usize = 0;
                    var j = i - 1;
                    while (j >= start_idx + return_pattern.len and content[j] == '\\') {
                        backslash_count += 1;
                        j -= 1;
                    }
                    is_escaped = (backslash_count % 2) == 1;
                }

                if (!is_escaped) {
                    if (!in_string) {
                        in_string = true;
                        string_char = char;
                    } else if (char == string_char) {
                        in_string = false;
                        string_char = null;
                    }
                }
            }

            // Only process brackets/braces/parentheses outside of strings
            if (!in_string) {
                if (char == '(' or char == '{' or char == '[') {
                    depth += 1;
                } else if (char == ')' or char == '}' or char == ']') {
                    depth -= 1;
                } else if (char == ';' and depth == 0) {
                    return allocator.dupe(u8, content[start_idx + return_pattern.len .. i]) catch unreachable;
                }
            }

            i += 1;
        }
    }
    return allocator.dupe(u8, content) catch unreachable;
}

const zx = @import("zx");
const std = @import("std");
