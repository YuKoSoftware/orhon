// sema.zig — Shared semantic analysis context
// Holds the common state needed by all validation passes (6–9).

const std = @import("std");
const parser = @import("parser.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const module = @import("module.zig");

/// Shared context built after declaration collection (pass 4).
/// Used by type resolution (pass 5) and validation passes 6–8; extended by MIR (pass 9) and codegen (pass 11).
pub const SemanticContext = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.Reporter,
    decls: *declarations.DeclTable,
    locs: ?*const parser.LocMap,
    file_offsets: []const module.FileOffset,
    /// All module DeclTables — for cross-module qualified generic type validation.
    all_decls: ?*const std.StringHashMap(*declarations.DeclTable) = null,

    /// Resolve an AST node to its original source location.
    pub fn nodeLoc(self: *const SemanticContext, node: *parser.Node) ?errors.SourceLoc {
        return module.resolveNodeLoc(self.locs, self.file_offsets, node);
    }

    /// Create a minimal context for unit tests.
    pub fn initForTest(allocator: std.mem.Allocator, reporter: *errors.Reporter, decls: *declarations.DeclTable) SemanticContext {
        return .{
            .allocator = allocator,
            .reporter = reporter,
            .decls = decls,
            .locs = null,
            .file_offsets = &.{},
        };
    }
};
