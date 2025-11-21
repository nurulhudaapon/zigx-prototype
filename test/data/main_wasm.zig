// Client-side Zig (csz) components
// This file will be implemented later

const std = @import("std");
const zx = @import("zx");

pub const ComponentMetadata = struct {
    type: zx.Ast.ClientComponentMetadata.Type,
    id: []const u8,
    name: []const u8,
    path: []const u8,
    import: fn (allocator: std.mem.Allocator) zx.Component,
};

// Static array of component metadata
// The placeholder below will be replaced with the actual Zig array literal
pub const components = [_]ComponentMetadata{.{.{
    .type = .csz,
    .id = "zx-3badae80b344e955a3048888ed2aae42",
    .name = "CounterComponent",
    .path = "component/csr_zig.zig",
    .import = @import("component/csr_zig.zig").CounterComponent,
}}};

// TODO: Implement WASM component loading and rendering logic here
// Use the components array to initialize and render WASM components
