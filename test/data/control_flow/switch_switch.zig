pub fn Page(allocator: zx.Allocator) zx.Component {
    const user_type: UserType = .admin;
    const status: Status = .active;
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = &.{
                switch (user_type) {
                    .admin => switch (status) {
                        .active => _zx.zx(
                            .p,
                            .{
                                .children = &.{
                                    _zx.txt("Active Admin"),
                                },
                            },
                        ),
                        .inactive => _zx.zx(
                            .p,
                            .{
                                .children = &.{
                                    _zx.txt("Inactive Admin"),
                                },
                            },
                        ),
                    },
                    .member => switch (status) {
                        .active => _zx.zx(
                            .p,
                            .{
                                .children = &.{
                                    _zx.txt("Active Member"),
                                },
                            },
                        ),
                        .inactive => _zx.zx(
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
        },
    );
}

const zx = @import("zx");

const UserType = enum { admin, member };
const Status = enum { active, inactive };
