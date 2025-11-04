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

pub fn parse(allocator: std.mem.Allocator, zx_source: [:0]const u8) !ParseResult {
    const zig_source = try Transpiler.transpile(allocator, zx_source);
    errdefer allocator.free(zig_source);

    // std.debug.print("Transpiled ZX source:\n{s}\n", .{zig_source});

    const ast = try std.zig.Ast.parse(allocator, zig_source, .zig);

    if (ast.errors.len > 0) {
        for (ast.errors) |err| {
            var w: std.io.Writer.Allocating = .init(allocator);
            defer w.deinit();
            try ast.renderError(err, &w.writer);
            std.debug.print("{s}\n", .{w.written()});
        }
        return error.ParseError;
    }

    const rendered_zig_source = try ast.renderAlloc(allocator);
    const rendered_zig_source_z = try allocator.dupeZ(u8, rendered_zig_source);
    defer allocator.free(rendered_zig_source);

    return ParseResult{
        .zig_ast = ast,
        .zx_source = zig_source,
        .zig_source = rendered_zig_source_z,
    };
}

const std = @import("std");
const Transpiler = @import("Transpiler_prototype.zig");
