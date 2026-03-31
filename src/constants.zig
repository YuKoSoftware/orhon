// constants.zig — Shared string constants used across multiple compiler passes.
// If a string is only used in one file, keep it local to that file.

/// Type names used in AST nodes and type checking
pub const Type = struct {
    pub const ERROR = "Error";
    pub const NULL = "null";
    pub const STRING = "String";
    pub const VOID = "void";
    pub const ANY = "any";
    pub const TYPE = "type";
};
