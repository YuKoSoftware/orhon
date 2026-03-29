// lsp_nav.zig -- LSP navigation handlers (hover, definition, references, highlight)

const std = @import("std");
const lsp_types = @import("lsp_types.zig");
const lsp_json = @import("lsp_json.zig");
const lsp_utils = @import("lsp_utils.zig");

const SymbolInfo = lsp_types.SymbolInfo;

const jsonStr = lsp_json.jsonStr;
const jsonObj = lsp_json.jsonObj;
const jsonInt = lsp_json.jsonInt;
const writeJsonValue = lsp_json.writeJsonValue;
const appendJsonString = lsp_json.appendJsonString;
const appendInt = lsp_json.appendInt;
const buildEmptyResponse = lsp_json.buildEmptyResponse;
const buildHoverResponse = lsp_json.buildHoverResponse;
const buildDefinitionResponse = lsp_json.buildDefinitionResponse;

const lspLog = lsp_utils.lspLog;
const getDocSource = lsp_utils.getDocSource;
const uriToPath = lsp_utils.uriToPath;
const getWordAtPosition = lsp_utils.getWordAtPosition;
const isIdentChar = lsp_utils.isIdentChar;
const getDotContext = lsp_utils.getDotContext;
const getModuleName = lsp_utils.getModuleName;
const getImportedModules = lsp_utils.getImportedModules;
const isVisibleModule = lsp_utils.isVisibleModule;
const findSymbolInContext = lsp_utils.findSymbolInContext;
const findVisibleSymbolByName = lsp_utils.findVisibleSymbolByName;
const isOnModuleLine = lsp_utils.isOnModuleLine;
const isModuleName = lsp_utils.isModuleName;
const builtinDetail = lsp_utils.builtinDetail;

pub fn handleHover(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
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

pub fn handleDefinition(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
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

pub fn handleReferences(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo) ![]u8 {
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

pub fn handleDocumentHighlight(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
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
