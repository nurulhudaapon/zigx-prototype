const std = @import("std");
const zx = @import("zx");

const User = struct { id: u32, name: []const u8 };

const MAX_USER_COUNT = 1000;
var users: std.ArrayList(User) = .empty;

const RequestInfo = struct {
    is_reset: bool,
    is_delete: bool,
    is_add: bool,
    users: std.ArrayList(User),
    filtered_users: std.ArrayList(User),
};

pub fn handleRequest(ctx: zx.PageContext) RequestInfo {
    const fd = ctx.request.formData() catch @panic("OOM");
    const qs = ctx.request.query() catch @panic("OOM");

    const is_reset = fd.get("reset") != null;
    const is_delete = fd.get("delete") != null;
    const is_add = fd.get("name") != null;

    if (is_reset) {
        handleReset(ctx.allocator);
    }

    if (is_delete) {
        if (fd.get("delete")) |delete_id| {
            handleDeleteUser(delete_id);
        }
    }

    if (is_add) {
        if (fd.get("name")) |name| {
            handleAddUser(ctx.allocator, name);
        }
    }

    const search_opt = qs.get("search");
    const filtered_users = filterUsers(ctx.arena, search_opt);

    if (is_delete or is_add or is_reset) {
        ctx.response.header("Location", "/example/form");
        ctx.response.setStatus(.found);
    }

    return RequestInfo{
        .is_reset = is_reset,
        .is_delete = is_delete,
        .is_add = is_add,
        .users = users,
        .filtered_users = filtered_users,
    };
}

fn handleReset(allocator: std.mem.Allocator) void {
    users.clearAndFree(allocator);
}

fn handleDeleteUser(delete_id_str: []const u8) void {
    const delete_id = std.fmt.parseInt(u32, delete_id_str, 10) catch @panic("Invalid delete ID");

    for (users.items, 0..) |user, i| {
        if (user.id == delete_id) {
            _ = users.orderedRemove(i);
            break;
        }
    }
}

fn handleAddUser(allocator: std.mem.Allocator, name: []const u8) void {
    if (name.len == 0) return;

    const new_id: u32 = @intCast(users.items.len + 1);
    const name_copy = allocator.dupe(u8, name) catch @panic("OOM");
    users.append(allocator, User{ .id = new_id, .name = name_copy }) catch @panic("OOM");
}

fn filterUsers(allocator: std.mem.Allocator, search_opt: ?[]const u8) std.ArrayList(User) {
    var filtered = std.ArrayList(User).empty;

    for (users.items) |user| {
        if (search_opt) |search| {
            if (std.mem.indexOf(u8, user.name, search) == null) {
                continue;
            }
        }
        filtered.append(allocator, user) catch @panic("OOM");
    }

    return filtered;
}
