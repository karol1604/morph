const std = @import("std");

pub const CompilerContext = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    arena: *std.heap.ArenaAllocator,

    pub fn init(arena: *std.heap.ArenaAllocator, sourceCode: []const u8) CompilerContext {
        return CompilerContext{
            .arena = arena,
            .allocator = arena.allocator(),
            .source = sourceCode,
        };
    }

    pub fn deinit(self: *CompilerContext) void {
        self.arena.deinit();
    }
};
