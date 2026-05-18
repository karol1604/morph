const std = @import("std");
const checked_ast = @import("checked_ast.zig");
const ast = @import("ast.zig");
const span_ = @import("span.zig");
const context = @import("context.zig");
const type_store = @import("type_store.zig");
const ids = @import("ids.zig");

const CheckedExpr = checked_ast.CheckedExpr;
const CheckedExprData = checked_ast.CheckedExprKind;
const TypeId = type_store.TypeId;
const TypeStore = type_store.TypeStore;
const Span = span_.Span;
const DiagnosticBuilder = @import("diagnostic.zig").DiagnosticBuilder;

// FIXME: code like this compiles :
// add: Int -> Int;
// add(x, u) => x + 1;

const TypeExpectation = struct {
    type_id: TypeId,
    span: ?Span,
    reason: []const u8,
};

const FunctionStatus = enum {
    declared,
    defining,
    defined,
    external,
};
const FunctionInfo = struct {
    name: []const u8,
    type_id: TypeId,
    status: FunctionStatus,
    sig_span: Span,
    def_span: ?Span = null,
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
    exprs: []*const ast.Expr,
    scopes: std.ArrayList(*Scope),
    global_scope: *Scope,
    type_store: TypeStore,
    next_id: usize = 0,
    next_call_id: usize = 0,
    functions: std.AutoHashMap(ids.FunctionId, FunctionInfo),

    pub fn init(ctx: *context.CompilerContext, exprs: []*const ast.Expr) !Checker {
        const global_scope = try ctx.allocator.create(Scope);
        global_scope.* = Scope.init(ctx.allocator, null);

        var scopes: std.ArrayList(*Scope) = .empty;
        try scopes.append(ctx.allocator, global_scope);

        const type_arena = TypeStore.init(ctx.allocator);

        var checker = Checker{
            .ctx = ctx,
            .exprs = exprs,
            .scopes = scopes,
            .global_scope = global_scope,
            .type_store = type_arena,
            .functions = std.AutoHashMap(ids.FunctionId, FunctionInfo).init(ctx.allocator),
        };

        const print_int_type_id = try checker.type_store.addType(.{ .function = .{
            .domain = type_arena.builtins.int,
            .codomain = type_arena.builtins.unit,
        } });

        const id = checker.getNewId();
        try checker.global_scope.defineSymbol(type_store.Symbol{
            .name = "printInt",
            .type_id = print_int_type_id,
            .kind = .function,
            .id = id,
            .span = Span{
                .start = span_.Location{ .col = 0, .line = 0, .offset = 0 },
                .end = span_.Location{ .col = 0, .line = 0, .offset = 0 },
            }, // FIXME: add spans for built-ins
            .domain_span = null,
            .codomain_span = null,
        });
        try checker.ctx.debug_names.addFunctionName(id, "printInt");

        return checker;
    }

    pub fn check(self: *Checker) ![]*CheckedExpr {
        // TODO: add a pre-pass to hoist functions
        try self.hoistFunctionSignatures();
        var checked_expr = try self.ctx.allocator.alloc(*CheckedExpr, self.exprs.len);
        for (self.exprs, 0..) |expr, idx| {
            checked_expr[idx] = try self.checkExpr(expr, null);
        }

        try self.validateDeclaredFunctionsDefined();
        return checked_expr;
    }

    fn hoistFunctionSignatures(self: *Checker) !void {
        for (self.exprs) |expr| {
            if (std.meta.activeTag(expr.kind) == .func_type_signature) {
                try self.declareFunctionSignature(expr);
            }
        }
    }

    fn validateDeclaredFunctionsDefined(self: *Checker) !void {
        var it = self.functions.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr.*;

            // NOTE: this forbids functions witout a body even if they're not called
            if (info.status == .declared) {
                var d = DiagnosticBuilder.err(
                    self.ctx,
                    "function `{s}` is declared but not defined",
                    .{info.name},
                );
                _ = d.primaryLabel(info.sig_span, "signature declared here", .{})
                    .note("add a function body or mark this as external when extern functions exist", .{})
                    .emit();
            }
        }
    }

    fn declareFunctionSignature(self: *Checker, expr: *const ast.Expr) !void {
        const func_sig = expr.kind.func_type_signature;

        // these should be safe unwraps since we only ever assign a `Function` type
        // whenever we create a function in the parser
        const domain = func_sig.ty.kind.function.domain;
        const codomain = func_sig.ty.kind.function.codomain;
        const domain_id = try self.resolveTypeExpr(domain);
        const codomain_id = try self.resolveTypeExpr(codomain);

        std.debug.print("domainId: {d}, codomainId: {d}\n", .{ domain_id, codomain_id });

        const func_type_id = try self.type_store.addType(
            .{ .function = .{
                .domain = domain_id,
                .codomain = codomain_id,
            } },
        );

        std.debug.print(
            "Function `{s}` has typeId `{d}` with {any}\n",
            .{ func_sig.name, func_type_id, self.type_store.types.items[func_type_id].function },
        );

        const id = self.getNewId();
        const func_sym = type_store.Symbol{
            .name = func_sig.name,
            .type_id = func_type_id,
            .kind = .function,
            .id = id,
            .span = expr.span,
            .domain_span = domain.span,
            .codomain_span = codomain.span,
        };

        try self.functions.put(id, .{
            .name = func_sig.name,
            .type_id = func_type_id,
            .status = .declared,
            .sig_span = expr.span,
        });

        self.currentScope().defineSymbol(func_sym) catch |err| switch (err) {
            error.SymbolAlreadyDefined => {
                const previous = self.currentScope().lookupSymbol(func_sig.name).?;
                var d = DiagnosticBuilder.err(
                    self.ctx,
                    "function `{s}` already declared in this scope",
                    .{func_sig.name},
                );
                _ = d.primaryLabel(expr.span, "redeclared here", .{});
                _ = d.secondaryLabel(previous.span, "first declared here", .{});
                d.emit();
            },
            else => return err,
        };
        try self.ctx.debug_names.addFunctionName(func_sym.id, func_sig.name);
    }

    fn checkExpr(
        self: *Checker,
        expr: *const ast.Expr,
        type_exp: ?TypeExpectation,
    ) anyerror!*CheckedExpr {
        switch (expr.*.kind) {
            .int_literal => |int| return try self.typedExpr(
                .{ .int_literal = int },
                self.type_store.builtins.int,
                type_exp,
                expr.span,
            ),
            .bool_literal => |b| return try self.typedExpr(
                .{ .bool_literal = b },
                self.type_store.builtins.bool,
                type_exp,
                expr.span,
            ),
            .unit_literal => return try self.typedExpr(
                .{ .unit_literal = {} },
                self.type_store.builtins.unit,
                type_exp,
                expr.span,
            ),
            .unary => return try self.checkUnaryExpr(expr, type_exp),
            .binary => return try self.checkBinaryExpr(expr, type_exp),
            .variable_decl => return try self.checkVariableDecl(expr),
            .identifier => return try self.checkIdentifier(expr, type_exp),
            .block => return try self.checkBlock(expr, type_exp, true),
            .func_type_signature => return try self.checkFunctionTypeSignature(expr),
            .func_def => return try self.checkFunctionDef(expr),
            .func_call => return try self.checkFunctionCall(expr, type_exp),
            .@"if" => return try self.checkIfExpression(expr, type_exp),
            // else => return error.Unimplemented,
        }
    }

    fn checkIfExpression(
        self: *Checker,
        expr: *const ast.Expr,
        type_exp: ?TypeExpectation,
    ) !*CheckedExpr {
        const if_expr = expr.kind.@"if";

        const bool_exp = TypeExpectation{
            .type_id = self.type_store.builtins.bool,
            .span = if_expr.condition.span,
            .reason = "if condition must be of type Bool",
        };
        const cond_checked = try self.checkExpr(if_expr.condition, bool_exp);

        const then_checked = try self.checkExpr(if_expr.then_branch, type_exp);

        if (if_expr.else_branch == null and then_checked.type_id != self.type_store.builtins.unit) {
            var d = DiagnosticBuilder.err(
                self.ctx,
                "if expression without an else branch must return Unit",
                .{},
            );
            const span = if (std.meta.activeTag(then_checked.kind) == .block)
                then_checked.kind.block.tail.?.span
            else
                then_checked.span;

            _ = d.primaryLabel(
                // then_checked.kind.block.tail.?.span, // FIXME: not good
                span,
                "this has type `{s}`, expected `Unit`",
                .{self.type_store.formatTypeName(then_checked.type_id)},
            );
            _ = d.note(
                "if expressions without an else branch are used as statements and must not produce a value",
                .{},
            );
            d.emit();

            return try self.typedExpr(
                .{ .@"if" = .{
                    .condition = cond_checked,
                    .then_branch = then_checked,
                    .else_branch = null,
                } },
                self.type_store.builtins.err,
                type_exp,
                expr.span,
            );
        }

        var else_checked: ?*CheckedExpr = null;
        if (if_expr.else_branch) |elseBranch| {
            const else_exp = if (type_exp) |th| th else TypeExpectation{
                .type_id = then_checked.type_id,
                .span = then_checked.span,
                .reason = "if branches must have the same type",
            };
            else_checked = try self.checkExpr(elseBranch, else_exp);
        }

        const result_type = if (else_checked) |_| then_checked.type_id else self.type_store.builtins.unit;
        return try self.typedExpr(
            .{ .@"if" = .{
                .condition = cond_checked,
                .then_branch = then_checked,
                .else_branch = else_checked,
            } },
            result_type,
            type_exp,
            expr.span,
        );
    }

    fn checkFunctionCall(
        self: *Checker,
        expr: *const ast.Expr,
        type_exp: ?TypeExpectation,
    ) !*CheckedExpr {
        const func_call = expr.kind.func_call;
        const func_sym = self.currentScope().lookupSymbol(func_call.callee);
        if (func_sym == null) {
            var d = DiagnosticBuilder.err(
                self.ctx,
                "call to undeclared function `{s}`",
                .{func_call.callee},
            );
            _ = d.primaryLabel(expr.span, "function call found here", .{})
                .note(
                "declare a function type signature like `{s} : <params> -> <return type>`",
                .{func_call.callee},
            );
            d.emit();
            return try self.typedExpr(
                .{
                    .func_call = .{
                        .callee_name = func_call.callee,
                        .args = &[_]*const CheckedExpr{},
                        .function_id = 0, // NOTE: id doesn't matter since it's error-typed
                        .call_id = 0,
                    },
                },
                self.type_store.builtins.err,
                type_exp,
                expr.span,
            );
        }

        if (func_sym.?.kind != .function) {
            var d = DiagnosticBuilder.err(self.ctx, "symbol `{s}` is not a function", .{func_call.callee});
            _ = d.primaryLabel(expr.span, "call found here", .{})
                .note(
                "`{s}` is of type `{s}`",
                .{ func_call.callee, self.type_store.formatTypeName(func_sym.?.type_id) },
            );
            d.emit();
            return try self.typedExpr(
                .{
                    .func_call = .{
                        .callee_name = func_call.callee,
                        .args = &[_]*const CheckedExpr{},
                        .function_id = 0, // NOTE: id doesn't matter since it's error-typed
                        .call_id = 0,
                    },
                },
                self.type_store.builtins.err,
                type_exp,
                expr.span,
            );
        }

        const domain_id = self.type_store.types.items[func_sym.?.type_id].function.domain;
        const codomain_id = self.type_store.types.items[func_sym.?.type_id].function.codomain;

        const param_types = try self.collectParamTypes(domain_id);
        if (param_types.len != func_call.args.len) {
            var d = DiagnosticBuilder.err(
                self.ctx,
                "function `{s}` expected {d} arguments, got {d}",
                .{ func_call.callee, param_types.len, func_call.args.len },
            );
            d.primaryLabel(expr.span, "function call found here", .{}).emit();
        }

        var checked_args = try self.ctx.allocator.alloc(*CheckedExpr, func_call.args.len);
        for (func_call.args, 0..) |argExpr, idx| {
            const expected_type_id = if (idx < param_types.len)
                param_types[idx]
            else
                self.type_store.builtins.err;

            const arg_exp = TypeExpectation{
                .type_id = expected_type_id,
                .span = null, // TODO: store param spans in Symbol
                .reason = "function parameter type",
            };
            checked_args[idx] = try self.checkExpr(argExpr, arg_exp);
        }

        // const func_info = self.functions.get(func_sym.?.id);
        // if (func_info) |info| {
        //     std.debug.print("function `{s}` is currently {s}\n", .{
        //         info.name, @tagName(info.status),
        //     });
        //     if (info.status == .declared) {
        //         var d = DiagnosticBuilder.err(
        //             self.ctx,
        //             "function `{s}` is declared but not defined",
        //             .{func_call.callee},
        //         );
        //         _ = d.primaryLabel(expr.span, "call found here", .{})
        //             .secondaryLabel(info.sig_span, "declared here", .{})
        //             .emit();
        //     }
        // }

        return try self.typedExpr(
            .{
                .func_call = .{
                    .callee_name = func_call.callee,
                    .args = checked_args,
                    .function_id = func_sym.?.id,
                    .call_id = self.getNewCallId(),
                },
            },
            codomain_id,
            type_exp,
            expr.span,
        );
    }

    fn checkFunctionDef(self: *Checker, expr: *const ast.Expr) !*CheckedExpr {
        const func_def = expr.kind.func_def;
        const func_sig = self.currentScope().lookupSymbol(func_def.name);

        if (func_sig) |sym| {
            if (sym.kind != .function) {
                var d = DiagnosticBuilder.err(
                    self.ctx,
                    "symbol `{s}` already declared and is not a function",
                    .{func_def.name},
                );
                _ = d.primaryLabel(expr.span, "function definition found here", .{})
                    .note(
                    "`{s}` is of type `{s}`",
                    .{ func_def.name, self.type_store.formatTypeName(sym.type_id) },
                );
                d.emit();
                return try self.typedExpr(
                    .{
                        .func_decl = .{
                            .name = func_def.name,
                            .body = undefined,
                            .params = undefined,
                            .function_id = sym.id,
                        },
                    },
                    self.type_store.builtins.err,
                    null,
                    expr.span,
                );
            }
        }

        var checked_params: std.ArrayList(checked_ast.Param) = .empty;

        if (func_sig == null) {
            var d = DiagnosticBuilder.err(
                self.ctx,
                "function `{s}` has no type signature",
                .{func_def.name},
            );
            _ = d.primaryLabel(expr.span, "definition found here", .{});
            _ = d.note("add a signature like `{s} : <params> -> <return type>`", .{func_def.name});
            d.emit();
            return try self.typedExpr(
                .{
                    .func_decl = .{
                        .name = func_def.name,
                        .body = undefined,
                        .params = undefined,
                        .function_id = 0, // id doesn't matter since it's error-typed
                    },
                },
                self.type_store.builtins.err,
                null,
                expr.span,
            );
        }

        if (self.functions.get(func_sig.?.id)) |info| {
            if (info.status == .defined) {
                var d = DiagnosticBuilder.err(
                    self.ctx,
                    "function `{s}` is already defined",
                    .{func_def.name},
                );
                _ = d.primaryLabel(expr.span, "redefinition found here", .{})
                    .secondaryLabel(info.def_span.?, "previous definition here", .{})
                    .note("consider removing one of these", .{})
                    .emit();
                return try self.typedExpr(
                    .{ .func_decl = .{
                        .name = func_def.name,
                        .body = undefined,
                        .params = try checked_params.toOwnedSlice(self.ctx.allocator),
                        .function_id = func_sig.?.id,
                    } },
                    self.type_store.builtins.err,
                    null,
                    expr.span,
                );
            }
        }

        try self.markFunctionAs(func_sig.?.id, .defining, expr.span);

        const domain_id = self.type_store.types.items[func_sig.?.type_id].function.domain;
        const codomain_id = self.type_store.types.items[func_sig.?.type_id].function.codomain;

        const params = try self.collectParamTypes(domain_id);
        if (func_def.params.len != params.len) {
            var d = DiagnosticBuilder.err(
                self.ctx,
                "function `{s}` type signature declares {d} parameters, but definition has {d}",
                .{ func_def.name, params.len, func_def.params.len },
            );
            _ = d.primaryLabel(expr.span, "but found {d} here", .{func_def.params.len})
                .secondaryLabel(func_sig.?.domain_span.?, "expected {d} params here", .{params.len})
                .emit();

            return try self.typedExpr(
                .{ .func_decl = .{
                    .name = func_def.name,
                    .body = undefined,
                    .params = undefined,
                    .function_id = func_sig.?.id,
                } },
                self.type_store.builtins.err,
                null,
                expr.span,
            );
        }

        std.debug.print("Collected param types: ", .{});
        for (params) |pid| {
            std.debug.print("{s} ", .{self.type_store.formatTypeName(pid)});
        }
        std.debug.print("\n", .{});

        try self.enterNewScope();
        defer self.exitScope();

        for (params, 0..) |paramTypeId, idx| {
            const param = func_def.params[idx];
            const id = self.getNewId();

            try checked_params.append(self.ctx.allocator, .{
                .name = param.name,
                .type_id = paramTypeId,
                .local_id = id,
                .span = param.span,
            });
            const param_sym = type_store.Symbol{
                .name = param.name,
                .type_id = paramTypeId,
                .kind = .variable,
                .id = id,
                .span = param.span, // FIXME: add spans to params
                .domain_span = null,
                .codomain_span = null,
            };
            self.currentScope().defineSymbol(param_sym) catch |err| switch (err) {
                error.SymbolAlreadyDefined => {
                    var d = DiagnosticBuilder.err(
                        self.ctx,
                        "parameter name `{s}` is duplicated",
                        .{param.name},
                    );
                    _ = d.primaryLabel(param_sym.span, "redeclared here", .{})
                        .note("consider renaming one of these parameters", .{})
                        .emit();
                },
                else => return err,
            };
            try self.ctx.debug_names.addLocalName(param_sym.id, param.name);
        }

        const return_exp = TypeExpectation{
            .type_id = codomain_id,
            .span = func_sig.?.codomain_span,
            .reason = "declared return type here",
        };
        const body_checked = if (std.meta.activeTag(func_def.body.kind) == .block)
            try self.checkBlock(func_def.body, return_exp, false)
        else
            try self.checkExpr(func_def.body, return_exp);

        var used_locals = std.AutoHashMap(ids.LocalId, void).init(self.ctx.allocator);
        try collectUsedLocals(body_checked, &used_locals);

        for (checked_params.items) |param| {
            if (!used_locals.contains(param.local_id)) {
                var d = DiagnosticBuilder.warn(
                    self.ctx,
                    "parameter `{s}` is not used in the function body",
                    .{param.name},
                );
                _ = d.primaryLabel(param.span, "declared here", .{})
                    .emit();
            }
        }

        try self.markFunctionAs(func_sig.?.id, .defined, expr.span);

        return try self.typedExpr(
            .{ .func_decl = .{
                .name = func_def.name,
                .body = body_checked,
                .params = try checked_params.toOwnedSlice(self.ctx.allocator),
                .function_id = func_sig.?.id,
            } },
            func_sig.?.type_id,
            null,
            expr.span,
        );
    }

    fn collectUsedLocals(
        expr: *const CheckedExpr,
        used: *std.AutoHashMap(ids.LocalId, void),
    ) !void {
        switch (expr.kind) {
            .identifier => |ident| {
                try used.put(ident.local_id, {});
            },
            .unary => |unary| try collectUsedLocals(unary.right, used),
            .binary => |binary| {
                try collectUsedLocals(binary.left, used);
                try collectUsedLocals(binary.right, used);
            },
            .block => |block| {
                for (block.stmts) |stmt| try collectUsedLocals(stmt, used);
                if (block.tail) |tail| try collectUsedLocals(tail, used);
            },
            .func_call => |call| {
                for (call.args) |arg| try collectUsedLocals(arg, used);
            },
            .@"if" => |ifExpr| {
                try collectUsedLocals(ifExpr.condition, used);
                try collectUsedLocals(ifExpr.then_branch, used);
                if (ifExpr.else_branch) |elseBranch| try collectUsedLocals(elseBranch, used);
            },
            else => {},
        }
    }

    fn markFunctionAs(
        self: *Checker,
        func_id: ids.FunctionId,
        status: FunctionStatus,
        span: Span,
    ) !void {
        var info = self.functions.getPtr(func_id) orelse return error.FunctionNotFound;
        info.status = status;
        switch (status) {
            .defined => info.def_span = span,
            else => {},
        }
    }

    fn collectParamTypes(self: *const Checker, type_id: TypeId) ![]TypeId {
        const type_item = self.type_store.types.items[type_id];
        var param_types: std.ArrayList(TypeId) = .empty;

        switch (type_item) {
            .unit => {}, // NOTE: is this good?
            .product => |prod| {
                // try paramTypes.append(self.ctx.allocator, prod.left);
                const left_tids = try self.collectParamTypes(prod.left);
                for (left_tids) |tid| {
                    try param_types.append(self.ctx.allocator, tid);
                }
                const right_tids = try self.collectParamTypes(prod.right);
                for (right_tids) |tid| {
                    try param_types.append(self.ctx.allocator, tid);
                }
            },
            else => {
                try param_types.append(self.ctx.allocator, type_id);
            },
        }

        return param_types.toOwnedSlice(self.ctx.allocator);
    }

    fn checkFunctionTypeSignature(self: *Checker, expr: *const ast.Expr) !*CheckedExpr {
        const func_sig = expr.kind.func_type_signature;
        const sym = self.currentScope().lookupSymbol(func_sig.name) orelse return error.FunctionNotFound;
        const func_type = self.type_store.types.items[sym.type_id].function;

        const domain = func_sig.ty.kind.function.domain;
        const codomain = func_sig.ty.kind.function.codomain;

        return try self.typedExpr(
            .{
                .func_type_signature = .{
                    .name = func_sig.name,
                    .domain = .{ .type_id = func_type.domain, .span = domain.span },
                    .codomain = .{ .type_id = func_type.codomain, .span = codomain.span },
                },
            },
            self.type_store.builtins.unit,
            null,
            expr.span,
        );
    }

    fn resolveTypeExpr(self: *Checker, type_expr: *const ast.TypeExpr) !TypeId {
        switch (type_expr.kind) {
            .named => |typeName| {
                if (self.type_store.resolve(typeName)) |tid| {
                    return tid;
                } else {
                    var d = DiagnosticBuilder.err(self.ctx, "unknown type `{s}`", .{typeName});
                    _ = d.primaryLabel(type_expr.span, "type not found in scope", .{});
                    d.emit();
                    return self.type_store.builtins.err;
                }
            },
            .unit => return self.type_store.builtins.unit,
            .product => |prod| {
                const left_id = try self.resolveTypeExpr(prod.left);
                const right_id = try self.resolveTypeExpr(prod.right);
                return self.type_store.addType(
                    .{ .product = .{
                        .left = left_id,
                        .right = right_id,
                    } },
                );
            },
            .function => |func| {
                const domain_id = try self.resolveTypeExpr(func.domain);
                const codomain_id = try self.resolveTypeExpr(func.codomain);
                return self.type_store.addType(
                    .{ .function = .{
                        .domain = domain_id,
                        .codomain = codomain_id,
                    } },
                );
            },
        }
    }

    fn checkBlock(
        self: *Checker,
        expr: *const ast.Expr,
        type_exp: ?TypeExpectation,
        creates_scope: bool,
    ) !*CheckedExpr {
        const block = expr.kind.block;

        if (creates_scope) try self.enterNewScope();
        defer if (creates_scope) self.exitScope();

        var checked_stmts = try self.ctx.allocator.alloc(*CheckedExpr, block.stmts.len);
        for (block.stmts, 0..) |stmt, idx| {
            checked_stmts[idx] = try self.checkExpr(stmt, null);
        }

        var tail_checked: ?*CheckedExpr = null;
        if (block.tail) |tailExpr| {
            tail_checked = try self.checkExpr(tailExpr, type_exp);
        }

        return try self.typedExpr(
            .{ .block = .{
                .stmts = checked_stmts,
                .tail = tail_checked,
            } },
            if (tail_checked) |t| t.type_id else self.type_store.builtins.unit,
            type_exp,
            expr.span,
        );
    }

    fn checkIdentifier(
        self: *Checker,
        expr: *const ast.Expr,
        type_exp: ?TypeExpectation,
    ) !*CheckedExpr {
        const ident_name = expr.kind.identifier;
        const symbol = self.currentScope().lookupSymbol(ident_name);
        if (symbol == null) {
            var d = DiagnosticBuilder.err(self.ctx, "undeclared variable `{s}`", .{ident_name});
            _ = d.primaryLabel(expr.span, "use found here", .{});
            d.emit();

            // Return a dummy expr of error type
            return try self.typedExpr(
                .{ .identifier = .{ .name = ident_name, .local_id = 0 } }, // NOTE: id doesn't matter since it's error-typed
                self.type_store.builtins.err,
                null,
                expr.span,
            );
        }

        std.debug.print("Identifier `{s}` resolved to `{s}`\n", .{
            ident_name,
            self.type_store.formatTypeName(symbol.?.type_id),
        });
        return try self.typedExpr(
            .{ .identifier = .{ .name = ident_name, .local_id = symbol.?.id } },
            symbol.?.type_id,
            type_exp,
            expr.span,
        );
    }

    fn checkVariableDecl(self: *Checker, expr: *const ast.Expr) !*CheckedExpr {
        const var_decl = expr.kind.variable_decl;

        if (self.type_store.resolve(var_decl.name)) |_| {
            var d = DiagnosticBuilder.err(
                self.ctx,
                "variable `{s}` shadows a type name",
                .{var_decl.name},
            );
            _ = d.primaryLabel(
                expr.span,
                "`{s}` is a type, not a valid variable name",
                .{var_decl.name},
            );
            _ = d.note("types in scope: Int, Bool, Unit", .{}); // TODO: enumarate types in scope
            d.emit();
        }

        var value_exp: ?TypeExpectation = null;
        if (var_decl.type) |typeExpr| {
            const expected_type_id = try self.resolveTypeExpr(typeExpr);
            value_exp = TypeExpectation{
                .type_id = expected_type_id,
                .span = typeExpr.span,
                .reason = "declared type annotation here",
            };
        }

        const value_checked = try self.checkExpr(var_decl.value, value_exp);

        const id = self.getNewId();

        var result_type: TypeId = self.type_store.builtins.unit;
        if (self.type_store.resolve(var_decl.name)) |_| {
            result_type = self.type_store.builtins.err;
        } else {
            self.declareVariable(var_decl.name, value_checked.type_id, id, expr.span) catch |err| switch (err) {
                error.VariableAlreadyDeclared => {
                    // TODO: add secondary label pointing to the original declaration (when `Symbol` stores span)
                    const previous = self.currentScope().lookupSymbol(var_decl.name).?;
                    var d = DiagnosticBuilder.err(
                        self.ctx,
                        "variable `{s}` already declared in this scope",
                        .{var_decl.name},
                    );
                    _ = d.primaryLabel(expr.span, "redeclared here", .{});
                    _ = d.secondaryLabel(previous.span, "first declared here", .{});
                    d.emit();
                    result_type = self.type_store.builtins.err;
                },
                else => return err,
            };
        }

        return try self.typedExpr(
            .{ .variable_decl = .{
                .name = var_decl.name,
                .value = value_checked,
                .local_id = id,
            } },
            result_type,
            null,
            expr.span,
        );
    }

    fn declareVariable(
        self: *Checker,
        name: []const u8,
        type_id: TypeId,
        id: usize,
        span: Span,
    ) !void {
        const scope = self.currentScope();
        // if (scope.lookupSymbol(name)) |_| {
        //     return error.VariableAlreadyDeclared;
        // }
        if (scope.symbols.contains(name)) {
            return error.VariableAlreadyDeclared;
        }

        const symbol = type_store.Symbol{
            .name = name,
            .type_id = type_id,
            .kind = .variable,
            .id = id,
            .span = span,
            .domain_span = null,
            .codomain_span = null,
        };

        try self.currentScope().defineSymbol(symbol);
        try self.ctx.debug_names.addLocalName(symbol.id, name);
    }

    fn checkBinaryExpr(
        self: *Checker,
        expr: *const ast.Expr,
        expected: ?TypeExpectation,
    ) !*CheckedExpr {
        const binary = expr.kind.binary;
        switch (binary.operator) {
            .plus, .minus, .multiply, .divide, .exponent => {
                const int_exp = TypeExpectation{
                    .type_id = self.type_store.builtins.int,
                    .span = null, // NOTE: should this be null?
                    .reason = "arithmetic operator requires Int operands",
                };

                const left_checked = try self.checkExpr(binary.left, int_exp);
                const right_checked = try self.checkExpr(binary.right, int_exp);

                var result_type: TypeId = self.type_store.builtins.int;
                if (left_checked.type_id == self.type_store.builtins.err or
                    right_checked.type_id == self.type_store.builtins.err)
                {
                    result_type = self.type_store.builtins.err;
                }

                return try self.typedExpr(
                    .{ .binary = .{
                        .left = left_checked,
                        .operator = binary.operator,
                        .right = right_checked,
                    } },
                    result_type,
                    expected,
                    expr.span,
                );
            },
            .less_than, .greater_than, .less_than_or_eq, .greater_than_or_eq => {
                const int_exp = TypeExpectation{
                    .type_id = self.type_store.builtins.int,
                    .span = null, // NOTE: should this be null?
                    .reason = "comparison operator requires Int operands",
                };

                const left_checked = try self.checkExpr(binary.left, int_exp);
                const right_checked = try self.checkExpr(binary.right, int_exp);

                var result_type: TypeId = self.type_store.builtins.bool;
                if (left_checked.type_id == self.type_store.builtins.err or
                    right_checked.type_id == self.type_store.builtins.err)
                {
                    result_type = self.type_store.builtins.err;
                }

                return try self.typedExpr(
                    .{ .binary = .{
                        .left = left_checked,
                        .operator = binary.operator,
                        .right = right_checked,
                    } },
                    result_type,
                    expected,
                    expr.span,
                );
            },
            .equal, .not_equal => {
                const left_checked = try self.checkExpr(binary.left, null);
                const left_exp = TypeExpectation{
                    .type_id = left_checked.type_id,
                    .span = null, // NOTE: should this be null?
                    .reason = "equality operator requires both operands to have the same type",
                };
                const right_checked = try self.checkExpr(binary.right, left_exp);

                var result_type: TypeId = self.type_store.builtins.bool;
                if (left_checked.type_id == self.type_store.builtins.err or
                    right_checked.type_id == self.type_store.builtins.err)
                {
                    result_type = self.type_store.builtins.err;
                }

                return try self.typedExpr(
                    .{ .binary = .{
                        .left = left_checked,
                        .operator = binary.operator,
                        .right = right_checked,
                    } },
                    result_type,
                    expected,
                    expr.span,
                );
            },
            .logical_or, .logical_and => {
                const bool_exp = TypeExpectation{
                    .type_id = self.type_store.builtins.bool,
                    .span = null, // NOTE: should this be null?
                    .reason = "logical operator requires Bool operands",
                };
                const left_checked = try self.checkExpr(binary.left, bool_exp);
                const right_checked = try self.checkExpr(binary.right, bool_exp);

                var result_type: TypeId = self.type_store.builtins.bool;
                if (left_checked.type_id == self.type_store.builtins.err or
                    right_checked.type_id == self.type_store.builtins.err)
                {
                    result_type = self.type_store.builtins.err;
                }

                return try self.typedExpr(
                    .{ .binary = .{
                        .left = left_checked,
                        .operator = binary.operator,
                        .right = right_checked,
                    } },
                    result_type,
                    expected,
                    expr.span,
                );
            },
            .type_prod => return error.IdkLol,
        }
    }

    fn checkUnaryExpr(
        self: *Checker,
        expr: *const ast.Expr,
        expected: ?TypeExpectation,
    ) !*CheckedExpr {
        const unary = expr.kind.unary;
        switch (unary.operator) {
            .plus, .minus => {
                const int_exp = TypeExpectation{
                    .type_id = self.type_store.builtins.int,
                    .span = null, // NOTE: should this be null?
                    .reason = "unary plus and minus require Int operand",
                };
                const right_checked = try self.checkExpr(unary.right, int_exp);

                const result_type = if (right_checked.type_id == self.type_store.builtins.err)
                    self.type_store.builtins.err
                else
                    self.type_store.builtins.int;

                return try self.typedExpr(
                    .{ .unary = .{
                        .operator = unary.operator,
                        .right = right_checked,
                    } },
                    result_type,
                    expected,
                    expr.span,
                );
            },
            .not => {
                const bool_exp = TypeExpectation{
                    .type_id = self.type_store.builtins.bool,
                    .span = null, // NOTE: should this be null?
                    .reason = "logical not requires Bool operand",
                };
                const right_checked = try self.checkExpr(unary.right, bool_exp);

                const result_type = if (right_checked.type_id == self.type_store.builtins.err)
                    self.type_store.builtins.err
                else
                    self.type_store.builtins.bool;

                return try self.typedExpr(
                    .{ .unary = .{
                        .operator = unary.operator,
                        .right = right_checked,
                    } },
                    result_type,
                    expected,
                    expr.span,
                );
            },
        }
    }

    fn typedExpr(
        self: *const Checker,
        data: CheckedExprData,
        result_type: TypeId,
        type_exp: ?TypeExpectation,
        span: Span,
    ) !*CheckedExpr {
        if (type_exp != null and
            result_type != type_exp.?.type_id and
            result_type != self.type_store.builtins.err and
            type_exp.?.type_id != self.type_store.builtins.err)
        {
            var d = DiagnosticBuilder.err(
                self.ctx,
                "type mismatch: expected `{s}`, got `{s}`",
                .{
                    self.type_store.formatTypeName(type_exp.?.type_id),
                    self.type_store.formatTypeName(result_type),
                },
            );
            _ = d.primaryLabel(
                span,
                "this has type `{s}`",
                .{self.type_store.formatTypeName(result_type)},
            );
            if (type_exp.?.span) |expectationSpan| {
                _ = d.secondaryLabel(expectationSpan, "{s}", .{type_exp.?.reason});
            }
            d.emit();
            // swallow the mismatch, but mark expression as error-typed
            return try self.heapAlloc(CheckedExpr, .{
                .type_id = self.type_store.builtins.err,
                .kind = data,
                .span = span,
            });
        }
        return try self.heapAlloc(CheckedExpr, .{
            .type_id = result_type,
            .kind = data,
            .span = span,
        });
    }

    fn getNewId(self: *Checker) usize {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn getNewCallId(self: *Checker) usize {
        const id = self.next_call_id;
        self.next_call_id += 1;
        return id;
    }

    fn currentScope(self: *const Checker) *Scope {
        return self.scopes.items[self.scopes.items.len - 1];
    }

    fn enterNewScope(self: *Checker) !void {
        const new_scope = try self.ctx.allocator.create(Scope);
        new_scope.* = Scope.init(self.ctx.allocator, self.currentScope());
        try self.scopes.append(self.ctx.allocator, new_scope);
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
