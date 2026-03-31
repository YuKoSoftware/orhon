// builder_types.zig — Type builders for the PEG AST builder
// Contains: buildNamedType, buildKeywordType, buildScopedType,
//           buildScopedGenericType, buildGenericType, buildBorrowType,
//           buildRefType, buildParenType, buildSliceType, buildArrayType,
//           buildFuncType

const std = @import("std");
const builder = @import("builder.zig");
const parser = @import("../parser.zig");
const lexer = @import("../lexer.zig");
const capture_mod = @import("capture.zig");
const CaptureNode = capture_mod.CaptureNode;
const Node = parser.Node;
const TokenKind = lexer.TokenKind;

const BuildContext = builder.BuildContext;

// ============================================================
// TYPE BUILDERS
// ============================================================

pub fn buildNamedType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return ctx.newNode(.{ .type_named = builder.tokenText(ctx, cap.start_pos) });
}

pub fn buildKeywordType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return ctx.newNode(.{ .type_named = builder.tokenText(ctx, cap.start_pos) });
}

/// scoped_type <- IDENTIFIER '.' IDENTIFIER
/// Produces type_named("module.Type") so @import("module") lookup works in codegen.
pub fn buildScopedType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const mod_name = builder.tokenText(ctx, cap.start_pos);
    // Second identifier follows the '.' token at start_pos+1
    const type_name = builder.tokenText(ctx, cap.start_pos + 2);
    const qualified = try std.fmt.allocPrint(ctx.alloc(), "{s}.{s}", .{ mod_name, type_name });
    return ctx.newNode(.{ .type_named = qualified });
}

/// scoped_generic_type <- IDENTIFIER '.' IDENTIFIER '(' _ generic_arg_list _ ')'
/// Produces type_generic with name="module.Type" and collected type args.
pub fn buildScopedGenericType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const mod_name = builder.tokenText(ctx, cap.start_pos);
    const type_name = builder.tokenText(ctx, cap.start_pos + 2);
    const qualified = try std.fmt.allocPrint(ctx.alloc(), "{s}.{s}", .{ mod_name, type_name });
    var args_list = std.ArrayListUnmanaged(*Node){};
    try collectGenericArgs(ctx, cap, &args_list);
    return ctx.newNode(.{ .type_generic = .{ .name = qualified, .args = try args_list.toOwnedSlice(ctx.alloc()) } });
}

pub fn buildGenericType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const name = builder.tokenText(ctx, cap.start_pos);
    // Collect type/expr args from generic_arg_list -> type_or_expr -> type/expr
    var args_list = std.ArrayListUnmanaged(*Node){};
    try collectGenericArgs(ctx, cap, &args_list);
    return ctx.newNode(.{ .type_generic = .{ .name = name, .args = try args_list.toOwnedSlice(ctx.alloc()) } });
}

fn collectGenericArgs(ctx: *BuildContext, cap: *const CaptureNode, out: *std.ArrayListUnmanaged(*Node)) anyerror!void {
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "type") or std.mem.eql(u8, r, "expr")) {
                try out.append(ctx.alloc(), try builder.buildNode(ctx, child));
            } else if (std.mem.eql(u8, r, "_") or std.mem.eql(u8, r, "TERM")) {
                // skip
            } else {
                // Recurse into generic_arg_list, type_or_expr wrappers
                try collectGenericArgs(ctx, child, out);
            }
        }
    }
}

pub fn buildBorrowType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // borrow_type <- 'const&' type
    if (cap.findChild("type")) |t| {
        const inner = try builder.buildNode(ctx, t);
        return ctx.newNode(.{ .type_ptr = .{ .kind = .const_ref, .elem = inner } });
    }
    return error.NoBorrowInner;
}

pub fn buildRefType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // ref_type <- 'mut&' type
    if (cap.findChild("type")) |t| {
        const inner = try builder.buildNode(ctx, t);
        return ctx.newNode(.{ .type_ptr = .{ .kind = .mut_ref, .elem = inner } });
    }
    return error.NoRefInner;
}

pub fn buildParenType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // paren_type <- '(' ')' / '(' IDENTIFIER ':' type ... ')' / '(' type ('|' type)+ ')' / '(' type ')'
    // Check for void: ()
    if (cap.end_pos - cap.start_pos <= 2) return ctx.newNode(.{ .type_named = "void" });

    // Collect type children
    var type_children = std.ArrayListUnmanaged(*Node){};
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "type")) {
                try type_children.append(ctx.alloc(), try builder.buildNode(ctx, child));
            }
        }
    }

    // Check for named tuple: IDENTIFIER ':' type pattern (not union with '|')
    var named_fields = std.ArrayListUnmanaged(parser.NamedTypeField){};
    var type_idx: usize = 0;
    var i = cap.start_pos;
    while (i + 1 < cap.end_pos and i + 1 < ctx.tokens.len) : (i += 1) {
        if (ctx.tokens[i].kind == .identifier and ctx.tokens[i + 1].kind == .colon) {
            if (type_idx < type_children.items.len) {
                try named_fields.append(ctx.alloc(), .{
                    .name = ctx.tokens[i].text,
                    .type_node = type_children.items[type_idx],
                    .default = null,
                });
                type_idx += 1;
            }
        }
    }
    if (named_fields.items.len > 0 and named_fields.items.len == type_children.items.len) {
        return ctx.newNode(.{ .type_tuple_named = try named_fields.toOwnedSlice(ctx.alloc()) });
    }

    // Union: multiple type children with | separators
    if (type_children.items.len > 1) {
        return ctx.newNode(.{ .type_union = try type_children.toOwnedSlice(ctx.alloc()) });
    }
    if (type_children.items.len == 1) return type_children.items[0];

    return ctx.newNode(.{ .type_named = "void" });
}

pub fn buildSliceType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    if (cap.findChild("type")) |t| {
        const elem = try builder.buildNode(ctx, t);
        return ctx.newNode(.{ .type_slice = elem });
    }
    return error.NoSliceElem;
}

pub fn buildArrayType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    if (cap.findChild("expr")) |size_cap| {
        if (cap.findChild("type")) |type_cap| {
            const size = try builder.buildNode(ctx, size_cap);
            const elem = try builder.buildNode(ctx, type_cap);
            return ctx.newNode(.{ .type_array = .{ .size = size, .elem = elem } });
        }
    }
    return error.NoArrayComponents;
}

pub fn buildFuncType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // func_type <- 'func' '(' _ type_list _ ')' type
    var params = std.ArrayListUnmanaged(*Node){};
    // Collect param types from type_list child, plus return type (direct type child)
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "type_list")) {
                // Param types are nested inside type_list
                for (child.children) |*tc| {
                    if (tc.rule) |tr| {
                        if (std.mem.eql(u8, tr, "type")) {
                            try params.append(ctx.alloc(), try builder.buildNode(ctx, tc));
                        }
                    }
                }
            } else if (std.mem.eql(u8, r, "type")) {
                try params.append(ctx.alloc(), try builder.buildNode(ctx, child));
            }
        }
    }
    // Last type is the return type
    if (params.items.len > 0) {
        const ret = params.items[params.items.len - 1];
        params.items.len -= 1;
        return ctx.newNode(.{ .type_func = .{
            .params = try params.toOwnedSlice(ctx.alloc()),
            .ret = ret,
        } });
    }
    return error.NoFuncTypeReturn;
}
