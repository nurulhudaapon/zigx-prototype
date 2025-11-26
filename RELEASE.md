This is a developer preview of ZX, some features are work in progress.

## Installation

##### Linux/macOS
```bash
curl -fsSL https://ziex.dev/install | bash
```
##### Windows
```powershell
powershell -c "irm ziex.dev/install.ps1 | iex"
```

## Changelog
- feat: more nested control flow support
- feat: if only support

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
- [ ] CLI
    - [x] `init` Project Template
    - [x] `transpile` Transpile .zx files to Zig source code
    - [x] `serve` Serve the project
    - [x] `dev` HMR or Rebuild on Change
    - [x] `fmt` Format the ZX source code (_Alpha_)
    - [x] `export` Generate static site assets
    - [ ] `bundle` Bundle the ZX executable with public/assets and exe
    - [x] `version` Show the version of the ZX CLI
    - [x] `update` Update the version of ZX dependency
    - [x] `upgrade` Upgrade the version of ZX CLI

