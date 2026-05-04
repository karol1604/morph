const std = @import("std");

const span = @import("span.zig");

pub const TypeExpr = struct {
    kind: TypeExprKind,
    span: span.Span,
};

pub const TypeExprKind = union(enum) {
    Named: []const u8,
    Unit,
    Product: struct {
        left: *const TypeExpr,
        right: *const TypeExpr,
    },
    Function: struct {
        domain: *const TypeExpr,
        codomain: *const TypeExpr,
    },
};

pub const Expr = struct {
    kind: ExprKind,
    span: span.Span,
};

pub const ExprKind = union(enum) {
    IntLiteral: i64,
    Identifier: []const u8,
    BoolLiteral: bool,
    UnitLiteral,

    Unary: struct {
        operator: UnaryOperator,
        right: *const Expr,
    },

    Binary: struct {
        left: *const Expr,
        operator: BinaryOperator,
        right: *const Expr,
    },

    VariableDecl: struct {
        name: []const u8,
        value: *const Expr,
        type: ?*const TypeExpr,
    },

    Block: struct {
        stmts: []const *Expr,
        tail: ?*const Expr,
    },

    FunctionTypeSignature: struct {
        name: []const u8,
        // domain: *const Expr, // TODO: replace by a proper type expression
        // codomain: *const Expr, // TODO: replace by a proper type expression
        ty: *const TypeExpr,
    },

    FunctionDef: struct {
        name: []const u8,
        params: [][]const u8,
        body: *const Expr,
    },

    FunctionCall: struct {
        callee: []const u8,
        args: []const *const Expr,
    },

    If: struct {
        condition: *const Expr,
        thenBranch: *const Expr,
        elseBranch: ?*const Expr,
    },
};

pub const UnaryOperator = union(enum) {
    Plus,
    Minus,
    Not,
};

pub const BinaryOperator = union(enum) {
    Plus,
    Minus,
    Divide,
    Multiply,
    TypeProduct,
    Exponent,

    Equal,
    NotEqual,
    LessThan,
    GreaterThan,
    LessThanOrEqual,
    GreaterThanOrEqual,

    LogicalOr,
    LogicalAnd,
};

pub const Precedence = enum(u8) {
    Lowest = 0,
    Logical,
    Equality,
    Comparison,
    Sum,
    Product,
    Exponent,
    Prefix,
    Group,
};
