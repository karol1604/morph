const std = @import("std");
const checkedAst = @import("checked_ast.zig");
const ast = @import("ast.zig");
const span_ = @import("span.zig");
const context = @import("context.zig");

const CheckedExpr = checkedAst.CheckedExpr;
const CheckedExprData = checkedAst.CheckedExprData;
const TypeId = checkedAst.TypeId;
const TypeStore = checkedAst.TypeStore;
const Span = span_.Span;

const UNIT_TYPE_ID: TypeId = 0;
const INT_TYPE_ID: TypeId = 1;
const BOOL_TYPE_ID: TypeId = 2;
const ERROR_TYPE_ID: TypeId = 3;

const Scope = struct {
    parent: ?*Scope,
    allocator: std.mem.Allocator,
    symbols: std.StringHashMap(checkedAst.Symbol),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return Scope{
            .parent = parent,
            .allocator = allocator,
            .symbols = std.StringHashMap(checkedAst.Symbol).init(allocator),
        };
    }

    pub fn defineSymbol(self: *Scope, symbol: checkedAst.Symbol) !void {
        const key = symbol.name;
        if (self.symbols.contains(key)) {
            return error.SymbolAlreadyDefined;
        }
        try self.symbols.put(key, symbol);
    }

    pub fn lookupSymbol(self: *Scope, name: []const u8) ?checkedAst.Symbol {
        if (self.symbols.get(name)) |sym| {
            return sym;
        }

        if (self.parent) |parentScope| {
            return parentScope.lookupSymbol(name);
        }

        return null;
    }

    pub fn deinit(self: *Scope) void {
        self.symbols.deinit();
    }
};

pub const Checker = struct {
    ctx: *context.CompilerContext,
    exprs: []*ast.Expr,
    scopes: std.ArrayList(*Scope),
    globalScope: *Scope,
    typeStore: TypeStore,

    pub fn init(ctx: *context.CompilerContext, exprs: []*ast.Expr) !Checker {
        const globalScope = try ctx.allocator.create(Scope);
        globalScope.* = Scope.init(ctx.allocator, null);

        var scopes: std.ArrayList(*Scope) = .empty;
        try scopes.append(ctx.allocator, globalScope);

        var typeArena = TypeStore.init(ctx.allocator);
        _ = try typeArena.addType(.{ .Named = "Unit" });
        _ = try typeArena.addType(.{ .Named = "Int" });
        _ = try typeArena.addType(.{ .Named = "Bool" });
        _ = try typeArena.addType(.{ .Named = "ErrorType" });

        return Checker{
            .ctx = ctx,
            .exprs = exprs,
            .scopes = scopes,
            .globalScope = globalScope,
            .typeStore = typeArena,
        };
    }

    pub fn check(self: *Checker) ![]*CheckedExpr {
        var checkedExprs = try self.ctx.allocator.alloc(*CheckedExpr, self.exprs.len);

        for (self.exprs, 0..) |expr, idx| {
            checkedExprs[idx] = try self.checkExpr(expr, null);
        }

        return checkedExprs;
    }

    fn checkExpr(self: *Checker, expr: *const ast.Expr, typeHint: ?TypeId) anyerror!*CheckedExpr {
        switch (expr.*.kind) {
            .IntLiteral => |int| return try self.typedExpr(.{ .IntLiteral = int }, INT_TYPE_ID, typeHint, expr.span),
            .BoolLiteral => |b| return try self.typedExpr(.{ .BoolLiteral = b }, BOOL_TYPE_ID, typeHint, expr.span),
            .Unary => return try self.checkUnaryExpr(expr, typeHint),
            .Binary => return try self.checkBinaryExpr(expr, typeHint),
            .VariableDecl => return try self.checkVariableDecl(expr),
            .Identifier => return try self.checkIdentifier(expr, typeHint),
            .Block => return try self.checkBlock(expr, typeHint),
            .FunctionTypeSignature => return try self.checkFunctionTypeSignature(expr),
            // else => return error.Unimplemented,
        }
    }

    fn checkFunctionTypeSignature(self: *Checker, expr: *const ast.Expr) !*CheckedExpr {
        const funcSig = expr.kind.FunctionTypeSignature;

        const domainId = try self.resolveTypeExpr(funcSig.domain);
        const codomainId = try self.resolveTypeExpr(funcSig.codomain);

        std.debug.print("domainId: {d}, codomainId: {d}\n", .{ domainId, codomainId });

        const funcTypeId = try self.typeStore.addType(
            .{ .Function = .{
                .domain = domainId,
                .codomain = codomainId,
            } },
        );

        std.debug.print("Function `{s}` has typeId `{d}` with {any}\n", .{ funcSig.name, funcTypeId, self.typeStore.items.items[funcTypeId].Function });

        const funcSym = checkedAst.Symbol{
            .name = funcSig.name,
            .typeId = funcTypeId,
            .kind = .Function,
        };

        try self.currentScope().defineSymbol(funcSym);

        return try self.typedExpr(
            .{
                .FunctionTypeSignature = .{
                    .name = funcSig.name,
                    .domain = try self.typedExpr(
                        .{ .Identifier = "DOMAIN" }, // FIXME: add proper type expr support
                        domainId,
                        null,
                        funcSig.domain.span,
                    ),
                    .codomain = try self.typedExpr(
                        .{ .Identifier = "CODOMAIN" }, // FIXME: add proper type expr support
                        codomainId,
                        null,
                        funcSig.codomain.span,
                    ),
                },
            },
            UNIT_TYPE_ID,
            null,
            expr.span,
        );
    }

    fn resolveTypeExpr(self: *Checker, expr: *const ast.Expr) !TypeId {
        switch (expr.kind) {
            .Identifier => |typeName| {
                if (self.typeStore.get(.{ .Named = typeName })) |tid| {
                    return tid;
                } else {
                    self.ctx.reportError(
                        expr.span,
                        "unknown type `{s}`",
                        .{typeName},
                    );
                    return ERROR_TYPE_ID;
                }
            },
            .Binary => |bin| switch (bin.operator) {
                .TypeProduct => {
                    const leftId = try self.resolveTypeExpr(bin.left);
                    const rightId = try self.resolveTypeExpr(bin.right);
                    return self.typeStore.addType(
                        .{ .Product = .{
                            .left = leftId,
                            .right = rightId,
                        } },
                    );
                },
                .Exponent => return error.Unimplemented,
                else => {
                    self.ctx.reportError(
                        expr.span,
                        "invalid operator in type expression",
                        .{},
                    );
                    return ERROR_TYPE_ID;
                },
            },
            else => {
                self.ctx.reportError(
                    expr.span,
                    "invalid type expression",
                    .{},
                );
                return ERROR_TYPE_ID;
            },
        }
    }

    fn checkBlock(self: *Checker, expr: *const ast.Expr, typeHint: ?TypeId) !*CheckedExpr {
        const block = expr.kind.Block;
        try self.enterNewScope();

        var checkedStmts = try self.ctx.allocator.alloc(*CheckedExpr, block.stmts.len);
        for (block.stmts, 0..) |stmt, idx| {
            checkedStmts[idx] = try self.checkExpr(stmt, null);
        }

        var tailChecked: ?*CheckedExpr = null;
        if (block.tail) |tailExpr| {
            tailChecked = try self.checkExpr(tailExpr, typeHint);
        }

        self.exitScope();

        return try self.typedExpr(
            .{ .Block = .{
                .stmts = checkedStmts,
                .tail = tailChecked,
            } },
            if (tailChecked) |t| t.typeId else UNIT_TYPE_ID,
            typeHint,
            expr.span,
        );
    }

    fn checkIdentifier(self: *Checker, expr: *const ast.Expr, typeHint: ?TypeId) !*CheckedExpr {
        const identName = expr.kind.Identifier;
        const symbol = self.currentScope().lookupSymbol(identName);
        if (symbol == null) {
            self.ctx.reportError(expr.span, "undeclared variable `{s}`", .{identName});

            // Return a dummy expr of error type
            return try self.typedExpr(
                .{ .Identifier = identName },
                ERROR_TYPE_ID,
                null,
                expr.span,
            );
        }

        std.debug.print("Identifier `{s}` resolved to `{s}`\n", .{ identName, self.typeStore.formatTypeName(symbol.?.typeId) });
        return try self.typedExpr(
            .{ .Identifier = identName },
            symbol.?.typeId,
            typeHint,
            expr.span,
        );
    }

    fn checkVariableDecl(self: *Checker, expr: *const ast.Expr) !*CheckedExpr {
        const varDecl = expr.kind.VariableDecl;
        var expectedTypeId: ?TypeId = null;

        if (self.typeStore.get(.{ .Named = varDecl.name })) |_| {
            self.ctx.reportError(
                expr.span,
                "variable `{s}` shadows type name",
                .{varDecl.name},
            );
        }

        if (varDecl.type) |typeName| {
            if (self.typeStore.get(.{ .Named = typeName })) |tid| {
                expectedTypeId = tid;
            } else {
                self.ctx.reportError(
                    expr.span,
                    "unknown type `{s}`",
                    .{typeName},
                );
                expectedTypeId = ERROR_TYPE_ID;
            }
        }

        const valueChecked = try self.checkExpr(varDecl.value, expectedTypeId);

        var resultType: TypeId = UNIT_TYPE_ID;
        if (self.typeStore.get(.{ .Named = varDecl.name })) |_| {
            self.ctx.reportError(
                expr.span,
                "variable `{s}` shadows type name",
                .{varDecl.name},
            );
            resultType = ERROR_TYPE_ID;
        } else {
            self.declareVariable(varDecl.name, valueChecked.typeId) catch |err| switch (err) {
                error.VariableAlreadyDeclared => {
                    self.ctx.reportError(
                        expr.span,
                        "variable `{s}` already declared in this scope",
                        .{varDecl.name},
                    );
                    resultType = ERROR_TYPE_ID;
                },
                else => return err,
            };
        }

        return try self.typedExpr(
            .{ .VariableDecl = .{
                .name = varDecl.name,
                .value = valueChecked,
            } },
            resultType,
            null,
            expr.span,
        );
    }

    fn declareVariable(self: *Checker, name: []const u8, typeId: TypeId) !void {
        const scope = self.currentScope();
        if (scope.lookupSymbol(name)) |_| {
            return error.VariableAlreadyDeclared;
        }

        const symbol = checkedAst.Symbol{
            .name = name,
            .typeId = typeId,
            .kind = .Variable,
        };

        try self.currentScope().defineSymbol(symbol);
    }

    fn checkBinaryExpr(self: *Checker, expr: *const ast.Expr, typeHint: ?TypeId) !*CheckedExpr {
        const binary = expr.kind.Binary;
        switch (binary.operator) {
            .Plus, .Minus, .Multiply, .Divide, .Exponent => {
                const leftChecked = try self.checkExpr(binary.left, INT_TYPE_ID);
                const rightChecked = try self.checkExpr(binary.right, INT_TYPE_ID);

                return try self.typedExpr(
                    .{ .Binary = .{
                        .left = leftChecked,
                        .operator = binary.operator,
                        .right = rightChecked,
                    } },
                    INT_TYPE_ID,
                    typeHint,
                    expr.span,
                );
            },
            .LessThan, .GreaterThan, .LessThanOrEqual, .GreaterThanOrEqual => {
                const leftChecked = try self.checkExpr(binary.left, INT_TYPE_ID);
                const rightChecked = try self.checkExpr(binary.right, INT_TYPE_ID);

                return try self.typedExpr(
                    .{ .Binary = .{
                        .left = leftChecked,
                        .operator = binary.operator,
                        .right = rightChecked,
                    } },
                    BOOL_TYPE_ID,
                    typeHint,
                    expr.span,
                );
            },
            .Equal, .NotEqual => {
                const leftChecked = try self.checkExpr(binary.left, null);
                const rightChecked = try self.checkExpr(binary.right, leftChecked.typeId);

                return try self.typedExpr(
                    .{ .Binary = .{
                        .left = leftChecked,
                        .operator = binary.operator,
                        .right = rightChecked,
                    } },
                    BOOL_TYPE_ID,
                    typeHint,
                    expr.span,
                );
            },
            .LogicalOr, .LogicalAnd => {
                const leftChecked = try self.checkExpr(binary.left, BOOL_TYPE_ID);
                const rightChecked = try self.checkExpr(binary.right, BOOL_TYPE_ID);

                return try self.typedExpr(
                    .{ .Binary = .{
                        .left = leftChecked,
                        .operator = binary.operator,
                        .right = rightChecked,
                    } },
                    BOOL_TYPE_ID,
                    typeHint,
                    expr.span,
                );
            },
            .TypeProduct => return error.IdkLol,
        }
    }

    fn checkUnaryExpr(self: *Checker, expr: *const ast.Expr, typeHint: ?TypeId) !*CheckedExpr {
        const unary = expr.kind.Unary;
        switch (unary.operator) {
            .Plus, .Minus => {
                const rightChecked = try self.checkExpr(unary.right, INT_TYPE_ID);
                return try self.typedExpr(
                    .{ .Unary = .{
                        .operator = unary.operator,
                        .right = rightChecked,
                    } },
                    INT_TYPE_ID,
                    typeHint,
                    expr.span,
                );
            },
            .Not => {
                const rightChecked = try self.checkExpr(unary.right, BOOL_TYPE_ID);
                if (rightChecked.typeId != BOOL_TYPE_ID) {
                    self.ctx.reportError(
                        expr.span,
                        "type mismatch: expected `Bool`, got `{s}`",
                        .{self.typeStore.formatTypeName(rightChecked.typeId)},
                    );

                    return try self.typedExpr(
                        .{ .Unary = .{
                            .operator = unary.operator,
                            .right = rightChecked,
                        } },
                        ERROR_TYPE_ID,
                        typeHint,
                        expr.span,
                    );
                }
                return try self.typedExpr(
                    .{ .Unary = .{
                        .operator = unary.operator,
                        .right = rightChecked,
                    } },
                    BOOL_TYPE_ID,
                    typeHint,
                    expr.span,
                );
            },
        }
    }

    fn typedExpr(
        self: *const Checker,
        data: CheckedExprData,
        resultType: TypeId,
        typeHint: ?TypeId,
        span: Span,
    ) !*CheckedExpr {
        if (typeHint != null and resultType != typeHint) {
            self.ctx.reportError(
                span,
                "type mismatch: expected `{s}`, got `{s}`",
                .{
                    self.typeStore.formatTypeName(typeHint.?),
                    self.typeStore.formatTypeName(resultType),
                },
            );
            // swallow the mismatch, but mark expression as error-typed
            return try self.heapAlloc(CheckedExpr, .{
                .typeId = ERROR_TYPE_ID,
                .data = data,
            });
        }
        return try self.heapAlloc(CheckedExpr, .{
            .typeId = resultType,
            .data = data,
        });
    }

    fn currentScope(self: *const Checker) *Scope {
        return self.scopes.items[self.scopes.items.len - 1];
    }

    fn enterNewScope(self: *Checker) !void {
        const newScope = try self.ctx.allocator.create(Scope);
        newScope.* = Scope.init(self.ctx.allocator, self.currentScope());
        try self.scopes.append(self.ctx.allocator, newScope);
    }

    fn exitScope(self: *Checker) void {
        const scope = self.scopes.items[self.scopes.items.len - 1];
        scope.deinit();
        _ = self.scopes.pop();
    }

    fn heapAlloc(self: *const Checker, comptime T: type, value: T) !*T {
        const ptr = try self.ctx.allocator.create(T);
        ptr.* = value;
        return ptr;
    }
};
