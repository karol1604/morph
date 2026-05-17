const std = @import("std");
const morph = @import("morph");

const type_store = morph.type_store;
const checked_ast = morph.checked_ast;
const context = morph.context;
const checker = morph.checker;
const lexer = morph.lexer;
const parser = morph.parser;

const TypeId = type_store.TypeId;
const CheckedExprKind = checked_ast.CheckedExprKind;

const CheckResult = struct {
    exprs: []*checked_ast.CheckedExpr,
    ctx: context.CompilerContext,
    check: checker.Checker,
};

fn check(arena: *std.heap.ArenaAllocator, source: []const u8) !CheckResult {
    var ctx = context.CompilerContext.init(arena, source, "<test>");

    var l = try lexer.Lexer.init(&ctx);
    const toks = try l.tokenize();

    var p = parser.Parser.init(toks, &ctx);
    const exprs = try p.parse();

    var chk = try checker.Checker.init(&ctx, exprs);
    const checked_exprs = try chk.check();

    ctx.attachTypeStore(&chk.type_store);

    return .{ .exprs = checked_exprs, .ctx = ctx, .check = chk };
}

fn checkOne(arena: *std.heap.ArenaAllocator, source: []const u8) !CheckResult {
    const res = try check(arena, source);
    try std.testing.expectEqual(@as(usize, 1), res.exprs.len);
    return res;
}

test "integer literal gets Int type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "42");
    try std.testing.expectEqual(res.check.type_store.builtins.int, res.exprs[0].type_id);
}

test "bool literal true gets Bool type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "true");
    try std.testing.expectEqual(res.check.type_store.builtins.bool, res.exprs[0].type_id);
}

test "bool literal false gets Bool type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "false");
    try std.testing.expectEqual(res.check.type_store.builtins.bool, res.exprs[0].type_id);
}

test "unit literal gets Unit type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "()");
    try std.testing.expectEqual(res.check.type_store.builtins.unit, res.exprs[0].type_id);
}

test "addition of ints returns Int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "1 + 2");
    try std.testing.expectEqual(res.check.type_store.builtins.int, res.exprs[0].type_id);
}

test "arithmetic type mismatch emits error and produces Error type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // true + 1 — left operand is Bool, expected Int
    const res = try check(&arena, "true + 1");
    try std.testing.expect(res.ctx.hasErrors());
    try std.testing.expectEqual(res.check.type_store.builtins.err, res.exprs[0].type_id);
}

test "comparison of ints returns Bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "1 < 2");
    try std.testing.expectEqual(res.check.type_store.builtins.bool, res.exprs[0].type_id);
}

test "equality of same types returns Bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "1 == 1");
    try std.testing.expectEqual(res.check.type_store.builtins.bool, res.exprs[0].type_id);
}

test "equality type mismatch emits error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "1 == true");
    try std.testing.expect(res.ctx.hasErrors());
}

test "logical and of bools returns Bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "true and false");
    try std.testing.expectEqual(res.check.type_store.builtins.bool, res.exprs[0].type_id);
}

test "logical or with non-bool emits error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "1 or false");
    try std.testing.expect(res.ctx.hasErrors());
}

test "unary minus on Int returns Int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "-5");
    try std.testing.expectEqual(res.check.type_store.builtins.int, res.exprs[0].type_id);
}

test "unary not on Bool returns Bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "!true");
    try std.testing.expectEqual(res.check.type_store.builtins.bool, res.exprs[0].type_id);
}

test "unary not on Int emits error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "!1");
    try std.testing.expect(res.ctx.hasErrors());
}

test "unary minus on Bool emits error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "-true");
    try std.testing.expect(res.ctx.hasErrors());
}

test "variable declaration infers type from value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "let x = 1");
    try std.testing.expect(!res.ctx.hasErrors());
}

test "variable declaration with matching type annotation is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "let x \u{2208} Int = 42");
    try std.testing.expect(!res.ctx.hasErrors());
}

test "variable declaration with wrong type annotation emits error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "let x \u{2208} Bool = 42");
    try std.testing.expect(res.ctx.hasErrors());
}

test "variable is accessible after declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "let x = 1; x");
    try std.testing.expect(!res.ctx.hasErrors());
    try std.testing.expectEqual(res.check.type_store.builtins.int, res.exprs[1].type_id);
}

test "undefined variable reference emits error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "undefined_var");
    try std.testing.expect(res.ctx.hasErrors());
}

test "variable declared in block is not accessible outside" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `a` is declared inside the block but referenced outside
    const res = try check(&arena, "{ let a = 1 }; a");
    try std.testing.expect(res.ctx.hasErrors());
}

test "duplicate variable declaration emits error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "let x = 1; let x = 2");
    try std.testing.expect(res.ctx.hasErrors());
}

test "block tail type propagates as block type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "{ let a = 1; a }");
    try std.testing.expect(!res.ctx.hasErrors());
    try std.testing.expectEqual(res.check.type_store.builtins.int, res.exprs[0].type_id);
}

test "empty block has Unit type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "{}");
    try std.testing.expectEqual(res.check.type_store.builtins.unit, res.exprs[0].type_id);
}

test "if-then-else with matching branch types is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try checkOne(&arena, "if true then 1 else 2");
    try std.testing.expect(!res.ctx.hasErrors());
    try std.testing.expectEqual(res.check.type_store.builtins.int, res.exprs[0].type_id);
}

test "if-then-else with mismatched branch types emits error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "if true then 1 else false");
    try std.testing.expect(res.ctx.hasErrors());
}

test "if condition must be Bool — Int condition emits error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "if 1 then 2 else 3");
    try std.testing.expect(res.ctx.hasErrors());
}

test "if-then without else requires Unit body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A block that returns Int without an else branch should produce an error
    const res = try check(&arena, "if true then { 42 }");
    try std.testing.expect(res.ctx.hasErrors());
}

test "if-then without else with Unit body is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "if true then { () }");
    try std.testing.expect(!res.ctx.hasErrors());
}

// test "function type signature is accepted without error" {
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//
//     const res = try checkOne(&arena, "add: Int -> Int");
//     try std.testing.expect(!res.ctx.hasErrors());
// }

test "duplicate function signature emits error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "add: Int -> Int; add: Int -> Bool");
    try std.testing.expect(res.ctx.hasErrors());
}

test "function definition consistent with prior signature is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "add: Int \u{00D7} Int -> Int\nadd x y => x + y");
    try std.testing.expect(!res.ctx.hasErrors());
}

test "function body type must match declared return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Declared to return Int but body is a Bool
    const res = try check(&arena, "f: Int -> Bool\nf x => x + 1");
    try std.testing.expect(res.ctx.hasErrors());
}

test "Scope.lookupSymbol finds symbol in parent scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const dummy_span = morph.Span{
        .start = .{ .offset = 0, .line = 1, .col = 1 },
        .end = .{ .offset = 0, .line = 1, .col = 1 },
    };

    _ = alloc;
    _ = dummy_span;

    const res = try check(&arena, "let x = 1; { x }");
    try std.testing.expect(!res.ctx.hasErrors());
}

test "Scope: symbol defined in child is not visible in parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const res = try check(&arena, "{ let inner = 5 }; inner");
    try std.testing.expect(res.ctx.hasErrors());
}
