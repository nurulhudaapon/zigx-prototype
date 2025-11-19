pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(writer, reader, allocator, .{
        .name = "dev",
        .description = "Start the app in development mode with rebuild on change",
    }, dev);

    try cmd.addFlag(bindir_flag);

    return cmd;
}

const RESTART_INTERVAL = std.time.ns_per_s * 2;
const BIN_DIR = "zig-out/bin";

const bindir_flag = zli.Flag{
    .name = "bindir",
    .shortcut = "b",
    .description = "Bindir to look for the app in, in case it's not in the default location",
    .type = .String,
    .default_value = .{ .String = BIN_DIR },
};

fn dev(ctx: zli.CommandContext) !void {
    const allocator = ctx.allocator;
    const bindir = ctx.flag("bindir", []const u8);

    var builder = std.process.Child.init(&.{ "zig", "build", "--watch" }, allocator);
    try builder.spawn();

    const program_path = try findprogram(allocator, bindir);
    var runner = std.process.Child.init(&.{program_path}, allocator);
    try runner.spawn();

    var bin_mtime: i128 = 0;
    while (true) {
        std.Thread.sleep(RESTART_INTERVAL);
        const stat = try std.fs.cwd().statFile(program_path);

        const should_restart = stat.mtime != bin_mtime and bin_mtime != 0;
        if (should_restart) {
            std.debug.print("\x1b[32mChange detected, restarting server...\x1b[0m\n", .{});

            _ = try runner.kill();
            try runner.spawn();
        }
        if (should_restart or bin_mtime == 0) bin_mtime = stat.mtime;
    }

    defer {
        _ = runner.kill() catch unreachable;
        _ = builder.kill() catch unreachable;
    }

    errdefer {
        _ = runner.kill() catch unreachable;
        _ = builder.kill() catch unreachable;
    }
}

/// Find the ZX executable from the bin directory
fn findprogram(allocator: std.mem.Allocator, bindir: []const u8) ![]const u8 {
    var files = try std.fs.cwd().openDir(bindir, .{ .iterate = true });
    defer files.close();

    var it = files.iterate();
    while (try it.next()) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ bindir, entry.name });
        // defer allocator.free(full_path);

        const stat = try std.fs.cwd().statFile(full_path);
        if (stat.kind == .file and std.mem.startsWith(u8, entry.name, "zx_")) {
            // std.debug.print("Inspecting exe: {s}\n", .{full_path});

            const app_meta = try inspectProgram(allocator, full_path);
            defer std.zon.parse.free(allocator, app_meta);

            // std.debug.print("Found app: {s} in {s}\n", .{ app_meta.version, full_path });

            return full_path;
        }
    }
    return error.ProgramNotFound;
}

fn inspectProgram(allocator: std.mem.Allocator, full_path: []const u8) !zx.App.SerilizableAppMeta {
    var exe = std.process.Child.init(&.{ full_path, "--introspect" }, allocator);
    exe.stdout_behavior = .Pipe;
    try exe.spawn();

    const source = try exe.stdout.?.readToEndAlloc(allocator, 8192);
    const source_z = try allocator.dupeZ(u8, source);

    const app_meta = try std.zon.parse.fromSlice(zx.App.SerilizableAppMeta, allocator, source_z, null, .{});

    defer {
        allocator.free(source);
        allocator.free(source_z);
        _ = exe.kill() catch unreachable;
    }
    errdefer {
        _ = exe.kill() catch unreachable;
    }

    return app_meta;
}
const std = @import("std");
const zli = @import("zli");
const zx = @import("zx");
