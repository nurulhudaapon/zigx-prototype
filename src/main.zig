pub fn main() !void {
    var dbg = std.heap.DebugAllocator(.{}).init;

    const allocator = switch (@import("builtin").mode) {
        .Debug => dbg.allocator(),
        .ReleaseFast, .ReleaseSafe, .ReleaseSmall => std.heap.smp_allocator,
    };

    defer if (@import("builtin").mode == .Debug) std.debug.assert(dbg.deinit() == .ok);

    var stdout_writer = fs.File.stdout().writerStreaming(&.{});
    var stdout = &stdout_writer.interface;

    var buf: [4096]u8 = undefined;
    var stdin_reader = fs.File.stdin().readerStreaming(&buf);
    const stdin = &stdin_reader.interface;

    const root = try cli.build(stdout, stdin, allocator);
    defer root.deinit();

    try root.execute(.{});

    try stdout.flush();
}

const std = @import("std");
const fs = std.fs;
const cli = @import("cli/root.zig");

pub const std_options = std.Options{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .@"html/ast", .level = .info },
        .{ .scope = .@"html/tokenizer", .level = .info },
        .{ .scope = .@"html/ast/fmt", .level = .info },
    },
};
