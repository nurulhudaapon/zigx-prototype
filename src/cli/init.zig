pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "init",
        .description = "Initialize a new ZX project in the current directory",
    }, init);

    try cmd.addFlag(template_flag);

    return cmd;
}

fn init(ctx: zli.CommandContext) !void {
    const t_val = ctx.flag("template", []const u8); // type-safe flag access

    std.debug.print("○ Initializing ZX project!", .{});

    if (!std.mem.eql(u8, t_val, "default")) {
        std.debug.print("Unknown template: {s}, only 'default' is available.\n", .{t_val});
        return;
    }

    std.debug.print(" Template: \x1b[90m{s}\x1b[0m\n\n", .{t_val});

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
        // File doesn't exist, which is what we want - continue
        switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    for (templates) |template| {
        const output_path = try std.fs.path.join(ctx.allocator, &.{ output_dir, template.path });
        defer ctx.allocator.free(output_path);

        if (std.fs.path.dirname(output_path)) |parent_dir| {
            try std.fs.cwd().makePath(parent_dir);
        }

        var file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });

        std.debug.print("  + \x1b[90m{s}\x1b[0m\n", .{template.path});
        defer file.close();
        try file.writeAll(template.content);
    }

    std.debug.print("\nNow run → \n\n\x1b[36mzig build serve\x1b[0m\n\n", .{});
}

const TemplateFile = struct {
    path: []const u8,
    content: []const u8,
};

const template_dir = "init/template";

const templates = [_]TemplateFile{
    .{ .path = ".vscode/extensions.json", .content = @embedFile(template_dir ++ "/.vscode/extensions.json") },
    .{ .path = "build.zig.zon", .content = @embedFile(template_dir ++ "/build.zig.zon") },
    .{ .path = "build.zig", .content = @embedFile(template_dir ++ "/build.zig") },
    .{ .path = "README.md", .content = @embedFile(template_dir ++ "/README.md") },
    .{ .path = "site/assets/style.css", .content = @embedFile(template_dir ++ "/site/assets/style.css") },
    .{ .path = "site/main.zig", .content = @embedFile(template_dir ++ "/site/main.zig") },
    .{ .path = "site/pages/about/page.zx", .content = @embedFile(template_dir ++ "/site/pages/about/page.zx") },
    .{ .path = "site/pages/layout.zx", .content = @embedFile(template_dir ++ "/site/pages/layout.zx") },
    .{ .path = "site/pages/page.zx", .content = @embedFile(template_dir ++ "/site/pages/page.zx") },
    .{ .path = "src/root.zig", .content = @embedFile(template_dir ++ "/src/root.zig") },
    .{ .path = ".gitignore", .content = @embedFile(template_dir ++ "/.gitignore") },
};

const template_flag = zli.Flag{
    .name = "template",
    .shortcut = "t",
    .description = "Template to use (currently only one template is available)",
    .type = .String,
    .default_value = .{ .String = "default" },
};

const std = @import("std");
const zli = @import("zli");
