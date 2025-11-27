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
    try test_fmt("control_flow/if", false);
}

test "if_block" {
    try test_fmt("control_flow/if_block", false);
}

test "if_if_only" {
    return error.Todo;
    // try test_transpile("control_flow/if_if_only");
}

test "if_if_only_block" {
    return error.Todo;
    // try test_transpile("control_flow/if_if_only_block");
}
test "if_only" {
    try test_fmt("control_flow/if_only", false);
}

test "if_only_block" {
    try test_fmt("control_flow/if_only_block", false);
}
// For
test "for" {
    try test_fmt("control_flow/for", false);
}

test "for_block" {
    try test_fmt("control_flow/for_block", false);
}
// Switch
test "switch" {
    try test_fmt("control_flow/switch", false);
}
test "switch_block" {
    return error.Todo;
    // try test_fmt("control_flow/switch_block");
}
// Nested Control Flow (2-level nesting)
test "if_if" {
    return error.Todo;
    // try test_fmt("control_flow/if_if", false);
}
test "if_for" {
    return error.Todo;
    // try test_fmt("control_flow/if_for", false);
}
test "if_switch" {
    return error.Todo;
    // try test_fmt("control_flow/if_switch", false);
}
test "for_if" {
    return error.Todo;
    // try test_fmt("control_flow/for_if", false);
}
test "for_for" {
    try test_fmt("control_flow/for_for", false);
}
test "for_switch" {
    try test_fmt("control_flow/for_switch", false);
}
test "switch_if" {
    return error.Todo;
    // try test_fmt("control_flow/switch_if");
}
test "switch_for" {
    return error.Todo;
    // try test_fmt("control_flow/switch_for");
}
test "switch_switch" {
    return error.Todo;
    // try test_fmt("control_flow/switch_switch");
}
// While
test "while" {
    try test_fmt("control_flow/while", false);
}

test "while_block" {
    return error.Todo;
    // try test_fmt("control_flow/while_block");
}

test "expression_text" {
    try test_fmt("expression/text", false);
}
test "expression_format" {
    try test_fmt("expression/format", false);
}
test "expression_component" {
    return error.Todo;
    // try test_fmt("expression/component");
}

test "component_basic" {
    return error.Todo;
    // try test_fmt("component/basic");
}
test "component_multiple" {
    return error.Todo;
    // try test_fmt("component/multiple");
}
test "component_csr_react" {
    return error.Todo;
    // try test_fmt("component/csr_react");
}
test "component_csr_react_multiple" {
    return error.Todo;
    // try test_fmt("component/csr_react_multiple");
}

test "performance" {
    const MAX_TIME_MS = 50.0 * 8; // 50ms is on M1 Pro
    const MAX_TIME_PER_FILE_MS = 8.0 * 10; // 5ms is on M1 Pro

    var total_time_ns: f64 = 0.0;
    inline for (TestFileCache.test_files) |comptime_path| {
        const start_time = std.time.nanoTimestamp();
        test_fmt(comptime_path, true) catch {
            // continue;
        };
        const end_time = std.time.nanoTimestamp();
        const duration = @as(f64, @floatFromInt(end_time - start_time));
        total_time_ns += duration;
        const duration_ms = duration / std.time.ns_per_ms;
        try expectLessThan(MAX_TIME_PER_FILE_MS, duration_ms);
    }

    const total_time_ms = total_time_ns / std.time.ns_per_ms;
    const average_time_ms = total_time_ms / TestFileCache.test_files.len;
    std.debug.print("\x1b[33m⏱️\x1b[0m fmt \x1b[90m>\x1b[0m {d:.2}ms | Avg: {d:.2}ms\n", .{ total_time_ms, average_time_ms });

    try expectLessThan(MAX_TIME_MS, total_time_ms);
    try expectLessThan(MAX_TIME_PER_FILE_MS, average_time_ms);
}

fn test_fmt(comptime file_path: []const u8, no_expect: bool) !void {
    const allocator = std.testing.allocator;
    const cache = test_file_cache orelse return error.CacheNotInitialized;

    // Construct paths for .zx and .zig files
    const source_path = file_path ++ ".zx";
    const expected_source_path = file_path ++ ".zx";

    // Get pre-loaded source file
    const source = cache.get(source_path) orelse return error.FileNotFound;
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    // Parse and transpile
    var result = try zx.Ast.fmt(allocator, source_z);
    defer result.deinit(allocator);

    // Get pre-loaded expected file
    const expected_source = cache.get(expected_source_path) orelse return error.FileNotFound;
    const expected_source_z = try allocator.dupeZ(u8, expected_source);
    defer allocator.free(expected_source_z);

    if (!no_expect) {
        try testing.expectEqualStrings(expected_source_z, result.formatted_zx);
    }
}

fn expectLessThan(expected: f64, actual: f64) !void {
    if (actual > expected) {
        std.debug.print("\x1b[31m✗\x1b[0m Expected < {d:.2}ms, got {d:.2}ms\n", .{ expected, actual });
        return error.TestExpectedLessThan;
    }
}

var test_file_cache: ?TestFileCache = null;
var gpa_state: ?std.heap.GeneralPurposeAllocator(.{}) = null;

const TestFileCache = @import("./../test_util.zig").TestFileCache;

const std = @import("std");
const testing = std.testing;
const zx = @import("zx");
