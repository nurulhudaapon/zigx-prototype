const std = @import("std");
const zli = @import("zli");
const transformjs_lib = @import("shared/js.zig");
const log = std.log.scoped(.cli);

const stdio_flag = zli.Flag{
    .name = "stdio",
    .description = "Read from stdin and write transformed output to stdout",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

const stdout_flag = zli.Flag{
    .name = "stdout",
    .description = "Write transformed output to stdout instead of disk",
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

const file_path_flag = zli.Flag{
    .name = "file-path",
    .description = "File path for source type detection (e.g., 'input.tsx')",
    .type = .String,
    .default_value = .{ .String = "" },
};

pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "transformjs",
        .description = "Transform JavaScript/TypeScript files using TransformJS.",
    }, transformjs);

    try cmd.addFlag(stdio_flag);
    try cmd.addFlag(stdout_flag);
    try cmd.addFlag(file_path_flag);
    try cmd.addPositionalArg(.{
        .name = "path",
        .description = "Path to .js, .ts, .jsx, or .tsx file or directory",
        .required = false,
    });
    return cmd;
}

fn transformjs(ctx: zli.CommandContext) !void {
    const use_stdio = ctx.flag("stdio", bool);
    const use_stdout = ctx.flag("stdout", bool);
    const file_path_str = ctx.flag("file-path", []const u8);
    const file_path = if (file_path_str.len > 0) file_path_str else null;
    const path = ctx.getArg("path");

    if (use_stdio) {
        try transformFromStdin(ctx.allocator, ctx.writer, file_path);
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
        // It's a directory, transform it
        try transformDir(
            ctx.allocator,
            ctx.writer,
            path_value,
            use_stdout,
        );
    } else |_| {
        // It's a file, transform it
        try transformFile(
            ctx.allocator,
            ctx.writer,
            std.fs.cwd(),
            path_value,
            path_value,
            use_stdout,
            file_path,
        );
    }
}

fn transformFromStdin(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    file_path: ?[]const u8,
) !void {
    var reader = std.fs.File.stdin().reader(&.{});
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    _ = try reader.interface.streamRemaining(&buffer.writer);
    const input = try buffer.toOwnedSliceSentinel(0);
    defer allocator.free(input);

    var result = transformjs_lib.transform(allocator, input, file_path, null) catch |err| {
        try writer.print("Error transforming: {}\n", .{err});
        return;
    };
    defer result.deinit(allocator);

    try writer.writeAll(result.output);
}

fn transformFile(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    base_dir: std.fs.Dir,
    sub_path: []const u8,
    full_path: []const u8,
    use_stdout: bool,
    file_path_override: ?[]const u8,
) !void {
    // Check if file has a supported extension
    const ext = std.fs.path.extension(sub_path);
    const supported_exts = [_][]const u8{ ".js", ".ts", ".jsx", ".tsx", ".mjs", ".cjs" };
    var is_supported = false;
    for (supported_exts) |supported_ext| {
        if (std.mem.eql(u8, ext, supported_ext)) {
            is_supported = true;
            break;
        }
    }
    if (!is_supported) {
        return; // Skip unsupported files
    }

    const source = try base_dir.readFileAlloc(
        allocator,
        sub_path,
        std.math.maxInt(usize),
    );
    defer allocator.free(source);

    const file_path_to_use = file_path_override orelse sub_path;

    var result = transformjs_lib.transform(allocator, source, file_path_to_use, null) catch |err| {
        log.err("Error transforming {s}: {}\n", .{ full_path, err });
        return;
    };
    defer result.deinit(allocator);

    if (use_stdout) {
        try writer.writeAll(result.output);
        return;
    }

    // Skip writing if content unchanged
    if (std.mem.eql(u8, result.output, source)) {
        return;
    }

    // Write transformed content back to file
    var atomic_file = try base_dir.atomicFile(sub_path, .{ .write_buffer = &.{} });
    defer atomic_file.deinit();

    try atomic_file.file_writer.interface.writeAll(result.output);
    try atomic_file.finish();
    try writer.print("{s}\n", .{full_path});
}

fn transformDir(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    path: []const u8,
    use_stdout: bool,
) !void {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    const supported_exts = [_][]const u8{ ".js", ".ts", ".jsx", ".tsx", ".mjs", ".cjs" };

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        // Check if file has a supported extension
        var is_supported = false;
        for (supported_exts) |ext| {
            if (std.mem.endsWith(u8, entry.path, ext)) {
                is_supported = true;
                break;
            }
        }
        if (!is_supported) continue;

        // Construct full path relative to current working directory
        const normalized_path = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
        const full_path = try std.fs.path.join(allocator, &.{ normalized_path, entry.path });
        defer allocator.free(full_path);

        // Read file using entry.dir
        const source = try entry.dir.readFileAlloc(
            allocator,
            entry.basename,
            std.math.maxInt(usize),
        );
        defer allocator.free(source);

        var result = transformjs_lib.transform(allocator, source, full_path, null) catch |err| {
            log.err("Error transforming {s}: {}\n", .{ full_path, err });
            continue;
        };
        defer result.deinit(allocator);

        if (use_stdout) {
            try writer.writeAll(result.output);
            continue;
        }

        // Skip writing if content unchanged
        if (std.mem.eql(u8, result.output, source)) {
            continue;
        }

        // Write transformed content back to file using entry.dir
        var atomic_file = try entry.dir.atomicFile(entry.basename, .{ .write_buffer = &.{} });
        defer atomic_file.deinit();

        try atomic_file.file_writer.interface.writeAll(result.output);
        try atomic_file.finish();
        try writer.print("{s}\n", .{full_path});
    }
}
