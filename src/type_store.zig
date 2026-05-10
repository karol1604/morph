const std = @import("std");
pub const TypeId = usize;
const Span = @import("span.zig").Span;
const ids = @import("ids.zig");

pub const BuiltinTypes = struct {
    unit: TypeId,
    int: TypeId,
    bool: TypeId,
    err: TypeId,
};

pub const Type = union(enum) {
    // builtins
    unit,
    int,
    bool,
    err,

    function: struct {
        // NOTE: makes no sense
        domain: TypeId,
        codomain: TypeId,
    },

    product: struct {
        left: TypeId,
        right: TypeId,
    },
    // ...
};

pub const TypeStore = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(Type),
    builtins: BuiltinTypes,

    pub fn init(allocator: std.mem.Allocator) TypeStore {
        var store = TypeStore{
            .allocator = allocator,
            .types = .empty,
            .builtins = undefined,
        };

        store.builtins = .{
            .unit = store.appendType(.unit) catch unreachable,
            .int = store.appendType(.int) catch unreachable,
            .bool = store.appendType(.bool) catch unreachable,
            .err = store.appendType(.err) catch unreachable,
        };

        return store;
    }

    pub fn format(self: TypeStore, writer: *std.Io.Writer) !void {
        for (self.types.items, 0..) |typ, id| {
            switch (typ) {
                .unit => try writer.print("Unit [{d}]\n", .{id}),
                .int => try writer.print("Int [{d}]\n", .{id}),
                .bool => try writer.print("Bool [{d}]\n", .{id}),
                .err => try writer.print("Error [{d}]\n", .{id}),
                .function => |fn_ty| try writer.print("({d} -> {d}) [{d}]\n", .{
                    fn_ty.domain,
                    fn_ty.codomain,
                    id,
                }),
                .product => |prod| try writer.print("({d} × {d}) [{d}]\n", .{
                    prod.left,
                    prod.right,
                    id,
                }),
            }
        }
    }

    fn appendType(self: *TypeStore, typ: Type) !TypeId {
        const id = self.types.items.len;
        try self.types.append(self.allocator, typ);
        return id;
    }

    /// Adds a type to the store if it doesn't already exist, returning its `TypeId`.
    pub fn addType(self: *TypeStore, typ: Type) !TypeId {
        if (self.get(typ)) |id| return id;

        const type_id = self.types.items.len;
        try self.types.append(self.allocator, typ);
        return type_id;
    }

    pub fn resolve(self: *const TypeStore, name: []const u8) ?TypeId {
        if (std.mem.eql(u8, name, "Unit")) return self.builtins.unit;
        if (std.mem.eql(u8, name, "Int")) return self.builtins.int;
        if (std.mem.eql(u8, name, "Bool")) return self.builtins.bool;
        // no "Error" — that's internal, not a user-facing type name
        return null; // eventually: search user-defined types too
    }

    pub fn get(self: *const TypeStore, typ: Type) ?TypeId {
        switch (typ) {
            .unit => return self.builtins.unit,
            .int => return self.builtins.int,
            .bool => return self.builtins.bool,
            .err => return self.builtins.err,
            .function => |fn_ty| {
                for (self.types.items, 0..) |item, idx| {
                    if (std.meta.activeTag(item) == .function and
                        item.function.domain == fn_ty.domain and
                        item.function.codomain == fn_ty.codomain)
                    {
                        return idx;
                    }
                }
            },
            .product => |prod| {
                for (self.types.items, 0..) |item, idx| {
                    if (std.meta.activeTag(item) == .product and
                        item.product.left == prod.left and
                        item.product.right == prod.right)
                    {
                        return idx;
                    }
                }
            },
            // ...
        }
        return null;
    }

    // pub fn getTypeName(self: *const TypeStore, typeId: TypeId) ?[]const u8 {
    //     if (typeId >= self.types.items.len) {
    //         return null;
    //     }
    //     const typ = self.types.items[typeId];
    //     switch (typ) {
    //         .Named => return typ.Named,
    //         .Function => return "Function", // TODO: actually format function type
    //         .Product => return "Product", // TODO: actually format product type
    //         // ...
    //     }
    // }

    pub fn formatTypeName(self: *const TypeStore, type_id: TypeId) []const u8 {
        if (type_id >= self.types.items.len) {
            return "Unknown";
        }
        const typ = self.types.items[type_id];
        switch (typ) {
            .unit => return "Unit",
            .int => return "Int",
            .bool => return "Bool",
            .err => return "Error",
            .function => |fn_ty| {
                const domain_name = self.formatTypeName(fn_ty.domain);
                const codomain_name = self.formatTypeName(fn_ty.codomain);
                return std.fmt.allocPrint(
                    self.allocator,
                    "({s} -> {s})",
                    .{ domain_name, codomain_name },
                ) catch "Function";
            },
            .product => |prod| {
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
    type_id: TypeId,
    id: usize, // unique id for this symbol (variable or function)
    kind: enum {
        variable,
        function,
    },
    span: Span,
    domain_span: ?Span, // Only used for functions to indicate the parameter type annotation span
    codomain_span: ?Span, // Only used for functions to indicate the return type annotation span
};
