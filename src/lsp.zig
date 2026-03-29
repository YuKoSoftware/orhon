// lsp.zig — Orhon Language Server Protocol
// JSON-RPC over stdio. Runs analysis passes 1–9, publishes diagnostics,
// and provides hover, go-to-definition, completion, references, rename,
// signature help, formatting, document symbols, highlights, folding,
// inlay hints, code actions, and workspace symbol search.

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
const getWordAtPosition = lsp_utils.getWordAtPosition;
const isIdentChar = lsp_utils.isIdentChar;
const getDotContext = lsp_utils.getDotContext;
const getLinePrefix = lsp_utils.getLinePrefix;
const getDotPrefix = lsp_utils.getDotPrefix;
const getModuleName = lsp_utils.getModuleName;
const getImportedModules = lsp_utils.getImportedModules;
const isVisibleModule = lsp_utils.isVisibleModule;
const findSymbolByName = lsp_utils.findSymbolByName;
const findVisibleSymbolByName = lsp_utils.findVisibleSymbolByName;
const findSymbolInContext = lsp_utils.findSymbolInContext;
const isOnModuleLine = lsp_utils.isOnModuleLine;
const isModuleName = lsp_utils.isModuleName;
const builtinDetail = lsp_utils.builtinDetail;

const runAnalysis = lsp_analysis.runAnalysis;
const formatType = lsp_analysis.formatType;



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
            const resp = handleHover(allocator, root, id, cached_symbols, &doc_store) catch |err| {
                lspLog("hover error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            if (!initialized) continue;
            const resp = handleDefinition(allocator, root, id, cached_symbols, &doc_store) catch |err| {
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
            const resp = handleCompletion(allocator, root, id, cached_symbols, enable_snippets, &doc_store) catch |err| {
                lspLog("completion error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            if (!initialized) continue;
            const resp = handleReferences(allocator, root, id, cached_symbols) catch |err| {
                lspLog("references error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            if (!initialized) continue;
            const resp = handleRename(allocator, root, id, cached_symbols, project_root) catch |err| {
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
            const resp = handleFormatting(allocator, root, id) catch |err| {
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
            const resp = handleCodeAction(allocator, root, id, cached_diags) catch |err| {
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
            const resp = handleDocumentHighlight(allocator, root, id, &doc_store) catch |err| {
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
// PHASE 2 HANDLERS
// ============================================================

fn handleHover(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);
    const pos = jsonObj(params, "position") orelse return buildEmptyResponse(allocator, id);
    const line_0: usize = @intCast(jsonInt(pos, "line") orelse return buildEmptyResponse(allocator, id));
    const col_0: usize = @intCast(jsonInt(pos, "character") orelse return buildEmptyResponse(allocator, id));

    // Read source (in-memory if available, otherwise from disk)
    const source = getDocSource(allocator, uri, doc_store) catch |err| {
        lspLog("hover: failed to read source: {}", .{err});
        return buildEmptyResponse(allocator, id);
    };
    defer allocator.free(source);

    const word = getWordAtPosition(source, line_0, col_0) orelse {
        lspLog("hover: no word at {d}:{d}", .{ line_0, col_0 });
        return buildEmptyResponse(allocator, id);
    };
    // Check for dot context (e.g. hovering over "println" in "console.println")
    const dot_context = getDotContext(source, line_0, col_0);
    if (dot_context) |ctx| {
        lspLog("hover: '{s}.{s}' at {d}:{d} ({d} symbols cached)", .{ ctx, word, line_0, col_0, symbols.len });
    } else {
        lspLog("hover: '{s}' at {d}:{d} ({d} symbols cached)", .{ word, line_0, col_0, symbols.len });
    }

    // Determine which modules are visible in this file
    const current_module = getModuleName(source);
    const imports = getImportedModules(source, allocator);
    defer if (imports) |imps| allocator.free(imps);

    // 0. If cursor is on a "module <name>" line, show module info
    if (isOnModuleLine(source, line_0)) {
        const detail = try std.fmt.allocPrint(allocator, "(module) {s}", .{word});
        defer allocator.free(detail);
        return buildHoverResponse(allocator, id, detail);
    }

    // 1. Context-aware lookup (module.func or struct.field)
    if (dot_context) |ctx| {
        if (findSymbolInContext(symbols, word, ctx)) |sym| {
            if (isVisibleModule(sym.module, current_module, imports))
                return buildHoverResponse(allocator, id, sym.detail);
        }
    }

    // 2. Check project symbols by name (only from visible modules)
    if (findVisibleSymbolByName(symbols, word, current_module, imports)) |sym| {
        return buildHoverResponse(allocator, id, sym.detail);
    }

    // 3. Check if hovering over a module name (only if no symbol matched)
    if (isModuleName(symbols, word)) {
        const detail = try std.fmt.allocPrint(allocator, "(module) {s}", .{word});
        defer allocator.free(detail);
        return buildHoverResponse(allocator, id, detail);
    }

    // 4. Check builtin/primitive types
    if (builtinDetail(allocator, word)) |detail| {
        defer allocator.free(detail);
        return buildHoverResponse(allocator, id, detail);
    }

    lspLog("hover: no match for '{s}'", .{word});
    return buildEmptyResponse(allocator, id);
}

fn handleDefinition(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);
    const pos = jsonObj(params, "position") orelse return buildEmptyResponse(allocator, id);
    const line_0: usize = @intCast(jsonInt(pos, "line") orelse return buildEmptyResponse(allocator, id));
    const col_0: usize = @intCast(jsonInt(pos, "character") orelse return buildEmptyResponse(allocator, id));

    const source = getDocSource(allocator, uri, doc_store) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(source);

    const word = getWordAtPosition(source, line_0, col_0) orelse return buildEmptyResponse(allocator, id);
    const dot_context = getDotContext(source, line_0, col_0);
    lspLog("definition: '{s}' ({d} symbols)", .{ word, symbols.len });

    // Determine which modules are visible in this file
    const current_module = getModuleName(source);
    const imports = getImportedModules(source, allocator);
    defer if (imports) |imps| allocator.free(imps);

    // Context-aware lookup first
    if (dot_context) |ctx| {
        if (findSymbolInContext(symbols, word, ctx)) |sym| {
            if (isVisibleModule(sym.module, current_module, imports))
                return buildDefinitionResponse(allocator, id, sym.uri, sym.line, sym.col);
        }
    }

    if (findVisibleSymbolByName(symbols, word, current_module, imports)) |sym|
        return buildDefinitionResponse(allocator, id, sym.uri, sym.line, sym.col);

    // Fallback: if the word is a module name, jump to the first symbol's file (line 0)
    if (isModuleName(symbols, word)) {
        for (symbols) |s| {
            if (std.mem.eql(u8, s.module, word) and s.parent.len == 0)
                return buildDefinitionResponse(allocator, id, s.uri, 0, 0);
        }
    }

    return buildEmptyResponse(allocator, id);
}

fn handleDocumentSymbols(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);
    lspLog("documentSymbol: {s}", .{uri});

    return buildDocumentSymbolsResponse(allocator, id, symbols, uri);
}

// ============================================================
// COMPLETION
// ============================================================

fn handleCompletion(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo, use_snippets: bool, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);
    const pos = jsonObj(params, "position") orelse return buildEmptyResponse(allocator, id);
    const line_0: usize = @intCast(jsonInt(pos, "line") orelse return buildEmptyResponse(allocator, id));
    const col_0: usize = @intCast(jsonInt(pos, "character") orelse return buildEmptyResponse(allocator, id));

    // Read source to determine context
    const source = getDocSource(allocator, uri, doc_store) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(source);

    // Get the text before cursor on this line to determine context
    const prefix = getLinePrefix(source, line_0, col_0);
    lspLog("completion: prefix='{s}'", .{prefix});

    // Determine which modules are visible in this file
    const current_module = getModuleName(source);
    const imports = getImportedModules(source, allocator);
    defer if (imports) |imps| allocator.free(imps);

    // Check if we're after a dot — offer struct fields or module functions
    if (getDotPrefix(prefix)) |obj_name| {
        lspLog("completion: dot context, object='{s}'", .{obj_name});
        return buildDotCompletionResponse(allocator, id, symbols, obj_name, use_snippets);
    }

    // General completion: keywords + symbols + types
    return buildGeneralCompletionResponse(allocator, id, symbols, current_module, imports, use_snippets);
}


fn buildDotCompletionResponse(allocator: std.mem.Allocator, id: std.json.Value, symbols: []const SymbolInfo, obj_name: []const u8, use_snippets: bool) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":{\"isIncomplete\":false,\"items\":[");

    var first = true;

    for (symbols) |s| {
        // Struct fields: parent matches obj_name (e.g. MyStruct.name)
        const is_field = s.parent.len > 0 and std.mem.eql(u8, s.parent, obj_name);
        // Module functions: module matches obj_name (e.g. console.println)
        const is_mod = std.mem.eql(u8, s.module, obj_name) and s.parent.len == 0;
        if (is_field or is_mod) {
            if (!first) try buf.append(allocator, ',');
            first = false;
            if (use_snippets) {
                try appendSymbolCompletionItem(&buf, allocator, s);
            } else {
                const kind: CompletionItemKind = switch (s.kind) {
                    .function => .function, .struct_ => .struct_, .enum_ => .enum_,
                    .variable => .variable, .constant => .constant,
                    .field => .field, .enum_member => .enum_member,
                };
                try appendCompletionItem(&buf, allocator, s.name, s.detail, kind);
            }
        }
    }

    try buf.appendSlice(allocator, "]}}");
    return allocator.dupe(u8, buf.items);
}

fn buildGeneralCompletionResponse(allocator: std.mem.Allocator, id: std.json.Value, symbols: []const SymbolInfo, current_module: ?[]const u8, imports: ?[]const []const u8, use_snippets: bool) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":{\"isIncomplete\":false,\"items\":[");

    var first = true;

    // Keywords
    const keywords = [_][]const u8{
        "func", "var", "const", "if", "elif", "else", "for", "while", "return",
        "import", "pub", "match", "struct", "enum", "bitfield", "defer",
        "thread", "null", "void", "compt", "any", "module", "test",
        "and", "or", "not", "as", "break", "continue", "true", "false",
        "bridge", "is",
    };
    for (keywords) |kw| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendCompletionItem(&buf, allocator, kw, "keyword", .keyword);
    }

    // Primitive types
    const primitives = [_][]const u8{
        "String", "bool", "i8", "i16", "i32", "i64", "i128",
        "u8", "u16", "u32", "u64", "u128", "isize", "usize",
        "f16", "f32", "f64", "f128", "bf16",
    };
    for (primitives) |pt| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendCompletionItem(&buf, allocator, pt, "primitive type", .type_);
    }

    // Builtin types
    for (builtins.BUILTIN_TYPES) |bt| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendCompletionItem(&buf, allocator, bt, "builtin type", .type_);
    }

    // Project symbols (only from current module + imported modules)
    for (symbols) |s| {
        if (!isVisibleModule(s.module, current_module, imports)) continue;
        if (!first) try buf.append(allocator, ',');
        first = false;
        if (use_snippets) {
            try appendSymbolCompletionItem(&buf, allocator, s);
        } else {
            const kind: CompletionItemKind = switch (s.kind) {
                .function => .function, .struct_ => .struct_, .enum_ => .enum_,
                .variable => .variable, .constant => .constant,
                .field => .field, .enum_member => .enum_member,
            };
            try appendCompletionItem(&buf, allocator, s.name, s.detail, kind);
        }
    }

    try buf.appendSlice(allocator, "]}}");
    return allocator.dupe(u8, buf.items);
}

fn appendCompletionItem(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, label: []const u8, detail: []const u8, kind: CompletionItemKind) !void {
    try buf.appendSlice(allocator, "{\"label\":\"");
    try appendJsonString(buf, allocator, label);
    try buf.appendSlice(allocator, "\",\"kind\":");
    try appendInt(buf, allocator, @intFromEnum(kind));
    try buf.appendSlice(allocator, ",\"detail\":\"");
    try appendJsonString(buf, allocator, detail);
    try buf.appendSlice(allocator, "\"}");
}

/// Append a completion item with snippet insertText for functions.
fn appendSymbolCompletionItem(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, sym: SymbolInfo) !void {
    try buf.appendSlice(allocator, "{\"label\":\"");
    try appendJsonString(buf, allocator, sym.name);
    try buf.appendSlice(allocator, "\",\"kind\":");
    const kind: CompletionItemKind = switch (sym.kind) {
        .function => .function,
        .struct_ => .struct_,
        .enum_ => .enum_,
        .variable => .variable,
        .constant => .constant,
        .field => .field,
        .enum_member => .enum_member,
    };
    try appendInt(buf, allocator, @intFromEnum(kind));
    try buf.appendSlice(allocator, ",\"detail\":\"");
    try appendJsonString(buf, allocator, sym.detail);
    try buf.append(allocator, '"');

    // For functions, add a snippet that includes parameter placeholders
    if (sym.kind == .function) {
        try buf.appendSlice(allocator, ",\"insertTextFormat\":2,\"insertText\":\"");
        try appendJsonString(buf, allocator, sym.name);
        // Build snippet: funcname(${1:param1}, ${2:param2})
        const labels = extractParamLabels(sym.detail);
        if (labels.count == 0) {
            try buf.appendSlice(allocator, "()$0");
        } else {
            try buf.append(allocator, '(');
            for (0..labels.count) |i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, "${");
                try appendInt(buf, allocator, i + 1);
                try buf.append(allocator, ':');
                // Extract parameter name from the detail string
                const param_text = sym.detail[labels.starts[i]..labels.ends[i]];
                // Use just the param name (before the colon) as placeholder
                if (std.mem.indexOfScalar(u8, param_text, ':')) |colon_pos| {
                    try appendJsonString(buf, allocator, std.mem.trimRight(u8, param_text[0..colon_pos], " "));
                } else {
                    try appendJsonString(buf, allocator, param_text);
                }
                try buf.append(allocator, '}');
            }
            try buf.appendSlice(allocator, ")$0");
        }
        try buf.append(allocator, '"');
    }

    try buf.append(allocator, '}');
}

// ============================================================
// REFERENCES — find all usages of a symbol across source files
// ============================================================

fn handleReferences(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);
    const pos = jsonObj(params, "position") orelse return buildEmptyResponse(allocator, id);
    const line_0: usize = @intCast(jsonInt(pos, "line") orelse return buildEmptyResponse(allocator, id));
    const col_0: usize = @intCast(jsonInt(pos, "character") orelse return buildEmptyResponse(allocator, id));

    const path = uriToPath(uri) orelse return buildEmptyResponse(allocator, id);
    const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(source);

    const word = getWordAtPosition(source, line_0, col_0) orelse return buildEmptyResponse(allocator, id);
    lspLog("references: '{s}'", .{word});

    // Collect all .orh files in the project by scanning symbol URIs
    var file_uris = std.StringHashMap(void).init(allocator);
    defer file_uris.deinit();
    for (symbols) |s| {
        if (!file_uris.contains(s.uri)) try file_uris.put(s.uri, {});
    }
    // Also include the current file
    if (!file_uris.contains(uri)) try file_uris.put(uri, {});

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":[");

    var first = true;
    var it = file_uris.iterator();
    while (it.next()) |entry| {
        const file_uri = entry.key_ptr.*;
        const file_path = uriToPath(file_uri) orelse continue;
        const file_source = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch continue;
        defer allocator.free(file_source);

        // Find all occurrences of `word` as a whole identifier
        var line_num: usize = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < file_source.len) {
            if (file_source[i] == '\n') {
                line_num += 1;
                line_start = i + 1;
                i += 1;
                continue;
            }
            // Check for word match at this position
            if (i + word.len <= file_source.len and
                std.mem.eql(u8, file_source[i .. i + word.len], word) and
                (i == 0 or !isIdentChar(file_source[i - 1])) and
                (i + word.len >= file_source.len or !isIdentChar(file_source[i + word.len])))
            {
                if (!first) try buf.append(allocator, ',');
                first = false;
                const col = i - line_start;
                try buf.appendSlice(allocator, "{\"uri\":\"");
                try appendJsonString(&buf, allocator, file_uri);
                try buf.appendSlice(allocator, "\",\"range\":{\"start\":{\"line\":");
                try appendInt(&buf, allocator, line_num);
                try buf.appendSlice(allocator, ",\"character\":");
                try appendInt(&buf, allocator, col);
                try buf.appendSlice(allocator, "},\"end\":{\"line\":");
                try appendInt(&buf, allocator, line_num);
                try buf.appendSlice(allocator, ",\"character\":");
                try appendInt(&buf, allocator, col + word.len);
                try buf.appendSlice(allocator, "}}}");
                i += word.len;
                continue;
            }
            i += 1;
        }
    }

    try buf.appendSlice(allocator, "]}");
    return allocator.dupe(u8, buf.items);
}

// ============================================================
// RENAME — rename a symbol across the project
// ============================================================

fn handleRename(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo, project_root: ?[]const u8) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);
    const pos = jsonObj(params, "position") orelse return buildEmptyResponse(allocator, id);
    const line_0: usize = @intCast(jsonInt(pos, "line") orelse return buildEmptyResponse(allocator, id));
    const col_0: usize = @intCast(jsonInt(pos, "character") orelse return buildEmptyResponse(allocator, id));
    const new_name = jsonStr(params, "newName") orelse return buildEmptyResponse(allocator, id);

    const path = uriToPath(uri) orelse return buildEmptyResponse(allocator, id);
    const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(source);

    const word = getWordAtPosition(source, line_0, col_0) orelse return buildEmptyResponse(allocator, id);
    lspLog("rename: '{s}' -> '{s}'", .{ word, new_name });

    // Only rename if symbol is known (not a keyword/builtin)
    const current_module = getModuleName(source);
    const imports = getImportedModules(source, allocator);
    defer if (imports) |imps| allocator.free(imps);
    if (findVisibleSymbolByName(symbols, word, current_module, imports) == null)
        return buildEmptyResponse(allocator, id);

    // Collect source files from symbol URIs
    var file_uris = std.StringHashMap(void).init(allocator);
    defer file_uris.deinit();
    for (symbols) |s| {
        if (!file_uris.contains(s.uri)) try file_uris.put(s.uri, {});
    }
    if (!file_uris.contains(uri)) try file_uris.put(uri, {});

    // Also scan for any .orh files under src/ that might reference the symbol
    if (project_root) |pr| {
        const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{pr});
        defer allocator.free(src_path);
        collectOrhFiles(allocator, src_path, pr, &file_uris) catch {};
    }

    // Build WorkspaceEdit with TextEdits per document
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":{\"changes\":{");

    var first_doc = true;
    var it = file_uris.iterator();
    while (it.next()) |entry| {
        const file_uri = entry.key_ptr.*;
        const file_path = uriToPath(file_uri) orelse continue;
        const file_source = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch continue;
        defer allocator.free(file_source);

        // Collect edits for this file
        var edits: std.ArrayListUnmanaged(u8) = .{};
        defer edits.deinit(allocator);
        var first_edit = true;
        var line_num: usize = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < file_source.len) {
            if (file_source[i] == '\n') {
                line_num += 1;
                line_start = i + 1;
                i += 1;
                continue;
            }
            if (i + word.len <= file_source.len and
                std.mem.eql(u8, file_source[i .. i + word.len], word) and
                (i == 0 or !isIdentChar(file_source[i - 1])) and
                (i + word.len >= file_source.len or !isIdentChar(file_source[i + word.len])))
            {
                if (!first_edit) try edits.append(allocator, ',');
                first_edit = false;
                const col = i - line_start;
                try edits.appendSlice(allocator, "{\"range\":{\"start\":{\"line\":");
                try appendInt(&edits, allocator, line_num);
                try edits.appendSlice(allocator, ",\"character\":");
                try appendInt(&edits, allocator, col);
                try edits.appendSlice(allocator, "},\"end\":{\"line\":");
                try appendInt(&edits, allocator, line_num);
                try edits.appendSlice(allocator, ",\"character\":");
                try appendInt(&edits, allocator, col + word.len);
                try edits.appendSlice(allocator, "}},\"newText\":\"");
                try appendJsonString(&edits, allocator, new_name);
                try edits.appendSlice(allocator, "\"}");
                i += word.len;
                continue;
            }
            i += 1;
        }

        if (edits.items.len > 0) {
            if (!first_doc) try buf.append(allocator, ',');
            first_doc = false;
            try buf.append(allocator, '"');
            try appendJsonString(&buf, allocator, file_uri);
            try buf.appendSlice(allocator, "\":[");
            try buf.appendSlice(allocator, edits.items);
            try buf.append(allocator, ']');
        }
    }

    try buf.appendSlice(allocator, "}}}");
    return allocator.dupe(u8, buf.items);
}

/// Recursively collect .orh file URIs from a directory.
fn collectOrhFiles(allocator: std.mem.Allocator, dir_path: []const u8, project_root: []const u8, uris: *std.StringHashMap(void)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            const sub = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(sub);
            try collectOrhFiles(allocator, sub, project_root, uris);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".orh")) {
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(full);
            const file_uri = try pathToUri(allocator, full);
            if (!uris.contains(file_uri)) {
                try uris.put(file_uri, {});
            } else {
                allocator.free(file_uri);
            }
        }
    }
}

// ============================================================
// SIGNATURE HELP — show parameter hints for function calls
// ============================================================

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
    const prefix = getLinePrefix(source, line_0, col_0);
    const call_info = findCallContext(prefix) orelse return buildEmptyResponse(allocator, id);
    lspLog("signatureHelp: func='{s}' activeParam={d}", .{ call_info.func_name, call_info.active_param });

    // Look up the function symbol — check dot context (module.func or struct.method)
    const sym = if (call_info.obj_name) |obj|
        findSymbolInContext(symbols, call_info.func_name, obj)
    else
        findSymbolByName(symbols, call_info.func_name);

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

// ============================================================
// FORMATTING — run `orhon fmt` on the file
// ============================================================

fn handleFormatting(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);

    const path = uriToPath(uri) orelse return buildEmptyResponse(allocator, id);
    lspLog("formatting: {s}", .{path});

    // Read original content
    const original = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(original);

    // Find the orhon binary (it's us — use /proc/self/exe on Linux)
    const self_exe = std.fs.selfExePathAlloc(allocator) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(self_exe);

    // Run `orhon fmt <path>`
    var child = std.process.Child.init(&.{ self_exe, "fmt", path }, allocator);
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    const term = child.spawnAndWait() catch return buildEmptyResponse(allocator, id);
    switch (term) {
        .Exited => |code| if (code != 0) return buildEmptyResponse(allocator, id),
        else => return buildEmptyResponse(allocator, id),
    }

    // Read formatted content
    const formatted = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(formatted);

    // If no change, return empty edits
    if (std.mem.eql(u8, original, formatted))
        return buildEmptyResponse(allocator, id);

    // Count lines in original to create a full-file replacement edit
    var line_count: usize = 0;
    for (original) |c| {
        if (c == '\n') line_count += 1;
    }

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":");
    try appendInt(&buf, allocator, line_count + 1);
    try buf.appendSlice(allocator, ",\"character\":0}},\"newText\":\"");
    try appendJsonString(&buf, allocator, formatted);
    try buf.appendSlice(allocator, "\"}]}");

    return allocator.dupe(u8, buf.items);
}

// ============================================================
// WORKSPACE SYMBOL — cross-file symbol search
// ============================================================

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

// ============================================================
// INLAY HINTS — show inferred types for variables
// ============================================================

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
                        if (findSymbolInFile(symbols, var_name, uri)) |sym| {
                            // Don't show "var" or "const" as the type — only actual types
                            if (!std.mem.eql(u8, sym.detail, "var") and
                                !std.mem.eql(u8, sym.detail, "const"))
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
                                try appendJsonString(&buf, allocator, sym.detail);
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

// ============================================================
// CODE ACTIONS — quick fixes for diagnostics
// ============================================================

fn handleCodeAction(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, diags: []const Diagnostic) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyArrayResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyArrayResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyArrayResponse(allocator, id);
    const range = jsonObj(params, "range") orelse return buildEmptyArrayResponse(allocator, id);
    const start = jsonObj(range, "start") orelse return buildEmptyArrayResponse(allocator, id);
    const start_line: usize = @intCast(jsonInt(start, "line") orelse return buildEmptyArrayResponse(allocator, id));

    lspLog("codeAction: {s} line {d}", .{ uri, start_line });

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":[");

    var first = true;

    // Find diagnostics that overlap with the requested range
    for (diags) |d| {
        if (!std.mem.eql(u8, d.uri, uri)) continue;
        if (d.line != start_line) continue;

        // Suggest fixes based on diagnostic message patterns
        if (std.mem.indexOf(u8, d.message, "unknown type")) |_| {
            // "unknown type 'Foo'" → suggest checking spelling or adding import
            if (!first) try buf.append(allocator, ',');
            first = false;
            try appendQuickFix(&buf, allocator, "Add import for this type", uri, 0,
                \\import std::
            );
        }
        if (std.mem.indexOf(u8, d.message, "unknown variable")) |_| {
            if (!first) try buf.append(allocator, ',');
            first = false;
            try appendQuickFix(&buf, allocator, "Declare this variable", uri, d.line,
                \\var
            );
        }
        if (std.mem.indexOf(u8, d.message, "unused")) |_| {
            if (!first) try buf.append(allocator, ',');
            first = false;
            try buf.appendSlice(allocator, "{\"title\":\"Prefix with underscore\",\"kind\":\"quickfix\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":");
            try appendInt(&buf, allocator, d.line);
            try buf.appendSlice(allocator, ",\"character\":");
            try appendInt(&buf, allocator, d.col);
            try buf.appendSlice(allocator, "},\"end\":{\"line\":");
            try appendInt(&buf, allocator, d.line);
            try buf.appendSlice(allocator, ",\"character\":");
            try appendInt(&buf, allocator, d.col);
            try buf.appendSlice(allocator, "}},\"message\":\"");
            try appendJsonString(&buf, allocator, d.message);
            try buf.appendSlice(allocator, "\"}]}");
        }
    }

    try buf.appendSlice(allocator, "]}");
    return allocator.dupe(u8, buf.items);
}

fn appendQuickFix(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, title: []const u8, uri: []const u8, line: usize, insert_text: []const u8) !void {
    try buf.appendSlice(allocator, "{\"title\":\"");
    try appendJsonString(buf, allocator, title);
    try buf.appendSlice(allocator, "\",\"kind\":\"quickfix\",\"edit\":{\"changes\":{\"");
    try appendJsonString(buf, allocator, uri);
    try buf.appendSlice(allocator, "\":[{\"range\":{\"start\":{\"line\":");
    try appendInt(buf, allocator, line);
    try buf.appendSlice(allocator, ",\"character\":0},\"end\":{\"line\":");
    try appendInt(buf, allocator, line);
    try buf.appendSlice(allocator, ",\"character\":0}},\"newText\":\"");
    try appendJsonString(buf, allocator, insert_text);
    try buf.appendSlice(allocator, "\"}]}}}");
}

// ============================================================
// PARAMETER LABEL EXTRACTION — for signature help highlights
// ============================================================

/// Parse parameter byte ranges from a signature like "func name(a: i32, b: String) void".
/// Returns offsets into the original string for each parameter.
fn extractParamLabels(sig: []const u8) ParamLabels {
    var result = ParamLabels{
        .starts = undefined,
        .ends = undefined,
        .count = 0,
    };

    // Find opening paren
    const paren_start = std.mem.indexOfScalar(u8, sig, '(') orelse return result;
    // Find matching closing paren
    var depth: usize = 0;
    var paren_end: usize = paren_start;
    for (sig[paren_start..], paren_start..) |c, idx| {
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                paren_end = idx;
                break;
            }
        }
    }
    if (paren_end == paren_start) return result;

    const params_str = sig[paren_start + 1 .. paren_end];
    if (params_str.len == 0) return result;

    // Split by commas at depth 0
    var start: usize = 0;
    var param_depth: usize = 0;
    for (params_str, 0..) |c, i| {
        if (c == '(') param_depth += 1;
        if (c == ')') param_depth -= 1;
        if (c == ',' and param_depth == 0) {
            if (result.count >= MAX_PARAMS) return result;
            const trimmed = trimRange(params_str, start, i);
            result.starts[result.count] = paren_start + 1 + trimmed.start;
            result.ends[result.count] = paren_start + 1 + trimmed.end;
            result.count += 1;
            start = i + 1;
        }
    }
    // Last parameter
    if (result.count < MAX_PARAMS) {
        const trimmed = trimRange(params_str, start, params_str.len);
        if (trimmed.end > trimmed.start) {
            result.starts[result.count] = paren_start + 1 + trimmed.start;
            result.ends[result.count] = paren_start + 1 + trimmed.end;
            result.count += 1;
        }
    }
    return result;
}

fn trimRange(s: []const u8, start: usize, end: usize) TrimResult {
    var a = start;
    while (a < end and s[a] == ' ') : (a += 1) {}
    var b = end;
    while (b > a and s[b - 1] == ' ') : (b -= 1) {}
    return .{ .start = a, .end = b };
}

// ============================================================
// DOCUMENT HIGHLIGHT — highlight all occurrences of word in file
// ============================================================

fn handleDocumentHighlight(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);
    const pos = jsonObj(params, "position") orelse return buildEmptyResponse(allocator, id);
    const line_0: usize = @intCast(jsonInt(pos, "line") orelse return buildEmptyResponse(allocator, id));
    const col_0: usize = @intCast(jsonInt(pos, "character") orelse return buildEmptyResponse(allocator, id));

    const source = getDocSource(allocator, uri, doc_store) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(source);

    const word = getWordAtPosition(source, line_0, col_0) orelse return buildEmptyResponse(allocator, id);
    lspLog("documentHighlight: '{s}'", .{word});

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":[");

    var first = true;
    var line_num: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\n') {
            line_num += 1;
            line_start = i + 1;
            i += 1;
            continue;
        }
        if (i + word.len <= source.len and
            std.mem.eql(u8, source[i .. i + word.len], word) and
            (i == 0 or !isIdentChar(source[i - 1])) and
            (i + word.len >= source.len or !isIdentChar(source[i + word.len])))
        {
            if (!first) try buf.append(allocator, ',');
            first = false;
            const col = i - line_start;
            // kind: 1=Text (read), 2=Read, 3=Write — use 1 for all
            try buf.appendSlice(allocator, "{\"range\":{\"start\":{\"line\":");
            try appendInt(&buf, allocator, line_num);
            try buf.appendSlice(allocator, ",\"character\":");
            try appendInt(&buf, allocator, col);
            try buf.appendSlice(allocator, "},\"end\":{\"line\":");
            try appendInt(&buf, allocator, line_num);
            try buf.appendSlice(allocator, ",\"character\":");
            try appendInt(&buf, allocator, col + word.len);
            try buf.appendSlice(allocator, "}},\"kind\":1}");
            i += word.len;
            continue;
        }
        i += 1;
    }

    try buf.appendSlice(allocator, "]}");
    return allocator.dupe(u8, buf.items);
}

// ============================================================
// FOLDING RANGES — code folding for blocks
// ============================================================

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

// ============================================================
// SEMANTIC TOKENS — rich syntax highlighting via LSP
// ============================================================

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
    for (tokens.items, 0..) |tok, idx| {
        if (idx > 0) try buf.append(allocator, ',');
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

test "extractParamLabels single param" {
    const labels = extractParamLabels("func println(msg: String) void");
    try std.testing.expectEqual(@as(usize, 1), labels.count);
    // "msg: String" starts at index 13, ends at 24
    try std.testing.expectEqualStrings("msg: String", "func println(msg: String) void"[labels.starts[0]..labels.ends[0]]);
}

test "extractParamLabels multiple params" {
    const labels = extractParamLabels("func add(a: i32, b: i32) i32");
    try std.testing.expectEqual(@as(usize, 2), labels.count);
    const sig = "func add(a: i32, b: i32) i32";
    try std.testing.expectEqualStrings("a: i32", sig[labels.starts[0]..labels.ends[0]]);
    try std.testing.expectEqualStrings("b: i32", sig[labels.starts[1]..labels.ends[1]]);
}

test "extractParamLabels no params" {
    const labels = extractParamLabels("func main() void");
    try std.testing.expectEqual(@as(usize, 0), labels.count);
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

