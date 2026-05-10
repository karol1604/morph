const std = @import("std");
const ast = @import("ast.zig");
const checked_ast = @import("checked_ast.zig");

pub fn encodeCodepointToUtf8(cp: u21, buf: *[4]u8) ![]const u8 {
    const len = try std.unicode.utf8Encode(cp, buf);
    return buf[0..len];
}

pub fn isDigit(c: u21) bool {
    return c >= '0' and c <= '9';
}

pub fn isAlpha(c: u21) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c == '_');
}

pub fn isAlphaNumeric(c: u21) bool {
    return isAlpha(c) or isDigit(c) or isSpecial(c);
}

pub fn isSpecial(c: u21) bool {
    return c == 'ℝ' or c == 'ℤ' or c == 'ℕ';
}

const MAX_DEPTH = 64;
/// Pretty prints an expression tree
pub fn prettyPrintExpression(expr: ast.Expr) void {
    var treeLines: [MAX_DEPTH]bool = undefined;
    prettyPrintRec(expr.kind, 0, &treeLines, true);
}

fn prettyPrintRecType(
    expr: ast.TypeExprKind,
    depth: usize,
    treeLines: *[MAX_DEPTH]bool,
    isLast: bool,
) void {
    if (depth > 0) {
        // we only loop up to depth-1, because the last indent
        // slot is for the branch itself
        for (0..depth) |i| {
            if (treeLines[i]) {
                std.debug.print("│   ", .{});
            } else {
                std.debug.print("    ", .{});
            }
        }
        // 2) Print the branch
        if (isLast) std.debug.print("└── ", .{}) else std.debug.print("├── ", .{});
    }

    switch (expr) {
        .named => |name| {
            std.debug.print("Named: {s}\n", .{name});
        },
        .unit => {
            std.debug.print("Unit\n", .{});
        },
        .product => |prod| {
            std.debug.print("Product\n", .{});

            treeLines[depth] = !isLast;

            prettyPrintRecType(prod.left.*.kind, depth + 1, treeLines, false);
            prettyPrintRecType(prod.right.*.kind, depth + 1, treeLines, true);
        },
        .function => |func| {
            std.debug.print("Function\n", .{});

            treeLines[depth] = !isLast;

            prettyPrintRecType(func.domain.*.kind, depth + 1, treeLines, false);
            prettyPrintRecType(func.codomain.*.kind, depth + 1, treeLines, true);
        },
    }
}

fn prettyPrintRec(
    expr: ast.ExprKind,
    depth: usize,
    treeLines: *[MAX_DEPTH]bool,
    isLast: bool,
) void {
    // 1) Print the indentation bars for all ancestor levels
    if (depth > 0) {
        // we only loop up to depth-1, because the last indent
        // slot is for the branch itself
        for (0..depth) |i| {
            if (treeLines[i]) {
                std.debug.print("│   ", .{});
            } else {
                std.debug.print("    ", .{});
            }
        }
        // 2) Print the branch
        if (isLast) std.debug.print("└── ", .{}) else std.debug.print("├── ", .{});
    }

    // 3) Print this node
    switch (expr) {
        .int_literal => |val| {
            std.debug.print("IntLiteral {d}\n", .{val});
        },
        .identifier => |name| {
            std.debug.print("Identifier {s}\n", .{name});
        },
        .bool_literal => |val| {
            std.debug.print("BoolLiteral {s}\n", .{if (val) "true" else "false"});
        },
        .unit_literal => {
            std.debug.print("UnitLiteral\n", .{});
        },
        .unary => |u| {
            const opStr = switch (u.operator) {
                .plus => "+",
                .minus => "-",
                .not => "!",
            };
            std.debug.print("Unary {s}\n", .{opStr});

            // mark at this depth whether we should draw a
            // vertical bar for deeper siblings
            treeLines[depth] = !isLast;
            // recurse on the single child (always the last one)
            prettyPrintRec(u.right.*.kind, depth + 1, treeLines, true);
        },
        .variable_decl => |varDecl| {
            if (varDecl.type) |ty| {
                _ = ty;
                // TODO: fix this
                // std.debug.print("VariableDecl {s} (∈ {f}) =\n", .{ varDecl.name, ty });
                std.debug.print("VariableDecl {s} (∈ ... ) =\n", .{varDecl.name});
            } else {
                std.debug.print("VariableDecl {s} =\n", .{varDecl.name});
            }

            treeLines[depth] = !isLast;
            prettyPrintRec(varDecl.value.*.kind, depth + 1, treeLines, true);
        },
        .binary => |b| {
            const opStr = switch (b.operator) {
                .plus => "+",
                .minus => "-",
                .multiply => "*",
                .type_prod => "×",
                .divide => "/",
                .exponent => "^",
                .equal => "==",
                .not_equal => "!=",
                .less_than => "<",
                .greater_than => ">",
                .less_than_or_eq => "<=",
                .greater_than_or_eq => ">=",
                .logical_and => "and",
                .logical_or => "or",
            };
            std.debug.print("Binary {s}\n", .{opStr});

            treeLines[depth] = !isLast;
            // left is not last
            prettyPrintRec(b.left.*.kind, depth + 1, treeLines, false);
            // right is last
            prettyPrintRec(b.right.*.kind, depth + 1, treeLines, true);
        },
        .block => |blk| {
            std.debug.print("Block\n", .{});

            treeLines[depth] = !isLast;

            const has_tail = (blk.tail != null);
            const stmt_count = blk.stmts.len;

            for (blk.stmts, 0..) |stmt, i| {
                const is_last_child = (i == stmt_count - 1) and (!has_tail);

                prettyPrintRec(stmt.kind, depth + 1, treeLines, is_last_child);
            }

            if (blk.tail) |t| {
                prettyPrintRec(t.kind, depth + 1, treeLines, true);
            }
        },
        .func_type_signature => |sig| {
            std.debug.print("FunctionTypeSignature: {s}\n", .{sig.name});

            treeLines[depth] = !isLast;

            const func = sig.ty.kind.function;
            prettyPrintRecType(func.domain.kind, depth + 1, treeLines, false);

            prettyPrintRecType(func.codomain.kind, depth + 1, treeLines, true);
        },
        .func_def => |def| {
            std.debug.print("FunctionDef: {s}\n", .{def.name});

            treeLines[depth] = !isLast;

            // Child 1: Body - Last
            prettyPrintRec(def.body.*.kind, depth + 1, treeLines, true);
        },
        .func_call => |call| {
            std.debug.print("FunctionCall: {s}\n", .{call.callee});

            treeLines[depth] = !isLast;

            const arg_count = call.args.len;
            for (call.args, 0..) |arg, i| {
                const is_last_child = (i == arg_count - 1);
                prettyPrintRec(arg.kind, depth + 1, treeLines, is_last_child);
            }
        },
        .@"if" => |ifExpr| {
            const isElseBranch = if (ifExpr.else_branch) |_| true else false;
            std.debug.print("If\n", .{});

            treeLines[depth] = !isLast;

            prettyPrintRec(ifExpr.condition.*.kind, depth + 1, treeLines, false);

            prettyPrintRec(ifExpr.then_branch.*.kind, depth + 1, treeLines, !isElseBranch);

            if (ifExpr.else_branch) |elseBranch| {
                prettyPrintRec(elseBranch.*.kind, depth + 1, treeLines, true);
            }
        },
        // else => {},
    }
}

pub fn prettyPrintCheckedExpression(expr: *const checked_ast.CheckedExpr) void {
    var treeLines: [MAX_DEPTH]bool = undefined;
    prettyPrintRecCheck(expr, 0, &treeLines, true);
}

fn prettyPrintRecCheck(
    expr: *const checked_ast.CheckedExpr,
    depth: usize,
    treeLines: *[MAX_DEPTH]bool,
    isLast: bool,
) void {
    // 1) Print the indentation bars for all ancestor levels
    if (depth > 0) {
        // we only loop up to depth-1, because the last indent
        // slot is for the branch itself
        for (0..depth) |i| {
            if (treeLines[i]) {
                std.debug.print("│   ", .{});
            } else {
                std.debug.print("    ", .{});
            }
        }
        // 2) Print the branch
        if (isLast) std.debug.print("└── ", .{}) else std.debug.print("├── ", .{});
    }

    // 3) Print this node
    switch (expr.kind) {
        .int_literal => |val| {
            std.debug.print("IntLiteral {d} (typeId: {d})\n", .{ val, expr.type_id });
        },
        .identifier => |name| {
            std.debug.print("Identifier {s} (typeId: {d})\n", .{ name.name, expr.type_id });
        },
        .bool_literal => |val| {
            std.debug.print("BoolLiteral {s} (typeId: {d})\n", .{ if (val) "true" else "false", expr.type_id });
        },
        .unit_literal => {
            std.debug.print("UnitLiteral (typeId: {d})\n", .{expr.type_id});
        },
        .unary => |u| {
            const opStr = switch (u.operator) {
                .plus => "+",
                .minus => "-",
                .not => "!",
            };
            std.debug.print("Unary {s} (typeId: {d})\n", .{ opStr, expr.type_id });

            // mark at this depth whether we should draw a
            // vertical bar for deeper siblings
            treeLines[depth] = !isLast;
            // recurse on the single child (always the last one)
            prettyPrintRecCheck(u.right, depth + 1, treeLines, true);
        },
        .variable_decl => |varDecl| {
            std.debug.print("VariableDecl {s} = (typeId: {d})\n", .{ varDecl.name, expr.type_id });

            treeLines[depth] = !isLast;
            prettyPrintRecCheck(varDecl.value, depth + 1, treeLines, true);
        },
        .binary => |b| {
            const opStr = switch (b.operator) {
                .plus => "+",
                .minus => "-",
                .multiply => "*",
                .type_prod => "×",
                .divide => "/",
                .exponent => "^",
                .equal => "==",
                .not_equal => "!=",
                .less_than => "<",
                .greater_than => ">",
                .less_than_or_eq => "<=",
                .greater_than_or_eq => ">=",
                .logical_and => "and",
                .logical_or => "or",
            };
            std.debug.print("Binary {s} (typeId: {d})\n", .{ opStr, expr.type_id });

            treeLines[depth] = !isLast;
            // left is not last
            prettyPrintRecCheck(b.left, depth + 1, treeLines, false);
            // right is last
            prettyPrintRecCheck(b.right, depth + 1, treeLines, true);
        },
        .block => |blk| {
            std.debug.print("Block (typeId: {d})\n", .{expr.type_id});

            treeLines[depth] = !isLast;

            const has_tail = (blk.tail != null);
            const stmt_count = blk.stmts.len;

            for (blk.stmts, 0..) |stmt, i| {
                const is_last_child = (i == stmt_count - 1) and (!has_tail);

                prettyPrintRecCheck(stmt, depth + 1, treeLines, is_last_child);
            }

            if (blk.tail) |t| {
                prettyPrintRecCheck(t, depth + 1, treeLines, true);
            }
        },
        .func_type_signature => |sig| {
            std.debug.print("TypeSignature: {s} :: {d} -> {d} (typeId: {d})\n", .{
                sig.name,
                sig.domain.type_id,
                sig.codomain.type_id,
                expr.type_id,
            });

            treeLines[depth] = !isLast;

            // Child 1: Domain (Input) - Not Last
            // prettyPrintRecCheck(sig.domain, depth + 1, treeLines, false);
            //
            // // Child 2: Codomain (Output) - Last
            // prettyPrintRecCheck(sig.codomain, depth + 1, treeLines, true);
        },
        .func_decl => |def| {
            std.debug.print("FunctionDecl: {s} (typeId: {d})\n", .{ def.name, expr.type_id });

            treeLines[depth] = !isLast;

            prettyPrintRecCheck(def.body, depth + 1, treeLines, true);
        },
        .func_call => |call| {
            std.debug.print("FunctionCall: {s} (typeId: {d})\n", .{ call.callee_name, expr.type_id });

            treeLines[depth] = !isLast;

            const arg_count = call.args.len;
            for (call.args, 0..) |arg, i| {
                const is_last_child = (i == arg_count - 1);
                prettyPrintRecCheck(arg, depth + 1, treeLines, is_last_child);
            }
        },
        .@"if" => |ifExpr| {
            const isElseBranch = if (ifExpr.else_branch) |_| true else false;

            std.debug.print("If (typeId: {d})\n", .{expr.type_id});

            treeLines[depth] = !isLast;

            prettyPrintRecCheck(ifExpr.condition, depth + 1, treeLines, false);

            prettyPrintRecCheck(ifExpr.then_branch, depth + 1, treeLines, !isElseBranch);

            if (ifExpr.else_branch) |elseBranch| {
                prettyPrintRecCheck(elseBranch, depth + 1, treeLines, true);
            }
        },
        // else => {},
    }
}
