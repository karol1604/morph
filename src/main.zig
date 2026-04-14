const std = @import("std");
const context = @import("context.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const checker = @import("checker.zig");
const ir = @import("ir.zig");
const parserTests = @import("tests/parser.zig");
const utils = @import("utils.zig");
const Span = @import("span.zig").Span;
const CompilerContext = context.CompilerContext;
const codegen = @import("codegen.zig");
const targ = @import("target.zig");

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
        printSnippet(ctx.source, diag.span, 2);
    }
}

fn printSnippet(source: []const u8, span: Span, context_lines: usize) void {
    var line_start = span.start.offset;
    while (line_start > 0 and source[line_start - 1] != '\n') : (line_start -= 1) {}

    var line_end = span.start.offset;
    while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}

    var ctx_start = line_start;
    var lines_found: usize = 0;
    while (lines_found < context_lines and ctx_start > 0) {
        ctx_start -= 1;
        if (source[ctx_start] == '\n') {
            lines_found += 1;
        }
    }
    if (source[ctx_start] == '\n') ctx_start += 1;

    if (ctx_start < line_start) {
        var it = std.mem.splitScalar(u8, source[ctx_start..line_start], '\n');
        while (it.next()) |ctx_line| {
            if (ctx_line.len > 0) std.debug.print("    {s}\n", .{ctx_line});
        }
    }

    const error_line = source[line_start..line_end];
    std.debug.print("    {s}\n", .{error_line});

    const underline_len = @max(1, span.end.col - span.start.col);
    std.debug.print("    ", .{});

    const padding = span.start.offset - line_start;

    var i: usize = 0;
    while (i < padding) : (i += 1) {
        std.debug.print(" ", .{});
    }
    i = 0;
    while (i < underline_len) : (i += 1) {
        std.debug.print("^", .{});
    }
    std.debug.print("\n", .{});

    var ctx_idx = line_end;
    if (ctx_idx < source.len) ctx_idx += 1; // Skip the newline of the error line itself

    lines_found = 0;
    while (lines_found < context_lines and ctx_idx < source.len) {
        // Find end of this specific context line
        var current_ctx_end = ctx_idx;
        while (current_ctx_end < source.len and source[current_ctx_end] != '\n') : (current_ctx_end += 1) {}

        const ctx_line = source[ctx_idx..current_ctx_end];
        std.debug.print("    {s}\n", .{ctx_line});

        ctx_idx = current_ctx_end + 1; // Move past the newline
        lines_found += 1;
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // const source = "ℕ";
    // const source = "let ℕ = a != true;";
    // const source = "let x ∈ Vec3 = { let a = 1; };";
    // const source = "let a = 1; let x ∈ Vec3 = { let a = 1; a == 1; x + 1 / 2; a };";
    // const source = "add1 : Int × Int -> Bool; add2 : Int × Int -> Bool; add1; add2";
    // const source = "let x ∈ Bool = 1 <= 1 and !false; x;";
    // const source =
    //     \\add: Int × Int -> Int;
    //     \\let Int = 1;
    //     \\add(x, y) => x + y;;
    // ;
    const source = @embedFile("tests/test.mp");

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

    var irGen = ir.IRGen.init(&ctx);
    try irGen.generate(checkedExprs);

    std.debug.print("************\n", .{});
    std.debug.print("Type Store:\n{f}", .{check.typeStore});
    std.debug.print("************\n", .{});
    std.debug.print("Checked Expression(s):\n", .{});
    for (checkedExprs) |expr| {
        std.debug.print("- ", .{});
        utils.prettyPrintCheckedExpression(&expr.*);
    }

    irGen.dump();

    const target = targ.Target.current();
    std.debug.print("Current target: {f} {f}\n", .{ target.arch, target.os });
    var codeGen = codegen.CodeGen.init(&ctx, target, &irGen);
    try codeGen.generate();

    const asmPath = "/Users/karol/projects/morph/tmp/out.s";
    const binPath = "/Users/karol/projects/morph/tmp/out";
    try codeGen.writeToFile(asmPath);
    try assembleAndLink(arena.allocator(), asmPath, binPath);

    // std.debug.print("Generated IR({d}):\n", .{instructions.len});
    // for (instructions) |instr| {
    //     std.debug.print("{f}", .{instr});
    // }
}

test "Tests" {
    std.testing.refAllDecls(parserTests);
}

fn assembleAndLink(allocator: std.mem.Allocator, asmPath: []const u8, outPath: []const u8) !void {
    // assemble
    const objPath = "/tmp/out.o";
    const asResult = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "as", "-o", objPath, asmPath },
    });
    if (asResult.term.Exited != 0) {
        std.debug.print("Assembler error:\n{s}\n", .{asResult.stderr});
        return error.AssemblerFailed;
    }

    // link
    const sdkPath = try getSdkPath(allocator);
    const ldResult = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "ld",
            "-o",
            outPath,
            objPath,
            "-lSystem",
            "-syslibroot",
            sdkPath,
            "-e",
            "_main",
            "-arch",
            "arm64",
        },
    });
    if (ldResult.term.Exited != 0) {
        std.debug.print("Linker error:\n{s}\n", .{ldResult.stderr});
        return error.LinkerFailed;
    }

    std.debug.print("Binary written to {s}\n", .{outPath});
}

fn getSdkPath(allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
    });
    // trim the trailing newline
    return std.mem.trimRight(u8, result.stdout, "\n");
}
