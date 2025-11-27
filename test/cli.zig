const allocator = std.testing.allocator;
test "cli" {
    _ = @import("cli/fmt.zig");
}

fn getZxPath() ![]const u8 {
    const zx_bin_rel = "zig-out/bin/zx";
    const zx_bin_abs = try std.fs.cwd().realpathAlloc(allocator, zx_bin_rel);
    return zx_bin_abs;
}

fn getTestDirPath() ![]const u8 {
    const test_dir = "test/tmp";
    const test_dir_abs = try std.fs.cwd().realpathAlloc(allocator, test_dir);
    return test_dir_abs;
}

fn killPort(port: []const u8) !void {
    const builtin = @import("builtin");
    const target_os = builtin.target.os.tag;

    if (target_os == .windows) {
        // Windows: Use PowerShell to find and kill process on port
        const ps_command = try std.fmt.allocPrint(
            allocator,
            "Get-NetTCPConnection -LocalPort {s} -ErrorAction SilentlyContinue | ForEach-Object {{ Stop-Process -Id $_.OwningProcess -Force }}",
            .{port},
        );
        defer allocator.free(ps_command);

        var kill_child = std.process.Child.init(&.{ "powershell", "-Command", ps_command }, allocator);
        kill_child.stdout_behavior = .Pipe;
        kill_child.stderr_behavior = .Pipe;
        _ = kill_child.spawn() catch return;
        _ = kill_child.wait() catch {};
    } else {
        // Unix-like: Use lsof and kill
        const kill_command = try std.fmt.allocPrint(allocator, "kill -9 $(lsof -t -i:{s})", .{port});
        defer allocator.free(kill_command);

        var kill_child = std.process.Child.init(&.{ "sh", "-c", kill_command }, allocator);
        kill_child.stdout_behavior = .Pipe;
        kill_child.stderr_behavior = .Pipe;
        _ = kill_child.spawn() catch return;
        _ = kill_child.wait() catch {};
    }
}

test "cli > init" {

    // Create test/tmp directory
    const test_dir = "test/tmp";
    try std.fs.cwd().makePath(test_dir);

    // Get absolute path for test directory
    const test_dir_abs = try std.fs.cwd().realpathAlloc(allocator, test_dir);
    defer allocator.free(test_dir_abs);

    // Get absolute path for zx binary
    const zx_bin_rel = "zig-out/bin/zx";
    const zx_bin_abs = try std.fs.cwd().realpathAlloc(allocator, zx_bin_rel);
    defer allocator.free(zx_bin_abs);

    // Initialize child process with cwd set to test/tmp
    var child = std.process.Child.init(&.{ zx_bin_abs, "init" }, allocator);
    child.cwd = test_dir_abs;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout = std.ArrayList(u8).empty;
    var stderr = std.ArrayList(u8).empty;
    defer stdout.deinit(allocator);
    defer stderr.deinit(allocator);
    try child.collectOutput(allocator, &stdout, &stderr, 8192);
    std.debug.print("stdout: {s}\n", .{stdout.items});
    std.debug.print("stderr: {s}\n", .{stderr.items});

    // Verify that build.zig.zon was created
    const build_zig_zon_path = try std.fs.path.join(allocator, &.{ test_dir_abs, "build.zig.zon" });
    defer allocator.free(build_zig_zon_path);

    const file = try std.fs.openFileAbsolute(build_zig_zon_path, .{});
    defer file.close();
}

test "cli > serve" {
    const zx_bin_abs = try getZxPath();
    const test_dir_abs = try getTestDirPath();
    defer allocator.free(zx_bin_abs);
    defer allocator.free(test_dir_abs);

    const port = "3456";
    const port_colon = try std.fmt.allocPrint(allocator, ":{s}", .{port});
    defer allocator.free(port_colon);

    // Kill anything on that port (cross-platform)
    killPort(port) catch {};

    var build_child = std.process.Child.init(&.{ "zig", "build" }, allocator);
    build_child.cwd = test_dir_abs;
    build_child.stdout_behavior = .Ignore;
    build_child.stderr_behavior = .Ignore;
    try build_child.spawn();
    _ = build_child.wait() catch {};

    var child = std.process.Child.init(&.{ zx_bin_abs, "serve", "--port", port }, allocator);
    child.cwd = test_dir_abs;
    // child.stdout_behavior = .Ignore;
    // child.stderr_behavior = .Ignore;
    try child.spawn();
    defer _ = child.kill() catch {};
    errdefer _ = child.kill() catch {};

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://{s}:{s}", .{ "localhost", port });
    defer allocator.free(url);

    // wait for 2 seconds
    std.Thread.sleep(std.time.ns_per_s * 1);
    const result = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .headers = std.http.Client.Request.Headers{},
        .response_writer = &aw.writer,
    });

    // Wait 500ms
    std.Thread.sleep(std.time.ns_per_ms * 500);
    _ = child.kill() catch {};
    errdefer _ = child.kill() catch {};

    try std.testing.expectEqual(result.status, std.http.Status.ok);
}

test "tests:beforeAll" {
    std.fs.cwd().deleteTree("test/tmp") catch {};
}

test "tests:afterAll" {
    std.fs.cwd().deleteTree("test/tmp") catch {};
}

const std = @import("std");
