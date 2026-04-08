// lsp_view.zig — LSP view and hints handlers (symbols, signature help, inlay hints, folding)

const std = @import("std");
const lsp_types = @import("lsp_types.zig");
const lsp_json = @import("lsp_json.zig");
const lsp_utils = @import("lsp_utils.zig");
const lsp_edit = @import("lsp_edit.zig");

const SymbolInfo = lsp_types.SymbolInfo;
const CallContext = lsp_types.CallContext;
const ParamLabels = lsp_types.ParamLabels;

const jsonStr = lsp_json.jsonStr;
const jsonObj = lsp_json.jsonObj;
const jsonInt = lsp_json.jsonInt;
const writeJsonValue = lsp_json.writeJsonValue;
const appendJsonString = lsp_json.appendJsonString;
const appendInt = lsp_json.appendInt;
const buildEmptyResponse = lsp_json.buildEmptyResponse;
const extractTextDocumentUri = lsp_json.extractTextDocumentUri;
const buildDocumentSymbolsResponse = lsp_json.buildDocumentSymbolsResponse;

const lspLog = lsp_utils.lspLog;
const getDocSource = lsp_utils.getDocSource;
const isIdentChar = lsp_utils.isIdentChar;
const getLinePrefix = lsp_utils.getLinePrefix;
const findSymbolByName = lsp_utils.findSymbolByName;
const findSymbolInContext = lsp_utils.findSymbolInContext;

// ============================================================
// DOCUMENT SYMBOLS
// ============================================================

pub fn handleDocumentSymbols(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const uri = extractTextDocumentUri(params) orelse return buildEmptyResponse(allocator, id);
    lspLog("documentSymbol: {s}", .{uri});

    return buildDocumentSymbolsResponse(allocator, id, symbols, uri);
}

// ============================================================
// WORKSPACE SYMBOL — cross-file symbol search
// ============================================================

pub fn handleWorkspaceSymbol(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo) ![]u8 {
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
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}


// ============================================================
// SIGNATURE HELP — show parameter hints for function calls
// ============================================================

pub fn handleSignatureHelp(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const uri = extractTextDocumentUri(params) orelse return buildEmptyResponse(allocator, id);
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

    // Extract parameter labels from signature like "func name(a: i32, b: str) void"
    const param_labels = lsp_edit.extractParamLabels(func_sym.detail);
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
pub fn findCallContext(prefix: []const u8) ?CallContext {
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
// INLAY HINTS — show inferred types for variables
// ============================================================

pub fn handleInlayHint(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const uri = extractTextDocumentUri(params) orelse return buildEmptyResponse(allocator, id);

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

// ============================================================
// FOLDING RANGES — code folding for blocks
// ============================================================

pub fn handleFoldingRange(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const uri = extractTextDocumentUri(params) orelse return buildEmptyResponse(allocator, id);

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
// TESTS
// ============================================================

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

