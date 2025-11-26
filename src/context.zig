const std = @import("std");

pub const CompilerContext = struct {
    allocator: std.mem.Allocator,
    source: []const u8,

    pub fn init(allocator: std.mem.Allocator, sourceCode: []const u8) CompilerContext {
        return CompilerContext{
            .allocator = allocator,
            .source = sourceCode,
        };
    }
};
