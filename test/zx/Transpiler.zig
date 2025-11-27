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
    try test_render(@import("./../data/control_flow/if.zig").Page);
}

test "if_block" {
    try test_transpile("control_flow/if_block");
    try test_render(@import("./../data/control_flow/if_block.zig").Page);
}

test "if_if_only" {
    return error.Todo;
    // try test_transpile("control_flow/if_if_only");
    // try test_render(@import("./../data/control_flow/if_if_only.zig").Page);
}

test "if_if_only_block" {
    return error.Todo;
    // try test_transpile("control_flow/if_if_only_block");
    // try test_render(@import("./../data/control_flow/if_if_only_block.zig").Page);
}
test "if_only" {
    try test_transpile("control_flow/if_only");
    try test_render(@import("./../data/control_flow/if_only.zig").Page);
}

test "if_only_block" {
    try test_transpile("control_flow/if_only_block");
    try test_render(@import("./../data/control_flow/if_only_block.zig").Page);
}
// For
test "for" {
    try test_transpile("control_flow/for");
    try test_render(@import("./../data/control_flow/for.zig").Page);
}
test "for_capture" {
    try test_render(@import("./../data/control_flow/for.zig").StructCapture);
}
test "for_capture_to_component" {
    try test_render(@import("./../data/control_flow/for.zig").StructCaptureToComponent);
}
test "for_block" {
    try test_transpile("control_flow/for_block");
    try test_render(@import("./../data/control_flow/for_block.zig").Page);
}
// Switch
test "switch" {
    try test_transpile("control_flow/switch");
    try test_render(@import("./../data/control_flow/switch.zig").Page);
}
test "switch_block" {
    try test_transpile("control_flow/switch_block");
    try test_render(@import("./../data/control_flow/switch_block.zig").Page);
}
// Nested Control Flow (2-level nesting)
test "if_if" {
    try test_transpile("control_flow/if_if");
    try test_render(@import("./../data/control_flow/if_if.zig").Page);
}
test "if_for" {
    try test_transpile("control_flow/if_for");
    try test_render(@import("./../data/control_flow/if_for.zig").Page);
}
test "if_switch" {
    try test_transpile("control_flow/if_switch");
    try test_render(@import("./../data/control_flow/if_switch.zig").Page);
}
test "for_if" {
    try test_transpile("control_flow/for_if");
    try test_render(@import("./../data/control_flow/for_if.zig").Page);
}
test "for_for" {
    try test_transpile("control_flow/for_for");
    try test_render(@import("./../data/control_flow/for_for.zig").Page);
}
test "for_switch" {
    try test_transpile("control_flow/for_switch");
    try test_render(@import("./../data/control_flow/for_switch.zig").Page);
}
test "switch_if" {
    try test_transpile("control_flow/switch_if");
    try test_render(@import("./../data/control_flow/switch_if.zig").Page);
}
test "switch_for" {
    try test_transpile("control_flow/switch_for");
    try test_render(@import("./../data/control_flow/switch_for.zig").Page);
}
test "switch_switch" {
    try test_transpile("control_flow/switch_switch");
    try test_render(@import("./../data/control_flow/switch_switch.zig").Page);
}
// While
test "while" {
    try test_transpile("control_flow/while");
    try test_render(@import("./../data/control_flow/while.zig").Page);
}

test "while_block" {
    try test_transpile("control_flow/while_block");
    try test_render(@import("./../data/control_flow/while_block.zig").Page);
}

test "expression_text" {
    try test_transpile("expression/text");
    try test_render(@import("./../data/expression/text.zig").Page);
}
test "expression_format" {
    try test_transpile("expression/format");
    try test_render(@import("./../data/expression/format.zig").Page);
}
test "expression_component" {
    try test_transpile("expression/component");
    try test_render(@import("./../data/expression/component.zig").Page);
}

test "component_basic" {
    try test_transpile("component/basic");
    try test_render(@import("./../data/component/basic.zig").Page);
}
test "component_multiple" {
    try test_transpile("component/multiple");
    try test_render(@import("./../data/component/multiple.zig").Page);
}
test "component_csr_react" {
    try test_transpile("component/csr_react");
    try test_render(@import("./../data/component/csr_react.zig").Page);
}
test "component_csr_react_multiple" {
    try test_transpile("component/csr_react_multiple");
    try test_render(@import("./../data/component/csr_react_multiple.zig").Page);
}

test "performance" {
    const MAX_TIME_MS = 50.0 * 8; // 50ms is on M1 Pro
    const MAX_TIME_PER_FILE_MS = 8.0 * 10; // 5ms is on M1 Pro

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

fn test_render(comptime cmp: fn (allocator: std.mem.Allocator) zx.Component) !void {
    const gpa = std.testing.allocator;
    var aa = std.heap.ArenaAllocator.init(gpa);
    defer aa.deinit();
    const allocator = aa.allocator();

    const component = cmp(allocator);
    var aw = std.io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try component.render(&aw.writer);
    const rendered = aw.written();
    try testing.expect(rendered.len > 0);

    // std.debug.print("\x1b[32m✓\x1b[0m Rendered: {s}\n", .{rendered});

    // try testing.expectEqualStrings(expected_source_z, rendered);
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
