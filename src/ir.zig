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

const Instruction = struct {
    opcode: Opcode,
    result: Operand,
    left: Operand,
    right: Operand,

    pub fn format(self: Instruction, writer: *std.io.Writer) !void {
        return switch (self.opcode) {
            .Add => try writer.print(
                "{f} = {f} + {f}\n",
                .{ self.result, self.left, self.right },
            ),
            .Sub => try writer.print(
                "{f} = {f} - {f}\n",
                .{ self.result, self.left, self.right },
            ),
            .Mul => try writer.print(
                "{f} = {f} * {f}\n",
                .{ self.result, self.left, self.right },
            ),
            .Div => try writer.print(
                "{f} = {f} / {f}\n",
                .{ self.result, self.left, self.right },
            ),
        };
    }
};

pub const IRGen = struct {
    ctx: *context.CompilerContext,
    instructions: std.ArrayList(Instruction),
    tempId: usize = 0,

    pub fn init(ctx: *context.CompilerContext) IRGen {
        return IRGen{
            .ctx = ctx,
            .instructions = .empty,
        };
    }

    pub fn generate(self: *IRGen, exprs: []const *checked_ast.CheckedExpr) ![]Instruction {
        for (exprs) |expr| {
            // We discard the result operand here because these are top-level expressions
            // (like "x = 1 + 2;" or just "1 + 2;" acting as a statement)
            _ = try self.genExpr(expr);
        }
        return self.instructions.toOwnedSlice(self.ctx.allocator);
    }

    fn genExpr(self: *IRGen, expr: *const checked_ast.CheckedExpr) !Operand {
        switch (expr.kind) {
            .IntLiteral => |v| {
                return Operand{ .value = .{ .Int = v }, .type = .Literal };
            },
            .Identifier => |name| {
                // If this is just a variable usage (reading it), return the variable operand
                return Operand{ .value = .{ .Variable = name }, .type = .Variable };
            },
            .Binary => |bin| {
                // 1. RECURSE LEFT
                // This will emit all instructions needed to calculate the left side
                // and return the storage location (Temp or Literal) of the result.
                const leftOp = try self.genExpr(bin.left);

                // 2. RECURSE RIGHT
                const rightOp = try self.genExpr(bin.right);

                // 3. PREPARE DESTINATION
                const resultTempId = self.makeTemp();
                const resultOp = Operand{ .value = .{ .Temp = resultTempId }, .type = .Temp };

                // 4. EMIT INSTRUCTION
                const opcode = switch (bin.operator) {
                    .Plus => Opcode.Add,
                    .Minus => Opcode.Sub,
                    .Multiply => Opcode.Mul,
                    .Divide => Opcode.Div,
                    else => return error.UnimplementedOp,
                };

                const instr = Instruction{
                    .opcode = opcode,
                    .left = leftOp,
                    .right = rightOp,
                    .result = resultOp,
                };

                // Append to the persistent list
                try self.instructions.append(self.ctx.allocator, instr);

                // 5. RETURN RESULT OPERAND
                // We return the temp so the parent expression knows where to find the answer
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
