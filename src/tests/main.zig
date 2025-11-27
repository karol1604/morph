const std = @import("std");
const lexerTests = @import("parser.zig");

test {
    std.testing.refAllDecls(lexerTests);
    try std.testing.expectEqual(3, 3);
}
