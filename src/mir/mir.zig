// mir.zig — MIR (Mid-level Intermediate Representation) pass (pass 9)
// Re-export hub — all implementations live in mir_*.zig files.

pub const TypeClass = @import("mir_types.zig").TypeClass;
pub const Coercion = @import("mir_types.zig").Coercion;
pub const classifyType = @import("mir_types.zig").classifyType;
pub const MirKind = @import("mir_types.zig").MirKind;
pub const LiteralKind = @import("mir_types.zig").LiteralKind;
pub const IfNarrowing = @import("mir_types.zig").IfNarrowing;
pub const NarrowBranch = @import("mir_types.zig").NarrowBranch;
pub const NarrowKind = @import("mir_types.zig").NarrowKind;
pub const UnionRegistry = @import("mir_registry.zig").UnionRegistry;
pub const union_sort = @import("union_sort.zig");
pub const TypeId = @import("../type_store.zig").TypeId;
pub const TypeStore = @import("../type_store.zig").TypeStore;
pub const MirNodeIndex = @import("../mir_store.zig").MirNodeIndex;
pub const MirExtraIndex = @import("../mir_store.zig").MirExtraIndex;
pub const MirEntry = @import("../mir_store.zig").MirEntry;
pub const MirData = @import("../mir_store.zig").MirData;
pub const MirStore = @import("../mir_store.zig").MirStore;
pub const mir_typed = @import("../mir_typed.zig");
