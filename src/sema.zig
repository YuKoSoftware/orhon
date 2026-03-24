// sema.zig — Shared semantic analysis context
// Holds the common state needed by all validation passes (6–9).
// Eliminates repeated field wiring and duplicated nodeLoc() functions.

const std = @import("std");
const parser = @import("parser.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const module = @import("module.zig");

/// Shared context built after declaration collection (pass 4) and type resolution (pass 5).
/// Read-only for validation passes 6–9; extended by MIR (pass 10) and codegen (pass 11).
pub const SemanticContext = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.Reporter,
    decls: *declarations.DeclTable,
    locs: ?*const parser.LocMap,
    file_offsets: []const module.FileOffset,

    /// Resolve an AST node to its original source location.
    /// Shared by all passes — replaces the per-checker nodeLoc() copies.
    pub fn nodeLoc(self: *const SemanticContext, node: *parser.Node) ?errors.SourceLoc {
        if (self.locs) |l| {
            if (l.get(node)) |loc| {
                const resolved = module.resolveFileLoc(self.file_offsets, loc.line);
                return .{ .file = resolved.file, .line = resolved.line, .col = loc.col };
            }
        }
        return null;
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
