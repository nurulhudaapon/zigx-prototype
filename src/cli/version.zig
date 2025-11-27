pub fn register(writer: *std.Io.Writer, reader: *std.Io.Reader, allocator: std.mem.Allocator) !*zli.Command {
    return zli.Command.init(writer, reader, allocator, .{
        .name = "version",
        .shortcut = "v",
        .description = "Show CLI version",
    }, show);
}

fn show(ctx: zli.CommandContext) !void {
    try ctx.root.printVersion();
}

pub fn run(ctx: zli.CommandContext) !void {
    var spinner = ctx.spinner;

    // All spinner style names (SpinnerStyles uses pub const fields, not enum variants)
    const style_names = [_][]const u8{
        "none",
        "line",
        "arc",
        "point",
        "dots",
        "dots2",
        "dots_wide",
        "dots_circle",
        "dots_8bit",
        "sand",
        "dots_scrolling",
        "flip",
        "aesthetic",
        "bouncing_ball",
        "bouncing_bar",
        "toggle",
        "toggle2",
        "noise",
        "hamburger",
        "triangle",
        "box_bounce",
        "circle_halvess",
        "star",
        "grow_vertical",
        "earth",
        "monkey",
        "speaker",
        "moon",
        "mindblown",
        "clock",
        "weather",
    };

    // Loop through all spinner styles and demonstrate each one
    inline for (style_names) |style_name| {
        const style = @field(Spinner.SpinnerStyles, style_name);

        // Update spinner style
        spinner.updateStyle(.{ .frames = style, .refresh_rate_ms = 150 });

        // Start spinner with style name
        try spinner.start("Demo: {s}", .{style_name});
        std.Thread.sleep(700 * std.time.ns_per_ms);

        // Complete with success
        try spinner.succeed("Demo: {s} - Complete", .{style_name});
    }

    try spinner.print("All {d} spinner styles demonstrated!\n", .{style_names.len});
}

fn work() u128 {
    var i: u128 = 1;
    for (0..100000000) |t| {
        i = (t + i);
    }

    return i;
}

const std = @import("std");
const zli = @import("zli");
const Spinner = zli.Spinner;
