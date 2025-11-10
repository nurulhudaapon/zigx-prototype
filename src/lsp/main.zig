//! Implements a language server using the `lsp.basic_server` abstraction.
//! This server forwards all requests and notifications to zls (Zig Language Server).

// Increase comptime branch quota BEFORE importing libraries
// This is needed because basic_server analyzes all handler methods at comptime
comptime {
    @setEvalBranchQuota(100_000);
}

const std = @import("std");
const builtin = @import("builtin");
const zls = @import("zls");
const lsp = zls.lsp;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

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

    const zls_server = zls.Server.create(.{
        .allocator = gpa,
        .transport = transport, // zls doesn't need transport, we just forward requests
        .config = null,
        // .config = &zls.Config{
        //     .builtin_path = "/Users/nurulhudaapon/Library/Caches/zls/builtin.zig",
        //     .zig_lib_path = "/Users/nurulhudaapon/.asdf/installs/zig/0.15.2/lib",
        //     .zig_exe_path = "/Users/nurulhudaapon/.asdf/shims/zig",
        //     .build_runner_path = "/Users/nurulhudaapon/Library/Caches/zls/build_runner/cf46548b062a7e79e448e80c05616097/build_runner.zig",
        //     .global_cache_path = "/Users/nurulhudaapon/Library/Caches/zls",
        // },
    }) catch unreachable;

    // The handler is a user provided type that stores the state of the
    // language server and provides callbacks for the desired LSP messages.
    var handler: Handler = .init(gpa, zls_server);
    defer handler.deinit();

    // try lsp.basic_server.run(
    //     gpa,
    //     transport,
    //     &handler,
    //     std.log.err,
    // );

    try zls_server.loop();
}

pub const Handler = struct {
    allocator: std.mem.Allocator,
    zls: *zls.Server,
    offset_encoding: lsp.offsets.Encoding,

    fn init(allocator: std.mem.Allocator, zls_server: *zls.Server) Handler {
        return .{
            .allocator = allocator,
            .zls = zls_server,
            .offset_encoding = .@"utf-16",
        };
    }

    fn deinit(handler: *Handler) void {
        zls.Server.destroy(handler.zls);
        handler.* = undefined;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#initialize
    pub fn initialize(
        handler: *Handler,
        arena: std.mem.Allocator,
        request: lsp.types.InitializeParams,
    ) lsp.types.InitializeResult {
        const result = handler.zls.sendRequestSync(arena, "initialize", request) catch |err| {
            std.log.err("zls initialize failed: {}", .{err});
            return .{
                .serverInfo = .{ .name = "zxls", .version = "0.1.0" },
                .capabilities = .{},
            };
        };

        // sendRequestSync returns the result directly (not optional) for initialize
        if (result.capabilities.positionEncoding) |encoding| {
            handler.offset_encoding = switch (encoding) {
                .@"utf-8" => .@"utf-8",
                .@"utf-16" => .@"utf-16",
                .@"utf-32" => .@"utf-32",
                .custom_value => .@"utf-16", // fallback to utf-16 for custom encodings
            };
        }
        return result;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#initialized
    pub fn initialized(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.InitializedParams,
    ) void {
        handler.zls.sendNotificationSync(arena, "initialized", params) catch {};
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#shutdown
    pub fn shutdown(
        handler: *Handler,
        arena: std.mem.Allocator,
        _: void,
    ) ?void {
        return handler.zls.sendRequestSync(arena, "shutdown", {}) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#exit
    pub fn exit(
        handler: *Handler,
        arena: std.mem.Allocator,
        _: void,
    ) void {
        handler.zls.sendNotificationSync(arena, "exit", {}) catch {};
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didOpen
    pub fn @"textDocument/didOpen"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DidOpenTextDocumentParams,
    ) !void {
        handler.zls.sendNotificationSync(arena, "textDocument/didOpen", params) catch {};
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didChange
    pub fn @"textDocument/didChange"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DidChangeTextDocumentParams,
    ) !void {
        handler.zls.sendNotificationSync(arena, "textDocument/didChange", params) catch {};
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didSave
    pub fn @"textDocument/didSave"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DidSaveTextDocumentParams,
    ) !void {
        handler.zls.sendNotificationSync(arena, "textDocument/didSave", params) catch {};
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_didClose
    pub fn @"textDocument/didClose"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DidCloseTextDocumentParams,
    ) !void {
        handler.zls.sendNotificationSync(arena, "textDocument/didClose", params) catch {};
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_willSaveWaitUntil
    pub fn @"textDocument/willSaveWaitUntil"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.WillSaveTextDocumentParams,
    ) error{OutOfMemory}!?[]const lsp.types.TextEdit {
        const result = handler.zls.sendRequestSync(arena, "textDocument/willSaveWaitUntil", params) catch null;
        return result;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_semanticTokens_full
    pub fn @"textDocument/semanticTokens/full"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.SemanticTokensParams,
    ) error{OutOfMemory}!?lsp.types.SemanticTokens {
        return handler.zls.sendRequestSync(arena, "textDocument/semanticTokens/full", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_semanticTokens_range
    pub fn @"textDocument/semanticTokens/range"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.SemanticTokensRangeParams,
    ) error{OutOfMemory}!?lsp.types.SemanticTokens {
        return handler.zls.sendRequestSync(arena, "textDocument/semanticTokens/range", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_inlayHint
    pub fn @"textDocument/inlayHint"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.InlayHintParams,
    ) error{OutOfMemory}!?[]const lsp.types.InlayHint {
        const result = handler.zls.sendRequestSync(arena, "textDocument/inlayHint", params) catch null;
        return result;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_completion
    pub fn @"textDocument/completion"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.CompletionParams,
    ) error{OutOfMemory}!lsp.ResultType("textDocument/completion") {
        return handler.zls.sendRequestSync(arena, "textDocument/completion", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_signatureHelp
    pub fn @"textDocument/signatureHelp"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.SignatureHelpParams,
    ) error{OutOfMemory}!?lsp.types.SignatureHelp {
        return handler.zls.sendRequestSync(arena, "textDocument/signatureHelp", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_definition
    pub fn @"textDocument/definition"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DefinitionParams,
    ) error{OutOfMemory}!lsp.ResultType("textDocument/definition") {
        return handler.zls.sendRequestSync(arena, "textDocument/definition", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_typeDefinition
    pub fn @"textDocument/typeDefinition"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.TypeDefinitionParams,
    ) error{OutOfMemory}!lsp.ResultType("textDocument/typeDefinition") {
        return handler.zls.sendRequestSync(arena, "textDocument/typeDefinition", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_implementation
    pub fn @"textDocument/implementation"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.ImplementationParams,
    ) error{OutOfMemory}!lsp.ResultType("textDocument/implementation") {
        return handler.zls.sendRequestSync(arena, "textDocument/implementation", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_declaration
    pub fn @"textDocument/declaration"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DeclarationParams,
    ) error{OutOfMemory}!lsp.ResultType("textDocument/declaration") {
        return handler.zls.sendRequestSync(arena, "textDocument/declaration", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_hover
    pub fn @"textDocument/hover"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.HoverParams,
    ) ?lsp.types.Hover {
        return handler.zls.sendRequestSync(arena, "textDocument/hover", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_documentSymbol
    pub fn @"textDocument/documentSymbol"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DocumentSymbolParams,
    ) error{OutOfMemory}!lsp.ResultType("textDocument/documentSymbol") {
        return handler.zls.sendRequestSync(arena, "textDocument/documentSymbol", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_formatting
    pub fn @"textDocument/formatting"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DocumentFormattingParams,
    ) error{OutOfMemory}!?[]const lsp.types.TextEdit {
        const result = handler.zls.sendRequestSync(arena, "textDocument/formatting", params) catch null;
        return result;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_rename
    pub fn @"textDocument/rename"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.RenameParams,
    ) error{OutOfMemory}!?lsp.types.WorkspaceEdit {
        return handler.zls.sendRequestSync(arena, "textDocument/rename", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_prepareRename
    pub fn @"textDocument/prepareRename"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.PrepareRenameParams,
    ) ?lsp.types.PrepareRenameResult {
        return handler.zls.sendRequestSync(arena, "textDocument/prepareRename", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_references
    pub fn @"textDocument/references"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.ReferenceParams,
    ) error{OutOfMemory}!?[]const lsp.types.Location {
        const result = handler.zls.sendRequestSync(arena, "textDocument/references", params) catch null;
        return result;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_documentHighlight
    pub fn @"textDocument/documentHighlight"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DocumentHighlightParams,
    ) error{OutOfMemory}!?[]const lsp.types.DocumentHighlight {
        const result = handler.zls.sendRequestSync(arena, "textDocument/documentHighlight", params) catch null;
        return result;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_codeAction
    pub fn @"textDocument/codeAction"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.CodeActionParams,
    ) error{OutOfMemory}!lsp.ResultType("textDocument/codeAction") {
        return handler.zls.sendRequestSync(arena, "textDocument/codeAction", params) catch null;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_foldingRange
    pub fn @"textDocument/foldingRange"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.FoldingRangeParams,
    ) error{OutOfMemory}!?[]const lsp.types.FoldingRange {
        const result = handler.zls.sendRequestSync(arena, "textDocument/foldingRange", params) catch null;
        return result;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_selectionRange
    pub fn @"textDocument/selectionRange"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.SelectionRangeParams,
    ) error{OutOfMemory}!?[]const lsp.types.SelectionRange {
        const result = handler.zls.sendRequestSync(arena, "textDocument/selectionRange", params) catch null;
        return result;
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#workspace_didChangeWatchedFiles
    pub fn @"workspace/didChangeWatchedFiles"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DidChangeWatchedFilesParams,
    ) !void {
        handler.zls.sendNotificationSync(arena, "workspace/didChangeWatchedFiles", params) catch {};
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#workspace_didChangeWorkspaceFolders
    pub fn @"workspace/didChangeWorkspaceFolders"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DidChangeWorkspaceFoldersParams,
    ) !void {
        handler.zls.sendNotificationSync(arena, "workspace/didChangeWorkspaceFolders", params) catch {};
    }

    /// https://microsoft.github.io/language-server-protocol/specifications/specification-current/#workspace_didChangeConfiguration
    pub fn @"workspace/didChangeConfiguration"(
        handler: *Handler,
        arena: std.mem.Allocator,
        params: lsp.types.DidChangeConfigurationParams,
    ) !void {
        handler.zls.sendNotificationSync(arena, "workspace/didChangeConfiguration", params) catch {};
    }

    /// We received a response message from the client/editor.
    pub fn onResponse(
        _: *Handler,
        _: std.mem.Allocator,
        _: lsp.JsonRPCMessage.Response,
    ) void {
        // zls handles responses internally
    }
};
