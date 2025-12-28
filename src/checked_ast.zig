const std = @import("std");
const ast = @import("ast.zig");
const TypeId = @import("type_store.zig").TypeId;

pub const CheckedExpr = struct {
    typeId: TypeId,
    data: CheckedExprData,
};

pub const CheckedExprData = union(enum) {
    IntLiteral: i64,
    BoolLiteral: bool,
    Identifier: []const u8,

    Unary: struct {
        operator: ast.UnaryOperator,
        right: *const CheckedExpr,
    },

    Binary: struct {
        left: *const CheckedExpr,
        operator: ast.BinaryOperator,
        right: *const CheckedExpr,
    },

    VariableDecl: struct {
        name: []const u8,
        value: *const CheckedExpr,
    },

    Block: struct {
        stmts: []const *CheckedExpr,
        tail: ?*const CheckedExpr,
    },

    FunctionTypeSignature: struct {
        name: []const u8,
        domain: *const CheckedExpr,
        codomain: *const CheckedExpr,
    },

    FunctionDecl: struct {
        name: []const u8,
        body: *const CheckedExpr,
    },

    FunctionCall: struct {
        callee: []const u8,
        args: []const *const CheckedExpr,
    },
};
