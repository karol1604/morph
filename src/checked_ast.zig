const std = @import("std");
const ast = @import("ast.zig");
const TypeId = @import("type_store.zig").TypeId;

pub const CheckedExpr = struct {
    typeId: TypeId,
    kind: CheckedExprKind,
};

pub const Param = struct {
    name: []const u8,
    typeId: TypeId,
    id: usize, // unique id for this parameter
};

pub const CheckedExprKind = union(enum) {
    IntLiteral: i64,
    BoolLiteral: bool,
    Identifier: struct {
        name: []const u8,
        id: usize, // unique id for this variable
    },

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
        id: usize, // unique id for this variable
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
        params: []const Param,
        id: usize, // unique id for this function
    },

    FunctionCall: struct {
        callee: []const u8,
        args: []const *const CheckedExpr,
        id: usize, // unique id for this function call
    },

    If: struct {
        condition: *const CheckedExpr,
        thenBranch: *const CheckedExpr,
        elseBranch: ?*const CheckedExpr,
    },
};
