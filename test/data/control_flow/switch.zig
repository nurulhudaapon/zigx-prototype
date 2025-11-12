pub fn Page(allocator: zx.Allocator) zx.Component {
    const user_type: UserType = .admin;
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = &.{
                switch (user_type) {
                    .admin => _zx.txt("Admin"),
                    .member => _zx.txt("Member"),
                },
            },
        },
    );
}

const zx = @import("zx");

const UserType = enum { admin, member };
