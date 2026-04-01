// builder_bridge.zig — Bridge and context flag builders for the PEG AST builder
// Contains: buildPubDecl, buildComptDecl, buildBridgeDecl, buildBridgeFunc,
//           buildBridgeConst, buildBridgeStruct, buildThreadDecl, setPub

const std = @import("std");
const builder = @import("builder.zig");
const parser = @import("../parser.zig");
const capture_mod = @import("capture.zig");
const CaptureNode = capture_mod.CaptureNode;
const Node = parser.Node;

const BuildContext = builder.BuildContext;

// ============================================================
// CONTEXT FLAG BUILDERS
// ============================================================

pub fn buildPubDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // pub_decl <- 'pub' (func_decl / struct_decl / ...)
    // Build the child, then set is_pub = true
    for (cap.children) |*child| {
        if (child.rule) |_| {
            const node = try builder.buildNode(ctx, child);
            builder.setPub(node, true);
            return node;
        }
    }
    return error.NoPubChild;
}

pub fn buildComptDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // compt_decl <- 'compt' func_decl
    if (cap.findChild("func_decl")) |child| {
        const node = try builder.buildNode(ctx, child);
        if (node.* == .func_decl) node.func_decl.context = .compt;
        return node;
    }
    return error.NoComptChild;
}

pub fn buildBridgeDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // bridge_decl <- 'bridge' (bridge_func / bridge_const / bridge_struct)
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "bridge_func") or
                std.mem.eql(u8, r, "bridge_const") or
                std.mem.eql(u8, r, "bridge_struct"))
            {
                return builder.buildNode(ctx, child);
            }
        }
    }
    return error.NoBridgeChild;
}

pub fn buildBridgeFunc(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // bridge_func <- 'func' func_name '(' _ param_list _ ')' type TERM
    var name: []const u8 = "";
    if (cap.findChild("func_name")) |fn_cap| {
        name = builder.tokenText(ctx, fn_cap.start_pos);
    }
    var params_list = std.ArrayListUnmanaged(*Node){};
    try builder.collectParamsRecursive(ctx, cap, &params_list);
    const ret_type = if (cap.findChild("type")) |t| try builder.buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "void" });

    return ctx.newNode(.{ .func_decl = .{
        .name = name,
        .params = try params_list.toOwnedSlice(ctx.alloc()),
        .return_type = ret_type,
        .body = try ctx.newNode(.{ .block = .{ .statements = &.{} } }),
        .context = .bridge,
        .is_pub = false,
    } });
}

pub fn buildBridgeConst(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // bridge_const <- 'const' IDENTIFIER ':' type TERM
    const name = builder.tokenText(ctx, cap.start_pos + 1);
    const type_ann = if (cap.findChild("type")) |t| try builder.buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "any" });
    return ctx.newNode(.{ .var_decl = .{
        .name = name,
        .type_annotation = type_ann,
        .value = try ctx.newNode(.{ .int_literal = "0" }),
        .is_pub = false,
        .mutability = .constant,
        .is_bridge = true,
    } });
}

pub fn buildBridgeStruct(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // bridge_struct <- 'struct' IDENTIFIER generic_params? ('{' _ bridge_struct_body _ '}' / TERM)
    const name = builder.tokenText(ctx, cap.start_pos + 1);
    var type_params_list = std.ArrayListUnmanaged(*Node){};
    var members = std.ArrayListUnmanaged(*Node){};
    try builder.collectStructParts(ctx, cap, &type_params_list, &members);
    return ctx.newNode(.{ .struct_decl = .{
        .name = name,
        .type_params = try type_params_list.toOwnedSlice(ctx.alloc()),
        .members = try members.toOwnedSlice(ctx.alloc()),
        .is_pub = false,
        .is_bridge = true,
    } });
}

pub fn buildThreadDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // thread_decl <- 'thread' func_name '(' _ param_list _ ')' type block
    var name: []const u8 = "";
    if (cap.findChild("func_name")) |fn_cap| {
        name = builder.tokenText(ctx, fn_cap.start_pos);
    }
    var params_list = std.ArrayListUnmanaged(*Node){};
    try builder.collectParamsRecursive(ctx, cap, &params_list);
    const ret_type = if (cap.findChild("type")) |t| try builder.buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "void" });
    const body = if (cap.findChild("block")) |b| try builder.buildNode(ctx, b) else try ctx.newNode(.{ .block = .{ .statements = &.{} } });

    return ctx.newNode(.{ .func_decl = .{
        .name = name,
        .params = try params_list.toOwnedSlice(ctx.alloc()),
        .return_type = ret_type,
        .body = body,
        .context = .thread,
        .is_pub = false,
    } });
}
