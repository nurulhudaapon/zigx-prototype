test "tests:beforeAll" {
    gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_state.?.allocator();
    test_file_cache = try TestFileCache.init(gpa);
}

test "tests:afterAll" {
    if (test_file_cache) |*cache| {
        cache.deinit();
        test_file_cache = null;
    }
    if (gpa_state) |*gpa| {
        _ = gpa.deinit();
        gpa_state = null;
    }
}

// Control Flow
const cf_path = "control_flow/";
// If
test "control_flow > if" {
    try test_transpile(cf_path ++ "if.zx", cf_path ++ "if.zig");
}
test "control_flow > if_block" {
    try test_transpile(cf_path ++ "if_block.zx", cf_path ++ "if_block.zig");
}
// For
test "control_flow > for" {
    try test_transpile(cf_path ++ "for.zx", cf_path ++ "for.zig");
}
test "control_flow > for_block" {
    try test_transpile(cf_path ++ "for_block.zx", cf_path ++ "for_block.zig");
}
// Switch
test "control_flow > switch" {
    try test_transpile(cf_path ++ "switch.zx", cf_path ++ "switch.zig");
}
test "control_flow > switch_block" {
    try test_transpile(cf_path ++ "switch_block.zx", cf_path ++ "switch_block.zig");
}
// While
// TODO: Implement while loop
// test "control_flow > while" {
//     try test_transpile(cf_path ++ "while.zx", cf_path ++ "while.zig");
// }

// test "control_flow > while_block" {
//     try test_transpile(cf_path ++ "while_block.zx", cf_path ++ "while_block.zig");
// }

const exp_path = "expression/";
test "expression > text" {
    try test_transpile(exp_path ++ "text.zx", exp_path ++ "text.zig");
}

fn test_transpile(comptime source_path: []const u8, comptime expected_source_path: []const u8) !void {
    const allocator = std.testing.allocator;
    const cache = test_file_cache orelse return error.CacheNotInitialized;

    // Get pre-loaded source file
    const source = cache.get(source_path) orelse return error.FileNotFound;
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    // Parse and transpile
    var result = try zx.Ast.parse(allocator, source_z);
    defer result.deinit(allocator);

    // Get pre-loaded expected file
    const expected_source = cache.get(expected_source_path) orelse return error.FileNotFound;
    const expected_source_z = try allocator.dupeZ(u8, expected_source);
    defer allocator.free(expected_source_z);

    try testing.expectEqualStrings(expected_source_z, result.zig_source);
}

var test_file_cache: ?TestFileCache = null;
var gpa_state: ?std.heap.GeneralPurposeAllocator(.{}) = null;

const TestFileCache = struct {
    files: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !TestFileCache {
        var cache = TestFileCache{
            .files = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };

        const base_path = "test/data/";
        const test_files = [_]struct { path: []const u8 }{
            // Control Flow
            // If
            .{ .path = "control_flow/if.zx" },
            .{ .path = "control_flow/if.zig" },
            .{ .path = "control_flow/if_block.zx" },
            .{ .path = "control_flow/if_block.zig" },
            // While
            // .{ .path = "control_flow/while.zx" },
            // .{ .path = "control_flow/while.zig" },
            // .{ .path = "control_flow/while_block.zx" },
            // .{ .path = "control_flow/while_block.zig" },
            // For
            .{ .path = "control_flow/for.zx" },
            .{ .path = "control_flow/for.zig" },
            .{ .path = "control_flow/for_block.zx" },
            .{ .path = "control_flow/for_block.zig" },
            // Switch
            .{ .path = "control_flow/switch.zx" },
            .{ .path = "control_flow/switch.zig" },
            .{ .path = "control_flow/switch_block.zx" },
            .{ .path = "control_flow/switch_block.zig" },
            // Expression
            // Text
            .{ .path = "expression/text.zx" },
            .{ .path = "expression/text.zig" },
        };

        for (test_files) |file| {
            const full_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_path, file.path });
            defer allocator.free(full_path);

            const content = try std.fs.cwd().readFileAlloc(
                allocator,
                full_path,
                std.math.maxInt(usize),
            );
            const key = try allocator.dupe(u8, file.path);
            try cache.files.put(key, content);
        }

        return cache;
    }

    fn deinit(self: *TestFileCache) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit();
    }

    fn get(self: *const TestFileCache, path: []const u8) ?[]const u8 {
        return self.files.get(path);
    }
};

const std = @import("std");
const testing = std.testing;
const zx = @import("zx");
