pub const TestFileCache = struct {
    files: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    pub const test_files = [_][]const u8{
        // Control Flow
        "control_flow/if",
        "control_flow/if_block",
        "control_flow/if_only",
        "control_flow/if_only_block",
        "control_flow/for",
        "control_flow/for_block",
        "control_flow/switch",
        "control_flow/switch_block",
        // Nested Control Flow (2-level nesting)
        "control_flow/if_if",
        "control_flow/if_for",
        "control_flow/if_switch",
        // "control_flow/if_if_only_block",
        // "control_flow/if_only_block",
        "control_flow/for_if",
        "control_flow/for_for",
        "control_flow/for_switch",
        "control_flow/switch_if",
        "control_flow/switch_for",
        "control_flow/switch_switch",
        "control_flow/while",
        "control_flow/while_block",
        // Expression
        "expression/text",
        "expression/format",
        "expression/component",
        // Component
        "component/basic",
        "component/multiple",
        "component/csr_react",
        "component/csr_react_multiple",
    };
    pub fn init(allocator: std.mem.Allocator) !TestFileCache {
        var cache = TestFileCache{
            .files = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };

        const base_path = "test/data/";

        // Load both .zx and .zig files for each test file
        for (test_files) |file_path| {
            for ([_]struct { ext: []const u8 }{ .{ .ext = ".zx" }, .{ .ext = ".zig" } }) |ext_info| {
                const full_path = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ base_path, file_path, ext_info.ext });
                defer allocator.free(full_path);

                const content = std.fs.cwd().readFileAlloc(
                    allocator,
                    full_path,
                    std.math.maxInt(usize),
                ) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                const cache_key = try std.fmt.allocPrint(allocator, "{s}{s}", .{ file_path, ext_info.ext });
                try cache.files.put(cache_key, content);
            }
        }

        return cache;
    }

    pub fn deinit(self: *TestFileCache) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit();
    }

    pub fn get(self: *const TestFileCache, path: []const u8) ?[]const u8 {
        return self.files.get(path);
    }
};

const std = @import("std");
const testing = std.testing;
const zx = @import("zx");
