pub fn Page(allocator: zx.Allocator) zx.Component {
    const user_names = [_][]const u8{ "John", "Jane", "Jim", "Jill" };
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = blk: {
                const __zx_children = _zx.getAllocator().alloc(zx.Component, user_names.len) catch unreachable;
                for (user_names, 0..) |name, i| {
                    __zx_children[i] = _zx.zx(
                        .p,
                        .{
                            .children = &.{
                                _zx.txt(name),
                            },
                        },
                    );
                }
                break :blk __zx_children;
            },
        },
    );
}

pub fn StructCapture(allocator: zx.Allocator) zx.Component {
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = blk: {
                const __zx_children = _zx.getAllocator().alloc(zx.Component, users.len) catch unreachable;
                for (users, 0..) |user, i| {
                    __zx_children[i] = _zx.zx(
                        .p,
                        .{
                            .children = &.{
                                _zx.txt(user.name),
                                _zx.txt(" - "),
                                _zx.fmt("{d}", .{user.age}),
                            },
                        },
                    );
                }
                break :blk __zx_children;
            },
        },
    );
}

pub fn StructCaptureToComponent(allocator: zx.Allocator) zx.Component {
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = blk: {
                const __zx_children = _zx.getAllocator().alloc(zx.Component, users.len) catch unreachable;
                for (users, 0..) |user, i| {
                    __zx_children[i] = _zx.lazy(UserComponent, .{ .name = user.name, .age = user.age });
                }
                break :blk __zx_children;
            },
        },
    );
}

const User = struct { name: []const u8, age: u32 };
const users = [_]User{
    .{ .name = "John", .age = 20 },
    .{ .name = "Jane", .age = 21 },
    .{ .name = "Jim", .age = 22 },
    .{ .name = "Jill", .age = 23 },
};

fn UserComponent(allocator: zx.Allocator, props: User) zx.Component {
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .p,
        .{
            .allocator = allocator,
            .children = &.{
                _zx.txt(props.name),
                _zx.txt(" - "),
                _zx.fmt("{d}", .{props.age}),
            },
        },
    );
}

const zx = @import("zx");
const std = @import("std");
