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
        .IntLiteral => |val| {
            std.debug.print("IntLiteral {d}\n", .{val});
        },
        .Identifier => |name| {
            std.debug.print("Identifier {s}\n", .{name});
        },
        .BoolLiteral => |val| {
            std.debug.print("BoolLiteral {s}\n", .{if (val) "true" else "false"});
        },
        .Unary => |u| {
            const opStr = switch (u.operator) {
                .Plus => "+",
                .Minus => "-",
                .Not => "!",
            };
            std.debug.print("Unary {s}\n", .{opStr});

            // mark at this depth whether we should draw a
            // vertical bar for deeper siblings
            treeLines[depth] = !isLast;
            // recurse on the single child (always the last one)
            prettyPrintRec(u.right.*.kind, depth + 1, treeLines, true);
        },
        .VariableDecl => |varDecl| {
            if (varDecl.type) |ty| {
                std.debug.print("VariableDecl {s} (∈ {s}) =\n", .{ varDecl.name, ty });
            } else {
                std.debug.print("VariableDecl {s} =\n", .{varDecl.name});
            }

            treeLines[depth] = !isLast;
            prettyPrintRec(varDecl.value.*.kind, depth + 1, treeLines, true);
        },
        .Binary => |b| {
            const opStr = switch (b.operator) {
                .Plus => "+",
                .Minus => "-",
                .Multiply => "*",
                .TypeProduct => "×",
                .Divide => "/",
                .Exponent => "^",
                .Equal => "==",
                .NotEqual => "!=",
                .LessThan => "<",
                .GreaterThan => ">",
                .LessThanOrEqual => "<=",
                .GreaterThanOrEqual => ">=",
                .LogicalAnd => "and",
                .LogicalOr => "or",
            };
            std.debug.print("Binary {s}\n", .{opStr});

            treeLines[depth] = !isLast;
            // left is not last
            prettyPrintRec(b.left.*.kind, depth + 1, treeLines, false);
            // right is last
            prettyPrintRec(b.right.*.kind, depth + 1, treeLines, true);
        },
        .Block => |blk| {
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
        .FunctionTypeSignature => |sig| {
            std.debug.print("TypeSignature: {s}\n", .{sig.name});

            treeLines[depth] = !isLast;

            // Child 1: Domain (Input) - Not Last
            prettyPrintRec(sig.domain.*.kind, depth + 1, treeLines, false);

            // Child 2: Codomain (Output) - Last
            prettyPrintRec(sig.codomain.*.kind, depth + 1, treeLines, true);
        },
        .FunctionDef => |def| {
            std.debug.print("FunctionDef: {s}\n", .{def.name});

            treeLines[depth] = !isLast;

            // Child 1: Body - Last
            prettyPrintRec(def.body.*.kind, depth + 1, treeLines, true);
        },
        .FunctionCall => |call| {
            std.debug.print("FunctionCall: {s}\n", .{call.callee});

            treeLines[depth] = !isLast;

            const arg_count = call.args.len;
            for (call.args, 0..) |arg, i| {
                const is_last_child = (i == arg_count - 1);
                prettyPrintRec(arg.kind, depth + 1, treeLines, is_last_child);
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
        .IntLiteral => |val| {
            std.debug.print("IntLiteral {d} (typeId: {d})\n", .{ val, expr.typeId });
        },
        .Identifier => |name| {
            std.debug.print("Identifier {s} (typeId: {d})\n", .{ name, expr.typeId });
        },
        .BoolLiteral => |val| {
            std.debug.print("BoolLiteral {s} (typeId: {d})\n", .{ if (val) "true" else "false", expr.typeId });
        },
        .Unary => |u| {
            const opStr = switch (u.operator) {
                .Plus => "+",
                .Minus => "-",
                .Not => "!",
            };
            std.debug.print("Unary {s} (typeId: {d})\n", .{ opStr, expr.typeId });

            // mark at this depth whether we should draw a
            // vertical bar for deeper siblings
            treeLines[depth] = !isLast;
            // recurse on the single child (always the last one)
            prettyPrintRecCheck(u.right, depth + 1, treeLines, true);
        },
        .VariableDecl => |varDecl| {
            std.debug.print("VariableDecl {s} = (typeId: {d})\n", .{ varDecl.name, expr.typeId });

            treeLines[depth] = !isLast;
            prettyPrintRecCheck(varDecl.value, depth + 1, treeLines, true);
        },
        .Binary => |b| {
            const opStr = switch (b.operator) {
                .Plus => "+",
                .Minus => "-",
                .Multiply => "*",
                .TypeProduct => "×",
                .Divide => "/",
                .Exponent => "^",
                .Equal => "==",
                .NotEqual => "!=",
                .LessThan => "<",
                .GreaterThan => ">",
                .LessThanOrEqual => "<=",
                .GreaterThanOrEqual => ">=",
                .LogicalAnd => "and",
                .LogicalOr => "or",
            };
            std.debug.print("Binary {s} (typeId: {d})\n", .{ opStr, expr.typeId });

            treeLines[depth] = !isLast;
            // left is not last
            prettyPrintRecCheck(b.left, depth + 1, treeLines, false);
            // right is last
            prettyPrintRecCheck(b.right, depth + 1, treeLines, true);
        },
        .Block => |blk| {
            std.debug.print("Block (typeId: {d})\n", .{expr.typeId});

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
        .FunctionTypeSignature => |sig| {
            std.debug.print("TypeSignature: {s} (typeId: {d})\n", .{ sig.name, expr.typeId });

            treeLines[depth] = !isLast;

            // Child 1: Domain (Input) - Not Last
            prettyPrintRecCheck(sig.domain, depth + 1, treeLines, false);

            // Child 2: Codomain (Output) - Last
            prettyPrintRecCheck(sig.codomain, depth + 1, treeLines, true);
        },
        .FunctionDecl => |def| {
            std.debug.print("FunctionDecl: {s} (typeId: {d})\n", .{ def.name, expr.typeId });

            treeLines[depth] = !isLast;

            // Child 1: Body - Last
            prettyPrintRecCheck(def.body, depth + 1, treeLines, true);
        },
        .FunctionCall => |call| {
            std.debug.print("FunctionCall: {s} (typeId: {d})\n", .{ call.callee, expr.typeId });

            treeLines[depth] = !isLast;

            const arg_count = call.args.len;
            for (call.args, 0..) |arg, i| {
                const is_last_child = (i == arg_count - 1);
                prettyPrintRecCheck(arg, depth + 1, treeLines, is_last_child);
            }
        },
        // else => {},
    }
}
