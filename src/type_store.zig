const std = @import("std");
pub const TypeId = usize;
const Span = @import("span.zig").Span;

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
    types: std.ArrayList(Type),

    pub fn init(allocator: std.mem.Allocator) TypeStore {
        return TypeStore{
            .allocator = allocator,
            .types = .empty,
        };
    }

    pub fn format(self: TypeStore, writer: *std.Io.Writer) !void {
        for (self.types.items, 0..) |typ, id| {
            switch (typ) {
                .Named => try writer.print("{s} [{d}]\n", .{ typ.Named, id }),
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

    /// Adds a type to the store if it doesn't already exist, returning its TypeId.
    pub fn addType(self: *TypeStore, typ: Type) !TypeId {
        if (self.get(typ)) |id| return id;

        const typeId = self.types.items.len;
        try self.types.append(self.allocator, typ);
        return typeId;
    }

    pub fn get(self: *const TypeStore, typ: Type) ?TypeId {
        switch (typ) {
            .Named => {
                const name = typ.Named;
                for (self.types.items, 0..) |item, idx| {
                    if (std.meta.activeTag(item) == .Named and std.mem.eql(u8, item.Named, name)) {
                        return idx;
                    }
                }
            },
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
    id: usize, // unique id for this symbol (e.g. variable id or function id)
    kind: enum {
        Variable,
        Function,
    },
    span: Span,
    domainSpan: ?Span, // Only used for functions to indicate the parameter type annotation span
    codomainSpan: ?Span, // Only used for functions to indicate the return type annotation span
};
