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

/// Operator strings used in cross-file comparisons.
/// The AST stores operators as strings; these constants centralize the literals.
pub const Op = struct {
    pub const AND = "and";
    pub const OR = "or";
    pub const NOT = "not";
    pub const EQ = "==";
    pub const NE = "!=";
    pub const LT = "<";
    pub const GT = ">";
    pub const LE = "<=";
    pub const GE = ">=";
    pub const CONCAT = "++";
    pub const RANGE = "..";
    pub const DIV = "/";
    pub const MOD = "%";
    pub const DIV_ASSIGN = "/=";
};
