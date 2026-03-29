// lsp.zig — Orhon Language Server Protocol
// JSON-RPC over stdio. Server loop, transport, and dispatch.
// Handler implementations live in lsp_nav, lsp_edit, lsp_view, lsp_semantic.

const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const module = @import("module.zig");
const declarations = @import("declarations.zig");
const resolver = @import("resolver.zig");
const ownership = @import("ownership.zig");
const borrow = @import("borrow.zig");
const thread_safety = @import("thread_safety.zig");
const propagation = @import("propagation.zig");
const sema = @import("sema.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const types = @import("types.zig");
const builtins = @import("builtins.zig");
const lsp_types = @import("lsp_types.zig");
const lsp_json = @import("lsp_json.zig");
const lsp_utils = @import("lsp_utils.zig");
const lsp_analysis = @import("lsp_analysis.zig");
const lsp_nav = @import("lsp_nav.zig");
const lsp_edit = @import("lsp_edit.zig");

const Diagnostic = lsp_types.Diagnostic;
const SymbolInfo = lsp_types.SymbolInfo;
const SymbolKind = lsp_types.SymbolKind;
const AnalysisResult = lsp_types.AnalysisResult;
const CompletionItemKind = lsp_types.CompletionItemKind;
const SemanticTokenType = lsp_types.SemanticTokenType;
const SemanticModifier = lsp_types.SemanticModifier;
const SemanticToken = lsp_types.SemanticToken;
const TokenClassification = lsp_types.TokenClassification;
const CallContext = lsp_types.CallContext;
const ParamLabels = lsp_types.ParamLabels;
const TrimResult = lsp_types.TrimResult;
const PublishResult = lsp_types.PublishResult;
const MAX_PARAMS = lsp_types.MAX_PARAMS;

const jsonStr = lsp_json.jsonStr;
const jsonObj = lsp_json.jsonObj;
const jsonInt = lsp_json.jsonInt;
const jsonArray = lsp_json.jsonArray;
const jsonBool = lsp_json.jsonBool;
const jsonId = lsp_json.jsonId;
const writeJsonValue = lsp_json.writeJsonValue;
const appendJsonString = lsp_json.appendJsonString;
const appendInt = lsp_json.appendInt;
const buildInitializeResult = lsp_json.buildInitializeResult;
const buildEmptyArrayResponse = lsp_json.buildEmptyArrayResponse;
const buildEmptyResponse = lsp_json.buildEmptyResponse;
const buildDiagnosticsMsg = lsp_json.buildDiagnosticsMsg;
const buildHoverResponse = lsp_json.buildHoverResponse;
const buildDefinitionResponse = lsp_json.buildDefinitionResponse;
const buildDocumentSymbolsResponse = lsp_json.buildDocumentSymbolsResponse;

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

const freeDiagnostics = lsp_types.freeDiagnostics;
const freeSymbols = lsp_types.freeSymbols;

const lspLog = lsp_utils.lspLog;
const getDocSource = lsp_utils.getDocSource;
const uriToPath = lsp_utils.uriToPath;
const pathToUri = lsp_utils.pathToUri;
const findProjectRoot = lsp_utils.findProjectRoot;
const isIdentChar = lsp_utils.isIdentChar;

const runAnalysis = lsp_analysis.runAnalysis;

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
            // Update in-memory document content (full sync mode — change contains entire text)
            if (!initialized) continue;
            if (jsonObj(root, "params")) |params| {
                if (jsonObj(params, "textDocument")) |td| {
                    if (jsonStr(td, "uri")) |uri| {
                        if (jsonArray(params, "contentChanges")) |arr| {
                            if (arr.len > 0) {
                                if (jsonStr(arr[0], "text")) |text| {
                                    const text_owned = try allocator.dupe(u8, text);
                                    if (doc_store.getPtr(uri)) |val_ptr| {
                                        // Key already exists — just replace the value
                                        allocator.free(val_ptr.*);
                                        val_ptr.* = text_owned;
                                    } else {
                                        // New key
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
            const resp = lsp_nav.handleHover(allocator, root, id, cached_symbols, &doc_store) catch |err| {
                lspLog("hover error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            if (!initialized) continue;
            const resp = lsp_nav.handleDefinition(allocator, root, id, cached_symbols, &doc_store) catch |err| {
                lspLog("definition error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            if (!initialized) continue;
            const resp = handleDocumentSymbols(allocator, root, id, cached_symbols) catch |err| {
                lspLog("documentSymbol error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            if (!initialized) continue;
            const resp = lsp_edit.handleCompletion(allocator, root, id, cached_symbols, enable_snippets, &doc_store) catch |err| {
                lspLog("completion error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            if (!initialized) continue;
            const resp = lsp_nav.handleReferences(allocator, root, id, cached_symbols) catch |err| {
                lspLog("references error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            if (!initialized) continue;
            const resp = lsp_edit.handleRename(allocator, root, id, cached_symbols, project_root) catch |err| {
                lspLog("rename error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            if (!initialized) continue;
            const resp = handleSignatureHelp(allocator, root, id, cached_symbols, &doc_store) catch |err| {
                lspLog("signatureHelp error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
            if (!initialized) continue;
            const resp = lsp_edit.handleFormatting(allocator, root, id) catch |err| {
                lspLog("formatting error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "workspace/symbol")) {
            if (!initialized) continue;
            const resp = handleWorkspaceSymbol(allocator, root, id, cached_symbols) catch |err| {
                lspLog("workspaceSymbol error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/codeAction")) {
            if (!initialized) continue;
            const resp = lsp_edit.handleCodeAction(allocator, root, id, cached_diags) catch |err| {
                lspLog("codeAction error: {}", .{err});
                try writeMessage(stdout, try buildEmptyArrayResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
            if (!initialized or !enable_inlay_hints) {
                if (id != .null) {
                    const resp = try buildEmptyArrayResponse(allocator, id);
                    defer allocator.free(resp);
                    try writeMessage(stdout, resp);
                }
                continue;
            }
            const resp = handleInlayHint(allocator, root, id, cached_symbols, &doc_store) catch |err| {
                lspLog("inlayHint error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/documentHighlight")) {
            if (!initialized) continue;
            const resp = lsp_nav.handleDocumentHighlight(allocator, root, id, &doc_store) catch |err| {
                lspLog("documentHighlight error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
            if (!initialized) continue;
            const resp = handleFoldingRange(allocator, root, id, &doc_store) catch |err| {
                lspLog("foldingRange error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            if (!initialized) continue;
            const resp = handleSemanticTokens(allocator, root, id) catch |err| {
                lspLog("semanticTokens error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

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

/// Run analysis, publish diagnostics, return new cached symbols.
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
// HANDLERS (to be extracted in Task 2: lsp_view, lsp_semantic)
// ============================================================

fn handleDocumentSymbols(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);
    lspLog("documentSymbol: {s}", .{uri});

    return buildDocumentSymbolsResponse(allocator, id, symbols, uri);
}

fn handleSignatureHelp(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);
    const pos = jsonObj(params, "position") orelse return buildEmptyResponse(allocator, id);
    const line_0: usize = @intCast(jsonInt(pos, "line") orelse return buildEmptyResponse(allocator, id));
    const col_0: usize = @intCast(jsonInt(pos, "character") orelse return buildEmptyResponse(allocator, id));

    const source = getDocSource(allocator, uri, doc_store) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(source);

    // Find the function name by scanning backwards from cursor to find `funcname(`
    const prefix = lsp_utils.getLinePrefix(source, line_0, col_0);
    const call_info = findCallContext(prefix) orelse return buildEmptyResponse(allocator, id);
    lspLog("signatureHelp: func='{s}' activeParam={d}", .{ call_info.func_name, call_info.active_param });

    // Look up the function symbol — check dot context (module.func or struct.method)
    const sym = if (call_info.obj_name) |obj|
        lsp_utils.findSymbolInContext(symbols, call_info.func_name, obj)
    else
        lsp_utils.findSymbolByName(symbols, call_info.func_name);

    const func_sym = sym orelse return buildEmptyResponse(allocator, id);
    if (func_sym.kind != .function) return buildEmptyResponse(allocator, id);

    // Build signature help response with parameter labels
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":{\"signatures\":[{\"label\":\"");
    try appendJsonString(&buf, allocator, func_sym.detail);
    try buf.append(allocator, '"');

    // Extract parameter labels from signature like "func name(a: i32, b: String) void"
    const param_labels = extractParamLabels(func_sym.detail);
    if (param_labels.count > 0) {
        try buf.appendSlice(allocator, ",\"parameters\":[");
        for (0..param_labels.count) |i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"label\":[");
            try appendInt(&buf, allocator, param_labels.starts[i]);
            try buf.append(allocator, ',');
            try appendInt(&buf, allocator, param_labels.ends[i]);
            try buf.appendSlice(allocator, "]}");
        }
        try buf.append(allocator, ']');
    }

    try buf.appendSlice(allocator, "}],\"activeSignature\":0,\"activeParameter\":");
    try appendInt(&buf, allocator, call_info.active_param);
    try buf.appendSlice(allocator, "}}");

    return allocator.dupe(u8, buf.items);
}

/// Scan backwards from cursor through `prefix` to find `funcname(` and count commas for active param.
fn findCallContext(prefix: []const u8) ?CallContext {
    if (prefix.len == 0) return null;

    // Walk backwards to find the opening paren, tracking nesting
    var depth: usize = 0;
    var commas: usize = 0;
    var i = prefix.len;
    while (i > 0) {
        i -= 1;
        switch (prefix[i]) {
            ')' => depth += 1,
            '(' => {
                if (depth == 0) {
                    // Found the opening paren — extract function name before it
                    if (i == 0) return null;
                    var end = i;
                    // Skip whitespace between name and paren
                    while (end > 0 and prefix[end - 1] == ' ') : (end -= 1) {}
                    if (end == 0) return null;
                    var start = end;
                    while (start > 0 and isIdentChar(prefix[start - 1])) : (start -= 1) {}
                    if (start == end) return null;
                    const func_name = prefix[start..end];
                    // Check for dot prefix (obj.func)
                    var obj_name: ?[]const u8 = null;
                    if (start > 1 and prefix[start - 1] == '.') {
                        const obj_end = start - 1;
                        var obj_start = obj_end;
                        while (obj_start > 0 and isIdentChar(prefix[obj_start - 1])) : (obj_start -= 1) {}
                        if (obj_start < obj_end) obj_name = prefix[obj_start..obj_end];
                    }
                    return .{
                        .func_name = func_name,
                        .obj_name = obj_name,
                        .active_param = commas,
                    };
                }
                depth -= 1;
            },
            ',' => {
                if (depth == 0) commas += 1;
            },
            else => {},
        }
    }
    return null;
}

fn extractParamLabels(sig: []const u8) ParamLabels {
    return lsp_edit.extractParamLabels(sig);
}

fn handleWorkspaceSymbol(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const query = jsonStr(params, "query") orelse "";
    lspLog("workspaceSymbol: query='{s}'", .{query});

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":[");

    var first = true;
    var count: usize = 0;
    for (symbols) |s| {
        // Filter by query (case-insensitive substring match)
        if (query.len > 0 and !containsIgnoreCase(s.name, query)) continue;
        if (count >= 200) break; // limit results

        if (!first) try buf.append(allocator, ',');
        first = false;
        count += 1;

        try buf.appendSlice(allocator, "{\"name\":\"");
        try appendJsonString(&buf, allocator, s.name);
        try buf.appendSlice(allocator, "\",\"kind\":");
        try appendInt(&buf, allocator, @intFromEnum(s.kind));
        if (s.module.len > 0) {
            try buf.appendSlice(allocator, ",\"containerName\":\"");
            try appendJsonString(&buf, allocator, s.module);
            try buf.append(allocator, '"');
        }
        try buf.appendSlice(allocator, ",\"location\":{\"uri\":\"");
        try appendJsonString(&buf, allocator, s.uri);
        try buf.appendSlice(allocator, "\",\"range\":{\"start\":{\"line\":");
        try appendInt(&buf, allocator, s.line);
        try buf.appendSlice(allocator, ",\"character\":");
        try appendInt(&buf, allocator, s.col);
        try buf.appendSlice(allocator, "},\"end\":{\"line\":");
        try appendInt(&buf, allocator, s.line);
        try buf.appendSlice(allocator, ",\"character\":");
        try appendInt(&buf, allocator, s.col);
        try buf.appendSlice(allocator, "}}}}");
    }

    try buf.appendSlice(allocator, "]}");
    return allocator.dupe(u8, buf.items);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matches = true;
        for (0..needle.len) |j| {
            if (toLowerAscii(haystack[i + j]) != toLowerAscii(needle[j])) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn toLowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn handleInlayHint(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);

    const source = getDocSource(allocator, uri, doc_store) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(source);
    lspLog("inlayHint: {s}", .{uri});

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":[");

    var first = true;

    // Find variable/const declarations without explicit type annotations
    // Pattern: "var name = ..." or "const name = ..." (no ": Type" after name)
    var line_num: usize = 0;
    var line_start: usize = 0;
    for (source, 0..) |c, idx| {
        if (c == '\n') {
            const line = source[line_start..idx];
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            const indent = idx - line_start - trimmed.len;
            _ = indent;

            // Check for "var name = ..." or "const name = ..."
            const is_var = std.mem.startsWith(u8, trimmed, "var ");
            const is_const = std.mem.startsWith(u8, trimmed, "const ");
            if (is_var or is_const) {
                const prefix_len: usize = if (is_var) 4 else 6;
                const after_kw = std.mem.trimLeft(u8, trimmed[prefix_len..], " ");
                // Extract variable name
                var name_end: usize = 0;
                while (name_end < after_kw.len and isIdentChar(after_kw[name_end])) : (name_end += 1) {}
                if (name_end > 0) {
                    const var_name = after_kw[0..name_end];
                    const after_name = std.mem.trimLeft(u8, after_kw[name_end..], " ");
                    // Only add hint if no explicit type (line has "= ..." not ": Type = ...")
                    if (std.mem.startsWith(u8, after_name, "= ") or std.mem.startsWith(u8, after_name, "=\t")) {
                        // Look up the type from symbols
                        if (findSymbolInFile(symbols, var_name, uri)) |sym_info| {
                            // Don't show "var" or "const" as the type — only actual types
                            if (!std.mem.eql(u8, sym_info.detail, "var") and
                                !std.mem.eql(u8, sym_info.detail, "const"))
                            {
                                if (!first) try buf.append(allocator, ',');
                                first = false;

                                // Position hint right after the variable name
                                const name_col = @as(usize, @intCast(line.len - trimmed.len)) + prefix_len + (@as(usize, @intCast(trimmed.len - prefix_len)) - after_kw.len) + name_end;
                                try buf.appendSlice(allocator, "{\"position\":{\"line\":");
                                try appendInt(&buf, allocator, line_num);
                                try buf.appendSlice(allocator, ",\"character\":");
                                try appendInt(&buf, allocator, name_col);
                                try buf.appendSlice(allocator, "},\"label\":\": ");
                                try appendJsonString(&buf, allocator, sym_info.detail);
                                try buf.appendSlice(allocator, "\",\"kind\":1,\"paddingLeft\":false,\"paddingRight\":true}");
                            }
                        }
                    }
                }
            }

            line_num += 1;
            line_start = idx + 1;
        }
    }

    try buf.appendSlice(allocator, "]}");
    return allocator.dupe(u8, buf.items);
}

/// Find a symbol by name that belongs to a specific file URI.
fn findSymbolInFile(symbols: []const SymbolInfo, name: []const u8, uri: []const u8) ?SymbolInfo {
    for (symbols) |s| {
        if (std.mem.eql(u8, s.name, name) and std.mem.eql(u8, s.uri, uri) and s.parent.len == 0)
            return s;
    }
    // Fallback: any symbol with this name
    for (symbols) |s| {
        if (std.mem.eql(u8, s.name, name) and s.parent.len == 0) return s;
    }
    return null;
}

fn handleFoldingRange(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);

    const source = getDocSource(allocator, uri, doc_store) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(source);
    lspLog("foldingRange: {s}", .{uri});

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":[");

    // Track brace-delimited blocks + comment blocks + import blocks
    var brace_stack: [256]usize = undefined; // line numbers of opening braces
    var brace_depth: usize = 0;
    var first = true;
    var line_num: usize = 0;
    var in_comment_block = false;
    var comment_start: usize = 0;
    var in_import_block = false;
    var import_start: usize = 0;
    var line_start: usize = 0;

    for (source, 0..) |c, idx| {
        if (c == '\n') {
            // Check if this line is a comment or import before moving on
            const line = source[line_start..idx];
            const trimmed = std.mem.trimLeft(u8, line, " \t");

            // Track consecutive comment blocks
            const is_comment = std.mem.startsWith(u8, trimmed, "//");
            if (is_comment and !in_comment_block) {
                in_comment_block = true;
                comment_start = line_num;
            } else if (!is_comment and in_comment_block) {
                in_comment_block = false;
                if (line_num > comment_start + 1) {
                    if (!first) try buf.append(allocator, ',');
                    first = false;
                    try appendFoldingRange(&buf, allocator, comment_start, line_num - 2, "comment");
                }
            }

            // Track import blocks
            const is_import = std.mem.startsWith(u8, trimmed, "import ");
            if (is_import and !in_import_block) {
                in_import_block = true;
                import_start = line_num;
            } else if (!is_import and in_import_block and trimmed.len > 0) {
                in_import_block = false;
                if (line_num > import_start + 1) {
                    if (!first) try buf.append(allocator, ',');
                    first = false;
                    try appendFoldingRange(&buf, allocator, import_start, line_num - 2, "imports");
                }
            }

            line_num += 1;
            line_start = idx + 1;
            continue;
        }
        if (c == '{') {
            if (brace_depth < brace_stack.len) {
                brace_stack[brace_depth] = line_num;
                brace_depth += 1;
            }
        } else if (c == '}') {
            if (brace_depth > 0) {
                brace_depth -= 1;
                const open_line = brace_stack[brace_depth];
                if (line_num > open_line) {
                    if (!first) try buf.append(allocator, ',');
                    first = false;
                    try appendFoldingRange(&buf, allocator, open_line, line_num - 1, "region");
                }
            }
        }
    }

    // Close any trailing comment block
    if (in_comment_block and line_num > comment_start + 1) {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendFoldingRange(&buf, allocator, comment_start, line_num - 1, "comment");
    }

    try buf.appendSlice(allocator, "]}");
    return allocator.dupe(u8, buf.items);
}

fn appendFoldingRange(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, start_line: usize, end_line: usize, kind: []const u8) !void {
    try buf.appendSlice(allocator, "{\"startLine\":");
    try appendInt(buf, allocator, start_line);
    try buf.appendSlice(allocator, ",\"endLine\":");
    try appendInt(buf, allocator, end_line);
    try buf.appendSlice(allocator, ",\"kind\":\"");
    try buf.appendSlice(allocator, kind);
    try buf.appendSlice(allocator, "\"}");
}

fn handleSemanticTokens(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);

    const path = uriToPath(uri) orelse return buildEmptyResponse(allocator, id);
    const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(source);
    lspLog("semanticTokens: {s}", .{path});

    // Lex the source to get tokens
    var lex = lexer.Lexer.init(source);
    var tokens: std.ArrayListUnmanaged(SemanticToken) = .{};
    defer tokens.deinit(allocator);

    while (true) {
        const tok = lex.next();
        if (tok.kind == .eof) break;
        if (tok.kind == .newline) continue;

        const sem = classifyToken(tok.kind);
        if (sem.token_type) |tt| {
            try tokens.append(allocator, .{
                .line = if (tok.line > 0) tok.line - 1 else 0, // lexer is 1-based
                .col = if (tok.col > 0) tok.col - 1 else 0,
                .length = tok.text.len,
                .token_type = @intFromEnum(tt),
                .modifiers = sem.modifiers,
            });
        }
    }

    // Encode as delta-encoded data array per LSP spec
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":{\"data\":[");

    var prev_line: usize = 0;
    var prev_col: usize = 0;
    for (tokens.items, 0..) |tok, tok_idx| {
        if (tok_idx > 0) try buf.append(allocator, ',');
        const delta_line = tok.line -| prev_line;
        const delta_col = if (tok.line == prev_line) tok.col -| prev_col else tok.col;
        try appendInt(&buf, allocator, delta_line);
        try buf.append(allocator, ',');
        try appendInt(&buf, allocator, delta_col);
        try buf.append(allocator, ',');
        try appendInt(&buf, allocator, tok.length);
        try buf.append(allocator, ',');
        try appendInt(&buf, allocator, tok.token_type);
        try buf.append(allocator, ',');
        try appendInt(&buf, allocator, tok.modifiers);
        prev_line = tok.line;
        prev_col = tok.col;
    }

    try buf.appendSlice(allocator, "]}}");
    return allocator.dupe(u8, buf.items);
}

fn classifyToken(kind: lexer.TokenKind) TokenClassification {
    return switch (kind) {
        // Keywords
        .kw_func, .kw_var, .kw_const, .kw_struct, .kw_enum, .kw_bitfield,
        .kw_module, .kw_import, .kw_use, .kw_pub, .kw_bridge, .kw_compt, .kw_test,
        .kw_if, .kw_elif, .kw_else, .kw_for, .kw_while, .kw_return, .kw_match,
        .kw_break, .kw_continue, .kw_defer, .kw_thread, .kw_any,
        .kw_and, .kw_or, .kw_not, .kw_as, .kw_is, .kw_cast,
        .kw_copy, .kw_move, .kw_swap, .kw_true, .kw_false, .kw_null,
        .kw_void, .kw_main, .kw_type,
        => .{ .token_type = .keyword, .modifiers = 0 },

        // Builtin functions
        .kw_assert, .kw_size, .kw_align, .kw_typename, .kw_typeid, .kw_typeof,
        => .{ .token_type = .function, .modifiers = SemanticModifier.readonly },

        // Literals
        .string_literal => .{ .token_type = .string, .modifiers = 0 },
        .int_literal, .float_literal => .{ .token_type = .number, .modifiers = 0 },

        // Operators
        .plus, .plus_plus, .minus, .star, .slash, .percent,
        .eq, .neq, .lt, .gt, .lte, .gte,
        .caret, .lshift, .rshift, .bang, .ampersand,
        .assign, .plus_assign, .minus_assign, .star_assign, .slash_assign,
        .arrow, .dotdot, .pipe,
        => .{ .token_type = .operator, .modifiers = 0 },

        .hash => .{ .token_type = .keyword, .modifiers = 0 },

        // Identifiers classified by context later, but base case
        .identifier => .{ .token_type = null, .modifiers = 0 },

        // Skip punctuation and structural tokens
        else => .{ .token_type = null, .modifiers = 0 },
    };
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
    // Content-Length claims 100 MiB — exceeds MAX_CONTENT_LENGTH (64 MiB)
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

test "findCallContext finds function name and active param" {
    const ctx1 = findCallContext("foo(").?;
    try std.testing.expectEqualStrings("foo", ctx1.func_name);
    try std.testing.expect(ctx1.obj_name == null);
    try std.testing.expectEqual(@as(usize, 0), ctx1.active_param);

    const ctx2 = findCallContext("foo(a, b, ").?;
    try std.testing.expectEqualStrings("foo", ctx2.func_name);
    try std.testing.expectEqual(@as(usize, 2), ctx2.active_param);

    const ctx3 = findCallContext("console.println(").?;
    try std.testing.expectEqualStrings("println", ctx3.func_name);
    try std.testing.expectEqualStrings("console", ctx3.obj_name.?);
    try std.testing.expectEqual(@as(usize, 0), ctx3.active_param);
}

test "findCallContext returns null for no call" {
    try std.testing.expect(findCallContext("var x = 42") == null);
    try std.testing.expect(findCallContext("") == null);
}

test "findCallContext handles nested parens" {
    const ctx = findCallContext("foo(bar(1), ").?;
    try std.testing.expectEqualStrings("foo", ctx.func_name);
    try std.testing.expectEqual(@as(usize, 1), ctx.active_param);
}

test "containsIgnoreCase matches" {
    try std.testing.expect(containsIgnoreCase("MyFunction", "func"));
    try std.testing.expect(containsIgnoreCase("MyFunction", "FUNC"));
    try std.testing.expect(containsIgnoreCase("abc", "abc"));
    try std.testing.expect(!containsIgnoreCase("abc", "xyz"));
    try std.testing.expect(!containsIgnoreCase("ab", "abc"));
}

test "classifyToken keywords" {
    const kw = classifyToken(.kw_func);
    try std.testing.expectEqual(SemanticTokenType.keyword, kw.token_type.?);
    const num = classifyToken(.int_literal);
    try std.testing.expectEqual(SemanticTokenType.number, num.token_type.?);
    const str = classifyToken(.string_literal);
    try std.testing.expectEqual(SemanticTokenType.string, str.token_type.?);
    const ident = classifyToken(.identifier);
    try std.testing.expect(ident.token_type == null);
}
