//! Implements a language server using the `lsp.basic_server` abstraction.

const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
var log_transport: ?lsp.AnyTransport = null;

pub fn main() !void {
    const gpa, const is_debug = switch (builtin.mode) {
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
        .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    // LSP implementations typically communicate over stdio (stdin and stdout)
    var read_buffer: [256]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    const transport: *lsp.Transport = &stdio_transport.transport;

    // The handler is a user provided type that stores the state of the
    // language server and provides callbacks for the desired LSP messages.
    var handler: Handler = .init(gpa);
    defer handler.deinit();

    try lsp.basic_server.run(
        gpa,
        transport,
        &handler,
        std.log.err,
    );
}

// Most functions can be omitted if you are not interested them. A unhandled request will automatically return a 'null' response.

pub const Handler = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged([]u8),
    /// The LSP protocol specifies position inside a text document using a line and character pair.
    /// This field stores encoding is used for the character value (UTF-8, UTF-16, UTF-32).
    ///
    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocuments
    offset_encoding: lsp.offsets.Encoding,

    fn init(allocator: std.mem.Allocator) Handler {
        return .{
            .allocator = allocator,
            .files = .{},
            // The default position encoding is UTF-16.
            // The agreed upon encoding between server client is actually decided during `initialize`.
            .offset_encoding = .@"utf-16",
        };
    }

    fn deinit(handler: *Handler) void {
        var file_it = handler.files.iterator();
        while (file_it.next()) |entry| {
            handler.allocator.free(entry.key_ptr.*);
            handler.allocator.free(entry.value_ptr.*);
        }

        handler.files.deinit(handler.allocator);

        handler.* = undefined;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#initialize
    pub fn initialize(
        handler: *Handler,
        _: std.mem.Allocator,
        request: lsp.types.InitializeParams,
    ) lsp.types.InitializeResult {
        std.log.debug("Received 'initialize' message", .{});

        if (request.clientInfo) |client_info| {
            std.log.info("The client is '{s}' ({s})", .{ client_info.name, client_info.version orelse "unknown version" });
        }

        // Specifies which features are supported by the client/editor.
        const client_capabilities: lsp.types.ClientCapabilities = request.capabilities;

        // Pick the client's favorite character offset encoding.
        if (client_capabilities.general) |general| {
            for (general.positionEncodings orelse &.{}) |encoding| {
                handler.offset_encoding = switch (encoding) {
                    .@"utf-8" => .@"utf-8",
                    .@"utf-16" => .@"utf-16",
                    .@"utf-32" => .@"utf-32",
                    .custom_value => continue,
                };
                break;
            }
        }

        // Specifies which features are supported by the language server.
        const server_capabilities: lsp.types.ServerCapabilities = .{
            .positionEncoding = switch (handler.offset_encoding) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
            },
            .textDocumentSync = .{
                .TextDocumentSyncOptions = .{
                    .openClose = true,
                    .change = .Full,
                },
            },
            .hoverProvider = .{ .bool = true },
            .completionProvider = .{ .triggerCharacters = &.{"."} },
        };

        // Tries to validate that our server capabilities are actually implemented.
        if (@import("builtin").mode == .Debug) {
            lsp.basic_server.validateServerCapabilities(Handler, server_capabilities);
        }

        return .{
            .serverInfo = .{
                .name = "My first LSP",
                .version = "0.1.0",
            },
            .capabilities = server_capabilities,
        };
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#initialized
    pub fn initialized(
        _: *Handler,
        _: std.mem.Allocator,
        _: lsp.types.InitializedParams,
    ) void {
        std.log.debug("Received 'initialized' notification", .{});
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#shutdown
    pub fn shutdown(
        _: *Handler,
        _: std.mem.Allocator,
        _: void,
    ) ?void {
        std.log.debug("Received 'shutdown' request", .{});
        return null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#exit
    /// The `lsp.basic_server.run` function will automatically return after this function completes.
    pub fn exit(
        _: *Handler,
        _: std.mem.Allocator,
        _: void,
    ) void {
        std.log.debug("Received 'exit' notification", .{});
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didOpen
    pub fn @"textDocument/didOpen"(
        self: *Handler,
        _: std.mem.Allocator,
        notification: lsp.types.DidOpenTextDocumentParams,
    ) !void {
        std.log.debug("Received 'textDocument/didOpen' notification", .{});

        const new_text = try self.allocator.dupe(u8, notification.textDocument.text);
        errdefer self.allocator.free(new_text);

        const gop = try self.files.getOrPut(self.allocator, notification.textDocument.uri);

        if (gop.found_existing) {
            std.log.warn("Document opened twice: '{s}'", .{notification.textDocument.uri});
            self.allocator.free(gop.value_ptr.*);
        } else {
            errdefer std.debug.assert(self.files.remove(notification.textDocument.uri));
            gop.key_ptr.* = try self.allocator.dupe(u8, notification.textDocument.uri);
        }

        gop.value_ptr.* = new_text;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didChange
    pub fn @"textDocument/didChange"(
        self: *Handler,
        _: std.mem.Allocator,
        notification: lsp.types.DidChangeTextDocumentParams,
    ) !void {
        std.log.debug("Received 'textDocument/didChange' notification", .{});

        const current_text = self.files.getPtr(notification.textDocument.uri) orelse {
            std.log.warn("Modifying non existent Document: '{s}'", .{notification.textDocument.uri});
            return;
        };

        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buffer.deinit(self.allocator);

        try buffer.appendSlice(self.allocator, current_text.*);

        for (notification.contentChanges) |content_change| {
            switch (content_change) {
                .literal_1 => |change| {
                    buffer.clearRetainingCapacity();
                    try buffer.appendSlice(self.allocator, change.text);
                },
                .literal_0 => |change| {
                    const loc = lsp.offsets.rangeToLoc(buffer.items, change.range, self.offset_encoding);
                    try buffer.replaceRange(self.allocator, loc.start, loc.end - loc.start, change.text);
                },
            }
        }

        const new_text = try buffer.toOwnedSlice(self.allocator);
        self.allocator.free(current_text.*);
        current_text.* = new_text;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didClose
    pub fn @"textDocument/didClose"(
        self: *Handler,
        _: std.mem.Allocator,
        notification: lsp.types.DidCloseTextDocumentParams,
    ) !void {
        std.log.debug("Received 'textDocument/didClose' notification", .{});

        const entry = self.files.fetchRemove(notification.textDocument.uri) orelse {
            std.log.warn("Closing non existent Document: '{s}'", .{notification.textDocument.uri});
            return;
        };
        self.allocator.free(entry.key);
        self.allocator.free(entry.value);
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_hover
    ///
    /// This function can be omitted if you are not interested in this request. A `null` response will be automatically send back.
    pub fn @"textDocument/hover"(
        handler: *Handler,
        _: std.mem.Allocator,
        params: lsp.types.HoverParams,
    ) ?lsp.types.Hover {
        std.log.debug("Received 'textDocument/hover' request", .{});

        const source = handler.files.get(params.textDocument.uri) orelse
            return null; // We should actually read the document from the file system

        const source_index = lsp.offsets.positionToIndex(source, params.position, handler.offset_encoding);
        std.log.debug("Hover position: line={d}, character={d}, index={d}", .{ params.position.line, params.position.character, source_index });

        return .{
            .contents = .{
                .MarkupContent = .{
                    .kind = .plaintext,
                    .value = "I don't know what you are hovering over but I'd like to point out that you have a nice editor theme",
                },
            },
        };
    }

    pub fn @"textDocument/completion"(
        _: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.CompletionParams,
    ) error{OutOfMemory}!lsp.ResultType("textDocument/completion") {
        std.log.debug("Received 'textDocument/completion' notification", .{});

        if (params.context) |context| {
            std.log.info("completion triggered by {?s} {t}", .{
                context.triggerCharacter,
                context.triggerKind,
            });
        }

        const completions = try arena.dupe(lsp.types.CompletionItem, &.{
            .{
                .label = "get",
                .detail = "get the value",
            },
            .{
                .label = "set",
                .detail = "set the value",
            },
        });
        return .{ .array_of_CompletionItem = completions };
    }

    /// We received a response message from the client/editor.
    pub fn onResponse(
        _: *Handler,
        _: std.mem.Allocator,
        response: lsp.JsonRPCMessage.Response,
    ) void {
        // We didn't make any requests to the client/editor.
        std.log.warn("received unexpected response from client with id '{?}'!", .{response.id});
    }
};
