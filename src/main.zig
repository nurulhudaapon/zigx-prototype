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

/// Check if a .zig file contains zigx syntax (JSX-like patterns)
fn hasZigxSyntax(allocator: std.mem.Allocator, file_path: []const u8) !bool {
    const source = std.fs.cwd().readFileAlloc(
        allocator,
        file_path,
        std.math.maxInt(usize),
    ) catch return false;
    defer allocator.free(source);

    // Look for patterns like "return (" followed by JSX-like syntax (<tag>)
    var i: usize = 0;
    while (i < source.len) {
        // Look for "return"
        if (i + 6 <= source.len and std.mem.eql(u8, source[i .. i + 6], "return")) {
            var j = i + 6;
            // Skip whitespace after "return"
            while (j < source.len and std.ascii.isWhitespace(source[j])) {
                j += 1;
            }
            // Check if next is '('
            if (j < source.len and source[j] == '(') {
                j += 1;
                // Skip whitespace after '('
                while (j < source.len and std.ascii.isWhitespace(source[j])) {
                    j += 1;
                }
                // Look for JSX opening tag (<)
                if (j < source.len and source[j] == '<') {
                    // Make sure it's not a comparison operator
                    // Check if it's followed by an identifier character or /
                    if (j + 1 < source.len) {
                        const next_char = source[j + 1];
                        if (std.ascii.isAlphabetic(next_char) or next_char == '/') {
                            return true;
                        }
                    }
                }
            }
        }
        i += 1;
    }
    return false;
}

/// Copy a directory recursively from source to destination
fn copyDirectory(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    dest_dir: []const u8,
) !void {
    var source = try std.fs.cwd().openDir(source_dir, .{ .iterate = true });
    defer source.close();

    // Create destination directory if it doesn't exist
    std.fs.cwd().makePath(dest_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dest = try std.fs.cwd().openDir(dest_dir, .{});
    defer dest.close();

    var walker = try source.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const src_path = try std.fs.path.join(allocator, &.{ source_dir, entry.path });
        defer allocator.free(src_path);

        const dst_path = try std.fs.path.join(allocator, &.{ dest_dir, entry.path });
        defer allocator.free(dst_path);

        switch (entry.kind) {
            .file => {
                // Create parent directory if needed
                if (std.fs.path.dirname(dst_path)) |parent| {
                    std.fs.cwd().makePath(parent) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                }

                // Copy file
                try std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{});
            },
            .directory => {
                // Create directory if needed
                std.fs.cwd().makePath(dst_path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            },
            else => continue,
        }
    }
}

/// Copy asset directories (assets and public) if they exist in the input path
fn copyAssetDirectories(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_dir: []const u8,
) !void {
    // Determine the base directory to check for assets
    const base_dir = if (std.fs.path.dirname(input_path)) |dir| dir else input_path;

    // Check for 'assets' directory
    const assets_src = try std.fs.path.join(allocator, &.{ base_dir, "assets" });
    defer allocator.free(assets_src);

    const assets_dest = try std.fs.path.join(allocator, &.{ output_dir, "assets" });
    defer allocator.free(assets_dest);

    if (std.fs.cwd().openDir(assets_src, .{})) |dir_result| {
        var dir = dir_result;
        defer dir.close();
        // Directory exists, copy it
        std.debug.print("Copying assets directory: {s} -> {s}\n", .{ assets_src, assets_dest });
        copyDirectory(allocator, assets_src, assets_dest) catch |copy_err| {
            std.debug.print("Warning: Failed to copy assets directory: {}\n", .{copy_err});
        };
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.NotDir => {},
        else => {
            std.debug.print("Warning: Failed to check assets directory: {}\n", .{err});
        },
    }

    // Check for 'public' directory
    const public_src = try std.fs.path.join(allocator, &.{ base_dir, "public" });
    defer allocator.free(public_src);

    const public_dest = try std.fs.path.join(allocator, &.{ output_dir, "public" });
    defer allocator.free(public_dest);

    if (std.fs.cwd().openDir(public_src, .{})) |dir_result| {
        var dir = dir_result;
        defer dir.close();
        // Directory exists, copy it
        std.debug.print("Copying public directory: {s} -> {s}\n", .{ public_src, public_dest });
        copyDirectory(allocator, public_src, public_dest) catch |copy_err| {
            std.debug.print("Warning: Failed to copy public directory: {}\n", .{copy_err});
        };
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.NotDir => {},
        else => {
            std.debug.print("Warning: Failed to check public directory: {}\n", .{err});
        },
    }
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

fn transpileDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    output_dir: []const u8,
    include_zig: bool,
) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const is_zigx = std.mem.endsWith(u8, entry.path, ".zigx");
        const is_zig = std.mem.endsWith(u8, entry.path, ".zig");

        // Skip files that don't match our criteria
        if (!is_zigx and !(include_zig and is_zig)) continue;

        // Build input path
        const input_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(input_path);

        // For .zig files with --zig flag, check if they contain zigx syntax
        if (is_zig and include_zig) {
            const has_zigx = hasZigxSyntax(allocator, input_path) catch false;
            if (!has_zigx) {
                // Skip .zig files that don't contain zigx syntax
                continue;
            }
        }

        // Build output path
        const relative_path = entry.path;
        var output_rel_path: []const u8 = undefined;

        if (is_zigx) {
            // Remove .zigx and add .zig
            output_rel_path = try std.mem.concat(allocator, u8, &.{
                relative_path[0 .. relative_path.len - 5], // Remove .zigx
                ".zig",
            });
        } else {
            // For .zig files, keep the same name
            output_rel_path = try allocator.dupe(u8, relative_path);
        }
        defer allocator.free(output_rel_path);

        const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel_path });
        defer allocator.free(output_path);

        transpileFile(allocator, input_path, output_path) catch |err| {
            std.debug.print("Error transpiling {s}: {}\n", .{ input_path, err });
            continue;
        };
    }

    // Copy asset directories after transpiling all files
    copyAssetDirectories(allocator, dir_path, output_dir) catch |err| {
        std.debug.print("Warning: Failed to copy asset directories: {}\n", .{err});
    };
}

fn transpileCommand(
    allocator: std.mem.Allocator,
    path: []const u8,
    output_dir: []const u8,
    include_zig: bool,
) !void {
    // Check if path is a file or directory
    const stat = std.fs.cwd().statFile(path) catch |err| {
        std.debug.print("Error: Could not access path '{s}': {}\n", .{ path, err });
        return err;
    };

    if (stat.kind == .directory) {
        std.debug.print("Transpiling directory: {s}\n", .{path});
        try transpileDirectory(allocator, path, output_dir, include_zig);
        std.debug.print("Done!\n", .{});
    } else if (stat.kind == .file) {
        const is_zigx = std.mem.endsWith(u8, path, ".zigx");
        const is_zig = std.mem.endsWith(u8, path, ".zig");

        if (!is_zigx and !(include_zig and is_zig)) {
            std.debug.print("Error: File must have .zigx extension, or use --zig flag for .zig files\n", .{});
            return error.InvalidFileExtension;
        }

        // For .zig files with --zig flag, check if they contain zigx syntax
        if (is_zig and include_zig) {
            const has_zigx = try hasZigxSyntax(allocator, path);
            if (!has_zigx) {
                std.debug.print("Info: File '{s}' does not contain zigx syntax, skipping\n", .{path});
                return;
            }
        }

        // Get just the filename (basename)
        const basename = getBasename(path);

        // Build output path
        var output_rel_path: []const u8 = undefined;
        defer allocator.free(output_rel_path);

        if (is_zigx) {
            // Remove .zigx and add .zig
            output_rel_path = try std.mem.concat(allocator, u8, &.{
                basename[0 .. basename.len - 5], // Remove .zigx
                ".zig",
            });
        } else {
            // For .zig files, keep the same name
            output_rel_path = try allocator.dupe(u8, basename);
        }

        const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel_path });
        defer allocator.free(output_path);

        try transpileFile(allocator, path, output_path);

        // Copy asset directories after transpiling the file
        copyAssetDirectories(allocator, path, output_dir) catch |err| {
            std.debug.print("Warning: Failed to copy asset directories: {}\n", .{err});
        };

        std.debug.print("Done!\n", .{});
    } else {
        std.debug.print("Error: Path must be a file or directory\n", .{});
        return error.InvalidPath;
    }
}

fn runDefaultBehavior(allocator: std.mem.Allocator) !void {
    const source = @embedFile("examples/index.zig");
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
            std.debug.print("Usage: {s} transpile <path> [options]\n", .{args[0]});
            std.debug.print("  <path> can be a .zigx file or a directory\n", .{});
            std.debug.print("  Options:\n", .{});
            std.debug.print("    --output <dir>, -o <dir>  Output directory (default: .zigx/site)\n", .{});
            std.debug.print("    --zig                     Also transpile .zig files containing zigx syntax\n", .{});
            return error.MissingArgument;
        }

        // Parse arguments
        var output_dir: []const u8 = ".zigx/site";
        var include_zig: bool = false;
        var path: ?[]const u8 = null;
        var i: usize = 2;

        while (i < args.len) {
            if (std.mem.eql(u8, args[i], "--output") or std.mem.eql(u8, args[i], "-o")) {
                if (i + 1 >= args.len) {
                    std.debug.print("Error: --output requires a directory argument\n", .{});
                    return error.MissingArgument;
                }
                output_dir = args[i + 1];
                i += 2;
            } else if (std.mem.eql(u8, args[i], "--zig")) {
                include_zig = true;
                i += 1;
            } else {
                if (path != null) {
                    std.debug.print("Error: Multiple paths specified\n", .{});
                    return error.InvalidArgument;
                }
                path = args[i];
                i += 1;
            }
        }

        if (path == null) {
            std.debug.print("Usage: {s} transpile <path> [options]\n", .{args[0]});
            std.debug.print("  <path> can be a .zigx file or a directory\n", .{});
            std.debug.print("  Options:\n", .{});
            std.debug.print("    --output <dir>, -o <dir>  Output directory (default: .zigx/site)\n", .{});
            std.debug.print("    --zig                     Also transpile .zig files containing zigx syntax\n", .{});
            return error.MissingArgument;
        }

        try transpileCommand(allocator, path.?, output_dir, include_zig);
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
