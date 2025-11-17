const outdir_flag = zli.Flag{
    .name = "outdir",
    .shortcut = "o",
    .description = "Output directory",
    .type = .String,
    .default_value = .{ .String = ".zx" },
};

pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "transpile",
        .description = "Transpile a .zx file or directory to zig source code.",
    }, transpile);

    try cmd.addFlag(outdir_flag);
    try cmd.addPositionalArg(.{
        .name = "path",
        .description = "Path to .zx file or directory",
        .required = true,
    });
    return cmd;
}

fn transpile(ctx: zli.CommandContext) !void {
    const outdir = ctx.flag("outdir", []const u8); // type-safe flag access
    const copy_dirs = [_][]const u8{ "assets", "public" };

    const path = ctx.getArg("path") orelse {
        try ctx.writer.print("Missing path arg\n", .{});
        return;
    };

    // Check if path is a file and outdir is default
    const default_outdir = ".zx";
    const is_default_outdir = std.mem.eql(u8, outdir, default_outdir);

    // Check if path is a file (not a directory)
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.IsDir => {
            // It's a directory, proceed with normal transpileCommand
            try transpileCommand(ctx.allocator, path, outdir, false, &copy_dirs, false);
            return;
        },
        else => {
            std.debug.print("Error: Could not access path '{s}': {}\n", .{ path, err });
            return err;
        },
    };

    // Path is a file
    if (stat.kind == .file) {
        const is_zx = std.mem.endsWith(u8, path, ".zx");
        const is_zig = std.mem.endsWith(u8, path, ".zig");

        if (is_zx or is_zig) {
            // If outdir is default and path is a file, output to stdout
            if (is_default_outdir) {
                // For .zig files, check if they contain zx syntax
                if (is_zig) {
                    const has_zx = try hasZXSyntax(ctx.allocator, path);
                    if (!has_zx) {
                        std.debug.print("Info: File '{s}' does not contain zx syntax, skipping\n", .{path});
                        return;
                    }
                }

                // Read the source file
                const source = try std.fs.cwd().readFileAlloc(
                    ctx.allocator,
                    path,
                    std.math.maxInt(usize),
                );
                defer ctx.allocator.free(source);

                const source_z = try ctx.allocator.dupeZ(u8, source);
                defer ctx.allocator.free(source_z);

                // Parse and transpile
                var result = try zx.Ast.parse(ctx.allocator, source_z);
                defer result.deinit(ctx.allocator);

                // Output to stdout
                try ctx.writer.writeAll(result.zig_source);
                return;
            }
        }
    }

    // Otherwise, proceed with normal transpileCommand
    try transpileCommand(ctx.allocator, path, outdir, false, &copy_dirs, false);
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

/// Check if output_dir is a subdirectory of dir_path and return the relative path if so
/// Returns null if output_dir is not a subdirectory of dir_path
fn getOutputDirRelativePath(allocator: std.mem.Allocator, dir_path: []const u8, output_dir: []const u8) !?[]const u8 {
    const sep = std.fs.path.sep_str;

    // Normalize paths by removing trailing separators
    var normalized_dir = dir_path;
    if (std.mem.endsWith(u8, dir_path, sep)) {
        normalized_dir = dir_path[0 .. dir_path.len - sep.len];
    }

    var normalized_output = output_dir;
    if (std.mem.endsWith(u8, output_dir, sep)) {
        normalized_output = output_dir[0 .. output_dir.len - sep.len];
    }

    // Check if output_dir starts with dir_path
    if (!std.mem.startsWith(u8, normalized_output, normalized_dir)) {
        return null;
    }

    // If they're equal, output_dir is not a subdirectory
    if (std.mem.eql(u8, normalized_dir, normalized_output)) {
        return null;
    }

    // Check if the next character after dir_path is a separator
    const remaining = normalized_output[normalized_dir.len..];
    if (remaining.len == 0) {
        return null;
    }

    if (!std.mem.startsWith(u8, remaining, sep)) {
        return null;
    }

    // Return the relative path (without leading separator)
    const relative_path = remaining[sep.len..];
    if (relative_path.len == 0) {
        return null;
    }

    return try allocator.dupe(u8, relative_path);
}

/// Check if a .zig file contains zx syntax (JSX-like patterns)
fn hasZXSyntax(allocator: std.mem.Allocator, file_path: []const u8) !bool {
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
/// Represents a route in the application
const Route = struct {
    path: []const u8,
    page_import: ?[]const u8,
    layout_import: ?[]const u8,
    children: std.array_list.Managed(Route),

    fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.page_import) |import| allocator.free(import);
        if (self.layout_import) |import| allocator.free(import);
        for (self.children.items) |*child| {
            child.deinit(allocator);
        }
        self.children.deinit();
    }
};

fn generateClientComponentJson(allocator: std.mem.Allocator, components: []const zx.Ast.ClientComponentMetadata, output_dir: []const u8) !void {
    const json_str = std.json.Stringify.valueAlloc(allocator, components, .{
        .whitespace = .indent_4,
    }) catch @panic("OOM");
    defer allocator.free(json_str);

    const client_component_json_path = try std.fs.path.join(allocator, &.{ output_dir, "public", "components.json" });
    defer allocator.free(client_component_json_path);

    // Ensure the public directory exists
    const public_dir = try std.fs.path.join(allocator, &.{ output_dir, "public" });
    defer allocator.free(public_dir);
    std.fs.cwd().makePath(public_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try std.fs.cwd().writeFile(.{
        .sub_path = client_component_json_path,
        .data = json_str,
    });
}

fn generateFiles(allocator: std.mem.Allocator, output_dir: []const u8, verbose: bool) !void {
    const pages_dir = try std.fs.path.join(allocator, &.{ output_dir, "pages" });
    defer allocator.free(pages_dir);

    // Check if pages directory exists
    std.fs.cwd().access(pages_dir, .{}) catch |err| {
        if (verbose) {
            std.debug.print("No pages directory found at {s}, skipping meta.zig generation\n", .{pages_dir});
        }
        return err;
    };

    if (verbose) {
        std.debug.print("Generating meta.zig from pages directory: {s}\n", .{pages_dir});
    }

    var routes = try scanPagesDirectory(allocator, pages_dir, "pages");
    defer {
        for (routes.items) |*route| {
            route.deinit(allocator);
        }
        routes.deinit();
    }

    // Generate meta.zig content
    var content = std.array_list.Managed(u8).init(allocator);
    defer content.deinit();
    const writer = content.writer();

    // Write routes array
    try writer.writeAll("pub const routes = [_]zx.App.Meta.Route{\n");
    for (routes.items) |route| {
        try writeRoute(writer, route, 1);
    }
    try writer.writeAll("};\n\n");

    // Write meta struct
    try writer.writeAll("pub const meta = zx.App.Meta{\n");
    try writer.writeAll("    .routes = &routes,\n");
    try writer.writeAll("};\n\n");
    try writer.writeAll("const zx = @import(\"zx\");\n");

    // Write the meta.zig file
    const meta_path = try std.fs.path.join(allocator, &.{ output_dir, "meta.zig" });
    defer allocator.free(meta_path);

    // Parse and render the meta.zig to get auto fmt
    const content_z = try allocator.dupeZ(u8, content.items);
    defer allocator.free(content_z);
    var ast = try std.zig.Ast.parse(allocator, content_z, .zig);
    defer ast.deinit(allocator);

    if (ast.errors.len > 0) {
        return error.ParseError;
    }

    const rendered_zig_source = try ast.renderAlloc(allocator);
    defer allocator.free(rendered_zig_source);

    try std.fs.cwd().writeFile(.{
        .sub_path = meta_path,
        .data = rendered_zig_source,
    });

    var aa = std.heap.ArenaAllocator.init(allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    const main_zig_path = try std.fs.path.join(arena, &.{ output_dir, "main.zig" });
    const main_export_file_content = @embedFile("./transpile/main_export.zig");

    try std.fs.cwd().writeFile(.{
        .sub_path = main_zig_path,
        .data = main_export_file_content,
    });

    if (verbose) {
        std.debug.print("Generated meta.zig at: {s}\n", .{meta_path});
        std.debug.print("Generated main.zig at: {s}\n", .{main_zig_path});
    }
}

/// Recursively write a route to the writer
fn writeRoute(writer: anytype, route: Route, indent_level: usize) !void {
    const indent = "    ";

    try writer.print("{s}.{{\n", .{indent});
    try writer.print("{s}    .path = \"{s}\",\n", .{ indent, route.path });

    if (route.page_import) |page| {
        try writer.print("{s}    .page = @import(\"{s}\").Page,\n", .{ indent, page });
    }

    if (route.layout_import) |layout| {
        try writer.print("{s}    .layout = @import(\"{s}\").Layout,\n", .{ indent, layout });
    }

    if (route.children.items.len > 0) {
        try writer.print("{s}    .routes = &.{{\n", .{indent});
        for (route.children.items) |child| {
            try writeRoute(writer, child, indent_level + 2);
        }
        try writer.print("{s}    }},\n", .{indent});
    }

    try writer.print("{s}}},\n", .{indent});
}

/// Scan pages directory and build route structure
fn scanPagesDirectory(
    allocator: std.mem.Allocator,
    pages_dir: []const u8,
    import_prefix: []const u8,
) !std.array_list.Managed(Route) {
    var routes = std.array_list.Managed(Route).init(allocator);
    errdefer {
        for (routes.items) |*route| {
            route.deinit(allocator);
        }
        routes.deinit();
    }

    // Check for root page and layout
    const root_page_path = try std.fs.path.join(allocator, &.{ pages_dir, "page.zig" });
    defer allocator.free(root_page_path);

    const root_layout_path = try std.fs.path.join(allocator, &.{ pages_dir, "layout.zig" });
    defer allocator.free(root_layout_path);

    const has_root_page = blk: {
        std.fs.cwd().access(root_page_path, .{}) catch break :blk false;
        break :blk true;
    };

    const has_root_layout = blk: {
        std.fs.cwd().access(root_layout_path, .{}) catch break :blk false;
        break :blk true;
    };

    // Only create root route if we have a page or layout
    if (has_root_page or has_root_layout) {
        var root_route = Route{
            .path = try allocator.dupe(u8, "/"),
            .page_import = if (has_root_page) try std.mem.concat(allocator, u8, &.{ import_prefix, "/page.zig" }) else null,
            .layout_import = if (has_root_layout) try std.mem.concat(allocator, u8, &.{ import_prefix, "/layout.zig" }) else null,
            .children = std.array_list.Managed(Route).init(allocator),
        };
        errdefer root_route.deinit(allocator);

        // Scan for child routes (subdirectories)
        var dir = try std.fs.cwd().openDir(pages_dir, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;

            // Skip .zx directories
            if (std.mem.eql(u8, entry.name, ".zx")) continue;

            const child_path = try std.fs.path.join(allocator, &.{ pages_dir, entry.name });
            defer allocator.free(child_path);

            const child_import_prefix = try std.mem.concat(allocator, u8, &.{ import_prefix, "/", entry.name });
            defer allocator.free(child_import_prefix);

            if (try scanRoute(allocator, child_path, child_import_prefix, entry.name)) |child_route| {
                try root_route.children.append(child_route);
            }
        }

        try routes.append(root_route);
    }

    return routes;
}

/// Scan a single route directory (e.g., /about)
fn scanRoute(
    allocator: std.mem.Allocator,
    route_dir: []const u8,
    import_prefix: []const u8,
    route_name: []const u8,
) !?Route {
    const page_path = try std.fs.path.join(allocator, &.{ route_dir, "page.zig" });
    defer allocator.free(page_path);

    const layout_path = try std.fs.path.join(allocator, &.{ route_dir, "layout.zig" });
    defer allocator.free(layout_path);

    const has_page = blk: {
        std.fs.cwd().access(page_path, .{}) catch break :blk false;
        break :blk true;
    };

    const has_layout = blk: {
        std.fs.cwd().access(layout_path, .{}) catch break :blk false;
        break :blk true;
    };

    // Only create route if we have a page
    if (!has_page) return null;

    const route_path = try std.mem.concat(allocator, u8, &.{ "/", route_name });
    errdefer allocator.free(route_path);

    const page_import = try std.mem.concat(allocator, u8, &.{ import_prefix, "/page.zig" });
    errdefer allocator.free(page_import);

    const layout_import = if (has_layout) try std.mem.concat(allocator, u8, &.{ import_prefix, "/layout.zig" }) else null;
    errdefer if (layout_import) |import| allocator.free(import);

    const route = Route{
        .path = route_path,
        .page_import = page_import,
        .layout_import = layout_import,
        .children = std.array_list.Managed(Route).init(allocator),
    };

    return route;
}

fn copySpecifiedDirectories(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_dir: []const u8,
    copy_dirs: []const []const u8,
    verbose: bool,
) !void {
    // Determine the base directory to check for directories
    const base_dir = if (std.fs.path.dirname(input_path)) |dir| dir else input_path;

    // Copy each specified directory if it exists
    for (copy_dirs) |dir_name| {
        const src_path = try std.fs.path.join(allocator, &.{ base_dir, dir_name });
        defer allocator.free(src_path);

        const dest_path = try std.fs.path.join(allocator, &.{ output_dir, dir_name });
        defer allocator.free(dest_path);

        if (std.fs.cwd().openDir(src_path, .{})) |dir_result| {
            var dir = dir_result;
            defer dir.close();
            // Directory exists, copy it
            if (verbose) {
                std.debug.print("Copying '{s}' directory: {s} -> {s}\n", .{ dir_name, src_path, dest_path });
            }
            copyDirectory(allocator, src_path, dest_path) catch |copy_err| {
                std.debug.print("Warning: Failed to copy '{s}' directory: {}\n", .{ dir_name, copy_err });
            };
        } else |err| switch (err) {
            error.FileNotFound => {
                // Silently skip if directory doesn't exist
            },
            error.NotDir => {},
            else => {
                std.debug.print("Warning: Failed to check '{s}' directory: {}\n", .{ dir_name, err });
            },
        }
    }
}

fn transpileFile(allocator: std.mem.Allocator, source_path: []const u8, output_path: []const u8, global_components: *std.array_list.Managed(zx.Ast.ClientComponentMetadata), verbose: bool) !void {
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

    // Append components from this file to the global list
    for (result.client_components.items) |component| {
        // Clone the component metadata to add to global list
        const cloned_name = try allocator.dupe(u8, component.name);
        const cloned_path = try allocator.dupe(u8, component.path);
        const cloned_id = try allocator.dupe(u8, component.id);

        try global_components.append(.{
            .name = cloned_name,
            .path = cloned_path,
            .id = cloned_id,
        });
    }

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

    if (verbose) {
        std.debug.print("Transpiled: {s} -> {s}\n", .{ source_path, output_path });
    }
}

fn transpileDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    output_dir: []const u8,
    include_zig: bool,
    copy_dirs: []const []const u8,
    global_components: *std.array_list.Managed(zx.Ast.ClientComponentMetadata),
    verbose: bool,
) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    // Check if output_dir is a subdirectory of dir_path
    const output_dir_relative = try getOutputDirRelativePath(allocator, dir_path, output_dir);
    defer if (output_dir_relative) |rel| allocator.free(rel);

    // Check if dir_path itself is or contains "pages"
    const sep = std.fs.path.sep_str;
    const dir_is_pages = std.mem.endsWith(u8, dir_path, sep ++ "pages") or
        std.mem.eql(u8, getBasename(dir_path), "pages") or
        std.mem.endsWith(u8, dir_path, "pages");

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        // Skip files in output directory if output_dir is a subdirectory of dir_path
        if (output_dir_relative) |rel| {
            // Check if entry.path starts with rel followed by separator, or is exactly rel
            if (std.mem.startsWith(u8, entry.path, rel)) {
                // Check if it's exactly rel or followed by separator
                if (entry.path.len == rel.len) {
                    continue;
                }
                if (std.mem.startsWith(u8, entry.path[rel.len..], sep)) {
                    continue;
                }
            }
        }

        const is_zx = std.mem.endsWith(u8, entry.path, ".zx");
        const is_zig = std.mem.endsWith(u8, entry.path, ".zig");

        // Check if this entry is within a "pages" directory
        // entry.path is relative to dir_path, so check if it contains "pages" in its path
        // or if dir_path itself is a pages directory
        const is_in_pages_dir = dir_is_pages or
            std.mem.startsWith(u8, entry.path, "pages" ++ sep) or
            std.mem.indexOf(u8, entry.path, sep ++ "pages" ++ sep) != null;

        // Build input path
        const input_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(input_path);

        // Check if this file should be transpiled
        var should_transpile = false;
        var should_copy = false;

        if (is_zx) {
            should_transpile = true;
        } else if (is_zig and include_zig) {
            const has_zx = hasZXSyntax(allocator, input_path) catch false;
            if (has_zx) {
                should_transpile = true;
            } else if (is_in_pages_dir) {
                // In pages directory, copy .zig files that don't have zx syntax
                should_copy = true;
            }
        } else if (is_in_pages_dir) {
            // In pages directory, copy all other files
            should_copy = true;
        }

        // Skip files that don't match our criteria
        if (!should_transpile and !should_copy) continue;

        // Build output path
        const relative_path = entry.path;
        var output_rel_path: []const u8 = undefined;

        if (should_transpile) {
            if (is_zx) {
                // Remove .zx and add .zig
                output_rel_path = try std.mem.concat(allocator, u8, &.{
                    relative_path[0 .. relative_path.len - (".zx").len], // Remove .zx
                    ".zig",
                });
            } else {
                // For .zig files, keep the same name
                output_rel_path = try allocator.dupe(u8, relative_path);
            }
        } else {
            // For copying, keep the same name
            output_rel_path = try allocator.dupe(u8, relative_path);
        }
        defer allocator.free(output_rel_path);

        const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel_path });
        defer allocator.free(output_path);

        if (should_transpile) {
            transpileFile(allocator, input_path, output_path, global_components, verbose) catch |err| {
                std.debug.print("Error transpiling {s}: {}\n", .{ input_path, err });
                continue;
            };
        } else {
            // Copy file as-is
            // Create parent directory if needed
            if (std.fs.path.dirname(output_path)) |parent| {
                std.fs.cwd().makePath(parent) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => {
                        std.debug.print("Error creating directory {s}: {}\n", .{ parent, err });
                        continue;
                    },
                };
            }

            try std.fs.cwd().copyFile(input_path, std.fs.cwd(), output_path, .{});
            if (verbose) {
                std.debug.print("Copied: {s} -> {s}\n", .{ input_path, output_path });
            }
        }
    }

    // Copy specified directories after transpiling all files
    copySpecifiedDirectories(allocator, dir_path, output_dir, copy_dirs, verbose) catch |err| {
        std.debug.print("Warning: Failed to copy specified directories: {}\n", .{err});
    };
}

fn transpileCommand(
    allocator: std.mem.Allocator,
    path: []const u8,
    output_dir: []const u8,
    include_zig: bool,
    copy_dirs: []const []const u8,
    verbose: bool,
) !void {
    // Initialize global component metadata list
    var global_components = std.array_list.Managed(zx.Ast.ClientComponentMetadata).init(allocator);
    defer {
        for (global_components.items) |*component| {
            allocator.free(component.name);
            allocator.free(component.path);
            allocator.free(component.id);
        }
        global_components.deinit();
    }

    // Check if path is a file or directory
    const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.IsDir => std.fs.File.Stat{ .kind = .directory, .size = 0, .mode = 0, .atime = 0, .mtime = 0, .ctime = 0, .inode = 0 },
        else => {
            std.debug.print("Error: Could not access path '{s}': {}\n", .{ path, err });
            return err;
        },
    };

    if (stat.kind == .directory) {
        if (verbose) {
            std.debug.print("Transpiling directory: {s}\n", .{path});
        }
        try transpileDirectory(allocator, path, output_dir, include_zig, copy_dirs, &global_components, verbose);

        // Generate meta.zig after transpiling directory
        generateFiles(allocator, output_dir, verbose) catch |err| {
            std.debug.print("Warning: Failed to generate meta.zig: {}\n", .{err});
        };
    } else if (stat.kind == .file) {
        const is_zx = std.mem.endsWith(u8, path, ".zx");
        const is_zig = std.mem.endsWith(u8, path, ".zig");

        if (!is_zx and !(include_zig and is_zig)) {
            std.debug.print("Error: File must have .zx extension, or use --zig flag for .zig files\n", .{});
            return error.InvalidFileExtension;
        }

        // For .zig files with --zig flag, check if they contain zx syntax
        if (is_zig and include_zig) {
            const has_zx = try hasZXSyntax(allocator, path);
            if (!has_zx) {
                std.debug.print("Info: File '{s}' does not contain zx syntax, skipping\n", .{path});
                return;
            }
        }

        // Get just the filename (basename)
        const basename = getBasename(path);

        // Build output path
        var output_rel_path: []const u8 = undefined;
        defer allocator.free(output_rel_path);

        if (is_zx) {
            // Remove .zx and add .zig
            output_rel_path = try std.mem.concat(allocator, u8, &.{
                basename[0 .. basename.len - (".zx").len], // Remove .zx
                ".zig",
            });
        } else {
            // For .zig files, keep the same name
            output_rel_path = try allocator.dupe(u8, basename);
        }

        const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel_path });
        defer allocator.free(output_path);

        try transpileFile(allocator, path, output_path, &global_components, verbose);

        // Copy specified directories after transpiling the file
        copySpecifiedDirectories(allocator, path, output_dir, copy_dirs, verbose) catch |err| {
            std.debug.print("Warning: Failed to copy specified directories: {}\n", .{err});
        };

        // Generate meta.zig if pages directory exists
        generateFiles(allocator, output_dir, verbose) catch |err| {
            std.debug.print("Warning: Failed to generate meta.zig: {}\n", .{err});
        };

        if (verbose) {
            std.debug.print("Done!\n", .{});
        }
    } else {
        std.debug.print("Error: Path must be a file or directory\n", .{});
        return error.InvalidPath;
    }

    // Write the single components.json file after all files are transpiled
    if (global_components.items.len > 0) {
        generateClientComponentJson(allocator, global_components.items, output_dir) catch |err| {
            std.debug.print("Warning: Failed to generate components.json: {}\n", .{err});
        };
    }
}

const std = @import("std");
const zli = @import("zli");
const zx = @import("zx");
