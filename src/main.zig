const Page = @import("examples/index.zig").Page;

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

fn getBasename(path: []const u8) []const u8 {
    // Get the last component of the path (the final directory or filename)
    const sep = std.fs.path.sep;
    if (std.mem.lastIndexOfScalar(u8, path, sep)) |last_sep| {
        if (last_sep + 1 < path.len) {
            return path[last_sep + 1 ..];
        }
    }
    // If no separator found, return the original path
    return path;
}

fn transpileFile(allocator: std.mem.Allocator, source_path: []const u8, output_path: []const u8) !void {
    // Read the source file
    const source = try std.fs.cwd().readFileAlloc(
        allocator,
        source_path,
        std.math.maxInt(usize),
    );
    defer allocator.free(source);

    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    // Parse and transpile
    var result = try zx.Ast.parse(allocator, source_z);
    defer result.deinit(allocator);

    // Create output directory if needed
    if (std.fs.path.dirname(output_path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Write the transpiled zig source
    try std.fs.cwd().writeFile(.{
        .sub_path = output_path,
        .data = result.zig_source,
    });

    std.debug.print("Transpiled: {s} -> {s}\n", .{ source_path, output_path });
}

fn transpileDirectory(allocator: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        // Check if file has .zigx extension
        if (!std.mem.endsWith(u8, entry.path, ".zigx")) continue;

        // Build input path
        const input_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(input_path);

        // Build output path: always output to .zigx/site/<file.zig>
        const relative_path = entry.path;
        const output_rel_path = try std.mem.concat(allocator, u8, &.{
            relative_path[0 .. relative_path.len - 5], // Remove .zigx
            ".zig",
        });
        defer allocator.free(output_rel_path);

        const output_path = try std.fs.path.join(allocator, &.{ ".zigx", "site", output_rel_path });
        defer allocator.free(output_path);

        transpileFile(allocator, input_path, output_path) catch |err| {
            std.debug.print("Error transpiling {s}: {}\n", .{ input_path, err });
            continue;
        };
    }
}

fn transpileCommand(allocator: std.mem.Allocator, path: []const u8) !void {
    // Check if path is a file or directory
    const stat = std.fs.cwd().statFile(path) catch |err| {
        std.debug.print("Error: Could not access path '{s}': {}\n", .{ path, err });
        return err;
    };

    if (stat.kind == .directory) {
        std.debug.print("Transpiling directory: {s}\n", .{path});
        try transpileDirectory(allocator, path);
        std.debug.print("Done!\n", .{});
    } else if (stat.kind == .file) {
        if (!std.mem.endsWith(u8, path, ".zigx")) {
            std.debug.print("Error: File must have .zigx extension\n", .{});
            return error.InvalidFileExtension;
        }

        // Get just the filename (basename)
        const basename = getBasename(path);

        // Build output path: always output to .zigx/site/<filename.zig>
        const output_rel_path = try std.mem.concat(allocator, u8, &.{
            basename[0 .. basename.len - 5], // Remove .zigx
            ".zig",
        });
        defer allocator.free(output_rel_path);

        const output_path = try std.fs.path.join(allocator, &.{ ".zigx", "site", output_rel_path });
        defer allocator.free(output_path);

        try transpileFile(allocator, path, output_path);
        std.debug.print("Done!\n", .{});
    } else {
        std.debug.print("Error: Path must be a file or directory\n", .{});
        return error.InvalidPath;
    }
}

fn runDefaultBehavior(allocator: std.mem.Allocator) !void {
    const source = @embedFile("zigx/examples/zx_custom.zigx");
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    var result = try zx.Ast.parse(allocator, source_z);
    defer result.deinit(allocator);

    // try writeFileIfChanged("src/zigx/examples/zig/index.zig", result.zig_source);

    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();

    // Use arena allocator for component tree - frees everything at once
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const page_allocator = arena.allocator();

    const page = Page(page_allocator);
    // No need to call page.deinit() - arena frees everything

    try page.render(&aw.writer);
    std.debug.print("{s}\n", .{aw.written()});
    try writeFileIfChanged("src/zigx/examples/html/index.html", aw.written());
    aw.clearRetainingCapacity();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check if "transpile" command is given
    if (args.len >= 2 and std.mem.eql(u8, args[1], "transpile")) {
        if (args.len < 3) {
            std.debug.print("Usage: {s} transpile <path>\n", .{args[0]});
            std.debug.print("  <path> can be a .zigx file or a directory\n", .{});
            return error.MissingArgument;
        }

        try transpileCommand(allocator, args[2]);
    } else {
        // Run default behavior
        try runDefaultBehavior(allocator);
    }
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
