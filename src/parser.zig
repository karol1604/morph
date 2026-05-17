const std = @import("std");
const token = @import("token.zig");
const span = @import("span.zig");
const ast = @import("ast.zig");
const utils = @import("utils.zig");

const Token = token.Token;
const TokenType = token.TokenType;

const Span = span.Span;
const Location = span.Location;

const Expr = ast.Expr;
const TypeExpr = ast.TypeExpr;
const BinaryOperator = ast.BinaryOperator;
const UnaryOperator = ast.UnaryOperator;
const Precedence = ast.Precedence;

const CompilerContext = @import("context.zig").CompilerContext;

pub const Parser = struct {
    tokens: []const Token,
    current: usize = 0,
    ctx: *CompilerContext,

    pub fn init(toks: []const Token, ctx: *CompilerContext) Parser {
        return .{
            .tokens = toks,
            .ctx = ctx,
        };
    }

    fn heapAlloc(self: *const Parser, comptime T: type, value: T) !*T {
        const ptr = try self.ctx.allocator.create(T);
        ptr.* = value;
        return ptr;
    }

    pub fn parse(self: *Parser) ![]*const Expr {
        var res: std.ArrayList(*const Expr) = .empty;
        _ = self.consumeSeparators(); // skip leading separators

        while (self.currentToken().kind != .eof) {
            const expr = try self.parseTopLevelExpression();
            try res.append(self.ctx.allocator, expr);

            if (self.currentToken().kind == .eof) {
                break;
            }

            if (!self.consumeSeparators()) {
                std.debug.print(
                    "Expected expression separator, found {f}\n",
                    .{self.currentToken().kind},
                );
                return error.ExpectedExpressionSeparator;
            }

            _ = self.consumeSeparators();
        }

        return try res.toOwnedSlice(self.ctx.allocator);
    }

    fn skipNewlines(self: *Parser) void {
        while (self.currentToken().kind == .newline) {
            self.advance();
        }
    }

    fn consumeSeparators(self: *Parser) bool {
        var consumed = false;

        while (true) {
            switch (self.currentToken().kind) {
                .newline, .semicolon => {
                    consumed = true;
                    self.advance();
                },
                else => return consumed,
            }
        }
    }

    fn parseTopLevelExpression(self: *Parser) !*Expr {
        if (self.currentToken().kind == .kw_let) {
            return try self.parseVariableDecl();
        }

        if (self.currentToken().kind != .identifier) {
            return try self.parseExpression(.lowest);
        }

        switch (self.peekToken().kind) {
            .colon => return try self.parseFunctionTypeSignature(),
            .double_right_arrow => return try self.parseFunctionDefinition(),
            .identifier => {
                if (self.isFunctionDefinition()) {
                    return try self.parseFunctionDefinition();
                }
                return try self.parseExpression(.lowest);
            },
            // .LParen => {
            //     if (self.isFunctionDefinition()) {
            //         std.debug.print("Parsing function definition...\n", .{});
            //         return try self.parseFunctionDefinition();
            //         // return error.FunctionDefNotSupported;
            //     }
            //     return try self.parseExpression(.Lowest); // function call
            // },
            else => return try self.parseExpression(.lowest),
        }
    }

    fn parseDeclOrExpr(self: *Parser) anyerror!*Expr {
        if (self.currentToken().kind == .kw_let) {
            return try self.parseVariableDecl();
        }
        return try self.parseExpression(.lowest);
    }

    fn parseFunctionDefinition(self: *Parser) !*Expr {
        const name = try self.parseIdentifier(); // consumes the name

        var params: std.ArrayList([]const u8) = .empty;

        while (self.currentToken().kind != .double_right_arrow) {
            const param = try self.parseIdentifier();
            if (std.meta.activeTag(param.kind) != .identifier) {
                return error.ExpectedIdentifier;
            }
            try params.append(self.ctx.allocator, param.kind.identifier);

            // if (self.currentToken().kind == .Comma) {
            //     self.advance(); // consume comma
            // } else {
            //     break;
            // }
        }

        _ = try self.expect(.double_right_arrow);

        const body = try self.parseExpression(.lowest);
        // if (std.meta.activeTag(body.kind) != .Block) {
        //     // require semicolon if body is not a block
        //     _ = try self.expect(.Semicolon);
        // }

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .func_def = .{
                .name = name.kind.identifier,
                .params = try params.toOwnedSlice(self.ctx.allocator),
                .body = body,
            } },
            .span = Span.join(name.span, body.span),
        });
    }

    // fn isFunctionDefinition(self: *const Parser) bool {
    //     var offset: usize = 1;
    //
    //     if (self.current + offset >= self.tokens.len) return false;
    //     if (self.tokens[self.current + offset].kind != .LParen) return false;
    //
    //     offset += 1;
    //     var openParens: usize = 1;
    //     while (self.current + offset < self.tokens.len and openParens > 0) : (offset += 1) {
    //         const tok = self.tokens[self.current + offset];
    //         if (tok.kind == .LParen) {
    //             openParens += 1;
    //         } else if (tok.kind == .RParen) {
    //             openParens -= 1;
    //         }
    //     }
    //
    //     if (self.current + offset < self.tokens.len) {
    //         return self.tokens[self.current + offset].kind == .DoubleRightArrow;
    //     }
    //
    //     return false;
    // }

    fn isFunctionDefinition(self: *const Parser) bool {
        var offset: usize = 1; // skip the function name
        while (self.current + offset < self.tokens.len) {
            const tok = self.tokens[self.current + offset];
            switch (tok.kind) {
                .identifier => offset += 1,
                .double_right_arrow => return true,
                else => return false,
            }
        }
        return false;
    }

    // FIXME: remove the `pub`
    pub fn parseExpression(self: *Parser, prec: Precedence) anyerror!*Expr {
        var expr = switch (self.currentToken().kind) {
            .int_literal => try self.parseIntLiteral(),
            .identifier => try self.parseIdentifierOrFunctionCall(),
            .kw_true, .kw_false => try self.parseBoolLiteral(),
            .kw_if => try self.parseIfExpression(),
            .plus, .minus, .bang => try self.parseUnaryExpression(),
            .lparen => try self.parseGroupExpression(),
            .lbrace => try self.parseBlockExpression(),
            else => {
                if (self.currentToken().kind == .kw_let) {
                    std.debug.print("`let` is not valid as a sub-expression\n", .{});
                    return error.LetInValuePosition;
                }
                std.debug.print("Invalid token: `{f}`\n", .{self.currentToken().kind});
                return error.UnsupportedToken;
            },
        };

        while (self.currentToken().kind != .eof and self.currentPrec() > @intFromEnum(prec)) {
            const op_kind = self.currentToken().kind;
            const semantic_op: ?BinaryOperator = getBinaryOperator(op_kind);

            if (semantic_op == null) {
                return expr;
            }

            expr = try self.parseBinaryExpression(expr, semantic_op.?, self.getTokenPrec(op_kind));
        }
        return expr;
    }

    fn parseIfExpression(self: *Parser) anyerror!*Expr {
        const start_span = self.currentToken().span;
        self.advance(); // consume `if`
        self.skipNewlines(); // allow newlines after `if`

        const condition = try self.parseExpression(.lowest);
        self.skipNewlines(); // allow newlines before `then`
        _ = try self.expect(.kw_then);
        self.skipNewlines(); // allow newlines after `then`
        const then_branch = try self.parseExpression(.lowest);

        var else_branch: ?*Expr = null;
        self.skipNewlines(); // allow newlines before `else`
        if (self.currentToken().kind == .kw_else) {
            self.advance(); // consume `else`
            self.skipNewlines(); // allow newlines after `else`
            else_branch = try self.parseExpression(.lowest);
        }

        const end_span = else_branch orelse then_branch;
        return self.heapAlloc(Expr, .{
            .kind = .{ .@"if" = .{
                .condition = condition,
                .then_branch = then_branch,
                .else_branch = else_branch,
            } },
            .span = Span.join(start_span, end_span.span),
        });
    }

    fn parseFunctionTypeSignature(self: *Parser) !*Expr {
        const name = try self.parseIdentifier(); // consumes the name
        _ = try self.expect(.colon);

        const domain = try self.parseTypeExpression(.lowest);

        _ = try self.expect(.right_arrow);

        const codomain = try self.parseTypeExpression(.lowest);

        // const semicl = try self.expect(.Semicolon);

        const func_type = try self.heapAlloc(TypeExpr, TypeExpr{
            .kind = .{ .function = .{
                .domain = domain,
                .codomain = codomain,
            } },
            .span = Span.join(name.span, codomain.span),
        });

        return self.heapAlloc(Expr, .{
            .kind = .{ .func_type_signature = .{
                .name = name.kind.identifier,
                .ty = func_type,
            } },
            .span = Span.join(name.span, codomain.span),
        });
    }

    fn parseTypeExpression(self: *Parser, prec: Precedence) !*const TypeExpr {
        var left = try self.parseTypePrefix();

        while (self.currentToken().kind != .eof and self.currentPrec() > @intFromEnum(prec)) {
            const tok = self.currentToken();
            std.debug.print("TOK: {f}\n", .{tok});

            // Only allow Type-valid operators here
            // var op: BinaryOperator = undefined;
            // switch (tok.kind) {
            //     .Cross => {
            //         op = .TypeProduct;
            //     }, // `×` symbol
            //     .Caret => {
            //         op = .Exponent;
            //     }, // `^` symbol
            //     else => return left,
            // }

            // self.advance();
            _ = try self.expect(.cross); // consume the `×` symbol

            // Recurse for the right side
            const right = try self.parseTypeExpression(self.getTokenPrec(tok.kind));

            left = try self.heapAlloc(TypeExpr, TypeExpr{
                .kind = .{ .product = .{
                    .left = left,
                    .right = right,
                } },
                .span = Span.join(left.span, right.span),
            });
        }

        return left;
    }

    fn parseTypeIdentifier(self: *Parser) !*TypeExpr {
        const start_span = self.currentToken().span;
        const name = try self.expectIdent(); // consumes the ident

        return self.heapAlloc(TypeExpr, TypeExpr{
            .kind = .{ .named = name },
            .span = Span.join(start_span, start_span),
        });
    }

    fn parseTypePrefix(self: *Parser) !*const TypeExpr {
        switch (self.currentToken().kind) {
            .identifier => return try self.parseTypeIdentifier(),
            // FIXME: will be useful when we allow stuff like Int^2 for fixed-size vectors
            // .IntLiteral => return try self.parseIntLiteral(),
            .lparen => return try self.parseTypeGroupExpression(),
            else => {
                std.debug.panic("&&&&& expected type: CURRENT: {f}\n", .{self.currentToken()});
                return error.ExpectedType;
            },
        }
    }

    fn parseTypeGroupExpression(self: *Parser) anyerror!*const TypeExpr {
        const start_span = self.currentToken().span;
        self.advance(); // consume the left paren

        if (self.currentToken().kind == .rparen) {
            const end_span = self.currentToken().span;
            self.advance(); // consume the right paren
            return self.heapAlloc(TypeExpr, .{
                .kind = .unit,
                .span = Span.join(start_span, end_span),
            });
        }

        const expr = try self.parseTypeExpression(.lowest);
        if (self.currentToken().kind != .rparen) {
            return error.UnclosedLParen;
        }
        self.advance(); // consume right paren
        return expr;
    }

    fn parseBinaryExpression(
        self: *Parser,
        lhs: *const Expr,
        op: BinaryOperator,
        prec: Precedence,
    ) !*Expr {
        self.advance(); // Consume the operator

        // NOTE: is this a hack? idk...
        const right_prec_adjust = if (op == .exponent) @intFromEnum(prec) - 1 else @intFromEnum(prec);
        const rhs = try self.parseExpression(@as(Precedence, @enumFromInt(right_prec_adjust)));

        const expr_span = Span.join(lhs.span, rhs.span);
        return self.heapAlloc(Expr, .{
            .kind = .{ .binary = .{
                .left = lhs,
                .operator = op,
                .right = rhs,
            } },
            .span = expr_span,
        });
    }

    fn parseBlockExpression(self: *Parser) !*Expr {
        // empty blocks evaluate to unit
        const start_span = self.currentToken().span;
        self.advance(); // consume the left brace
        _ = self.consumeSeparators(); // allow separators immediately after `{`

        var exprs: std.ArrayList(*Expr) = .empty;

        while (self.currentToken().kind != .rbrace and self.currentToken().kind != .eof) {
            // Parse the expression
            const expr = try self.parseDeclOrExpr();
            try exprs.append(self.ctx.allocator, expr);

            if (self.currentToken().kind == .rbrace) {
                break; // end of block, no more expressions
            }

            if (!self.consumeSeparators()) {
                std.debug.print(
                    "Expected expression separator or end of block, found {f}\n",
                    .{self.currentToken().kind},
                );
                return error.ExpectedExpressionSeparatorOrRBrace;
            }

            _ = self.consumeSeparators(); // allow multiple separators between expressions

        }

        const end_span = self.currentToken().span;
        _ = try self.expect(.rbrace);

        const owned_exprs = try exprs.toOwnedSlice(self.ctx.allocator);

        var stmts: []const *Expr = owned_exprs;
        var tail: ?*Expr = null;

        if (owned_exprs.len > 0) {
            stmts = owned_exprs[0 .. owned_exprs.len - 1];
            tail = owned_exprs[owned_exprs.len - 1];
        }

        return self.heapAlloc(Expr, .{
            .kind = .{ .block = .{ .stmts = stmts, .tail = tail } },
            .span = Span.join(start_span, end_span),
        });
    }

    fn parseGroupExpression(self: *Parser) !*Expr {
        const start_span = self.currentToken().span;
        self.advance(); // consume the left paren
        self.skipNewlines(); // allow newlines immediately after `(`

        if (self.currentToken().kind == .rparen) {
            const end_span = self.currentToken().span;
            self.advance(); // consume `)`

            return self.heapAlloc(Expr, .{
                .kind = .unit_literal,
                .span = Span.join(start_span, end_span),
            });
        }

        const expr = try self.parseExpression(.lowest);

        self.skipNewlines(); // allow newlines before `)`
        if (self.currentToken().kind != .rparen) {
            return error.UnclosedLParen;
        }
        self.advance(); // consume right paren
        return expr;
    }

    fn parseBoolLiteral(self: *Parser) !*Expr {
        const bool_tok = self.currentToken();
        const val = switch (bool_tok.kind) {
            .kw_true => true,
            .kw_false => false,
            else => unreachable,
        };

        self.advance();

        return self.heapAlloc(Expr, .{
            .kind = .{ .bool_literal = val },
            .span = bool_tok.span,
        });
    }

    fn parseIntLiteral(self: *Parser) !*Expr {
        const int_tok = self.currentToken();
        const value = switch (int_tok.kind) {
            .int_literal => |int| int,
            else => return error.ExpectedInt,
        };

        self.advance();

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .int_literal = value },
            .span = int_tok.span,
        });
    }

    fn parseVariableDecl(self: *Parser) !*Expr {
        const start_span = self.currentToken().span;
        self.advance(); // consume `let`

        const name = try self.expectIdent(); // consume the ident

        var ty: ?*const TypeExpr = null;
        if (self.currentToken().kind == .in) {
            self.advance(); // consume the `in`
            // ty = try self.expectIdent();
            ty = try self.parseTypeExpression(.lowest);
        }
        _ = try self.expect(.equal); // consume `=`

        const value = try self.parseExpression(.lowest);
        const end_span = value.span;

        return self.heapAlloc(Expr, .{
            .kind = .{ .variable_decl = .{
                .name = name,
                .value = value,
                .type = ty,
            } },
            .span = Span.join(start_span, end_span),
        });
    }

    fn parseIdentifier(self: *Parser) !*Expr {
        const start_span = self.currentToken().span;
        const name = try self.expectIdent(); // consumes the ident

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .identifier = name },
            .span = Span.join(start_span, start_span),
        });
    }

    fn parseIdentifierOrFunctionCall(self: *Parser) !*Expr {
        const start_span = self.currentToken().span;
        const name = try self.expectIdent(); // consumes the ident

        if (self.currentToken().kind == .lparen) {
            return try self.parseFunctionCall(name, start_span);
        }

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .identifier = name },
            .span = Span.join(start_span, start_span),
        });
    }

    fn parseFunctionCall(self: *Parser, callee: []const u8, start_span: Span) !*Expr {
        self.advance(); // consume the left paren
        self.skipNewlines(); // allow newlines immediately after `(`

        var args: std.ArrayList(*const Expr) = .empty;

        while (self.currentToken().kind != .rparen and self.currentToken().kind != .eof) {
            const arg = try self.parseExpression(.lowest);
            try args.append(self.ctx.allocator, arg);

            self.skipNewlines(); // allow newlines between arguments

            if (self.currentToken().kind == .comma) {
                self.advance(); // consume comma
                self.skipNewlines(); // allow newlines after comma
            } else {
                break;
            }
        }

        const end_span = self.currentToken().span;
        _ = try self.expect(.rparen);

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .func_call = .{
                .callee = callee,
                .args = try args.toOwnedSlice(self.ctx.allocator),
            } },
            .span = Span.join(start_span, end_span),
        });
    }

    fn parseUnaryExpression(self: *Parser) !*Expr {
        const op_tok = self.currentToken();
        const op = getUnaryOperator(op_tok.kind) orelse return {
            std.debug.print("Error: Invalid token for unary operator {any}\n", .{op_tok});
            return error.InvalidUnaryOperator;
        };

        self.advance();

        const rhs = try self.parseExpression(.prefix);
        return self.heapAlloc(Expr, Expr{
            .kind = .{ .unary = .{ .operator = op, .right = rhs } },
            .span = Span.join(op_tok.span, rhs.span),
        });
    }

    fn expect(self: *Parser, expected: TokenType) !Token {
        if (std.meta.eql(expected, self.currentToken().kind)) {
            const tok = self.currentToken();
            self.advance();
            return tok;
        }
        std.debug.print("Expected `{f}`, got `{f}`.\n", .{ expected, self.currentToken().kind });
        return error.UnexpectedToken;
    }

    /// consumes the current token if it's an identifier and returns its string value, otherwise returns an error
    fn expectIdent(self: *Parser) ![]const u8 {
        switch (self.currentToken().kind) {
            .identifier => |ident| {
                self.advance();
                return ident;
            },
            else => return error.ExpectedIdentifier,
        }
    }

    fn getUnaryOperator(token_type: TokenType) ?UnaryOperator {
        return switch (token_type) {
            .plus => .plus,
            .minus => .minus,
            .bang => .not,
            else => null,
        };
    }

    fn currentToken(self: *const Parser) Token {
        return self.tokens[self.current];
    }

    fn advance(self: *Parser) void {
        if (self.current < self.tokens.len - 1) {
            self.current += 1;
        }
    }

    fn peekToken(self: *const Parser) Token {
        if (self.current + 1 >= self.tokens.len) {
            return self.tokens[self.tokens.len - 1];
        }
        return self.tokens[self.current + 1];
    }

    fn getBinaryOperator(token_type: TokenType) ?BinaryOperator {
        return switch (token_type) {
            .plus => .plus,
            .minus => .minus,
            .star => .multiply,
            .slash => .divide,
            .caret => .exponent,
            .double_equal => .equal,
            .not_equal => .not_equal,
            .less_than => .less_than,
            .greater_than => .greater_than,
            .less_than_or_equal => .less_than_or_eq,
            .greater_than_or_equal => .greater_than_or_eq,
            .kw_and => .logical_and,
            .kw_or => .logical_or,
            else => null,
        };
    }

    fn getTokenPrec(_: *const Parser, token_type: TokenType) Precedence {
        return switch (token_type) {
            .kw_and, .kw_or => .logical,

            .double_equal, .not_equal => .equality,

            .less_than, .greater_than, .less_than_or_equal, .greater_than_or_equal => .comparison,

            .plus, .minus => .sum,

            .star, .slash, .cross => .product,

            .caret => .exponent,

            .lparen => .group,

            else => .lowest,
        };
    }

    fn currentPrec(self: *Parser) u8 {
        return @intFromEnum(self.getTokenPrec(self.currentToken().kind));
    }
};
