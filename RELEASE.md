This is a developer preview of ZX, some features are work in progress.

## Installation

#### Linux/MacOS
```bash
curl -fsSL https://ziex.dev/install | bash
```

#### Windows
```powershell
powershell -c "irm ziex.dev/install.ps1 | iex"
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
- [x] CLI
- [ ] Dev Server (HMR or Rebuild on Change)
