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
    scratch: ra.ScratchPool = ra.ScratchPool.init(),

    current_callee_saved: []const ra.Register = &.{},
    current_frame_size: usize = 0,
    allocations: ?std.HashMap(
        liveness.LivenessKey,
        ra.PhysicalLocation,
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
        };
    }

    pub fn generate(self: *CodeGen) !void {
        std.debug.print(
            "Generating code for target: {f} {f}\n",
            .{ self.target.arch, self.target.os },
        );
        try self.emitHeader();

        for (self.ir_gen.functions.items) |func| {
            try self.generateFunction(func);
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

    fn findInterval(
        intervals: []const liveness.LiveInterval,
        key: liveness.LivenessKey,
    ) ?liveness.LiveInterval {
        const ctx = liveness.LivenessKeyContext{};

        for (intervals) |interval| {
            if (ctx.eql(interval.key, key)) return interval;
        }

        return null;
    }

    fn generateFunction(self: *CodeGen, func: ir.IRFunction) !void {
        const live_intervals = try liveness.analyze(&func, self.ctx.allocator);
        std.debug.print("Liveness info for function {s}:\n", .{func.name});

        var reg_alloc = try RegisterAllocator.init(live_intervals, self.ctx.allocator);

        const call_sites = self.findCallSites(func);

        // pre-allocate parameter registers
        for (func.params.items, 0..) |param, idx| {
            if (idx >= ra.ARGUMENT_REGISTERS.len) {
                @panic("more than 8 params not yet supported");
            }

            const key = liveness.LivenessKey{ .variable = param.toString() };

            if (findInterval(live_intervals, key)) |interval| {
                if (intervalSpansCallSite(interval, call_sites)) {
                    // if a parameter is live across a call site, we need to ensure it gets a callee-saved register,
                    // otherwise it might get overwritten by the callee
                    try reg_alloc.hintCalleeSaved(key);
                } else {
                    // otherwise, we can pre-allocate it to the argument register
                    try reg_alloc.preAllocate(key, ra.ARGUMENT_REGISTERS[idx]);
                }
            }
        }

        for (live_intervals) |interval| {
            if (reg_alloc.allocations.contains(interval.key)) continue;
            if (intervalSpansCallSite(interval, call_sites)) {
                try reg_alloc.hintCalleeSaved(interval.key);
            }
        }

        try reg_alloc.allocate();
        reg_alloc.dumpLog();

        // const frame_size = std.mem.alignForward(usize, reg_alloc.spill_count * 8 + 16, 16);

        const callee_saved = try reg_alloc.collectCalleeSaved(self.ctx.allocator);
        self.current_callee_saved = callee_saved;

        const callee_save_bytes = callee_saved.len * 8;

        // NOTE: this is hacky
        if (callee_saved.len > 0) {
            var it = reg_alloc.allocations.valueIterator();
            while (it.next()) |loc| {
                switch (loc.*) {
                    .stack => |*offset| offset.* -= @as(isize, @intCast(callee_save_bytes)),
                    .reg => {},
                }
            }
        }

        const frame_size = std.mem.alignForward(
            usize,
            reg_alloc.spill_count * 8 + callee_save_bytes + 16,
            16,
        );

        self.allocations = reg_alloc.allocations;
        self.current_frame_size = frame_size;
        self.scratch = ra.ScratchPool.init();

        try self.emitFunction(func, frame_size);

        for (live_intervals) |info| {
            std.debug.print("{f}\n", .{info});
        }
    }

    fn findCallSites(self: *CodeGen, func: ir.IRFunction) []usize {
        var call_sites: std.ArrayList(usize) = .empty;
        var pos: usize = 0;

        for (func.blocks.items) |block| {
            for (block.instructions.items) |instr| {
                switch (instr) {
                    .call, .tail_call => call_sites.append(self.ctx.allocator, pos) catch
                        @panic("failed to append call site"),
                    else => {},
                }
                pos += 1;
            }
            pos += 1; // for the terminator
        }
        return call_sites.toOwnedSlice(self.ctx.allocator) catch
            @panic("failed to create call sites slice");
    }

    fn intervalSpansCallSite(interval: liveness.LiveInterval, call_sites: []const usize) bool {
        for (call_sites) |pos| {
            if (interval.start < pos and pos < interval.end) return true;
        }
        return false;
    }

    /// Emit code to move parameters from their argument registers to their allocated homes (register or stack).
    fn emitParamHomes(self: *CodeGen, func: ir.IRFunction) !void {
        for (func.params.items, 0..) |param, idx| {
            if (idx >= ra.ARGUMENT_REGISTERS.len) {
                @panic("more than 8 params not yet supported");
            }

            const src = ra.ARGUMENT_REGISTERS[idx].name;

            const key: liveness.LivenessKey = switch (param.value) {
                .variable => |name| .{ .variable = name },
                .temp => |id| .{ .temp = id },
                else => continue,
            };

            const loc = self.allocations.?.get(key) orelse continue;

            switch (loc) {
                .reg => |reg| {
                    if (reg.name != src) {
                        try self.emit("    mov {s}, {s} ; param {f}\n", .{
                            reg.name.toString(),
                            src.toString(),
                            param,
                        });
                    }
                },
                .stack => |offset| {
                    try self.emit("    str {s}, [x29, #{d}] ; param {f}\n", .{
                        src.toString(),
                        offset,
                        param,
                    });
                },
            }
        }

        if (func.params.items.len > 0) {
            try self.emit("\n", .{});
        }
    }

    fn emitFunction(self: *CodeGen, func: ir.IRFunction, frame_size: usize) !void {
        // try self.emit("{s}:   ; param count: {d}\n", .{ func.name, func.params.items.len });
        try self.emit("{s}:\n", .{func.name});

        self.current_frame_size = frame_size;
        try self.emitPrologue(self.current_frame_size, self.current_callee_saved);

        // we do this before emitting the entry block to ensure parameters are in their homes
        // before any instructions use them
        // this is to prevent params that live across call sites from being clobbered by the callee
        // for example if param `x` lives across a `foo(x)` recursive function call,
        // it enters the function in x0, but if we don't move it to its home (e.g. x19) before the call,
        // the recursive call will overwrite x0 and clobber `x`'s value
        try self.emitParamHomes(func);

        for (func.blocks.items, 0..) |block, i| {
            try self.emitBlock(block, func.name, i == 0);
        }
        try self.emit("\n", .{});
    }

    fn emitBlock(
        self: *CodeGen,
        block: ir.BasicBlock,
        func_name: []const u8,
        is_entry: bool,
    ) !void {
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
            .stack => @panic("handle spills separately"),
        };
    }

    fn materialize(self: *CodeGen, operand: ir.Operand, dest_reg: ra.RegisterName) !ra.RegisterName {
        switch (operand.value) {
            .int => |i| {
                try self.emit("    mov {s}, #{d}\n", .{ dest_reg.toString(), i });
                return dest_reg;
            },
            .bool => |b| {
                try self.emit("    mov {s}, #{d}\n", .{ dest_reg.toString(), @intFromBool(b) });
                return dest_reg;
            },
            .variable, .temp => {
                switch (self.resolve(operand)) {
                    .reg => |reg| return reg.name, // already in a register
                    .stack => |offset| {
                        try self.emit("    ldr {s}, [x29, #{d}]\n", .{
                            dest_reg.toString(), offset,
                        });
                        return dest_reg;
                    },
                }
            },
            else => std.debug.panic("unsupported operand type for materialization {f}", .{operand}),
        }
    }

    fn emitInstr(self: *CodeGen, instr: ir.Instr) !void {
        // TODO: abstract these to functions
        switch (instr) {
            .assign => |op| {
                const d = self.dest(op.target);
                try self.emit("    ; {f} = {f}\n", .{ op.target, op.value });
                switch (op.value.value) {
                    .int => |i| try self.emit("    mov {s}, #{d}\n", .{ d.reg.toString(), i }),
                    .bool => |b| try self.emit("    mov {s}, #{d}\n", .{
                        d.reg.toString(), @intFromBool(b),
                    }),
                    .variable, .temp => {
                        const s_scratch = self.scratch.borrow();
                        defer self.scratch.release(s_scratch);

                        const s = try self.materialize(op.value, s_scratch);
                        if (!std.mem.eql(u8, s.toString(), d.reg.toString())) {
                            try self.emit("    mov {s}, {s}\n", .{
                                d.reg.toString(), s.toString(),
                            });
                        }
                    },
                    else => std.debug.panic("unsupported operand type for assign: {f}", .{op.value}),
                }
                if (d.must_store) {
                    try self.store(op.target, d.reg);
                    self.scratch.release(d.reg);
                }
            },
            .add => |op| {
                const d = self.dest(op.result);

                const ls = self.scratch.borrow();
                defer self.scratch.release(ls);

                const left = try self.materialize(op.left, ls);

                switch (op.right.value) {
                    .int => |i| {
                        try self.emit("    add {s}, {s}, #{d} ; {f} = {f} + {f}\n", .{
                            d.reg.toString(), left.toString(), i,
                            op.result,        op.left,         op.right,
                        });
                    },
                    else => {
                        const rs = self.scratch.borrow();
                        defer self.scratch.release(rs);

                        const right = try self.materialize(op.right, rs);
                        try self.emit("    add {s}, {s}, {s} ; {f} = {f} + {f}\n", .{
                            d.reg.toString(), left.toString(), right.toString(),
                            op.result,        op.left,         op.right,
                        });
                    },
                }
                if (d.must_store) {
                    try self.store(op.result, d.reg);
                    self.scratch.release(d.reg);
                }
            },
            .sub => |op| {
                const d = self.dest(op.result);

                const ls = self.scratch.borrow();
                defer self.scratch.release(ls);

                const left = try self.materialize(op.left, ls);

                switch (op.right.value) {
                    .int => |i| {
                        try self.emit("    sub {s}, {s}, #{d} ; {f} = {f} - {f}\n", .{
                            d.reg.toString(), left.toString(), i,
                            op.result,        op.left,         op.right,
                        });
                    },
                    else => {
                        const rs = self.scratch.borrow();
                        defer self.scratch.release(rs);

                        const right = try self.materialize(op.right, rs);
                        try self.emit("    sub {s}, {s}, {s} ; {f} = {f} - {f}\n", .{
                            d.reg.toString(), left.toString(), right.toString(),
                            op.result,        op.left,         op.right,
                        });
                    },
                }
                if (d.must_store) {
                    try self.store(op.result, d.reg);
                    self.scratch.release(d.reg);
                }
            },
            .mul => |op| {
                const d = self.dest(op.result);
                const ls = self.scratch.borrow();
                defer self.scratch.release(ls);
                const rs = self.scratch.borrow();
                defer self.scratch.release(rs);

                const left = try self.materialize(op.left, ls);
                const right = try self.materialize(op.right, rs);

                try self.emit("    mul {s}, {s}, {s} ; {f} = {f} * {f}\n", .{
                    d.reg.toString(), left.toString(), right.toString(),
                    op.result,        op.left,         op.right,
                });

                if (d.must_store) {
                    try self.store(op.result, d.reg);
                    self.scratch.release(d.reg);
                }
            },
            .div => |op| {
                const d = self.dest(op.result);
                const ls = self.scratch.borrow();
                defer self.scratch.release(ls);

                const rs = self.scratch.borrow();
                defer self.scratch.release(rs);

                const left = try self.materialize(op.left, ls);
                const right = try self.materialize(op.right, rs);
                try self.emit("    sdiv {s}, {s}, {s} ; {f} = {f} / {f}\n", .{
                    d.reg.toString(), left.toString(), right.toString(),
                    op.result,        op.left,         op.right,
                });
                if (d.must_store) {
                    try self.store(op.result, d.reg);
                    self.scratch.release(d.reg);
                }
            },
            .unary_minus => |op| {
                const d = self.dest(op.result);
                const os = self.scratch.borrow();
                defer self.scratch.release(os);

                const operand = try self.materialize(op.operand, os);
                try self.emit("    neg {s}, {s}\n", .{
                    d.reg.toString(), operand.toString(),
                });

                if (d.must_store) {
                    try self.store(op.result, d.reg);
                    self.scratch.release(d.reg);
                }
            },
            .unary_not => |op| {
                const d = self.dest(op.result);
                const os = self.scratch.borrow();
                defer self.scratch.release(os);

                const operand = try self.materialize(op.operand, os);
                try self.emit("    eor {s}, {s}, #1\n", .{
                    d.reg.toString(), operand.toString(),
                });

                if (d.must_store) {
                    try self.store(op.result, d.reg);
                    self.scratch.release(d.reg);
                }
            },
            .call => |op| {
                try self.emit(
                    "    ; call {s}({d} args)[{f}]\n",
                    .{ op.callee, op.args.len, op.result },
                );

                if (op.args.len > ra.ARGUMENT_REGISTERS.len) {
                    @panic("more than 8 call args not yet supported");
                }

                // BUG: this is WRONG. instead of sequentially, argument passing needs to be done
                // in a parallel manner to mitigate register swapping issues
                // (e.g. if arg1 is in x1 but needs to be in x0, and arg0 is in x0 but needs to be in x1,
                // we can't just move them sequentially or we'll clobber one of the arguments values)
                // for (op.args, 0..) |arg, idx| {
                //     const target_reg = ra.ARGUMENT_REGISTERS[idx];
                //     const arg_scratch = self.scratch.borrow();
                //     defer self.scratch.release(arg_scratch);
                //
                //     const arg_reg = try self.materialize(arg, arg_scratch);
                //
                //     if (!std.mem.eql(u8, arg_reg.toString(), target_reg.name.toString())) {
                //         try self.emit("    mov {s}, {s}\n", .{
                //             target_reg.name.toString(), arg_reg.toString(),
                //         });
                //     }
                // }

                try self.emitCallArgs(op.args);

                try self.emit("    bl {s}\n", .{op.callee});
                try self.store(op.result, .x0);
            },
            .tail_call => |op| {
                try self.emit(
                    "    ; tail call {s}({d} args)\n",
                    .{ op.callee, op.args.len },
                );

                if (op.args.len > ra.ARGUMENT_REGISTERS.len) {
                    @panic("more than 8 call args not yet supported");
                }

                try self.emitCallArgs(op.args);
                try self.emitEpilogue(self.current_frame_size, self.current_callee_saved);
                try self.emit("    b {s}\n", .{op.callee});
            },
            .eq => |op| try self.emitCondition(op.result, op.left, op.right, "eq"),
            .neq => |op| try self.emitCondition(op.result, op.left, op.right, "ne"),
            .lt => |op| try self.emitCondition(op.result, op.left, op.right, "lt"),
            .lt_eq => |op| try self.emitCondition(op.result, op.left, op.right, "le"),
            .gt => |op| try self.emitCondition(op.result, op.left, op.right, "gt"),
            .gt_eq => |op| try self.emitCondition(op.result, op.left, op.right, "ge"),
            // .unary_not => |op| try self.emitCondition(op.result, op.operand, ir.Operand{
            //     .value = .{ .int = 0 },
            //     .type_id = self.ctx.typeStore().builtins.int,
            // }, "eq"),

            // else => @panic("Unsupported instruction type"),
        }
    }

    const RegMove = struct { dst: ra.RegisterName, src: ra.RegisterName };

    fn regUsedAsSource(moves: []const RegMove, reg: ra.RegisterName) bool {
        for (moves) |move| {
            if (move.src == reg) return true;
        }

        return false;
    }

    const DelayedArg = union(enum) {
        int: struct {
            dst: ra.RegisterName,
            value: i64,
        },
        bool: struct {
            dst: ra.RegisterName,
            value: bool,
        },
        stack: struct {
            dst: ra.RegisterName,
            offset: isize,
        },
    };

    fn emitParallelRegMoves(self: *CodeGen, moves_in: []const RegMove) !void {
        var moves: std.ArrayList(RegMove) = .empty;

        for (moves_in) |m| {
            if (!std.mem.eql(u8, m.src.toString(), m.dst.toString())) {
                try moves.append(self.ctx.allocator, m);
            }
        }

        // maybe we need a temp register to properly swap
        var maybe_tmp: ?ra.RegisterName = null;
        defer {
            if (maybe_tmp) |tmp| {
                self.scratch.release(tmp);
            }
        }

        while (moves.items.len > 0) {
            var progress = false;

            // try to find a move that can be safely emitted without clobbering any sources
            var i: usize = 0;
            while (i < moves.items.len) : (i += 1) {
                const move = moves.items[i];

                if (!regUsedAsSource(moves.items, move.dst)) {
                    try self.emit("    mov {s}, {s}\n", .{
                        move.dst.toString(), move.src.toString(),
                    });
                    _ = moves.orderedRemove(i);
                    progress = true;
                    break;
                }
            }

            if (progress) continue; // reordering moves worked, no need for a temp

            // we have a cycle, we need to break it with a temp register
            const tmp = maybe_tmp orelse blk: {
                const t = self.scratch.borrow();
                maybe_tmp = t;
                break :blk t;
            };

            const src_to_save = moves.items[0].src;
            std.debug.print("^^^^^^^^^^^^^^^ cycle detected, {d}\n", .{moves.items.len});

            try self.emit("    mov {s}, {s} ; breaking cycle\n", .{
                tmp.toString(), src_to_save.toString(),
            });

            for (moves.items) |*move| {
                if (std.mem.eql(u8, move.src.toString(), src_to_save.toString())) {
                    move.src = tmp;
                }
            }
        }
    }

    fn emitCallArgs(self: *CodeGen, args: []const ir.Operand) !void {
        var reg_moves: std.ArrayList(RegMove) = .empty;
        var delayed_args: std.ArrayList(DelayedArg) = .empty;

        // first pass: determine which arguments can be moved directly
        // and which need to be delayed (immediates and stack values)
        for (args, 0..) |arg, idx| {
            const dst = ra.ARGUMENT_REGISTERS[idx].name;

            switch (arg.value) {
                .int => |i| {
                    delayed_args.append(self.ctx.allocator, DelayedArg{
                        .int = .{ .dst = dst, .value = i },
                    }) catch @panic("failed to append delayed int arg");
                },
                .bool => |b| {
                    delayed_args.append(self.ctx.allocator, DelayedArg{
                        .bool = .{ .dst = dst, .value = b },
                    }) catch @panic("failed to append delayed bool arg");
                },
                .variable, .temp => {
                    switch (self.resolve(arg)) {
                        .reg => |reg| {
                            if (!std.mem.eql(u8, reg.name.toString(), dst.toString())) {
                                reg_moves.append(self.ctx.allocator, RegMove{
                                    .dst = dst,
                                    .src = reg.name,
                                }) catch @panic("failed to append reg move for call arg");
                            }
                        },
                        .stack => |offset| {
                            delayed_args.append(self.ctx.allocator, DelayedArg{
                                .stack = .{ .dst = dst, .offset = offset },
                            }) catch @panic("failed to append delayed stack arg");
                        },
                    }
                },
                else => std.debug.panic("unsupported argument type for operand {f}", .{arg}),
            }
        }

        // second pass: emit register moves in an order that avoids clobbering sources (might add a temp)
        try self.emitParallelRegMoves(reg_moves.items);

        // finally: emit delayed arguments which we couldn't move in the first pass
        for (delayed_args.items) |arg| {
            switch (arg) {
                .int => |a| try self.emit("    mov {s}, #{d}\n", .{ a.dst.toString(), a.value }),
                .bool => |a| try self.emit("    mov {s}, #{d}\n", .{ a.dst.toString(), @intFromBool(a.value) }),
                .stack => |a| try self.emit("    ldr {s}, [x29, #{d}]\n", .{ a.dst.toString(), a.offset }),
            }
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

        const ls = self.scratch.borrow();
        defer self.scratch.release(ls);
        const rs = self.scratch.borrow();
        defer self.scratch.release(rs);

        const lreg = try self.materialize(left, ls);
        const rreg = try self.materialize(right, rs);

        try self.emit("    cmp {s}, {s}\n", .{ lreg.toString(), rreg.toString() });

        const d = self.dest(result);
        try self.emit("    cset {s}, {s}\n", .{ d.reg.toString(), cmp_instr });

        if (d.must_store) {
            try self.store(result, d.reg);
            self.scratch.release(d.reg);
        }
    }

    fn resolve(self: *const CodeGen, operand: ir.Operand) ra.PhysicalLocation {
        const key: liveness.LivenessKey = switch (operand.value) {
            .temp => |id| .{ .temp = id },
            .variable => |name| .{ .variable = name },
            else => std.debug.panic(
                "resolve: operand {f} has no allocation key\n",
                .{operand},
            ),
        };

        return self.allocations.?.get(key) orelse std.debug.panic(
            "resolve: no allocation for {f}\n",
            .{operand},
        );
    }

    fn emitTerminator(self: *CodeGen, term: ir.Terminator, func_name: []const u8) !void {
        switch (term) {
            .exit => |op| {
                try self.emit("\n    ; exit {f}\n", .{op});
                const s = self.scratch.borrow();
                defer self.scratch.release(s);

                const d = try self.materialize(op, s);

                if (!std.mem.eql(u8, d.toString(), "x0")) {
                    try self.emit("    mov x0, {s}\n", .{d.toString()});
                }
                try self.emit("    mov x16, #1\n    svc #0x80\n", .{});
            },
            .@"return" => |op| {
                const s = self.scratch.borrow();
                defer self.scratch.release(s);

                const r = try self.materialize(op, s);

                if (!std.mem.eql(u8, r.toString(), "x0")) {
                    try self.emit("    mov x0, {s}\n", .{r.toString()});
                }

                try self.emitEpilogue(self.current_frame_size, self.current_callee_saved);
                try self.emit("    ret\n", .{});
            },
            .jump => |target| try self.emit("    b block_{s}_{d}\n", .{ func_name, target }),
            .cond_jump => |cj| {
                const s = self.scratch.borrow();
                defer self.scratch.release(s);
                const r = try self.materialize(cj.condition, s);

                try self.emit("    cbnz {s}, block_{s}_{d}\n", .{
                    r.toString(), func_name, cj.true_target,
                });
                // try self.emit("    cmp {s}, #1\n", .{r.toString()});
                // try self.emit("    b.eq block_{s}_{d}\n", .{ func_name, cj.true_target });
                try self.emit("    b block_{s}_{d}\n", .{ func_name, cj.false_target });
            },
            // else => @panic("Unsupported terminator type"),
        }
    }

    fn emit(self: *CodeGen, comptime fmt: []const u8, args: anytype) !void {
        try self.output.print(self.ctx.allocator, fmt, args);
        std.debug.print(fmt, args); // for debugging
    }

    fn emitPrologue(self: *CodeGen, frame_size: usize, callee_saved: []const ra.Register) !void {
        // try self.emit("    ; prologue\n", .{});
        try self.emit("    ; frame size: {d}\n", .{frame_size});
        try self.emit("    sub sp, sp, #{d}\n", .{frame_size});
        try self.emit("    stp x29, x30, [sp, #{d}]\n", .{frame_size - 16});
        try self.emit("    add x29, sp, #{d}\n\n", .{frame_size - 16});

        for (callee_saved, 0..) |reg, i| {
            const offset = -@as(isize, @intCast((i + 1) * 8));
            try self.emit("    str {s}, [x29, #{d}]\n", .{ reg.name.toString(), offset });
        }
    }

    fn emitEpilogue(self: *CodeGen, frame_size: usize, callee_saved: []const ra.Register) !void {
        try self.emit("\n    ; epilogue\n", .{});

        var i = callee_saved.len;
        while (i > 0) {
            i -= 1;
            const offset = -@as(isize, @intCast((i + 1) * 8));
            try self.emit("    ldr {s}, [x29, #{d}]\n", .{ callee_saved[i].name.toString(), offset });
        }

        try self.emit("    ldp x29, x30, [sp, #{d}]\n", .{frame_size - 16});
        try self.emit("    add sp, sp, #{d}\n", .{frame_size});
    }

    fn emitHeader(self: *CodeGen) !void {
        try self.emit(".global _main\n", .{}); // NOTE: hardcoded
        try self.emit(".align 2\n\n", .{});
    }

    fn store(self: *CodeGen, result: ir.Operand, src_reg: ra.RegisterName) !void {
        switch (self.resolve(result)) {
            .reg => |reg| {
                if (!std.mem.eql(u8, reg.name.toString(), src_reg.toString())) {
                    try self.emit("    mov {s}, {s}\n", .{
                        reg.name.toString(), src_reg.toString(),
                    });
                }
            },
            .stack => |offset| {
                try self.emit("    str {s}, [x29, #{d}]\n", .{
                    src_reg.toString(), offset,
                });
            },
        }
    }

    const DestResult = struct { reg: ra.RegisterName, must_store: bool };
    fn dest(self: *CodeGen, result: ir.Operand) DestResult {
        switch (self.resolve(result)) {
            .reg => |reg| return .{ .reg = reg.name, .must_store = false },
            .stack => return .{ .reg = self.scratch.borrow(), .must_store = true },
        }
    }
};
