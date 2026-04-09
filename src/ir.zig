const std = @import("std");
const context = @import("context.zig");
const checked_ast = @import("checked_ast.zig");

const TempId = usize;
const Opcode = enum {
    Add,
    Sub,
    Mul,
    Div,
};

const Value = union(enum) {
    Temp: TempId,
    Unit,
    Int: i64,
    Bool: bool,
    Variable: []const u8,
};

const OperandType = enum {
    Variable,
    Literal,
    Temp,
};

const Operand = struct {
    value: Value,
    type: OperandType,

    pub fn format(self: Operand, writer: *std.io.Writer) !void {
        return switch (self.type) {
            .Temp => try writer.print("t{d}", .{self.value.Temp}),
            .Literal => switch (self.value) {
                .Int => |v| try writer.print("{d}", .{v}),
                .Bool => |v| try writer.print("{s}", .{if (v) "true" else "false"}),
                else => try writer.print("unit", .{}),
            },
            .Variable => try writer.print("{s}", .{self.value.Variable}),
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
        };
    }
};

pub const IRGen = struct {
    ctx: *context.CompilerContext,
    instructions: std.ArrayList(Instr) = .empty,
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

    fn genExpr(self: *IRGen, expr: *const checked_ast.CheckedExpr) !Operand {
        switch (expr.kind) {
            .IntLiteral => |v| {
                return Operand{ .value = .{ .Int = v }, .type = .Literal };
            },
            .BoolLiteral => |v| {
                return Operand{ .value = .{ .Bool = v }, .type = .Literal };
            },
            .Identifier => |name| {
                // If this is just a variable usage (reading it), return the variable operand
                return Operand{ .value = .{ .Variable = name }, .type = .Variable };
            },
            .Binary => |bin| {
                const leftOp = try self.genExpr(bin.left);
                const rightOp = try self.genExpr(bin.right);

                const resultTempId = self.makeTemp();
                const resultOp = Operand{ .value = .{ .Temp = resultTempId }, .type = .Temp };

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
            else => return error.Unimplemented,
        }
    }

    fn makeTemp(self: *IRGen) usize {
        const id = self.tempId;
        self.tempId += 1;
        return id;
    }
};
