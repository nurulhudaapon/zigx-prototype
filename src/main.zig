const Page = @import("zigx/examples/zig/index.zig").Page;

fn writeFileIfChanged(sub_path: []const u8, data: []const u8) !void {
    // Try to read existing file
    const existing = std.fs.cwd().readFileAlloc(
        std.heap.page_allocator,
        sub_path,
        std.math.maxInt(usize),
    ) catch |err| switch (err) {
        error.FileNotFound => {
            // File doesn't exist, write it
            try std.fs.cwd().writeFile(.{
                .sub_path = sub_path,
                .data = data,
            });
            return;
        },
        else => return err,
    };
    defer std.heap.page_allocator.free(existing);

    // Compare content
    if (std.mem.eql(u8, existing, data)) {
        // Content is the same, skip writing
        return;
    }

    // Content changed, write the file
    try std.fs.cwd().writeFile(.{
        .sub_path = sub_path,
        .data = data,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const source = @embedFile("zigx/examples/index.zigx");
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    var result = try zx.Ast.parse(allocator, source_z);
    defer result.deinit(allocator);

    try writeFileIfChanged("src/zigx/examples/zig/index.zig", result.zig_source);

    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();

    try Page().element.render(&aw.writer);
    std.debug.print("{s}\n", .{aw.written()});
    try writeFileIfChanged("src/zigx/examples/html/index.html", aw.written());
    aw.clearRetainingCapacity();
}

test "test parse" {
    const allocator = std.testing.allocator;
    const source = @embedFile("zigx/examples/index.zigx");
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    var result = try zx.Ast.parse(allocator, source_z);
    defer result.deinit(allocator);

    if (result.zig_ast.errors.len > 0) {
        std.debug.print("\n=== PARSE ERRORS ===\n", .{});
        for (result.zig_ast.errors) |err| {
            const loc = result.zig_ast.tokenLocation(0, err.token);
            std.debug.print("Error at line {d}, col {d}: {s}\n", .{ loc.line, loc.column, @tagName(err.tag) });
        }
    } else {
        std.debug.print("\n=== AST PARSED SUCCESSFULLY ===\n", .{});
        const rendered = try result.zig_ast.renderAlloc(allocator);
        defer allocator.free(rendered);
        std.debug.print("{s}\n", .{rendered});
    }
}

const std = @import("std");
const zx = @import("zx");
