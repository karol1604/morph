const std = @import("std");
const Span = @import("span.zig").Span;
const diag = @import("diagnostic.zig");
const zspan = @import("zspan");
const TypeStore = @import("type_store.zig").TypeStore;

pub const CompilerContext = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    diagnostics: std.ArrayList(zspan.Diagnostic),
    source_file: zspan.SourceFile,
    source: []const u8,
    type_store: ?*const TypeStore,

    pub fn init(
        arena: *std.heap.ArenaAllocator,
        source_code: []const u8,
        name: []const u8,
    ) CompilerContext {
        return CompilerContext{
            .arena = arena,
            .allocator = arena.allocator(),
            .source = source_code,
            .diagnostics = .empty,
            .source_file = zspan.SourceFile.init(name, source_code, arena.allocator()),
            .type_store = null,
        };
    }

    pub fn attachTypeStore(self: *CompilerContext, type_store: *const TypeStore) void {
        self.type_store = type_store;
    }

    pub fn getTypeStore(self: *const CompilerContext) *const TypeStore {
        return self.type_store orelse
            std.debug.panic("Type store not attached to compiler context", .{});
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

        const labels = self.allocator.alloc(zspan.Label, 1) catch return;
        labels[0] = zspan.Label.primary(span.start.offset, span.end.offset, "", 0); // FIXME: temporary

        self.diagnostics.append(self.allocator, .{
            .severity = .@"error",
            .message = msg,
            .labels = labels,
            .notes = &.{},
        }) catch {};
    }

    pub fn hasErrors(self: *const CompilerContext) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }
};
