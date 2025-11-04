# Zx

A Zig library for building web applications with JSX-like syntax.

## Building

```bash
zig build
```

## Usage

#### Transpiling

```bash
zig build run -- transpile site --output site/.zx
```

#### Syntaxes

##### For Loops
```zx
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

##### Switch Statements
```zx
<section>
    {switch (user.user_type) {
        .admin => ("Admin"),
        .member => ("Member"),
    }}
    {switch (user.user_type) {
        .admin => (<p>Admin</p>),
        .member => (<p>Member</p>),
    }}
</section>
```
to

```zig
_zx.zx(.section, .{ .children = &.{
switch (user.user_type) {
    .admin => _zx.txt("Admin"),
    .member => _zx.txt("Member"),
},
switch (user.user_type) {
    .admin => _zx.zx(.p, .{ .children = &.{_zx.txt("Admin")} }),
    .member => _zx.zx(.p, .{ .children = &.{_zx.txt("Member")} }),
},
}),
```