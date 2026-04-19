const std = @import("std");
const targ = @import("target.zig");
const context = @import("context.zig");
const Emitter = @import("emitters/emitter.zig").Emitter;
const ir = @import("ir.zig");

pub const CodeGen = struct {
    ctx: *context.CompilerContext,
    target: targ.Target,
    output: std.ArrayList(u8) = .empty,
    irGen: *const ir.IRGen,
    varToStackOffset: std.StringHashMap(isize),
    currentStackOffset: isize = -8,

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
        try self.emit("{s}:\n", .{func.name});

        const frameSize = CodeGen.calculateFrameSize(func);

        try self.emitPrologue(frameSize);

        for (func.blocks.items) |block| {
            try self.emitBlock(block);
        }

        // epilogue
        // FIXME: wrong spot
        // if (frameSize > 0) {
        //     try self.emit("\n    ; epilogue\n", .{});
        //     try self.emit("    ldp x29, x30, [sp, #{d}]\n", .{frameSize - 16});
        //     try self.emit("    add sp, sp, #{d}\n", .{frameSize});
        // }
    }

    fn emitBlock(self: *CodeGen, block: ir.BasicBlock) !void {
        for (block.instructions.items) |instr| {
            try self.emitInstr(instr);
        }

        if (block.terminator) |term| {
            try self.emitTerminator(term);
        }
    }

    fn emitInstr(self: *CodeGen, instr: ir.Instr) !void {
        // _ = self;
        // _ = instr;
        // @panic("Instruction emission not implemented yet");

        switch (instr) {
            .Assign => |op| {
                switch (op.value.value) {
                    .Int => |i| {
                        try self.emit("    ; assign {f} = {f}\n", .{ op.target, op.value });
                        try self.emit("    mov x0, #{d}\n", .{i});
                        // TODO: negate the offset since we are growing downwards
                        try self.emit("    str x0, [x29, #{d}]\n\n", .{self.currentStackOffset});

                        self.varToStackOffset.put(op.target.toString(), self.currentStackOffset) catch {
                            @panic("Failed to map variable to stack offset");
                        };

                        self.currentStackOffset -= 8;
                    },
                    else => @panic("Unsupported operand type for assign instruction"),
                }
            },
            else => @panic("Unsupported instruction type"),
        }
    }

    fn emitTerminator(self: *CodeGen, term: ir.Terminator) !void {
        switch (term) {
            .Exit => |op| {
                switch (op.value) {
                    .Int => |code| {
                        try self.emit("    mov x0, #{d}\n", .{code});
                        try self.emit("    mov x16, #1\n    svc #0x80\n", .{});
                    },
                    .Variable => |name| {
                        // NOTE: im pretty sure that the IR enforces that the variable used in an exit terminator must be assigned to an integer literal, so this should be safe
                        const offset = self.varToStackOffset.get(name) orelse unreachable;
                        try self.emit("    ldr x0, [x29, #{d}]\n", .{offset});
                        try self.emit("    mov x16, #1\n    svc #0x80\n", .{});
                    },
                    else => @panic("Unsupported exit operand type"),
                }
            },
            else => @panic("Unsupported terminator type"),
        }
    }

    fn emit(self: *CodeGen, comptime fmt: []const u8, args: anytype) !void {
        try self.output.writer(self.ctx.allocator).print(fmt, args);
    }

    fn emitPrologue(self: *CodeGen, frameSize: usize) !void {
        try self.emit("    ; prologue\n", .{});
        try self.emit("    ; frame size: {}\n", .{frameSize});
        try self.emit("    sub sp, sp, #{d}\n", .{frameSize});

        try self.emit("    stp x29, x30, [sp, #{d}]\n", .{frameSize - 16});

        try self.emit("    add x29, sp, #{d}\n\n", .{frameSize - 16});
    }

    fn emitHeader(self: *CodeGen) !void {
        try self.emit(".global _main\n", .{}); // NOTE: hardcoded
        try self.emit(".align 2\n\n", .{});
    }

    fn calculateFrameSize(func: ir.IRFunction) usize {
        var count: usize = 0;
        for (func.blocks.items) |block| {
            for (block.instructions.items) |instr| {
                switch (instr) {
                    .Assign => count += 1,
                    else => {},
                }
            }
        }
        const bytes = count * 8;
        return std.mem.alignForward(usize, bytes + 16, 16); // NOTE: we need the +16 for x29 x30
    }
};
