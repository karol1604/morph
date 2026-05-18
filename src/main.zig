const std = @import("std");

const zspan = @import("zspan");

pub const ast = @import("ast.zig");
pub const checked_ast = @import("checked_ast.zig");
pub const checker = @import("checker.zig");
pub const codegen = @import("codegen.zig");
pub const context = @import("context.zig");
pub const CompilerContext = context.CompilerContext;
pub const ir = @import("ir.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const Span = @import("span.zig").Span;
const tail_call_analyzer = @import("tail_call_analyzer.zig");
pub const targ = @import("target.zig");
pub const tok = @import("token.zig");
pub const type_store = @import("type_store.zig");
pub const utils = @import("utils.zig");

const Args = struct {
    path: []const u8,
    verbose: bool = false,
};

fn parseArgs(args: *std.process.Args.Iterator) void {
    _ = args.next(); // skip program name

    var res = Args{ .path = undefined };
    var got_path = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            res.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown flag: {s}\n", .{arg});
            return error.InvalidArgument;
        } else {
            res.path = arg;
            got_path = true;
        }
    }

    if (!got_path) {
        std.debug.print("Usage: morph [options] <file>\n", .{});
        std.debug.print("  -o <path>     output binary path\n", .{});
        std.debug.print("  -v, --verbose show tokens, IR, type store\n", .{});
        return error.InvalidArgs;
    }

    return res;
}

fn printDiagnostics(ctx: *CompilerContext, writer: *std.Io.Writer) !void {
    for (ctx.diagnostics.items) |diag| {
        try zspan.displayDiagnostic(
            diag,
            &[_]zspan.SourceFile{ctx.source_file},
            writer,
            ctx.allocator,
        );
    }
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
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
    // const source = @embedFile("tests/test.mp");

    var args = try init.minimal.args.iterateAllocator(arena.allocator());

    _ = args.next(); // skip program name

    const path = args.next() orelse {
        std.debug.print("Usage: program <path>\n", .{});
        return;
    };

    var source: ?[]const u8 = null;

    if (std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only })) |file| {
        defer file.close(io);

        const buf = try alloc.alloc(u8, try file.length(io));

        var reader = file.reader(io, buf);
        reader.interface.readSliceAll(buf) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };

        source = buf;
    } else |err| switch (err) {
        error.FileNotFound, error.AccessDenied => {
            std.debug.print("cannot open file: {}\n", .{err});
        },
        else => return err,
    }

    // add : ℕ × ℕ -> ℕ;
    // add(x, y) => x + y;

    // unsafe unwrap here
    var ctx = context.CompilerContext.init(&arena, source.?, "test.mp");
    defer ctx.deinit();

    var lex = lexer.Lexer.init(&ctx) catch return error.LexerInitFailed;
    const tokens = try lex.tokenize();

    // std.debug.print("Tokens:\n", .{});
    // for (tokens, 0..) |token, idx| {
    //     std.debug.print("  {d}: {f}\n", .{ idx, token });
    // }

    var pars = parser.Parser.init(tokens, &ctx);

    const exprs = try pars.parse();
    // std.debug.print("Expression(s):\n", .{});
    // for (exprs) |expr| {
    //     std.debug.print("- ", .{});
    //     utils.prettyPrintExpression(expr.*);
    // }

    var check = try checker.Checker.init(&ctx, exprs);
    const checked_exprs = try check.check();

    ctx.attachTypeStore(&check.type_store);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (ctx.hasErrors()) {
        std.debug.print("\nCompilation failed with errors:\n", .{});
        try printDiagnostics(&ctx, stdout);
        try stdout.flush();
        return error.CompilationFailed;
    }

    try printDiagnostics(&ctx, stdout);

    for (checked_exprs) |expr| {
        std.debug.print("- ", .{});
        utils.prettyPrintCheckedExpression(&expr.*);
    }

    var tca = tail_call_analyzer.init(ctx.allocator);
    try tca.analyze(checked_exprs);

    var tc_it = tca.tail_calls.keyIterator();
    std.debug.print("Tail call positions:\n", .{});
    while (tc_it.next()) |key| {
        std.debug.print("  - {d}\n", .{key.*});
    }

    var ir_gen = ir.IRGen.init(&ctx, &tca.tail_calls);
    try ir_gen.generate(checked_exprs);

    std.debug.print("************\n", .{});
    std.debug.print("Type Store:\n{f}", .{check.type_store});
    std.debug.print("************\n", .{});
    std.debug.print("Checked Expression(s):\n", .{});

    ir_gen.dump();

    const target = targ.Target.current();
    std.debug.print("Current target: {f} {f}\n", .{ target.arch, target.os });
    var code_gen = codegen.CodeGen.init(&ctx, target, &ir_gen);
    try code_gen.generate();

    const asm_path = "/Users/karol/projects/morph/tmp/out.s";
    const bin_path = "/Users/karol/projects/morph/tmp/out";
    try code_gen.writeToFile(asm_path, io);
    try assembleAndLink(io, arena.allocator(), asm_path, bin_path);

    // std.debug.print("Generated IR({d}):\n", .{instructions.len});
    // for (instructions) |instr| {
    //     std.debug.print("{f}", .{instr});
    // }
}

fn assembleAndLink(
    io: std.Io,
    allocator: std.mem.Allocator,
    asmPath: []const u8,
    outPath: []const u8,
) !void {
    // assemble
    const obj_path = "/tmp/out.o";
    const as_result = try std.process.run(allocator, io, .{
        .argv = &.{ "as", "-g", "-o", obj_path, asmPath },
    });
    if (as_result.term.exited != 0) {
        std.debug.print("Assembler error:\n{s}\n", .{as_result.stderr});
        return error.AssemblerFailed;
    }

    // link
    const sdk_path = try getSdkPath(io, allocator);
    const ld_res = try std.process.run(allocator, io, .{
        .argv = &.{
            "ld",
            "-o",
            outPath,
            obj_path,
            "-lSystem",
            "-syslibroot",
            sdk_path,
            "-e",
            "_main",
            "-arch",
            "arm64",
            "/Users/karol/projects/morph/src/tests/runtime.o",
        },
    });
    if (ld_res.term.exited != 0) {
        std.debug.print("Linker error:\n{s}\n", .{ld_res.stderr});
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
