const std = @import("std");
const cheked_ast = @import("checked_ast.zig");
const ast = @import("ast.zig");
const span_ = @import("span.zig");
const context = @import("context.zig");
const type_store = @import("type_store.zig");

const CheckedExpr = cheked_ast.CheckedExpr;
const CheckedExprData = cheked_ast.CheckedExprKind;
const TypeId = type_store.TypeId;
const TypeStore = type_store.TypeStore;
const Span = span_.Span;
const DiagnosticBuilder = @import("diagnostic.zig").DiagnosticBuilder;

// FIXME: code like this compiles :
// add: Int -> Int;
// add(x, u) => x + 1;

const TypeExpectation = struct {
    typeId: TypeId,
    span: ?Span,
    reason: []const u8,
};

const Scope = struct {
    parent: ?*Scope,
    allocator: std.mem.Allocator,
    symbols: std.StringHashMap(type_store.Symbol),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return Scope{
            .parent = parent,
            .allocator = allocator,
            .symbols = std.StringHashMap(type_store.Symbol).init(allocator),
        };
    }

    pub fn defineSymbol(self: *Scope, symbol: type_store.Symbol) !void {
        const key = symbol.name;
        if (self.symbols.contains(key)) {
            return error.SymbolAlreadyDefined;
        }
        try self.symbols.put(key, symbol);
    }

    pub fn lookupSymbol(self: *Scope, name: []const u8) ?type_store.Symbol {
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
    nextVarId: usize = 0,

    pub fn init(ctx: *context.CompilerContext, exprs: []*ast.Expr) !Checker {
        const globalScope = try ctx.allocator.create(Scope);
        globalScope.* = Scope.init(ctx.allocator, null);

        var scopes: std.ArrayList(*Scope) = .empty;
        try scopes.append(ctx.allocator, globalScope);

        const typeArena = TypeStore.init(ctx.allocator);

        std.debug.print("Builtins: Unit={d} Int={d} Bool={d} Error={d}\n", .{
            typeArena.builtins.Unit,
            typeArena.builtins.Int,
            typeArena.builtins.Bool,
            typeArena.builtins.Error,
        });
        // _ = try typeArena.addType(.{ .Named = "Unit" });
        // _ = try typeArena.addType(.{ .Named = "Int" });
        // _ = try typeArena.addType(.{ .Named = "Bool" });
        // _ = try typeArena.addType(.{ .Named = "ErrorType" });

        return Checker{
            .ctx = ctx,
            .exprs = exprs,
            .scopes = scopes,
            .globalScope = globalScope,
            .typeStore = typeArena,
        };
    }

    pub fn check(self: *Checker) ![]*CheckedExpr {
        // TODO: add a pre-pass to hoist functions
        var checkedExprs = try self.ctx.allocator.alloc(*CheckedExpr, self.exprs.len);
        for (self.exprs, 0..) |expr, idx| {
            checkedExprs[idx] = try self.checkExpr(expr, null);
        }

        return checkedExprs;
    }

    fn checkExpr(self: *Checker, expr: *const ast.Expr, typeExp: ?TypeExpectation) anyerror!*CheckedExpr {
        switch (expr.*.kind) {
            .IntLiteral => |int| return try self.typedExpr(
                .{ .IntLiteral = int },
                self.typeStore.builtins.Int,
                typeExp,
                expr.span,
            ),
            .BoolLiteral => |b| return try self.typedExpr(
                .{ .BoolLiteral = b },
                self.typeStore.builtins.Bool,
                typeExp,
                expr.span,
            ),
            .UnitLiteral => return try self.typedExpr(
                .{ .UnitLiteral = {} },
                self.typeStore.builtins.Unit,
                typeExp,
                expr.span,
            ),
            .Unary => return try self.checkUnaryExpr(expr, typeExp),
            .Binary => return try self.checkBinaryExpr(expr, typeExp),
            .VariableDecl => return try self.checkVariableDecl(expr),
            .Identifier => return try self.checkIdentifier(expr, typeExp),
            .Block => return try self.checkBlock(expr, typeExp),
            .FunctionTypeSignature => return try self.checkFunctionTypeSignature(expr),
            .FunctionDef => return try self.checkFunctionDef(expr),
            .FunctionCall => return try self.checkFunctionCall(expr, typeExp),
            .If => return try self.checkIfExpression(expr, typeExp),
            // else => return error.Unimplemented,
        }
    }

    fn checkIfExpression(self: *Checker, expr: *const ast.Expr, typeExp: ?TypeExpectation) !*CheckedExpr {
        const ifExpr = expr.kind.If;

        const boolExpectation = TypeExpectation{
            .typeId = self.typeStore.builtins.Bool,
            .span = ifExpr.condition.span,
            .reason = "if condition must be of type Bool",
        };
        const conditionChecked = try self.checkExpr(ifExpr.condition, boolExpectation);

        const thenChecked = try self.checkExpr(ifExpr.thenBranch, typeExp);

        if (ifExpr.elseBranch == null and thenChecked.typeId != self.typeStore.builtins.Unit) {
            // self.ctx.reportError(
            //     expr.span,
            //     "if expression without else branch must have a Unit-typed body, got `{s}`",
            //     .{self.typeStore.formatTypeName(thenChecked.typeId)},
            // );
            var d = DiagnosticBuilder.err(self.ctx, "if expression without an else branch must return Unit", .{});
            _ = d.primaryLabel(
                thenChecked.kind.Block.tail.?.span, // FIXME: not good
                "this has type `{s}`, expected `Unit`",
                .{self.typeStore.formatTypeName(thenChecked.typeId)},
            );
            _ = d.note("if expressions without an else branch are used as statements and must not produce a value", .{});
            d.emit();

            return try self.typedExpr(
                .{ .If = .{
                    .condition = conditionChecked,
                    .thenBranch = thenChecked,
                    .elseBranch = null,
                } },
                self.typeStore.builtins.Error,
                typeExp,
                expr.span,
            );
        }

        var elseChecked: ?*CheckedExpr = null;
        if (ifExpr.elseBranch) |elseBranch| {
            const elseExpectation = if (typeExp) |th| th else TypeExpectation{
                .typeId = thenChecked.typeId,
                .span = thenChecked.span,
                .reason = "if branches must have the same type",
            };
            elseChecked = try self.checkExpr(elseBranch, elseExpectation);

            // if (thenChecked.typeId != elseChecked.?.typeId) { // NOTE: we know there is en else branch
            //     self.ctx.reportError(
            //         expr.span,
            //         "type mismatch between then and else branches: `{s}` vs `{s}`",
            //         .{
            //             self.typeStore.formatTypeName(thenChecked.typeId),
            //             self.typeStore.formatTypeName(elseChecked.?.typeId),
            //         },
            //     );
            // }
        }

        const resultType = if (elseChecked) |_| thenChecked.typeId else self.typeStore.builtins.Unit;
        return try self.typedExpr(
            .{ .If = .{
                .condition = conditionChecked,
                .thenBranch = thenChecked,
                .elseBranch = elseChecked,
            } },
            resultType,
            typeExp,
            expr.span,
        );
    }

    fn checkFunctionCall(self: *Checker, expr: *const ast.Expr, typeExp: ?TypeExpectation) !*CheckedExpr {
        const funcCall = expr.kind.FunctionCall;
        const funcSym = self.currentScope().lookupSymbol(funcCall.callee);
        if (funcSym == null) {
            // self.ctx.reportError(
            //     expr.span,
            //     "call to undeclared function `{s}`",
            //     .{funcCall.callee},
            // );
            var d = DiagnosticBuilder.err(self.ctx, "call to undeclared function `{s}`", .{funcCall.callee});
            _ = d.primaryLabel(expr.span, "function call found here", .{})
                .note(
                "declare a function type signature like `{s} : <params> -> <return type>`",
                .{funcCall.callee},
            );
            d.emit();
            return try self.typedExpr(
                .{
                    .FunctionCall = .{
                        .callee = funcCall.callee,
                        .args = &[_]*const CheckedExpr{},
                        .id = 0, // NOTE: id doesn't matter since it's error-typed
                    },
                },
                self.typeStore.builtins.Error,
                typeExp,
                expr.span,
            );
        }

        if (funcSym.?.kind != .Function) {
            var d = DiagnosticBuilder.err(self.ctx, "symbol `{s}` is not a function", .{funcCall.callee});
            _ = d.primaryLabel(expr.span, "call found here", .{})
                .note(
                "`{s}` is of type `{s}`",
                .{ funcCall.callee, self.typeStore.formatTypeName(funcSym.?.typeId) },
            );
            d.emit();
            return try self.typedExpr(
                .{
                    .FunctionCall = .{
                        .callee = funcCall.callee,
                        .args = &[_]*const CheckedExpr{},
                        .id = 0, // NOTE: id doesn't matter since it's error-typed
                    },
                },
                self.typeStore.builtins.Error,
                typeExp,
                expr.span,
            );
        }

        const domainId = self.typeStore.types.items[funcSym.?.typeId].Function.domain;
        const codomainId = self.typeStore.types.items[funcSym.?.typeId].Function.codomain;

        const paramTypes = try self.collectParamTypes(domainId);
        if (paramTypes.len != funcCall.args.len) {
            // self.ctx.reportError(
            //     expr.span,
            //     "function `{s}` expecte {d} arguments, got {d}",
            //     .{ funcCall.callee, paramTypes.len, funcCall.args.len },
            // );
            var d = DiagnosticBuilder.err(
                self.ctx,
                "function `{s}` expected {d} arguments, got {d}",
                .{ funcCall.callee, paramTypes.len, funcCall.args.len },
            );
            d.primaryLabel(expr.span, "function call found here", .{}).emit();
        }

        var checkedArgs = try self.ctx.allocator.alloc(*CheckedExpr, funcCall.args.len);
        for (funcCall.args, 0..) |argExpr, idx| {
            const expectedTypeId = if (idx < paramTypes.len) paramTypes[idx] else self.typeStore.builtins.Error;
            const argExpectation = TypeExpectation{
                .typeId = expectedTypeId,
                .span = null, // TODO: store param spans in Symbol
                .reason = "function parameter type",
            };
            checkedArgs[idx] = try self.checkExpr(argExpr, argExpectation);
        }

        return try self.typedExpr(
            .{
                .FunctionCall = .{
                    .callee = funcCall.callee,
                    .args = checkedArgs,
                    .id = funcSym.?.id,
                },
            },
            codomainId,
            typeExp,
            expr.span,
        );
    }

    fn checkFunctionDef(self: *Checker, expr: *const ast.Expr) !*CheckedExpr {
        const funcDef = expr.kind.FunctionDef;
        const funcSig = self.currentScope().lookupSymbol(funcDef.name);

        if (funcSig) |sym| {
            if (sym.kind != .Function) {
                var d = DiagnosticBuilder.err(self.ctx, "symbol `{s}` already declared and is not a function", .{funcDef.name});
                _ = d.primaryLabel(expr.span, "function definition found here", .{})
                    .note(
                    "`{s}` is of type `{s}`",
                    .{ funcDef.name, self.typeStore.formatTypeName(sym.typeId) },
                );
                d.emit();
                return try self.typedExpr(
                    .{
                        .FunctionDecl = .{
                            .name = funcDef.name,
                            .body = undefined,
                            .params = undefined,
                            .id = sym.id,
                        },
                    },
                    self.typeStore.builtins.Error,
                    null,
                    expr.span,
                );
            }
        }

        var checkedParams: std.ArrayList(cheked_ast.Param) = .empty;

        if (funcSig == null) {
            var d = DiagnosticBuilder.err(self.ctx, "function `{s}` has no type signature", .{funcDef.name});
            _ = d.primaryLabel(expr.span, "definition found here", .{});
            _ = d.note("add a signature like `{s} : <params> -> <return type>`", .{funcDef.name});
            d.emit();
            return try self.typedExpr(
                .{
                    .FunctionDecl = .{
                        .name = funcDef.name,
                        .body = undefined,
                        .params = undefined,
                        .id = 0, // NOTE: id doesn't matter since it's error-typed
                    },
                },
                self.typeStore.builtins.Error,
                null,
                expr.span,
            );
        }

        const domainId = self.typeStore.types.items[funcSig.?.typeId].Function.domain;
        const codomainId = self.typeStore.types.items[funcSig.?.typeId].Function.codomain;

        const params = try self.collectParamTypes(domainId);
        if (funcDef.params.len != params.len) {
            var d = DiagnosticBuilder.err(
                self.ctx,
                "function `{s}` type signature declares {d} parameters, but definition has {d}",
                .{ funcDef.name, params.len, funcDef.params.len },
            );
            _ = d.primaryLabel(expr.span, "but found {d} here", .{funcDef.params.len})
                .secondaryLabel(funcSig.?.domainSpan.?, "expected {d} params here", .{params.len})
                .emit();

            return try self.typedExpr(
                .{ .FunctionDecl = .{
                    .name = funcDef.name,
                    .body = undefined,
                    .params = undefined,
                    .id = funcSig.?.id,
                } },
                self.typeStore.builtins.Error,
                null,
                expr.span,
            );
        }

        std.debug.print("Collected param types: ", .{});
        for (params) |pid| {
            std.debug.print("{s} ", .{self.typeStore.formatTypeName(pid)});
        }
        std.debug.print("\n", .{});

        try self.enterNewScope();
        defer self.exitScope();

        for (params, 0..) |paramTypeId, idx| {
            const paramName = funcDef.params[idx];
            const id = self.getNewVarId();

            try checkedParams.append(self.ctx.allocator, .{
                .name = paramName,
                .typeId = paramTypeId,
                .id = id,
            });
            const paramSym = type_store.Symbol{
                .name = paramName,
                .typeId = paramTypeId,
                .kind = .Variable,
                .id = id,
                .span = expr.span, // FIXME: add spans to params
                .domainSpan = null,
                .codomainSpan = null,
            };
            try self.currentScope().defineSymbol(paramSym);
        }

        const returnExpectation = TypeExpectation{
            .typeId = codomainId,
            .span = funcSig.?.codomainSpan,
            .reason = "declared return type here",
        };
        const bodyChecked = try self.checkExpr(funcDef.body, returnExpectation);

        return try self.typedExpr(
            .{ .FunctionDecl = .{
                .name = funcDef.name,
                .body = bodyChecked,
                .params = try checkedParams.toOwnedSlice(self.ctx.allocator),
                .id = funcSig.?.id,
            } },
            funcSig.?.typeId,
            null,
            expr.span,
        );
    }

    fn collectParamTypes(self: *const Checker, typeId: TypeId) ![]TypeId {
        const typeItem = self.typeStore.types.items[typeId];
        var paramTypes: std.ArrayList(TypeId) = .empty;

        switch (typeItem) {
            // .Named => |name| {
            //     if (std.mem.eql(u8, name, "Unit")) {
            //         return paramTypes.toOwnedSlice(self.ctx.allocator); // special case for no function params
            //     }
            //     try paramTypes.append(self.ctx.allocator, typeId);
            // },
            .Unit => {}, // NOTE: is this good?
            .Product => |prod| {
                // try paramTypes.append(self.ctx.allocator, prod.left);
                const leftTids = try self.collectParamTypes(prod.left);
                for (leftTids) |tid| {
                    try paramTypes.append(self.ctx.allocator, tid);
                }
                const rightTids = try self.collectParamTypes(prod.right);
                for (rightTids) |tid| {
                    try paramTypes.append(self.ctx.allocator, tid);
                }
            },
            else => {
                try paramTypes.append(self.ctx.allocator, typeId);
            },
        }

        return paramTypes.toOwnedSlice(self.ctx.allocator);
    }

    fn checkFunctionTypeSignature(self: *Checker, expr: *const ast.Expr) !*CheckedExpr {
        const funcSig = expr.kind.FunctionTypeSignature;

        // these should be safe unwraps since we only ever assign a `Function` type
        // whenever we create a function in the parser
        const domain = funcSig.ty.kind.Function.domain;
        const codomain = funcSig.ty.kind.Function.codomain;
        const domainId = try self.resolveTypeExpr(domain);
        const codomainId = try self.resolveTypeExpr(codomain);

        std.debug.print("domainId: {d}, codomainId: {d}\n", .{ domainId, codomainId });

        const funcTypeId = try self.typeStore.addType(
            .{ .Function = .{
                .domain = domainId,
                .codomain = codomainId,
            } },
        );

        std.debug.print("Function `{s}` has typeId `{d}` with {any}\n", .{ funcSig.name, funcTypeId, self.typeStore.types.items[funcTypeId].Function });

        const id = self.getNewVarId();
        const funcSym = type_store.Symbol{
            .name = funcSig.name,
            .typeId = funcTypeId,
            .kind = .Function,
            .id = id,
            .span = expr.span,
            .domainSpan = domain.span,
            .codomainSpan = codomain.span,
        };

        self.currentScope().defineSymbol(funcSym) catch |err| switch (err) {
            error.SymbolAlreadyDefined => {
                const previous = self.currentScope().lookupSymbol(funcSig.name).?;
                var d = DiagnosticBuilder.err(
                    self.ctx,
                    "function `{s}` already declared in this scope",
                    .{funcSig.name},
                );
                _ = d.primaryLabel(expr.span, "redeclared here", .{});
                _ = d.secondaryLabel(previous.span, "first declared here", .{});
                d.emit();
            },
            else => return err,
        };

        return try self.typedExpr(
            .{
                .FunctionTypeSignature = .{
                    .name = funcSig.name,
                    .domain = .{ .typeId = domainId, .span = domain.span },
                    .codomain = .{ .typeId = codomainId, .span = codomain.span },
                },
            },
            self.typeStore.builtins.Unit,
            null,
            expr.span,
        );
    }

    fn resolveTypeExpr(self: *Checker, type_expr: *const ast.TypeExpr) !TypeId {
        switch (type_expr.kind) {
            .Named => |typeName| {
                if (self.typeStore.resolve(typeName)) |tid| {
                    return tid;
                } else {
                    var d = DiagnosticBuilder.err(self.ctx, "unknown type `{s}`", .{typeName});
                    _ = d.primaryLabel(type_expr.span, "type not found in scope", .{});
                    d.emit();
                    return self.typeStore.builtins.Error;
                }
            },
            .Unit => return self.typeStore.builtins.Unit,
            .Product => |prod| {
                const leftId = try self.resolveTypeExpr(prod.left);
                const rightId = try self.resolveTypeExpr(prod.right);
                return self.typeStore.addType(
                    .{ .Product = .{
                        .left = leftId,
                        .right = rightId,
                    } },
                );
            },
            .Function => |func| {
                const domainId = try self.resolveTypeExpr(func.domain);
                const codomainId = try self.resolveTypeExpr(func.codomain);
                return self.typeStore.addType(
                    .{ .Function = .{
                        .domain = domainId,
                        .codomain = codomainId,
                    } },
                );
            },
            // else => {
            //     self.ctx.reportError(
            //         type_expr.span,
            //         "invalid type expression",
            //         .{},
            //     );
            //     return self.typeStore.builtins.Error;
            // },
        }
    }

    // fn resolveTypeExpr(self: *Checker, expr: *const ast.Expr) !TypeId {
    //     switch (expr.kind) {
    //         .Identifier => |typeName| {
    //             if (self.typeStore.get(.{ .Named = typeName })) |tid| {
    //                 return tid;
    //             } else {
    //                 var d = DiagnosticBuilder.err(self.ctx, "unknown type `{s}`", .{typeName});
    //                 _ = d.primaryLabel(expr.span, "type not found in scope", .{});
    //                 d.emit();
    //                 return self.typeStore.builtins.Error;
    //             }
    //         },
    //         .Binary => |bin| switch (bin.operator) {
    //             .TypeProduct => {
    //                 const leftId = try self.resolveTypeExpr(bin.left);
    //                 const rightId = try self.resolveTypeExpr(bin.right);
    //                 return self.typeStore.addType(
    //                     .{ .Product = .{
    //                         .left = leftId,
    //                         .right = rightId,
    //                     } },
    //                 );
    //             },
    //             .Exponent => return error.Unimplemented,
    //             else => {
    //                 self.ctx.reportError(
    //                     expr.span,
    //                     "invalid operator in type expression",
    //                     .{},
    //                 );
    //                 return self.typeStore.builtins.Error;
    //             },
    //         },
    //         else => {
    //             self.ctx.reportError(
    //                 expr.span,
    //                 "invalid type expression",
    //                 .{},
    //             );
    //             return self.typeStore.builtins.Error;
    //         },
    //     }
    // }

    fn checkBlock(self: *Checker, expr: *const ast.Expr, typeExp: ?TypeExpectation) !*CheckedExpr {
        const block = expr.kind.Block;

        try self.enterNewScope();
        defer self.exitScope();

        var checkedStmts = try self.ctx.allocator.alloc(*CheckedExpr, block.stmts.len);
        for (block.stmts, 0..) |stmt, idx| {
            checkedStmts[idx] = try self.checkExpr(stmt, null);
        }

        var tailChecked: ?*CheckedExpr = null;
        if (block.tail) |tailExpr| {
            tailChecked = try self.checkExpr(tailExpr, typeExp);
        }

        return try self.typedExpr(
            .{ .Block = .{
                .stmts = checkedStmts,
                .tail = tailChecked,
            } },
            if (tailChecked) |t| t.typeId else self.typeStore.builtins.Unit,
            typeExp,
            expr.span,
        );
    }

    fn checkIdentifier(self: *Checker, expr: *const ast.Expr, typeExp: ?TypeExpectation) !*CheckedExpr {
        const identName = expr.kind.Identifier;
        const symbol = self.currentScope().lookupSymbol(identName);
        if (symbol == null) {
            // self.ctx.reportError(expr.span, "undeclared variable `{s}`", .{identName});
            var d = DiagnosticBuilder.err(self.ctx, "undeclared variable `{s}`", .{identName});
            _ = d.primaryLabel(expr.span, "use found here", .{});
            d.emit();

            // Return a dummy expr of error type
            return try self.typedExpr(
                .{ .Identifier = .{ .name = identName, .id = 0 } }, // NOTE: id doesn't matter since it's error-typed
                self.typeStore.builtins.Error,
                null,
                expr.span,
            );
        }

        std.debug.print("Identifier `{s}` resolved to `{s}`\n", .{ identName, self.typeStore.formatTypeName(symbol.?.typeId) });
        return try self.typedExpr(
            .{ .Identifier = .{ .name = identName, .id = symbol.?.id } },
            symbol.?.typeId,
            typeExp,
            expr.span,
        );
    }

    fn checkVariableDecl(self: *Checker, expr: *const ast.Expr) !*CheckedExpr {
        const varDecl = expr.kind.VariableDecl;
        // var expectedTypeId: ?TypeId = null;

        if (self.typeStore.resolve(varDecl.name)) |_| {
            // self.ctx.reportError(
            //     expr.span,
            //     "variable `{s}` shadows type name",
            //     .{varDecl.name},
            // );
            var d = DiagnosticBuilder.err(self.ctx, "variable `{s}` shadows a type name", .{varDecl.name});
            _ = d.primaryLabel(expr.span, "`{s}` is a type, not a valid variable name", .{varDecl.name});
            _ = d.note("types in scope: Int, Bool, Unit", .{}); // TODO: enumarate types in scope
            d.emit();
        }

        var valueExpectation: ?TypeExpectation = null;
        if (varDecl.type) |typeExpr| {
            // if (self.typeStore.get(.{ .Named = typeExpr })) |tid| {
            //     expectedTypeId = tid;
            // } else {
            //     self.ctx.reportError(
            //         expr.span,
            //         "unknown type `{s}`",
            //         .{typeExpr},
            //     );
            //     expectedTypeId = self.typeStore.builtins.Error;
            // }
            const expectedTypeId = try self.resolveTypeExpr(typeExpr);
            valueExpectation = TypeExpectation{
                .typeId = expectedTypeId,
                .span = typeExpr.span,
                .reason = "declared type annotation here",
            };
        }

        const valueChecked = try self.checkExpr(varDecl.value, valueExpectation);

        const id = self.getNewVarId();

        var resultType: TypeId = self.typeStore.builtins.Unit;
        if (self.typeStore.resolve(varDecl.name)) |_| {
            // NOTE: ????
            // self.ctx.reportError(
            //     expr.span,
            //     "variable `{s}` shadows type name",
            //     .{varDecl.name},
            // );
            resultType = self.typeStore.builtins.Error;
        } else {
            self.declareVariable(varDecl.name, valueChecked.typeId, id, expr.span) catch |err| switch (err) {
                error.VariableAlreadyDeclared => {
                    // TODO: add secondary label pointing to the original declaration (when `Symbol` stores span)
                    const previous = self.currentScope().lookupSymbol(varDecl.name).?;
                    var d = DiagnosticBuilder.err(
                        self.ctx,
                        "variable `{s}` already declared in this scope",
                        .{varDecl.name},
                    );
                    _ = d.primaryLabel(expr.span, "redeclared here", .{});
                    _ = d.secondaryLabel(previous.span, "first declared here", .{});
                    d.emit();
                    resultType = self.typeStore.builtins.Error;
                },
                else => return err,
            };
        }

        return try self.typedExpr(
            .{ .VariableDecl = .{
                .name = varDecl.name,
                .value = valueChecked,
                .id = id,
            } },
            resultType,
            null,
            expr.span,
        );
    }

    fn declareVariable(self: *Checker, name: []const u8, typeId: TypeId, id: usize, span: Span) !void {
        const scope = self.currentScope();
        // if (scope.lookupSymbol(name)) |_| {
        //     return error.VariableAlreadyDeclared;
        // }
        if (scope.symbols.contains(name)) {
            return error.VariableAlreadyDeclared;
        }

        const symbol = type_store.Symbol{
            .name = name,
            .typeId = typeId,
            .kind = .Variable,
            .id = id,
            .span = span,
            .domainSpan = null,
            .codomainSpan = null,
        };

        try self.currentScope().defineSymbol(symbol);
    }

    fn checkBinaryExpr(self: *Checker, expr: *const ast.Expr, expected: ?TypeExpectation) !*CheckedExpr {
        const binary = expr.kind.Binary;
        switch (binary.operator) {
            .Plus, .Minus, .Multiply, .Divide, .Exponent => {
                const intExpectation = TypeExpectation{
                    .typeId = self.typeStore.builtins.Int,
                    .span = null, // NOTE: should this be null?
                    .reason = "arithmetic operator requires Int operands",
                };

                const leftChecked = try self.checkExpr(binary.left, intExpectation);
                const rightChecked = try self.checkExpr(binary.right, intExpectation);

                var resultType: TypeId = self.typeStore.builtins.Int;
                if (leftChecked.typeId == self.typeStore.builtins.Error or rightChecked.typeId == self.typeStore.builtins.Error) {
                    resultType = self.typeStore.builtins.Error;
                }

                return try self.typedExpr(
                    .{ .Binary = .{
                        .left = leftChecked,
                        .operator = binary.operator,
                        .right = rightChecked,
                    } },
                    resultType,
                    expected,
                    expr.span,
                );
            },
            .LessThan, .GreaterThan, .LessThanOrEqual, .GreaterThanOrEqual => {
                const intExpectation = TypeExpectation{
                    .typeId = self.typeStore.builtins.Int,
                    .span = null, // NOTE: should this be null?
                    .reason = "comparison operator requires Int operands",
                };

                const leftChecked = try self.checkExpr(binary.left, intExpectation);
                const rightChecked = try self.checkExpr(binary.right, intExpectation);

                var resultType: TypeId = self.typeStore.builtins.Bool;
                if (leftChecked.typeId == self.typeStore.builtins.Error or rightChecked.typeId == self.typeStore.builtins.Error) {
                    resultType = self.typeStore.builtins.Error;
                }

                return try self.typedExpr(
                    .{ .Binary = .{
                        .left = leftChecked,
                        .operator = binary.operator,
                        .right = rightChecked,
                    } },
                    resultType,
                    expected,
                    expr.span,
                );
            },
            .Equal, .NotEqual => {
                const leftChecked = try self.checkExpr(binary.left, null);
                const leftExpectation = TypeExpectation{
                    .typeId = leftChecked.typeId,
                    .span = null, // NOTE: should this be null?
                    .reason = "equality operator requires both operands to have the same type",
                };
                const rightChecked = try self.checkExpr(binary.right, leftExpectation);

                var resultType: TypeId = self.typeStore.builtins.Bool;
                if (leftChecked.typeId == self.typeStore.builtins.Error or rightChecked.typeId == self.typeStore.builtins.Error) {
                    resultType = self.typeStore.builtins.Error;
                }

                return try self.typedExpr(
                    .{ .Binary = .{
                        .left = leftChecked,
                        .operator = binary.operator,
                        .right = rightChecked,
                    } },
                    resultType,
                    expected,
                    expr.span,
                );
            },
            .LogicalOr, .LogicalAnd => {
                const boolExpectation = TypeExpectation{
                    .typeId = self.typeStore.builtins.Bool,
                    .span = null, // NOTE: should this be null?
                    .reason = "logical operator requires Bool operands",
                };
                const leftChecked = try self.checkExpr(binary.left, boolExpectation);
                const rightChecked = try self.checkExpr(binary.right, boolExpectation);

                var resultType: TypeId = self.typeStore.builtins.Bool;
                if (leftChecked.typeId == self.typeStore.builtins.Error or rightChecked.typeId == self.typeStore.builtins.Error) {
                    resultType = self.typeStore.builtins.Error;
                }

                return try self.typedExpr(
                    .{ .Binary = .{
                        .left = leftChecked,
                        .operator = binary.operator,
                        .right = rightChecked,
                    } },
                    resultType,
                    expected,
                    expr.span,
                );
            },
            .TypeProduct => return error.IdkLol,
        }
    }

    fn checkUnaryExpr(self: *Checker, expr: *const ast.Expr, expected: ?TypeExpectation) !*CheckedExpr {
        const unary = expr.kind.Unary;
        switch (unary.operator) {
            .Plus, .Minus => {
                const intExpectation = TypeExpectation{
                    .typeId = self.typeStore.builtins.Int,
                    .span = null, // NOTE: should this be null?
                    .reason = "unary plus and minus require Int operand",
                };
                const rightChecked = try self.checkExpr(unary.right, intExpectation);

                const resultType = if (rightChecked.typeId == self.typeStore.builtins.Error) self.typeStore.builtins.Error else self.typeStore.builtins.Int;
                return try self.typedExpr(
                    .{ .Unary = .{
                        .operator = unary.operator,
                        .right = rightChecked,
                    } },
                    resultType,
                    expected,
                    expr.span,
                );
            },
            .Not => {
                const boolExpectation = TypeExpectation{
                    .typeId = self.typeStore.builtins.Bool,
                    .span = null, // NOTE: should this be null?
                    .reason = "logical not requires Bool operand",
                };
                const rightChecked = try self.checkExpr(unary.right, boolExpectation);

                const resultType = if (rightChecked.typeId == self.typeStore.builtins.Error) self.typeStore.builtins.Error else self.typeStore.builtins.Bool;
                return try self.typedExpr(
                    .{ .Unary = .{
                        .operator = unary.operator,
                        .right = rightChecked,
                    } },
                    resultType,
                    expected,
                    expr.span,
                );
            },
        }
    }

    fn typedExpr(
        self: *const Checker,
        data: CheckedExprData,
        resultType: TypeId,
        typeExp: ?TypeExpectation,
        span: Span,
    ) !*CheckedExpr {
        if (typeExp != null and resultType != typeExp.?.typeId and resultType != self.typeStore.builtins.Error and typeExp.?.typeId != self.typeStore.builtins.Error) {
            var d = DiagnosticBuilder.err(
                self.ctx,
                "type mismatch: expected `{s}`, got `{s}`",
                .{
                    self.typeStore.formatTypeName(typeExp.?.typeId),
                    self.typeStore.formatTypeName(resultType),
                },
            );
            _ = d.primaryLabel(span, "this has type `{s}`", .{self.typeStore.formatTypeName(resultType)});
            if (typeExp.?.span) |expectationSpan| {
                _ = d.secondaryLabel(expectationSpan, "{s}", .{typeExp.?.reason});
            }
            d.emit();
            // swallow the mismatch, but mark expression as error-typed
            return try self.heapAlloc(CheckedExpr, .{
                .typeId = self.typeStore.builtins.Error,
                .kind = data,
                .span = span,
            });
        }
        return try self.heapAlloc(CheckedExpr, .{
            .typeId = resultType,
            .kind = data,
            .span = span,
        });
    }

    fn getNewVarId(self: *Checker) usize {
        const id = self.nextVarId;
        self.nextVarId += 1;
        return id;
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
