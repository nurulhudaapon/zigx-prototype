pub fn Page() zx.Component {
    const dynamic_class = "btn-class";
	const hero_title = "Zigx";
	const sub_title = "ZigX is a modern web framework powered by Zig. Experience unprecedented performance and developer experience.";

    return zx.zx (
        .html,
        .{
            .children=&.{
                .{
                    .element= .{
                        .tag= .head,
                        .children=&.{.{.element= .{
                            .tag= .meta,
                            .attributes=&.{.{.name= "charset", .value= "UTF-8"}, .{.name= "class", .value= dynamic_class}, },
                        }}, .{.element= .{
                            .tag= .meta,
                            .attributes=&.{.{.name= "name", .value= "viewport"}, .{.name= "content", .value= "width=device-width, initial-scale=1.0"}, },
                        }}, .{.element= .{
                            .tag= .title,
                            .children=&.{.{.text= "ZigX - Modern Web Framework"}, },
                        }}, .{.element= .{
                            .tag= .link,
                            .attributes=&.{.{.name= "rel", .value= "stylesheet"}, .{.name= "href", .value= "index.css"}, },
                        }}, },
                    },
                },
                .{
                    .element= .{
                        .tag= .body,
                        .children=&.{.{.element= .{
                            .tag= .header,
                            .children=&.{.{.element= .{
                                .tag= .nav,
                                .attributes=&.{.{.name= "class", .value= "container"}, },
                                .children=&.{.{.element= .{
                                    .tag= .div,
                                    .attributes=&.{.{.name= "class", .value= "logo"}, },
                                    .children=&.{.{.text= "ZigX ⚡"}, },
                                }}, },
                            }}, },
                        }}, .{.element= .{
                            .tag= .section,
                            .attributes=&.{.{.name= "class", .value= "hero"}, .{.name= "id", .value= "home"}, },
                            .children=&.{.{.element= .{
                                .tag= .div,
                                .attributes=&.{.{.name= "class", .value= "container"}, },
                                .children=&.{.{.element= .{
                                    .tag= .h1,
                                    .children=&.{.{.text= hero_title}, },
                                }}, .{.element= .{
                                    .tag= .h1,
                                    .children=&.{.{.text= hero_title}, },
                                }}, .{.element= .{
                                    .tag= .h1,
                                    .children=&.{.{.text= hero_title}, },
                                }}, .{.element= .{
                                    .tag= .h1,
                                    .children=&.{.{.text= hero_title}, },
                                }}, .{.element= .{
                                    .tag= .h1,
                                    .children=&.{.{.text= hero_title}, },
                                }}, .{.element= .{
                                    .tag= .p,
                                    .children=&.{.{.text= sub_title}, },
                                }}, },
                            }}, },
                        }}, },
                    },
                },
            },
        },
    );
}

const zx = @import("zx");
