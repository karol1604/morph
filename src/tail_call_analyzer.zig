const std = @import("std");
const checked_ast = @import("checked_ast.zig");

pub const TailCallSet = std.AutoHashMap(usize, void);

alloc: std.mem.Allocator,
tail_calls: TailCallSet,

pub fn init(alloc: std.mem.Allocator) @This() {
    return .{
        .alloc = alloc,
        .tail_calls = TailCallSet.init(alloc),
    };
}

pub fn analyze(
    self: *@This(),
    exprs: []const *const checked_ast.CheckedExpr,
) !void {
    for (exprs) |expr| {
        if (std.meta.activeTag(expr.kind) != .func_decl) continue;
        try self.visit(expr.kind.func_decl.body, true);
    }
}

fn visit(
    self: *@This(),
    expr: *const checked_ast.CheckedExpr,
    in_tail_pos: bool,
) !void {
    switch (expr.kind) {
        .@"if" => |if_expr| {
            try self.visit(if_expr.condition, false);
            try self.visit(if_expr.then_branch, in_tail_pos);
            if (if_expr.else_branch) |else_branch| {
                try self.visit(else_branch, in_tail_pos);
            }
        },
        .binary => |binary_expr| {
            if (binary_expr.operator != .logical_and and binary_expr.operator != .logical_or) return;
            try self.visit(binary_expr.left, false);
            try self.visit(binary_expr.right, in_tail_pos);
        },
        .func_call => |call_expr| {
            if (in_tail_pos) {
                try self.tail_calls.put(call_expr.call_id, {});
            }

            for (call_expr.args) |arg| {
                try self.visit(arg, false);
            }
        },
        .block => |block_expr| {
            for (block_expr.stmts) |stmt| {
                try self.visit(stmt, false);
            }
            if (block_expr.tail) |tail_expr| {
                try self.visit(tail_expr, in_tail_pos);
            }
        },
        else => {},
    }
}
