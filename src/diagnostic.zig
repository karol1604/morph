const std = @import("std");
const Span = @import("span.zig").Span;
const CompilerContext = @import("context.zig").CompilerContext;
const zspan = @import("zspan");

pub const DiagnosticBuilder = struct {
    ctx: *CompilerContext,
    severity: zspan.Severity,
    message: []const u8,
    labels: std.ArrayList(zspan.Label),
    notes: std.ArrayList([]const u8),

    pub fn err(ctx: *CompilerContext, comptime fmt: []const u8, args: anytype) DiagnosticBuilder {
        return .{
            .ctx = ctx,
            .severity = .Error,
            .message = std.fmt.allocPrint(ctx.allocator, fmt, args) catch "Failed to format diagnostic message",
            .labels = .empty,
            .notes = .empty,
        };
    }

    pub fn warn(ctx: *CompilerContext, comptime fmt: []const u8, args: anytype) DiagnosticBuilder {
        return .{
            .ctx = ctx,
            .severity = .Warning,
            .message = std.fmt.allocPrint(ctx.allocator, fmt, args) catch "Failed to format diagnostic message",
            .labels = .empty,
            .notes = .empty,
        };
    }

    pub fn info(ctx: *CompilerContext, comptime fmt: []const u8, args: anytype) DiagnosticBuilder {
        return .{
            .ctx = ctx,
            .severity = .Info,
            .message = std.fmt.allocPrint(ctx.allocator, fmt, args) catch "Failed to format diagnostic message",
            .labels = .empty,
            .notes = .empty,
        };
    }

    pub fn primaryLabel(
        self: *DiagnosticBuilder,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) *DiagnosticBuilder {
        const msg = std.fmt.allocPrint(self.ctx.allocator, fmt, args) catch "Failed to format label message";
        self.labels.append(
            self.ctx.allocator,
            zspan.Label.primary(span.start.offset, span.end.offset, msg, 0),
        ) catch {};
        return self;
    }

    pub fn secondaryLabel(
        self: *DiagnosticBuilder,
        span: Span,
        comptime fmt: []const u8,
        args: anytype,
    ) *DiagnosticBuilder {
        const msg = std.fmt.allocPrint(self.ctx.allocator, fmt, args) catch "Failed to format label message";
        self.labels.append(
            self.ctx.allocator,
            zspan.Label.secondary(span.start.offset, span.end.offset, msg, 0),
        ) catch {
            std.debug.print("Failed to append label to diagnostic\n", .{});
        };
        return self;
    }

    pub fn note(self: *DiagnosticBuilder, comptime fmt: []const u8, args: anytype) *DiagnosticBuilder {
        const msg = std.fmt.allocPrint(self.ctx.allocator, fmt, args) catch "Failed to format note message";
        self.notes.append(self.ctx.allocator, msg) catch {};
        return self;
    }

    pub fn emit(self: *DiagnosticBuilder) void {
        const diag = zspan.Diagnostic{
            .severity = self.severity,
            .message = self.message,
            .labels = self.labels.toOwnedSlice(self.ctx.allocator) catch &.{},
            .notes = self.notes.toOwnedSlice(self.ctx.allocator) catch &.{},
        };
        self.ctx.diagnostics.append(self.ctx.allocator, diag) catch {};
    }
};
