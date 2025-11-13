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
test "if" {
    try test_transpile("control_flow/if");
}
test "if_block" {
    try test_transpile("control_flow/if_block");
}
// For
test "for" {
    try test_transpile("control_flow/for");
}
test "for_block" {
    try test_transpile("control_flow/for_block");
}
// Switch
test "switch" {
    try test_transpile("control_flow/switch");
}
test "switch_block" {
    return error.Todo;
    // try test_transpile("control_flow/switch_block");
}
// Nested Control Flow (2-level nesting)
test "if_if" {
    return error.Todo;
    // try test_transpile("control_flow/if_if");
}
test "if_for" {
    return error.Todo;
    // try test_transpile("control_flow/if_for");
}
test "if_switch" {
    return error.Todo;
    // try test_transpile("control_flow/if_switch");
}
test "for_if" {
    return error.Todo;
    // try test_transpile("control_flow/for_if");
}
test "for_for" {
    return error.Todo;
    // try test_transpile("control_flow/for_for");
}
test "for_switch" {
    try test_transpile("control_flow/for_switch");
}
test "switch_if" {
    return error.Todo;
    // try test_transpile("control_flow/switch_if");
}
test "switch_for" {
    return error.Todo;
    // try test_transpile("control_flow/switch_for");
}
test "switch_switch" {
    return error.Todo;
    // try test_transpile("control_flow/switch_switch");
}
// While
// TODO: Implement while loop
test "while" {
    return error.Todo;
    // try test_transpile("control_flow/while");
}

test "while_block" {
    return error.Todo;
    // try test_transpile("control_flow/while_block");
}

test "expression_text" {
    try test_transpile("expression/text");
}
test "expression_format" {
    try test_transpile("expression/format");
}
test "expression_component" {
    try test_transpile("expression/component");
}

test "component_basic" {
    try test_transpile("component/basic");
}
test "component_multiple" {
    try test_transpile("component/multiple");
}

test "performance" {
    const MAX_TIME_MS = 50.0 * 3; // 50ms is on M1 Pro
    const MAX_TIME_PER_FILE_MS = 5.0 * 10; // 5ms is on M1 Pro

    var total_time_ns: f64 = 0.0;
    inline for (TestFileCache.test_files) |comptime_path| {
        const start_time = std.time.nanoTimestamp();
        try test_transpile(comptime_path);
        const end_time = std.time.nanoTimestamp();
        const duration = @as(f64, @floatFromInt(end_time - start_time));
        total_time_ns += duration;
        const duration_ms = duration / std.time.ns_per_ms;
        try expectLessThan(MAX_TIME_PER_FILE_MS, duration_ms);
    }

    const total_time_ms = total_time_ns / std.time.ns_per_ms;
    const average_time_ms = total_time_ms / TestFileCache.test_files.len;
    std.debug.print("\x1b[33m⏱️\x1b[0m Transpiler \x1b[90m>\x1b[0m {d:.2}ms | Avg: {d:.2}ms\n", .{ total_time_ms, average_time_ms });

    try expectLessThan(MAX_TIME_MS, total_time_ms);
    try expectLessThan(MAX_TIME_PER_FILE_MS, average_time_ms);
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

fn expectLessThan(expected: f64, actual: f64) !void {
    if (actual > expected) {
        std.debug.print("\x1b[31m✗\x1b[0m Expected {d:.2}ms, got {d:.2}ms\n", .{ expected, actual });
        return error.TestExpectedLessThan;
    }
}

var test_file_cache: ?TestFileCache = null;
var gpa_state: ?std.heap.GeneralPurposeAllocator(.{}) = null;

const TestFileCache = struct {
    files: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    pub const test_files = [_][]const u8{
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
    fn init(allocator: std.mem.Allocator) !TestFileCache {
        var cache = TestFileCache{
            .files = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };

        const base_path = "test/data/";

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
