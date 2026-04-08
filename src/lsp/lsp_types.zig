// lsp_types.zig — LSP shared type definitions and constants

const std = @import("std");

// ============================================================
// TRANSPORT CONSTANTS
// ============================================================

pub const MAX_HEADER_LINE: usize = 4096;
pub const MAX_CONTENT_LENGTH: usize = 64 * 1024 * 1024; // 64 MiB

// ============================================================
// DIAGNOSTICS
// ============================================================

pub const Diagnostic = struct {
    uri: []const u8,
    line: usize, // 0-based
    col: usize, // 0-based
    severity: u8, // 1=error, 2=warning
    message: []const u8,
};

pub fn freeDiagnostics(allocator: std.mem.Allocator, diags: []Diagnostic) void {
    if (diags.len > 0) {
        for (diags) |d| {
            allocator.free(d.uri);
            allocator.free(d.message);
        }
        allocator.free(diags);
    }
}

// ============================================================
// SYMBOL INFO — cached analysis data for hover/definition/symbols
// ============================================================

/// LSP symbol kinds (subset we use)
pub const SymbolKind = enum(u8) {
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
pub const SymbolInfo = struct {
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
pub const AnalysisResult = struct {
    diagnostics: []Diagnostic,
    symbols: []SymbolInfo,
};

pub fn freeSymbols(allocator: std.mem.Allocator, symbols: []SymbolInfo) void {
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
// COMPLETION
// ============================================================

/// LSP CompletionItemKind values
pub const CompletionItemKind = enum(u8) {
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

// ============================================================
// SEMANTIC TOKENS — rich syntax highlighting via LSP
// ============================================================

/// Token type indices (must match legend in capabilities)
pub const SemanticTokenType = enum(u8) {
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
pub const SemanticModifier = struct {
    pub const declaration: u32 = 1 << 0;
    pub const definition: u32 = 1 << 1;
    pub const readonly: u32 = 1 << 2;
};

pub const SemanticToken = struct {
    line: usize,
    col: usize,
    length: usize,
    token_type: u8,
    modifiers: u32,
};

pub const TokenClassification = struct {
    token_type: ?SemanticTokenType,
    modifiers: u32,
};

// ============================================================
// SIGNATURE HELP
// ============================================================

pub const MAX_PARAMS = 16;

pub const ParamLabels = struct {
    starts: [MAX_PARAMS]usize,
    ends: [MAX_PARAMS]usize,
    count: usize,
};

pub const CallContext = struct {
    func_name: []const u8,
    obj_name: ?[]const u8, // e.g. "console" in "console.println("
    active_param: usize,
};

pub const TrimResult = struct { start: usize, end: usize };

// ============================================================
// PUBLISH RESULT — returned by runAndPublishWithDiags
// ============================================================

/// Run analysis, publish diagnostics, return new cached symbols.
pub const PublishResult = struct {
    symbols: []SymbolInfo,
    diags: []Diagnostic,
};
