const Metadata = @import("meta.zig");
const std = @import("std");
const zx = @import("zx");
const httpz = @import("httpz");
const Page = @import("page.zig").Page;
const Layout = @import("layout.zig").Layout;

// Global thread pool shared across all requests
var global_thread_pool: std.Thread.Pool = undefined;
var thread_pool_initialized = false;
var thread_pool_mutex = std.Thread.Mutex{};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Initialize global thread pool
    try global_thread_pool.init(.{ .allocator = std.heap.page_allocator });
    thread_pool_initialized = true;
    defer global_thread_pool.deinit();

    var server = try httpz.Server(void).init(allocator, .{ .port = 3002 }, {});
    var router = try server.router(.{});
    router.get("/", index, .{});

    defer {
        server.stop();
        server.deinit();
    }
    std.debug.print("Server is running on port 3002\n", .{});
    try server.listen();
}

const Handler = struct {
    pub fn handle(_: *Handler, req: *httpz.Request, res: *httpz.Response) void {
        const app = zx.App.init(.{ .routes = &Metadata.routes });
        const error_body = app.handle(req.arena, &res.buffer.writer, req.url.path) catch {
            res.body = "Internal Server Error";
            return;
        };

        if (error_body) |body| {
            res.body = body;
        }
    }
};

fn index(req: *httpz.Request, res: *httpz.Response) !void {
    // const wait_time = 1_000_000_000; // 1 second

    // try res.chunk(
    //     \\<!DOCTYPE html>
    //     \\<html>
    //     \\  <body>
    //     \\      <template shadowrootmode="open">
    //     \\          <ul>
    //     \\              <li><slot name="item-0">Loading...</slot></li>
    //     \\              <li><slot name="item-1">Loading...</slot></li>
    //     \\              <li><slot name="item-2">Loading...</slot></li>
    //     \\          </ul>
    //     \\      </template>
    //     \\  </body>
    //     \\</html>
    // );
    // std.Thread.sleep(wait_time);
    // try res.chunk("\n<span slot='item-2'>Item 2</span>");
    // std.Thread.sleep(wait_time);
    // try res.chunk("\n<span slot='item-0'>Item 0</span>");
    // std.Thread.sleep(wait_time);
    // try res.chunk("\n<span slot='item-1'>Item 1</span>");
    // var i: u32 = 0;
    // while (i < 10) {
    //     std.Thread.sleep(1_000_000_000); // 1 second
    //     const str = std.fmt.allocPrint(res.arena, "<span slot='item-{d}'>Item {d}</span>", .{ i, i }) catch unreachable;
    //     try res.chunk(str);
    //     i += 1;
    // }

    // try Page(res.arena).action(req, req, res);

    var aw: std.Io.Writer.Allocating = .init(res.arena);
    std.debug.print("Start compiling shell\n", .{});
    // Use page_allocator for lazy components so they're thread-safe
    const slots = try Page(std.heap.page_allocator).stream(res.arena, &aw.writer);
    std.debug.print("Shell compiled\nFound {d} slots\n", .{slots.len});

    // Send the static shell
    res.chunk(aw.written()) catch |err| {
        std.debug.print("Failed to send initial shell, client may have disconnected: {}\n", .{err});
        return;
    };
    aw.clearRetainingCapacity();

    // Render slots in parallel with global thread pool
    if (slots.len > 0 and thread_pool_initialized) {
        var wait_group = std.Thread.WaitGroup{};
        var mutex = std.Thread.Mutex{};

        // Allocate results with page_allocator for thread safety
        var results = try std.heap.page_allocator.alloc(SlotRenderResult, slots.len);
        defer std.heap.page_allocator.free(results);

        var streamed = try std.heap.page_allocator.alloc(bool, slots.len);
        defer std.heap.page_allocator.free(streamed);
        @memset(streamed, false);

        // Initialize results
        for (results, 0..) |*result, i| {
            result.* = .{ .data = &.{}, .index = i, .done = false, .writer = null };
        }

        // Submit slot render tasks to global pool
        for (slots, 0..) |slot, i| {
            const ctx = try std.heap.page_allocator.create(SlotRenderTask);
            ctx.* = .{
                .slot = slot,
                .result = &results[i],
                .mutex = &mutex,
                .wait_group = &wait_group,
            };

            wait_group.start();
            try global_thread_pool.spawn(renderSlotTask, .{ctx});
        }

        // Stream results as they complete
        var completed: usize = 0;
        var connection_closed = false;
        while (completed < slots.len and !connection_closed) {
            for (results, 0..) |*result, i| {
                if (streamed[i]) continue;

                mutex.lock();
                const is_done = result.done;
                mutex.unlock();

                if (is_done) {
                    // Copy data to response arena before streaming
                    mutex.lock();
                    const data = result.data;
                    const data_copy = res.arena.dupe(u8, data) catch {
                        mutex.unlock();
                        continue;
                    };
                    mutex.unlock();

                    std.debug.print("Streaming slot {d} of {d}\n", .{ i + 1, slots.len });
                    // Handle write failures gracefully (e.g., client disconnected)
                    res.chunk(data_copy) catch |err| {
                        std.debug.print("Connection closed while streaming slot {d}: {}\n", .{ i + 1, err });
                        connection_closed = true;
                        break;
                    };
                    streamed[i] = true;
                    completed += 1;
                }
            }
            if (completed < slots.len and !connection_closed) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
        
        if (connection_closed) {
            std.debug.print("Client disconnected, stopped streaming after {d}/{d} slots\n", .{ completed, slots.len });
        }

        // Wait for all tasks to complete
        global_thread_pool.waitAndWork(&wait_group);

        // Cleanup: deinit and free all writers
        for (results) |result| {
            if (result.writer) |writer| {
                writer.deinit();
                std.heap.page_allocator.destroy(writer);
            }
        }
    }

    _ = req;
}

const SlotRenderResult = struct {
    data: []u8,
    index: usize,
    done: bool,
    writer: ?*std.Io.Writer.Allocating = null,
};

const SlotRenderTask = struct {
    slot: zx.Component,
    result: *SlotRenderResult,
    mutex: *std.Thread.Mutex,
    wait_group: *std.Thread.WaitGroup,
};

fn renderSlotTask(task: *SlotRenderTask) void {
    // Save wait_group pointer before potentially freeing task
    const wait_group = task.wait_group;
    defer wait_group.finish();
    defer std.heap.page_allocator.destroy(task);

    // Allocate writer on heap so it persists
    const aw = std.heap.page_allocator.create(std.Io.Writer.Allocating) catch {
        std.debug.print("Failed to allocate writer\n", .{});
        return;
    };
    aw.* = .init(std.heap.page_allocator);

    task.slot.render(&aw.writer) catch |err| {
        std.debug.print("Error rendering slot: {}\n", .{err});
        aw.deinit();
        std.heap.page_allocator.destroy(aw);
        return;
    };

    const data = aw.written();

    task.mutex.lock();
    defer task.mutex.unlock();
    task.result.data = data;
    task.result.writer = aw;
    task.result.done = true;
}
