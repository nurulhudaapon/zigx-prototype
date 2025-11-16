pub fn Page(allocator: zx.Allocator) zx.Component {
    const user_type: UserType = .admin;
    const is_active = true;
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = &.{
                switch (user_type) {
                    .admin => if (is_active) _zx.zx(
                        .p,
                        .{
                            .children = &.{
                                _zx.txt("Active Admin"),
                            },
                        },
                    ) else _zx.zx(
                        .p,
                        .{
                            .children = &.{
                                _zx.txt("Inactive Admin"),
                            },
                        },
                    ),
                    .member => if (is_active) _zx.zx(
                        .p,
                        .{
                            .children = &.{
                                _zx.txt("Active Member"),
                            },
                        },
                    ) else _zx.zx(
                        .p,
                        .{
                            .children = &.{
                                _zx.txt("Inactive Member"),
                            },
                        },
                    ),
                },
            },
        },
    );
}

const zx = @import("zx");

const UserType = enum { admin, member };
