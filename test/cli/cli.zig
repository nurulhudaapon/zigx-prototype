const allocator = std.testing.allocator;

test "init" {
    return error.Todo;
    // var child = std.process.Child.init(&.{ "zx", "init" }, allocator);
    // try child.spawn();

    // var stdout = std.ArrayList(u8).empty;
    // var stderr = std.ArrayList(u8).empty;
    // try child.collectOutput(allocator, &stdout, &stderr, 8192);
    // std.debug.print("stdout: {s}\n", .{stdout.items});
    // std.debug.print("stderr: {s}\n", .{stderr.items});
    // _ = try child.wait();
}

// fn gotoTempDir() void {
//     const temp_dir = std.fs.path.join(allocator, &.{ std.fs.cwd() catch unreachable, "tmp/test/init" });
//     std.fs.makeDirAbsolute(temp_dir) catch unreachable;
// }

const std = @import("std");
