const std = @import("std");
const Span = @import("span.zig").Span;
const diag = @import("diagnostic.zig");
const zspan = @import("zspan");

pub const CompilerContext = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    diagnostics: std.ArrayList(zspan.Diagnostic),
    sourceFile: zspan.SourceFile,
    source: []const u8,

    pub fn init(
        arena: *std.heap.ArenaAllocator,
        sourceCode: []const u8,
        name: []const u8,
    ) CompilerContext {
        return CompilerContext{
            .arena = arena,
            .allocator = arena.allocator(),
            .source = sourceCode,
            .diagnostics = .empty,
            .sourceFile = zspan.SourceFile.init(name, sourceCode, arena.allocator()),
        };
    }

    pub fn deinit(self: *CompilerContext) void {
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn reportError(self: *CompilerContext, span: Span, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;

        const labels = self.allocator.alloc(zspan.Label, 1) catch return;
        labels[0] = zspan.Label.primary(span.start.offset, span.end.offset, "", 0); // FIXME: temporary

        self.diagnostics.append(self.allocator, .{
            .severity = .Error,
            .message = msg,
            .labels = labels,
            .notes = &.{},
        }) catch {};
    }

    pub fn hasErrors(self: *const CompilerContext) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .Error) return true;
        }
        return false;
    }
};
