const std = @import("std");
const targ = @import("target.zig");
const context = @import("context.zig");
const Emitter = @import("emitters/emitter.zig").Emitter;
const irg = @import("ir.zig");

// fn Emitter(comptime target: targ.Target) type {
//     return comptime switch (target.arch) {
//         .x86_64 => @compileError("x86_64 code generation not implemented yet"),
//         .aarch64 => switch (target.os) {
//             .linux => @compileError("aarch64 Linux code generation not implemented yet"),
//             .macos => @import("emitters/emit_aarch64_macos.zig"),
//         },
//     };
// }

pub const CodeGen = struct {
    ctx: *context.CompilerContext,
    target: targ.Target,
    output: std.ArrayList(u8) = .empty,
    irGen: *const irg.IRGen,

    pub fn init(ctx: *context.CompilerContext, target: targ.Target, irGen: *const irg.IRGen) CodeGen {
        return CodeGen{
            .ctx = ctx,
            .target = target,
            .irGen = irGen,
        };
    }

    pub fn generate(self: *CodeGen) !void {
        // Placeholder for code generation logic
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

    fn emitFunction(self: *CodeGen, func: irg.IRFunction) !void {
        for (func.blocks.items) |block| {
            try self.emitBlock(block);
        }
    }

    fn emitBlock(self: *CodeGen, block: irg.BasicBlock) !void {
        for (block.instructions.items) |instr| {
            try self.emitInstr(instr);
        }

        if (block.terminator) |term| {
            try self.emitTerminator(term);
        }
    }

    fn emitInstr(self: *CodeGen, instr: irg.Instr) !void {
        // Placeholder for instruction emission logic
        _ = instr;
        _ = self;
        @panic("Instruction emission not implemented yet");
    }

    fn emitTerminator(self: *CodeGen, term: irg.Terminator) !void {
        switch (term) {
            .Exit => |op| {
                switch (op.value) {
                    .Int => |code| {
                        try self.emit("    mov x0, #");
                        try self.emit(try std.fmt.allocPrint(self.ctx.allocator, "{}", .{code}));
                        try self.emit("\n    mov x16, #1\n    svc #0x80\n");
                    },
                    else => @panic("Unsupported exit operand type"),
                }
            },
            else => @panic("Unsupported terminator type"),
        }
    }
    fn emit(self: *CodeGen, bytes: []const u8) !void {
        try self.output.appendSlice(self.ctx.allocator, bytes);
    }

    fn emitHeader(self: *CodeGen) !void {
        try self.emit(".global _main\n");
        try self.emit(".align 2\n\n");
        try self.emit("_main:\n"); //FIXME: this should not be here
    }
};
