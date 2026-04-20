const std = @import("std");

const context = @import("context.zig");
const Emitter = @import("emitters/emitter.zig").Emitter;
const ir = @import("ir.zig");
const targ = @import("target.zig");

pub const CodeGen = struct {
    ctx: *context.CompilerContext,
    target: targ.Target,
    output: std.ArrayList(u8) = .empty,
    irGen: *const ir.IRGen,
    varToStackOffset: std.StringHashMap(isize),
    currentStackOffset: isize = -8,
    currentFrameSize: usize = 0,

    pub fn init(ctx: *context.CompilerContext, target: targ.Target, irGen: *const ir.IRGen) CodeGen {
        return CodeGen{
            .ctx = ctx,
            .target = target,
            .irGen = irGen,
            .varToStackOffset = std.StringHashMap(isize).init(ctx.allocator), // it should probably be unmanaged
        };
    }

    pub fn generate(self: *CodeGen) !void {
        std.debug.print("Generating code for target: {f} {f}\n", .{ self.target.arch, self.target.os });
        try self.emitHeader();

        for (self.irGen.functions.items) |func| {
            try self.emitFunction(func);
        }
    }

    pub fn writeToFile(self: *CodeGen, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(self.output.items);
        for (self.output.items) |byte| {
            std.debug.print("{c}", .{byte});
        }
    }

    fn emitFunction(self: *CodeGen, func: ir.IRFunction) !void {
        self.currentStackOffset = -8; // reset stack offset for each function
        // FIXME: this is horrid, we should just replace the # with something else in the IR
        // const label = try std.mem.replaceOwned(u8, self.ctx.allocator, func.name, "#", "$");
        try self.emit("{s}:\n; param count: {d}\n", .{ func.name, func.params.items.len });

        self.currentFrameSize = CodeGen.calculateFrameSize(func);
        try self.emitPrologue(self.currentFrameSize);

        // FIXME: does not work for more than 8 params in the arm64 calling convention, but we can fix that later
        for (func.params.items, 0..) |param, idx| {
            try self.emit("    ; param {d}: {f}\n", .{ idx, param });
            // try self.emit("    str x{d}, [x29, #{d}]\n\n", .{ idx, self.currentStackOffset });
            // try self.varToStackOffset.put(param.toString(), self.currentStackOffset);
            // self.currentStackOffset -= 8;
            const reg = std.fmt.allocPrint(self.ctx.allocator, "x{d}", .{idx}) catch unreachable;
            try self.storeVariable(param.toString(), reg);
        }

        for (func.blocks.items, 0..) |block, i| {
            try self.emitBlock(block, func.name, i == 0);
        }

        // epilogue
        // FIXME: wrong spot
        // if (frameSize > 0) {
        //     try self.emit("\n    ; epilogue\n", .{});
        //     try self.emit("    ldp x29, x30, [sp, #{d}]\n", .{frameSize - 16});
        //     try self.emit("    add sp, sp, #{d}\n", .{frameSize});
        // }

        try self.emit("\n", .{});
    }

    fn emitBlock(self: *CodeGen, block: ir.BasicBlock, funcName: []const u8, isEntry: bool) !void {
        if (!isEntry) try self.emit("block_{s}_{d}:\n", .{ funcName, block.id });
        for (block.instructions.items) |instr| {
            try self.emitInstr(instr);
        }

        if (block.terminator) |term| {
            try self.emitTerminator(term, funcName);
        }
        try self.emit("\n", .{});
    }

    fn emitInstr(self: *CodeGen, instr: ir.Instr) !void {
        // _ = self;
        // _ = instr;
        // @panic("Instruction emission not implemented yet");

        // TODO: abstract these to functions
        switch (instr) {
            .Assign => |op| {
                try self.emit("    ; assign {f} = {f}\n", .{ op.target, op.value });
                switch (op.value.value) {
                    .Int => |i| try self.emit("    mov x0, #{d}\n", .{i}),
                    else => try self.loadOperand(op.value, "x0"),
                }
                // try self.emit("    str x0, [x29, #{d}]\n\n", .{self.currentStackOffset});
                // try self.varToStackOffset.put(op.target.toString(), self.currentStackOffset);
                // self.currentStackOffset -= 8;
                try self.storeVariable(op.target.toString(), "x0");
            },
            .Add => |op| {
                try self.emit("    ; add {f} = {f} + {f}\n", .{ op.result, op.left, op.right });

                try self.loadOperand(op.left, "x0");
                try self.loadOperand(op.right, "x1");

                try self.emit("    add x0, x0, x1\n", .{});

                // try self.emit("    str x0, [x29, #{d}]\n\n", .{self.currentStackOffset});
                // try self.varToStackOffset.put(op.result.toString(), self.currentStackOffset);
                // self.currentStackOffset -= 8;
                try self.storeVariable(op.result.toString(), "x0");
            },
            .Sub => |op| {
                try self.emit("    ; sub {f} = {f} - {f}\n", .{ op.result, op.left, op.right });
                try self.loadOperand(op.left, "x0");
                try self.loadOperand(op.right, "x1");

                try self.emit("    sub x0, x0, x1\n", .{});

                // try self.emit("    str x0, [x29, #{d}]\n\n", .{self.currentStackOffset});
                // try self.varToStackOffset.put(op.result.toString(), self.currentStackOffset);
                // self.currentStackOffset -= 8;
                try self.storeVariable(op.result.toString(), "x0");
            },
            .Mul => |op| {
                try self.emit("    ; mul {f} = {f} * {f}\n", .{ op.result, op.left, op.right });
                try self.loadOperand(op.left, "x0");
                try self.loadOperand(op.right, "x1");
                try self.emit("    mul x0, x0, x1\n", .{});
                // try self.emit("    str x0, [x29, #{d}]\n\n", .{self.currentStackOffset});
                // try self.varToStackOffset.put(op.result.toString(), self.currentStackOffset);
                // self.currentStackOffset -= 8;
                try self.storeVariable(op.result.toString(), "x0");
            },
            .Div => |op| {
                try self.emit("    ; div {f} = {f} / {f}\n", .{ op.result, op.left, op.right });
                try self.loadOperand(op.left, "x0");
                try self.loadOperand(op.right, "x1");
                try self.emit("    sdiv x0, x0, x1\n", .{});
                // try self.emit("    str x0, [x29, #{d}]\n\n", .{self.currentStackOffset});
                // try self.varToStackOffset.put(op.result.toString(), self.currentStackOffset);
                // self.currentStackOffset -= 8;
                try self.storeVariable(op.result.toString(), "x0");
            },
            .Call => |op| {
                try self.emit("    ; call {s}({d} args)[{f}]\n", .{ op.callee, op.args.len, op.result });
                for (op.args, 0..) |arg, idx| {
                    try self.emit("    ; arg {d}: {f}\n", .{ idx, arg });
                    const reg = std.fmt.allocPrint(self.ctx.allocator, "x{d}", .{idx}) catch unreachable;
                    try self.loadOperand(arg, reg);
                }
                try self.emit("    bl {s}\n", .{op.callee});
                // try self.emit("    str x0, [x29, #{d}]\n\n", .{self.currentStackOffset});
                // try self.varToStackOffset.put(op.result.toString(), self.currentStackOffset);
                // self.currentStackOffset -= 8;
                try self.storeVariable(op.result.toString(), "x0");
            },
            .Lt => |op| {
                try self.emit("    ; lt {f} = {f} < {f}\n", .{ op.result, op.left, op.right });
                try self.loadOperand(op.left, "x0");
                try self.loadOperand(op.right, "x1");
                try self.emit("    cmp x0, x1\n", .{});
                try self.emit("    cset x0, lt\n", .{});
                // try self.emit("    str x0, [x29, #{d}]\n\n", .{self.currentStackOffset});
                // try self.varToStackOffset.put(op.result.toString(), self.currentStackOffset);
                // self.currentStackOffset -= 8;
                try self.storeVariable(op.result.toString(), "x0");
            },
            .Eq => |op| {
                try self.emit("    ; eq {f} = {f} == {f}\n", .{ op.result, op.left, op.right });
                try self.loadOperand(op.left, "x0");
                try self.loadOperand(op.right, "x1");
                try self.emit("    cmp x0, x1\n", .{});
                try self.emit("    cset x0, eq\n", .{});
                // try self.emit("    str x0, [x29, #{d}]\n\n", .{self.currentStackOffset});
                // try self.varToStackOffset.put(op.result.toString(), self.currentStackOffset);
                // self.currentStackOffset -= 8;
                try self.storeVariable(op.result.toString(), "x0");
            },

            else => @panic("Unsupported instruction type"),
        }
    }

    fn loadOperand(self: *CodeGen, operand: ir.Operand, reg: []const u8) !void {
        switch (operand.value) {
            .Int => |i| try self.emit("    mov {s}, #{d}\n", .{ reg, i }),
            .Variable => |name| {
                const offset = self.varToStackOffset.get(name) orelse unreachable;
                try self.emit("    ldr {s}, [x29, #{d}] ; load {s}\n", .{ reg, offset, name });
            },
            .Temp => |id| {
                const tempName = std.fmt.allocPrint(self.ctx.allocator, "t{}", .{id}) catch unreachable;
                const offset = self.varToStackOffset.get(tempName) orelse unreachable;
                try self.emit("    ldr {s}, [x29, #{d}] ; load t{d}\n", .{ reg, offset, id });
            },
            else => @panic("Unsupported operand type"),
        }
    }

    fn emitTerminator(self: *CodeGen, term: ir.Terminator, funcName: []const u8) !void {
        switch (term) {
            .Exit => |op| {
                try self.emit("    ; exit {f}\n", .{op});
                switch (op.value) {
                    .Int => |code| try self.emit("    mov x0, #{d}\n", .{code}),
                    .Variable, .Temp => try self.loadOperand(op, "x0"),
                    else => @panic("unsupported exit operand"),
                }
                try self.emit("    mov x16, #1\n    svc #0x80\n", .{});
            },
            .Return => |op| {
                try self.emit("    ; return {f}\n", .{op});
                try self.loadOperand(op, "x0");
                try self.emitEpilogue(self.currentFrameSize);
                try self.emit("    ret\n", .{});
            },
            .Jump => |target| try self.emit("    b block_{s}_{d}\n", .{ funcName, target }),
            .ConditionalJump => |cj| {
                try self.loadOperand(cj.condition, "x0");
                try self.emit("    cmp x0, #1\n", .{});
                try self.emit("    b.eq block_{s}_{d}\n", .{ funcName, cj.trueTarget });
                try self.emit("    b block_{s}_{d}\n", .{ funcName, cj.falseTarget });
            },
            // else => @panic("Unsupported terminator type"),
        }
    }

    fn emit(self: *CodeGen, comptime fmt: []const u8, args: anytype) !void {
        try self.output.writer(self.ctx.allocator).print(fmt, args);
        std.debug.print(fmt, args); // for debugging
    }

    fn emitPrologue(self: *CodeGen, frameSize: usize) !void {
        try self.emit("    ; prologue\n", .{});
        try self.emit("    ; frame size: {}\n", .{frameSize});
        try self.emit("    sub sp, sp, #{d}\n", .{frameSize});

        try self.emit("    stp x29, x30, [sp, #{d}]\n", .{frameSize - 16});

        try self.emit("    add x29, sp, #{d}\n\n", .{frameSize - 16});
    }

    fn emitEpilogue(self: *CodeGen, frameSize: usize) !void {
        try self.emit("\n    ; epilogue\n", .{});
        try self.emit("    ldp x29, x30, [sp, #{d}]\n", .{frameSize - 16});
        try self.emit("    add sp, sp, #{d}\n", .{frameSize});
    }

    fn emitHeader(self: *CodeGen) !void {
        try self.emit(".global _main\n", .{}); // NOTE: hardcoded
        try self.emit(".align 2\n\n", .{});
    }

    fn calculateFrameSize(func: ir.IRFunction) usize {
        var count: usize = func.params.items.len;
        for (func.blocks.items) |block| {
            for (block.instructions.items) |instr| {
                switch (instr) {
                    // TODO: dont forget about the rest
                    .Assign, .Add, .Sub, .Mul, .Div, .Call => count += 1,
                    else => {},
                }
            }
        }
        const bytes = count * 8;
        return std.mem.alignForward(usize, bytes + 16, 16); // NOTE: we need the +16 for x29 x30
    }

    fn storeVariable(self: *CodeGen, name: []const u8, reg: []const u8) !void {
        // if the variable is already on the stack, reuse its slot
        if (self.varToStackOffset.get(name)) |offset| {
            try self.emit("    str {s}, [x29, #{d}] ; store {s}\n", .{ reg, offset, name });
            return;
        }
        try self.emit("    str {s}, [x29, #{d}] ; store {s}\n", .{ reg, self.currentStackOffset, name });
        try self.varToStackOffset.put(name, self.currentStackOffset);
        self.currentStackOffset -= 8;
    }
};
