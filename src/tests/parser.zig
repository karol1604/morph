const std = @import("std");
const testing = std.testing;
const context = @import("../context.zig");
const lexer = @import("../lexer.zig");
const parser = @import("../parser.zig");
const ast = @import("../ast.zig");

// Helper to setup parser and parse a single expression
fn parse(arena: *std.heap.ArenaAllocator, source: []const u8) !*ast.Expr {
    const ctx = context.CompilerContext.init(arena, source);
    // Note: In real code, ensure ctx pointer logic is safe.
    // Here we rely on arena to keep memory alive, but ctx is on stack.
    // For tests this is usually fine if parser/lexer don't store &ctx permanently
    // outside the scope, but your structs do store `ctx: *CompilerContext`.
    // So we must allocate Context on heap to be safe, or keep it alive.
    const ctx_ptr = try arena.allocator().create(context.CompilerContext);
    ctx_ptr.* = ctx;

    var lex = try lexer.Lexer.init(ctx_ptr);
    const tokens = try lex.tokenize();

    // Allocate parser on heap or stack? Stack is fine here.
    var pars = parser.Parser.init(tokens, ctx_ptr);
    // Requires parseExpression to be 'pub'
    return pars.parseExpression(.Lowest);
}

test "precedence: multiplication before addition" {
    // 1 + 2 * 3  ->  (1 + (2 * 3))
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const root = try parse(&arena, "1 + 2 * 3");

    // Root should be Plus
    try testing.expectEqual(ast.BinaryOperator.Plus, root.kind.Binary.operator);

    // Left should be 1
    try testing.expectEqual(@as(i64, 1), root.kind.Binary.left.kind.IntLiteral);

    // Right should be (2 * 3)
    const right = root.kind.Binary.right;
    try testing.expectEqual(ast.BinaryOperator.Multiply, right.kind.Binary.operator);
    try testing.expectEqual(@as(i64, 2), right.kind.Binary.left.kind.IntLiteral);
    try testing.expectEqual(@as(i64, 3), right.kind.Binary.right.kind.IntLiteral);
}

test "precedence: grouping overrides" {
    // (1 + 2) * 3
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const root = try parse(&arena, "(1 + 2) * 3");

    // Root should be Multiply
    try testing.expectEqual(ast.BinaryOperator.Multiply, root.kind.Binary.operator);

    // Left should be (1 + 2)
    const left = root.kind.Binary.left;
    try testing.expectEqual(ast.BinaryOperator.Plus, left.kind.Binary.operator);
    try testing.expectEqual(@as(i64, 1), left.kind.Binary.left.kind.IntLiteral);
    try testing.expectEqual(@as(i64, 2), left.kind.Binary.right.kind.IntLiteral);

    // Right should be 3
    try testing.expectEqual(@as(i64, 3), root.kind.Binary.right.kind.IntLiteral);
}

test "associativity: right associative power" {
    // 2 ^ 3 ^ 4  ->  (2 ^ (3 ^ 4))
    // If it were left associative, it would be ((2 ^ 3) ^ 4)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const root = try parse(&arena, "2 ^ 3 ^ 4");

    // Root is ^
    try testing.expectEqual(ast.BinaryOperator.Exponent, root.kind.Binary.operator);

    // Left is 2
    try testing.expectEqual(@as(i64, 2), root.kind.Binary.left.kind.IntLiteral);

    // Right is (3 ^ 4)
    const right = root.kind.Binary.right;
    try testing.expectEqual(ast.BinaryOperator.Exponent, right.kind.Binary.operator);
    try testing.expectEqual(@as(i64, 3), right.kind.Binary.left.kind.IntLiteral);
    try testing.expectEqual(@as(i64, 4), right.kind.Binary.right.kind.IntLiteral);
}

test "unary operators" {
    // -5 + !true
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const root = try parse(&arena, "-5 + !true");

    try testing.expectEqual(ast.BinaryOperator.Plus, root.kind.Binary.operator);

    // Check Left: -5
    const left = root.kind.Binary.left;
    try testing.expectEqual(ast.UnaryOperator.Minus, left.kind.Unary.operator);
    try testing.expectEqual(@as(i64, 5), left.kind.Unary.right.kind.IntLiteral);

    // Check Right: !true
    const right = root.kind.Binary.right;
    try testing.expectEqual(ast.UnaryOperator.Not, right.kind.Unary.operator);
    try testing.expectEqual(true, right.kind.Unary.right.kind.BoolLiteral);
}
