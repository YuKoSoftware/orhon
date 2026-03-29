// lsp_json.zig -- LSP JSON helpers and response builders

const std = @import("std");
const lsp_types = @import("lsp_types.zig");

const Diagnostic = lsp_types.Diagnostic;
const SymbolInfo = lsp_types.SymbolInfo;
const SymbolKind = lsp_types.SymbolKind;

// ============================================================
// JSON HELPERS
// ============================================================

pub fn jsonStr(value: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = switch (value) { .object => |o| o, else => return null };
    const val = obj.get(key) orelse return null;
    return switch (val) { .string => |s| s, else => null };
}

pub fn jsonObj(value: std.json.Value, key: []const u8) ?std.json.Value {
    const obj = switch (value) { .object => |o| o, else => return null };
    const val = obj.get(key) orelse return null;
    return switch (val) { .object => val, else => null };
}

pub fn jsonInt(value: std.json.Value, key: []const u8) ?i64 {
    const obj = switch (value) { .object => |o| o, else => return null };
    const val = obj.get(key) orelse return null;
    return switch (val) { .integer => |i| i, else => null };
}

pub fn jsonArray(value: std.json.Value, key: []const u8) ?[]std.json.Value {
    const obj = switch (value) { .object => |o| o, else => return null };
    const val = obj.get(key) orelse return null;
    return switch (val) { .array => |a| a.items, else => null };
}

pub fn jsonBool(value: std.json.Value, key: []const u8) bool {
    const obj = switch (value) { .object => |o| o, else => return false };
    const val = obj.get(key) orelse return false;
    return switch (val) { .bool => |b| b, else => false };
}

pub fn jsonId(root: std.json.Value) std.json.Value {
    return switch (root) {
        .object => |obj| obj.get("id") orelse .null,
        else => .null,
    };
}

// ============================================================
// JSON RESPONSE BUILDERS
// ============================================================

pub fn writeJsonValue(w: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: std.json.Value) !void {
    switch (value) {
        .integer => |i| {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0";
            try w.appendSlice(allocator, s);
        },
        .string => |s| {
            try w.append(allocator, '"');
            try appendJsonString(w, allocator, s);
            try w.append(allocator, '"');
        },
        .null => try w.appendSlice(allocator, "null"),
        else => try w.appendSlice(allocator, "null"),
    }
}

pub fn appendJsonString(w: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.appendSlice(allocator, "\\\""),
            '\\' => try w.appendSlice(allocator, "\\\\"),
            '\n' => try w.appendSlice(allocator, "\\n"),
            '\r' => try w.appendSlice(allocator, "\\r"),
            '\t' => try w.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                    try w.appendSlice(allocator, esc);
                } else {
                    try w.append(allocator, c);
                }
            },
        }
    }
}

pub fn appendInt(w: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: usize) !void {
    var nbuf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&nbuf, "{d}", .{val}) catch "0";
    try w.appendSlice(allocator, s);
}

pub fn buildInitializeResult(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator,
        \\,"result":{"capabilities":{"textDocumentSync":{"openClose":true,"change":1,"save":{"includeText":false}},"hoverProvider":true,"definitionProvider":true,"documentSymbolProvider":true,"completionProvider":{"triggerCharacters":["."]},"referencesProvider":true,"renameProvider":{"prepareProvider":false},"signatureHelpProvider":{"triggerCharacters":["(", ","]},"documentFormattingProvider":true,"workspaceSymbolProvider":true,"documentHighlightProvider":true,"foldingRangeProvider":true,"inlayHintProvider":true,"codeActionProvider":true},"serverInfo":{"name":"orhon-lsp","version":"0.8.2"}}}
    );

    return allocator.dupe(u8, buf.items);
}

pub fn buildEmptyArrayResponse(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":[]}");

    return allocator.dupe(u8, buf.items);
}

pub fn buildEmptyResponse(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":null}");

    return allocator.dupe(u8, buf.items);
}

pub fn buildDiagnosticsMsg(allocator: std.mem.Allocator, uri: []const u8, diags: []const Diagnostic) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
    try appendJsonString(&buf, allocator, uri);
    try buf.appendSlice(allocator, "\",\"diagnostics\":[");

    var first = true;
    for (diags) |d| {
        if (!std.mem.eql(u8, d.uri, uri)) continue;
        if (!first) try buf.append(allocator, ',');
        first = false;

        try buf.appendSlice(allocator, "{\"range\":{\"start\":{\"line\":");
        try appendInt(&buf, allocator, d.line);
        try buf.appendSlice(allocator, ",\"character\":");
        try appendInt(&buf, allocator, d.col);
        try buf.appendSlice(allocator, "},\"end\":{\"line\":");
        try appendInt(&buf, allocator, d.line);
        try buf.appendSlice(allocator, ",\"character\":");
        try appendInt(&buf, allocator, d.col + 1);
        try buf.appendSlice(allocator, "}},\"severity\":");
        try appendInt(&buf, allocator, d.severity);
        try buf.appendSlice(allocator, ",\"source\":\"orhon\",\"message\":\"");
        try appendJsonString(&buf, allocator, d.message);
        try buf.appendSlice(allocator, "\"}");
    }

    try buf.appendSlice(allocator, "]}}");
    return allocator.dupe(u8, buf.items);
}

// ============================================================
// PHASE 2 RESPONSE BUILDERS
// ============================================================

pub fn buildHoverResponse(allocator: std.mem.Allocator, id: std.json.Value, detail: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":{\"contents\":{\"kind\":\"markdown\",\"value\":\"```orhon\\n");
    try appendJsonString(&buf, allocator, detail);
    try buf.appendSlice(allocator, "\\n```\"}}}");

    return allocator.dupe(u8, buf.items);
}

pub fn buildDefinitionResponse(allocator: std.mem.Allocator, id: std.json.Value, uri: []const u8, line: usize, col: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":{\"uri\":\"");
    try appendJsonString(&buf, allocator, uri);
    try buf.appendSlice(allocator, "\",\"range\":{\"start\":{\"line\":");
    try appendInt(&buf, allocator, line);
    try buf.appendSlice(allocator, ",\"character\":");
    try appendInt(&buf, allocator, col);
    try buf.appendSlice(allocator, "},\"end\":{\"line\":");
    try appendInt(&buf, allocator, line);
    try buf.appendSlice(allocator, ",\"character\":");
    try appendInt(&buf, allocator, col);
    try buf.appendSlice(allocator, "}}}}");

    return allocator.dupe(u8, buf.items);
}

pub fn buildDocumentSymbolsResponse(allocator: std.mem.Allocator, id: std.json.Value, symbols: []const SymbolInfo, uri: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":[");

    // Use hierarchical DocumentSymbol format — children nested under parents
    var first = true;
    for (symbols) |s| {
        if (!std.mem.eql(u8, s.uri, uri)) continue;
        if (s.parent.len > 0) continue; // children handled below

        if (!first) try buf.append(allocator, ',');
        first = false;

        try appendDocumentSymbol(&buf, allocator, s, symbols, uri);
    }

    try buf.appendSlice(allocator, "]}");
    return allocator.dupe(u8, buf.items);
}

fn appendDocumentSymbol(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: SymbolInfo, all_symbols: []const SymbolInfo, uri: []const u8) !void {
    try buf.appendSlice(allocator, "{\"name\":\"");
    try appendJsonString(buf, allocator, s.name);
    try buf.appendSlice(allocator, "\",\"detail\":\"");
    try appendJsonString(buf, allocator, s.detail);
    try buf.appendSlice(allocator, "\",\"kind\":");
    try appendInt(buf, allocator, @intFromEnum(s.kind));
    // DocumentSymbol uses range + selectionRange (not location)
    try buf.appendSlice(allocator, ",\"range\":{\"start\":{\"line\":");
    try appendInt(buf, allocator, s.line);
    try buf.appendSlice(allocator, ",\"character\":");
    try appendInt(buf, allocator, s.col);
    try buf.appendSlice(allocator, "},\"end\":{\"line\":");
    try appendInt(buf, allocator, s.line);
    try buf.appendSlice(allocator, ",\"character\":");
    try appendInt(buf, allocator, s.col + s.name.len);
    try buf.appendSlice(allocator, "}},\"selectionRange\":{\"start\":{\"line\":");
    try appendInt(buf, allocator, s.line);
    try buf.appendSlice(allocator, ",\"character\":");
    try appendInt(buf, allocator, s.col);
    try buf.appendSlice(allocator, "},\"end\":{\"line\":");
    try appendInt(buf, allocator, s.line);
    try buf.appendSlice(allocator, ",\"character\":");
    try appendInt(buf, allocator, s.col + s.name.len);
    try buf.appendSlice(allocator, "}}");

    // Add children (fields, enum members)
    var has_children = false;
    for (all_symbols) |child| {
        if (!std.mem.eql(u8, child.uri, uri)) continue;
        if (!std.mem.eql(u8, child.parent, s.name)) continue;
        if (!has_children) {
            try buf.appendSlice(allocator, ",\"children\":[");
            has_children = true;
        } else {
            try buf.append(allocator, ',');
        }
        try appendDocumentSymbol(buf, allocator, child, &.{}, uri); // no recursive children
    }
    if (has_children) try buf.append(allocator, ']');

    try buf.append(allocator, '}');
}

// ============================================================
// TESTS
// ============================================================

test "appendJsonString escapes special characters" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try appendJsonString(&buf, std.testing.allocator, "hello \"world\"\nnew\\line");
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nnew\\\\line", buf.items);
}
