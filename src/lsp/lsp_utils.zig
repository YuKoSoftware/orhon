// lsp_utils.zig -- LSP URI helpers, text utilities, symbol lookup, and logging

const std = @import("std");
const lsp_types = @import("lsp_types.zig");
const parser = @import("../parser.zig");
const declarations = @import("../declarations.zig");
const builtins = @import("../builtins.zig");

const SymbolInfo = lsp_types.SymbolInfo;
const SymbolKind = lsp_types.SymbolKind;

// ============================================================
// LOGGING
// ============================================================

pub fn lspLog(comptime fmt: []const u8, args: anytype) void {
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

// ============================================================
// URI HELPERS
// ============================================================

/// Get document source: from in-memory store if available, otherwise from disk.
/// Caller must free the returned slice.
pub fn getDocSource(allocator: std.mem.Allocator, uri: []const u8, doc_store: *const std.StringHashMap([]u8)) ![]u8 {
    // Check in-memory store first (has unsaved changes)
    if (doc_store.get(uri)) |content| {
        return allocator.dupe(u8, content);
    }
    // Fall back to disk
    const path = uriToPath(uri) orelse return error.InvalidUri;
    return std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
}

pub fn uriToPath(uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) return uri[prefix.len..];
    return null;
}

pub fn pathToUri(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "file://{s}", .{path});
}

/// Given a file path inside src/, find the project root (parent of src/).
pub fn findProjectRoot(file_path: []const u8) ?[]const u8 {
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
// WORD-AT-POSITION — extract the identifier under cursor from source
// ============================================================

pub fn getWordAtPosition(source: []const u8, line_0: usize, col_0: usize) ?[]const u8 {
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

pub fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// Get the object name before the dot if the word is part of a `obj.member` expression.
/// Returns null if there's no dot prefix.
pub fn getDotContext(source: []const u8, line_0: usize, col_0: usize) ?[]const u8 {
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

pub fn getLinePrefix(source: []const u8, line_0: usize, col_0: usize) []const u8 {
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
pub fn getDotPrefix(prefix: []const u8) ?[]const u8 {
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
pub fn getModuleName(source: []const u8) ?[]const u8 {
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

/// Extract imported module names from "import std::console" -> "console", "import mymod" -> "mymod".
pub fn getImportedModules(source: []const u8, allocator: std.mem.Allocator) ?[]const []const u8 {
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
                // Get the last segment: "std::console" -> "console"
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

pub fn isVisibleModule(mod: []const u8, current_module: ?[]const u8, imports: ?[]const []const u8) bool {
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

// ============================================================
// SYMBOL LOOKUP — find symbol by name in cached symbols
// ============================================================

pub fn findSymbolByName(symbols: []const SymbolInfo, name: []const u8) ?SymbolInfo {
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

pub fn findVisibleSymbolByName(symbols: []const SymbolInfo, name: []const u8, current_module: ?[]const u8, imports: ?[]const []const u8) ?SymbolInfo {
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
pub fn findSymbolInContext(symbols: []const SymbolInfo, name: []const u8, context: []const u8) ?SymbolInfo {
    // Check if it's a module function (e.g. console.println -> module=console, name=println)
    for (symbols) |s| {
        if (std.mem.eql(u8, s.name, name) and std.mem.eql(u8, s.module, context)) return s;
    }
    // Check if it's a struct field (e.g. MyStruct.name -> parent=MyStruct, name=name)
    for (symbols) |s| {
        if (std.mem.eql(u8, s.name, name) and std.mem.eql(u8, s.parent, context)) return s;
    }
    return null;
}

/// Check if a name is a known module in the symbol cache
pub fn isOnModuleLine(source: []const u8, line_0: usize) bool {
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

pub fn isModuleName(symbols: []const SymbolInfo, name: []const u8) bool {
    for (symbols) |s| {
        if (std.mem.eql(u8, s.module, name)) return true;
    }
    return false;
}

/// Look up a builtin type or primitive by name, return hover detail
pub fn builtinDetail(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
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
        .{ "elif", "(keyword) chained conditional branch" },
        .{ "else", "(keyword) alternative branch" },
        .{ "for", "(keyword) iteration over a collection or range" },
        .{ "while", "(keyword) loop with condition" },
        .{ "return", "(keyword) return a value from function" },
        .{ "match", "(keyword) pattern matching" },
        .{ "struct", "(keyword) composite data type" },
        .{ "enum", "(keyword) enumerated type" },
        .{ "bitfield", "(keyword) bit-level flag type" },
        .{ "import", "(keyword) import a module (namespaced)" },
        .{ "use", "(keyword) use a module (flat, dumps symbols into scope)" },
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
        .{ "bridge", "(keyword) Zig bridge declaration" },
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
