const std = @import("std");
const build_options = @import("build_options");
const compiler_path = build_options.compiler_path;

const Case = struct {
    source: []const u8,
    expected_exit: u8,
};

const cases = [_]Case{
    .{ .source = "tests/e2e/cases/001-empty.mp", .expected_exit = 0 },
    .{ .source = "tests/e2e/cases/002-exit_constant.mp", .expected_exit = 69 },
    .{ .source = "tests/e2e/cases/003-basic_arithmetic.mp", .expected_exit = 9 },
    .{ .source = "tests/e2e/cases/004-simple_function_call.mp", .expected_exit = 69 },
    .{ .source = "tests/e2e/cases/005-variable_assignment.mp", .expected_exit = 12 },
    .{ .source = "tests/e2e/cases/006-if_true.mp", .expected_exit = 0 },
    .{ .source = "tests/e2e/cases/007-fib.mp", .expected_exit = 55 },
    .{ .source = "tests/e2e/cases/008-fib_add.mp", .expected_exit = 55 },
    .{ .source = "tests/e2e/cases/010-unary_minus.mp", .expected_exit = 7 },
    .{ .source = "tests/e2e/cases/011-not_condition.mp", .expected_exit = 42 },
    .{ .source = "tests/e2e/cases/012-nested_if.mp", .expected_exit = 42 },
    .{ .source = "tests/e2e/cases/013-if_as_value.mp", .expected_exit = 50 },
    .{ .source = "tests/e2e/cases/014-block_scope.mp", .expected_exit = 18 },
    .{ .source = "tests/e2e/cases/015-block_in_function.mp", .expected_exit = 42 },
    .{ .source = "tests/e2e/cases/017-comparisons.mp", .expected_exit = 1 },
    .{ .source = "tests/e2e/cases/018-equality.mp", .expected_exit = 42 },
    .{ .source = "tests/e2e/cases/019-logical_ops.mp", .expected_exit = 42 },
    .{ .source = "tests/e2e/cases/020-sum_to_n.mp", .expected_exit = 45 },
    .{ .source = "tests/e2e/cases/021-compose_calls.mp", .expected_exit = 42 },
    .{ .source = "tests/e2e/cases/022-nested_blocks.mp", .expected_exit = 25 },
    .{ .source = "tests/e2e/cases/023-boundary_comparison.mp", .expected_exit = 2 },
    .{ .source = "tests/e2e/cases/024-stress.mp", .expected_exit = 42 },
};

test "e2e test suite" {
    const io = std.testing.io;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var failed_cases: std.ArrayList(Case) = .empty;

    for (cases) |case| {
        const compile = try std.process.run(allocator, io, .{
            .argv = &.{ compiler_path, case.source },
        });

        if (std.meta.activeTag(compile.term) != .exited) {
            std.debug.print("\nFAIL (compile) {s}: process did not exit\n", .{case.source});
            return error.CompileFailed;
        }

        if (compile.term.exited != 0) {
            std.debug.print("\nFAIL (compile) {s}:\n{s}\n", .{ case.source, compile.stderr });
            return error.CompileFailed;
        }

        const run = try std.process.run(allocator, io, .{
            .argv = &.{"./tmp/out"},
        });

        const exit_code = run.term.exited;
        if (exit_code != case.expected_exit) {
            failed_cases.append(allocator, case) catch |err| {
                std.debug.panic("Failed to append failed case: {}", .{err});
            };
        }

        // std.debug.print("PASS {s}\n", .{case.source});
    }

    for (failed_cases.items) |case| {
        std.debug.print("FAIL {s}: expected exit {d}\n", .{
            case.source,
            case.expected_exit,
        });
        try std.testing.expect(false);
    }
}
