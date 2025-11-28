pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "init",
        .description = "Initialize a new ZX project in the current directory",
    }, init);

    try cmd.addFlag(template_flag);

    return cmd;
}

const template_flag = zli.Flag{
    .name = "template",
    .shortcut = "t",
    .description = "Template to use (default, react)",
    .type = .String,
    .default_value = .{ .String = "default" },
};

fn init(ctx: zli.CommandContext) !void {
    const t_val = ctx.flag("template", []const u8); // type-safe flag access

    const template_name = if (std.meta.stringToEnum(TemplateFile.Name, t_val)) |name| name else {
        std.debug.print("\x1b[33mUnknown template:\x1b[0m {s}\n\nTemplates:\n", .{t_val});

        for (std.enums.values(TemplateFile.Name)) |name| {
            std.debug.print("  - \x1b[34m{s}\x1b[0m\n", .{@tagName(name)});
        }
        std.debug.print("\n", .{});
        return;
    };

    var printer = tui.Printer.init(ctx.allocator, .{ .file_path_mode = .flat, .file_tree_max_depth = 1 });
    defer printer.deinit();

    printer.header("Initializing ZX project!", "○", .{});
    std.debug.print("  - {s}[{s}]{s}\n", .{ tui.Colors.gray, @tagName(template_name), tui.Colors.reset });
    const output_dir = ".";

    try std.fs.cwd().makePath(output_dir);

    // Check if build.zig.zon already exists
    const build_zig_zon_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, "build.zig.zon" });
    defer ctx.allocator.free(build_zig_zon_path);

    const cwd = std.fs.cwd();
    if (cwd.openFile(build_zig_zon_path, .{})) |file| {
        file.close();
        std.debug.print("\x1b[33m⚠ Warning: build.zig.zon already exists in {s}/. Skipping template initialization.\x1b[0m\n", .{output_dir});
        return;
    } else |err| {
        switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    for (templates) |template| {
        if (template.name != null and template.name.? != template_name) continue;

        const output_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, template.path });
        defer ctx.allocator.free(output_path);

        if (std.fs.path.dirname(output_path)) |parent_dir| {
            try std.fs.cwd().makePath(parent_dir);
        }

        var file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });

        printer.filepath(template.path);
        defer file.close();
        try file.writeAll(template.content);
    }

    printer.footer("Now run →\n\n{s}zig build serve{s}", .{ tui.Colors.cyan, tui.Colors.reset });
}

const TemplateFile = struct {
    const Name = enum { default, react, wasm };

    name: ?Name = null,
    path: []const u8,
    content: []const u8,
    description: ?[]const u8 = "",
};

const template_dir = "init/template";

const templates = [_]TemplateFile{
    // Shared
    .{ .path = ".vscode/extensions.json", .content = @embedFile(template_dir ++ "/.vscode/extensions.json") },
    .{ .path = "build.zig.zon", .content = @embedFile(template_dir ++ "/build.zig.zon") },
    .{ .path = "build.zig", .content = @embedFile(template_dir ++ "/build.zig") },
    .{ .path = "README.md", .content = @embedFile(template_dir ++ "/README.md") },
    .{ .path = "site/public/style.css", .content = @embedFile(template_dir ++ "/site/public/style.css") },
    .{ .path = "site/public/favicon.ico", .content = @embedFile(template_dir ++ "/site/public/favicon.ico") },
    .{ .path = "site/main.zig", .content = @embedFile(template_dir ++ "/site/main.zig") },
    .{ .path = "site/pages/about/page.zx", .content = @embedFile(template_dir ++ "/site/pages/about/page.zx") },
    .{ .path = "site/pages/layout.zx", .content = @embedFile(template_dir ++ "/site/pages/layout.zx") },
    .{ .path = "src/root.zig", .content = @embedFile(template_dir ++ "/src/root.zig") },
    .{ .path = ".gitignore", .content = @embedFile(template_dir ++ "/.gitignore") },

    // Default
    .{ .name = .default, .path = "site/pages/page.zx", .content = @embedFile(template_dir ++ "/site/pages/page.zx") },

    // React
    .{ .name = .react, .path = "site/main.ts", .content = @embedFile(template_dir ++ "/site/main.ts") },
    .{ .name = .react, .path = "site/pages/page.zx", .content = @embedFile(template_dir ++ "/site/pages/page+react.zx") },
    .{ .name = .react, .path = "site/pages/client.tsx", .content = @embedFile(template_dir ++ "/site/pages/client.tsx") },
    .{ .name = .react, .path = "package.json", .content = @embedFile(template_dir ++ "/package.json") },
    .{ .name = .react, .path = "tsconfig.json", .content = @embedFile(template_dir ++ "/tsconfig.json") },
};

const std = @import("std");
const zli = @import("zli");
const tui = @import("../tui/main.zig");
