const std = @import("std");
const context = @import("context.zig");
const checked_ast = @import("checked_ast.zig");
const type_store = @import("type_store.zig");

const TempId = usize;

const Value = union(enum) {
    Temp: TempId,
    Unit,
    Int: i64,
    Bool: bool,
    Variable: []const u8,
    Function: []const u8,
};

const OperandType = union(enum) {
    Unit,
    Int,
    Bool,
    Function: struct {
        returnType: *const OperandType,
    },
};

const Operand = struct {
    value: Value,
    type: OperandType,

    pub fn format(self: Operand, writer: *std.io.Writer) !void {
        return switch (self.value) {
            .Temp => |id| try writer.print("t{d}", .{id}),
            .Unit => try writer.print("()", .{}),
            .Int => |i| try writer.print("{d}", .{i}),
            .Bool => |b| try writer.print("{s}", .{if (b) "true" else "false"}),
            .Variable => |name| try writer.print("{s}", .{name}),
            .Function => |name| try writer.print("{s}", .{name}),
        };
    }
};

const Terminator = union(enum) {
    Return: Operand,
    Exit: Operand,
    Jump: usize, // target block id
    ConditionalJump: struct {
        condition: Operand,
        trueTarget: usize,
        falseTarget: usize,
    },

    pub fn format(self: Terminator, writer: *std.io.Writer) !void {
        return switch (self) {
            .Return => |value| try writer.print("return {f}", .{value}),
            .Exit => |code| try writer.print("exit {f}", .{code}),
            .Jump => |target| try writer.print("jump Block {d}", .{target}),
            .ConditionalJump => |cj| try writer.print(
                "if {f} then jump Block {d} else jump Block {d}",
                .{ cj.condition, cj.trueTarget, cj.falseTarget },
            ),
        };
    }
};

const BasicBlock = struct {
    id: usize,
    instructions: std.ArrayList(Instr) = .empty,
    terminator: ?Terminator = null,

    pub fn format(self: BasicBlock, writer: *std.io.Writer) !void {
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

const IRFunction = struct {
    name: []const u8,
    // id: usize,
    parameters: std.ArrayList(Operand) = .empty,
    blocks: std.ArrayList(BasicBlock) = .empty,
    entryBlockId: usize,

    pub fn format(self: IRFunction, writer: *std.io.Writer) !void {
        try writer.print("Function {s}:\n", .{self.name});
        for (self.blocks.items) |block| {
            try writer.print("    {f}\n", .{block});
        }
    }
};

const Instr = union(enum) {
    Add: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    Sub: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    Mul: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    Div: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    UnaryMinus: struct {
        result: Operand,
        operand: Operand,
    },
    Eq: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    Neq: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    Lt: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    LtEq: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    Gt: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    GtEq: struct {
        result: Operand,
        left: Operand,
        right: Operand,
    },
    Assign: struct {
        target: Operand,
        value: Operand,
    },
    Call: struct {
        result: Operand,
        callee: []const u8,
        args: []Operand,
    },

    pub fn format(self: Instr, writer: *std.io.Writer) !void {
        return switch (self) {
            .Add => |a| try writer.print(
                "{f} := {f} + {f}\n",
                .{ a.result, a.left, a.right },
            ),
            .Sub => |s| try writer.print(
                "{f} := {f} - {f}\n",
                .{ s.result, s.left, s.right },
            ),
            .Mul => |m| try writer.print(
                "{f} := {f} * {f}\n",
                .{ m.result, m.left, m.right },
            ),
            .Div => |d| try writer.print(
                "{f} := {f} / {f}\n",
                .{ d.result, d.left, d.right },
            ),
            .UnaryMinus => |u| try writer.print(
                "{f} := -{f}\n",
                .{ u.result, u.operand },
            ),
            .Assign => |a| try writer.print(
                "{f} := {f}\n",
                .{ a.target, a.value },
            ),
            .Eq => |e| try writer.print(
                "{f} := {f} == {f}\n",
                .{ e.result, e.left, e.right },
            ),
            .Neq => |n| try writer.print(
                "{f} := {f} != {f}\n",
                .{ n.result, n.left, n.right },
            ),
            .Lt => |l| try writer.print(
                "{f} := {f} < {f}\n",
                .{ l.result, l.left, l.right },
            ),
            .LtEq => |le| try writer.print(
                "{f} := {f} <= {f}\n",
                .{ le.result, le.left, le.right },
            ),
            .Gt => |g| try writer.print(
                "{f} := {f} > {f}\n",
                .{ g.result, g.left, g.right },
            ),
            .GtEq => |ge| try writer.print(
                "{f} := {f} >= {f}\n",
                .{ ge.result, ge.left, ge.right },
            ),
            .Call => |c| {
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
    type: OperandType,
};

pub const IRGen = struct {
    ctx: *context.CompilerContext,
    // instructions: std.ArrayList(Instr) = .empty,
    variables: std.ArrayList(Variable) = .empty,
    tempId: usize = 0,

    functions: std.ArrayList(IRFunction) = .empty,
    currentFuncIdx: ?usize = null,
    currentBlockIdx: ?usize = null,
    nextBlockId: usize = 0,

    pub fn init(ctx: *context.CompilerContext) IRGen {
        return IRGen{
            .ctx = ctx,
        };
    }

    pub fn generate(self: *IRGen, exprs: []const *checked_ast.CheckedExpr) !void {
        try self.createFunction("main", null);
        const exitCode = if (exprs.len > 0) blk: {
            for (exprs[0 .. exprs.len - 1]) |expr| {
                _ = try self.genExpr(expr);
            }
            const last = try self.genExpr(exprs[exprs.len - 1]);
            if (last.type == .Int) break :blk last;
            break :blk Operand{ .value = .{ .Int = 0 }, .type = .Int };
        } else Operand{ .value = .{ .Int = 0 }, .type = .Int };

        self.setTerminator(.{ .Exit = exitCode });

        // const f_idx = self.currentFuncIdx.?;
        // const b_idx = self.currentBlockIdx.?;
        // if (self.functions.items[f_idx].blocks.items[b_idx].terminator == null) {
        //     self.functions.items[f_idx].blocks.items[b_idx].terminator = .{ .Return = null };
        // }

        // return self.instructions.toOwnedSlice(self.ctx.allocator);
    }

    pub fn dump(self: *const IRGen) void {
        std.debug.print("=== IR DUMP ===\n", .{});

        for (self.functions.items) |func| {
            std.debug.print("{f}", .{func});
        }
    }

    fn createFunction(self: *IRGen, name: []const u8, id: ?usize) !void {
        var funcName: []const u8 = name;
        if (id) |i| {
            funcName = try std.fmt.allocPrint(self.ctx.allocator, "{s}#{d}", .{ name, i });
        }
        // const id = self.nextFuncId;
        // self.nextFuncId += 1;

        const func = IRFunction{
            .name = funcName,
            // .id = id,
            .entryBlockId = self.nextBlockId,
        };
        try self.functions.append(self.ctx.allocator, func);
        self.currentFuncIdx = self.functions.items.len - 1;
        const entryId = try self.createBlock(); // create entry block
        try self.switchToBlock(entryId);
    }

    fn emit(self: *IRGen, instr: Instr) !void {
        const f_idx = self.currentFuncIdx.?;
        const b_idx = self.currentBlockIdx.?;

        try self.functions.items[f_idx].blocks.items[b_idx].instructions.append(self.ctx.allocator, instr);
    }

    fn createBlock(self: *IRGen) !usize {
        const id = self.nextBlockId;
        self.nextBlockId += 1;

        const block = BasicBlock.init(id);
        const f_idx = self.currentFuncIdx orelse return error.NoCurrentFunction;
        try self.functions.items[f_idx].blocks.append(self.ctx.allocator, block);

        return id;
    }

    fn switchToBlock(self: *IRGen, id: usize) !void {
        const f_idx = self.currentFuncIdx orelse return error.NoCurrentFunction;
        for (self.functions.items[f_idx].blocks.items, 0..) |block, idx| {
            if (block.id == id) {
                self.currentBlockIdx = idx;
                return;
            }
        }
        return error.BlockNotFound;
    }

    fn setTerminator(self: *IRGen, terminator: Terminator) void {
        const f_idx = self.currentFuncIdx.?;
        const b_idx = self.currentBlockIdx.?;
        self.functions.items[f_idx].blocks.items[b_idx].terminator = terminator;
    }

    fn addVariable(self: *IRGen, name: []const u8, id: usize, ty: OperandType) !void {
        const n = try std.fmt.allocPrint(self.ctx.allocator, "{s}#{d}", .{ name, id });
        try self.variables.append(self.ctx.allocator, Variable{
            .name = n,
            .type = ty,
        });
    }

    fn lookupVariable(self: *IRGen, name: []const u8, id: usize) ?Variable {
        const fullName = std.fmt.allocPrint(self.ctx.allocator, "{s}#{d}", .{ name, id }) catch return null;
        for (self.variables.items) |v| {
            if (std.mem.eql(u8, v.name, fullName)) {
                return v;
            }
        }
        return null;
    }

    fn genExpr(self: *IRGen, expr: *const checked_ast.CheckedExpr) !Operand {
        switch (expr.kind) {
            .IntLiteral => |v| {
                return Operand{ .value = .{ .Int = v }, .type = .Int };
            },
            .BoolLiteral => |v| {
                return Operand{ .value = .{ .Bool = v }, .type = .Bool };
            },
            .Identifier => |ident| {
                const v = self.lookupVariable(ident.name, ident.id) orelse return error.UndefinedVariable;
                return Operand{
                    .value = .{ .Variable = v.name },
                    .type = v.type,
                };
            },
            .Unary => |un| {
                const rightOp = try self.genExpr(un.right);

                const resultTempId = self.nextId();
                const resultOp = Operand{ .value = .{ .Temp = resultTempId }, .type = rightOp.type };

                var instr: Instr = undefined;
                switch (un.operator) {
                    .Minus => {
                        instr = Instr{ .UnaryMinus = .{
                            .result = resultOp,
                            .operand = rightOp,
                        } };
                    },
                    else => return error.IRUnimplementedOperator,
                }

                // try self.instructions.append(self.ctx.allocator, instr);
                try self.emit(instr);
                return resultOp;
            },
            .Binary => |bin| {
                const leftOp = try self.genExpr(bin.left);
                const rightOp = try self.genExpr(bin.right);

                const resultTempId = self.nextId();
                var resultOp: Operand = undefined;
                var instr: Instr = undefined;

                switch (bin.operator) {
                    .Plus, .Minus, .Multiply, .Divide => {
                        resultOp = Operand{ .value = .{ .Temp = resultTempId }, .type = .Int };

                        if (bin.operator == .Plus) instr = Instr{ .Add = .{
                            .result = resultOp,
                            .left = leftOp,
                            .right = rightOp,
                        } };
                        if (bin.operator == .Minus) instr = Instr{ .Sub = .{
                            .result = resultOp,
                            .left = leftOp,
                            .right = rightOp,
                        } };
                        if (bin.operator == .Multiply) instr = Instr{ .Mul = .{
                            .result = resultOp,
                            .left = leftOp,
                            .right = rightOp,
                        } };
                        if (bin.operator == .Divide) instr = Instr{ .Div = .{
                            .result = resultOp,
                            .left = leftOp,
                            .right = rightOp,
                        } };
                    },

                    .Equal, .NotEqual, .LessThan, .GreaterThan, .LessThanOrEqual, .GreaterThanOrEqual => {
                        resultOp = Operand{ .value = .{ .Temp = resultTempId }, .type = .Bool };

                        if (bin.operator == .Equal) instr = Instr{
                            .Eq = .{
                                .result = resultOp,
                                .left = leftOp,
                                .right = rightOp,
                            },
                        };
                        if (bin.operator == .NotEqual) instr = Instr{
                            .Neq = .{
                                .result = resultOp,
                                .left = leftOp,
                                .right = rightOp,
                            },
                        };
                        if (bin.operator == .LessThan) instr = Instr{
                            .Lt = .{
                                .result = resultOp,
                                .left = leftOp,
                                .right = rightOp,
                            },
                        };
                        if (bin.operator == .GreaterThan) instr = Instr{
                            .Gt = .{
                                .result = resultOp,
                                .left = leftOp,
                                .right = rightOp,
                            },
                        };
                        if (bin.operator == .LessThanOrEqual) instr = Instr{
                            .LtEq = .{
                                .result = resultOp,
                                .left = leftOp,
                                .right = rightOp,
                            },
                        };
                        if (bin.operator == .GreaterThanOrEqual) instr = Instr{
                            .GtEq = .{
                                .result = resultOp,
                                .left = leftOp,
                                .right = rightOp,
                            },
                        };
                    },
                    else => return error.IRUnimplementedOperator,
                }

                // try self.instructions.append(self.ctx.allocator, instr);
                try self.emit(instr);
                return resultOp;
            },
            .Block => |block| {
                var lastOp: ?Operand = null;
                for (block.stmts) |stmt| {
                    lastOp = try self.genExpr(stmt);
                }

                if (block.tail) |tailExpr| {
                    return try self.genExpr(tailExpr);
                }
                return Operand{ .value = .Unit, .type = .Unit };
            },
            .VariableDecl => |decl| { // TODO: finish
                const val = try self.genExpr(decl.value);
                const name = try std.fmt.allocPrint(self.ctx.allocator, "{s}#{d}", .{ decl.name, decl.id });

                // try self.instructions.append(self.ctx.allocator, Instr{ .Assign = .{
                //     .target = Operand{
                //         .value = .{ .Variable = name },
                //         .type = val.type,
                //     },
                //     .value = val,
                // } });

                try self.emit(Instr{ .Assign = .{
                    .target = Operand{
                        .value = .{ .Variable = name },
                        .type = val.type,
                    },
                    .value = val,
                } });

                try self.addVariable(decl.name, decl.id, val.type);

                return Operand{
                    .value = .Unit,
                    .type = .Unit,
                };
            },
            .FunctionDecl => |func| {
                const prevFuncIdx = self.currentFuncIdx;
                const prevBlockIdx = self.currentBlockIdx;

                try self.createFunction(func.name, func.id);

                for (func.params) |param| {
                    const paramOp = Operand{
                        .value = .{ .Variable = try std.fmt.allocPrint(self.ctx.allocator, "{s}#{d}", .{
                            param.name,
                            param.id,
                        }) },
                        .type = .Int, // TODO: actually use parameter type
                    };
                    try self.functions.items[self.currentFuncIdx.?].parameters.append(self.ctx.allocator, paramOp);
                    try self.addVariable(param.name, param.id, paramOp.type);
                }
                const bodyOp = try self.genExpr(func.body);
                self.setTerminator(.{ .Return = bodyOp });

                // try self.emit(Instr{ .Ret = .{ .value = bodyOp } });

                self.currentFuncIdx = prevFuncIdx;
                self.currentBlockIdx = prevBlockIdx;

                const fullName = try std.fmt.allocPrint(self.ctx.allocator, "{s}#{d}", .{ func.name, func.id });
                return Operand{
                    .value = .{ .Function = fullName },
                    .type = .{ .Function = .{ .returnType = &bodyOp.type } }, //BUG: dangling pointer, need to figure out how to handle function types properly
                };
            },
            .FunctionTypeSignature => return Operand{ .value = .Unit, .type = .Unit }, // NOTE: noop
            .FunctionCall => |call| {
                var argOps: std.ArrayList(Operand) = .empty;
                for (call.args) |arg| {
                    const argOp = try self.genExpr(arg);
                    try argOps.append(self.ctx.allocator, argOp);
                }

                const resultTempId = self.nextId();
                const t = self.operandTypeFromTypeId(expr.typeId);
                const resultOp = Operand{ .value = .{ .Temp = resultTempId }, .type = t };

                const fullname = try std.fmt.allocPrint(self.ctx.allocator, "{s}#{d}", .{ call.callee, call.id });
                try self.emit(Instr{ .Call = .{
                    .result = resultOp,
                    .callee = fullname,
                    .args = try argOps.toOwnedSlice(self.ctx.allocator),
                } });

                return resultOp;
            },
            // else => return error.Unimplemented,
        }
    }

    // FIXME: we need to handle the more complex types from the type store.
    fn operandTypeFromTypeId(_: *const IRGen, typeId: type_store.TypeId) OperandType {
        return switch (typeId) {
            1 => .Int, // INT_TYPE_ID
            2 => .Bool, // BOOL_TYPE_ID
            else => .Unit,
        };
    }

    fn nextId(self: *IRGen) usize {
        const id = self.tempId;
        self.tempId += 1;
        return id;
    }
};
