const std = @import("std");
pub const TypeId = usize;
const Span = @import("span.zig").Span;

pub const BuiltinTypes = struct {
    Unit: TypeId,
    Int: TypeId,
    Bool: TypeId,
    Error: TypeId,
};

pub const Type = union(enum) {
    // builtins
    Unit,
    Int,
    Bool,
    Error,

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
    types: std.ArrayList(Type),
    builtins: BuiltinTypes,

    pub fn init(allocator: std.mem.Allocator) TypeStore {
        var store = TypeStore{
            .allocator = allocator,
            .types = .empty,
            .builtins = undefined,
        };

        store.builtins = .{
            .Unit = store.appendType(.Unit) catch unreachable,
            .Int = store.appendType(.Int) catch unreachable,
            .Bool = store.appendType(.Bool) catch unreachable,
            .Error = store.appendType(.Error) catch unreachable,
        };

        return store;
    }

    pub fn format(self: TypeStore, writer: *std.Io.Writer) !void {
        for (self.types.items, 0..) |typ, id| {
            switch (typ) {
                .Unit => try writer.print("Unit [{d}]\n", .{id}),
                .Int => try writer.print("Int [{d}]\n", .{id}),
                .Bool => try writer.print("Bool [{d}]\n", .{id}),
                .Error => try writer.print("Error [{d}]\n", .{id}),
                .Function => |fn_ty| try writer.print("({d} -> {d}) [{d}]\n", .{
                    fn_ty.domain,
                    fn_ty.codomain,
                    id,
                }),
                .Product => |prod| try writer.print("({d} × {d}) [{d}]\n", .{
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

        const typeId = self.types.items.len;
        try self.types.append(self.allocator, typ);
        return typeId;
    }

    pub fn resolve(self: *const TypeStore, name: []const u8) ?TypeId {
        if (std.mem.eql(u8, name, "Unit")) return self.builtins.Unit;
        if (std.mem.eql(u8, name, "Int")) return self.builtins.Int;
        if (std.mem.eql(u8, name, "Bool")) return self.builtins.Bool;
        // no "Error" — that's internal, not a user-facing type name
        return null; // eventually: search user-defined types too
    }

    pub fn get(self: *const TypeStore, typ: Type) ?TypeId {
        switch (typ) {
            .Unit => return self.builtins.Unit,
            .Int => return self.builtins.Int,
            .Bool => return self.builtins.Bool,
            .Error => return self.builtins.Error,
            .Function => |fn_ty| {
                for (self.types.items, 0..) |item, idx| {
                    if (std.meta.activeTag(item) == .Function and
                        item.Function.domain == fn_ty.domain and
                        item.Function.codomain == fn_ty.codomain)
                    {
                        return idx;
                    }
                }
            },
            .Product => |prod| {
                for (self.types.items, 0..) |item, idx| {
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

    pub fn formatTypeName(self: *const TypeStore, typeId: TypeId) []const u8 {
        if (typeId >= self.types.items.len) {
            return "Unknown";
        }
        const typ = self.types.items[typeId];
        switch (typ) {
            .Unit => return "Unit",
            .Int => return "Int",
            .Bool => return "Bool",
            .Error => return "Error",
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
    id: usize, // unique id for this symbol (e.g. variable id or function id)
    kind: enum {
        Variable,
        Function,
    },
    span: Span,
    domainSpan: ?Span, // Only used for functions to indicate the parameter type annotation span
    codomainSpan: ?Span, // Only used for functions to indicate the return type annotation span
};
