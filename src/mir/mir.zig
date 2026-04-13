// mir.zig — MIR (Mid-level Intermediate Representation) pass (pass 9)
// Re-export hub — all implementations live in mir_*.zig files.

pub const TypeClass = @import("mir_types.zig").TypeClass;
pub const Coercion = @import("mir_types.zig").Coercion;
pub const NodeInfo = @import("mir_types.zig").NodeInfo;
pub const NodeMap = @import("mir_types.zig").NodeMap;
pub const classifyType = @import("mir_types.zig").classifyType;
pub const MirKind = @import("mir_node.zig").MirKind;
pub const LiteralKind = @import("mir_node.zig").LiteralKind;
pub const IfNarrowing = @import("mir_node.zig").IfNarrowing;
pub const MirNode = @import("mir_node.zig").MirNode;
pub const UnionRegistry = @import("mir_registry.zig").UnionRegistry;
pub const union_sort = @import("union_sort.zig");
pub const MirAnnotator = @import("mir_annotator.zig").MirAnnotator;
pub const MirLowerer = @import("mir_lowerer.zig").MirLowerer;
