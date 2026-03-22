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
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const types = @import("types.zig");
const builtins = @import("builtins.zig");

const Io = std.Io;

// ============================================================
// JSON-RPC TRANSPORT
// ============================================================

/// Read a single LSP message from stdin.
/// Format: "Content-Length: N\r\n\r\n<N bytes of JSON>"
fn readMessage(reader: *Io.Reader, allocator: std.mem.Allocator) ![]u8 {
    var content_length: usize = 0;

    // Read headers line by line
    while (true) {
        var line_buf: [1024]u8 = undefined;
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

        const line = line_buf[0..line_len];
        if (line.len == 0) break;

        const prefix = "Content-Length: ";
        if (std.mem.startsWith(u8, line, prefix)) {
            content_length = std.fmt.parseInt(usize, line[prefix.len..], 10) catch return error.InvalidHeader;
        }
    }

    if (content_length == 0) return error.InvalidHeader;
    return reader.readAlloc(allocator, content_length) catch return error.EndOfStream;
}

/// Write an LSP message to stdout.
fn writeMessage(writer: *Io.Writer, json: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{json.len});
    try writer.writeAll(json);
    try writer.flush();
}

// ============================================================
// JSON HELPERS
// ============================================================

fn jsonStr(value: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = switch (value) { .object => |o| o, else => return null };
    const val = obj.get(key) orelse return null;
    return switch (val) { .string => |s| s, else => null };
}

fn jsonObj(value: std.json.Value, key: []const u8) ?std.json.Value {
    const obj = switch (value) { .object => |o| o, else => return null };
    const val = obj.get(key) orelse return null;
    return switch (val) { .object => val, else => null };
}

fn jsonInt(value: std.json.Value, key: []const u8) ?i64 {
    const obj = switch (value) { .object => |o| o, else => return null };
    const val = obj.get(key) orelse return null;
    return switch (val) { .integer => |i| i, else => null };
}

fn jsonArray(value: std.json.Value, key: []const u8) ?[]std.json.Value {
    const obj = switch (value) { .object => |o| o, else => return null };
    const val = obj.get(key) orelse return null;
    return switch (val) { .array => |a| a.items, else => null };
}

fn jsonBool(value: std.json.Value, key: []const u8) bool {
    const obj = switch (value) { .object => |o| o, else => return false };
    const val = obj.get(key) orelse return false;
    return switch (val) { .bool => |b| b, else => false };
}

fn jsonId(root: std.json.Value) std.json.Value {
    return switch (root) {
        .object => |obj| obj.get("id") orelse .null,
        else => .null,
    };
}

// ============================================================
// JSON RESPONSE BUILDERS
// ============================================================

fn writeJsonValue(w: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: std.json.Value) !void {
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

fn appendJsonString(w: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
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

fn appendInt(w: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: usize) !void {
    var nbuf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&nbuf, "{d}", .{val}) catch "0";
    try w.appendSlice(allocator, s);
}

fn buildInitializeResult(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator,
        \\,"result":{"capabilities":{"textDocumentSync":{"openClose":true,"change":1,"save":{"includeText":false}},"hoverProvider":true,"definitionProvider":true,"documentSymbolProvider":true,"completionProvider":{"triggerCharacters":["."]},"referencesProvider":true,"renameProvider":{"prepareProvider":false},"signatureHelpProvider":{"triggerCharacters":["(", ","]},"documentFormattingProvider":true,"workspaceSymbolProvider":true,"documentHighlightProvider":true,"foldingRangeProvider":true,"inlayHintProvider":true,"codeActionProvider":true},"serverInfo":{"name":"orhon-lsp","version":"0.4.2"}}}
    );

    return allocator.dupe(u8, buf.items);
}

fn buildEmptyArrayResponse(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":[]}");

    return allocator.dupe(u8, buf.items);
}

fn buildEmptyResponse(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":null}");

    return allocator.dupe(u8, buf.items);
}

const Diagnostic = struct {
    uri: []const u8,
    line: usize, // 0-based
    col: usize, // 0-based
    severity: u8, // 1=error, 2=warning
    message: []const u8,
};

fn buildDiagnosticsMsg(allocator: std.mem.Allocator, uri: []const u8, diags: []const Diagnostic) ![]u8 {
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
// SYMBOL INFO — cached analysis data for hover/definition/symbols
// ============================================================

/// LSP symbol kinds (subset we use)
const SymbolKind = enum(u8) {
    function = 12,
    struct_ = 23,
    enum_ = 10,
    variable = 13,
    constant = 14,
    field = 8,
    enum_member = 22,
};

/// Flattened symbol info extracted from DeclTable + LocMap.
/// All strings are owned by the allocator.
const SymbolInfo = struct {
    name: []const u8,
    detail: []const u8, // type signature for hover
    kind: SymbolKind,
    module: []const u8, // owning module name (e.g. "main", "console")
    parent: []const u8, // parent symbol name (e.g. "MyStruct" for fields, "" for top-level)
    uri: []const u8, // file URI
    line: usize, // 0-based
    col: usize, // 0-based
};

/// Result of running analysis — diagnostics + symbols
const AnalysisResult = struct {
    diagnostics: []Diagnostic,
    symbols: []SymbolInfo,
};

fn freeDiagnostics(allocator: std.mem.Allocator, diags: []Diagnostic) void {
    if (diags.len > 0) {
        for (diags) |d| {
            allocator.free(d.uri);
            allocator.free(d.message);
        }
        allocator.free(diags);
    }
}

fn freeSymbols(allocator: std.mem.Allocator, symbols: []SymbolInfo) void {
    if (symbols.len > 0) {
        for (symbols) |s| {
            allocator.free(s.name);
            allocator.free(s.detail);
            allocator.free(s.module);
            if (s.parent.len > 0) allocator.free(s.parent);
            allocator.free(s.uri);
        }
        allocator.free(symbols);
    }
}

// ============================================================
// URI HELPERS
// ============================================================

/// Get document source: from in-memory store if available, otherwise from disk.
/// Caller must free the returned slice.
fn getDocSource(allocator: std.mem.Allocator, uri: []const u8, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    // Check in-memory store first (has unsaved changes)
    if (doc_store.get(uri)) |content| {
        return allocator.dupe(u8, content);
    }
    // Fall back to disk
    const path = uriToPath(uri) orelse return error.InvalidUri;
    return std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
}

fn uriToPath(uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) return uri[prefix.len..];
    return null;
}

fn pathToUri(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "file://{s}", .{path});
}

/// Given a file path inside src/, find the project root (parent of src/).
fn findProjectRoot(file_path: []const u8) ?[]const u8 {
    var dir = std.fs.path.dirname(file_path) orelse return null;
    var depth: usize = 0;
    while (depth < 10) : (depth += 1) {
        if (std.mem.eql(u8, std.fs.path.basename(dir), "src")) {
            return std.fs.path.dirname(dir);
        }
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
    return null;
}

// ============================================================
// TYPE FORMATTING — for hover display
// ============================================================

fn formatType(allocator: std.mem.Allocator, t: types.ResolvedType) ![]u8 {
    return switch (t) {
        .primitive => |n| allocator.dupe(u8, n),
        .named => |n| allocator.dupe(u8, n),
        .err => allocator.dupe(u8, "Error"),
        .null_type => allocator.dupe(u8, "null"),
        .slice => |inner| blk: {
            const inner_s = try formatType(allocator, inner.*);
            defer allocator.free(inner_s);
            break :blk std.fmt.allocPrint(allocator, "[]{s}", .{inner_s});
        },
        .array => |a| blk: {
            const inner_s = try formatType(allocator, a.elem.*);
            defer allocator.free(inner_s);
            const size_str = if (a.size.* == .int_literal) a.size.int_literal else "N";
            break :blk std.fmt.allocPrint(allocator, "[{s}]{s}", .{ size_str, inner_s });
        },
        .error_union => |inner| blk: {
            const inner_s = try formatType(allocator, inner.*);
            defer allocator.free(inner_s);
            break :blk std.fmt.allocPrint(allocator, "(Error | {s})", .{inner_s});
        },
        .null_union => |inner| blk: {
            const inner_s = try formatType(allocator, inner.*);
            defer allocator.free(inner_s);
            break :blk std.fmt.allocPrint(allocator, "(null | {s})", .{inner_s});
        },
        .generic => |g| allocator.dupe(u8, g.name),
        .func_ptr => |f| blk: {
            const ret_s = try formatType(allocator, f.return_type.*);
            defer allocator.free(ret_s);
            break :blk std.fmt.allocPrint(allocator, "func(...) {s}", .{ret_s});
        },
        .ptr => |p| allocator.dupe(u8, p.kind),
        .inferred => allocator.dupe(u8, "inferred"),
        .unknown => allocator.dupe(u8, "unknown"),
        .tuple, .union_type => allocator.dupe(u8, t.name()),
    };
}

fn formatFuncSig(allocator: std.mem.Allocator, sig: declarations.FuncSig) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "func ");
    try buf.appendSlice(allocator, sig.name);
    try buf.append(allocator, '(');

    for (sig.params, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, p.name);
        try buf.appendSlice(allocator, ": ");
        const ts = try formatType(allocator, p.type_);
        defer allocator.free(ts);
        try buf.appendSlice(allocator, ts);
    }

    try buf.appendSlice(allocator, ") ");
    const ret_s = try formatType(allocator, sig.return_type);
    defer allocator.free(ret_s);
    try buf.appendSlice(allocator, ret_s);

    return allocator.dupe(u8, buf.items);
}

fn formatStructSig(allocator: std.mem.Allocator, sig: declarations.StructSig) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "struct ");
    try buf.appendSlice(allocator, sig.name);
    try buf.appendSlice(allocator, " { ");

    for (sig.fields, 0..) |f, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, f.name);
        try buf.appendSlice(allocator, ": ");
        const ts = try formatType(allocator, f.type_);
        defer allocator.free(ts);
        try buf.appendSlice(allocator, ts);
    }

    try buf.appendSlice(allocator, " }");
    return allocator.dupe(u8, buf.items);
}

fn formatEnumSig(allocator: std.mem.Allocator, sig: declarations.EnumSig) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "enum ");
    try buf.appendSlice(allocator, sig.name);
    try buf.appendSlice(allocator, " { ");

    for (sig.variants, 0..) |v, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, v);
    }

    try buf.appendSlice(allocator, " }");
    return allocator.dupe(u8, buf.items);
}

// ============================================================
// ANALYSIS — run passes 1–9, collect diagnostics + symbols
// ============================================================

fn runAnalysis(allocator: std.mem.Allocator, project_root: []const u8) !AnalysisResult {
    var empty = AnalysisResult{ .diagnostics = &.{}, .symbols = &.{} };

    const saved_cwd = std.fs.cwd();
    var proj_dir = std.fs.cwd().openDir(project_root, .{}) catch {
        log("analysis: failed to open project dir '{s}'", .{project_root});
        return empty;
    };
    defer proj_dir.close();
    proj_dir.setAsCwd() catch {
        log("analysis: failed to setAsCwd", .{});
        return empty;
    };
    defer saved_cwd.setAsCwd() catch {};

    // Ensure std files exist
    std.fs.cwd().makePath(cache.CACHE_DIR ++ "/std") catch {};

    var reporter = errors.Reporter.init(allocator, .debug);
    defer reporter.deinit();

    var mod_resolver = module.Resolver.init(allocator, &reporter);
    defer mod_resolver.deinit();

    std.fs.cwd().access("src", .{}) catch {
        log("analysis: no 'src' directory in '{s}'", .{project_root});
        return empty;
    };
    mod_resolver.scanDirectory("src") catch {
        log("analysis: scanDirectory failed", .{});
        empty.diagnostics = toDiagnostics(allocator, &reporter, project_root) catch &.{};
        return empty;
    };
    if (reporter.hasErrors()) {
        log("analysis: errors after scan", .{});
        empty.diagnostics = toDiagnostics(allocator, &reporter, project_root) catch &.{};
        return empty;
    }

    mod_resolver.checkCircularImports() catch {};
    if (reporter.hasErrors()) {
        log("analysis: circular import errors", .{});
        empty.diagnostics = toDiagnostics(allocator, &reporter, project_root) catch &.{};
        return empty;
    }

    mod_resolver.parseModules(allocator) catch {};
    if (reporter.hasErrors()) {
        log("analysis: parse errors (continuing with partial symbols)", .{});
    }

    // Second parse pass for std imports
    {
        var has_unparsed = false;
        var it = mod_resolver.modules.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.ast == null) { has_unparsed = true; break; }
        }
        if (has_unparsed) {
            mod_resolver.parseModules(allocator) catch {};
        }
    }

    mod_resolver.scanAndParseDeps(allocator, "src") catch {};
    mod_resolver.validateImports(&reporter) catch {};

    const order = mod_resolver.topologicalOrder(allocator) catch {
        log("analysis: topological order failed", .{});
        empty.diagnostics = toDiagnostics(allocator, &reporter, project_root) catch &.{};
        return empty;
    };
    defer allocator.free(order);

    // Collect symbols from all modules
    var all_symbols: std.ArrayListUnmanaged(SymbolInfo) = .{};
    log("analysis: processing {d} modules", .{order.len});

    // Passes 4–9 per module — continue to next module on errors so we
    // still get symbols from modules that compiled successfully.
    for (order) |mod_name| {
        const mod_ptr = mod_resolver.modules.getPtr(mod_name) orelse continue;
        const ast = mod_ptr.ast orelse continue;
        const locs_ptr: ?*const parser.LocMap = if (mod_ptr.locs) |*l| l else null;
        const source_file: []const u8 = if (mod_ptr.files.len > 0) mod_ptr.files[0] else "";
        const errors_before = reporter.errors.items.len;

        // Pass 4: Declarations
        var dc = declarations.DeclCollector.init(allocator, &reporter);
        defer dc.deinit();
        dc.locs = locs_ptr;
        dc.source_file = source_file;
        dc.collect(ast) catch {};
        if (reporter.errors.items.len > errors_before) {
            // Still extract what symbols we can from partial declarations
            extractSymbols(allocator, &all_symbols, &dc.table, ast, locs_ptr, source_file, project_root, mod_name) catch {};
            continue;
        }

        // Pass 5: Type Resolution
        var tr = resolver.TypeResolver.init(allocator, &dc.table, &reporter);
        defer tr.deinit();
        tr.locs = locs_ptr;
        tr.source_file = source_file;
        tr.resolve(ast) catch {};

        // Extract symbols from DeclTable + AST locations (even if type resolution had errors)
        extractSymbols(allocator, &all_symbols, &dc.table, ast, locs_ptr, source_file, project_root, mod_name) catch {};

        if (reporter.errors.items.len > errors_before) continue;

        // Pass 6: Ownership
        var oc = ownership.OwnershipChecker.init(allocator, &reporter);
        oc.locs = locs_ptr;
        oc.source_file = source_file;
        oc.decls = &dc.table;
        oc.check(ast) catch {};
        if (reporter.errors.items.len > errors_before) continue;

        // Pass 7: Borrow Checking
        var bc = borrow.BorrowChecker.init(allocator, &reporter);
        defer bc.deinit();
        bc.locs = locs_ptr;
        bc.source_file = source_file;
        bc.decls = &dc.table;
        bc.check(ast) catch {};
        if (reporter.errors.items.len > errors_before) continue;

        // Pass 8: Thread Safety
        var tc = thread_safety.ThreadSafetyChecker.init(allocator, &reporter);
        defer tc.deinit();
        tc.locs = locs_ptr;
        tc.source_file = source_file;
        tc.check(ast) catch {};
        if (reporter.errors.items.len > errors_before) continue;

        // Pass 9: Error Propagation
        var pc = propagation.PropChecker.init(allocator, &reporter, &dc.table);
        pc.locs = locs_ptr;
        pc.source_file = source_file;
        pc.check(ast) catch {};
    }

    const diags = toDiagnostics(allocator, &reporter, project_root) catch
        @as([]Diagnostic, &.{});
    const symbols = if (all_symbols.items.len > 0)
        (allocator.dupe(SymbolInfo, all_symbols.items) catch @as([]SymbolInfo, &.{}))
    else
        @as([]SymbolInfo, &.{});

    return .{ .diagnostics = diags, .symbols = symbols };
}

/// Walk AST top-level nodes and match them against DeclTable to build SymbolInfo entries.
fn extractSymbols(
    allocator: std.mem.Allocator,
    symbols: *std.ArrayListUnmanaged(SymbolInfo),
    table: *declarations.DeclTable,
    ast: *parser.Node,
    locs: ?*const parser.LocMap,
    source_file: []const u8,
    project_root: []const u8,
    mod_name: []const u8,
) !void {
    if (ast.* != .program) return;

    for (ast.program.top_level) |node| {
        switch (node.*) {
            .func_decl => |f| {
                const loc = nodeLocInfo(locs, node) orelse continue;
                const func_sig = table.funcs.get(f.name);
                const detail = if (func_sig) |sig|
                    formatFuncSig(allocator, sig) catch try allocator.dupe(u8, "func")
                else
                    try allocator.dupe(u8, "func");
                const func_uri = try makeUri(allocator, source_file, project_root);
                try symbols.append(allocator, .{
                    .name = try allocator.dupe(u8, f.name),
                    .detail = detail,
                    .kind = .function,
                    .module = try allocator.dupe(u8, mod_name),
                    .parent = "",
                    .uri = func_uri,
                    .line = if (loc.line > 0) loc.line - 1 else 0,
                    .col = if (loc.col > 0) loc.col - 1 else 0,
                });
                // Extract function parameters as symbols
                if (func_sig) |sig| {
                    for (f.params, 0..) |param_node, pi| {
                        const ploc = nodeLocInfo(locs, param_node) orelse continue;
                        const ptype = if (pi < sig.params.len)
                            formatType(allocator, sig.params[pi].type_) catch try allocator.dupe(u8, "param")
                        else
                            try allocator.dupe(u8, "param");
                        try symbols.append(allocator, .{
                            .name = try allocator.dupe(u8, sig.params[pi].name),
                            .detail = ptype,
                            .kind = .variable,
                            .module = try allocator.dupe(u8, mod_name),
                            .parent = try allocator.dupe(u8, f.name),
                            .uri = try allocator.dupe(u8, func_uri),
                            .line = if (ploc.line > 0) ploc.line - 1 else 0,
                            .col = if (ploc.col > 0) ploc.col - 1 else 0,
                        });
                    }
                }
                // Extract local variables from function body
                if (f.body.* == .block) {
                    extractLocals(allocator, symbols, f.body.block.statements, locs, func_uri, mod_name, f.name) catch {};
                }
            },
            .struct_decl => |s| {
                const loc = nodeLocInfo(locs, node) orelse continue;
                const detail = if (table.structs.get(s.name)) |sig|
                    formatStructSig(allocator, sig) catch try allocator.dupe(u8, "struct")
                else
                    try allocator.dupe(u8, "struct");
                try symbols.append(allocator, .{
                    .name = try allocator.dupe(u8, s.name),
                    .detail = detail,
                    .kind = .struct_,
                    .module = try allocator.dupe(u8, mod_name),
                    .parent = "",
                    .uri = try makeUri(allocator, source_file, project_root),
                    .line = if (loc.line > 0) loc.line - 1 else 0,
                    .col = if (loc.col > 0) loc.col - 1 else 0,
                });
                // Add struct fields as child symbols
                for (s.members) |member| {
                    if (member.* == .field_decl) {
                        const floc = nodeLocInfo(locs, member) orelse continue;
                        const fd = member.field_decl;
                        const ftype = if (table.structs.get(s.name)) |sig| blk: {
                            for (sig.fields) |field| {
                                if (std.mem.eql(u8, field.name, fd.name)) {
                                    break :blk formatType(allocator, field.type_) catch try allocator.dupe(u8, "field");
                                }
                            }
                            break :blk try allocator.dupe(u8, "field");
                        } else try allocator.dupe(u8, "field");
                        try symbols.append(allocator, .{
                            .name = try allocator.dupe(u8, fd.name),
                            .detail = ftype,
                            .kind = .field,
                            .module = try allocator.dupe(u8, mod_name),
                            .parent = try allocator.dupe(u8, s.name),
                            .uri = try makeUri(allocator, source_file, project_root),
                            .line = if (floc.line > 0) floc.line - 1 else 0,
                            .col = if (floc.col > 0) floc.col - 1 else 0,
                        });
                    }
                }
            },
            .enum_decl => |e| {
                const loc = nodeLocInfo(locs, node) orelse continue;
                const detail = if (table.enums.get(e.name)) |sig|
                    formatEnumSig(allocator, sig) catch try allocator.dupe(u8, "enum")
                else
                    try allocator.dupe(u8, "enum");
                try symbols.append(allocator, .{
                    .name = try allocator.dupe(u8, e.name),
                    .detail = detail,
                    .kind = .enum_,
                    .module = try allocator.dupe(u8, mod_name),
                    .parent = "",
                    .uri = try makeUri(allocator, source_file, project_root),
                    .line = if (loc.line > 0) loc.line - 1 else 0,
                    .col = if (loc.col > 0) loc.col - 1 else 0,
                });
                // Add enum variants
                for (e.members) |member| {
                    const mloc = nodeLocInfo(locs, member) orelse continue;
                    const vname = switch (member.*) {
                        .identifier => |id| id,
                        else => continue,
                    };
                    try symbols.append(allocator, .{
                        .name = try allocator.dupe(u8, vname),
                        .detail = try allocator.dupe(u8, e.name),
                        .kind = .enum_member,
                        .module = try allocator.dupe(u8, mod_name),
                        .parent = try allocator.dupe(u8, e.name),
                        .uri = try makeUri(allocator, source_file, project_root),
                        .line = if (mloc.line > 0) mloc.line - 1 else 0,
                        .col = if (mloc.col > 0) mloc.col - 1 else 0,
                    });
                }
            },
            .var_decl => |v| {
                const loc = nodeLocInfo(locs, node) orelse continue;
                const detail = if (table.vars.get(v.name)) |sig| blk: {
                    if (sig.type_) |t| break :blk formatType(allocator, t) catch try allocator.dupe(u8, "var");
                    break :blk try allocator.dupe(u8, "var");
                } else try allocator.dupe(u8, "var");
                try symbols.append(allocator, .{
                    .name = try allocator.dupe(u8, v.name),
                    .detail = detail,
                    .kind = .variable,
                    .module = try allocator.dupe(u8, mod_name),
                    .parent = "",
                    .uri = try makeUri(allocator, source_file, project_root),
                    .line = if (loc.line > 0) loc.line - 1 else 0,
                    .col = if (loc.col > 0) loc.col - 1 else 0,
                });
            },
            .const_decl => |cd| {
                const loc = nodeLocInfo(locs, node) orelse continue;
                const detail = if (table.vars.get(cd.name)) |sig| blk: {
                    if (sig.type_) |t| break :blk formatType(allocator, t) catch try allocator.dupe(u8, "const");
                    break :blk try allocator.dupe(u8, "const");
                } else try allocator.dupe(u8, "const");
                try symbols.append(allocator, .{
                    .name = try allocator.dupe(u8, cd.name),
                    .detail = detail,
                    .kind = .constant,
                    .module = try allocator.dupe(u8, mod_name),
                    .parent = "",
                    .uri = try makeUri(allocator, source_file, project_root),
                    .line = if (loc.line > 0) loc.line - 1 else 0,
                    .col = if (loc.col > 0) loc.col - 1 else 0,
                });
            },
            else => {},
        }
    }
}

/// Walk statements to extract local var/const declarations.
fn extractLocals(
    allocator: std.mem.Allocator,
    symbols: *std.ArrayListUnmanaged(SymbolInfo),
    statements: []*parser.Node,
    locs: ?*const parser.LocMap,
    uri: []const u8,
    mod_name: []const u8,
    func_name: []const u8,
) !void {
    for (statements) |stmt| {
        switch (stmt.*) {
            .var_decl => |v| {
                const loc = nodeLocInfo(locs, stmt) orelse continue;
                const detail = if (v.type_annotation) |ta|
                    nodeTypeStr(ta)
                else
                    "var";
                try symbols.append(allocator, .{
                    .name = try allocator.dupe(u8, v.name),
                    .detail = try allocator.dupe(u8, detail),
                    .kind = .variable,
                    .module = try allocator.dupe(u8, mod_name),
                    .parent = try allocator.dupe(u8, func_name),
                    .uri = try allocator.dupe(u8, uri),
                    .line = if (loc.line > 0) loc.line - 1 else 0,
                    .col = if (loc.col > 0) loc.col - 1 else 0,
                });
            },
            .const_decl => |c| {
                const loc = nodeLocInfo(locs, stmt) orelse continue;
                const detail = if (c.type_annotation) |ta|
                    nodeTypeStr(ta)
                else
                    "const";
                try symbols.append(allocator, .{
                    .name = try allocator.dupe(u8, c.name),
                    .detail = try allocator.dupe(u8, detail),
                    .kind = .constant,
                    .module = try allocator.dupe(u8, mod_name),
                    .parent = try allocator.dupe(u8, func_name),
                    .uri = try allocator.dupe(u8, uri),
                    .line = if (loc.line > 0) loc.line - 1 else 0,
                    .col = if (loc.col > 0) loc.col - 1 else 0,
                });
            },
            // Recurse into nested blocks
            .block => |b| try extractLocals(allocator, symbols, b.statements, locs, uri, mod_name, func_name),
            .if_stmt => |ifs| {
                if (ifs.then_block.* == .block)
                    try extractLocals(allocator, symbols, ifs.then_block.block.statements, locs, uri, mod_name, func_name);
                if (ifs.else_block) |eb| {
                    if (eb.* == .block)
                        try extractLocals(allocator, symbols, eb.block.statements, locs, uri, mod_name, func_name);
                }
            },
            .for_stmt => |fs| {
                if (fs.body.* == .block)
                    try extractLocals(allocator, symbols, fs.body.block.statements, locs, uri, mod_name, func_name);
            },
            .while_stmt => |ws| {
                if (ws.body.* == .block)
                    try extractLocals(allocator, symbols, ws.body.block.statements, locs, uri, mod_name, func_name);
            },
            else => {},
        }
    }
}

/// Get a simple type name string from a type annotation AST node.
fn nodeTypeStr(node: *parser.Node) []const u8 {
    return switch (node.*) {
        .type_primitive => |p| p,
        .type_named => |n| n,
        .identifier => |id| id,
        else => "var",
    };
}

fn nodeLocInfo(locs: ?*const parser.LocMap, node: *parser.Node) ?errors.SourceLoc {
    const l = locs orelse return null;
    return l.get(node);
}

fn makeUri(allocator: std.mem.Allocator, source_file: []const u8, project_root: []const u8) ![]u8 {
    if (source_file.len == 0) return allocator.dupe(u8, "file:///unknown");
    const full_path = if (!std.fs.path.isAbsolute(source_file))
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, source_file })
    else
        try allocator.dupe(u8, source_file);
    defer if (!std.fs.path.isAbsolute(source_file)) allocator.free(full_path);
    return pathToUri(allocator, full_path);
}

/// Convert Reporter errors/warnings into LSP Diagnostics with file URIs.
fn toDiagnostics(allocator: std.mem.Allocator, reporter: *errors.Reporter, project_root: []const u8) ![]Diagnostic {
    var diags: std.ArrayListUnmanaged(Diagnostic) = .{};

    for (reporter.errors.items) |err| {
        const d = makeDiag(allocator, err, 1, project_root) catch continue;
        try diags.append(allocator, d);
    }
    for (reporter.warnings.items) |warn| {
        const d = makeDiag(allocator, warn, 2, project_root) catch continue;
        try diags.append(allocator, d);
    }

    return if (diags.items.len > 0) allocator.dupe(Diagnostic, diags.items) else &.{};
}

fn makeDiag(allocator: std.mem.Allocator, err: errors.OrhonError, severity: u8, project_root: []const u8) !Diagnostic {
    const loc = err.loc orelse return error.NoLoc;
    if (loc.file.len == 0) return error.NoLoc;

    const full_path = if (!std.fs.path.isAbsolute(loc.file))
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, loc.file })
    else
        try allocator.dupe(u8, loc.file);

    return .{
        .uri = try pathToUri(allocator, full_path),
        .line = if (loc.line > 0) loc.line - 1 else 0,
        .col = if (loc.col > 0) loc.col - 1 else 0,
        .severity = severity,
        .message = try allocator.dupe(u8, err.message),
    };
}

// ============================================================
// PHASE 2 RESPONSE BUILDERS
// ============================================================

fn buildHoverResponse(allocator: std.mem.Allocator, id: std.json.Value, detail: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":{\"contents\":{\"kind\":\"markdown\",\"value\":\"```orhon\\n");
    try appendJsonString(&buf, allocator, detail);
    try buf.appendSlice(allocator, "\\n```\"}}}");

    return allocator.dupe(u8, buf.items);
}

fn buildDefinitionResponse(allocator: std.mem.Allocator, id: std.json.Value, uri: []const u8, line: usize, col: usize) ![]u8 {
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

fn buildDocumentSymbolsResponse(allocator: std.mem.Allocator, id: std.json.Value, symbols: []const SymbolInfo, uri: []const u8) ![]u8 {
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
// WORD-AT-POSITION — extract the identifier under cursor from source
// ============================================================

fn getWordAtPosition(source: []const u8, line_0: usize, col_0: usize) ?[]const u8 {
    // Find the target line
    var current_line: usize = 0;
    var line_start: usize = 0;
    for (source, 0..) |c, i| {
        if (current_line == line_0) {
            line_start = i;
            break;
        }
        if (c == '\n') current_line += 1;
    } else {
        // Reached end without finding the line
        if (current_line == line_0) line_start = source.len else return null;
    }

    // Find line end
    var line_end = line_start;
    while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

    const line_text = source[line_start..line_end];
    if (col_0 >= line_text.len) return null;

    // Expand from cursor position to find word boundaries
    var start = col_0;
    while (start > 0 and isIdentChar(line_text[start - 1])) : (start -= 1) {}
    var end = col_0;
    while (end < line_text.len and isIdentChar(line_text[end])) : (end += 1) {}

    if (start == end) return null;
    return line_text[start..end];
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Get the object name before the dot if the word is part of a `obj.member` expression.
/// Returns null if there's no dot prefix.
fn getDotContext(source: []const u8, line_0: usize, col_0: usize) ?[]const u8 {
    var current_line: usize = 0;
    var line_start: usize = 0;
    for (source, 0..) |c, i| {
        if (current_line == line_0) {
            line_start = i;
            break;
        }
        if (c == '\n') current_line += 1;
    } else {
        if (current_line == line_0) line_start = source.len else return null;
    }

    var line_end = line_start;
    while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

    const line_text = source[line_start..line_end];
    if (col_0 >= line_text.len) return null;

    // Find start of current word
    var start = col_0;
    while (start > 0 and isIdentChar(line_text[start - 1])) : (start -= 1) {}

    // Check if there's a dot before the word
    if (start == 0 or line_text[start - 1] != '.') return null;

    // Find the object name before the dot
    const obj_end = start - 1;
    var obj_start = obj_end;
    while (obj_start > 0 and isIdentChar(line_text[obj_start - 1])) : (obj_start -= 1) {}

    if (obj_start == obj_end) return null;
    return line_text[obj_start..obj_end];
}

// ============================================================
// SYMBOL LOOKUP — find symbol by name in cached symbols
// ============================================================

fn findSymbolByName(symbols: []const SymbolInfo, name: []const u8) ?SymbolInfo {
    // Prefer top-level symbols (not fields/enum members)
    for (symbols) |s| {
        if (std.mem.eql(u8, s.name, name) and s.parent.len == 0) return s;
    }
    // Fallback: any symbol with this name
    for (symbols) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

fn findVisibleSymbolByName(symbols: []const SymbolInfo, name: []const u8, current_module: ?[]const u8, imports: ?[]const []const u8) ?SymbolInfo {
    // Prefer top-level symbols from visible modules
    for (symbols) |s| {
        if (std.mem.eql(u8, s.name, name) and s.parent.len == 0 and isVisibleModule(s.module, current_module, imports)) return s;
    }
    // Fallback: any symbol with this name from visible modules
    for (symbols) |s| {
        if (std.mem.eql(u8, s.name, name) and isVisibleModule(s.module, current_module, imports)) return s;
    }
    return null;
}

/// Find a symbol by name within a specific module or parent context
fn findSymbolInContext(symbols: []const SymbolInfo, name: []const u8, context: []const u8) ?SymbolInfo {
    // Check if it's a module function (e.g. console.println → module=console, name=println)
    for (symbols) |s| {
        if (std.mem.eql(u8, s.name, name) and std.mem.eql(u8, s.module, context)) return s;
    }
    // Check if it's a struct field (e.g. MyStruct.name → parent=MyStruct, name=name)
    for (symbols) |s| {
        if (std.mem.eql(u8, s.name, name) and std.mem.eql(u8, s.parent, context)) return s;
    }
    return null;
}

/// Check if a name is a known module in the symbol cache
fn isOnModuleLine(source: []const u8, line_0: usize) bool {
    var cur_line: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (cur_line == line_0) {
            // Skip leading whitespace
            while (i < source.len and source[i] == ' ') : (i += 1) {}
            const rest = source[i..];
            return std.mem.startsWith(u8, rest, "module ");
        }
        if (source[i] == '\n') cur_line += 1;
    }
    return false;
}

fn isModuleName(symbols: []const SymbolInfo, name: []const u8) bool {
    for (symbols) |s| {
        if (std.mem.eql(u8, s.module, name)) return true;
    }
    return false;
}

/// Look up a builtin type or primitive by name, return hover detail
fn builtinDetail(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    // Primitive types
    const primitives = [_][]const u8{
        "String", "bool",
        "i8", "i16", "i32", "i64", "i128",
        "u8", "u16", "u32", "u64", "u128",
        "isize", "usize",
        "f16", "f32", "f64", "f128", "bf16",
    };
    for (primitives) |p| {
        if (std.mem.eql(u8, name, p)) {
            return std.fmt.allocPrint(allocator, "(primitive type) {s}", .{p}) catch null;
        }
    }
    // Builtin types
    for (builtins.BUILTIN_TYPES) |bt| {
        if (std.mem.eql(u8, name, bt)) {
            return std.fmt.allocPrint(allocator, "(builtin type) {s}", .{bt}) catch null;
        }
    }
    // Keywords
    const keyword_info = std.StaticStringMap([]const u8).initComptime(.{
        .{ "null", "(keyword) null — the absence of a value" },
        .{ "true", "(keyword) bool literal" },
        .{ "false", "(keyword) bool literal" },
        .{ "func", "(keyword) function declaration" },
        .{ "var", "(keyword) mutable variable declaration" },
        .{ "const", "(keyword) immutable variable declaration" },
        .{ "if", "(keyword) conditional branch" },
        .{ "else", "(keyword) alternative branch" },
        .{ "for", "(keyword) iteration over a collection or range" },
        .{ "while", "(keyword) loop with condition" },
        .{ "return", "(keyword) return a value from function" },
        .{ "match", "(keyword) pattern matching" },
        .{ "struct", "(keyword) composite data type" },
        .{ "enum", "(keyword) enumerated type" },
        .{ "bitfield", "(keyword) bit-level flag type" },
        .{ "import", "(keyword) import a module" },
        .{ "module", "(keyword) module declaration" },
        .{ "pub", "(keyword) public visibility modifier" },
        .{ "defer", "(keyword) execute on scope exit" },
        .{ "break", "(keyword) exit loop" },
        .{ "continue", "(keyword) skip to next iteration" },
        .{ "and", "(keyword) logical AND operator" },
        .{ "or", "(keyword) logical OR operator" },
        .{ "not", "(keyword) logical NOT operator" },
        .{ "as", "(keyword) type conversion" },
        .{ "is", "(keyword) type check" },
        .{ "cast", "(keyword) explicit type cast" },
        .{ "copy", "(keyword) copy value" },
        .{ "move", "(keyword) move ownership" },
        .{ "swap", "(keyword) swap two values" },
        .{ "thread", "(keyword) spawn a thread" },
        .{ "compt", "(keyword) compile-time evaluation" },
        .{ "test", "(keyword) test block" },
        .{ "extern", "(keyword) external linkage" },
        .{ "any", "(keyword) any type" },
        .{ "void", "(keyword) no return value" },
        .{ "assert", "(builtin) runtime assertion" },
        .{ "size", "(builtin) size of a type in bytes" },
        .{ "align", "(builtin) alignment of a type" },
        .{ "typename", "(builtin) name of a type as String" },
        .{ "typeid", "(builtin) unique type identifier" },
        .{ "typeOf", "(builtin) returns the type of a value as a first-class type" },
        .{ "type", "(keyword) first-class type — use as parameter type or return type" },
    });
    if (keyword_info.get(name)) |info| {
        return allocator.dupe(u8, info) catch null;
    }
    return null;
}

// ============================================================
// LSP SERVER
// ============================================================

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    const stderr = &w.interface;
    stderr.print("[orhon-lsp] " ++ fmt ++ "\n", args) catch {};
    stderr.flush() catch {};

    // Format into a stack buffer, then append to log file
    var log_buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&log_buf, "[orhon-lsp] " ++ fmt ++ "\n", args) catch return;
    const log_path = "/tmp/orhon-lsp.log";
    const file = std.fs.cwd().openFile(log_path, .{ .mode = .write_only }) catch
        std.fs.cwd().createFile(log_path, .{}) catch return;
    defer file.close();
    file.seekFromEnd(0) catch {};
    file.writeAll(msg) catch {};
}

pub fn serve(allocator: std.mem.Allocator) !void {
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var stdin_buf: [65536]u8 = undefined;
    var stdin_r = stdin_file.reader(&stdin_buf);
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var stdout_buf: [65536]u8 = undefined;
    var stdout_w = stdout_file.writer(&stdout_buf);

    const stdin: *Io.Reader = &stdin_r.interface;
    const stdout: *Io.Writer = &stdout_w.interface;

    log("server starting", .{});

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
            if (err == error.EndOfStream) { log("client disconnected", .{}); return; }
            log("read error: {}", .{err});
            continue;
        };
        defer allocator.free(body);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            log("invalid JSON", .{});
            continue;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const method = jsonStr(root, "method") orelse "";
        const id = jsonId(root);

        if (std.mem.eql(u8, method, "initialize")) {
            log("initialize", .{});
            if (jsonObj(root, "params")) |params| {
                if (jsonStr(params, "rootUri")) |root_uri| {
                    if (uriToPath(root_uri)) |path| {
                        project_root = try allocator.dupe(u8, path);
                        log("project root: {s}", .{path});
                    }
                }
                // Read client settings from initializationOptions
                if (jsonObj(params, "initializationOptions")) |opts| {
                    enable_inlay_hints = jsonBool(opts, "inlayHints");
                    enable_snippets = jsonBool(opts, "completionSnippets");
                    log("settings: inlayHints={}, snippets={}", .{ enable_inlay_hints, enable_snippets });
                }
            }
            const resp = try buildInitializeResult(allocator, id);
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "initialized")) {
            initialized = true;
            log("initialized", .{});
            if (project_root) |r| {
                const result = try runAndPublishWithDiags(allocator, stdout, r, &open_docs, cached_symbols);
                cached_symbols = result.symbols;
                freeDiagnostics(allocator, cached_diags);
                cached_diags = result.diags;
            }

        } else if (std.mem.eql(u8, method, "shutdown")) {
            log("shutdown", .{});
            const resp = try buildEmptyResponse(allocator, id);
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "exit")) {
            log("exit", .{});
            return;

        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            if (!initialized) continue;
            if (jsonObj(root, "params")) |params| {
                if (jsonObj(params, "textDocument")) |td| {
                    if (jsonStr(td, "uri")) |uri| {
                        log("didOpen: {s}", .{uri});
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
                                    log("detected root: {s}", .{r});
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
            log("didSave", .{});
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
                        log("didClose: {s}", .{uri});
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
                log("hover error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            if (!initialized) continue;
            const resp = handleDefinition(allocator, root, id, cached_symbols, &doc_store) catch |err| {
                log("definition error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            if (!initialized) continue;
            const resp = handleDocumentSymbols(allocator, root, id, cached_symbols) catch |err| {
                log("documentSymbol error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            if (!initialized) continue;
            const resp = handleCompletion(allocator, root, id, cached_symbols, enable_snippets, &doc_store) catch |err| {
                log("completion error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            if (!initialized) continue;
            const resp = handleReferences(allocator, root, id, cached_symbols) catch |err| {
                log("references error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            if (!initialized) continue;
            const resp = handleRename(allocator, root, id, cached_symbols, project_root) catch |err| {
                log("rename error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            if (!initialized) continue;
            const resp = handleSignatureHelp(allocator, root, id, cached_symbols, &doc_store) catch |err| {
                log("signatureHelp error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
            if (!initialized) continue;
            const resp = handleFormatting(allocator, root, id) catch |err| {
                log("formatting error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "workspace/symbol")) {
            if (!initialized) continue;
            const resp = handleWorkspaceSymbol(allocator, root, id, cached_symbols) catch |err| {
                log("workspaceSymbol error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/codeAction")) {
            if (!initialized) continue;
            const resp = handleCodeAction(allocator, root, id, cached_diags) catch |err| {
                log("codeAction error: {}", .{err});
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
                log("inlayHint error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/documentHighlight")) {
            if (!initialized) continue;
            const resp = handleDocumentHighlight(allocator, root, id, &doc_store) catch |err| {
                log("documentHighlight error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
            if (!initialized) continue;
            const resp = handleFoldingRange(allocator, root, id, &doc_store) catch |err| {
                log("foldingRange error: {}", .{err});
                try writeMessage(stdout, try buildEmptyResponse(allocator, id));
                continue;
            };
            defer allocator.free(resp);
            try writeMessage(stdout, resp);

        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            if (!initialized) continue;
            const resp = handleSemanticTokens(allocator, root, id) catch |err| {
                log("semanticTokens error: {}", .{err});
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
const PublishResult = struct {
    symbols: []SymbolInfo,
    diags: []Diagnostic,
};

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

    log("cached {d} symbols", .{result.symbols.len});
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
        log("hover: failed to read source: {}", .{err});
        return buildEmptyResponse(allocator, id);
    };
    defer allocator.free(source);

    const word = getWordAtPosition(source, line_0, col_0) orelse {
        log("hover: no word at {d}:{d}", .{ line_0, col_0 });
        return buildEmptyResponse(allocator, id);
    };
    // Check for dot context (e.g. hovering over "println" in "console.println")
    const dot_ctx = getDotContext(source, line_0, col_0);
    if (dot_ctx) |ctx| {
        log("hover: '{s}.{s}' at {d}:{d} ({d} symbols cached)", .{ ctx, word, line_0, col_0, symbols.len });
    } else {
        log("hover: '{s}' at {d}:{d} ({d} symbols cached)", .{ word, line_0, col_0, symbols.len });
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
    if (dot_ctx) |ctx| {
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

    log("hover: no match for '{s}'", .{word});
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
    const dot_ctx = getDotContext(source, line_0, col_0);
    log("definition: '{s}' ({d} symbols)", .{ word, symbols.len });

    // Determine which modules are visible in this file
    const current_module = getModuleName(source);
    const imports = getImportedModules(source, allocator);
    defer if (imports) |imps| allocator.free(imps);

    // Context-aware lookup first
    if (dot_ctx) |ctx| {
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
    log("documentSymbol: {s}", .{uri});

    return buildDocumentSymbolsResponse(allocator, id, symbols, uri);
}

// ============================================================
// COMPLETION
// ============================================================

/// LSP CompletionItemKind values
const CompletionItemKind = enum(u8) {
    keyword = 14,
    function = 3,
    struct_ = 22,
    enum_ = 13,
    variable = 6,
    constant = 21,
    field = 5,
    enum_member = 20,
    type_ = 25, // for builtin/primitive types
};

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
    log("completion: prefix='{s}'", .{prefix});

    // Determine which modules are visible in this file
    const current_module = getModuleName(source);
    const imports = getImportedModules(source, allocator);
    defer if (imports) |imps| allocator.free(imps);

    // Check if we're after a dot — offer struct fields or module functions
    if (getDotPrefix(prefix)) |obj_name| {
        log("completion: dot context, object='{s}'", .{obj_name});
        return buildDotCompletionResponse(allocator, id, symbols, obj_name, use_snippets);
    }

    // General completion: keywords + symbols + types
    return buildGeneralCompletionResponse(allocator, id, symbols, current_module, imports, use_snippets);
}

fn getLinePrefix(source: []const u8, line_0: usize, col_0: usize) []const u8 {
    var current_line: usize = 0;
    var line_start: usize = 0;
    for (source, 0..) |c, i| {
        if (current_line == line_0) {
            line_start = i;
            break;
        }
        if (c == '\n') current_line += 1;
    } else {
        if (current_line == line_0) line_start = source.len else return "";
    }

    var line_end = line_start;
    while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

    const line_text = source[line_start..line_end];
    if (col_0 > line_text.len) return line_text;
    return line_text[0..col_0];
}

/// If prefix ends with `identifier.`, return the identifier before the dot.
fn getDotPrefix(prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0) return null;
    // Find the last dot
    var i = prefix.len;
    while (i > 0) : (i -= 1) {
        if (prefix[i - 1] == '.') {
            // Walk backwards from dot to find identifier start
            var j = i - 1;
            while (j > 0 and isIdentChar(prefix[j - 1])) : (j -= 1) {}
            if (j < i - 1) return prefix[j .. i - 1];
            return null;
        }
        if (!isIdentChar(prefix[i - 1])) return null;
    }
    return null;
}

/// Extract "module <name>" from source, return the name or null.
fn getModuleName(source: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < source.len) {
        // Skip whitespace
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
        if (i + 7 <= source.len and std.mem.eql(u8, source[i .. i + 7], "module ")) {
            var start = i + 7;
            while (start < source.len and source[start] == ' ') : (start += 1) {}
            var end = start;
            while (end < source.len and isIdentChar(source[end])) : (end += 1) {}
            if (end > start) return source[start..end];
        }
        // Skip to next line
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        if (i < source.len) i += 1;
    }
    return null;
}

/// Extract imported module names from "import std::console" → "console", "import mymod" → "mymod".
fn getImportedModules(source: []const u8, allocator: std.mem.Allocator) ?[]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    var i: usize = 0;
    while (i < source.len) {
        // Skip whitespace
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
        if (i + 7 <= source.len and std.mem.eql(u8, source[i .. i + 7], "import ")) {
            var start = i + 7;
            while (start < source.len and source[start] == ' ') : (start += 1) {}
            var end = start;
            while (end < source.len and (isIdentChar(source[end]) or source[end] == ':')) : (end += 1) {}
            if (end > start) {
                // Get the last segment: "std::console" → "console"
                const full = source[start..end];
                const name = if (std.mem.lastIndexOf(u8, full, "::")) |sep|
                    full[sep + 2 ..]
                else
                    full;
                if (name.len > 0) list.append(allocator, name) catch {};
            }
        }
        // Skip to next line
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        if (i < source.len) i += 1;
    }
    if (list.items.len == 0) {
        list.deinit(allocator);
        return null;
    }
    const result = allocator.dupe([]const u8, list.items) catch {
        list.deinit(allocator);
        return null;
    };
    list.deinit(allocator);
    return result;
}

fn isVisibleModule(mod: []const u8, current_module: ?[]const u8, imports: ?[]const []const u8) bool {
    if (current_module) |cm| {
        if (std.mem.eql(u8, mod, cm)) return true;
    }
    if (imports) |imps| {
        for (imps) |imp| {
            if (std.mem.eql(u8, mod, imp)) return true;
        }
    }
    return false;
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
        "func", "var", "const", "if", "else", "for", "while", "return",
        "import", "pub", "match", "struct", "enum", "bitfield", "defer",
        "thread", "null", "void", "compt", "any", "module", "test",
        "and", "or", "not", "as", "break", "continue", "true", "false",
        "extern", "is",
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
    log("references: '{s}'", .{word});

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
    log("rename: '{s}' -> '{s}'", .{ word, new_name });

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
    log("signatureHelp: func='{s}' activeParam={d}", .{ call_info.func_name, call_info.active_param });

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

const CallContext = struct {
    func_name: []const u8,
    obj_name: ?[]const u8, // e.g. "console" in "console.println("
    active_param: usize,
};

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
    log("formatting: {s}", .{path});

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
    log("workspaceSymbol: query='{s}'", .{query});

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
    log("inlayHint: {s}", .{uri});

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

    log("codeAction: {s} line {d}", .{ uri, start_line });

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

const MAX_PARAMS = 16;

const ParamLabels = struct {
    starts: [MAX_PARAMS]usize,
    ends: [MAX_PARAMS]usize,
    count: usize,
};

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

const TrimResult = struct { start: usize, end: usize };

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
    log("documentHighlight: '{s}'", .{word});

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
    log("foldingRange: {s}", .{uri});

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

/// Token type indices (must match legend in capabilities)
const SemanticTokenType = enum(u8) {
    keyword = 0,
    type_ = 1,
    function = 2,
    variable = 3,
    string = 4,
    number = 5,
    comment = 6,
    operator = 7,
    parameter = 8,
    enum_member = 9,
    property = 10,
    namespace = 11,
};

/// Token modifier bit flags (must match legend)
const SemanticModifier = struct {
    const declaration: u32 = 1 << 0;
    const definition: u32 = 1 << 1;
    const readonly: u32 = 1 << 2;
};

fn handleSemanticTokens(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const td = jsonObj(params, "textDocument") orelse return buildEmptyResponse(allocator, id);
    const uri = jsonStr(td, "uri") orelse return buildEmptyResponse(allocator, id);

    const path = uriToPath(uri) orelse return buildEmptyResponse(allocator, id);
    const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(source);
    log("semanticTokens: {s}", .{path});

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

const SemanticToken = struct {
    line: usize,
    col: usize,
    length: usize,
    token_type: u8,
    modifiers: u32,
};

const TokenClassification = struct {
    token_type: ?SemanticTokenType,
    modifiers: u32,
};

fn classifyToken(kind: lexer.TokenKind) TokenClassification {
    return switch (kind) {
        // Keywords
        .kw_func, .kw_var, .kw_const, .kw_struct, .kw_enum, .kw_bitfield,
        .kw_module, .kw_import, .kw_pub, .kw_extern, .kw_compt, .kw_test,
        .kw_if, .kw_else, .kw_for, .kw_while, .kw_return, .kw_match,
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

test "uriToPath converts file URI" {
    const path = uriToPath("file:///home/user/project/src/main.orh");
    try std.testing.expectEqualStrings("/home/user/project/src/main.orh", path.?);
}

test "uriToPath returns null for non-file URI" {
    try std.testing.expect(uriToPath("https://example.com") == null);
}

test "findProjectRoot detects src directory" {
    const root = findProjectRoot("/home/user/project/src/main.orh");
    try std.testing.expectEqualStrings("/home/user/project", root.?);
}

test "appendJsonString escapes special characters" {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try appendJsonString(&buf, std.testing.allocator, "hello \"world\"\nnew\\line");
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nnew\\\\line", buf.items);
}

test "readMessage parses LSP header" {
    const input = "Content-Length: 13\r\n\r\n{\"test\":true}";
    var reader = Io.Reader.fixed(input);
    const body = try readMessage(&reader, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{\"test\":true}", body);
}

test "getWordAtPosition finds identifier" {
    const source = "func main() void {\n    console.println(x)\n}";
    const word = getWordAtPosition(source, 0, 5);
    try std.testing.expectEqualStrings("main", word.?);
}

test "getWordAtPosition finds word on second line" {
    const source = "func main() void {\n    console.println(x)\n}";
    const word = getWordAtPosition(source, 1, 6);
    try std.testing.expectEqualStrings("console", word.?);
}

test "isIdentChar recognizes valid chars" {
    try std.testing.expect(isIdentChar('a'));
    try std.testing.expect(isIdentChar('Z'));
    try std.testing.expect(isIdentChar('_'));
    try std.testing.expect(isIdentChar('5'));
    try std.testing.expect(!isIdentChar('.'));
    try std.testing.expect(!isIdentChar(' '));
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
