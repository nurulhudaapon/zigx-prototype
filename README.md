# ZX

A Zig library for building web applications with JSX-like syntax. Write declarative UI components using familiar JSX patterns, transpiled to efficient Zig code.

ZX combines the power and performance of Zig with the expressiveness of JSX, enabling you to build fast, type-safe web applications. ZX uses [http.zig](https://github.com/karlseguin/http.zig) to create high-performance HTTP servers, making it significantly faster than frameworks like Next.js.

**📚 [Full Documentation →](https://zx.nuhu.dev)**

## Quick Example

```jsx
pub fn Page(allocator: zx.Allocator) zx.Component {
    const is_loading = true;
    const chars = "Hello, World!";

    return (
        <body>
            <section>
                {if (is_loading) (<h1>Loading...</h1>) else (<h1>Loaded</h1>)}
            </section>

            <section>
                {for (chars) |char| (<span>{[char:c]}</span>)}
            </section>

            <section>
                {for (users) |user| {
                    (<p>{user.name} - {[user.age:d]} - 
                    
                    {switch (user.user_type) {
                        .admin => ("Admin"),
                        .member => ("Member"),
                    }}
                    </p>)
                }}
            </section>

        </body>
    );
}

const zx = @import("zx");

const User = struct {
    const UserType = enum { admin, member };

    name: []const u8,
    age: u32,
    user_type: UserType,
};

const users = [_]User{
    .{ .name = "John", .age = 20, .user_type = .admin },
    .{ .name = "Jane", .age = 21, .user_type = .member },
};

```
## Features

- **JSX-like syntax** - Write UI components using familiar JSX patterns
- **Type-safe** - Full Zig type checking and safety
- **High performance** - Powered by Zig and http.zig for maximum speed
- **Server-Side Rendering (SSR)** - Generate HTML on the server
- **Static Site Generation (SSG)** - Pre-render pages at build time

## Documentation

For complete documentation, examples, and guides, visit **[https://zx.nuhu.dev](https://zx.nuhu.dev)**

## License

MIT
