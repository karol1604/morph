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
    ir_gen: *const ir.IRGen,
    var_to_stack_offset: std.StringHashMap(isize),
    current_stack_offset: isize = -8,
    current_frame_size: usize = 0,
    allocations: ?std.HashMap(
        liveness.LivenessKey,
        ra.Allocation,
        liveness.LivenessKeyContext,
        std.hash_map.default_max_load_percentage,
    ) = null,

    pub fn init(
        ctx: *context.CompilerContext,
        target: targ.Target,
        ir_gen: *const ir.IRGen,
    ) CodeGen {
        return CodeGen{
            .ctx = ctx,
            .target = target,
            .ir_gen = ir_gen,
            .var_to_stack_offset = std.StringHashMap(isize).init(ctx.allocator), // it should probably be unmanaged
        };
    }

    pub fn generate(self: *CodeGen) !void {
        std.debug.print(
            "Generating code for target: {f} {f}\n",
            .{ self.target.arch, self.target.os },
        );
        try self.emitHeader();

        for (self.ir_gen.functions.items) |func| {
            const live_intervals = try liveness.analyze(&func, self.ctx.allocator);
            std.debug.print("Liveness info for function {s}:\n", .{func.name});

            var reg_alloc = try RegisterAllocator.init(live_intervals, self.ctx.allocator);

            // FIXME: does not work for more than 8 params in the arm64 calling convention,
            // but we can fix that later
            for (func.params.items, 0..) |param, idx| {
                const key = liveness.LivenessKey{ .variable = param.toString() };
                const arg_reg = ra.ARGUMENT_REGISTERS[idx];
                try reg_alloc.allocations.put(key, .{ .reg = arg_reg });

                for (reg_alloc.available_regs.items, 0..) |reg, i| {
                    if (reg.name == arg_reg.name) {
                        _ = reg_alloc.available_regs.orderedRemove(i);
                        break;
                    }
                }

                std.debug.print("******* param {d}: {s} assigned to {s}\n", .{
                    idx,
                    param.toString(),
                    ra.ARGUMENT_REGISTERS[idx].name.toString(),
                });

                for (live_intervals) |interval| {
                    if (std.meta.eql(interval.key, key)) {
                        try reg_alloc.insertSortedByEndIntoActive(interval);
                        break;
                    }
                }
            }

            const call_sites = self.findCallSites(func);

            for (live_intervals) |interval| {
                // skip params, already pre-assigned
                if (reg_alloc.allocations.contains(interval.key)) continue;

                for (call_sites) |call_pos| {
                    if (interval.start <= call_pos and call_pos <= interval.end) {
                        // find next available callee-saved register
                        for (reg_alloc.available_regs.items, 0..) |reg, i| {
                            if (reg.kind == .callee_saved) {
                                try reg_alloc.allocations.put(interval.key, .{ .reg = reg });
                                _ = reg_alloc.available_regs.orderedRemove(i);
                                try reg_alloc.insertSortedByEndIntoActive(interval);
                                std.debug.print("******* pre-assigning {f} to callee-saved register {s} because of call at position {d}\n", .{
                                    interval,
                                    reg.name.toString(),
                                    call_pos,
                                });
                                break;
                            }
                        }
                        break;
                    }
                }
            }

            try reg_alloc.allocate();
            self.allocations = reg_alloc.allocations;
            const frame_size = std.mem.alignForward(usize, reg_alloc.spill * 8 + 16, 16);
            reg_alloc.dumpLog();

            try self.emitFunction(func, frame_size);

            for (live_intervals) |info| {
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
        var call_sites: std.ArrayList(usize) = .empty;
        var pos: usize = 0;

        for (func.blocks.items) |block| {
            for (block.instructions.items) |instr| {
                switch (instr) {
                    .call => call_sites.append(self.ctx.allocator, pos) catch
                        @panic("failed to append call site"),
                    else => {},
                }
                pos += 1;
            }
        }
        return call_sites.toOwnedSlice(self.ctx.allocator) catch
            @panic("failed to create call sites slice");
    }

    fn emitFunction(self: *CodeGen, func: ir.IRFunction, frame_size: usize) !void {
        self.current_stack_offset = -8; // reset stack offset for each function
        // try self.emit("{s}:   ; param count: {d}\n", .{ func.name, func.params.items.len });
        try self.emit("{s}:\n", .{func.name});

        self.current_frame_size = frame_size;
        try self.emitPrologue(self.current_frame_size);

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

    fn emitBlock(self: *CodeGen, block: ir.BasicBlock, func_name: []const u8, is_entry: bool) !void {
        if (!is_entry) try self.emit("block_{s}_{d}:\n", .{ func_name, block.id });
        for (block.instructions.items) |instr| {
            try self.emitInstr(instr);
        }

        if (block.terminator) |term| {
            try self.emitTerminator(term, func_name);
        }
        try self.emit("\n", .{});
    }

    fn resolveRegister(self: *CodeGen, op: ir.Operand) []const u8 {
        const key: liveness.LivenessKey = switch (op.value) {
            .temp => |id| .{ .temp = id },
            .variable => |name| .{ .variable = name },
            else => std.debug.panic("unsupported operand type for register resolution {f}", .{op}),
        };
        const alloc = self.allocations.?.get(key) orelse @panic("no allocation for operand");
        return switch (alloc) {
            .reg => |reg| reg.name.toString(),
            .spil => @panic("handle spills separately"),
        };
    }

    fn materializeOperand(self: *CodeGen, operand: ir.Operand, dest_reg: []const u8) ![]const u8 {
        switch (operand.value) {
            .int, .bool => {
                try self.loadOperand(operand, dest_reg, null, .{});
                return dest_reg;
            },
            .variable, .temp => {
                switch (self.resolveOperand(operand)) {
                    .reg => |reg| return reg.name.toString(),
                    .spil => {
                        @panic("handle spills separately");
                        // try self.loadOperand(operand, dest_reg, null, .{});
                        // return dest_reg;
                    },
                }
            },
            else => @panic("unsupported operand type"),
        }
    }
    fn emitInstr(self: *CodeGen, instr: ir.Instr) !void {
        // _ = self;
        // _ = instr;
        // @panic("Instruction emission not implemented yet");

        // TODO: abstract these to functions
        switch (instr) {
            .assign => |op| {
                const dst = self.resolveRegister(op.target);
                switch (op.value.value) {
                    .int => |i| try self.emit(
                        "    mov {s}, #{d} ; {f} = {f}\n",
                        .{ dst, i, op.target, op.value },
                    ),
                    .bool => |b| try self.emit("    mov {s}, #{d} ; {f} = {f}\n", .{
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
            .add => |op| {
                const dst = self.resolveRegister(op.result);
                const left = try self.materializeOperand(op.left, dst);

                switch (op.right.value) {
                    .int => |i| try self.emit("    add {s}, {s}, #{d} ; {f} = {f} + {f}\n", .{
                        dst, left, i, op.result, op.left, op.right,
                    }),
                    .variable, .temp => {
                        // const right = self.resolveRegister(op.right);

                        // use x8 as a temporary since it's not an argument register
                        const right = try self.materializeOperand(op.right, "x8");
                        try self.emit("    add {s}, {s}, {s} ; {f} = {f} + {f}\n", .{
                            dst, left, right, op.result, op.left, op.right,
                        });
                    },
                    else => @panic("unsupported add operand"),
                }
            },
            .sub => |op| {
                const dst = self.resolveRegister(op.result);
                const left = try self.materializeOperand(op.left, dst);

                switch (op.right.value) {
                    .int => |i| try self.emit("    sub {s}, {s}, #{d} ; {f} = {f} - {f}\n", .{
                        dst, left, i, op.result, op.left, op.right,
                    }),
                    .variable, .temp => {
                        // const right = self.resolveRegister(op.right);

                        const right = try self.materializeOperand(op.right, "x8");
                        try self.emit("    sub {s}, {s}, {s} ; {f} = {f} - {f}\n", .{
                            dst, left, right, op.result, op.left, op.right,
                        });
                    },
                    else => @panic("unsupported add operand"),
                }
            },
            .mul => |op| {
                const dst = self.resolveRegister(op.result);

                const left = try self.materializeOperand(op.left, "x8");
                const right = try self.materializeOperand(op.right, "x9");

                // self.storeVariable(, src_reg: []const u8)

                try self.emit(
                    "    mul {s}, {s}, {s} ; {f} = {f} * {f}\n",
                    .{ dst, left, right, op.result, op.left, op.right },
                );

                // switch (op.right.value) {
                //     .int => |i| {
                //         // mul has no immediate form, must use a scratch register
                //         try self.emit("    mov x8, #{d}\n", .{i}); // NOTE: i think we can use x8 as a temporary since it's not an argument register
                //         try self.emit("    mul {s}, {s}, x8 ; {f} = {f} * {f}\n", .{
                //             dst, left, op.result, op.left, op.right,
                //         });
                //     },
                //     .variable, .temp => {
                //         const right = self.resolveRegister(op.right);
                //         try self.emit("    mul {s}, {s}, {s} ; {f} = {f} * {f}\n", .{
                //             dst, left, right, op.result, op.left, op.right,
                //         });
                //     },
                //     else => @panic("unsupported mul operand"),
                // }
            },
            .div => |op| {
                const dst = self.resolveRegister(op.result);

                const left = try self.materializeOperand(op.left, "x8");
                const right = try self.materializeOperand(op.right, "x9");

                try self.emit(
                    "    sdiv {s}, {s}, {s} ; {f} = {f} / {f}\n",
                    .{ dst, left, right, op.result, op.left, op.right },
                );

                // switch (op.right.value) {
                //     .int => |i| {
                //         // mul has no immediate form, must use a scratch register
                //         try self.emit("    mov x8, #{d}\n", .{i}); // NOTE: i think we can use x8 as a temporary since it's not an argument register
                //         try self.emit("    sdiv {s}, {s}, x8 ; {f} = {f} * {f}\n", .{
                //             dst, left, op.result, op.left, op.right,
                //         });
                //     },
                //     .variable, .temp => {
                //         const right = self.resolveRegister(op.right);
                //         try self.emit("    sdiv {s}, {s}, {s} ; {f} = {f} * {f}\n", .{
                //             dst, left, right, op.result, op.left, op.right,
                //         });
                //     },
                //     else => @panic("unsupported mul operand"),
                // }
            },
            .call => |op| {
                try self.emit(
                    "    ; call {s}({d} args)[{f}]\n",
                    .{ op.callee, op.args.len, op.result },
                );
                for (op.args, 0..) |arg, idx| {
                    const reg = std.fmt.allocPrint(self.ctx.allocator, "x{d}", .{idx}) catch unreachable;
                    try self.loadOperand(arg, reg, "arg {d}: {f}", .{ idx, arg });
                }
                try self.emit("    bl {s}\n", .{op.callee});
                try self.storeVariable(op.result, "x0");
            },
            .eq => |op| try self.emitCondition(op.result, op.left, op.right, "eq"),
            .neq => |op| try self.emitCondition(op.result, op.left, op.right, "ne"),
            .lt => |op| try self.emitCondition(op.result, op.left, op.right, "lt"),
            .lt_eq => |op| try self.emitCondition(op.result, op.left, op.right, "le"),
            .gt => |op| try self.emitCondition(op.result, op.left, op.right, "gt"),
            .gt_eq => |op| try self.emitCondition(op.result, op.left, op.right, "ge"),

            else => @panic("Unsupported instruction type"),
        }
    }

    fn emitCondition(
        self: *CodeGen,
        result: ir.Operand,
        left: ir.Operand,
        right: ir.Operand,
        cmp_instr: []const u8,
    ) !void {
        try self.emit("    ; {f} = {f} {s} {f}\n", .{ result, left, cmp_instr, right });
        try self.loadOperand(left, "x0", null, .{});
        try self.loadOperand(right, "x1", null, .{});
        try self.emit("    cmp x0, x1\n", .{});
        try self.emit("    cset x0, {s}\n", .{cmp_instr});
        try self.storeVariable(result, "x0");
    }

    fn resolveOperand(self: *CodeGen, operand: ir.Operand) ra.Allocation {
        const key: liveness.LivenessKey = switch (operand.value) {
            .variable => |name| liveness.LivenessKey{ .variable = name },
            .temp => |id| liveness.LivenessKey{ .temp = id },
            else => @panic("Unsupported operand type for register allocation"),
        };

        return self.allocations.?.get(key) orelse @panic("No allocation found for operand");
    }

    fn loadOperand(
        self: *CodeGen,
        operand: ir.Operand,
        dest_reg: []const u8,
        comptime comment_fmt: ?[]const u8,
        comment_args: anytype,
    ) !void {
        switch (operand.value) {
            .int => |i| {
                try self.emit("    mov {s}, #{d}", .{ dest_reg, i });
                if (comment_fmt) |fmt| try self.emit(" ; " ++ fmt, comment_args);
                try self.emit("\n", .{});
            },
            .bool => |b| {
                try self.emit("    mov {s}, #{d}", .{ dest_reg, @intFromBool(b) });
                if (comment_fmt) |fmt| try self.emit(" ; " ++ fmt, comment_args);
                try self.emit("\n", .{});
            },
            .variable, .temp => {
                // const offset = self.varToStackOffset.get(name) orelse unreachable;
                // try self.emit("    ldr {s}, [x29, #{d}] ; load {s}\n", .{ reg, offset, name });
                switch (self.resolveOperand(operand)) {
                    .reg => |reg| {
                        if (!std.mem.eql(u8, reg.name.toString(), dest_reg)) {
                            try self.emit("    mov {s}, {s}", .{ dest_reg, reg.name.toString() });
                            if (comment_fmt) |fmt| try self.emit(" ; " ++ fmt, comment_args);
                            try self.emit("\n", .{});
                        }
                    },
                    .spil => |slot| {
                        const offset = CodeGen.spillSlotOffset(slot);
                        try self.emit("    ldr {s}, [x29, #-{d}] ; load spilled value\n", .{
                            dest_reg,
                            offset,
                        });
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

    fn emitTerminator(self: *CodeGen, term: ir.Terminator, func_name: []const u8) !void {
        switch (term) {
            .exit => |op| {
                try self.emit("\n    ; exit {f}\n", .{op});
                switch (op.value) {
                    .int => |code| try self.emit("    mov x0, #{d}\n", .{code}),
                    .variable, .temp => try self.loadOperand(op, "x0", null, .{}),
                    else => @panic("unsupported exit operand"),
                }
                try self.emit("    mov x16, #1\n    svc #0x80\n", .{});
            },
            .@"return" => |op| {
                // try self.emit("    ; return {f}\n", .{op});
                try self.loadOperand(op, "x0", "return {f}", .{op});
                try self.emitEpilogue(self.current_frame_size);
                try self.emit("    ret\n", .{});
            },
            .jump => |target| try self.emit("    b block_{s}_{d}\n", .{ func_name, target }),
            .cond_jump => |cj| {
                try self.loadOperand(cj.condition, "x0", null, .{});
                try self.emit("    cmp x0, #1\n", .{});
                try self.emit("    b.eq block_{s}_{d}\n", .{ func_name, cj.true_target });
                try self.emit("    b block_{s}_{d}\n", .{ func_name, cj.false_target });
            },
            // else => @panic("Unsupported terminator type"),
        }
    }

    fn emit(self: *CodeGen, comptime fmt: []const u8, args: anytype) !void {
        try self.output.print(self.ctx.allocator, fmt, args);
        std.debug.print(fmt, args); // for debugging
    }

    fn emitPrologue(self: *CodeGen, frame_size: usize) !void {
        // try self.emit("    ; prologue\n", .{});
        try self.emit("    ; frame size: {d}\n", .{frame_size});
        try self.emit("    sub sp, sp, #{d}\n", .{frame_size});

        try self.emit("    stp x29, x30, [sp, #{d}]\n", .{frame_size - 16});

        try self.emit("    add x29, sp, #{d}\n\n", .{frame_size - 16});
    }

    fn emitEpilogue(self: *CodeGen, frame_size: usize) !void {
        try self.emit("\n    ; epilogue\n", .{});
        try self.emit("    ldp x29, x30, [sp, #{d}]\n", .{frame_size - 16});
        try self.emit("    add sp, sp, #{d}\n", .{frame_size});
    }

    fn emitHeader(self: *CodeGen) !void {
        try self.emit(".global _main\n", .{}); // NOTE: hardcoded
        try self.emit(".align 2\n\n", .{});
    }

    fn storeVariable(self: *CodeGen, result: ir.Operand, src_reg: []const u8) !void {
        // if the variable is already on the stack, reuse its slot
        // if (self.varToStackOffset.get(name)) |offset| {
        //     try self.emit("    str {s}, [x29, #{d}] ; store {s}\n", .{ srcReg, offset, name });
        //     return;
        // }
        // try self.emit("    str {s}, [x29, #{d}] ; store {s}\n", .{ srcReg, self.currentStackOffset, name });
        // try self.varToStackOffset.put(name, self.currentStackOffset);
        // self.currentStackOffset -= 8;
        switch (self.resolveOperand(result)) {
            .reg => |reg| {
                if (!std.mem.eql(u8, reg.name.toString(), src_reg)) {
                    try self.emit("    mov {s}, {s}\n", .{ reg.name.toString(), src_reg });
                }
            },
            .spil => |slot| {
                const offset = CodeGen.spillSlotOffset(slot);
                try self.emit(
                    "    str {s}, [x29, #-{d}] ; store spilled value\n",
                    .{ src_reg, offset },
                );
            },
        }
    }
};
