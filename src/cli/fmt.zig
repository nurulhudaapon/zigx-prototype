const std = @import("std");
const zli = @import("zli");
const util = @import("fmt/util.zig");
const log = std.log.scoped(.fmt);

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

    // Check if path is a directory first
    if (std.fs.cwd().openDir(path_value, .{ .iterate = true })) |dir| {
        var dir_mut = dir;
        dir_mut.close();
        // It's a directory, format it
        try formatDir(
            ctx.allocator,
            ctx.writer,
            path_value,
            use_stdout,
        );
    } else |_| {
        // It's a file, format it
        try formatFile(
            ctx.allocator,
            ctx.writer,
            std.fs.cwd(),
            path_value,
            path_value,
            use_stdout,
        );
    }
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

        // Check if file ends with .zx before processing
        if (!std.mem.endsWith(u8, entry.path, ".zx")) continue;

        // Construct full path relative to current working directory
        // Normalize path by removing leading ./ if present
        const normalized_path = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
        const full_path = try std.fs.path.join(allocator, &.{ normalized_path, entry.path });
        defer allocator.free(full_path);

        // Read file using entry.dir (which is the directory containing the file)
        const source = try entry.dir.readFileAlloc(
            allocator,
            entry.basename,
            std.math.maxInt(usize),
        );
        defer allocator.free(source);

        const source_z = try allocator.dupeZ(u8, source);
        defer allocator.free(source_z);

        var format_result = util.format(allocator, source_z) catch |err| switch (err) {
            error.ParseError => {
                log.err("Error formatting {s}: {}\n", .{ full_path, err });
                continue;
            },
            else => return err,
        };
        defer format_result.deinit(allocator);

        if (use_stdout) {
            try writer.writeAll(format_result.formatted_zx);
            continue;
        }

        // Skip writing if content unchanged
        if (std.mem.eql(u8, format_result.formatted_zx, source)) {
            continue;
        }

        // Write formatted content back to file using entry.dir
        var atomic_file = try entry.dir.atomicFile(entry.basename, .{ .write_buffer = &.{} });
        defer atomic_file.deinit();

        try atomic_file.file_writer.interface.writeAll(format_result.formatted_zx);
        try atomic_file.finish();
        try writer.print("{s}\n", .{full_path});
    }
}
