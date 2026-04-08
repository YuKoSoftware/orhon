// lsp_edit.zig — LSP editing handlers (completion, rename, code actions, formatting)

const std = @import("std");
const lsp_types = @import("lsp_types.zig");
const lsp_json = @import("lsp_json.zig");
const lsp_utils = @import("lsp_utils.zig");
const builtins = @import("../builtins.zig");

const SymbolInfo = lsp_types.SymbolInfo;
const Diagnostic = lsp_types.Diagnostic;
const CompletionItemKind = lsp_types.CompletionItemKind;
const ParamLabels = lsp_types.ParamLabels;
const TrimResult = lsp_types.TrimResult;
const MAX_PARAMS = lsp_types.MAX_PARAMS;

const jsonStr = lsp_json.jsonStr;
const jsonObj = lsp_json.jsonObj;
const jsonInt = lsp_json.jsonInt;
const writeJsonValue = lsp_json.writeJsonValue;
const appendJsonString = lsp_json.appendJsonString;
const appendInt = lsp_json.appendInt;
const buildEmptyResponse = lsp_json.buildEmptyResponse;
const buildEmptyArrayResponse = lsp_json.buildEmptyArrayResponse;
const extractTextDocumentUri = lsp_json.extractTextDocumentUri;

const lspLog = lsp_utils.lspLog;
const getDocSource = lsp_utils.getDocSource;
const uriToPath = lsp_utils.uriToPath;
const pathToUri = lsp_utils.pathToUri;
const getWordAtPosition = lsp_utils.getWordAtPosition;
const isIdentChar = lsp_utils.isIdentChar;
const findWordOccurrences = lsp_utils.findWordOccurrences;
const getLinePrefix = lsp_utils.getLinePrefix;
const getDotPrefix = lsp_utils.getDotPrefix;
const getModuleName = lsp_utils.getModuleName;
const getImportedModules = lsp_utils.getImportedModules;
const isVisibleModule = lsp_utils.isVisibleModule;
const findVisibleSymbolByName = lsp_utils.findVisibleSymbolByName;

// ============================================================
// COMPLETION
// ============================================================

pub fn handleCompletion(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo, use_snippets: bool, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const uri = extractTextDocumentUri(params) orelse return buildEmptyResponse(allocator, id);
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
        "import", "pub", "match", "struct", "enum", "defer",
        "thread", "null", "void", "compt", "any", "module", "test",
        "and", "or", "not", "as", "break", "continue", "true", "false",
        "is",
    };
    for (keywords) |kw| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try appendCompletionItem(&buf, allocator, kw, "keyword", .keyword);
    }

    // Primitive types
    const primitives = [_][]const u8{
        "str", "bool", "i8", "i16", "i32", "i64", "i128",
        "u8", "u16", "u32", "u64", "u128", "isize", "usize",
        "f16", "f32", "f64", "f128",
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
// RENAME — rename a symbol across the project
// ============================================================

pub fn handleRename(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, symbols: []const SymbolInfo, project_root: ?[]const u8) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const uri = extractTextDocumentUri(params) orelse return buildEmptyResponse(allocator, id);
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
        collectOrhFiles(allocator, src_path, &file_uris) catch {};
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

        const occurrences = findWordOccurrences(allocator, file_source, word) catch continue;
        defer allocator.free(occurrences);
        for (occurrences) |occ| {
            if (!first_edit) try edits.append(allocator, ',');
            first_edit = false;
            try edits.appendSlice(allocator, "{\"range\":{\"start\":{\"line\":");
            try appendInt(&edits, allocator, occ.line);
            try edits.appendSlice(allocator, ",\"character\":");
            try appendInt(&edits, allocator, occ.col);
            try edits.appendSlice(allocator, "},\"end\":{\"line\":");
            try appendInt(&edits, allocator, occ.line);
            try edits.appendSlice(allocator, ",\"character\":");
            try appendInt(&edits, allocator, occ.col + word.len);
            try edits.appendSlice(allocator, "}},\"newText\":\"");
            try appendJsonString(&edits, allocator, new_name);
            try edits.appendSlice(allocator, "\"}");
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
fn collectOrhFiles(allocator: std.mem.Allocator, dir_path: []const u8, uris: *std.StringHashMap(void)) anyerror!void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            const sub = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(sub);
            try collectOrhFiles(allocator, sub, uris);
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
// FORMATTING — run `orhon fmt` on the file
// ============================================================

pub fn handleFormatting(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const uri = extractTextDocumentUri(params) orelse return buildEmptyResponse(allocator, id);

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
// CODE ACTIONS — quick fixes for diagnostics
// ============================================================

pub fn handleCodeAction(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value, diags: []const Diagnostic) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyArrayResponse(allocator, id);
    const uri = extractTextDocumentUri(params) orelse return buildEmptyArrayResponse(allocator, id);
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
            // "unknown type 'Foo'" -> suggest checking spelling or adding import
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

/// Parse parameter byte ranges from a signature like "func name(a: i32, b: str) void".
/// Returns offsets into the original string for each parameter.
pub fn extractParamLabels(sig: []const u8) ParamLabels {
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
    var start_pos: usize = 0;
    var param_depth: usize = 0;
    for (params_str, 0..) |c, i| {
        if (c == '(') param_depth += 1;
        if (c == ')') param_depth -= 1;
        if (c == ',' and param_depth == 0) {
            if (result.count >= MAX_PARAMS) return result;
            const trimmed = trimRange(params_str, start_pos, i);
            result.starts[result.count] = paren_start + 1 + trimmed.start;
            result.ends[result.count] = paren_start + 1 + trimmed.end;
            result.count += 1;
            start_pos = i + 1;
        }
    }
    // Last parameter
    if (result.count < MAX_PARAMS) {
        const trimmed = trimRange(params_str, start_pos, params_str.len);
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
// TESTS
// ============================================================

test "extractParamLabels single param" {
    const labels = extractParamLabels("func println(msg: str) void");
    try std.testing.expectEqual(@as(usize, 1), labels.count);
    try std.testing.expectEqualStrings("msg: str", "func println(msg: str) void"[labels.starts[0]..labels.ends[0]]);
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
