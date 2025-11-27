const std = @import("std");
const context = @import("context.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const parserTests = @import("tests/parser.zig");
const utils = @import("utils.zig");

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    const all = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(all);

    // const source = "ℕ";
    const source = "{ 67; a;} ";

    var ctx = context.CompilerContext.init(&arena, source);
    defer ctx.deinit();

    var lex = lexer.Lexer.init(&ctx) catch return error.LexerInitFailed;
    const tokens = try lex.tokenize();

    var pars = parser.Parser.init(tokens, &ctx);

    // std.debug.print("Tokens:\n", .{});
    // for (tokens, 0..) |token, idx| {
    //     std.debug.print("  {d}: {f}\n", .{ idx, token });
    // }

    const exprs = try pars.parse();
    std.debug.print("Expression(s):\n", .{});
    for (exprs) |expr| {
        utils.prettyPrintExpression(expr.*);
    }
}

test "simple test" {
    std.testing.refAllDecls(parserTests);
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
