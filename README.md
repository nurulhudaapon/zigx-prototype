# ZigX

A Zig library for building web applications with JSX-like syntax.

## Building

```bash
zig build
```

## Usage

#### Transpiling

```bash
zig build run -- transpile site --output site/.zigx
```

#### Syntaxes

##### For Loops
```zigx
<section>
    {for (chars) |char| (<span>{[char:c]}</span>)}
</section>
```
to 

```zig
_zx.zx(.section, .{ .children = blk: {
        const children = allocator.alloc(zx.Component, chars.len) catch unreachable;
        for (children, 0..) |*child, i| {
            child.* = _zx.zx(.span, .{
                .children = &.{
                    _zx.fmt("{c}", .{chars[i]}),
                },
            });
        }
        break :blk children;
    } }),
```