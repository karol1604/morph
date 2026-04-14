const std = @import("std");

pub const Emitter = struct {
    emitHeader: *const fn (output: *std.ArrayList(u8)) anyerror!void,
    emitExit: *const fn (output: *std.ArrayList(u8), code: u8) anyerror!void,
};
