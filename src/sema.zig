// sema.zig — Shared semantic analysis context
// Holds the common state needed by all validation passes (6–9).

const std = @import("std");
const parser = @import("parser.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const module = @import("module.zig");
const types = @import("types.zig");
const ast_store_mod = @import("ast_store.zig");

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
    /// Node-to-ResolvedType map produced by pass 5. Set after the type resolver runs
    /// so later passes (borrow, propagation) can look up receiver types by AST node.
    type_map: ?*const std.AutoHashMapUnmanaged(*parser.Node, types.ResolvedType) = null,
    /// AstStore produced by ast_conv — available after Phase A migration.
    ast: ?*const ast_store_mod.AstStore = null,
    /// Reverse map from AstNodeIndex back to *parser.Node for bridge code.
    reverse_map: ?*const std.AutoHashMap(ast_store_mod.AstNodeIndex, *parser.Node) = null,

    /// Resolve an AST node to its original source location.
    pub fn nodeLoc(self: *const SemanticContext, node: *parser.Node) ?errors.SourceLoc {
        return module.resolveNodeLoc(self.locs, self.file_offsets, node);
    }

    /// Resolve a source location for an AstNodeIndex via the bridge reverse_map.
    /// Returns null if the reverse_map is absent or the index is not mapped.
    pub fn nodeLocFromIdx(self: *const SemanticContext, idx: ast_store_mod.AstNodeIndex) ?errors.SourceLoc {
        const rm = self.reverse_map orelse return null;
        const node = rm.get(idx) orelse return null;
        return self.nodeLoc(node);
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
