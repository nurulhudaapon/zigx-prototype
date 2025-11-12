test "control flow > if" {
    try test_transpile(std.testing.allocator, "control_flow/if.zx", "control_flow/if.zig");
}

test "expression > text" {
    try test_transpile(std.testing.allocator, "expression/text.zx", "expression/text.zig");
}

fn test_transpile(allocator: std.mem.Allocator, comptime source_path: []const u8, comptime expected_source_path: []const u8) !void {
    const base_path = "test/data/";
    // Read the source file
    const source = try std.fs.cwd().readFileAlloc(
        allocator,
        base_path ++ source_path,
        std.math.maxInt(usize),
    );
    defer allocator.free(source);

    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    // Parse and transpile
    var result = try zx.Ast.parse(allocator, source_z);
    defer result.deinit(allocator);

    const expected_source = try std.fs.cwd().readFileAlloc(
        allocator,
        base_path ++ expected_source_path,
        std.math.maxInt(usize),
    );
    defer allocator.free(expected_source);
    const expected_source_z = try allocator.dupeZ(u8, expected_source);
    defer allocator.free(expected_source_z);

    try testing.expectEqualStrings(expected_source_z, result.zig_source);
}

const std = @import("std");
const testing = std.testing;
const zx = @import("zx");
