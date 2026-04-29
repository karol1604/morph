const std = @import("std");

const context = @import("context.zig");
const Emitter = @import("emitters/emitter.zig").Emitter;
const ir = @import("ir.zig");
const liveness = @import("liveness.zig");
const ra = @import("register_allocator.zig");
const RegisterAllocator = ra.RegisterAllocator;
const targ = @import("target.zig");

pub const CodeGen = struct {
    ctx: *context.CompilerContext,
    target: targ.Target,
    output: std.ArrayList(u8) = .empty,
    irGen: *const ir.IRGen,
    varToStackOffset: std.StringHashMap(isize),
    currentStackOffset: isize = -8,
    currentFrameSize: usize = 0,
    allocations: ?std.HashMap(
        liveness.LivenessKey,
        ra.Allocation,
        liveness.LivenessKeyContext,
        std.hash_map.default_max_load_percentage,
    ) = null,

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
            const liveIntervals = try liveness.analyze(&func, self.ctx.allocator);
            std.debug.print("Liveness info for function {s}:\n", .{func.name});

            var regAlloc = try RegisterAllocator.init(liveIntervals, self.ctx.allocator);

            // FIXME: does not work for more than 8 params in the arm64 calling convention, but we can fix that later
            for (func.params.items, 0..) |param, idx| {
                const key = liveness.LivenessKey{ .Var = param.toString() };
                const argReg = ra.ARGUMENT_REGISTERS[idx];
                try regAlloc.allocations.put(key, .{ .Reg = argReg });

                for (regAlloc.availableRegisters.items, 0..) |reg, i| {
                    if (reg.name == argReg.name) {
                        _ = regAlloc.availableRegisters.orderedRemove(i);
                        break;
                    }
                }

                std.debug.print("******* param {d}: {s} assigned to {s}\n", .{
                    idx,
                    param.toString(),
                    ra.ARGUMENT_REGISTERS[idx].name.toString(),
                });

                for (liveIntervals) |interval| {
                    if (std.meta.eql(interval.key, key)) {
                        try regAlloc.insertSortedByEndIntoActive(interval);
                        break;
                    }
                }
            }

            const callSites = self.findCallSites(func);

            for (liveIntervals) |interval| {
                // skip params, already pre-assigned
                if (regAlloc.allocations.contains(interval.key)) continue;

                for (callSites) |callPos| {
                    if (interval.start <= callPos and callPos <= interval.end) {
                        // find next available callee-saved register
                        for (regAlloc.availableRegisters.items, 0..) |reg, i| {
                            if (reg.kind == .CalleeSaved) {
                                try regAlloc.allocations.put(interval.key, .{ .Reg = reg });
                                _ = regAlloc.availableRegisters.orderedRemove(i);
                                try regAlloc.insertSortedByEndIntoActive(interval);
                                std.debug.print("******* pre-assigning {f} to callee-saved register {s} because of call at position {d}\n", .{
                                    interval,
                                    reg.name.toString(),
                                    callPos,
                                });
                                break;
                            }
                        }
                        break;
                    }
                }
            }

            try regAlloc.allocate();
            self.allocations = regAlloc.allocations;
            const frameSize = std.mem.alignForward(usize, regAlloc.spill * 8 + 16, 16);
            regAlloc.dumpLog();

            try self.emitFunction(func, frameSize);

            for (liveIntervals) |info| {
                std.debug.print("{f}\n", .{info});
            }
        }
    }

    pub fn writeToFile(self: *CodeGen, path: []const u8, io: std.Io) !void {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        // trim trailing new lines for cleaner output
        while (self.output.items.len > 0 and self.output.items[self.output.items.len - 1] == '\n') {
            self.output.items = self.output.items[0 .. self.output.items.len - 1];
        }
        try file.writeStreamingAll(io, self.output.items);
    }

    fn findCallSites(self: *CodeGen, func: ir.IRFunction) []usize {
        var callSites: std.ArrayList(usize) = .empty;
        var pos: usize = 0;

        for (func.blocks.items) |block| {
            for (block.instructions.items) |instr| {
                switch (instr) {
                    .Call => callSites.append(self.ctx.allocator, pos) catch @panic("failed to append call site"),
                    else => {},
                }
                pos += 1;
            }
        }
        return callSites.toOwnedSlice(self.ctx.allocator) catch @panic("failed to create call sites slice");
    }

    fn emitFunction(self: *CodeGen, func: ir.IRFunction, frameSize: usize) !void {
        self.currentStackOffset = -8; // reset stack offset for each function
        // try self.emit("{s}:   ; param count: {d}\n", .{ func.name, func.params.items.len });
        try self.emit("{s}:\n", .{func.name});

        self.currentFrameSize = frameSize;
        try self.emitPrologue(self.currentFrameSize);

        // FIXME: does not work for more than 8 params in the arm64 calling convention, but we can fix that later
        // for (func.params.items, 0..) |param, idx| {
        //     try self.emit("    ; param {d}: {f}\n", .{ idx, param });
        //     // try self.emit("    str x{d}, [x29, #{d}]\n\n", .{ idx, self.currentStackOffset });
        //     // try self.varToStackOffset.put(param.toString(), self.currentStackOffset);
        //     // self.currentStackOffset -= 8;
        //     const reg = std.fmt.allocPrint(self.ctx.allocator, "x{d}", .{idx}) catch unreachable;
        //     try self.storeVariable(param, reg);
        // }

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

    fn resolveRegister(self: *CodeGen, op: ir.Operand) []const u8 {
        const key: liveness.LivenessKey = switch (op.value) {
            .Temp => |id| .{ .Temp = id },
            .Variable => |name| .{ .Var = name },
            else => @panic("unsupported operand type for register resolution"),
        };
        const alloc = self.allocations.?.get(key) orelse @panic("no allocation for operand");
        return switch (alloc) {
            .Reg => |reg| reg.name.toString(),
            .Spill => @panic("handle spills separately"),
        };
    }

    fn emitInstr(self: *CodeGen, instr: ir.Instr) !void {
        // _ = self;
        // _ = instr;
        // @panic("Instruction emission not implemented yet");

        // TODO: abstract these to functions
        switch (instr) {
            .Assign => |op| {
                const dst = self.resolveRegister(op.target);
                switch (op.value.value) {
                    .Int => |i| try self.emit("    mov {s}, #{d} ; {f} = {f}\n", .{ dst, i, op.target, op.value }),
                    .Bool => |b| try self.emit("    mov {s}, #{d} ; {f} = {f}\n", .{
                        dst,
                        @intFromBool(b),
                        op.target,
                        op.value,
                    }),
                    else => {
                        const src = self.resolveRegister(op.value);
                        if (!std.mem.eql(u8, dst, src)) {
                            try self.emit("    mov {s}, {s}\n", .{ dst, src });
                        }
                    },
                }
            },
            .Add => |op| {
                const dst = self.resolveRegister(op.result);
                const left = self.resolveRegister(op.left);
                switch (op.right.value) {
                    .Int => |i| try self.emit("    add {s}, {s}, #{d} ; {f} = {f} + {f}\n", .{
                        dst, left, i, op.result, op.left, op.right,
                    }),
                    .Variable, .Temp => {
                        const right = self.resolveRegister(op.right);
                        try self.emit("    add {s}, {s}, {s} ; {f} = {f} + {f}\n", .{
                            dst, left, right, op.result, op.left, op.right,
                        });
                    },
                    else => @panic("unsupported add operand"),
                }
            },
            .Sub => |op| {
                const dst = self.resolveRegister(op.result);
                const left = self.resolveRegister(op.left);
                switch (op.right.value) {
                    .Int => |i| try self.emit("    sub {s}, {s}, #{d} ; {f} = {f} + {f}\n", .{
                        dst, left, i, op.result, op.left, op.right,
                    }),
                    .Variable, .Temp => {
                        const right = self.resolveRegister(op.right);
                        try self.emit("    sub {s}, {s}, {s} ; {f} = {f} + {f}\n", .{
                            dst, left, right, op.result, op.left, op.right,
                        });
                    },
                    else => @panic("unsupported add operand"),
                }
            },
            .Mul => |op| {
                const dst = self.resolveRegister(op.result);
                const left = self.resolveRegister(op.left);

                switch (op.right.value) {
                    .Int => |i| {
                        // mul has no immediate form, must use a scratch register
                        try self.emit("    mov x8, #{d}\n", .{i}); // NOTE: i think we can use x8 as a temporary since it's not an argument register
                        try self.emit("    mul {s}, {s}, x8 ; {f} = {f} * {f}\n", .{
                            dst, left, op.result, op.left, op.right,
                        });
                    },
                    .Variable, .Temp => {
                        const right = self.resolveRegister(op.right);
                        try self.emit("    mul {s}, {s}, {s} ; {f} = {f} * {f}\n", .{
                            dst, left, right, op.result, op.left, op.right,
                        });
                    },
                    else => @panic("unsupported mul operand"),
                }
            },
            .Div => |op| {
                const dst = self.resolveRegister(op.result);
                const left = self.resolveRegister(op.left);

                switch (op.right.value) {
                    .Int => |i| {
                        // mul has no immediate form, must use a scratch register
                        try self.emit("    mov x8, #{d}\n", .{i}); // NOTE: i think we can use x8 as a temporary since it's not an argument register
                        try self.emit("    sdiv {s}, {s}, x8 ; {f} = {f} * {f}\n", .{
                            dst, left, op.result, op.left, op.right,
                        });
                    },
                    .Variable, .Temp => {
                        const right = self.resolveRegister(op.right);
                        try self.emit("    sdiv {s}, {s}, {s} ; {f} = {f} * {f}\n", .{
                            dst, left, right, op.result, op.left, op.right,
                        });
                    },
                    else => @panic("unsupported mul operand"),
                }
            },
            .Call => |op| {
                try self.emit("    ; call {s}({d} args)[{f}]\n", .{ op.callee, op.args.len, op.result });
                for (op.args, 0..) |arg, idx| {
                    const reg = std.fmt.allocPrint(self.ctx.allocator, "x{d}", .{idx}) catch unreachable;
                    try self.loadOperand(arg, reg, "arg {d}: {f}", .{ idx, arg });
                }
                try self.emit("    bl {s}\n", .{op.callee});
                try self.storeVariable(op.result, "x0");
            },
            .Eq => |op| try self.emitCondition(op.result, op.left, op.right, "eq"),
            .Neq => |op| try self.emitCondition(op.result, op.left, op.right, "ne"),
            .Lt => |op| try self.emitCondition(op.result, op.left, op.right, "lt"),
            .LtEq => |op| try self.emitCondition(op.result, op.left, op.right, "le"),
            .Gt => |op| try self.emitCondition(op.result, op.left, op.right, "gt"),
            .GtEq => |op| try self.emitCondition(op.result, op.left, op.right, "ge"),

            else => @panic("Unsupported instruction type"),
        }
    }

    fn emitCondition(
        self: *CodeGen,
        result: ir.Operand,
        left: ir.Operand,
        right: ir.Operand,
        cmpInstr: []const u8,
    ) !void {
        try self.emit("    ; {f} = {f} {s} {f}\n", .{ result, left, cmpInstr, right });
        try self.loadOperand(left, "x0", null, .{});
        try self.loadOperand(right, "x1", null, .{});
        try self.emit("    cmp x0, x1\n", .{});
        try self.emit("    cset x0, {s}\n", .{cmpInstr});
        try self.storeVariable(result, "x0");
    }

    fn resolveOperand(self: *CodeGen, operand: ir.Operand) ra.Allocation {
        const key: liveness.LivenessKey = switch (operand.value) {
            .Variable => |name| liveness.LivenessKey{ .Var = name },
            .Temp => |id| liveness.LivenessKey{ .Temp = id },
            else => @panic("Unsupported operand type for register allocation"),
        };

        return self.allocations.?.get(key) orelse @panic("No allocation found for operand");
    }

    fn loadOperand(
        self: *CodeGen,
        operand: ir.Operand,
        destReg: []const u8,
        comptime commentFmt: ?[]const u8,
        commentArgs: anytype,
    ) !void {
        switch (operand.value) {
            .Int => |i| {
                try self.emit("    mov {s}, #{d}", .{ destReg, i });
                if (commentFmt) |fmt| try self.emit(" ; " ++ fmt, commentArgs);
                try self.emit("\n", .{});
            },
            .Bool => |b| {
                try self.emit("    mov {s}, #{d}", .{ destReg, @intFromBool(b) });
                if (commentFmt) |fmt| try self.emit(" ; " ++ fmt, commentArgs);
                try self.emit("\n", .{});
            },
            .Variable, .Temp => {
                // const offset = self.varToStackOffset.get(name) orelse unreachable;
                // try self.emit("    ldr {s}, [x29, #{d}] ; load {s}\n", .{ reg, offset, name });
                switch (self.resolveOperand(operand)) {
                    .Reg => |reg| {
                        if (!std.mem.eql(u8, reg.name.toString(), destReg)) {
                            try self.emit("    mov {s}, {s}", .{ destReg, reg.name.toString() });
                            if (commentFmt) |fmt| try self.emit(" ; " ++ fmt, commentArgs);
                            try self.emit("\n", .{});
                        }
                    },
                    .Spill => |slot| {
                        const offset = CodeGen.spillSlotOffset(slot);
                        try self.emit("    ldr {s}, [x29, #-{d}] ; load spilled value\n", .{ destReg, offset });
                    },
                }
            },
            // .Temp => |id| {
            //     const tempName = std.fmt.allocPrint(self.ctx.allocator, "t{}", .{id}) catch unreachable;
            //     const offset = self.varToStackOffset.get(tempName) orelse unreachable;
            //     try self.emit("    ldr {s}, [x29, #{d}] ; load t{d}\n", .{ reg, offset, id });
            // },
            else => @panic("Unsupported operand type"),
        }
    }
    fn spillSlotOffset(slot: usize) usize {
        return (slot + 1) * 8;
    }

    fn emitTerminator(self: *CodeGen, term: ir.Terminator, funcName: []const u8) !void {
        switch (term) {
            .Exit => |op| {
                try self.emit("\n    ; exit {f}\n", .{op});
                switch (op.value) {
                    .Int => |code| try self.emit("    mov x0, #{d}\n", .{code}),
                    .Variable, .Temp => try self.loadOperand(op, "x0", null, .{}),
                    else => @panic("unsupported exit operand"),
                }
                try self.emit("    mov x16, #1\n    svc #0x80\n", .{});
            },
            .Return => |op| {
                // try self.emit("    ; return {f}\n", .{op});
                try self.loadOperand(op, "x0", "return {f}", .{op});
                try self.emitEpilogue(self.currentFrameSize);
                try self.emit("    ret\n", .{});
            },
            .Jump => |target| try self.emit("    b block_{s}_{d}\n", .{ funcName, target }),
            .ConditionalJump => |cj| {
                try self.loadOperand(cj.condition, "x0", null, .{});
                try self.emit("    cmp x0, #1\n", .{});
                try self.emit("    b.eq block_{s}_{d}\n", .{ funcName, cj.trueTarget });
                try self.emit("    b block_{s}_{d}\n", .{ funcName, cj.falseTarget });
            },
            // else => @panic("Unsupported terminator type"),
        }
    }

    fn emit(self: *CodeGen, comptime fmt: []const u8, args: anytype) !void {
        try self.output.print(self.ctx.allocator, fmt, args);
        std.debug.print(fmt, args); // for debugging
    }

    fn emitPrologue(self: *CodeGen, frameSize: usize) !void {
        // try self.emit("    ; prologue\n", .{});
        try self.emit("    ; frame size: {d}\n", .{frameSize});
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

    fn storeVariable(self: *CodeGen, result: ir.Operand, srcReg: []const u8) !void {
        // if the variable is already on the stack, reuse its slot
        // if (self.varToStackOffset.get(name)) |offset| {
        //     try self.emit("    str {s}, [x29, #{d}] ; store {s}\n", .{ srcReg, offset, name });
        //     return;
        // }
        // try self.emit("    str {s}, [x29, #{d}] ; store {s}\n", .{ srcReg, self.currentStackOffset, name });
        // try self.varToStackOffset.put(name, self.currentStackOffset);
        // self.currentStackOffset -= 8;
        switch (self.resolveOperand(result)) {
            .Reg => |reg| {
                if (!std.mem.eql(u8, reg.name.toString(), srcReg)) {
                    try self.emit("    mov {s}, {s}\n", .{ reg.name.toString(), srcReg });
                }
            },
            .Spill => |slot| {
                const offset = CodeGen.spillSlotOffset(slot);
                try self.emit("    str {s}, [x29, #-{d}] ; store spilled value\n", .{ srcReg, offset });
            },
        }
    }
};
