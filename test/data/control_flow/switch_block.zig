pub fn Page(allocator: zx.Allocator) zx.Component {
    const user_switch = users[0];
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = &.{
                switch (user_switch.user_type) {
                    .admin => _zx.txt("Admin"),
                    .member => _zx.txt("Member"),
                },
            },
        },
    );
}

const zx = @import("zx");

const UserType = enum { admin, member };

const User = struct {
    name: []const u8,
    age: u32,
    user_type: UserType,
};

const users = [_]User{
    .{ .name = "John", .age = 20, .user_type = .admin },
    .{ .name = "Jane", .age = 21, .user_type = .member },
};
