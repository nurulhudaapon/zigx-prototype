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
    
    // Post-process to comment out @jsImport declarations
    const processed_zig_source = try commentOutJsImports(arena, zig_source);
    defer arena.free(processed_zig_source);

    var ast = try std.zig.Ast.parse(gpa, processed_zig_source, .zig);

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

/// Post-process Zig source to comment out @jsImport declarations
fn commentOutJsImports(allocator: std.mem.Allocator, source: [:0]const u8) ![:0]const u8 {
    var result = std.ArrayList(u8){};
    try result.ensureTotalCapacity(allocator, source.len + 100); // Extra space for comment markers
    errdefer result.deinit(allocator);
    defer result.deinit(allocator);
    
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first_line = true;
    
    while (lines.next()) |line| {
        if (!first_line) {
            try result.append(allocator, '\n');
        }
        first_line = false;
        
        // Check if line contains @jsImport
        if (std.mem.indexOf(u8, line, "@jsImport") != null) {
            // Comment out the line
            try result.appendSlice(allocator, "// ");
            try result.appendSlice(allocator, line);
        } else {
            // Keep the line as-is
            try result.appendSlice(allocator, line);
        }
    }
    
    return try allocator.dupeZ(u8, result.items);
}
