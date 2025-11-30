const std = @import("std");
const span = @import("span.zig");

pub const Severity = enum {
    Info,
    Warning,
    Error,
};

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    span: span.Span,
};
