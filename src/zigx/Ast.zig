pub const ParseResult = struct {
    zig_ast: std.zig.Ast,
    zigx_source: [:0]const u8,
    zig_source: [:0]const u8,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        self.zig_ast.deinit(allocator);
        allocator.free(self.zigx_source);
    }
};

pub fn parse(allocator: std.mem.Allocator, zigx_source: [:0]const u8) !ParseResult {
    const zig_source = try Transpiler.transpile(allocator, zigx_source);
    errdefer allocator.free(zig_source);

    const ast = try std.zig.Ast.parse(allocator, zig_source, .zig);

    return ParseResult{
        .zig_ast = ast,
        .zigx_source = zig_source,
        .zig_source = zig_source,
    };
}

const std = @import("std");
const Transpiler = @import("Transpiler_prototype.zig");
