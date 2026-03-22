// mir.zig — MIR (Mid-level Intermediate Representation) pass (pass 10)
// MIR instruction type definitions + generation from AST.
// Simple SSA-based instructions. Bridge between AST and Zig codegen.

const std = @import("std");
const parser = @import("parser.zig");
const errors = @import("errors.zig");

/// MIR instruction kinds
pub const MirKind = enum {
    alloc,      // allocate a variable slot
    move,       // move value from one slot to another
    borrow,     // create an immutable borrow
    mut_borrow, // create a mutable borrow
    drop,       // drop a value (scope exit)
    call,       // function call
    load,       // load a value
    store,      // store a value
    ret,        // return from function
    jump,       // unconditional jump
    branch,     // conditional branch
    label,      // jump target label
    phi,        // SSA phi node (merge point)
};

/// A MIR value — either a local slot or a constant
pub const MirValue = union(enum) {
    local: usize,       // slot index
    int_const: i64,
    float_const: f64,
    bool_const: bool,
    string_const: []const u8,
    null_const: void,
    func_ref: []const u8,
};

/// A single MIR instruction
pub const MirInstr = union(MirKind) {
    alloc: struct {
        slot: usize,
        type_str: []const u8,
        name: []const u8,
    },
    move: struct {
        dst: usize,
        src: MirValue,
    },
    borrow: struct {
        dst: usize,
        src: usize,
    },
    mut_borrow: struct {
        dst: usize,
        src: usize,
    },
    drop: struct {
        slot: usize,
    },
    call: struct {
        dst: ?usize,
        func: MirValue,
        args: []MirValue,
    },
    load: struct {
        dst: usize,
        src: MirValue,
    },
    store: struct {
        dst: usize,
        value: MirValue,
    },
    ret: struct {
        value: ?MirValue,
    },
    jump: struct {
        target: usize, // label index
    },
    branch: struct {
        condition: MirValue,
        true_target: usize,
        false_target: usize,
    },
    label: struct {
        id: usize,
    },
    phi: struct {
        dst: usize,
        sources: []usize,
    },
};

/// A MIR function — sequence of instructions for one function
pub const MirFunc = struct {
    name: []const u8,
    instructions: std.ArrayListUnmanaged(MirInstr),
    slot_count: usize,

    pub fn init(name: []const u8) MirFunc {
        return .{
            .name = name,
            .instructions = .{},
            .slot_count = 0,
        };
    }

    pub fn deinit(self: *MirFunc, allocator: std.mem.Allocator) void {
        for (self.instructions.items) |instr| {
            switch (instr) {
                .call => |c| allocator.free(c.args),
                else => {},
            }
        }
        self.instructions.deinit(allocator);
    }

    pub fn nextSlot(self: *MirFunc) usize {
        const slot = self.slot_count;
        self.slot_count += 1;
        return slot;
    }
};

/// The MIR module — collection of functions
pub const MirModule = struct {
    name: []const u8,
    funcs: std.StringHashMap(MirFunc),
    allocator: std.mem.Allocator,

    pub fn init(name: []const u8, allocator: std.mem.Allocator) MirModule {
        return .{
            .name = name,
            .funcs = std.StringHashMap(MirFunc).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MirModule) void {
        var it = self.funcs.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.funcs.deinit();
    }
};

/// The MIR generator
pub const MirGen = struct {
    module: MirModule,
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    current_func: ?*MirFunc,
    label_counter: usize,

    pub fn init(mod_name: []const u8, allocator: std.mem.Allocator, reporter: *errors.Reporter) MirGen {
        return .{
            .module = MirModule.init(mod_name, allocator),
            .reporter = reporter,
            .allocator = allocator,
            .current_func = null,
            .label_counter = 0,
        };
    }

    pub fn deinit(self: *MirGen) void {
        self.module.deinit();
    }

    fn nextLabel(self: *MirGen) usize {
        const l = self.label_counter;
        self.label_counter += 1;
        return l;
    }

    fn emit(self: *MirGen, instr: MirInstr) !void {
        if (self.current_func) |f| {
            try f.instructions.append(self.allocator, instr);
        }
    }

    /// Generate MIR from a program AST
    pub fn generate(self: *MirGen, ast: *parser.Node) !void {
        if (ast.* != .program) return;
        for (ast.program.top_level) |node| {
            try self.generateTopLevel(node);
        }
    }

    fn generateTopLevel(self: *MirGen, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .func_decl => |f| try self.generateFunc(f),
            .struct_decl => |s| {
                for (s.members) |member| {
                    if (member.* == .func_decl) try self.generateTopLevel(member);
                }
            },
            else => {},
        }
    }

    fn generateFunc(self: *MirGen, f: parser.FuncDecl) anyerror!void {
        const func = MirFunc.init(f.name);
        try self.module.funcs.put(f.name, func);
        self.current_func = self.module.funcs.getPtr(f.name);

        // Allocate slots for parameters
        if (self.current_func) |cf| {
            for (f.params) |param| {
                if (param.* == .param) {
                    const slot = cf.nextSlot();
                    try self.emit(.{ .alloc = .{
                        .slot = slot,
                        .type_str = "param",
                        .name = param.param.name,
                    }});
                }
            }
        }

        // Generate body
        try self.generateNode(f.body);

        self.current_func = null;
    }

    fn generateNode(self: *MirGen, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .block => |b| {
                for (b.statements) |stmt| {
                    try self.generateStatement(stmt);
                }
            },
            else => {},
        }
    }

    fn generateStatement(self: *MirGen, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .var_decl => |v| {
                if (self.current_func) |cf| {
                    const slot = cf.nextSlot();
                    try self.emit(.{ .alloc = .{
                        .slot = slot,
                        .type_str = if (v.type_annotation) |t| typeStr(t) else "inferred",
                        .name = v.name,
                    }});
                    const val = try self.generateExpr(v.value);
                    try self.emit(.{ .store = .{ .dst = slot, .value = val } });
                }
            },

            .return_stmt => |r| {
                if (r.value) |val| {
                    const mir_val = try self.generateExpr(val);
                    try self.emit(.{ .ret = .{ .value = mir_val } });
                } else {
                    try self.emit(.{ .ret = .{ .value = null } });
                }
            },

            .if_stmt => |i| {
                const cond = try self.generateExpr(i.condition);
                const true_label = self.nextLabel();
                const false_label = self.nextLabel();
                const end_label = self.nextLabel();

                try self.emit(.{ .branch = .{
                    .condition = cond,
                    .true_target = true_label,
                    .false_target = false_label,
                }});

                try self.emit(.{ .label = .{ .id = true_label } });
                try self.generateNode(i.then_block);
                try self.emit(.{ .jump = .{ .target = end_label } });

                try self.emit(.{ .label = .{ .id = false_label } });
                if (i.else_block) |e| try self.generateNode(e);

                try self.emit(.{ .label = .{ .id = end_label } });
            },

            .assignment => |a| {
                const val = try self.generateExpr(a.right);
                _ = val;
                // Store to left-hand side (simplified)
            },

            .block => try self.generateNode(node),

            else => _ = try self.generateExpr(node),
        }
    }

    fn generateExpr(self: *MirGen, node: *parser.Node) !MirValue {
        return switch (node.*) {
            .int_literal => |text| blk: {
                const val = std.fmt.parseInt(i64, std.mem.trim(u8, text, "_"), 0) catch 0;
                break :blk MirValue{ .int_const = val };
            },
            .float_literal => |text| blk: {
                const val = std.fmt.parseFloat(f64, text) catch 0.0;
                break :blk MirValue{ .float_const = val };
            },
            .bool_literal => |b| MirValue{ .bool_const = b },
            .null_literal => MirValue{ .null_const = {} },
            .string_literal => |s| MirValue{ .string_const = s },
            .interpolated_string => MirValue{ .string_const = "\"<interpolated>\"" },
            .identifier => |name| blk: {
                // Look up slot — simplified, returns func_ref for now
                break :blk MirValue{ .func_ref = name };
            },
            .call_expr => |c| blk: {
                if (self.current_func) |cf| {
                    const dst = cf.nextSlot();
                    var args: std.ArrayListUnmanaged(MirValue) = .{};
                    for (c.args) |arg| {
                        try args.append(self.allocator, try self.generateExpr(arg));
                    }
                    const callee = try self.generateExpr(c.callee);
                    try self.emit(.{ .call = .{
                        .dst = dst,
                        .func = callee,
                        .args = try args.toOwnedSlice(self.allocator),
                    }});
                    break :blk MirValue{ .local = dst };
                }
                break :blk MirValue{ .null_const = {} };
            },
            else => MirValue{ .null_const = {} },
        };
    }
};

fn typeStr(node: *parser.Node) []const u8 {
    return switch (node.*) {
        .type_named => |n| n,
        else => "unknown",
    };
}

test "mir - basic generation" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var gen = MirGen.init("test", alloc, &reporter);
    defer gen.deinit();

    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), gen.module.funcs.count());
}

test "mir - func registration" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var gen = MirGen.init("test", alloc, &reporter);
    defer gen.deinit();

    // Manually add a function
    const func = MirFunc.init("add");
    try gen.module.funcs.put("add", func);
    try std.testing.expectEqual(@as(usize, 1), gen.module.funcs.count());
}
