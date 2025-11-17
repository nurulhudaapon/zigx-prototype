const std = @import("std");
const zli = @import("zli");
const zx = @import("zx");

// ============================================================================
// Command Registration
// ============================================================================

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
    const outdir = ctx.flag("outdir", []const u8);
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
            try transpileCommand(ctx.allocator, path, outdir, &copy_dirs, false);
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

        if (is_zx) {
            // If outdir is default and path is a file, output to stdout
            if (is_default_outdir) {
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
    try transpileCommand(ctx.allocator, path, outdir, &copy_dirs, false);
}

// ============================================================================
// Path Utilities
// ============================================================================

fn getBasename(path: []const u8) []const u8 {
    const sep = std.fs.path.sep;
    if (std.mem.lastIndexOfScalar(u8, path, sep)) |last_sep| {
        if (last_sep + 1 < path.len) {
            return path[last_sep + 1 ..];
        }
    }
    return path;
}

/// Resolve a relative path against a base directory
fn resolvePath(allocator: std.mem.Allocator, base_dir: []const u8, relative_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(relative_path)) {
        return try allocator.dupe(u8, relative_path);
    }

    var base = base_dir;
    const sep = std.fs.path.sep_str;
    if (std.mem.endsWith(u8, base_dir, sep)) {
        base = base_dir[0 .. base_dir.len - sep.len];
    }

    const joined = try std.fs.path.join(allocator, &.{ base, relative_path });
    defer allocator.free(joined);

    return try std.fs.path.resolve(allocator, &.{joined});
}

/// Calculate relative path from base to target
fn relativePath(allocator: std.mem.Allocator, base: []const u8, target: []const u8) ![]const u8 {
    const sep = std.fs.path.sep_str;

    var base_normalized = base;
    var target_normalized = target;
    if (std.mem.endsWith(u8, base, sep)) {
        base_normalized = base[0 .. base.len - sep.len];
    }
    if (std.mem.endsWith(u8, target, sep)) {
        target_normalized = target[0 .. target.len - sep.len];
    }

    var base_parts = std.ArrayList([]const u8){};
    defer base_parts.deinit(allocator);
    var target_parts = std.ArrayList([]const u8){};
    defer target_parts.deinit(allocator);

    var base_iter = std.mem.splitScalar(u8, base_normalized, std.fs.path.sep);
    while (base_iter.next()) |part| {
        if (part.len > 0) {
            try base_parts.append(allocator, part);
        }
    }

    var target_iter = std.mem.splitScalar(u8, target_normalized, std.fs.path.sep);
    while (target_iter.next()) |part| {
        if (part.len > 0) {
            try target_parts.append(allocator, part);
        }
    }

    var common_len: usize = 0;
    const min_len = @min(base_parts.items.len, target_parts.items.len);
    while (common_len < min_len and std.mem.eql(u8, base_parts.items[common_len], target_parts.items[common_len])) {
        common_len += 1;
    }

    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    var i = common_len;
    while (i < base_parts.items.len) : (i += 1) {
        if (result.items.len > 0) {
            try result.appendSlice(allocator, sep);
        }
        try result.appendSlice(allocator, "..");
    }

    i = common_len;
    while (i < target_parts.items.len) : (i += 1) {
        if (result.items.len > 0) {
            try result.appendSlice(allocator, sep);
        }
        try result.appendSlice(allocator, target_parts.items[i]);
    }

    if (result.items.len == 0) {
        return try allocator.dupe(u8, ".");
    }

    return try result.toOwnedSlice(allocator);
}

/// Check if output_dir is a subdirectory of dir_path and return the relative path if so
fn getOutputDirRelativePath(allocator: std.mem.Allocator, dir_path: []const u8, output_dir: []const u8) !?[]const u8 {
    const sep = std.fs.path.sep_str;

    var normalized_dir = dir_path;
    if (std.mem.endsWith(u8, dir_path, sep)) {
        normalized_dir = dir_path[0 .. dir_path.len - sep.len];
    }

    var normalized_output = output_dir;
    if (std.mem.endsWith(u8, output_dir, sep)) {
        normalized_output = output_dir[0 .. output_dir.len - sep.len];
    }

    if (!std.mem.startsWith(u8, normalized_output, normalized_dir)) {
        return null;
    }

    if (std.mem.eql(u8, normalized_dir, normalized_output)) {
        return null;
    }

    const remaining = normalized_output[normalized_dir.len..];
    if (remaining.len == 0) {
        return null;
    }

    if (!std.mem.startsWith(u8, remaining, sep)) {
        return null;
    }

    const relative_path = remaining[sep.len..];
    if (relative_path.len == 0) {
        return null;
    }

    return try allocator.dupe(u8, relative_path);
}

// ============================================================================
// File Operations
// ============================================================================

/// Copy a directory recursively from source to destination
fn copyDirectory(
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    dest_dir: []const u8,
) !void {
    var source = try std.fs.cwd().openDir(source_dir, .{ .iterate = true });
    defer source.close();

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
                if (std.fs.path.dirname(dst_path)) |parent| {
                    std.fs.cwd().makePath(parent) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                }
                try std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{});
            },
            .directory => {
                std.fs.cwd().makePath(dst_path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            },
            else => continue,
        }
    }
}

fn copySpecifiedDirectories(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_dir: []const u8,
    copy_dirs: []const []const u8,
    verbose: bool,
) !void {
    const base_dir = if (std.fs.path.dirname(input_path)) |dir| dir else input_path;

    for (copy_dirs) |dir_name| {
        const src_path = try std.fs.path.join(allocator, &.{ base_dir, dir_name });
        defer allocator.free(src_path);

        const dest_path = try std.fs.path.join(allocator, &.{ output_dir, dir_name });
        defer allocator.free(dest_path);

        if (std.fs.cwd().openDir(src_path, .{})) |dir_result| {
            var dir = dir_result;
            defer dir.close();
            if (verbose) {
                std.debug.print("Copying '{s}' directory: {s} -> {s}\n", .{ dir_name, src_path, dest_path });
            }
            copyDirectory(allocator, src_path, dest_path) catch |copy_err| {
                std.debug.print("Warning: Failed to copy '{s}' directory: {}\n", .{ dir_name, copy_err });
            };
        } else |err| switch (err) {
            error.FileNotFound => {},
            error.NotDir => {},
            else => {
                std.debug.print("Warning: Failed to check '{s}' directory: {}\n", .{ dir_name, err });
            },
        }
    }
}

// ============================================================================
// Client Component Handling
// ============================================================================

const ClientComponentJson = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
    import: []const u8,
};

fn genClientMain(allocator: std.mem.Allocator, components: []const ClientComponentJson, output_dir: []const u8) !void {
    var json_str = std.json.Stringify.valueAlloc(allocator, components, .{
        .whitespace = .indent_2,
    }) catch @panic("OOM");
    errdefer allocator.free(json_str);

    // Replace all instances of "@ and @" with empty string
    const placeHolder_start = "\"@";
    const placeHolder_end = "@\"";

    while (std.mem.indexOf(u8, json_str, placeHolder_start)) |index| {
        const old_json_str = json_str;
        const before = json_str[0..index];
        const after = json_str[index + placeHolder_start.len ..];
        json_str = try std.mem.concat(allocator, u8, &.{ before, "", after });
        allocator.free(old_json_str);
    }
    while (std.mem.indexOf(u8, json_str, placeHolder_end)) |index| {
        const old_json_str = json_str;
        const before = json_str[0..index];
        const after = json_str[index + placeHolder_end.len ..];
        json_str = try std.mem.concat(allocator, u8, &.{ before, "", after });
        allocator.free(old_json_str);
    }
    defer allocator.free(json_str);

    const main_csr_react = @embedFile("./transpile/main_csr_react.tsx");
    const placeholder = "`{[ZX_COMPONENTS]s}`";
    const placeholder_index = std.mem.indexOf(u8, main_csr_react, placeholder) orelse {
        @panic("Placeholder {ZX_COMPONENTS} not found in main_csr_react.tsx");
    };

    const before = main_csr_react[0..placeholder_index];
    const after = main_csr_react[placeholder_index + placeholder.len ..];

    const main_csr_react_z = try std.mem.concat(allocator, u8, &.{ before, json_str, after });
    defer allocator.free(main_csr_react_z);

    const main_csr_react_path = try std.fs.path.join(allocator, &.{ output_dir, "main.tsx" });
    defer allocator.free(main_csr_react_path);

    try std.fs.cwd().writeFile(.{
        .sub_path = main_csr_react_path,
        .data = main_csr_react_z,
    });

    // Now using system command to compile the main.tsx file
    const outdir = try std.fs.path.join(allocator, &.{ output_dir, "public" });
    defer allocator.free(outdir);
    var system = std.process.Child.init(&.{ "bun", "build", main_csr_react_path, "--outdir", outdir }, allocator);
    _ = system.spawnAndWait() catch |err| {
        std.debug.print("You need to install bun to compile the main.tsx file: https://bun.sh/docs/installation\n", .{});
        return err;
    };
}

// ============================================================================
// Route and Meta Generation
// ============================================================================

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

fn generateFiles(allocator: std.mem.Allocator, output_dir: []const u8, verbose: bool) !void {
    const pages_dir = try std.fs.path.join(allocator, &.{ output_dir, "pages" });
    defer allocator.free(pages_dir);

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

    var content = std.array_list.Managed(u8).init(allocator);
    defer content.deinit();
    const writer = content.writer();

    try writer.writeAll("pub const routes = [_]zx.App.Meta.Route{\n");
    for (routes.items) |route| {
        try writeRoute(writer, route, 1);
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll("pub const meta = zx.App.Meta{\n");
    try writer.writeAll("    .routes = &routes,\n");
    try writer.writeAll("};\n\n");
    try writer.writeAll("const zx = @import(\"zx\");\n");

    const meta_path = try std.fs.path.join(allocator, &.{ output_dir, "meta.zig" });
    defer allocator.free(meta_path);

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

    if (has_root_page or has_root_layout) {
        var root_route = Route{
            .path = try allocator.dupe(u8, "/"),
            .page_import = if (has_root_page) try std.mem.concat(allocator, u8, &.{ import_prefix, "/page.zig" }) else null,
            .layout_import = if (has_root_layout) try std.mem.concat(allocator, u8, &.{ import_prefix, "/layout.zig" }) else null,
            .children = std.array_list.Managed(Route).init(allocator),
        };
        errdefer root_route.deinit(allocator);

        var dir = try std.fs.cwd().openDir(pages_dir, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;

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

// ============================================================================
// Transpilation
// ============================================================================

fn transpileFile(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    output_path: []const u8,
    input_root: []const u8,
    global_components: *std.array_list.Managed(ClientComponentJson),
    verbose: bool,
) !void {
    const source = try std.fs.cwd().readFileAlloc(
        allocator,
        source_path,
        std.math.maxInt(usize),
    );
    defer allocator.free(source);

    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    var result = try zx.Ast.parse(allocator, source_z);
    defer result.deinit(allocator);

    // Append components from this file to the global list
    for (result.client_components.items) |component| {
        const source_dir = std.fs.path.dirname(source_path) orelse ".";
        const resolved_component_path = try resolvePath(allocator, source_dir, component.path);
        defer allocator.free(resolved_component_path);

        // Calculate relative path from input root to component
        // This path will be the same in the output directory structure
        const component_rel_to_input = try relativePath(allocator, input_root, resolved_component_path);
        defer allocator.free(component_rel_to_input);

        // main.tsx is now in output_dir/, so import path is relative to output_dir
        const import_path = try std.fmt.allocPrint(allocator, "./{s}", .{component_rel_to_input});
        defer allocator.free(import_path);

        const import_str = try std.fmt.allocPrint(allocator, "@async () => (await import('{s}')).default@", .{import_path});
        defer allocator.free(import_str);

        const cloned_id = try allocator.dupe(u8, component.id);
        const cloned_name = try allocator.dupe(u8, component.name);
        const cloned_path = try allocator.dupe(u8, component_rel_to_input);
        const cloned_import = try allocator.dupe(u8, import_str);

        try global_components.append(.{
            .id = cloned_id,
            .name = cloned_name,
            .path = cloned_path,
            .import = cloned_import,
        });
    }

    if (std.fs.path.dirname(output_path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

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
    copy_dirs: []const []const u8,
    global_components: *std.array_list.Managed(ClientComponentJson),
    verbose: bool,
) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    const output_dir_relative = try getOutputDirRelativePath(allocator, dir_path, output_dir);
    defer if (output_dir_relative) |rel| allocator.free(rel);

    const sep = std.fs.path.sep_str;
    const dir_is_pages = std.mem.endsWith(u8, dir_path, sep ++ "pages") or
        std.mem.eql(u8, getBasename(dir_path), "pages") or
        std.mem.endsWith(u8, dir_path, "pages");

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        if (output_dir_relative) |rel| {
            if (std.mem.startsWith(u8, entry.path, rel)) {
                if (entry.path.len == rel.len) {
                    continue;
                }
                if (std.mem.startsWith(u8, entry.path[rel.len..], sep)) {
                    continue;
                }
            }
        }

        const is_zx = std.mem.endsWith(u8, entry.path, ".zx");

        const is_in_pages_dir = dir_is_pages or
            std.mem.startsWith(u8, entry.path, "pages" ++ sep) or
            std.mem.indexOf(u8, entry.path, sep ++ "pages" ++ sep) != null;

        const input_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(input_path);

        if (is_zx) {
            const output_rel_path = try std.mem.concat(allocator, u8, &.{
                entry.path[0 .. entry.path.len - (".zx").len],
                ".zig",
            });
            defer allocator.free(output_rel_path);

            const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel_path });
            defer allocator.free(output_path);

            transpileFile(allocator, input_path, output_path, dir_path, global_components, verbose) catch |err| {
                std.debug.print("Error transpiling {s}: {}\n", .{ input_path, err });
                continue;
            };
        } else if (is_in_pages_dir) {
            const output_path = try std.fs.path.join(allocator, &.{ output_dir, entry.path });
            defer allocator.free(output_path);

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

    copySpecifiedDirectories(allocator, dir_path, output_dir, copy_dirs, verbose) catch |err| {
        std.debug.print("Warning: Failed to copy specified directories: {}\n", .{err});
    };
}

fn transpileCommand(
    allocator: std.mem.Allocator,
    path: []const u8,
    output_dir: []const u8,
    copy_dirs: []const []const u8,
    verbose: bool,
) !void {
    var client_components = std.array_list.Managed(ClientComponentJson).init(allocator);
    defer {
        for (client_components.items) |*component| {
            allocator.free(component.id);
            allocator.free(component.name);
            allocator.free(component.path);
            allocator.free(component.import);
        }
        client_components.deinit();
    }

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
        try transpileDirectory(allocator, path, output_dir, copy_dirs, &client_components, verbose);

        generateFiles(allocator, output_dir, verbose) catch |err| {
            std.debug.print("Warning: Failed to generate meta.zig: {}\n", .{err});
        };
    } else if (stat.kind == .file) {
        const is_zx = std.mem.endsWith(u8, path, ".zx");

        if (!is_zx) {
            std.debug.print("Error: File must have .zx extension\n", .{});
            return error.InvalidFileExtension;
        }

        const basename = getBasename(path);

        const output_rel_path = try std.mem.concat(allocator, u8, &.{
            basename[0 .. basename.len - (".zx").len],
            ".zig",
        });
        defer allocator.free(output_rel_path);

        const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel_path });
        defer allocator.free(output_path);

        const input_root = if (std.fs.path.dirname(path)) |dir| dir else ".";
        try transpileFile(allocator, path, output_path, input_root, &client_components, verbose);

        copySpecifiedDirectories(allocator, path, output_dir, copy_dirs, verbose) catch |err| {
            std.debug.print("Warning: Failed to copy specified directories: {}\n", .{err});
        };

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

    if (client_components.items.len > 0) {
        genClientMain(allocator, client_components.items, output_dir) catch |err| {
            std.debug.print("Warning: Failed to generate main.tsx: {}\n", .{err});
        };
    }
}
