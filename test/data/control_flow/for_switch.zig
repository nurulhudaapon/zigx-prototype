pub fn Page(ctx: zx.PageContext) zx.Component {
    const users = [_]struct { name: []const u8, role: UserRole }{
        .{ .name = "John", .role = .admin },
        .{ .name = "Jane", .role = .member },
        .{ .name = "Jim", .role = .guest },
    };
    var _zx = zx.initWithAllocator(ctx.arena);
    return _zx.zx(
        .main,
        .{
            .allocator = ctx.arena,
            .children = blk: {
                const __zx_children = _zx.getAllocator().alloc(zx.Component, users.len) catch unreachable;
                for (users, 0..) |user, i| {
                    __zx_children[i] = _zx.zx(
                        .div,
                        .{
                            .children = &.{
                                _zx.zx(
                                    .p,
                                    .{
                                        .children = &.{
                                            _zx.txt(user.name),
                                        },
                                    },
                                ),
                                switch (user.role) {
                                    .admin => _zx.zx(
                                        .span,
                                        .{
                                            .children = &.{
                                                _zx.txt("Admin"),
                                            },
                                        },
                                    ),
                                    .member => _zx.zx(
                                        .span,
                                        .{
                                            .children = &.{
                                                _zx.txt("Member"),
                                            },
                                        },
                                    ),
                                    .guest => _zx.zx(
                                        .span,
                                        .{
                                            .children = &.{
                                                _zx.txt("Guest"),
                                            },
                                        },
                                    ),
                                },
                            },
                        },
                    );
                }
                break :blk __zx_children;
            },
        },
    );
}

const zx = @import("zx");

const UserRole = enum { admin, member, guest };
