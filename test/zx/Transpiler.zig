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
// If
test "control_flow > if" {
    try test_transpile("control_flow/if");
}
test "control_flow > if_block" {
    try test_transpile("control_flow/if_block");
}
// For
test "control_flow > for" {
    try test_transpile("control_flow/for");
}
test "control_flow > for_block" {
    try test_transpile("control_flow/for_block");
}
// Switch
test "control_flow > switch" {
    try test_transpile("control_flow/switch");
}
test "control_flow > switch_block" {
    return error.SkipZigTest;
    // try test_transpile("control_flow/switch_block");
}
// Nested Control Flow (2-level nesting)
test "control_flow > if_if" {
    return error.SkipZigTest;
    // try test_transpile("control_flow/if_if");
}
test "control_flow > if_for" {
    return error.SkipZigTest;
    // try test_transpile("control_flow/if_for");
}
test "control_flow > if_switch" {
    return error.SkipZigTest;
    // try test_transpile("control_flow/if_switch");
}
test "control_flow > for_if" {
    return error.SkipZigTest;
    // try test_transpile("control_flow/for_if");
}
test "control_flow > for_for" {
    return error.SkipZigTest;
    // try test_transpile("control_flow/for_for");
}
test "control_flow > for_switch" {
    try test_transpile("control_flow/for_switch");
}
test "control_flow > switch_if" {
    return error.SkipZigTest;
    // try test_transpile("control_flow/switch_if");
}
test "control_flow > switch_for" {
    return error.SkipZigTest;
    // try test_transpile("control_flow/switch_for");
}
test "control_flow > switch_switch" {
    return error.SkipZigTest;
    // try test_transpile("control_flow/switch_switch");
}
// While
// TODO: Implement while loop
test "control_flow > while" {
    return error.SkipZigTest;
    // try test_transpile("control_flow/while");
}

test "control_flow > while_block" {
    return error.SkipZigTest;
    // try test_transpile("control_flow/while_block");
}

test "expression > text" {
    try test_transpile("expression/text");
}
test "expression > format" {
    try test_transpile("expression/format");
}
test "expression > component" {
    try test_transpile("expression/component");
}

test "component > basic" {
    try test_transpile("component/basic");
}
test "component > multiple" {
    try test_transpile("component/multiple");
}

fn test_transpile(comptime file_path: []const u8) !void {
    const allocator = std.testing.allocator;
    const cache = test_file_cache orelse return error.CacheNotInitialized;

    // Construct paths for .zx and .zig files
    const source_path = file_path ++ ".zx";
    const expected_source_path = file_path ++ ".zig";

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
        const test_files = [_][]const u8{
            // Control Flow
            "control_flow/if",
            "control_flow/if_block",
            "control_flow/for",
            "control_flow/for_block",
            "control_flow/switch",
            // "control_flow/switch_block",
            // Nested Control Flow (2-level nesting)
            // "control_flow/if_if",
            // "control_flow/if_for",
            // "control_flow/if_switch",
            // "control_flow/for_if",
            // "control_flow/for_for",
            "control_flow/for_switch",
            // "control_flow/switch_if",
            // "control_flow/switch_for",
            // "control_flow/switch_switch",
            // "control_flow/while",
            // "control_flow/while_block",
            // Expression
            "expression/text",
            "expression/format",
            "expression/component",
            // Component
            "component/basic",
            "component/multiple",
        };

        // Load both .zx and .zig files for each test file
        for (test_files) |file_path| {
            for ([_]struct { ext: []const u8 }{ .{ .ext = ".zx" }, .{ .ext = ".zig" } }) |ext_info| {
                const full_path = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ base_path, file_path, ext_info.ext });
                defer allocator.free(full_path);

                const content = std.fs.cwd().readFileAlloc(
                    allocator,
                    full_path,
                    std.math.maxInt(usize),
                ) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                const cache_key = try std.fmt.allocPrint(allocator, "{s}{s}", .{ file_path, ext_info.ext });
                try cache.files.put(cache_key, content);
            }
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
