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

const std = @import("std");
const zx = @import("zx");
const log = std.log.scoped(.cli);
