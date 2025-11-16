pub const ParseResult = struct {
    zig_ast: std.zig.Ast,
    zx_source: [:0]const u8,
    zig_source: [:0]const u8,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        self.zig_ast.deinit(allocator);
        allocator.free(self.zx_source);
        allocator.free(self.zig_source);
    }
};

pub fn parse(gpa: std.mem.Allocator, zx_source: [:0]const u8) !ParseResult {
    var aa = std.heap.ArenaAllocator.init(gpa);
    defer aa.deinit();
    const arena = aa.allocator();
    const allocator = aa.allocator();

    const zig_source = try Transpiler.transpile(arena, zx_source);

    var ast = try std.zig.Ast.parse(gpa, zig_source, .zig);

    if (ast.errors.len > 0) {
        for (ast.errors) |err| {
            var w: std.io.Writer.Allocating = .init(allocator);
            defer w.deinit();
            try ast.renderError(err, &w.writer);
            std.debug.print("{s}\n", .{w.written()});
        }
        ast.deinit(gpa);
        return error.ParseError;
    }

    const rendered_zig_source = try ast.renderAlloc(allocator);
    const rendered_zig_source_z = try allocator.dupeZ(u8, rendered_zig_source);

    return ParseResult{
        .zig_ast = ast,
        .zx_source = try gpa.dupeZ(u8, zig_source),
        .zig_source = try gpa.dupeZ(u8, rendered_zig_source_z),
    };
}

const std = @import("std");
const Transpiler = @import("Transpiler_prototype.zig");
