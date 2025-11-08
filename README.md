# ZX

A Zig library for building web applications with JSX-like syntax. Write declarative UI components using familiar JSX patterns, transpiled to efficient Zig code.

ZX combines the power and performance of Zig with the expressiveness of JSX, enabling you to build fast, type-safe web applications. ZX is significantly faster than frameworks like Next.js at SSR.

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
                    (<p>{user.name} - {[user.age:d]} - {switch (user.user_type) {
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
## Feature Checklist

Core
- [x] JSX-like syntax
- [x] Server-Side Rendering (SSR)
- [ ] Static Site Generation (SSG) _(in progress)_
- [x] High performance  
  _Currently 120X faster than Next.js at SSR_
- [x] Asset Copying
- [x] Asset Serving
- [ ] Image Optimization
- [ ] Server Actions
- [ ] Route Handlers / Path Segments
- [x] Type Safety
- [x] File-system Routing
- [ ] Middleware support
- [ ] API Endpoints
- [ ] CSS-in-ZX / Styling Solution
- [ ] Incremental Static Regeneration (ISR)
- [ ] Client-Side Rendering (CSR) via WebAssembly
- [ ] Importing React Components

Tooling
- [ ] CLI
- [ ] Dev Server (HMR or Rebuild on Change)

### Editor Support

* [VSCode](https://marketplace.visualstudio.com/items?itemName=nurulhudaapon.zx)/[Cursor](https://marketplace.visualstudio.com/items?itemName=nurulhudaapon.zx) Extension
    - [x] Syntax Highlighting
    - [x] LSP Support
    - [ ] Auto Format

* Neovim
    - [ ] Syntax Highlighting
    - [ ] LSP Support
    - [ ] Auto Format

## Similar Projects

* [ZTS](https://github.com/zigster64/zts)
* [zmpl](https://github.com/jetzig-framework/zmpl)
* [mustache-zig](https://github.com/batiati/mustache-zig)
* [etch](https://github.com/haze/etch)
* [Zap](https://github.com/zigzap/zap)
* [http.zig](https://github.com/karlseguin/http.zig) (_ZX_'s backend)
* [tokamak](https://github.com/cztomsik/tokamak)
* [zig-router](https://github.com/Cloudef/zig-router)
* [zig-webui](https://github.com/webui-dev/zig-webui/)
* [Zine](https://github.com/kristoff-it/zine)
* [Zinc](https://github.com/zon-dev/zinc/)
* [zUI](https://github.com/thienpow/zui)
* [ziggy](https://github.com/kristoff-it/ziggy) — SSG

## Documentation

For complete documentation, examples, and guides, visit **[https://zx.nuhu.dev](https://zx.nuhu.dev)**

## License

MIT
