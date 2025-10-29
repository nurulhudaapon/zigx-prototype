pub fn Page(allocator: std.mem.Allocator) zx.Component {
    const dynamic_title = "Dynamic Title!";
    const _zx= zx.init (allocator);
return _zx.zx (
        .div,
        .{
            .children=&.{
                .{
                    .element= .{
                        .tag= .h1,
                        .children=&.{.{.text= "Testing Props"}, },
                    },
                },
                                Button (allocator, .{.title= "Send Message"}),
                                Button (allocator, .{.title= dynamic_title}),
                                Button (allocator, .{}),
                .{
                    .element= .{
                        .tag= .p,
                        .children=&.{.{.text= "Three buttons with different titles!"}, },
                    },
                },
            },
        },
    );
}

const std = @import("std");
const zx = @import("zx");

const ButtonProps = struct {
    title: []const u8 = "Click Me",  // Default value
};

// Custom Button component with props
fn Button(allocator: std.mem.Allocator, props: ButtonProps) zx.Component {
    const _zx= zx.init (allocator);
return _zx.zx (
        .button,
        .{
            .attributes=&.{
                .{.name= "class", .value= "btn"},
            },
            .children=&.{
                .{.text= props.title},
            },
        },
    );
}