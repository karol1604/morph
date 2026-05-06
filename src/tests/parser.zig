const std = @import("std");
const testing = std.testing;
const context = @import("../context.zig");
const lexer = @import("../lexer.zig");
const parser = @import("../parser.zig");
const ast = @import("../ast.zig");

// Helper to setup parser and parse a single expression
fn parse(arena: *std.heap.ArenaAllocator, source: []const u8) !*ast.Expr {
    const ctx = context.CompilerContext.init(arena, source, "test.mp");
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
    return pars.parseExpression(.lowest);
}

test "precedence: multiplication before addition" {
    // 1 + 2 * 3  ->  (1 + (2 * 3))
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const root = try parse(&arena, "1 + 2 * 3;");

    // Root should be Plus
    try testing.expectEqual(ast.BinaryOperator.plus, root.kind.binary.operator);

    // Left should be 1
    try testing.expectEqual(@as(i64, 1), root.kind.binary.left.kind.int_literal);

    // Right should be (2 * 3)
    const right = root.kind.binary.right;
    try testing.expectEqual(ast.BinaryOperator.multiply, right.kind.binary.operator);
    try testing.expectEqual(@as(i64, 2), right.kind.binary.left.kind.int_literal);
    try testing.expectEqual(@as(i64, 3), right.kind.binary.right.kind.int_literal);
}

test "precedence: grouping overrides" {
    // (1 + 2) * 3
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const root = try parse(&arena, "(1 + 2) * 3");

    // Root should be Multiply
    try testing.expectEqual(ast.BinaryOperator.multiply, root.kind.binary.operator);

    // Left should be (1 + 2)
    const left = root.kind.binary.left;
    try testing.expectEqual(ast.BinaryOperator.plus, left.kind.binary.operator);
    try testing.expectEqual(@as(i64, 1), left.kind.binary.left.kind.int_literal);
    try testing.expectEqual(@as(i64, 2), left.kind.binary.right.kind.int_literal);

    // Right should be 3
    try testing.expectEqual(@as(i64, 3), root.kind.binary.right.kind.int_literal);
}

test "associativity: right associative power" {
    // 2 ^ 3 ^ 4  ->  (2 ^ (3 ^ 4))
    // If it were left associative, it would be ((2 ^ 3) ^ 4)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const root = try parse(&arena, "2 ^ 3 ^ 4");

    // Root is ^
    try testing.expectEqual(ast.BinaryOperator.exponent, root.kind.binary.operator);

    // Left is 2
    try testing.expectEqual(@as(i64, 2), root.kind.binary.left.kind.int_literal);

    // Right is (3 ^ 4)
    const right = root.kind.binary.right;
    try testing.expectEqual(ast.BinaryOperator.exponent, right.kind.binary.operator);
    try testing.expectEqual(@as(i64, 3), right.kind.binary.left.kind.int_literal);
    try testing.expectEqual(@as(i64, 4), right.kind.binary.right.kind.int_literal);
}

test "unary operators" {
    // -5 + !true
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const root = try parse(&arena, "-5 + !true");

    try testing.expectEqual(ast.BinaryOperator.plus, root.kind.binary.operator);

    // Check Left: -5
    const left = root.kind.binary.left;
    try testing.expectEqual(ast.UnaryOperator.minus, left.kind.unary.operator);
    try testing.expectEqual(@as(i64, 5), left.kind.unary.right.kind.int_literal);

    // Check Right: !true
    const right = root.kind.binary.right;
    try testing.expectEqual(ast.UnaryOperator.not, right.kind.unary.operator);
    try testing.expectEqual(true, right.kind.unary.right.kind.bool_literal);
}
