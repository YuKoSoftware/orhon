// constants.zig — Shared string constants and string utilities used across multiple compiler passes.
// If a string is only used in one file, keep it local to that file.

/// Type names used in AST nodes and type checking
pub const Type = struct {
    pub const ERROR = "Error";
    pub const VECTOR = "Vector";
    pub const NULL = "null";
    pub const STRING = "str";
    pub const VOID = "void";
    pub const ANY = "any";
    pub const TYPE = "type";
    pub const THIS = "@this";
    pub const SELF_DEPRECATED = "Self";
};

/// Error messages used across multiple passes
pub const Err = struct {
    pub const MAIN_RESERVED = "'main' is reserved for the executable entry point";
};

// --- String utilities ---

/// Strip surrounding double quotes from a string literal.
/// Returns the inner content, or the original string if not quoted.
pub fn stripQuotes(raw: []const u8) []const u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return raw[1 .. raw.len - 1];
    }
    return raw;
}
