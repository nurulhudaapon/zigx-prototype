# ZigX Transpiler

A simple transpiler written in Zig 0.15.1 that converts JSX-like `.zigx` syntax to regular Zig code.

## Features

- Converts JSX-like syntax to `zigx.Element` structures
- Handles nested elements with proper indentation
- Supports text expressions using `.{variable}` syntax
- Preserves non-transpiled code unchanged

## Building

```bash
zig build-exe src/zigx_transpiler.zig -femit-bin=zig-out/bin/zigx_transpiler
```

## Usage

```bash
./zig-out/bin/zigx_transpiler <input.zigx> <output.zig>
```

### Example

Input file (`src/zigx_raw.zigx`):
```zig
const std = @import("std");
const zigx = @import("root.zig");

pub fn Button() []const u8 {
    const btn_title = "Click me";

    return .{ <button>.{btn_title}<span><text>.{btn_title}</text></span></button> };
}
```

Command:
```bash
./zig-out/bin/zigx_transpiler src/zigx_raw.zigx src/zigx_transpiled.zig
```

Output file (`src/zigx_transpiled.zig`):
```zig
const std = @import("std");
const zigx = @import("root.zig");

pub fn Button() []const u8 {
    const btn_title = "Click me";

    return (zigx.Element{
        .tag = "button",
        .text = btn_title,
        .children = &[_]zigx.Element{
            .{
                .tag = "span",
                .children = &[_]zigx.Element{
                    .{
                        .tag = "text",
                        .text = btn_title,
                    },
                },
            },
        },
    }).render();
}
```

## Syntax

The transpiler recognizes JSX-like syntax within `.{ }` blocks:

- `<tag>` - Opening tag
- `</tag>` - Closing tag
- `.{variable}` - Text expression that references a variable
- Nested elements are supported

## Running the Example

```bash
# Build and run the example
zig run src/main.zig

# Output: <button>Click me<span><text>Click me</text></span></button>
```

## Project Structure

- `src/zigx_transpiler.zig` - The transpiler implementation
- `src/zigx_raw.zigx` - Example input file with JSX-like syntax
- `src/zigx_transpiled.zig` - Example output file with transpiled Zig code
- `src/root.zig` - Element struct definition and render function
- `src/main.zig` - Example usage

