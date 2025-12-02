const std = @import("std");
const Span = @import("span.zig").Span;
const diag = @import("diagnostic.zig");

pub const CompilerContext = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    arena: *std.heap.ArenaAllocator,
    diagnostics: std.ArrayList(diag.Diagnostic),

    pub fn init(arena: *std.heap.ArenaAllocator, sourceCode: []const u8) CompilerContext {
        return CompilerContext{
            .arena = arena,
            .allocator = arena.allocator(),
            .source = sourceCode,
            .diagnostics = .empty,
        };
    }

    pub fn deinit(self: *CompilerContext) void {
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn reportError(
        self: *CompilerContext,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.diagnostics.append(self.allocator, .{
            .severity = .Error,
            .span = span,
            .message = msg,
        }) catch {};
    }

    pub fn hasErrors(self: *const CompilerContext) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .Error) return true;
        }
        return false;
    }
};
