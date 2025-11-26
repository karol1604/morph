const std = @import("std");

pub fn encodeCodepointToUtf8(cp: u21, buf: *[4]u8) ![]const u8 {
    const len = try std.unicode.utf8Encode(cp, buf);
    return buf[0..len];
}

pub fn isDigit(c: u21) bool {
    return c >= '0' and c <= '9';
}

pub fn isAlpha(c: u21) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c == '_');
}

pub fn isAlphaNumeric(c: u21) bool {
    return isAlpha(c) or isDigit(c);
}
