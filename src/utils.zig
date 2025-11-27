const std = @import("std");
const ast = @import("ast.zig");

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
        .Binary => |b| {
            const opStr = switch (b.operator) {
                .Plus => "+",
                .Minus => "-",
                .Multiply => "*",
                .Divide => "/",
                .Exponent => "^",
                .Equal => "==",
                .NotEqual => "!=",
                .LessThan => "<",
                .GreaterThan => ">",
                .LessThanOrEqual => "<=",
                .GreaterThanOrEqual => ">=",
                .LogicalAnd => "&&",
                .LogicalOr => "||",
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
        // else => {},
    }
}
