const std = @import("std");
const context = @import("context.zig");
const checked_ast = @import("checked_ast.zig");

const TempId = usize;

const Value = union(enum) {
    Temp: TempId,
    Unit,
    Int: i64,
    Bool: bool,
    Variable: []const u8,
};

const OperandType = union(enum) {
    Unit,
    Int,
    Bool,
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
        };
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
    Assign: struct {
        target: Operand,
        value: Operand,
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
            .Assign => |a| try writer.print(
                "{f} := {f}\n",
                .{ a.target, a.value },
            ),
        };
    }
};

const Variable = struct {
    name: []const u8,
    type: OperandType,
};

pub const IRGen = struct {
    ctx: *context.CompilerContext,
    instructions: std.ArrayList(Instr) = .empty,
    variables: std.ArrayList(Variable) = .empty,
    tempId: usize = 0,

    pub fn init(ctx: *context.CompilerContext) IRGen {
        return IRGen{
            .ctx = ctx,
        };
    }

    pub fn generate(self: *IRGen, exprs: []const *checked_ast.CheckedExpr) ![]Instr {
        for (exprs) |expr| {
            _ = try self.genExpr(expr);
        }
        return self.instructions.toOwnedSlice(self.ctx.allocator);
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
            .Binary => |bin| {
                const leftOp = try self.genExpr(bin.left);
                const rightOp = try self.genExpr(bin.right);

                const resultTempId = self.makeTemp();
                const resultOp = Operand{ .value = .{ .Temp = resultTempId }, .type = .Int };

                var instr: Instr = undefined;
                switch (bin.operator) {
                    .Plus => {
                        instr = Instr{ .Add = .{
                            .result = resultOp,
                            .left = leftOp,
                            .right = rightOp,
                        } };
                    },
                    .Minus => {
                        instr = Instr{ .Sub = .{
                            .result = resultOp,
                            .left = leftOp,
                            .right = rightOp,
                        } };
                    },
                    .Divide => {
                        instr = Instr{ .Div = .{
                            .result = resultOp,
                            .left = leftOp,
                            .right = rightOp,
                        } };
                    },
                    .Multiply => {
                        instr = Instr{ .Mul = .{
                            .result = resultOp,
                            .left = leftOp,
                            .right = rightOp,
                        } };
                    },
                    else => return error.IRUnimplementedOperator,
                }

                try self.instructions.append(self.ctx.allocator, instr);
                return resultOp;
            },
            .Block => |block| {
                std.debug.print("Entering block\n", .{});

                var lastOp: ?Operand = null;
                for (block.stmts) |stmt| {
                    lastOp = try self.genExpr(stmt);
                }

                if (block.tail) |tailExpr| {
                    return try self.genExpr(tailExpr);
                }
                std.debug.print("Empty block, returning unit\n", .{});
                return Operand{ .value = .Unit, .type = .Unit };
            },
            .VariableDecl => |decl| { // TODO: finish
                const val = try self.genExpr(decl.value);
                const name = try std.fmt.allocPrint(self.ctx.allocator, "{s}#{d}", .{ decl.name, decl.id });

                try self.instructions.append(self.ctx.allocator, Instr{ .Assign = .{
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
            else => return error.Unimplemented,
        }
    }

    fn makeTemp(self: *IRGen) usize {
        const id = self.tempId;
        self.tempId += 1;
        return id;
    }
};
