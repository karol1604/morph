const std = @import("std");
const morph = @import("morph");
const lexer = morph.lexer;
const parser = morph.parser;
const context = morph.context;
const ast = morph.ast;

const ExprKind = ast.ExprKind;
const BinaryOperator = ast.BinaryOperator;
const UnaryOperator = ast.UnaryOperator;

fn parse(arena: *std.heap.ArenaAllocator, source: []const u8) ![]*const ast.Expr {
    var ctx = context.CompilerContext.init(arena, source, "<test>");
    var l = try lexer.Lexer.init(&ctx);
    const toks = try l.tokenize();
    var p = parser.Parser.init(toks, &ctx);
    return try p.parse();
}

fn parseOne(arena: *std.heap.ArenaAllocator, source: []const u8) !*const ast.Expr {
    const exprs = try parse(arena, source);
    try std.testing.expectEqual(@as(usize, 1), exprs.len);
    return exprs[0];
}

test "integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "42");
    try std.testing.expectEqual(expr.kind.int_literal, 42);
}

test "negative integer via unary minus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "-7");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.unary);
    try std.testing.expectEqual(expr.kind.unary.operator, UnaryOperator.minus);
    try std.testing.expectEqual(expr.kind.unary.right.kind.int_literal, 7);
}

test "bool literal true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "true");
    try std.testing.expectEqual(expr.kind.bool_literal, true);
}

test "bool literal false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "false");
    try std.testing.expectEqual(expr.kind.bool_literal, false);
}

test "unit literal ()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "()");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.unit_literal);
}

test "simple addition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "1 + 2");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.binary);
    try std.testing.expectEqual(expr.kind.binary.operator, BinaryOperator.plus);
    try std.testing.expectEqual(expr.kind.binary.left.kind.int_literal, 1);
    try std.testing.expectEqual(expr.kind.binary.right.kind.int_literal, 2);
}

test "multiplication binds tighter than addition — root is +" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 1 + 2 * 3  =>  +(1, *(2, 3))
    const expr = try parseOne(&arena, "1 + 2 * 3");
    try std.testing.expectEqual(expr.kind.binary.operator, BinaryOperator.plus);
    try std.testing.expectEqual(expr.kind.binary.right.kind.binary.operator, BinaryOperator.multiply);
}

test "exponentiation is right-associative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 2 ^ 3 ^ 4  =>  ^(2, ^(3, 4))
    const expr = try parseOne(&arena, "2 ^ 3 ^ 4");
    try std.testing.expectEqual(expr.kind.binary.operator, BinaryOperator.exponent);
    try std.testing.expectEqual(expr.kind.binary.right.kind.binary.operator, BinaryOperator.exponent);
}

test "comparison operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lt = try parseOne(&arena, "1 < 2");
    try std.testing.expectEqual(lt.kind.binary.operator, BinaryOperator.less_than);

    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();
    const lte = try parseOne(&arena2, "1 <= 2");
    try std.testing.expectEqual(lte.kind.binary.operator, BinaryOperator.less_than_or_eq);
}

test "equality operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const eq = try parseOne(&arena, "a == b");
    try std.testing.expectEqual(eq.kind.binary.operator, BinaryOperator.equal);

    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();
    const neq = try parseOne(&arena2, "a != b");
    try std.testing.expectEqual(neq.kind.binary.operator, BinaryOperator.not_equal);
}

test "logical and / or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const and_expr = try parseOne(&arena, "true and false");
    try std.testing.expectEqual(and_expr.kind.binary.operator, BinaryOperator.logical_and);

    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();
    const or_expr = try parseOne(&arena2, "true or false");
    try std.testing.expectEqual(or_expr.kind.binary.operator, BinaryOperator.logical_or);
}

test "parentheses override precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // (1 + 2) * 3  =>  *(+(1,2), 3)
    const expr = try parseOne(&arena, "(1 + 2) * 3");
    try std.testing.expectEqual(expr.kind.binary.operator, BinaryOperator.multiply);
    try std.testing.expectEqual(expr.kind.binary.left.kind.binary.operator, BinaryOperator.plus);
}

test "unary not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "!true");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.unary);
    try std.testing.expectEqual(expr.kind.unary.operator, UnaryOperator.not);
    try std.testing.expectEqual(expr.kind.unary.right.kind.bool_literal, true);
}

test "unary plus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "+5");
    try std.testing.expectEqual(expr.kind.unary.operator, UnaryOperator.plus);
}

test "let binding without type annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "let x = 1");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.variable_decl);
    try std.testing.expectEqualStrings("x", expr.kind.variable_decl.name);
    try std.testing.expectEqual(expr.kind.variable_decl.value.kind.int_literal, 1);
    try std.testing.expectEqual(expr.kind.variable_decl.type, null);
}

test "let binding with type annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "let x \u{2208} Int = 42");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.variable_decl);
    try std.testing.expectEqualStrings("x", expr.kind.variable_decl.name);
    try std.testing.expect(expr.kind.variable_decl.type != null);
    const type_name = expr.kind.variable_decl.type.?.kind.named;
    try std.testing.expectEqualStrings("Int", type_name);
}

test "identifier expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "foo");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.identifier);
    try std.testing.expectEqualStrings("foo", expr.kind.identifier);
}

test "function call with arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "add(1, 2)");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.func_call);
    try std.testing.expectEqualStrings("add", expr.kind.func_call.callee);
    try std.testing.expectEqual(@as(usize, 2), expr.kind.func_call.args.len);
    try std.testing.expectEqual(expr.kind.func_call.args[0].kind.int_literal, 1);
    try std.testing.expectEqual(expr.kind.func_call.args[1].kind.int_literal, 2);
}

test "function call with no arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "foo()");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.func_call);
    try std.testing.expectEqual(@as(usize, 0), expr.kind.func_call.args.len);
}

test "function definition with two params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "add x y => x + y");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.func_def);
    try std.testing.expectEqualStrings("add", expr.kind.func_def.name);
    try std.testing.expectEqual(@as(usize, 2), expr.kind.func_def.params.len);
    try std.testing.expectEqualStrings("x", expr.kind.func_def.params[0]);
    try std.testing.expectEqualStrings("y", expr.kind.func_def.params[1]);
}

test "function definition with no params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "answer => 42");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.func_def);
    try std.testing.expectEqual(@as(usize, 0), expr.kind.func_def.params.len);
    try std.testing.expectEqual(expr.kind.func_def.body.kind.int_literal, 42);
}

test "function type signature simple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "add: Int -> Int");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.func_type_signature);
    try std.testing.expectEqualStrings("add", expr.kind.func_type_signature.name);

    const fn_type = expr.kind.func_type_signature.ty;
    const domain = fn_type.kind.function.domain;
    const codomain = fn_type.kind.function.codomain;
    try std.testing.expectEqualStrings("Int", domain.kind.named);
    try std.testing.expectEqualStrings("Int", codomain.kind.named);
}

test "function type signature with product domain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // add: Int × Int -> Bool
    const expr = try parseOne(&arena, "add: Int \u{00D7} Int -> Bool");
    const fn_type = expr.kind.func_type_signature.ty;
    try std.testing.expectEqual(std.meta.activeTag(fn_type.kind), ast.TypeExprKind.function);
    try std.testing.expectEqual(std.meta.activeTag(fn_type.kind.function.domain.kind), ast.TypeExprKind.product);
    try std.testing.expectEqualStrings("Bool", fn_type.kind.function.codomain.kind.named);
}

test "empty block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "{}");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.block);
    try std.testing.expectEqual(@as(usize, 0), expr.kind.block.stmts.len);
    try std.testing.expectEqual(expr.kind.block.tail, null);
}

test "block with only a tail expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "{ 42 }");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.block);
    try std.testing.expectEqual(@as(usize, 0), expr.kind.block.stmts.len);
    try std.testing.expectEqual(expr.kind.block.tail.?.kind.int_literal, 42);
}

test "block with statements and a tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "{ let a = 1; a }");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.block);
    try std.testing.expectEqual(@as(usize, 1), expr.kind.block.stmts.len);
    try std.testing.expectEqual(std.meta.activeTag(expr.kind.block.stmts[0].kind), ExprKind.variable_decl);
    try std.testing.expectEqualStrings("a", expr.kind.block.tail.?.kind.identifier);
}

test "if-then-else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "if true then 1 else 2");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.@"if");
    try std.testing.expectEqual(expr.kind.@"if".condition.kind.bool_literal, true);
    try std.testing.expectEqual(expr.kind.@"if".then_branch.kind.int_literal, 1);
    try std.testing.expectEqual(expr.kind.@"if".else_branch.?.kind.int_literal, 2);
}

test "if-then without else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const expr = try parseOne(&arena, "if true then { 1 }");
    try std.testing.expectEqual(std.meta.activeTag(expr.kind), ExprKind.@"if");
    try std.testing.expectEqual(expr.kind.@"if".else_branch, null);
}

test "semicolon separates two top-level expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const exprs = try parse(&arena, "1; 2");
    try std.testing.expectEqual(@as(usize, 2), exprs.len);
    try std.testing.expectEqual(exprs[0].kind.int_literal, 1);
    try std.testing.expectEqual(exprs[1].kind.int_literal, 2);
}

test "newline separates two top-level expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const exprs = try parse(&arena, "1\n2");
    try std.testing.expectEqual(@as(usize, 2), exprs.len);
}

test "unclosed left paren returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = parse(&arena, "(1 + 2");
    try std.testing.expectError(error.UnclosedLParen, result);
}

test "let in value position returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = parse(&arena, "1 + let x = 2");
    try std.testing.expectError(error.LetInValuePosition, result);
}
