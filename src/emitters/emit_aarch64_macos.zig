const std = @import("std");
const context = @import("../context.zig");
const Emitter = @import("emitter.zig").Emitter;

const Self = @This();

pub const emitter = Emitter{
    .emitHeader = &emitHeader,
    .emitExit = &emitExit,
};

// ctx: *context.CompilerContext,
// output: *std.ArrayList(u8),

pub fn emitHeader(output: *std.ArrayList(u8)) !void {
    try output.appendSlice(".global _main\n");
    try output.appendSlice(".align 2\n\n");
}
pub fn emitExit(output: *std.ArrayList(u8), code: u8) !void {
    _ = code;
    try output.appendSlice("    mov x0, #69\n", .{});
    try output.appendSlice("    mov x16, #1\n");
    try output.appendSlice("    svc #0x80\n");
}

fn emit(self: *@This(), bytes: []const u8) !void {
    try self.output.appendSlice(self.ctx.allocator, bytes);
}
