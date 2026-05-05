const std = @import("std");
const ast = @import("ast.zig");
const TypeId = @import("type_store.zig").TypeId;
const Span = @import("span.zig").Span;

pub const CheckedTypeExpr = struct {
    type_id: TypeId,
    span: Span,
};

pub const CheckedExpr = struct {
    type_id: TypeId,
    kind: CheckedExprKind,
    span: Span,
};

pub const Param = struct {
    name: []const u8,
    type_id: TypeId,
    id: usize, // unique id for this parameter
};

pub const CheckedExprKind = union(enum) {
    int_literal: i64,
    bool_literal: bool,
    unit_literal,
    identifier: struct {
        name: []const u8,
        id: usize, // unique id for this variable
    },

    unary: struct {
        operator: ast.UnaryOperator,
        right: *const CheckedExpr,
    },

    binary: struct {
        left: *const CheckedExpr,
        operator: ast.BinaryOperator,
        right: *const CheckedExpr,
    },

    variable_decl: struct {
        name: []const u8,
        value: *const CheckedExpr,
        id: usize, // unique id for this variable
    },

    block: struct {
        stmts: []const *CheckedExpr,
        tail: ?*const CheckedExpr,
    },

    func_type_signature: struct {
        name: []const u8,
        domain: CheckedTypeExpr,
        codomain: CheckedTypeExpr,
    },

    func_decl: struct {
        name: []const u8,
        body: *const CheckedExpr,
        params: []const Param,
        id: usize, // unique id for this function
    },

    func_call: struct {
        callee: []const u8,
        args: []const *const CheckedExpr,
        id: usize, // unique id for this function call
    },

    @"if": struct {
        condition: *const CheckedExpr,
        then_branch: *const CheckedExpr,
        else_branch: ?*const CheckedExpr,
    },
};
