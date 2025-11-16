This is a developer preview of ZX, some features are work in progress.

## Changelog
- `zx export` for generating static site assets

## Installation

##### Linux/macOS
```bash
curl -fsSL https://ziex.dev/install | bash
```
##### Windows
```powershell
powershell -c "irm ziex.dev/install.ps1 | iex"
```

## Feature Checklist

- [x] Server Side Rendering (SSR)
- [x] Static Site Generation (SSG)
- [ ] Client Side Rendering (CSR) via WebAssembly
- [ ] Client Side Rendering (CSR) via React
- [x] Type Safety
- [x] Routing
    - [x] File-system Routing
    - [x] Search Parameters
    - [ ] Path Segments
- [x] Components
- [x] Control Flow
    - [ ] `if`
    - [ ] `if` nested
    - [x] `if/else`
    - [x] `if/else` nested
    - [x] `for`
    - [x] `for` nested
    - [x] `switch`
    - [x] `switch` nested
    - [ ] `while`
    - [ ] `while` nested
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
- [ ] CLI
    - [x] `init` Project Template
    - [x] `transpile` Transpile .zx files to Zig source code
    - [x] `serve` Serve the project
    - [ ] `dev` HMR or Rebuild on Change
    - [x] `fmt` Format the ZX source code (_Alpha_)
    - [ ] `export --container` Generate containerizable assets
    - [x] `export --ssg` Generate static site assets
    - [x] `version` Show the version of the ZX CLI
    - [ ] `revision` Show the current revision of the ZX CLI

