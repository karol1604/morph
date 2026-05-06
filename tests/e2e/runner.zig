const std = @import("std");
const build_options = @import("build_options");
const compiler_path = build_options.compiler_path;

const Case = struct {
    source: []const u8,
    expected_exit: u8,
};

const cases = [_]Case{
    .{ .source = "tests/e2e/cases/empty.mp", .expected_exit = 0 },
    .{ .source = "tests/e2e/cases/exit_constant.mp", .expected_exit = 69 },
    .{ .source = "tests/e2e/cases/basic_arithmetic.mp", .expected_exit = 6 },
    .{ .source = "tests/e2e/cases/simple_function_call.mp", .expected_exit = 69 },
    .{ .source = "tests/e2e/cases/variable_assignment.mp", .expected_exit = 12 },
    .{ .source = "tests/e2e/cases/if_true.mp", .expected_exit = 0 },
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
        // try std.testing.expectEqual(0, compile.term.exited);

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
    }
}
