const std = @import("std");
const context = @import("context.zig");
const checked_ast = @import("checked_ast.zig");
const type_store = @import("type_store.zig");

const TempId = usize;

const Value = union(enum) {
    temp: TempId,
    unit,
    int: i64,
    bool: bool,
    variable: []const u8,
    function: []const u8,
};

pub const Operand = struct {
    value: Value,
    type_id: type_store.TypeId,

    pub fn format(self: Operand, writer: *std.Io.Writer) !void {
        return switch (self.value) {
            .temp => |id| try writer.print("t{d}", .{id}),
            .unit => try writer.print("()", .{}),
            .int => |i| try writer.print("{d}", .{i}),
            .bool => |b| try writer.print("{s}", .{if (b) "true" else "false"}),
            .variable => |name| try writer.print("{s}", .{name}),
            .function => |name| try writer.print("{s}", .{name}),
        };
    }

    pub fn toString(self: Operand) []const u8 {
        return switch (self.value) {
            .temp => |id| std.fmt.allocPrint(std.heap.page_allocator, "t{d}", .{id}) catch
                @panic("Failed to format temp operand"),
            .unit => "()",
            .int => |i| std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{i}) catch
                @panic("Failed to format int operand"),
            .bool => |b| if (b) "true" else "false",
            .variable => |name| name,
            .function => |name| name,
        };
    }
};

pub const Terminator = union(enum) {
    @"return": Operand,
    exit: Operand,
    jump: usize, // target block id
    cond_jump: struct {
        condition: Operand,
        true_target: usize,
        false_target: usize,
    },

    pub fn format(self: Terminator, writer: *std.Io.Writer) !void {
        return switch (self) {
            .@"return" => |value| try writer.print("return {f}", .{value}),
            .exit => |code| try writer.print("exit {f}", .{code}),
            .jump => |target| try writer.print("jump Block {d}", .{target}),
            .cond_jump => |cj| try writer.print(
                "if {f} then jump Block {d} else jump Block {d}",
                .{ cj.condition, cj.true_target, cj.false_target },
            ),
        };
    }
};

pub const BasicBlock = struct {
    id: usize,
    instructions: std.ArrayList(Instr) = .empty,
    terminator: ?Terminator = null,

    pub fn format(self: BasicBlock, writer: *std.Io.Writer) !void {
        try writer.print("Block {d}:\n", .{self.id});
        for (self.instructions.items) |instr| {
            try writer.print("\t{f}", .{instr});
        }
        if (self.terminator) |term| {
            try writer.print("\t{f}\n", .{term});
        }
    }

    pub fn init(id: usize) BasicBlock {
        return BasicBlock{ .id = id };
    }
};

pub const IRFunction = struct {
    name: []const u8,
    params: std.ArrayList(Operand) = .empty,
    blocks: std.ArrayList(BasicBlock) = .empty,
    entry_block_id: usize,

    pub fn format(self: IRFunction, writer: *std.Io.Writer) !void {
        try writer.print("Function {s}:\n", .{self.name});
        for (self.blocks.items) |block| {
            try writer.print("    {f}\n", .{block});
        }
    }
};

pub const Instr = union(enum) {
    add: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    sub: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    mul: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    div: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    unary_minus: struct {
        result: Operand,
        operand: Operand,
    },
    eq: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    neq: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    lt: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    lt_eq: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    gt: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    gt_eq: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    assign: struct {
        target: Operand,
        value: Operand,
    },
    call: struct {
        result: Operand,
        callee: []const u8,
        args: []Operand,
    },

    pub fn format(self: Instr, writer: *std.Io.Writer) !void {
        return switch (self) {
            .add => |a| try writer.print(
                "{f} := {f} + {f}\n",
                .{ a.result, a.left, a.right },
            ),
            .sub => |s| try writer.print(
                "{f} := {f} - {f}\n",
                .{ s.result, s.left, s.right },
            ),
            .mul => |m| try writer.print(
                "{f} := {f} * {f}\n",
                .{ m.result, m.left, m.right },
            ),
            .div => |d| try writer.print(
                "{f} := {f} / {f}\n",
                .{ d.result, d.left, d.right },
            ),
            .unary_minus => |u| try writer.print(
                "{f} := -{f}\n",
                .{ u.result, u.operand },
            ),
            .assign => |a| try writer.print(
                "{f} := {f}\n",
                .{ a.target, a.value },
            ),
            .eq => |e| try writer.print(
                "{f} := {f} == {f}\n",
                .{ e.result, e.left, e.right },
            ),
            .neq => |n| try writer.print(
                "{f} := {f} != {f}\n",
                .{ n.result, n.left, n.right },
            ),
            .lt => |l| try writer.print(
                "{f} := {f} < {f}\n",
                .{ l.result, l.left, l.right },
            ),
            .lt_eq => |le| try writer.print(
                "{f} := {f} <= {f}\n",
                .{ le.result, le.left, le.right },
            ),
            .gt => |g| try writer.print(
                "{f} := {f} > {f}\n",
                .{ g.result, g.left, g.right },
            ),
            .gt_eq => |ge| try writer.print(
                "{f} := {f} >= {f}\n",
                .{ ge.result, ge.left, ge.right },
            ),
            .call => |c| {
                try writer.print("{f} := call {s}(", .{ c.result, c.callee });
                for (c.args, 0..) |arg, i| {
                    try writer.print("{f}", .{arg});
                    if (i < c.args.len - 1) try writer.print(", ", .{});
                }
                try writer.print(")\n", .{});
            },
        };
    }
};

const Variable = struct {
    name: []const u8,
    type_id: type_store.TypeId,
};

pub const IRGen = struct {
    ctx: *context.CompilerContext,
    variables: std.ArrayList(Variable) = .empty,
    temp_id: usize = 0,

    functions: std.ArrayList(IRFunction) = .empty,
    current_func_idx: ?usize = null,
    current_block_idx: ?usize = null,
    next_block_idx: usize = 0,

    pub fn init(ctx: *context.CompilerContext) IRGen {
        return IRGen{
            .ctx = ctx,
        };
    }

    pub fn generate(self: *IRGen, exprs: []const *checked_ast.CheckedExpr) !void {
        try self.createFunction("_main", null);
        const exit_code = if (exprs.len > 0) blk: {
            for (exprs[0 .. exprs.len - 1]) |expr| {
                _ = try self.genExpr(expr);
            }

            const last = try self.genExpr(exprs[exprs.len - 1]);
            if (last.type_id == self.ctx.typeStore().builtins.int or
                last.type_id == self.ctx.typeStore().builtins.bool) break :blk last;

            // NOTE: for now, we accept Bool as exit code (false: 0, true: 1)
            break :blk Operand{
                .value = .{ .int = 0 },
                .type_id = self.ctx.typeStore().builtins.int,
            };
        } else Operand{
            .value = .{ .int = 0 },
            .type_id = self.ctx.typeStore().builtins.int,
        };

        self.setTerminator(.{ .exit = exit_code });

        // const f_idx = self.currentFuncIdx.?;
        // const b_idx = self.currentBlockIdx.?;
        // if (self.functions.items[f_idx].blocks.items[b_idx].terminator == null) {
        //     self.functions.items[f_idx].blocks.items[b_idx].terminator = .{ .Return = null };
        // }

        // return self.instructions.toOwnedSlice(self.ctx.allocator);
    }

    fn createFunction(self: *IRGen, name: []const u8, id: ?usize) !void {
        var func_name: []const u8 = name;
        if (id) |i| {
            func_name = try std.fmt.allocPrint(self.ctx.allocator, "{s}${d}", .{ name, i });
        }
        // const id = self.nextFuncId;
        // self.nextFuncId += 1;

        const func = IRFunction{
            .name = func_name,
            .entry_block_id = self.next_block_idx,
        };
        try self.functions.append(self.ctx.allocator, func);
        self.current_func_idx = self.functions.items.len - 1;
        const entry_id = try self.createBlock(); // create entry block
        try self.switchToBlock(entry_id);
    }

    fn emit(self: *IRGen, instr: Instr) !void {
        const f_idx = self.current_func_idx.?;
        const b_idx = self.current_block_idx.?;

        try self.functions.items[f_idx].blocks.items[b_idx].instructions.append(self.ctx.allocator, instr);
    }

    fn createBlock(self: *IRGen) !usize {
        const id = self.next_block_idx;
        self.next_block_idx += 1;

        const block = BasicBlock.init(id);
        const f_idx = self.current_func_idx orelse return error.NoCurrentFunction;
        try self.functions.items[f_idx].blocks.append(self.ctx.allocator, block);

        return id;
    }

    fn switchToBlock(self: *IRGen, id: usize) !void {
        const f_idx = self.current_func_idx orelse return error.NoCurrentFunction;
        for (self.functions.items[f_idx].blocks.items, 0..) |block, idx| {
            if (block.id == id) {
                self.current_block_idx = idx;
                return;
            }
        }
        return error.BlockNotFound;
    }

    fn setTerminator(self: *IRGen, terminator: Terminator) void {
        const f_idx = self.current_func_idx.?;
        const b_idx = self.current_block_idx.?;
        self.functions.items[f_idx].blocks.items[b_idx].terminator = terminator;
    }

    fn addVariable(self: *IRGen, name: []const u8, id: usize, type_id: usize) !void {
        const n = try std.fmt.allocPrint(self.ctx.allocator, "{s}#{d}", .{ name, id });
        try self.variables.append(self.ctx.allocator, Variable{
            .name = n,
            .type_id = type_id,
        });
    }

    fn lookupVariable(self: *IRGen, name: []const u8, id: usize) ?Variable {
        const full_name = std.fmt.allocPrint(self.ctx.allocator, "{s}#{d}", .{ name, id }) catch return null;
        for (self.variables.items) |v| {
            if (std.mem.eql(u8, v.name, full_name)) {
                return v;
            }
        }
        return null;
    }

    // TODO: too long, split into multiple functions
    fn genExpr(self: *IRGen, expr: *const checked_ast.CheckedExpr) !Operand {
        switch (expr.kind) {
            .int_literal => |v| return Operand{
                .value = .{ .int = v },
                .type_id = self.ctx.typeStore().builtins.int,
            },
            .bool_literal => |v| return Operand{
                .value = .{ .bool = v },
                .type_id = self.ctx.typeStore().builtins.bool,
            },
            .identifier => |ident| {
                const v = self.lookupVariable(ident.name, ident.id) orelse return error.UndefinedVariable;
                return Operand{
                    .value = .{ .variable = v.name },
                    .type_id = v.type_id,
                };
            },
            .unit_literal => return Operand{
                .value = .unit,
                .type_id = self.ctx.typeStore().builtins.unit,
            },
            .unary => |un| {
                const right_op = try self.genExpr(un.right);

                const result_temp_id = self.nextId();
                const result_op = Operand{
                    .value = .{ .temp = result_temp_id },
                    .type_id = right_op.type_id,
                };

                var instr: Instr = undefined;
                switch (un.operator) {
                    .minus => {
                        instr = Instr{ .unary_minus = .{
                            .result = result_op,
                            .operand = right_op,
                        } };
                    },
                    else => return error.IRUnimplementedOperator,
                }

                try self.emit(instr);
                return result_op;
            },
            .binary => |bin| {
                const left_op = try self.genExpr(bin.left);
                const right_op = try self.genExpr(bin.right);

                const result_temp_id = self.nextId();
                var result_op: Operand = undefined;
                var instr: Instr = undefined;

                switch (bin.operator) {
                    .plus, .minus, .multiply, .divide => {
                        result_op = Operand{
                            .value = .{ .temp = result_temp_id },
                            .type_id = self.ctx.typeStore().builtins.int,
                        };

                        if (bin.operator == .plus) instr = Instr{ .add = .{
                            .result = result_op,
                            .left = left_op,
                            .right = right_op,
                        } };
                        if (bin.operator == .minus) instr = Instr{ .sub = .{
                            .result = result_op,
                            .left = left_op,
                            .right = right_op,
                        } };
                        if (bin.operator == .multiply) instr = Instr{ .mul = .{
                            .result = result_op,
                            .left = left_op,
                            .right = right_op,
                        } };
                        if (bin.operator == .divide) instr = Instr{ .div = .{
                            .result = result_op,
                            .left = left_op,
                            .right = right_op,
                        } };
                    },

                    .equal,
                    .not_equal,
                    .less_than,
                    .greater_than,
                    .less_than_or_eq,
                    .greater_than_or_eq,
                    => {
                        result_op = Operand{
                            .value = .{ .temp = result_temp_id },
                            .type_id = self.ctx.typeStore().builtins.bool,
                        };

                        if (bin.operator == .equal) instr = Instr{
                            .eq = .{
                                .result = result_op,
                                .left = left_op,
                                .right = right_op,
                            },
                        };
                        if (bin.operator == .not_equal) instr = Instr{
                            .neq = .{
                                .result = result_op,
                                .left = left_op,
                                .right = right_op,
                            },
                        };
                        if (bin.operator == .less_than) instr = Instr{
                            .lt = .{
                                .result = result_op,
                                .left = left_op,
                                .right = right_op,
                            },
                        };
                        if (bin.operator == .greater_than) instr = Instr{
                            .gt = .{
                                .result = result_op,
                                .left = left_op,
                                .right = right_op,
                            },
                        };
                        if (bin.operator == .less_than_or_eq) instr = Instr{
                            .lt_eq = .{
                                .result = result_op,
                                .left = left_op,
                                .right = right_op,
                            },
                        };
                        if (bin.operator == .greater_than_or_eq) instr = Instr{
                            .gt_eq = .{
                                .result = result_op,
                                .left = left_op,
                                .right = right_op,
                            },
                        };
                    },
                    else => return error.IRUnimplementedOperator,
                }

                try self.emit(instr);
                return result_op;
            },
            .block => |block| {
                var last_op: ?Operand = null;
                for (block.stmts) |stmt| {
                    last_op = try self.genExpr(stmt);
                }

                if (block.tail) |tailExpr| {
                    return try self.genExpr(tailExpr);
                }
                return Operand{
                    .value = .unit,
                    .type_id = self.ctx.typeStore().builtins.unit,
                };
            },
            .variable_decl => |decl| { // TODO: finish
                const val = try self.genExpr(decl.value);
                const name = try std.fmt.allocPrint(
                    self.ctx.allocator,
                    "{s}#{d}",
                    .{ decl.name, decl.id },
                );

                // try self.instructions.append(self.ctx.allocator, Instr{ .Assign = .{
                //     .target = Operand{
                //         .value = .{ .Variable = name },
                //         .type = val.type,
                //     },
                //     .value = val,
                // } });

                try self.emit(Instr{ .assign = .{
                    .target = Operand{
                        .value = .{ .variable = name },
                        .type_id = val.type_id,
                    },
                    .value = val,
                } });

                try self.addVariable(decl.name, decl.id, val.type_id);

                return Operand{
                    .value = .unit,
                    .type_id = self.ctx.typeStore().builtins.unit,
                };
            },
            .func_decl => |func| {
                const prev_func_idx = self.current_func_idx;
                const prev_block_idx = self.current_block_idx;

                try self.createFunction(func.name, func.id);

                for (func.params) |param| {
                    const param_op = Operand{
                        .value = .{ .variable = try std.fmt.allocPrint(self.ctx.allocator, "{s}#{d}", .{
                            param.name,
                            param.id,
                        }) },
                        .type_id = param.type_id,
                    };
                    try self.functions.items[self.current_func_idx.?].params.append(self.ctx.allocator, param_op);
                    try self.addVariable(param.name, param.id, param_op.type_id);
                }

                const body_op = try self.genExpr(func.body);
                self.setTerminator(.{ .@"return" = body_op });

                // try self.emit(Instr{ .Ret = .{ .value = bodyOp } });

                // self.variables.shrinkRetainingCapacity(prevVarCount);
                self.current_func_idx = prev_func_idx;
                self.current_block_idx = prev_block_idx;

                const full_name = try std.fmt.allocPrint(
                    self.ctx.allocator,
                    "{s}${d}",
                    .{ func.name, func.id },
                );

                return Operand{
                    .value = .{ .function = full_name },
                    .type_id = expr.type_id, // NOTE: is this correct?
                };
            },
            // noop
            .func_type_signature => return Operand{
                .value = .unit,
                .type_id = self.ctx.typeStore().builtins.unit,
            },
            .func_call => |call| {
                var arg_ops: std.ArrayList(Operand) = .empty;
                for (call.args) |arg| {
                    const arg_op = try self.genExpr(arg);
                    try arg_ops.append(self.ctx.allocator, arg_op);
                }

                const result_temp_id = self.nextId();
                // const t = self.operandTypeFromTypeId(expr.type_id);
                const result_op = Operand{
                    .value = .{ .temp = result_temp_id },
                    .type_id = expr.type_id,
                };

                const full_name = try std.fmt.allocPrint(
                    self.ctx.allocator,
                    "{s}${d}",
                    .{ call.callee, call.id },
                );

                try self.emit(Instr{ .call = .{
                    .result = result_op,
                    .callee = full_name,
                    .args = try arg_ops.toOwnedSlice(self.ctx.allocator),
                } });

                return result_op;
            },
            .@"if" => |i| {
                const cond_op = try self.genExpr(i.condition);

                const then_block_id = try self.createBlock();
                const merge_block_id = try self.createBlock();

                const else_block_id = if (i.else_branch) |_|
                    try self.createBlock()
                else
                    merge_block_id;

                self.setTerminator(.{ .cond_jump = .{
                    .condition = cond_op,
                    .true_target = then_block_id,
                    .false_target = if (i.else_branch) |_| else_block_id else merge_block_id,
                } });

                const if_result_temp_id = self.nextId();
                const result_op = Operand{
                    .value = .{ .temp = if_result_temp_id },
                    .type_id = expr.type_id,
                };

                try self.switchToBlock(then_block_id);
                const then_op = try self.genExpr(i.then_branch);
                if (i.else_branch) |_| {
                    try self.emit(Instr{ .assign = .{
                        .target = result_op,
                        .value = then_op,
                    } });
                }
                self.setTerminator(.{ .jump = merge_block_id });

                if (i.else_branch) |elseBranch| {
                    try self.switchToBlock(else_block_id);
                    const else_op = try self.genExpr(elseBranch);
                    try self.emit(Instr{ .assign = .{
                        .target = result_op,
                        .value = else_op,
                    } });
                    self.setTerminator(.{ .jump = merge_block_id });
                }

                try self.switchToBlock(merge_block_id);

                if (i.else_branch) |_| {
                    return result_op;
                }
                return Operand{
                    .value = .unit,
                    .type_id = self.ctx.typeStore().builtins.unit,
                };
            },
            // else => return error.Unimplemented,
        }
    }

    fn nextId(self: *IRGen) usize {
        const id = self.temp_id;
        self.temp_id += 1;
        return id;
    }

    pub fn dump(self: *const IRGen) void {
        std.debug.print("=== IR DUMP ===\n", .{});
        for (self.functions.items) |func| {
            dumpFunction(func, self.ctx.typeStore());
            std.debug.print("\n", .{});
        }
    }

    fn dumpOperand(op: Operand, ts: *const type_store.TypeStore) void {
        switch (op.value) {
            .temp => |id| std.debug.print("t{d}", .{id}),
            .unit => std.debug.print("()", .{}),
            .int => |i| std.debug.print("{d}", .{i}),
            .bool => |b| std.debug.print("{s}", .{if (b) "true" else "false"}),
            .variable => |n| std.debug.print("{s}", .{n}),
            .function => |n| std.debug.print("{s}", .{n}),
        }
        std.debug.print(" : {s}", .{ts.formatTypeName(op.type_id)});
    }

    fn dumpInstr(instr: Instr, ts: *const type_store.TypeStore) void {
        std.debug.print("    ", .{});
        switch (instr) {
            .add => |x| {
                dumpOperand(x.result, ts);
                std.debug.print(" := ", .{});
                dumpOperand(x.left, ts);
                std.debug.print(" + ", .{});
                dumpOperand(x.right, ts);
            },
            .sub => |x| {
                dumpOperand(x.result, ts);
                std.debug.print(" := ", .{});
                dumpOperand(x.left, ts);
                std.debug.print(" - ", .{});
                dumpOperand(x.right, ts);
            },
            .mul => |x| {
                dumpOperand(x.result, ts);
                std.debug.print(" := ", .{});
                dumpOperand(x.left, ts);
                std.debug.print(" * ", .{});
                dumpOperand(x.right, ts);
            },
            .div => |x| {
                dumpOperand(x.result, ts);
                std.debug.print(" := ", .{});
                dumpOperand(x.left, ts);
                std.debug.print(" / ", .{});
                dumpOperand(x.right, ts);
            },
            .eq => |x| {
                dumpOperand(x.result, ts);
                std.debug.print(" := ", .{});
                dumpOperand(x.left, ts);
                std.debug.print(" == ", .{});
                dumpOperand(x.right, ts);
            },
            .neq => |x| {
                dumpOperand(x.result, ts);
                std.debug.print(" := ", .{});
                dumpOperand(x.left, ts);
                std.debug.print(" != ", .{});
                dumpOperand(x.right, ts);
            },
            .lt => |x| {
                dumpOperand(x.result, ts);
                std.debug.print(" := ", .{});
                dumpOperand(x.left, ts);
                std.debug.print(" < ", .{});
                dumpOperand(x.right, ts);
            },
            .lt_eq => |x| {
                dumpOperand(x.result, ts);
                std.debug.print(" := ", .{});
                dumpOperand(x.left, ts);
                std.debug.print(" <= ", .{});
                dumpOperand(x.right, ts);
            },
            .gt => |x| {
                dumpOperand(x.result, ts);
                std.debug.print(" := ", .{});
                dumpOperand(x.left, ts);
                std.debug.print(" > ", .{});
                dumpOperand(x.right, ts);
            },
            .gt_eq => |x| {
                dumpOperand(x.result, ts);
                std.debug.print(" := ", .{});
                dumpOperand(x.left, ts);
                std.debug.print(" >= ", .{});
                dumpOperand(x.right, ts);
            },
            .unary_minus => |x| {
                dumpOperand(x.result, ts);
                std.debug.print(" := -", .{});
                dumpOperand(x.operand, ts);
            },
            .assign => |x| {
                dumpOperand(x.target, ts);
                std.debug.print(" := ", .{});
                dumpOperand(x.value, ts);
            },
            .call => |x| {
                dumpOperand(x.result, ts);
                std.debug.print(" := call {s}(", .{x.callee});
                for (x.args, 0..) |arg, i| {
                    dumpOperand(arg, ts);
                    if (i < x.args.len - 1) std.debug.print(", ", .{});
                }
                std.debug.print(")", .{});
            },
        }
        std.debug.print("\n", .{});
    }

    fn dumpTerminator(term: Terminator, ts: *const type_store.TypeStore) void {
        std.debug.print("    ", .{});
        switch (term) {
            .@"return" => |op| {
                std.debug.print("return ", .{});
                dumpOperand(op, ts);
            },
            .exit => |op| {
                std.debug.print("exit ", .{});
                dumpOperand(op, ts);
            },
            .jump => |id| std.debug.print("jump Block {d}", .{id}),
            .cond_jump => |cj| {
                std.debug.print("if ", .{});
                dumpOperand(cj.condition, ts);
                std.debug.print(" then jump Block {d} else jump Block {d}", .{
                    cj.true_target,
                    cj.false_target,
                });
            },
        }
        std.debug.print("\n", .{});
    }

    fn dumpFunction(func: IRFunction, ts: *const type_store.TypeStore) void {
        std.debug.print("Function {s}", .{func.name});
        if (func.params.items.len > 0) {
            std.debug.print("(", .{});
            for (func.params.items, 0..) |p, i| {
                dumpOperand(p, ts);
                if (i < func.params.items.len - 1) std.debug.print(", ", .{});
            }
            std.debug.print(")", .{});
        }
        std.debug.print(":\n", .{});

        for (func.blocks.items) |block| {
            std.debug.print("  Block {d}:\n", .{block.id});
            for (block.instructions.items) |instr| {
                dumpInstr(instr, ts);
            }
            if (block.terminator) |term| {
                dumpTerminator(term, ts);
            } else {
                std.debug.print("    <no terminator>\n", .{});
            }
        }
    }
};
