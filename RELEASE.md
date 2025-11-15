This is a developer preview of ZX, some features are work in progress.

## Installation

##### Linux/MacOS
```bash
curl -fsSL https://ziex.dev/install | bash
```
##### Windows
```powershell
powershell -c "irm ziex.dev/install.ps1 | iex"
```

## Feature Checklist

- [x] Server Side Rendering (SSR)
- [ ] Static Site Generation (SSG)
- [ ] Client Side Rendering (CSR) via WebAssembly
- [ ] Client Side Rendering (CSR) via React
- [x] Type Safety
- [x] Routing
    - [x] File-system Routing
    - [ ] Search Parameters
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
    - [ ] `fmt` Format the ZX source code
    - [ ] `export --container` Generate containerizable assets
    - [ ] `export --ssg` Generate static site assets
    - [x] `version` Show the version of the ZX CLI
    - [ ] `revision` Show the current revision of the ZX CLI

