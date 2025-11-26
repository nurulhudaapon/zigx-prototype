# ZX

A Zig library for building web applications with JSX-like syntax. Write declarative UI components using familiar JSX patterns, transpiled to efficient Zig code.

ZX combines the power and performance of Zig with the expressiveness of JSX, enabling you to build fast, type-safe web applications. ZX is significantly faster than frameworks like Next.js at SSR.

**[Full Documentation →](https://ziex.dev)**

## Installation

##### Linux/macOS
```bash
curl -fsSL https://ziex.dev/install | bash
```

##### Windows
```powershell
powershell -c "irm ziex.dev/install.ps1 | iex"

```
##### Installing Zig
```bash
brew install zig # macOS
winget install -e --id zig.zig # Windows
```
[_See for other platforms →_](https://ziglang.org/learn/getting-started/)

## Quick Example

```tsx site/pages/examples/overview.zx
pub fn QuickExample(allocator: zx.Allocator) zx.Component {
    const is_loading = true;
    const chars = "Hello, ZX Dev!";

    return (
        <main @allocator={allocator}>
            <section>
                {if (is_loading) (<h1>Loading...</h1>) else (<h1>Loaded</h1>)}
            </section>
        
            <section>
                {for (chars) |char| (<span>{[char:c]}</span>)}
            </section>
        
            <section>
                {for (users) |user| (
                    <Profile name={user.name} age={user.age} role={user.role} />
                )}
            </section>
        </main>
    );
}

fn Profile(allocator: zx.Allocator, user: User) zx.Component {
    return (
        <div @allocator={allocator}>
            <h1>{user.name}</h1>
            <p>{[user.age:d]}</p>
            {switch (user.role) {
                .admin => (<p>Admin</p>),
                .member => (<p>Member</p>),
            }}
        </div>
    );
}

const UserRole = enum { admin, member };
const User = struct { name: []const u8, age: u32, role: UserRole };

const users = [_]User{
    .{ .name = "John", .age = 20, .role = .admin },
    .{ .name = "Jane", .age = 21, .role = .member },
};

const zx = @import("zx");
```
## Feature Checklist

- [x] Server Side Rendering (SSR)
- [x] Static Site Generation (SSG)
- [ ] Client Side Rendering (CSR) via WebAssembly (_WIP_)
- [x] Client Side Rendering (CSR) via React
- [x] Type Safety
- [x] Routing
    - [x] File-system Routing
    - [x] Search Parameters
    - [x] Path Segments
- [x] Components
- [x] Control Flow
    - [x] `if`
    - [ ] `if` nested
    - [x] `if/else`
    - [x] `if/else` nested
    - [x] `for`
    - [x] `for` nested
    - [x] `switch`
    - [x] `switch` nested
    - [x] `while`
    - [x] `while` nested
- [x] Assets
    - [x] Copying
    - [x] Serving
- [ ] Assets Optimization
    - [ ] Image
    - [ ] CSS
    - [ ] JS
    - [ ] HTML
- [ ] Middleware
- [ ] API Endpoints
- [ ] Server Actions
- [x] CLI
    - [x] `init` Project Template
    - [x] `transpile` Transpile .zx files to Zig source code
    - [x] `serve` Serve the project
    - [x] `dev` HMR or Rebuild on Change
    - [x] `fmt` Format the ZX source code (_Alpha_)
    - [x] `export` Generate static site assets
    - [x] `bundle` Bundle the ZX executable with public/assets and exe
    - [x] `version` Show the version of the ZX CLI
    - [x] `update` Update the version of ZX dependency
    - [x] `upgrade` Upgrade the version of ZX CLI

#### Editor Support

* [VSCode](https://marketplace.visualstudio.com/items?itemName=nurulhudaapon.zx)/[Cursor](https://marketplace.visualstudio.com/items?itemName=nurulhudaapon.zx) Extension
    - [x] Syntax Highlighting
    - [x] LSP Support
    - [x] Auto Format

* Neovim
    - [ ] Syntax Highlighting
    - [ ] LSP Support
    - [ ] Auto Format

## Similar Projects

* [Yew](https://github.com/yewstack/yew) - Rust / Wasm framework for creating reliable and efficient web applications
* [ZTS](https://github.com/zigster64/zts) — Zig Templates made Simple, a templating system for Zig
* [zmpl](https://github.com/jetzig-framework/zmpl) — Mode-based templating language that compiles to Zig functions at build time, used in Jetzig
* [mustache-zig](https://github.com/batiati/mustache-zig) — Mustache template engine implementation in Zig
* [etch](https://github.com/haze/etch) — Compile-time tuned templating engine focusing on speed and simplicity
* [Zap](https://github.com/zigzap/zap) — High-performance backend framework in Zig
* [http.zig](https://github.com/karlseguin/http.zig) — Low-level HTTP/1.1 server written entirely in Zig (_ZX_'s backend)
* [tokamak](https://github.com/cztomsik/tokamak) — Server-side framework for Zig
* [zig-router](https://github.com/Cloudef/zig-router) — Straightforward HTTP-like request routing library for Zig
* [zig-webui](https://github.com/webui-dev/zig-webui/) — Zig library that allows using any web browser as a GUI
* [Zine](https://github.com/kristoff-it/zine) — Fast, scalable, flexible static site generator (SSG) written in Zig
* [Zinc](https://github.com/zon-dev/zinc/) — Web framework written in pure Zig with focus on high performance, usability, security, and extensibility
* [zUI](https://github.com/thienpow/zui) — UI kit for Jetzig framework with reusable components and styles

## Contributing

Contributions are welcome! Currently trying out ZX and reporting issues for edge cases and providing feedback are greatly appreciated.
