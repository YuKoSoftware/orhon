// builder_decls.zig — Declaration builders for the PEG AST builder
// Contains: buildProgram, buildModuleDecl, buildImport, buildMetadata,
//           buildFuncDecl, buildParam, buildConstDecl, buildVarDecl,
//           buildStructDecl, buildBlueprintDecl, buildEnumDecl, buildFieldDecl,
//           buildEnumVariant, buildDestructDecl, buildTestDecl, buildPubDecl, buildComptDecl
// All functions receive *BuildContext as first parameter.

const std = @import("std");
const builder = @import("builder.zig");
const parser = @import("../parser.zig");
const capture_mod = @import("capture.zig");
const CaptureNode = capture_mod.CaptureNode;
const Node = parser.Node;

const constants = @import("../constants.zig");

const BuildContext = builder.BuildContext;

// ============================================================
// PROGRAM STRUCTURE BUILDERS
// ============================================================

pub fn buildProgram(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // program <- _ module_decl (_ (doc_block / metadata / import_decl / top_level))* _ EOF
    const mod = if (cap.findChild("module_decl")) |m| try builder.buildNode(ctx, m) else return error.NoModule;

    var metadata_list = std.ArrayListUnmanaged(*Node){};
    var imports_list = std.ArrayListUnmanaged(*Node){};
    var top_level_list = std.ArrayListUnmanaged(*Node){};
    var pending_doc: ?[]const u8 = null;

    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "doc_block")) {
                // doc_block at program level — attach to the next top_level declaration
                pending_doc = builder.extractDoc(ctx, child);
            } else if (std.mem.eql(u8, r, "metadata")) {
                const node = builder.buildNode(ctx, child) catch |err| switch (err) {
                    error.ParseError => continue, // unknown directive — error already reported
                    else => return err,
                };
                try metadata_list.append(ctx.alloc(), node);
            } else if (std.mem.eql(u8, r, "import_decl")) {
                try imports_list.append(ctx.alloc(), try builder.buildNode(ctx, child));
            } else if (std.mem.eql(u8, r, "top_level")) {
                // top_level <- doc_block? top_level_decl
                // doc_block may be inside top_level OR at program level (pending_doc)
                var inner_doc: ?[]const u8 = null;
                for (child.children) |*tl_child| {
                    if (tl_child.rule) |tl_rule| {
                        if (std.mem.eql(u8, tl_rule, "doc_block")) {
                            inner_doc = builder.extractDoc(ctx, tl_child);
                        } else {
                            const node = try builder.buildNode(ctx, tl_child);
                            // Inner doc_block takes precedence over program-level pending_doc
                            const doc = inner_doc orelse pending_doc;
                            if (doc) |d| builder.setDoc(node, d);
                            inner_doc = null;
                            pending_doc = null;
                            try top_level_list.append(ctx.alloc(), node);
                        }
                    }
                }
            } else if (std.mem.eql(u8, r, "top_level_decl")) {
                try top_level_list.append(ctx.alloc(), try builder.buildNode(ctx, child));
            } else if (std.mem.eql(u8, r, "error_skip")) {
                // Error recovery: report the skipped tokens as a syntax error
                const start = child.start_pos;
                const tok = if (start < ctx.tokens.len) ctx.tokens[start] else null;
                if (tok) |t| {
                    const msg = try std.fmt.allocPrint(ctx.alloc(), "unexpected '{s}'", .{t.text});
                    ctx.reportError(msg, start);
                }
                // Don't add to AST — skipped tokens are discarded
            }
        }
    }

    // Wire #description metadata to module_decl.doc (takes precedence over /// on module)
    for (metadata_list.items) |meta| {
        if (meta.* == .metadata) {
            if (meta.metadata.field == .description) {
                if (meta.metadata.value.* == .string_literal) {
                    const text = constants.stripQuotes(meta.metadata.value.string_literal);
                    builder.setDoc(mod, text);
                }
                break;
            }
        }
    }

    return ctx.newNode(.{ .program = .{
        .module = mod,
        .metadata = try metadata_list.toOwnedSlice(ctx.alloc()),
        .imports = try imports_list.toOwnedSlice(ctx.alloc()),
        .top_level = try top_level_list.toOwnedSlice(ctx.alloc()),
    } });
}

pub fn buildModuleDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // module_decl <- doc_block? 'module' IDENTIFIER NL
    // Find the name token — it's the identifier after 'module'
    const name_pos = builder.findTokenInRange(ctx, cap.start_pos + 1, cap.end_pos, .identifier) orelse
        return error.NoModuleName;
    const doc = if (cap.findChild("doc_block")) |db| builder.extractDoc(ctx, db) else null;
    return ctx.newNode(.{ .module_decl = .{ .name = builder.tokenText(ctx, name_pos), .doc = doc } });
}

pub fn buildImport(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // import_decl <- 'import' import_path ('as' IDENTIFIER)? NL
    //             / 'use' import_path NL
    const is_include = ctx.tokens[cap.start_pos].kind == .kw_use;
    var path: []const u8 = "";
    var scope: ?[]const u8 = null;
    var alias: ?[]const u8 = null;
    var is_c_header = false;

    // Walk tokens to extract path components
    var i = cap.start_pos + 1;
    while (i < cap.end_pos) : (i += 1) {
        const tok = ctx.tokens[i];
        if (tok.kind == .string_literal) {
            path = tok.text;
            is_c_header = true;
        } else if (tok.kind == .identifier) {
            if (i + 1 < cap.end_pos and ctx.tokens[i + 1].kind == .scope) {
                scope = tok.text;
                i += 2; // skip ::
                if (i < cap.end_pos) path = ctx.tokens[i].text;
            } else {
                path = tok.text;
            }
        } else if (tok.kind == .kw_as) {
            i += 1;
            if (i < cap.end_pos) alias = ctx.tokens[i].text;
        }
    }

    return ctx.newNode(.{ .import_decl = .{
        .path = path,
        .scope = scope,
        .alias = alias,
        .is_c_header = is_c_header,
        .is_include = is_include,
    } });
}

pub fn buildMetadata(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // metadata <- '#' metadata_body NL
    // metadata_body <- 'dep' expr expr? / IDENTIFIER '=' expr
    const field_pos = cap.start_pos + 1; // after #
    const field = builder.tokenText(ctx, field_pos);

    const parsed_field = parser.MetadataField.parse(field) orelse {
        const msg = std.fmt.allocPrint(ctx.alloc(), "unknown metadata directive '#{s}' — expected #build, #version, #dep, or #description", .{field}) catch "unknown metadata directive";
        ctx.reportError(msg, field_pos);
        return error.ParseError;
    };

    // Build value from first expr child
    if (cap.children.len > 0) {
        const value = try builder.buildNode(ctx, &cap.children[0]);
        var extra: ?*Node = null;
        if (cap.children.len > 1) {
            extra = try builder.buildNode(ctx, &cap.children[1]);
        }
        return ctx.newNode(.{ .metadata = .{ .field = parsed_field, .value = value, .extra = extra } });
    }

    // Fallback — create a dummy value
    const dummy = try ctx.newNode(.{ .identifier = field });
    return ctx.newNode(.{ .metadata = .{ .field = parsed_field, .value = dummy } });
}

// ============================================================
// DECLARATION BUILDERS
// ============================================================

pub fn buildFuncDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // func_decl <- 'func' func_name '(' _ param_list _ ')' type (block / TERM)
    var name: []const u8 = "";
    if (cap.findChild("func_name")) |fn_cap| {
        const name_pos = fn_cap.start_pos;
        name = builder.tokenText(ctx, name_pos);
    }

    // Params may be nested inside param_list
    var params_list = std.ArrayListUnmanaged(*Node){};
    try builder.collectParamsRecursive(ctx, cap, &params_list);
    const params = try params_list.toOwnedSlice(ctx.alloc());

    const ret_type = if (cap.findChild("type")) |t| try builder.buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "void" });
    const body = if (cap.findChild("block")) |b| try builder.buildNode(ctx, b) else try ctx.newNode(.{ .block = .{ .statements = &.{} } });

    return ctx.newNode(.{ .func_decl = .{
        .name = name,
        .params = params,
        .return_type = ret_type,
        .body = body,
        .context = .normal,
        .is_pub = false,
    } });
}

pub fn buildParam(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // param <- param_name ':' type ('=' expr)?
    var name: []const u8 = "";
    if (cap.findChild("param_name")) |pn| {
        name = builder.tokenText(ctx, pn.start_pos);
    }

    const type_ann = if (cap.findChild("type")) |t| try builder.buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "any" });
    var default: ?*Node = null;
    if (cap.findChild("expr")) |e| {
        default = try builder.buildNode(ctx, e);
    }

    return ctx.newNode(.{ .param = .{
        .name = name,
        .type_annotation = type_ann,
        .default_value = default,
    } });
}

pub fn buildConstDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return buildVarOrConst(ctx, cap, .constant);
}

pub fn buildVarDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return buildVarOrConst(ctx, cap, .mutable);
}

fn buildVarOrConst(ctx: *BuildContext, cap: *const CaptureNode, mutability: parser.Mutability) !*Node {
    const is_const = mutability == .constant;

    if (cap.findChild("destruct_tail")) |dt| {
        return buildDestructFromTail(ctx, cap, dt, is_const);
    }

    const name_pos = cap.start_pos + 1; // after 'const'/'var'
    const name = builder.tokenText(ctx, name_pos);

    var type_ann: ?*Node = null;
    if (cap.findChild("type")) |t| {
        type_ann = try builder.buildNode(ctx, t);
    }

    const value = if (cap.findChild("expr")) |e| try builder.buildNode(ctx, e) else try ctx.newNode(.{ .int_literal = "0" });

    return ctx.newNode(.{ .var_decl = .{
        .name = name,
        .type_annotation = type_ann,
        .value = value,
        .is_pub = false,
        .mutability = mutability,
    } });
}

pub fn buildStructDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // struct_decl <- 'struct' IDENTIFIER generic_params? (':' blueprint_list)? '{' _ struct_body _ '}'
    const name_pos = cap.start_pos + 1;
    const name = builder.tokenText(ctx, name_pos);

    var type_params_list = std.ArrayListUnmanaged(*Node){};
    var members = std.ArrayListUnmanaged(*Node){};

    // Walk children recursively to find params (from generic_params) and members
    try builder.collectStructParts(ctx, cap, &type_params_list, &members);

    // Collect blueprint names from ': Eq, Hash' syntax
    var blueprints = std.ArrayListUnmanaged([]const u8){};
    if (cap.findChild("blueprint_list")) |bl| {
        // blueprint_list <- IDENTIFIER (',' _ IDENTIFIER)*
        // Walk the token range and collect all identifiers
        for (bl.start_pos..bl.end_pos) |i| {
            if (i < ctx.tokens.len and ctx.tokens[i].kind == .identifier) {
                try blueprints.append(ctx.alloc(), ctx.tokens[i].text);
            }
        }
    }

    return ctx.newNode(.{ .struct_decl = .{
        .name = name,
        .type_params = try type_params_list.toOwnedSlice(ctx.alloc()),
        .members = try members.toOwnedSlice(ctx.alloc()),
        .blueprints = try blueprints.toOwnedSlice(ctx.alloc()),
        .is_pub = false,
    } });
}

pub fn buildBlueprintDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // blueprint_decl <- 'blueprint' IDENTIFIER '{' _ blueprint_body _ '}'
    const name_pos = cap.start_pos + 1;
    const name = builder.tokenText(ctx, name_pos);

    var methods = std.ArrayListUnmanaged(*Node){};
    try collectBlueprintMethods(ctx, cap, &methods);

    return ctx.newNode(.{ .blueprint_decl = .{
        .name = name,
        .methods = try methods.toOwnedSlice(ctx.alloc()),
        .is_pub = false,
    } });
}

fn collectBlueprintMethods(ctx: *BuildContext, cap: *const CaptureNode, methods: *std.ArrayListUnmanaged(*Node)) anyerror!void {
    var pending_doc: ?[]const u8 = null;
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "doc_block")) {
                pending_doc = builder.extractDoc(ctx, child);
            } else if (std.mem.eql(u8, r, "blueprint_method")) {
                const node = try buildBlueprintMethod(ctx, child);
                if (pending_doc) |doc| {
                    builder.setDoc(node, doc);
                    pending_doc = null;
                }
                try methods.append(ctx.alloc(), node);
            } else if (std.mem.eql(u8, r, "_") or std.mem.eql(u8, r, "TERM")) {
                // skip
            } else {
                try collectBlueprintMethods(ctx, child, methods);
            }
        }
    }
}

fn buildBlueprintMethod(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // blueprint_method <- doc_block? 'func' IDENTIFIER '(' _ param_list? _ ')' type? TERM
    // Find the function name — identifier after 'func' keyword
    var name: []const u8 = "";
    for (cap.start_pos..cap.end_pos) |i| {
        if (i < ctx.tokens.len and ctx.tokens[i].kind == .kw_func) {
            if (i + 1 < ctx.tokens.len and ctx.tokens[i + 1].kind == .identifier) {
                name = ctx.tokens[i + 1].text;
                break;
            }
        }
    }

    // Collect parameters
    var params_list = std.ArrayListUnmanaged(*Node){};
    try builder.collectParamsRecursive(ctx, cap, &params_list);

    // Collect return type
    const return_type = if (cap.findChild("type")) |t|
        try builder.buildNode(ctx, t)
    else
        try ctx.newNode(.{ .type_named = "void" });

    // Create a func_decl with an empty body (signature only for blueprint contracts)
    const empty_body = try ctx.newNode(.{ .block = .{ .statements = &.{} } });

    return ctx.newNode(.{ .func_decl = .{
        .name = name,
        .params = try params_list.toOwnedSlice(ctx.alloc()),
        .return_type = return_type,
        .body = empty_body,
        .context = .normal,
        .is_pub = true,
    } });
}

pub fn buildEnumDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // enum_decl <- 'enum' '(' type ')' IDENTIFIER '{' _ enum_body _ '}'
    const backing = if (cap.findChild("type")) |t| try builder.buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "u8" });

    // Name is the identifier after ')'
    var name: []const u8 = "";
    for (cap.start_pos..cap.end_pos) |i| {
        if (i > 0 and i < ctx.tokens.len and ctx.tokens[i].kind == .identifier and ctx.tokens[i - 1].kind == .rparen) {
            name = ctx.tokens[i].text;
            break;
        }
    }

    var members = std.ArrayListUnmanaged(*Node){};
    try collectEnumMembers(ctx, cap, &members);

    return ctx.newNode(.{ .enum_decl = .{
        .name = name,
        .backing_type = backing,
        .members = try members.toOwnedSlice(ctx.alloc()),
        .is_pub = false,
    } });
}

fn collectEnumMembers(ctx: *BuildContext, cap: *const CaptureNode, members: *std.ArrayListUnmanaged(*Node)) anyerror!void {
    var pending_doc: ?[]const u8 = null;
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "doc_block")) {
                pending_doc = builder.extractDoc(ctx, child);
            } else if (std.mem.eql(u8, r, "enum_variant") or std.mem.eql(u8, r, "func_decl") or std.mem.eql(u8, r, "pub_decl")) {
                const node = try builder.buildNode(ctx, child);
                if (builder.hasPubBefore(ctx, cap, child.start_pos)) builder.setPub(node, true);
                if (pending_doc) |doc| {
                    builder.setDoc(node, doc);
                    pending_doc = null;
                }
                try members.append(ctx.alloc(), node);
            } else if (std.mem.eql(u8, r, "_") or std.mem.eql(u8, r, "TERM") or std.mem.eql(u8, r, "type")) {
                // skip
            } else {
                try collectEnumMembers(ctx, child, members);
            }
        }
    }
}

pub fn buildFieldDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // field_decl <- IDENTIFIER ':' type ('=' expr)? TERM
    const name = builder.tokenText(ctx, cap.start_pos);
    const type_ann = if (cap.findChild("type")) |t| try builder.buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "any" });
    var default: ?*Node = null;
    if (cap.findChild("expr")) |e| {
        default = try builder.buildNode(ctx, e);
    }
    return ctx.newNode(.{ .field_decl = .{
        .name = name,
        .type_annotation = type_ann,
        .default_value = default,
        .is_pub = false,
    } });
}

pub fn buildEnumVariant(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const name = builder.tokenText(ctx, cap.start_pos);
    var value: ?*Node = null;
    // Scan for '=' followed by int_literal within this variant's token range
    for (cap.start_pos..cap.end_pos) |i| {
        if (i < ctx.tokens.len and ctx.tokens[i].kind == .assign) {
            if (i + 1 < ctx.tokens.len and ctx.tokens[i + 1].kind == .int_literal) {
                value = try ctx.newNode(.{ .int_literal = ctx.tokens[i + 1].text });
            }
            break;
        }
    }
    const fields = try builder.buildChildrenByRule(ctx, cap, "param");
    return ctx.newNode(.{ .enum_variant = .{
        .name = name,
        .fields = fields,
        .value = value,
    } });
}

pub fn buildDestructDecl(_: *BuildContext, _: *const CaptureNode) !*Node {
    return error.DestructNotReached; // handled by buildDestructFromTail
}

fn buildDestructFromTail(ctx: *BuildContext, cap: *const CaptureNode, dt: *const CaptureNode, is_const: bool) !*Node {
    // destruct_tail <- (',' IDENTIFIER)+ '=' expr
    // First name is after 'const'/'var' keyword
    const first_name = builder.tokenText(ctx, cap.start_pos + 1);
    var names = std.ArrayListUnmanaged([]const u8){};
    try names.append(ctx.alloc(), first_name);
    // Collect additional names from comma-separated identifiers in destruct_tail (before '=')
    for (dt.start_pos..dt.end_pos) |i| {
        if (i < ctx.tokens.len and ctx.tokens[i].kind == .assign) break;
        if (i < ctx.tokens.len and ctx.tokens[i].kind == .identifier) {
            try names.append(ctx.alloc(), ctx.tokens[i].text);
        }
    }
    // Value is the expr child
    var value: *Node = try ctx.newNode(.{ .int_literal = "0" });
    if (dt.findChild("expr")) |e| {
        value = try builder.buildNode(ctx, e);
    } else {
        // expr might be a sibling of destruct_tail in the const_decl capture
        if (cap.findChild("expr")) |e| {
            value = try builder.buildNode(ctx, e);
        }
    }
    return ctx.newNode(.{ .destruct_decl = .{
        .names = try names.toOwnedSlice(ctx.alloc()),
        .is_const = is_const,
        .value = value,
    } });
}

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

pub fn buildTestDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // test_decl <- 'test' STRING_LITERAL block
    var desc: []const u8 = "";
    if (builder.findTokenInRange(ctx, cap.start_pos, cap.end_pos, .string_literal)) |pos| {
        desc = builder.tokenText(ctx, pos);
    }
    const body = if (cap.findChild("block")) |b| try builder.buildNode(ctx, b) else try ctx.newNode(.{ .block = .{ .statements = &.{} } });
    return ctx.newNode(.{ .test_decl = .{ .description = desc, .body = body } });
}
