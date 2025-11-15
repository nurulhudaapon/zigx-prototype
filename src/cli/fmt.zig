const std = @import("std");
const zli = @import("zli");
const util = @import("fmt/util.zig");

const stdio_flag = zli.Flag{
    .name = "stdio",
    .description = "Read from stdin and write formatted output to stdout",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

const stdout_flag = zli.Flag{
    .name = "stdout",
    .description = "Write formatted output to stdout instead of disk",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "fmt",
        .description = "Format a .zx file or directory.",
    }, fmt);

    try cmd.addFlag(stdio_flag);
    try cmd.addFlag(stdout_flag);
    try cmd.addPositionalArg(.{
        .name = "path",
        .description = "Path to .zx file or directory",
        .required = false,
    });
    return cmd;
}

fn fmt(ctx: zli.CommandContext) !void {
    const use_stdio = ctx.flag("stdio", bool);
    const use_stdout = ctx.flag("stdout", bool);
    const path = ctx.getArg("path");

    if (use_stdio) {
        try formatFromStdin(ctx.allocator, ctx.writer);
        return;
    }

    const path_value = path orelse {
        try ctx.writer.print("Missing path arg\n", .{});
        return;
    };

    // Try to format as file first
    formatFile(
        ctx.allocator,
        ctx.writer,
        std.fs.cwd(),
        path_value,
        path_value,
        use_stdout,
    ) catch |err| switch (err) {
        error.IsDir, error.AccessDenied => {
            // It's a directory, format it
            try formatDir(
                ctx.allocator,
                ctx.writer,
                path_value,
                use_stdout,
            );
        },
        else => {
            std.debug.print("Error: Could not access path '{s}': {}\n", .{ path_value, err });
            return err;
        },
    };
}

fn formatFromStdin(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var reader = std.fs.File.stdin().reader(&.{});
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    _ = try reader.interface.streamRemaining(&buffer.writer);
    const input = try buffer.toOwnedSliceSentinel(0);
    defer allocator.free(input);

    var format_result = try util.format(allocator, input);
    defer format_result.deinit(allocator);

    try writer.writeAll(format_result.formatted_zx);
}

fn formatFile(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    base_dir: std.fs.Dir,
    sub_path: []const u8,
    full_path: []const u8,
    use_stdout: bool,
) !void {
    if (!std.mem.endsWith(u8, sub_path, ".zx")) {
        return; // Skip non-.zx files
    }

    const source = try base_dir.readFileAlloc(
        allocator,
        sub_path,
        std.math.maxInt(usize),
    );
    defer allocator.free(source);

    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    var format_result = try util.format(allocator, source_z);
    defer format_result.deinit(allocator);

    if (use_stdout) {
        try writer.writeAll(format_result.formatted_zx);
        return;
    }

    // Skip writing if content unchanged
    if (std.mem.eql(u8, format_result.formatted_zx, source)) {
        return;
    }

    // Write formatted content back to file
    var atomic_file = try base_dir.atomicFile(sub_path, .{ .write_buffer = &.{} });
    defer atomic_file.deinit();

    try atomic_file.file_writer.interface.writeAll(format_result.formatted_zx);
    try atomic_file.finish();
    try writer.print("{s}\n", .{full_path});
}

fn formatDir(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    path: []const u8,
    use_stdout: bool,
) !void {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        formatFile(
            allocator,
            writer,
            entry.dir,
            entry.basename,
            entry.path,
            use_stdout,
        ) catch |err| {
            std.debug.print("Error formatting {s}: {}\n", .{ entry.path, err });
            continue;
        };
    }
}
