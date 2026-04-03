# Blueprints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `blueprint` keyword to Orhon — compile-time-only nominal contracts that structs must satisfy, with pure erasure at codegen.

**Architecture:** Blueprints are parsed into a new `BlueprintDecl` AST node, collected into `DeclTable.blueprints` during pass 4, and validated by conformance checking in the resolver (pass 5). Codegen ignores them entirely — structs emit as plain Zig structs. The colon syntax on `struct_decl` (`struct Point: Eq {}`) is parsed into a `blueprints` field on `StructDecl`.

**Tech Stack:** Zig 0.15.2+, PEG grammar, existing compiler pipeline passes 1–7.

**Spec:** `docs/superpowers/specs/2026-03-31-blueprints-design.md`

---

### Task 1: Add `blueprint` keyword to lexer

**Files:**
- Modify: `src/lexer.zig:31` (TokenKind enum)
- Modify: `src/lexer.zig:118-156` (KEYWORDS map)

- [ ] **Step 1: Add `kw_blueprint` to TokenKind enum**

In `src/lexer.zig`, add `kw_blueprint` after `kw_struct` (line 31):

```zig
kw_struct,
kw_blueprint,
kw_enum,
```

- [ ] **Step 2: Add `"blueprint"` to KEYWORDS map**

In the `KEYWORDS` static string map (around line 132), add:

```zig
.{ "blueprint", .kw_blueprint },
```

Place it near the other type-declaration keywords (`struct`, `enum`, `bitfield`).

- [ ] **Step 3: Run unit tests**

Run: `zig build test 2>&1 | tail -20`
Expected: All existing tests pass. The new keyword is recognized but not used yet.

- [ ] **Step 4: Commit**

```bash
git add src/lexer.zig
git commit -m "feat: add 'blueprint' keyword to lexer"
```

---

### Task 2: Add `BlueprintDecl` AST node

**Files:**
- Modify: `src/parser.zig:15-78` (NodeKind enum)
- Modify: `src/parser.zig:82-143` (Node union)
- Modify: `src/parser.zig:185-192` (StructDecl — add `blueprints` field)

- [ ] **Step 1: Add `blueprint_decl` to NodeKind enum**

In `src/parser.zig`, add `blueprint_decl` after `struct_decl` (line 21):

```zig
struct_decl,
blueprint_decl,
enum_decl,
```

- [ ] **Step 2: Add BlueprintDecl struct**

After the `StructDecl` struct (line 192), add:

```zig
pub const BlueprintDecl = struct {
    name: []const u8,
    methods: []*Node, // func_decl nodes (signature only, no body)
    is_pub: bool,
    doc: ?[]const u8 = null,
};
```

- [ ] **Step 3: Add `blueprint_decl` variant to Node union**

In the Node union (around line 88), add after `struct_decl`:

```zig
struct_decl: StructDecl,
blueprint_decl: BlueprintDecl,
enum_decl: EnumDecl,
```

- [ ] **Step 4: Add `blueprints` field to StructDecl**

Modify the existing `StructDecl` struct (lines 185-192) to add a `blueprints` field:

```zig
pub const StructDecl = struct {
    name: []const u8,
    type_params: []*Node,
    members: []*Node,
    blueprints: []const []const u8 = &.{}, // blueprint names from `: Eq, Hash`
    is_pub: bool,
    is_bridge: bool = false,
    doc: ?[]const u8 = null,
};
```

The default `&.{}` ensures all existing struct construction sites remain valid.

- [ ] **Step 5: Run unit tests**

Run: `zig build test 2>&1 | tail -20`
Expected: All existing tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/parser.zig
git commit -m "feat: add BlueprintDecl AST node and StructDecl.blueprints field"
```

---

### Task 3: Add blueprint grammar rules to PEG

**Files:**
- Modify: `src/peg/orhon.peg:75-99` (top_level_decl and pub_decl)
- Modify: `src/peg/orhon.peg:132-133` (struct_decl — add colon conformance)
- Modify: `src/peg/orhon.peg:~145` (add blueprint_decl rule)
- Modify: `src/peg/orhon.peg:596-605` (keyword list comment)

- [ ] **Step 1: Add `blueprint_decl` grammar rule**

After the `struct_decl` section (around line 145, before enum_decl), add:

```
# ============================================================
# BLUEPRINT DECLARATIONS
# ============================================================

blueprint_decl
    <- 'blueprint' IDENTIFIER '{' _ blueprint_body _ '}'  {label: "blueprint declaration"}

blueprint_body
    <- (blueprint_method _)*

blueprint_method
    <- doc_block? 'func' IDENTIFIER '(' _ param_list? _ ')' type? TERM
```

- [ ] **Step 2: Extend `struct_decl` with optional blueprint conformance**

Modify the `struct_decl` rule (line 132-133) to accept an optional `: Blueprint1, Blueprint2` list:

```
struct_decl
    <- 'struct' IDENTIFIER generic_params? (':' blueprint_list)? '{' _ struct_body _ '}'  {label: "struct declaration"}

blueprint_list
    <- IDENTIFIER (',' _ IDENTIFIER)*
```

- [ ] **Step 3: Add `blueprint_decl` to `top_level_decl`**

In the `top_level_decl` alternatives (lines 83-89), add `blueprint_decl`:

```
top_level_decl
    <- pub_decl
     / func_decl
     / thread_decl
     / compt_decl
     / struct_decl
     / blueprint_decl
     / enum_decl
     / bitfield_decl
     / const_decl
     / var_decl
     / bridge_decl
     / test_decl
```

- [ ] **Step 4: Add `blueprint_decl` to `pub_decl`**

In the `pub_decl` alternatives (lines 92-99), add `blueprint_decl`:

```
pub_decl
    <- 'pub' (func_decl
            / thread_decl
            / bridge_decl
            / struct_decl
            / blueprint_decl
            / enum_decl
            / bitfield_decl
            / const_decl
            / compt_decl)
```

- [ ] **Step 5: Update keyword comment**

Update the keyword comment (lines 596-605) to include `blueprint`:

```
# KEYWORDS (reserved — cannot be used as identifiers)
# func var const if else elif for while return throw import use
# pub match struct enum bitfield defer thread null void compt
# any module test and or not main as break continue true false
# bridge is type blueprint
```

- [ ] **Step 6: Run unit tests**

Run: `zig build test 2>&1 | tail -20`
Expected: All existing tests pass. Grammar changes are loaded at runtime by the PEG engine.

- [ ] **Step 7: Commit**

```bash
git add src/peg/orhon.peg
git commit -m "feat: add blueprint grammar rules and struct conformance syntax"
```

---

### Task 4: Add blueprint builder in PEG builder

**Files:**
- Modify: `src/peg/builder.zig:148-153` (dispatch table)
- Modify: `src/peg/builder.zig:403-406` (setPub switch)
- Modify: `src/peg/builder_decls.zig:1-6` (file header comment)
- Modify: `src/peg/builder_decls.zig:316-333` (add buildBlueprintDecl after buildStructDecl)
- Modify: `src/peg/builder_decls.zig:316-333` (modify buildStructDecl to parse blueprint list)

- [ ] **Step 1: Add dispatch entry in builder.zig**

In `src/peg/builder.zig`, after the `struct_decl` dispatch line (line 148), add:

```zig
if (std.mem.eql(u8, rule, "blueprint_decl")) return decls_impl.buildBlueprintDecl(ctx, cap);
```

- [ ] **Step 2: Add `blueprint_decl` to setPub switch**

In the `setPub` function (around line 403), add:

```zig
.blueprint_decl => |*d| d.is_pub = value,
```

Place it after `.struct_decl`.

- [ ] **Step 3: Modify buildStructDecl to parse blueprint list**

In `src/peg/builder_decls.zig`, modify `buildStructDecl` (line 316-333). After collecting type_params and members via `collectStructParts`, add blueprint list parsing:

```zig
pub fn buildStructDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // struct_decl <- 'struct' IDENTIFIER generic_params? (':' blueprint_list)? '{' _ struct_body _ '}'
    const name_pos = cap.start_pos + 1;
    const name = builder.tokenText(ctx, name_pos);

    var type_params_list = std.ArrayListUnmanaged(*Node){};
    var members = std.ArrayListUnmanaged(*Node){};

    // Walk children recursively to find params (from generic_params) and members
    try builder.collectStructParts(ctx, cap, &type_params_list, &members);

    // Collect blueprint names from `: Eq, Hash` syntax
    var blueprints = std.ArrayListUnmanaged([]const u8){};
    // Look for identifiers between ':' and '{' in token range
    var in_blueprint_list = false;
    for (cap.start_pos..cap.end_pos) |i| {
        if (i < ctx.tokens.len) {
            if (ctx.tokens[i].kind == .colon and !in_blueprint_list) {
                // Check this is the blueprint colon (before '{'), not a field colon
                // Blueprint colon appears before the opening brace, after name/generic_params
                in_blueprint_list = true;
            } else if (ctx.tokens[i].kind == .lbrace) {
                break;
            } else if (in_blueprint_list and ctx.tokens[i].kind == .identifier) {
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
```

- [ ] **Step 4: Add buildBlueprintDecl function**

In `src/peg/builder_decls.zig`, after `buildStructDecl`, add:

```zig
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
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "blueprint_method")) {
                // Blueprint method is a func signature without a body.
                // Reuse buildFuncDecl-like logic but produce a bodiless func_decl.
                const node = try buildBlueprintMethod(ctx, child);
                try methods.append(ctx.alloc(), node);
            } else if (std.mem.eql(u8, r, "_") or std.mem.eql(u8, r, "TERM") or std.mem.eql(u8, r, "doc_block")) {
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
    if (cap.findChild("param_list")) |pl| {
        try builder.collectParamsRecursive(ctx, pl, &params_list);
    }

    // Collect return type
    const return_type = if (cap.findChild("type")) |t|
        try builder.buildNode(ctx, t)
    else
        try ctx.newNode(.{ .type_named = "void" });

    // Create a func_decl with an empty block body (signature-only marker)
    const empty_body = try ctx.newNode(.{ .block = .{ .stmts = &.{} } });

    return ctx.newNode(.{ .func_decl = .{
        .name = name,
        .params = try params_list.toOwnedSlice(ctx.alloc()),
        .return_type = return_type,
        .body = empty_body,
        .is_compt = false,
        .is_pub = true, // blueprint methods are implicitly pub
        .is_bridge = true, // mark as bridge so codegen knows there's no real body
        .is_thread = false,
    } });
}
```

Note: We reuse `func_decl` nodes for blueprint methods with `is_bridge = true` (no body) and `is_pub = true` (implicitly public). This avoids adding a new node kind just for method signatures and reuses existing infrastructure for parameter/type resolution.

- [ ] **Step 5: Update builder_decls.zig file header**

Update the comment at line 1-5 to include the new functions:

```zig
// builder_decls.zig — Declaration builders for the PEG AST builder
// Contains: buildProgram, buildModuleDecl, buildImport, buildMetadata,
//           buildFuncDecl, buildParam, buildConstDecl, buildVarDecl,
//           buildStructDecl, buildBlueprintDecl, buildEnumDecl, buildFieldDecl,
//           buildEnumVariant, buildDestructDecl, buildBitfieldDecl, buildTestDecl
```

- [ ] **Step 6: Run unit tests**

Run: `zig build test 2>&1 | tail -20`
Expected: All existing tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/peg/builder.zig src/peg/builder_decls.zig
git commit -m "feat: add blueprint PEG builder and struct conformance parsing"
```

---

### Task 5: Add blueprint collection to declaration pass

**Files:**
- Modify: `src/declarations.zig:14-27` (add BlueprintMethodSig struct)
- Modify: `src/declarations.zig:35-39` (add BlueprintSig struct, extend StructSig)
- Modify: `src/declarations.zig:74-152` (DeclTable — add blueprints map, init, deinit)
- Modify: `src/declarations.zig:228-244` (collectTopLevel — add blueprint_decl case)

- [ ] **Step 1: Write a failing unit test for blueprint collection**

At the bottom of `src/declarations.zig`, add a test block:

```zig
test "collectBlueprint registers blueprint in DeclTable" {
    // This test verifies that a BlueprintDecl AST node gets collected
    // into decls.blueprints with correct method signatures.
    // For now, just verify the BlueprintSig and BlueprintMethodSig types exist
    // and DeclTable.blueprints map is initialized.
    const alloc = std.testing.allocator;
    var reporter = @import("errors.zig").Reporter.init(alloc);
    defer reporter.deinit();
    var table = DeclTable.init(alloc);
    defer table.deinit();
    try std.testing.expect(table.blueprints.count() == 0);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | grep -A5 "blueprint"`
Expected: Compile error — `blueprints` field doesn't exist on DeclTable yet.

- [ ] **Step 3: Add BlueprintMethodSig and BlueprintSig structs**

After `FieldSig` (around line 50), add:

```zig
pub const BlueprintMethodSig = struct {
    name: []const u8,
    params: []ParamSig,
    return_type: types.ResolvedType,
};

pub const BlueprintSig = struct {
    name: []const u8,
    methods: []BlueprintMethodSig,
    is_pub: bool,
};
```

- [ ] **Step 4: Extend StructSig with conforms_to field**

Modify `StructSig` (lines 35-39):

```zig
pub const StructSig = struct {
    name: []const u8,
    fields: []FieldSig,
    conforms_to: []const []const u8 = &.{},
    is_pub: bool,
};
```

- [ ] **Step 5: Add `blueprints` map to DeclTable**

In the `DeclTable` struct (around line 80), add after `bitfields`:

```zig
blueprints: std.StringHashMap(BlueprintSig),
```

In `init()`, add:

```zig
.blueprints = std.StringHashMap(BlueprintSig).init(allocator),
```

In `deinit()`, add (following the pattern of other maps):

```zig
{
    var it = self.blueprints.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.methods) |method| {
            self.allocator.free(method.params);
        }
        self.allocator.free(entry.value_ptr.methods);
    }
    self.blueprints.deinit();
}
```

- [ ] **Step 6: Add `collectBlueprint` function**

After `collectStruct` (line 377), add:

```zig
fn collectBlueprint(self: *DeclCollector, b: parser.BlueprintDecl, loc: ?errors.SourceLoc) anyerror!void {
    var methods: std.ArrayListUnmanaged(BlueprintMethodSig) = .{};

    for (b.methods) |member| {
        if (member.* == .func_decl) {
            const f = member.func_decl;
            var params: std.ArrayListUnmanaged(ParamSig) = .{};
            for (f.params) |param| {
                if (param.* == .param) {
                    try params.append(self.allocator, .{
                        .name = param.param.name,
                        .type_ = try types.resolveTypeNode(self.table.typeAllocator(), param.param.type_annotation),
                    });
                }
            }
            try methods.append(self.allocator, .{
                .name = f.name,
                .params = try params.toOwnedSlice(self.allocator),
                .return_type = try types.resolveTypeNode(self.table.typeAllocator(), f.return_type),
            });
        }
    }

    if (self.table.blueprints.contains(b.name)) {
        const msg = try std.fmt.allocPrint(self.allocator,
            "duplicate blueprint declaration: '{s}'", .{b.name});
        defer self.allocator.free(msg);
        try self.reporter.report(.{ .message = msg, .loc = loc });
        return;
    }

    try self.table.blueprints.put(b.name, .{
        .name = b.name,
        .methods = try methods.toOwnedSlice(self.allocator),
        .is_pub = b.is_pub,
    });
}
```

- [ ] **Step 7: Add `blueprint_decl` to collectTopLevel switch**

In `collectTopLevel` (line 228-244), add after `.struct_decl`:

```zig
.blueprint_decl => |b| try self.collectBlueprint(b, loc),
```

- [ ] **Step 8: Update collectStruct to store conforms_to**

In `collectStruct` (line 329-333), modify the StructSig construction:

```zig
const sig = StructSig{
    .name = s.name,
    .fields = try fields.toOwnedSlice(self.allocator),
    .conforms_to = s.blueprints,
    .is_pub = s.is_pub,
};
```

- [ ] **Step 9: Run unit tests**

Run: `zig build test 2>&1 | tail -20`
Expected: All tests pass, including the new blueprint collection test.

- [ ] **Step 10: Commit**

```bash
git add src/declarations.zig
git commit -m "feat: add blueprint collection to declaration pass"
```

---

### Task 6: Add conformance checking to resolver

**Files:**
- Modify: `src/resolver.zig:173-189` (registerDecl — register blueprint name in scope)
- Modify: `src/resolver.zig:278-294` (resolveNode — add blueprint_decl case)
- Modify: `src/resolver.zig` (add new `checkBlueprintConformance` function)

- [ ] **Step 1: Write negative test fixture for missing method**

Create `test/fixtures/fail_blueprint_missing_method.orh`:

```
module main

blueprint Eq {
    func eq(self: const& Eq, other: const& Eq) bool
}

struct Point: Eq {
    x: f32
    y: f32
}

func main() void {
}
```

- [ ] **Step 2: Write negative test fixture for wrong signature**

Create `test/fixtures/fail_blueprint_wrong_sig.orh`:

```
module main

blueprint Eq {
    func eq(self: const& Eq, other: const& Eq) bool
}

struct Point: Eq {
    x: f32
    y: f32

    func eq(self: const& Point) bool {
        return true
    }
}

func main() void {
}
```

- [ ] **Step 3: Write negative test fixture for unknown blueprint**

Create `test/fixtures/fail_blueprint_unknown.orh`:

```
module main

struct Point: NonExistent {
    x: f32
    y: f32
}

func main() void {
}
```

- [ ] **Step 4: Register blueprint names in scope**

In `registerDecl` (around line 173), add after `.struct_decl`:

```zig
.blueprint_decl => |b| {
    try scope.define(b.name, RT{ .named = b.name });
},
```

- [ ] **Step 5: Add blueprint_decl case to resolveNode**

In `resolveNode` (around line 278), add after `.struct_decl` case:

```zig
.blueprint_decl => |b| {
    // Validate method signatures resolve correctly
    var bp_scope = Scope.init(self.allocator, scope);
    defer bp_scope.deinit();
    // Blueprint name is a valid type within its own methods
    try bp_scope.define(b.name, .{ .primitive = .@"type" });
    for (b.methods) |method| {
        try self.resolveNode(method, &bp_scope);
    }
},
```

- [ ] **Step 6: Add conformance checking after struct resolution**

Extend the `.struct_decl` case in `resolveNode` (lines 278-294). After resolving all members, add conformance checking:

```zig
.struct_decl => |s| {
    var struct_scope = Scope.init(self.allocator, scope);
    defer struct_scope.deinit();
    // Add type params to scope (T: type → T is a known type)
    for (s.type_params) |param| {
        if (param.* == .param) {
            const is_tp = param.param.type_annotation.* == .type_named and
                std.mem.eql(u8, param.param.type_annotation.type_named, "type");
            if (is_tp) {
                try struct_scope.define(param.param.name, .{ .primitive = .@"type" });
            }
        }
    }
    for (s.members) |member| {
        try self.resolveNode(member, &struct_scope);
    }
    // Check blueprint conformance
    try self.checkBlueprintConformance(s, self.nodeLoc(node));
},
```

- [ ] **Step 7: Implement checkBlueprintConformance**

Add this function to the `TypeResolver` struct:

```zig
fn checkBlueprintConformance(self: *TypeResolver, s: parser.StructDecl, loc: ?errors.SourceLoc) anyerror!void {
    // Check for duplicate blueprint references
    for (s.blueprints, 0..) |bp_name, i| {
        for (s.blueprints[0..i]) |prev| {
            if (std.mem.eql(u8, bp_name, prev)) {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "struct '{s}' lists blueprint '{s}' more than once", .{ s.name, bp_name });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = loc });
            }
        }
    }

    for (s.blueprints) |bp_name| {
        // Look up blueprint in declarations
        const bp_sig = self.decls.blueprints.get(bp_name) orelse {
            const msg = try std.fmt.allocPrint(self.allocator,
                "unknown blueprint '{s}'", .{bp_name});
            defer self.allocator.free(msg);
            try self.reporter.report(.{ .message = msg, .loc = loc });
            continue;
        };

        // Check each required method
        for (bp_sig.methods) |bp_method| {
            const method_key = try std.fmt.allocPrint(self.allocator,
                "{s}.{s}", .{ s.name, bp_method.name });
            defer self.allocator.free(method_key);

            const struct_method = self.decls.struct_methods.get(method_key) orelse {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "struct '{s}' does not implement '{s}' required by blueprint '{s}'",
                    .{ s.name, bp_method.name, bp_name });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = loc });
                continue;
            };

            // Compare parameter count
            if (struct_method.params.len != bp_method.params.len) {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "method '{s}' in struct '{s}' has {d} parameter(s), blueprint '{s}' requires {d}",
                    .{ bp_method.name, s.name, struct_method.params.len, bp_name, bp_method.params.len });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = loc });
                continue;
            }

            // Compare parameter types (with blueprint→struct name substitution)
            for (struct_method.params, bp_method.params) |sp, bp| {
                if (!self.typesMatchWithSubstitution(sp.type_, bp.type_, bp_name, s.name)) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "method '{s}' in struct '{s}' does not match blueprint '{s}': parameter type mismatch",
                        .{ bp_method.name, s.name, bp_name });
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = loc });
                    break;
                }
            }

            // Compare return type
            if (!self.typesMatchWithSubstitution(struct_method.return_type, bp_method.return_type, bp_name, s.name)) {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "method '{s}' in struct '{s}' does not match blueprint '{s}': return type mismatch",
                    .{ bp_method.name, s.name, bp_name });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = loc });
            }
        }
    }
}

fn typesMatchWithSubstitution(self: *TypeResolver, struct_type: types.ResolvedType, bp_type: types.ResolvedType, bp_name: []const u8, struct_name: []const u8) bool {
    _ = self;
    // Named types: blueprint name in bp_type matches struct name in struct_type
    switch (bp_type) {
        .named => |name| {
            if (std.mem.eql(u8, name, bp_name)) {
                // Blueprint's own name → must match struct's name
                return switch (struct_type) {
                    .named => |sn| std.mem.eql(u8, sn, struct_name),
                    else => false,
                };
            }
            // Non-self named type must match exactly
            return switch (struct_type) {
                .named => |sn| std.mem.eql(u8, sn, name),
                else => false,
            };
        },
        .primitive => |p| {
            return switch (struct_type) {
                .primitive => |sp| sp == p,
                else => false,
            };
        },
        .ptr => |bp_ptr| {
            return switch (struct_type) {
                .ptr => |sp| {
                    if (!std.mem.eql(u8, bp_ptr.kind, sp.kind)) return false;
                    return self.typesMatchWithSubstitution(bp_ptr.elem.*, sp.elem.*, bp_name, struct_name);
                },
                else => false,
            };
        },
        .error_union => |bp_inner| {
            return switch (struct_type) {
                .error_union => |si| self.typesMatchWithSubstitution(bp_inner.*, si.*, bp_name, struct_name),
                else => false,
            };
        },
        .null_union => |bp_inner| {
            return switch (struct_type) {
                .null_union => |si| self.typesMatchWithSubstitution(bp_inner.*, si.*, bp_name, struct_name),
                else => false,
            };
        },
        .inferred => return struct_type == .inferred,
        .unknown => return true,
        else => {
            // For other types (slice, array, tuple, func_ptr, generic, etc.)
            // fall back to direct equality check via tag comparison
            return std.meta.activeTag(bp_type) == std.meta.activeTag(struct_type);
        },
    }
}
```

- [ ] **Step 8: Run unit tests**

Run: `zig build test 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add src/resolver.zig test/fixtures/fail_blueprint_missing_method.orh test/fixtures/fail_blueprint_wrong_sig.orh test/fixtures/fail_blueprint_unknown.orh
git commit -m "feat: add blueprint conformance checking to resolver"
```

---

### Task 7: Handle blueprints in MIR and codegen (skip/erase)

**Files:**
- Modify: `src/mir/mir_annotator.zig:120-133` (add blueprint_decl skip case)
- Modify: `src/codegen/codegen_decls.zig` (add blueprint_decl skip case)
- Modify: `src/declarations.zig:204-221` (has_bridge check — skip blueprint_decl)

- [ ] **Step 1: Add blueprint_decl case to MIR annotator**

In `src/mir/mir_annotator.zig`, in the `annotateNode` switch (around line 120), add after `.struct_decl`:

```zig
.blueprint_decl => {
    // Blueprints are erased — no MIR annotation needed
},
```

- [ ] **Step 2: Add blueprint_decl skip to codegen**

In `src/codegen/codegen_decls.zig`, find the top-level node dispatch and add:

```zig
.blueprint_decl => {
    // Blueprints are erased at codegen — no Zig output
},
```

- [ ] **Step 3: Skip blueprint_decl in has_bridge check**

In `src/declarations.zig`, the `collect` function's bridge validation loop (lines 206-212) uses a switch on node kinds. Ensure `blueprint_decl` doesn't interfere — it should fall through to `else => {}`.

Verify the existing code already handles this via `else => {}`. If the switch is exhaustive, add:

```zig
.blueprint_decl => {},
```

- [ ] **Step 4: Run full test suite**

Run: `./testall.sh 2>&1 | tail -30`
Expected: All existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/mir/mir_annotator.zig src/codegen/codegen_decls.zig src/declarations.zig
git commit -m "feat: skip blueprints in MIR annotation and codegen (pure erasure)"
```

---

### Task 8: Write positive test fixtures

**Files:**
- Create: `test/fixtures/blueprint_basic.orh`
- Create: `test/fixtures/blueprint_multiple.orh`
- Create: `test/fixtures/blueprint_main.orh`

- [ ] **Step 1: Create basic blueprint test fixture**

Create `test/fixtures/blueprint_basic.orh`:

```
module tester

blueprint Eq {
    func eq(self: const& Eq, other: const& Eq) bool
}

struct Point: Eq {
    x: f32
    y: f32

    pub func eq(self: const& Point, other: const& Point) bool {
        return self.x == other.x and self.y == other.y
    }
}
```

- [ ] **Step 2: Create multiple-blueprint test fixture**

Create `test/fixtures/blueprint_multiple.orh`:

```
module tester

blueprint Eq {
    func eq(self: const& Eq, other: const& Eq) bool
}

blueprint Printable {
    func toString(self: const& Printable) str
}

struct Color: Eq, Printable {
    r: u8
    g: u8
    b: u8

    pub func eq(self: const& Color, other: const& Color) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b
    }

    pub func toString(self: const& Color) str {
        return "Color"
    }
}
```

- [ ] **Step 3: Create main entry point for blueprint test project**

Create `test/fixtures/blueprint_main.orh`:

```
module main
#name    = "bptest"
#version = (1, 0, 0)
#build   = exe

func main() void {
}
```

- [ ] **Step 4: Commit**

```bash
git add test/fixtures/blueprint_basic.orh test/fixtures/blueprint_multiple.orh test/fixtures/blueprint_main.orh
git commit -m "test: add blueprint positive test fixtures"
```

---

### Task 9: Add integration tests

**Files:**
- Modify: `test/09_language.sh` (add blueprint compilation tests)
- Modify: `test/11_errors.sh` (add blueprint negative tests)

- [ ] **Step 1: Add blueprint tests to test/09_language.sh**

At the end of `test/09_language.sh`, before the final line, add:

```bash
section "Blueprint features"

cd "$TESTDIR"
mkdir -p bptest/src
cp "$FIXTURES/blueprint_main.orh" bptest/src/main.orh
cp "$FIXTURES/blueprint_basic.orh" bptest/src/blueprint_basic.orh
cd bptest

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/bptest"; then
    pass "basic blueprint compiles"
else
    fail "basic blueprint compiles" "$OUTPUT"
fi

GEN_TESTER=".orh-cache/generated/tester.zig"
if [ -f "$GEN_TESTER" ]; then
    # Verify blueprint is erased — no trace in generated Zig
    if grep -q "blueprint" "$GEN_TESTER"; then
        fail "blueprint erased from codegen"
    else
        pass "blueprint erased from codegen"
    fi
    # Verify struct and method are present
    if grep -q "fn eq" "$GEN_TESTER"; then
        pass "blueprint method present in struct codegen"
    else
        fail "blueprint method present in struct codegen"
    fi
else
    fail "tester.zig generated for blueprint test"
fi

cd "$TESTDIR"
mkdir -p bpmulti/src
cp "$FIXTURES/blueprint_main.orh" bpmulti/src/main.orh
cp "$FIXTURES/blueprint_multiple.orh" bpmulti/src/blueprint_multiple.orh
cd bpmulti

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/bptest"; then
    pass "multiple blueprints compile"
else
    fail "multiple blueprints compile" "$OUTPUT"
fi
```

- [ ] **Step 2: Add negative tests to test/11_errors.sh**

At the end of `test/11_errors.sh`, add:

```bash
# blueprint: missing method
cd "$TESTDIR"
mkdir -p neg_bp_missing/src
cp "$FIXTURES/fail_blueprint_missing_method.orh" neg_bp_missing/src/main.orh
cd neg_bp_missing
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "does not implement.*required by blueprint"; then
    pass "rejects missing blueprint method"
else
    fail "rejects missing blueprint method" "$NEG_OUT"
fi

# blueprint: wrong signature
cd "$TESTDIR"
mkdir -p neg_bp_sig/src
cp "$FIXTURES/fail_blueprint_wrong_sig.orh" neg_bp_sig/src/main.orh
cd neg_bp_sig
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "does not match blueprint\|parameter"; then
    pass "rejects wrong blueprint method signature"
else
    fail "rejects wrong blueprint method signature" "$NEG_OUT"
fi

# blueprint: unknown blueprint
cd "$TESTDIR"
mkdir -p neg_bp_unknown/src
cp "$FIXTURES/fail_blueprint_unknown.orh" neg_bp_unknown/src/main.orh
cd neg_bp_unknown
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "unknown blueprint"; then
    pass "rejects unknown blueprint"
else
    fail "rejects unknown blueprint" "$NEG_OUT"
fi
```

- [ ] **Step 3: Run full test suite**

Run: `./testall.sh 2>&1 | tail -40`
Expected: All tests pass, including the new blueprint tests.

- [ ] **Step 4: Commit**

```bash
git add test/09_language.sh test/11_errors.sh
git commit -m "test: add blueprint integration and negative tests"
```

---

### Task 10: Update example module and docs

**Files:**
- Modify: one of the example module files in `src/templates/` (add blueprint usage)
- Modify: `docs/TODO.md` (mark blueprint as done)

- [ ] **Step 1: Add blueprint to example module**

Pick an appropriate example file (or create a new one like `src/templates/example_blueprints.orh`). Add:

```
module example

// blueprints — strict contracts for structs
blueprint Describable {
    func describe(self: const& Describable) str
}

// struct conformance — implement all blueprint methods
struct Animal: Describable {
    name: str
    legs: i32

    pub func describe(self: const& Animal) str {
        return self.name
    }
}
```

If creating a new template file, also:
- Add the `@embedFile` constant in `src/main.zig` (follow the pattern of existing example files)
- Add the write logic in `initProject()` in `src/init.zig`

- [ ] **Step 2: Update docs/TODO.md**

Add blueprint to the completed items or mark it as done.

- [ ] **Step 3: Run full test suite**

Run: `./testall.sh 2>&1 | tail -30`
Expected: All tests pass, including example module compilation.

- [ ] **Step 4: Commit**

```bash
git add src/templates/ src/init.zig docs/TODO.md
git commit -m "docs: add blueprint to example module and mark as done in TODO"
```

---

### Task 11: Final validation and version bump

- [ ] **Step 1: Run full test suite**

Run: `./testall.sh`
Expected: All tests pass — zero failures.

- [ ] **Step 2: Verify error messages work**

Manually test each error case by creating a quick `.orh` file:

```bash
cd /tmp && mkdir bpcheck && cd bpcheck && mkdir src
cat > src/main.orh << 'EOF'
module main
#name    = "bpcheck"
#version = (1, 0, 0)
#build   = exe

blueprint Eq {
    func eq(self: const& Eq, other: const& Eq) bool
}

struct Point: Eq {
    x: f32
}

func main() void {
}
EOF
orhon build 2>&1
```

Expected: Error about missing `eq` method on `Point`.

- [ ] **Step 3: Bump version to v0.12.0**

Update version in `build.zig.zon`:

```bash
# Find and update the version string
```

- [ ] **Step 4: Final commit**

```bash
git add build.zig.zon
git commit -m "bump version to 0.12.0 — blueprint contracts"
```
