const std = @import("std");

const checker = @import("checker.zig");
const codegen = @import("codegen.zig");
const context = @import("context.zig");
const CompilerContext = context.CompilerContext;
const ir = @import("ir.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const Span = @import("span.zig").Span;
const targ = @import("target.zig");
const parserTests = @import("tests/parser.zig");
const utils = @import("utils.zig");
const zspan = @import("zspan");

fn printDiagnostics(ctx: *CompilerContext, writer: *std.Io.Writer) !void {
    for (ctx.diagnostics.items) |diag| {
        try zspan.displayDiagnostic(diag, &[_]zspan.SourceFile{ctx.sourceFile}, writer, ctx.allocator);
    }
}

pub fn main(init: std.process.Init) !void {
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
    const io = init.io;
    const source = @embedFile("tests/test.mp");

    // add : ℕ × ℕ -> ℕ;
    // add(x, y) => x + y;

    var ctx = context.CompilerContext.init(&arena, source, "test.mp");
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

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (ctx.hasErrors()) {
        std.debug.print("\nCompilation failed with errors:\n", .{});
        try printDiagnostics(&ctx, stdout);
        try stdout.flush();
        return error.CompilationFailed;
    }

    for (checkedExprs) |expr| {
        std.debug.print("- ", .{});
        utils.prettyPrintCheckedExpression(&expr.*);
    }

    var irGen = ir.IRGen.init(&ctx);
    try irGen.generate(checkedExprs);

    std.debug.print("************\n", .{});
    std.debug.print("Type Store:\n{f}", .{check.typeStore});
    std.debug.print("************\n", .{});
    std.debug.print("Checked Expression(s):\n", .{});

    irGen.dump();

    const target = targ.Target.current();
    std.debug.print("Current target: {f} {f}\n", .{ target.arch, target.os });
    var codeGen = codegen.CodeGen.init(&ctx, target, &irGen);
    try codeGen.generate();

    const asmPath = "/Users/karol/projects/morph/tmp/out.s";
    const binPath = "/Users/karol/projects/morph/tmp/out";
    try codeGen.writeToFile(asmPath, io);
    try assembleAndLink(io, arena.allocator(), asmPath, binPath);

    // std.debug.print("Generated IR({d}):\n", .{instructions.len});
    // for (instructions) |instr| {
    //     std.debug.print("{f}", .{instr});
    // }
}

test "Tests" {
    std.testing.refAllDecls(parserTests);
}

fn assembleAndLink(
    io: std.Io,
    allocator: std.mem.Allocator,
    asmPath: []const u8,
    outPath: []const u8,
) !void {
    // assemble
    const objPath = "/tmp/out.o";
    const asResult = try std.process.run(allocator, io, .{
        .argv = &.{ "as", "-g", "-o", objPath, asmPath },
    });
    if (asResult.term.exited != 0) {
        std.debug.print("Assembler error:\n{s}\n", .{asResult.stderr});
        return error.AssemblerFailed;
    }

    // link
    const sdkPath = try getSdkPath(io, allocator);
    const ldResult = try std.process.run(allocator, io, .{
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
    if (ldResult.term.exited != 0) {
        std.debug.print("Linker error:\n{s}\n", .{ldResult.stderr});
        return error.LinkerFailed;
    }

    std.debug.print("Binary written to {s}\n", .{outPath});
}

fn getSdkPath(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
    });
    // trim the trailing newline
    return std.mem.trimEnd(u8, result.stdout, "\n");
}
