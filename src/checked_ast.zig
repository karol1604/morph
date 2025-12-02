const std = @import("std");
const ast = @import("ast.zig");

pub const TypeId = usize;

pub const Type = union(enum) {
    Named: []const u8,

    Function: struct {
        // NOTE: makes no sense
        domain: TypeId,
        codomain: TypeId,
    },

    Product: struct {
        left: TypeId,
        right: TypeId,
    },
    // ...
};

pub const TypeStore = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Type),

    pub fn init(allocator: std.mem.Allocator) TypeStore {
        return TypeStore{
            .allocator = allocator,
            .items = .empty,
        };
    }

    /// Adds a type to the store if it doesn't already exist, returning its TypeId.
    pub fn addType(self: *TypeStore, typ: Type) !TypeId {
        if (self.get(typ)) |id| return id;

        const typeId = self.items.items.len;
        try self.items.append(self.allocator, typ);
        return typeId;
    }

    pub fn get(self: *const TypeStore, typ: Type) ?TypeId {
        switch (typ) {
            .Named => {
                const name = typ.Named;
                for (self.items.items, 0..) |item, idx| {
                    if (std.mem.eql(u8, item.Named, name)) {
                        return idx;
                    }
                }
            },
            .Function => |fn_ty| {
                for (self.items.items, 0..) |item, idx| {
                    if (std.meta.activeTag(item) == .Function and
                        item.Function.domain == fn_ty.domain and
                        item.Function.codomain == fn_ty.codomain)
                    {
                        return idx;
                    }
                }
            },
            .Product => |prod| {
                for (self.items.items, 0..) |item, idx| {
                    if (std.meta.activeTag(item) == .Product and
                        item.Product.left == prod.left and
                        item.Product.right == prod.right)
                    {
                        return idx;
                    }
                }
            },
            // ...
        }
        return null;
    }

    pub fn getTypeName(self: *const TypeStore, typeId: TypeId) ?[]const u8 {
        if (typeId >= self.items.items.len) {
            return null;
        }
        const typ = self.items.items[typeId];
        switch (typ) {
            .Named => return typ.Named,
            .Function => return "Function", // TODO: actually format function type
            .Product => return "Product", // TODO: actually format product type
            // ...
        }
    }

    pub fn formatTypeName(self: *const TypeStore, typeId: TypeId) []const u8 {
        if (typeId >= self.items.items.len) {
            return "Unknown";
        }
        const typ = self.items.items[typeId];
        switch (typ) {
            .Named => return typ.Named,
            .Function => |fn_ty| {
                const domain_name = self.formatTypeName(fn_ty.domain);
                const codomain_name = self.formatTypeName(fn_ty.codomain);
                return std.fmt.allocPrint(
                    self.allocator,
                    "({s} -> {s})",
                    .{ domain_name, codomain_name },
                ) catch "Function";
            },
            .Product => |prod| {
                const left_name = self.formatTypeName(prod.left);
                const right_name = self.formatTypeName(prod.right);
                return std.fmt.allocPrint(
                    self.allocator,
                    "({s} × {s})",
                    .{ left_name, right_name },
                ) catch "Product";
            },
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
