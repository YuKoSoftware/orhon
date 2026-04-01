// lsp.zig — Orhon Language Server Protocol
// JSON-RPC over stdio. Server loop, transport, and dispatch.
// Handler implementations live in lsp_nav, lsp_edit, lsp_view, lsp_semantic.

const std = @import("std");
const lexer = @import("../lexer.zig");
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
        const method = jsonStr(root, "method") orelse "";
        const id = jsonId(root);

        if (std.mem.eql(u8, method, "initialize")) {
            lspLog("initialize", .{});
            if (jsonObj(root, "params")) |params| {
                if (jsonStr(params, "rootUri")) |root_uri| {
                    if (uriToPath(root_uri)) |path| {
                        project_root = try allocator.dupe(u8, path);
                        lspLog("project root: {s}", .{path});
                    }
                }
                // Read client settings from initializationOptions
                if (jsonObj(params, "initializationOptions")) |opts| {
                    enable_inlay_hints = jsonBool(opts, "inlayHints");
                    enable_snippets = jsonBool(opts, "completionSnippets");
                    lspLog("settings: inlayHints={}, snippets={}", .{ enable_inlay_hints, enable_snippets });
                }
            }
            const resp = try buildInitializeResult(allocator, id);
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "initialized")) {
            initialized = true;
            lspLog("initialized", .{});
            if (project_root) |r| {
                const result = try runAndPublishWithDiags(allocator, stdout, r, &open_docs, cached_symbols);
                cached_symbols = result.symbols;
                freeDiagnostics(allocator, cached_diags);
                cached_diags = result.diags;
            }

        } else if (std.mem.eql(u8, method, "shutdown")) {
            lspLog("shutdown", .{});
            const resp = try buildEmptyResponse(allocator, id);
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "exit")) {
            lspLog("exit", .{});
            return;

        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            if (!initialized) continue;
            if (jsonObj(root, "params")) |params| {
                if (jsonObj(params, "textDocument")) |td| {
                    if (jsonStr(td, "uri")) |uri| {
                        lspLog("didOpen: {s}", .{uri});
                        if (!open_docs.contains(uri))
                            try open_docs.put(try allocator.dupe(u8, uri), {});
                        // Store document content
                        if (jsonStr(td, "text")) |text| {
                            const text_owned = try allocator.dupe(u8, text);
                            if (doc_store.getPtr(uri)) |val_ptr| {
                                allocator.free(val_ptr.*);
                                val_ptr.* = text_owned;
                            } else {
                                try doc_store.put(try allocator.dupe(u8, uri), text_owned);
                            }
                        }
                        if (project_root == null) {
                            if (uriToPath(uri)) |path| {
                                if (findProjectRoot(path)) |r| {
                                    project_root = try allocator.dupe(u8, r);
                                    lspLog("detected root: {s}", .{r});
                                }
                            }
                        }
                        if (project_root) |r| {
                            const result = try runAndPublishWithDiags(allocator, stdout, r, &open_docs, cached_symbols);
                            cached_symbols = result.symbols;
                            freeDiagnostics(allocator, cached_diags);
                cached_diags = result.diags;
                        }
                    }
                }
            }

        } else if (std.mem.eql(u8, method, "textDocument/didSave")) {
            if (!initialized) continue;
            lspLog("didSave", .{});
            if (project_root) |r| {
                const result = try runAndPublishWithDiags(allocator, stdout, r, &open_docs, cached_symbols);
                cached_symbols = result.symbols;
                freeDiagnostics(allocator, cached_diags);
                cached_diags = result.diags;
            }

        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            if (!initialized) continue;
            if (jsonObj(root, "params")) |params| {
                if (jsonObj(params, "textDocument")) |td| {
                    if (jsonStr(td, "uri")) |uri| {
                        if (jsonArray(params, "contentChanges")) |arr| {
                            if (arr.len > 0) {
                                if (jsonStr(arr[0], "text")) |text| {
                                    const text_owned = try allocator.dupe(u8, text);
                                    if (doc_store.getPtr(uri)) |val_ptr| {
                                        allocator.free(val_ptr.*);
                                        val_ptr.* = text_owned;
                                    } else {
                                        try doc_store.put(try allocator.dupe(u8, uri), text_owned);
                                    }
                                }
                            }
                        }
                    }
                }
            }

        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            if (!initialized) continue;
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

        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            if (!initialized) continue;
            try dispatchLsp(allocator, stdout, id, "hover",
                lsp_nav.handleHover(allocator, root, id, cached_symbols, &doc_store));

        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            if (!initialized) continue;
            try dispatchLsp(allocator, stdout, id, "definition",
                lsp_nav.handleDefinition(allocator, root, id, cached_symbols, &doc_store));

        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            if (!initialized) continue;
            try dispatchLsp(allocator, stdout, id, "documentSymbol",
                lsp_view.handleDocumentSymbols(allocator, root, id, cached_symbols));

        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            if (!initialized) continue;
            try dispatchLsp(allocator, stdout, id, "completion",
                lsp_edit.handleCompletion(allocator, root, id, cached_symbols, enable_snippets, &doc_store));

        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            if (!initialized) continue;
            try dispatchLsp(allocator, stdout, id, "references",
                lsp_nav.handleReferences(allocator, root, id, cached_symbols));

        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            if (!initialized) continue;
            try dispatchLsp(allocator, stdout, id, "rename",
                lsp_edit.handleRename(allocator, root, id, cached_symbols, project_root));

        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            if (!initialized) continue;
            try dispatchLsp(allocator, stdout, id, "signatureHelp",
                lsp_view.handleSignatureHelp(allocator, root, id, cached_symbols, &doc_store));

        } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
            if (!initialized) continue;
            try dispatchLsp(allocator, stdout, id, "formatting",
                lsp_edit.handleFormatting(allocator, root, id));

        } else if (std.mem.eql(u8, method, "workspace/symbol")) {
            if (!initialized) continue;
            try dispatchLsp(allocator, stdout, id, "workspaceSymbol",
                lsp_view.handleWorkspaceSymbol(allocator, root, id, cached_symbols));

        } else if (std.mem.eql(u8, method, "textDocument/codeAction")) {
            if (!initialized) continue;
            try dispatchLspArray(allocator, stdout, id, "codeAction",
                lsp_edit.handleCodeAction(allocator, root, id, cached_diags));

        } else if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
            if (!initialized or !enable_inlay_hints) {
                if (id != .null) {
                    const resp = try buildEmptyArrayResponse(allocator, id);
                    defer allocator.free(resp);
                    try writeMessage(stdout, resp);
                }
                continue;
            }
            try dispatchLsp(allocator, stdout, id, "inlayHint",
                lsp_view.handleInlayHint(allocator, root, id, cached_symbols, &doc_store));

        } else if (std.mem.eql(u8, method, "textDocument/documentHighlight")) {
            if (!initialized) continue;
            try dispatchLsp(allocator, stdout, id, "documentHighlight",
                lsp_nav.handleDocumentHighlight(allocator, root, id, &doc_store));

        } else if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
            if (!initialized) continue;
            try dispatchLsp(allocator, stdout, id, "foldingRange",
                lsp_view.handleFoldingRange(allocator, root, id, &doc_store));

        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            if (!initialized) continue;
            try dispatchLsp(allocator, stdout, id, "semanticTokens",
                lsp_semantic.handleSemanticTokens(allocator, root, id));

        } else {
            // Unknown request — respond with null result
            switch (id) {
                .integer, .string => {
                    const resp = try buildEmptyResponse(allocator, id);
                    defer allocator.free(resp);
                    try writeMessage(stdout, resp);
                },
                else => {},
            }
        }
    }
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
