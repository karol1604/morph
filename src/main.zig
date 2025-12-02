const std = @import("std");
const context = @import("context.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const checker = @import("checker.zig");
const parserTests = @import("tests/parser.zig");
const utils = @import("utils.zig");
const Span = @import("span.zig").Span;
const CompilerContext = context.CompilerContext;

fn printDiagnostics(ctx: *CompilerContext) void {
    for (ctx.diagnostics.items) |diag| {
        std.debug.print(
            "<input>:{d}:{d}: {t}: {s}\n",
            .{
                diag.span.start.line,
                diag.span.start.col,
                diag.severity,
                diag.message,
            },
        );
        printSnippet(ctx.source, diag.span);
    }
}

fn printSnippet(source: []const u8, span: Span) void {
    // 1. Find line start and end in `source` using span.start.offset
    var line_start: usize = span.start.offset;
    while (line_start > 0 and source[line_start - 1] != '\n') : (line_start -= 1) {}

    var line_end: usize = span.start.offset;
    while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

    const line = source[line_start..line_end];
    std.debug.print("    {s}\n", .{line});

    // 2. Underline the span
    const underline_len = @max(1, span.end.col - span.start.col);
    std.debug.print("    ", .{});
    // spaces before the caret
    var i: usize = 0;
    // std.debug.print("num: {d}\n", .{line_start});
    while (i < span.start.col - 1 - line_start) : (i += 1) {
        std.debug.print(" ", .{});
    }
    // carets
    i = 0;
    while (i < underline_len) : (i += 1) {
        std.debug.print("^", .{});
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // const source = "ℕ";
    // const source = "let ℕ = a != true;";
    // const source = "let x ∈ Vec3 = { let a = 1; };";
    // const source = "let a = 1; let x ∈ Vec3 = { let a = 1; a == 1; x + 1 / 2; a };";
    const source = "add1 : Int × Int -> Bool; add2 : Int × Int -> Bool; add1; add2";
    // const source = "let x ∈ Bool = 1 <= 1 and !false; x;";

    // add : ℕ × ℕ -> ℕ;
    // add(x, y) => x + y;

    var ctx = context.CompilerContext.init(&arena, source);
    defer ctx.deinit();

    var lex = lexer.Lexer.init(&ctx) catch return error.LexerInitFailed;
    const tokens = try lex.tokenize();

    std.debug.print("Tokens:\n", .{});
    for (tokens, 0..) |token, idx| {
        std.debug.print("  {d}: {f}\n", .{ idx, token });
    }

    var pars = parser.Parser.init(tokens, &ctx);

    const exprs = try pars.parse();
    std.debug.print("Expression(s):\n", .{});
    for (exprs) |expr| {
        std.debug.print("- ", .{});
        utils.prettyPrintExpression(expr.*);
    }

    var check = try checker.Checker.init(&ctx, exprs);
    const checkedExprs = try check.check();

    if (ctx.hasErrors()) {
        std.debug.print("\nCompilation failed with errors:\n", .{});
        printDiagnostics(&ctx);
        return error.CompilationFailed;
    }

    std.debug.print("Checked Expression(s): {any}\n", .{checkedExprs[0]});
}

test "Tests" {
    std.testing.refAllDecls(parserTests);
}
