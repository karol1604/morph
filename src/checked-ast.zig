const std = @import("std");
const ast = @import("ast.zig");

pub const TypeId = usize;

pub const Type = union(enum) {
    Named: []const u8,
    Function: struct {
        domain: TypeId,
        codomain: TypeId,
    },
    // ...
};

pub const TypeArena = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Type),

    pub fn init(allocator: std.mem.Allocator) TypeArena {
        return TypeArena{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn addType(self: *TypeArena, typ: Type) !TypeId {
        const typeId = self.items.items.len;
        try self.items.append(self.allocator, typ);
        return typeId;
    }

    pub fn get(self: *const TypeArena, typ: Type) ?TypeId {
        switch (typ) {
            .Named => {
                const name = typ.Named;
                for (self.items.items, 0..) |item, idx| {
                    if (std.mem.eql(u8, item.Named, name)) {
                        return idx;
                    }
                }
            },
            .Function => {
                const domain = typ.Function.domain;
                const codomain = typ.Function.codomain;
                for (self.items.items, 0..) |item, idx| {
                    if (item.Function.domain == domain and
                        item.Function.codomain == codomain)
                    {
                        return idx;
                    }
                }
            },
            // ...
        }
        return null;
    }

    pub fn getTypeName(self: *const TypeArena, typeId: TypeId) ?[]const u8 {
        if (typeId >= self.items.items.len) {
            return null;
        }
        const typ = self.items.items[typeId];
        switch (typ) {
            .Named => return typ.Named,
            .Function => return "Function", // TODO: actually format function type
            // ...
        }
    }
};

pub const Symbol = struct {
    name: []const u8,
    typeId: TypeId,
    kind: enum {
        Variable,
        Function,
    },
};

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
};
