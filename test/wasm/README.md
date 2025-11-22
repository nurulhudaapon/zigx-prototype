# Running the WASM Example

From this directory (test/wasm), run:
```bash
# test/wasm
zig build --watch
```

In another terminal, run:
```bash
# test/wasm
bun dev
```

This will start the development server at `http://localhost:3000`.

The WASM file will be built and served at `http://localhost:3000/main.wasm`.