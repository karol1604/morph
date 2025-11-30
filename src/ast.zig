const std = @import("std");
const span = @import("span.zig");

pub const Expr = struct {
    kind: ExprKind,
    span: span.Span,
};

pub const ExprKind = union(enum) {
    IntLiteral: i64,
    Identifier: []const u8,
    BoolLiteral: bool,

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
        type: ?[]const u8,
    },

    Block: struct {
        stmts: []const *Expr,
        tail: ?*const Expr,
    },

    FunctionTypeSignature: struct {
        name: []const u8,
        domain: *const Expr,
        codomain: *const Expr,
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
