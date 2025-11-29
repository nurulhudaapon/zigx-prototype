const std = @import("std");
const builtin = @import("builtin");
const Colors = @import("Colors.zig");

pub const Printer = @This();

// Helper to check if a string is likely an emoji
fn isEmojiString(str: []const u8) bool {
    // Check if string contains non-ASCII characters (likely emoji)
    // Simple heuristic: if it's a short string with non-ASCII, it's probably emoji
    if (str.len == 0) return false;

    var has_non_ascii = false;
    for (str) |byte| {
        if (byte > 127) {
            has_non_ascii = true;
            break;
        }
    }

    // If it's a short string (1-8 bytes typically) with non-ASCII, likely emoji
    return has_non_ascii and str.len <= 8;
}

// Helper to print with emoji replacement on Windows
fn printWithEmojiReplacement(comptime fmt: []const u8, args: anytype) void {
    const is_windows = builtin.os.tag == .windows;

    if (is_windows) {
        // Process args to replace emoji strings
        const ArgsType = @TypeOf(args);
        const args_info = @typeInfo(ArgsType);

        // In Zig, tuples are anonymous structs, so check for struct
        if (args_info == .@"struct") {
            // Create a modified struct/tuple by processing each field
            var processed_args: ArgsType = args;
            inline for (args_info.@"struct".fields) |field| {
                if (field.type == []const u8) {
                    // Use @field with the field name (which for tuples is like .0, .1, etc.)
                    const field_ptr = &@field(processed_args, field.name);
                    if (isEmojiString(field_ptr.*)) {
                        field_ptr.* = "";
                    }
                }
            }
            std.debug.print(fmt, processed_args);
        } else {
            // Single arg - check if it's a string and emoji
            if (ArgsType == []const u8 and isEmojiString(args)) {
                std.debug.print(fmt, .{""});
            } else {
                std.debug.print(fmt, args);
            }
        }
    } else {
        std.debug.print(fmt, args);
    }
}

arena: std.heap.ArenaAllocator,
printed_dirs: std.StringHashMap(void),
options: PrinterOptions,

pub const DisplayMode = enum {
    tree,
    flat,
};

pub const PrinterOptions = struct {
    file_path_mode: DisplayMode = .tree,
    file_tree_max_depth: ?usize = null,
};

pub fn init(allocator: std.mem.Allocator, options: PrinterOptions) Printer {
    return Printer{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .printed_dirs = std.StringHashMap(void).init(allocator),
        .options = options,
    };
}

pub fn deinit(self: *Printer) void {
    self.printed_dirs.deinit();
    self.arena.deinit();
}

pub fn filepath(self: *Printer, file_path: []const u8) void {
    switch (self.options.file_path_mode) {
        .flat => {
            // Show as single flat path like before
            std.debug.print("    + \x1b[90m{s}\x1b[0m\n", .{file_path});
            return;
        },
        .tree => {
            // Show as tree structure
            const arena = self.arena.allocator();

            // Split path into components
            var components = std.array_list.Managed([]const u8).init(arena);
            defer components.deinit();

            var it = std.mem.splitScalar(u8, file_path, '/');
            while (it.next()) |component| {
                if (component.len > 0) {
                    components.append(component) catch return;
                }
            }

            if (components.items.len == 0) return;

            // Print directories leading to the file
            var current_path = std.array_list.Managed(u8).init(arena);
            defer current_path.deinit();

            for (components.items[0 .. components.items.len - 1], 0..) |dir, depth| {
                if (self.options.file_tree_max_depth) |max_depth| {
                    if (depth >= max_depth) break;
                }

                if (current_path.items.len > 0) {
                    current_path.append('/') catch return;
                }
                current_path.appendSlice(dir) catch return;

                const dir_path = current_path.items;
                const key = arena.dupe(u8, dir_path) catch return;

                if (self.printed_dirs.contains(key)) {
                    // Key already exists, skip
                } else {
                    // Print indent (4 spaces per depth level)
                    var i: usize = 0;
                    while (i < depth + 1) : (i += 1) {
                        std.debug.print("    ", .{});
                    }
                    std.debug.print("- \x1b[90m{s}\x1b[0m\n", .{dir});
                    self.printed_dirs.put(key, {}) catch return;
                }
            }

            // Print the file
            var i: usize = 0;
            while (i < components.items.len) : (i += 1) {
                std.debug.print("    ", .{});
            }
            const filename = components.items[components.items.len - 1];
            std.debug.print("+ \x1b[90m{s}\x1b[0m\n", .{filename});
        },
    }
}

pub fn header(self: *Printer, comptime fmt: []const u8, args: anytype) void {
    _ = self;
    const is_windows = builtin.os.tag == .windows;

    if (is_windows) {
        std.debug.print("{s}", .{Colors.cyan});
        printWithEmojiReplacement(fmt, args);
        std.debug.print("{s}\n\n", .{Colors.reset});
    } else {
        printWithEmojiReplacement(fmt, args);
        std.debug.print("\n\n", .{});
    }
}

pub fn footer(self: *Printer, comptime fmt: []const u8, args: anytype) void {
    _ = self;
    std.debug.print("\n", .{});
    printWithEmojiReplacement(fmt, args);
    std.debug.print("\n\n", .{});
}

pub fn warning(self: *Printer, comptime fmt: []const u8, args: anytype) void {
    _ = self;
    const is_windows = builtin.os.tag == .windows;

    if (is_windows) {
        std.debug.print("{s}Warning:{s} ", .{ Colors.yellow, Colors.reset });
    } else {
        std.debug.print("{s}{s} Warning:{s} ", .{ Colors.yellow, "⚠", Colors.reset });
    }
    printWithEmojiReplacement(fmt, args);
    std.debug.print("\n", .{});
}

pub fn info(self: *Printer, comptime fmt: []const u8, args: anytype) void {
    _ = self;
    std.debug.print("  - {s}", .{Colors.gray});
    printWithEmojiReplacement(fmt, args);
    std.debug.print("{s}\n", .{Colors.reset});
}
