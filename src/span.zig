const std = @import("std");

pub const Location = struct {
    offset: usize,
    line: usize,
    col: usize,
};

pub const Span = struct {
    start: Location,
    end: Location,

    pub fn join(left: Span, right: Span) Span {
        return Span{
            .start = left.start,
            .end = right.end,
        };
    }

    pub fn format(self: Span, writer: *std.Io.Writer) !void {
        try writer.print("{d}:{d}..{d}:{d} (offset: [{d}..{d}])", .{
            self.start.line,
            self.start.col,
            self.end.line,
            self.end.col,
            self.start.offset,
            self.end.offset,
        });
    }
};
