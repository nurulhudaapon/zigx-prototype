const std = @import("std");

test {
    _ = @import("zx/Transpiler.zig");
}

pub const std_options = std.Options{
    .log_level = .info,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .zx_transpiler, .level = .info },
    },
};
