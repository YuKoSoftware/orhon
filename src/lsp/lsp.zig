// lsp.zig — Orhon Language Server Protocol
// JSON-RPC over stdio. Server loop, transport, and dispatch.
// Handler implementations live in lsp_nav, lsp_edit, lsp_view, lsp_semantic.

const std = @import("std");
const lsp_types = @import("lsp_types.zig");
const lsp_json = @import("lsp_json.zig");
const lsp_utils = @import("lsp_utils.zig");
const lsp_analysis = @import("lsp_analysis.zig");
const lsp_nav = @import("lsp_nav.zig");
const lsp_edit = @import("lsp_edit.zig");
const lsp_view = @import("lsp_view.zig");
const lsp_semantic = @import("lsp_semantic.zig");

const Diagnostic = lsp_types.Diagnostic;
const SymbolInfo = lsp_types.SymbolInfo;
const PublishResult = lsp_types.PublishResult;

const jsonStr = lsp_json.jsonStr;
const jsonObj = lsp_json.jsonObj;
const jsonInt = lsp_json.jsonInt;
const jsonArray = lsp_json.jsonArray;
const jsonBool = lsp_json.jsonBool;
const jsonId = lsp_json.jsonId;
const writeJsonValue = lsp_json.writeJsonValue;
const buildInitializeResult = lsp_json.buildInitializeResult;
const buildEmptyArrayResponse = lsp_json.buildEmptyArrayResponse;
const buildEmptyResponse = lsp_json.buildEmptyResponse;
const buildDiagnosticsMsg = lsp_json.buildDiagnosticsMsg;

const Io = std.Io;

// ============================================================
// METHOD DISPATCH
// ============================================================

const Method = enum {
    initialize,
    initialized,
    shutdown,
    exit,
    did_open,
    did_save,
    did_change,
    did_close,
    hover,
    definition,
    document_symbol,
    completion,
    references,
    rename,
    signature_help,
    formatting,
    workspace_symbol,
    code_action,
    inlay_hint,
    document_highlight,
    folding_range,
    semantic_tokens,
};

const METHOD_MAP = std.StaticStringMap(Method).initComptime(.{
    .{ "initialize", .initialize },
    .{ "initialized", .initialized },
    .{ "shutdown", .shutdown },
    .{ "exit", .exit },
    .{ "textDocument/didOpen", .did_open },
    .{ "textDocument/didSave", .did_save },
    .{ "textDocument/didChange", .did_change },
    .{ "textDocument/didClose", .did_close },
    .{ "textDocument/hover", .hover },
    .{ "textDocument/definition", .definition },
    .{ "textDocument/documentSymbol", .document_symbol },
    .{ "textDocument/completion", .completion },
    .{ "textDocument/references", .references },
    .{ "textDocument/rename", .rename },
    .{ "textDocument/signatureHelp", .signature_help },
    .{ "textDocument/formatting", .formatting },
    .{ "workspace/symbol", .workspace_symbol },
    .{ "textDocument/codeAction", .code_action },
    .{ "textDocument/inlayHint", .inlay_hint },
    .{ "textDocument/documentHighlight", .document_highlight },
    .{ "textDocument/foldingRange", .folding_range },
    .{ "textDocument/semanticTokens/full", .semantic_tokens },
});

// ============================================================
// JSON-RPC TRANSPORT
// ============================================================

const MAX_HEADER_LINE: usize = lsp_types.MAX_HEADER_LINE;
const MAX_CONTENT_LENGTH: usize = lsp_types.MAX_CONTENT_LENGTH;

/// Read a single LSP message from stdin.
/// Format: "Content-Length: N\r\n\r\n<N bytes of JSON>"
fn readMessage(reader: *Io.Reader, allocator: std.mem.Allocator) ![]u8 {
    var content_length: usize = 0;

    // Read headers line by line
    while (true) {
        var line_buf: [MAX_HEADER_LINE]u8 = undefined;
        var line_len: usize = 0;

        while (line_len < line_buf.len) {
            const byte = reader.takeByte() catch return error.EndOfStream;
            if (byte == '\r') {
                _ = reader.takeByte() catch return error.EndOfStream;
                break;
            }
            line_buf[line_len] = byte;
            line_len += 1;
        }
        if (line_len == line_buf.len) return error.HeaderTooLong;

        const line = line_buf[0..line_len];
        if (line.len == 0) break;

        const prefix = "Content-Length: ";
        if (std.mem.startsWith(u8, line, prefix)) {
            content_length = std.fmt.parseInt(usize, line[prefix.len..], 10) catch return error.InvalidHeader;
        }
    }

    if (content_length == 0) return error.InvalidHeader;
    if (content_length > MAX_CONTENT_LENGTH) return error.InvalidHeader;
    return reader.readAlloc(allocator, content_length) catch return error.EndOfStream;
}

/// Write an LSP message to stdout.
fn writeMessage(writer: *Io.Writer, json: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{json.len});
    try writer.writeAll(json);
    try writer.flush();
}

/// Dispatch an LSP handler result: on success write response, on error log and send empty response.
fn dispatchLsp(allocator: std.mem.Allocator, writer: *Io.Writer, id: std.json.Value, method: []const u8, result: anyerror![]const u8) !void {
    const resp = result catch |err| {
        lspLog("{s} error: {}", .{ method, err });
        try writeMessage(writer, try buildEmptyResponse(allocator, id));
        return;
    };
    defer allocator.free(resp);
    try writeMessage(writer, resp);
}

/// Like dispatchLsp but sends an empty array `[]` on error instead of `null`.
fn dispatchLspArray(allocator: std.mem.Allocator, writer: *Io.Writer, id: std.json.Value, method: []const u8, result: anyerror![]const u8) !void {
    const resp = result catch |err| {
        lspLog("{s} error: {}", .{ method, err });
        try writeMessage(writer, try buildEmptyArrayResponse(allocator, id));
        return;
    };
    defer allocator.free(resp);
    try writeMessage(writer, resp);
}

const freeDiagnostics = lsp_types.freeDiagnostics;
const freeSymbols = lsp_types.freeSymbols;
const lspLog = lsp_utils.lspLog;
const uriToPath = lsp_utils.uriToPath;
const findProjectRoot = lsp_utils.findProjectRoot;
const runAnalysis = lsp_analysis.runAnalysis;

// ============================================================
// SERVER LOOP + DISPATCH
// ============================================================

pub fn serve(allocator: std.mem.Allocator) !void {
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var stdin_buf: [65536]u8 = undefined;
    var stdin_r = stdin_file.reader(&stdin_buf);
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var stdout_buf: [65536]u8 = undefined;
    var stdout_w = stdout_file.writer(&stdout_buf);

    const stdin: *Io.Reader = &stdin_r.interface;
    const stdout: *Io.Writer = &stdout_w.interface;

    lspLog("server starting", .{});

    var initialized = false;
    var project_root: ?[]const u8 = null;
    defer if (project_root) |r| allocator.free(r);

    // Client settings (from initializationOptions)
    var enable_inlay_hints = false;
    var enable_snippets = false;

    // Track open document URIs for clearing stale diagnostics
    var open_docs = std.StringHashMap(void).init(allocator);
    defer {
        var it = open_docs.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        open_docs.deinit();
    }

    // In-memory document content (updated on didOpen/didChange)
    var doc_store = std.StringHashMap([]u8).init(allocator);
    defer {
        var ds_it = doc_store.iterator();
        while (ds_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        doc_store.deinit();
    }

    // Cached diagnostics for code actions
    var cached_diags: []Diagnostic = &.{};
    defer freeDiagnostics(allocator, cached_diags);

    // Cached symbols from last analysis
    var cached_symbols: []SymbolInfo = &.{};
    defer freeSymbols(allocator, cached_symbols);

    while (true) {
        const body = readMessage(stdin, allocator) catch |err| {
            if (err == error.EndOfStream) { lspLog("client disconnected", .{}); return; }
            lspLog("read error: {}", .{err});
            continue;
        };
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            lspLog("invalid JSON", .{});
            continue;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const method_str = jsonStr(root, "method") orelse "";
        const id = jsonId(root);
        const m = METHOD_MAP.get(method_str) orelse {
            // Unknown request — respond with null result if it has an id
            switch (id) {
                .integer, .string => {
                    const resp = try buildEmptyResponse(allocator, id);
                    defer allocator.free(resp);
                    try writeMessage(stdout, resp);
                },
                else => {},
            }
            continue;
        };

        // All methods except lifecycle require initialization
        switch (m) {
            .initialize, .initialized, .shutdown, .exit => {},
            else => if (!initialized) continue,
        }

        switch (m) {
            .initialize => {
                lspLog("initialize", .{});
                if (jsonObj(root, "params")) |params| {
                    if (jsonStr(params, "rootUri")) |root_uri| {
                        if (uriToPath(root_uri)) |path| {
                            project_root = try allocator.dupe(u8, path);
                            lspLog("project root: {s}", .{path});
                        }
                    }
                    if (jsonObj(params, "initializationOptions")) |opts| {
                        enable_inlay_hints = jsonBool(opts, "inlayHints");
                        enable_snippets = jsonBool(opts, "completionSnippets");
                        lspLog("settings: inlayHints={}, snippets={}", .{ enable_inlay_hints, enable_snippets });
                    }
                }
                const resp = try buildInitializeResult(allocator, id);
                defer allocator.free(resp);
                try writeMessage(stdout, resp);
            },
            .initialized => {
                initialized = true;
                lspLog("initialized", .{});
                if (project_root) |r|
                    try analyzeAndCache(allocator, stdout, r, &open_docs, &cached_symbols, &cached_diags);
            },
            .shutdown => {
                lspLog("shutdown", .{});
                const resp = try buildEmptyResponse(allocator, id);
                defer allocator.free(resp);
                try writeMessage(stdout, resp);
            },
            .exit => {
                lspLog("exit", .{});
                return;
            },
            .did_open => {
                if (jsonObj(root, "params")) |params| {
                    if (jsonObj(params, "textDocument")) |td| {
                        if (jsonStr(td, "uri")) |uri| {
                            lspLog("didOpen: {s}", .{uri});
                            if (!open_docs.contains(uri))
                                try open_docs.put(try allocator.dupe(u8, uri), {});
                            if (jsonStr(td, "text")) |text|
                                try updateDocStore(&doc_store, allocator, uri, text);
                            if (project_root == null) {
                                if (uriToPath(uri)) |path| {
                                    if (findProjectRoot(path)) |r| {
                                        project_root = try allocator.dupe(u8, r);
                                        lspLog("detected root: {s}", .{r});
                                    }
                                }
                            }
                            if (project_root) |r|
                                try analyzeAndCache(allocator, stdout, r, &open_docs, &cached_symbols, &cached_diags);
                        }
                    }
                }
            },
            .did_save => {
                lspLog("didSave", .{});
                if (project_root) |r|
                    try analyzeAndCache(allocator, stdout, r, &open_docs, &cached_symbols, &cached_diags);
            },
            .did_change => {
                if (jsonObj(root, "params")) |params| {
                    if (jsonObj(params, "textDocument")) |td| {
                        if (jsonStr(td, "uri")) |uri| {
                            if (jsonArray(params, "contentChanges")) |arr| {
                                if (arr.len > 0) {
                                    if (jsonStr(arr[0], "text")) |text|
                                        try updateDocStore(&doc_store, allocator, uri, text);
                                }
                            }
                        }
                    }
                }
            },
            .did_close => {
                if (jsonObj(root, "params")) |params| {
                    if (jsonObj(params, "textDocument")) |td| {
                        if (jsonStr(td, "uri")) |uri| {
                            lspLog("didClose: {s}", .{uri});
                            const clear = buildDiagnosticsMsg(allocator, uri, &.{}) catch continue;
                            defer allocator.free(clear);
                            writeMessage(stdout, clear) catch {};
                            if (open_docs.fetchRemove(uri)) |kv| allocator.free(kv.key);
                            if (doc_store.fetchRemove(uri)) |kv| {
                                allocator.free(kv.key);
                                allocator.free(kv.value);
                            }
                        }
                    }
                }
            },
            .hover => try dispatchLsp(allocator, stdout, id, "hover",
                lsp_nav.handleHover(allocator, root, id, cached_symbols, &doc_store)),
            .definition => try dispatchLsp(allocator, stdout, id, "definition",
                lsp_nav.handleDefinition(allocator, root, id, cached_symbols, &doc_store)),
            .document_symbol => try dispatchLsp(allocator, stdout, id, "documentSymbol",
                lsp_view.handleDocumentSymbols(allocator, root, id, cached_symbols)),
            .completion => try dispatchLsp(allocator, stdout, id, "completion",
                lsp_edit.handleCompletion(allocator, root, id, cached_symbols, enable_snippets, &doc_store)),
            .references => try dispatchLsp(allocator, stdout, id, "references",
                lsp_nav.handleReferences(allocator, root, id, cached_symbols)),
            .rename => try dispatchLsp(allocator, stdout, id, "rename",
                lsp_edit.handleRename(allocator, root, id, cached_symbols, project_root)),
            .signature_help => try dispatchLsp(allocator, stdout, id, "signatureHelp",
                lsp_view.handleSignatureHelp(allocator, root, id, cached_symbols, &doc_store)),
            .formatting => try dispatchLsp(allocator, stdout, id, "formatting",
                lsp_edit.handleFormatting(allocator, root, id)),
            .workspace_symbol => try dispatchLsp(allocator, stdout, id, "workspaceSymbol",
                lsp_view.handleWorkspaceSymbol(allocator, root, id, cached_symbols)),
            .code_action => try dispatchLspArray(allocator, stdout, id, "codeAction",
                lsp_edit.handleCodeAction(allocator, root, id, cached_diags)),
            .inlay_hint => {
                if (!enable_inlay_hints) {
                    if (id != .null) {
                        const resp = try buildEmptyArrayResponse(allocator, id);
                        defer allocator.free(resp);
                        try writeMessage(stdout, resp);
                    }
                    continue;
                }
                try dispatchLsp(allocator, stdout, id, "inlayHint",
                    lsp_view.handleInlayHint(allocator, root, id, cached_symbols, &doc_store));
            },
            .document_highlight => try dispatchLsp(allocator, stdout, id, "documentHighlight",
                lsp_nav.handleDocumentHighlight(allocator, root, id, &doc_store)),
            .folding_range => try dispatchLsp(allocator, stdout, id, "foldingRange",
                lsp_view.handleFoldingRange(allocator, root, id, &doc_store)),
            .semantic_tokens => try dispatchLsp(allocator, stdout, id, "semanticTokens",
                lsp_semantic.handleSemanticTokens(allocator, root, id)),
        }
    }
}

// ============================================================
// HELPERS
// ============================================================

/// Update in-memory document content. Frees old value if key exists, otherwise inserts new entry.
fn updateDocStore(doc_store: *std.StringHashMap([]u8), allocator: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
    const text_owned = try allocator.dupe(u8, text);
    if (doc_store.getPtr(uri)) |val_ptr| {
        allocator.free(val_ptr.*);
        val_ptr.* = text_owned;
    } else {
        try doc_store.put(try allocator.dupe(u8, uri), text_owned);
    }
}

/// Run analysis, publish diagnostics, and swap cached symbols/diags.
fn analyzeAndCache(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    root: []const u8,
    open_docs: *std.StringHashMap(void),
    cached_symbols: *[]SymbolInfo,
    cached_diags: *[]Diagnostic,
) !void {
    const result = try runAndPublishWithDiags(allocator, writer, root, open_docs, cached_symbols.*);
    cached_symbols.* = result.symbols;
    freeDiagnostics(allocator, cached_diags.*);
    cached_diags.* = result.diags;
}

// ============================================================
// ANALYSIS + DIAGNOSTICS PUBLISHING
// ============================================================

fn runAndPublishWithDiags(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    project_root: []const u8,
    open_docs: *std.StringHashMap(void),
    old_symbols: []SymbolInfo,
) !PublishResult {
    const result = try runAnalysis(allocator, project_root);

    // Free old symbols
    freeSymbols(allocator, old_symbols);

    // Collect unique URIs that have diagnostics
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (result.diagnostics) |d| {
        if (!seen.contains(d.uri)) {
            try seen.put(d.uri, {});
            const msg = try buildDiagnosticsMsg(allocator, d.uri, result.diagnostics);
            defer allocator.free(msg);
            try writeMessage(writer, msg);
        }
    }

    // Clear diagnostics for open files that have no errors anymore
    var doc_it = open_docs.iterator();
    while (doc_it.next()) |entry| {
        if (!seen.contains(entry.key_ptr.*)) {
            const clear = try buildDiagnosticsMsg(allocator, entry.key_ptr.*, &.{});
            defer allocator.free(clear);
            try writeMessage(writer, clear);
        }
    }

    lspLog("cached {d} symbols", .{result.symbols.len});
    return .{ .symbols = result.symbols, .diags = result.diagnostics };
}

// ============================================================
// TESTS
// ============================================================

test "readMessage parses LSP header" {
    const input = "Content-Length: 13\r\n\r\n{\"test\":true}";
    var reader = Io.Reader.fixed(input);
    const body = try readMessage(&reader, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{\"test\":true}", body);
}

test "readMessage rejects oversized content-length" {
    const input = "Content-Length: 104857600\r\n\r\n";
    var reader = Io.Reader.fixed(input);
    const result = readMessage(&reader, std.testing.allocator);
    try std.testing.expectError(error.InvalidHeader, result);
}

test "readMessage accepts valid content-length" {
    const body_content = "{}";
    const input = "Content-Length: 2\r\n\r\n{}";
    var reader = Io.Reader.fixed(input);
    const body = try readMessage(&reader, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(body_content, body);
}
