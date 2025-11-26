pub fn Page(allocator: zx.Allocator) zx.Component {
    const show_user_type = true;
    const user_type: UserType = .admin;
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = &.{
                if ((show_user_type))
                    switch (user_type) {
                        .admin => _zx.zx(
                            .p,
                            .{
                                .children = &.{
                                    _zx.txt("Admin"),
                                },
                            },
                        ),
                        .member => _zx.zx(
                            .p,
                            .{
                                .children = &.{
                                    _zx.txt("Member"),
                                },
                            },
                        ),
                    }
                else
                    _zx.zx(
                        .p,
                        .{
                            .children = &.{
                                _zx.txt("User type hidden"),
                            },
                        },
                    ),
            },
        },
    );
}

const zx = @import("zx");

const UserType = enum { admin, member };
