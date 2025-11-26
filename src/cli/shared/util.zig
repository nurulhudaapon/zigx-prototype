const BIN_DIR = "zig-out/bin";

/// Find the ZX executable from the bin directory
pub fn findprogram(allocator: std.mem.Allocator, binpath: []const u8) !zx.App.SerilizableAppMeta {
    if (!std.mem.eql(u8, binpath, "")) {
        var app_meta = try inspectProgram(allocator, binpath);
        // defer std.zon.parse.free(allocator, app_meta);
        // errdefer std.zon.parse.free(allocator, app_meta);
        app_meta.binpath = binpath;
        return app_meta;
    }

    var files = try std.fs.cwd().openDir(BIN_DIR, .{ .iterate = true });
    defer files.close();

    var exe_count: usize = 0;
    var it = files.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file) {
            exe_count += 1;

            const full_path = try std.fs.path.join(allocator, &.{ BIN_DIR, entry.name });
            defer allocator.free(full_path);

            log.debug("Inspecting exe: {s}", .{full_path});

            var app_meta = inspectProgram(allocator, full_path) catch |err| switch (err) {
                error.ProgramNotFound, error.ParseZon => continue,
                else => return err,
            };
            // defer std.zon.parse.free(allocator, app_meta);

            log.debug("Found app: {s} in {s}", .{ app_meta.version, full_path });

            app_meta.binpath = try allocator.dupe(u8, full_path);
            return app_meta;
        }
    }

    if (exe_count == 0) return error.EmptyBinDir;
    return error.ProgramNotFound;
}

pub fn inspectProgram(allocator: std.mem.Allocator, binpath: []const u8) !zx.App.SerilizableAppMeta {
    var exe = std.process.Child.init(&.{ binpath, "--introspect" }, allocator);
    exe.stdout_behavior = .Pipe;
    exe.stderr_behavior = .Ignore;
    try exe.spawn();

    const source = if (exe.stdout) |estdout| estdout.readToEndAlloc(allocator, 8192) catch |err| {
        _ = exe.kill() catch {};
        return err;
    } else {
        _ = exe.kill() catch {};
        return error.ProgramNotFound;
    };
    defer allocator.free(source);

    _ = exe.wait() catch {};

    if (source.len == 0) return error.ProgramNotFound;

    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    const app_meta = try std.zon.parse.fromSlice(zx.App.SerilizableAppMeta, allocator, source_z, null, .{});

    return app_meta;
}

const ignore_dirs = [_][]const u8{"assets/_zx"};
fn shouldIgnorePath(path: []const u8) bool {
    for (ignore_dirs) |ignore_dir| {
        if (std.mem.startsWith(u8, path, ignore_dir)) return true;
    }
    return false;
}
pub fn copydirs(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    source_dirs: []const []const u8,
    dest_dir: []const u8,
    public_to_root: bool,
    printer: *zx.Printer,
) !void {
    for (source_dirs) |source_dir| {
        const source_path = try std.fs.path.join(allocator, &.{ base_dir, source_dir });
        defer allocator.free(source_path);

        var source = std.fs.cwd().openDir(source_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.NotDir => continue,
            else => return err,
        };
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
            const src_path = try std.fs.path.join(allocator, &.{ source_path, entry.path });
            defer allocator.free(src_path);

            const dst_rel_path = try std.fs.path.join(allocator, &.{
                if (public_to_root and std.mem.eql(u8, source_dir, "public")) "" else source_dir,
                entry.path,
            });
            defer allocator.free(dst_rel_path);

            const dst_abs_path = try std.fs.path.join(allocator, &.{ dest_dir, dst_rel_path });
            defer allocator.free(dst_abs_path);

            switch (entry.kind) {
                .file => {
                    if (shouldIgnorePath(dst_rel_path)) continue;

                    // Create parent directory if needed
                    if (std.fs.path.dirname(dst_abs_path)) |parent| {
                        std.fs.cwd().makePath(parent) catch |err| switch (err) {
                            error.PathAlreadyExists => {},
                            else => return err,
                        };
                    }

                    // Copy file
                    try std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_abs_path, .{});
                    printer.printFilePath(dst_rel_path);
                },
                .directory => {
                    if (shouldIgnorePath(dst_abs_path)) continue;
                    // Create directory if needed
                    std.fs.cwd().makePath(dst_abs_path) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                },
                else => continue,
            }
        }
    }
}

const std = @import("std");
const zx = @import("zx");
const log = std.log.scoped(.cli);
