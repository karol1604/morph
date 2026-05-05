const std = @import("std");

const span = @import("span.zig");

pub const TypeExpr = struct {
    kind: TypeExprKind,
    span: span.Span,
};

pub const TypeExprKind = union(enum) {
    named: []const u8,
    unit,
    product: struct {
        left: *const TypeExpr,
        right: *const TypeExpr,
    },
    function: struct {
        domain: *const TypeExpr,
        codomain: *const TypeExpr,
    },
};

pub const Expr = struct {
    kind: ExprKind,
    span: span.Span,
};

pub const ExprKind = union(enum) {
    int_literal: i64,
    identifier: []const u8,
    bool_literal: bool,
    unit_literal,

    unary: struct {
        operator: UnaryOperator,
        right: *const Expr,
    },

    binary: struct {
        left: *const Expr,
        operator: BinaryOperator,
        right: *const Expr,
    },

    variable_decl: struct {
        name: []const u8,
        value: *const Expr,
        type: ?*const TypeExpr,
    },

    block: struct {
        stmts: []const *Expr,
        tail: ?*const Expr,
    },

    func_type_signature: struct {
        name: []const u8,
        ty: *const TypeExpr,
    },

    func_def: struct {
        name: []const u8,
        params: [][]const u8,
        body: *const Expr,
    },

    func_call: struct {
        callee: []const u8,
        args: []const *const Expr,
    },

    @"if": struct {
        condition: *const Expr,
        then_branch: *const Expr,
        else_branch: ?*const Expr,
    },
};

pub const UnaryOperator = union(enum) {
    plus,
    minus,
    not,
};

pub const BinaryOperator = union(enum) {
    plus,
    minus,
    divide,
    multiply,
    type_prod,
    exponent,

    equal,
    not_equal,
    less_than,
    greater_than,
    less_than_or_eq,
    greater_than_or_eq,

    logical_or,
    logical_and,
};

pub const Precedence = enum(u8) {
    lowest = 0,
    logical,
    equality,
    comparison,
    sum,
    product,
    exponent,
    prefix,
    group,
};
