pub const binpath_flag = zli.Flag{
    .name = "binpath",
    .shortcut = "b",
    .description = "Binpath of the app in case if you have multiple exe artificats or using custom zig-out directory",
    .type = .String,
    .default_value = .{ .String = "" },
};

const zli = @import("zli");
