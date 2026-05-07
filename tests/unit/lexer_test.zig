const std = @import("std");
const morph = @import("morph");
const lexer = morph.lexer;
const context = morph.context;
const token = morph.tok;

const TokenType = token.TokenType;

fn lex(arena: *std.heap.ArenaAllocator, source: []const u8) ![]TokenType {
    var ctx = context.CompilerContext.init(arena, source, "<test>");
    var l = try lexer.Lexer.init(&ctx);
    const toks = try l.tokenize();

    const kinds = try arena.allocator().alloc(TokenType, toks.len - 1);
    for (toks[0 .. toks.len - 1], 0..) |t, i| kinds[i] = t.kind;
    return kinds;
}

fn lexRaw(arena: *std.heap.ArenaAllocator, source: []const u8) ![]token.Token {
    var ctx = context.CompilerContext.init(arena, source, "<test>");
    var l = try lexer.Lexer.init(&ctx);
    return l.tokenize();
}

fn expectKinds(actual: []TokenType, expected: []const TokenType) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try std.testing.expect(std.meta.activeTag(a) == e);
    }
}

test "single-char arithmetic operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "+ - * / ^");
    try expectKinds(kinds, &.{ .plus, .minus, .star, .slash, .caret });
}

test "single-char delimiter tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "( ) [ ] { } ; : ,");
    try expectKinds(kinds, &.{
        .lparen,    .rparen,
        .lsquare,   .rsquare,
        .lbrace,    .rbrace,
        .semicolon, .colon,
        .comma,
    });
}

test "bang produces bang token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "!");
    try expectKinds(kinds, &.{.bang});
}

test "arrow ->" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "->");
    try expectKinds(kinds, &.{.right_arrow});
}

test "double arrow =>" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "=>");
    try expectKinds(kinds, &.{.double_right_arrow});
}

test "double equal ==" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "==");
    try expectKinds(kinds, &.{.double_equal});
}

test "not equal !=" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "!=");
    try expectKinds(kinds, &.{.not_equal});
}

test "less than or equal <=" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "<=");
    try expectKinds(kinds, &.{.less_than_or_equal});
}

test "greater than or equal >=" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, ">=");
    try expectKinds(kinds, &.{.greater_than_or_equal});
}

test "lone < and > stay as their own tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "< >");
    try expectKinds(kinds, &.{ .less_than, .greater_than });
}

test "lone = stays as equal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "=");
    try expectKinds(kinds, &.{.equal});
}

test "lone - stays as minus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "-");
    try expectKinds(kinds, &.{.minus});
}

test "unicode in operator ∈" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "∈");
    try expectKinds(kinds, &.{.in});
}

test "unicode cross operator ×" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "×");
    try expectKinds(kinds, &.{.cross});
}

test "unicode identifier ℕ is treated as identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toks = try lexRaw(&arena, "ℕ");
    try std.testing.expectEqual(std.meta.activeTag(toks[0].kind), TokenType.identifier);
}

test "integer literal value is preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toks = try lexRaw(&arena, "42");
    try std.testing.expectEqual(toks[0].kind.int_literal, 42);
}

test "multi-digit integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toks = try lexRaw(&arena, "12345");
    try std.testing.expectEqual(toks[0].kind.int_literal, 12345);
}

test "zero is a valid integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toks = try lexRaw(&arena, "0");
    try std.testing.expectEqual(toks[0].kind.int_literal, 0);
}

test "plain identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toks = try lexRaw(&arena, "foo");
    try std.testing.expectEqualStrings("foo", toks[0].kind.identifier);
}

test "underscore-prefixed identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toks = try lexRaw(&arena, "_bar");
    try std.testing.expectEqualStrings("_bar", toks[0].kind.identifier);
}

test "identifier with digits in it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toks = try lexRaw(&arena, "x1");
    try std.testing.expectEqualStrings("x1", toks[0].kind.identifier);
}

test "all keywords are recognised" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "true false let and or if then else");
    try expectKinds(kinds, &.{
        .kw_true, .kw_false, .kw_let,
        .kw_and,  .kw_or,    .kw_if,
        .kw_then, .kw_else,
    });
}

test "keyword prefix does not swallow identifier" {
    // 'letter' starts with 'let' but is not a keyword
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toks = try lexRaw(&arena, "letter");
    try std.testing.expectEqual(std.meta.activeTag(toks[0].kind), TokenType.identifier);
    try std.testing.expectEqualStrings("letter", toks[0].kind.identifier);
}

test "spaces and tabs are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "  1   +\t2  ");
    try expectKinds(kinds, &.{ .{ .int_literal = 1 }, .plus, .{ .int_literal = 2 } });
}

test "newlines produce newline tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "1\n2");
    try expectKinds(kinds, &.{ .{ .int_literal = 1 }, .newline, .{ .int_literal = 2 } });
}

test "multiple consecutive newlines produce multiple newline tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "\n\n");
    try expectKinds(kinds, &.{ .newline, .newline });
}

test "empty source produces only EOF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toks = try lexRaw(&arena, "");
    try std.testing.expectEqual(toks.len, 1);
    try std.testing.expectEqual(std.meta.activeTag(toks[0].kind), TokenType.eof);
}

test "single token span starts at offset 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toks = try lexRaw(&arena, "+");
    try std.testing.expectEqual(toks[0].span.start.offset, 0);
}

test "second token span starts after first token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toks = try lexRaw(&arena, "+ +");
    // First `+` is at offset 0; second `+` is at offset 2 (after the space)
    try std.testing.expectEqual(toks[1].span.start.offset, 2);
}

test "token spans carry correct line numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const toks = try lexRaw(&arena, "1\n2");
    try std.testing.expectEqual(toks[0].span.start.line, 1);
    // toks[1] is the newline
    try std.testing.expectEqual(toks[2].span.start.line, 2);
}

test "unknown character returns UnexpectedCharacter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var ctx = context.CompilerContext.init(&arena, "@", "<test>");
    var l = try lexer.Lexer.init(&ctx);
    const result = l.tokenize();
    try std.testing.expectError(error.UnexpectedCharacter, result);
}

test "let binding token stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "let x = 1");
    try expectKinds(kinds, &.{ .kw_let, .{ .identifier = "" }, .equal, .{ .int_literal = 1 } });
}

test "function type signature token stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // add: Int × Int -> Int
    const kinds = try lex(&arena, "add: Int \u{00D7} Int -> Int");
    try expectKinds(kinds, &.{
        .{ .identifier = "" }, .colon,
        .{ .identifier = "" }, .cross,
        .{ .identifier = "" }, .right_arrow,
        .{ .identifier = "" },
    });
}

test "function definition token stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "add x y => x + y");
    try expectKinds(kinds, &.{
        .{ .identifier = "" }, .{ .identifier = "" }, .{ .identifier = "" },
        .double_right_arrow,   .{ .identifier = "" }, .plus,
        .{ .identifier = "" },
    });
}

test "if-then-else token stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const kinds = try lex(&arena, "if true then 1 else 2");
    try expectKinds(kinds, &.{
        .kw_if,                .kw_true, .kw_then,
        .{ .int_literal = 1 }, .kw_else, .{ .int_literal = 2 },
    });
}
