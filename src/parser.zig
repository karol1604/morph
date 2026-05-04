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

    pub fn parse(self: *Parser) ![]*Expr {
        var res: std.ArrayList(*Expr) = .empty;
        _ = self.consumeSeparators(); // skip leading separators

        while (self.currentToken().kind != .Eof) {
            const expr = try self.parseTopLevelExpression();
            try res.append(self.ctx.allocator, expr);

            if (self.currentToken().kind == .Eof) {
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
        while (self.currentToken().kind == .Newline) {
            self.advance();
        }
    }

    fn consumeSeparators(self: *Parser) bool {
        var consumed = false;

        while (true) {
            switch (self.currentToken().kind) {
                .Newline, .Semicolon => {
                    consumed = true;
                    self.advance();
                },
                else => return consumed,
            }
        }
    }

    fn parseTopLevelExpression(self: *Parser) !*Expr {
        if (self.currentToken().kind == .KwLet) {
            return try self.parseVariableDecl();
        }

        if (self.currentToken().kind != .Identifier) {
            return try self.parseExpression(.Lowest);
        }

        switch (self.peekToken().kind) {
            .Colon => return try self.parseFunctionTypeSignature(),
            .DoubleRightArrow => return try self.parseFunctionDefinition(),
            .Identifier => {
                if (self.isFunctionDefinition()) {
                    return try self.parseFunctionDefinition();
                }
                return try self.parseExpression(.Lowest);
            },
            // .LParen => {
            //     if (self.isFunctionDefinition()) {
            //         std.debug.print("Parsing function definition...\n", .{});
            //         return try self.parseFunctionDefinition();
            //         // return error.FunctionDefNotSupported;
            //     }
            //     return try self.parseExpression(.Lowest); // function call
            // },
            else => return try self.parseExpression(.Lowest),
        }
    }

    fn parseDeclOrExpr(self: *Parser) anyerror!*Expr {
        if (self.currentToken().kind == .KwLet) {
            return try self.parseVariableDecl();
        }
        return try self.parseExpression(.Lowest);
    }

    fn parseFunctionDefinition(self: *Parser) !*Expr {
        const name = try self.parseIdentifier(); // consumes the name

        var params: std.ArrayList([]const u8) = .empty;

        while (self.currentToken().kind != .DoubleRightArrow) {
            const param = try self.parseIdentifier();
            if (std.meta.activeTag(param.kind) != .Identifier) {
                return error.ExpectedIdentifier;
            }
            try params.append(self.ctx.allocator, param.kind.Identifier);

            // if (self.currentToken().kind == .Comma) {
            //     self.advance(); // consume comma
            // } else {
            //     break;
            // }
        }

        _ = try self.expect(.DoubleRightArrow);

        const body = try self.parseExpression(.Lowest);
        // if (std.meta.activeTag(body.kind) != .Block) {
        //     // require semicolon if body is not a block
        //     _ = try self.expect(.Semicolon);
        // }

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .FunctionDef = .{
                .name = name.kind.Identifier,
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
                .Identifier => offset += 1,
                .DoubleRightArrow => return true,
                else => return false,
            }
        }
        return false;
    }

    // FIXME: remove the `pub`
    pub fn parseExpression(self: *Parser, prec: Precedence) anyerror!*Expr {
        var expr = switch (self.currentToken().kind) {
            .IntLiteral => try self.parseIntLiteral(),
            .Identifier => try self.parseIdentifierOrFunctionCall(),
            .KwTrue, .KwFalse => try self.parseBoolLiteral(),
            // .KwLet => try self.parseVariableDecl(),
            .KwIf => try self.parseIfExpression(),
            .Plus, .Minus, .Bang => try self.parseUnaryExpression(),
            .LParen => try self.parseGroupExpression(),
            .LBrace => try self.parseBlockExpression(),
            else => {
                if (self.currentToken().kind == .KwLet) {
                    std.debug.print("`let` is not valid as a sub-expression\n", .{});
                    return error.LetInValuePosition;
                }
                std.debug.print("Invalid token: `{f}`\n", .{self.currentToken().kind});
                return error.UnsupportedToken;
            },
        };

        while (self.currentToken().kind != .Eof and self.currentPrec() > @intFromEnum(prec)) {
            const opKind = self.currentToken().kind;
            const semanticOp: ?BinaryOperator = getBinaryOperator(opKind);

            if (semanticOp == null) {
                return expr;
            }

            expr = try self.parseBinaryExpression(expr, semanticOp.?, self.getTokenPrec(opKind));
        }
        return expr;
    }

    fn parseIfExpression(self: *Parser) anyerror!*Expr {
        const startSpan = self.currentToken().span;
        self.advance(); // consume `if`
        self.skipNewlines(); // allow newlines after `if`

        std.debug.print("Parsing if expression...\n", .{});

        const condition = try self.parseExpression(.Lowest);
        self.skipNewlines(); // allow newlines before `then`
        _ = try self.expect(.KwThen);
        self.skipNewlines(); // allow newlines after `then`
        const thenBranch = try self.parseExpression(.Lowest);

        var elseBranch: ?*Expr = null;
        self.skipNewlines(); // allow newlines before `else`
        if (self.currentToken().kind == .KwElse) {
            self.advance(); // consume `else`
            self.skipNewlines(); // allow newlines after `else`
            elseBranch = try self.parseExpression(.Lowest);
        }

        const endSpan = elseBranch orelse thenBranch;
        return self.heapAlloc(Expr, .{
            .kind = .{ .If = .{
                .condition = condition,
                .thenBranch = thenBranch,
                .elseBranch = elseBranch,
            } },
            .span = Span.join(startSpan, endSpan.span),
        });
    }

    fn parseFunctionTypeSignature(self: *Parser) !*Expr {
        const name = try self.parseIdentifier(); // consumes the name
        _ = try self.expect(.Colon);

        const domain = try self.parseTypeExpression(.Lowest);

        _ = try self.expect(.RightArrow);

        const codomain = try self.parseTypeExpression(.Lowest);

        // const semicl = try self.expect(.Semicolon);

        const func_type = try self.heapAlloc(TypeExpr, TypeExpr{
            .kind = .{ .Function = .{
                .domain = domain,
                .codomain = codomain,
            } },
            .span = Span.join(name.span, codomain.span),
        });

        return self.heapAlloc(Expr, .{
            .kind = .{ .FunctionTypeSignature = .{
                .name = name.kind.Identifier,
                .ty = func_type,
            } },
            .span = Span.join(name.span, codomain.span),
        });
    }

    fn parseTypeExpression(self: *Parser, prec: Precedence) !*const TypeExpr {
        var left = try self.parseTypePrefix();

        while (self.currentToken().kind != .Eof and self.currentPrec() > @intFromEnum(prec)) {
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
            _ = try self.expect(.Cross); // consume the `×` symbol

            // Recurse for the right side
            const right = try self.parseTypeExpression(self.getTokenPrec(tok.kind));

            left = try self.heapAlloc(TypeExpr, TypeExpr{
                .kind = .{ .Product = .{
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
            .kind = .{ .Named = name },
            .span = Span.join(start_span, start_span),
        });
    }

    fn parseTypePrefix(self: *Parser) !*const TypeExpr {
        switch (self.currentToken().kind) {
            .Identifier => return try self.parseTypeIdentifier(),
            // .IntLiteral => return try self.parseIntLiteral(), // FIXME: what?
            .LParen => return try self.parseTypeGroupExpression(),
            else => {
                std.debug.panic("&&&&& expected type: CURRENT: {f}\n", .{self.currentToken()});
                return error.ExpectedType;
            },
        }
    }

    fn parseTypeGroupExpression(self: *Parser) anyerror!*const TypeExpr {
        const startSpan = self.currentToken().span;
        self.advance(); // consume the left paren

        if (self.currentToken().kind == .RParen) {
            const endSpan = self.currentToken().span;
            self.advance(); // consume the right paren
            return self.heapAlloc(TypeExpr, .{
                .kind = .Unit,
                .span = Span.join(startSpan, endSpan),
            });
        }

        const expr = try self.parseTypeExpression(.Lowest);
        if (self.currentToken().kind != .RParen) {
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
        const rightPrecAdjust = if (op == .Exponent) @intFromEnum(prec) - 1 else @intFromEnum(prec);
        const rhs = try self.parseExpression(@as(Precedence, @enumFromInt(rightPrecAdjust)));

        const exprSpan = Span.join(lhs.span, rhs.span);
        return self.heapAlloc(Expr, .{
            .kind = .{ .Binary = .{
                .left = lhs,
                .operator = op,
                .right = rhs,
            } },
            .span = exprSpan,
        });
    }

    fn parseBlockExpression(self: *Parser) !*Expr {
        // empty blocks evaluate to unit
        const startSpan = self.currentToken().span;
        self.advance(); // consume the left brace
        _ = self.consumeSeparators(); // allow separators immediately after `{`

        var exprs: std.ArrayList(*Expr) = .empty;

        while (self.currentToken().kind != .RBrace and self.currentToken().kind != .Eof) {
            // Parse the expression
            const expr = try self.parseDeclOrExpr();
            try exprs.append(self.ctx.allocator, expr);

            if (self.currentToken().kind == .RBrace) {
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

        const endSpan = self.currentToken().span;
        _ = try self.expect(.RBrace);

        const owned_exprs = try exprs.toOwnedSlice(self.ctx.allocator);

        var stmts: []const *Expr = owned_exprs;
        var tail: ?*Expr = null;

        if (owned_exprs.len > 0) {
            stmts = owned_exprs[0 .. owned_exprs.len - 1];
            tail = owned_exprs[owned_exprs.len - 1];
        }

        return self.heapAlloc(Expr, .{
            .kind = .{ .Block = .{ .stmts = stmts, .tail = tail } },
            .span = Span.join(startSpan, endSpan),
        });
    }

    fn parseGroupExpression(self: *Parser) !*Expr {
        const startSpan = self.currentToken().span;
        self.advance(); // consume the left paren
        self.skipNewlines(); // allow newlines immediately after `(`

        if (self.currentToken().kind == .RParen) {
            const endSpan = self.currentToken().span;
            self.advance(); // consume `)`

            return self.heapAlloc(Expr, .{
                .kind = .UnitLiteral,
                .span = Span.join(startSpan, endSpan),
            });
        }

        const expr = try self.parseExpression(.Lowest);

        self.skipNewlines(); // allow newlines before `)`
        if (self.currentToken().kind != .RParen) {
            return error.UnclosedLParen;
        }
        self.advance(); // consume right paren
        return expr;
    }

    fn parseBoolLiteral(self: *Parser) !*Expr {
        const boolTok = self.currentToken();
        const val = switch (boolTok.kind) {
            .KwTrue => true,
            .KwFalse => false,
            else => unreachable,
        };

        self.advance();

        return self.heapAlloc(Expr, .{
            .kind = .{ .BoolLiteral = val },
            .span = boolTok.span,
        });
    }

    fn parseIntLiteral(self: *Parser) !*Expr {
        const intToken = self.currentToken();
        const value = switch (intToken.kind) {
            .IntLiteral => |int| int,
            else => return error.ExpectedInt,
        };

        self.advance();

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .IntLiteral = value },
            .span = intToken.span,
        });
    }

    fn parseVariableDecl(self: *Parser) !*Expr {
        const startSpan = self.currentToken().span;
        self.advance(); // consume `let`

        const name = try self.expectIdent(); // consume the ident

        var ty: ?*const TypeExpr = null;
        if (self.currentToken().kind == .In) {
            self.advance(); // consume the `in`
            // ty = try self.expectIdent();
            ty = try self.parseTypeExpression(.Lowest);
        }
        _ = try self.expect(.Equal); // consume `=`

        const value = try self.parseExpression(.Lowest);
        const endSpan = value.span;

        return self.heapAlloc(Expr, .{
            .kind = .{ .VariableDecl = .{
                .name = name,
                .value = value,
                .type = ty,
            } },
            .span = Span.join(startSpan, endSpan),
        });
    }

    fn parseIdentifier(self: *Parser) !*Expr {
        const start_span = self.currentToken().span;
        const name = try self.expectIdent(); // consumes the ident

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .Identifier = name },
            .span = Span.join(start_span, start_span),
        });
    }

    fn parseIdentifierOrFunctionCall(self: *Parser) !*Expr {
        const start_span = self.currentToken().span;
        const name = try self.expectIdent(); // consumes the ident

        if (self.currentToken().kind == .LParen) {
            return try self.parseFunctionCall(name, start_span);
        }

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .Identifier = name },
            .span = Span.join(start_span, start_span),
        });
    }

    fn parseFunctionCall(self: *Parser, callee: []const u8, start_span: Span) !*Expr {
        self.advance(); // consume the left paren
        self.skipNewlines(); // allow newlines immediately after `(`

        var args: std.ArrayList(*const Expr) = .empty;

        while (self.currentToken().kind != .RParen and self.currentToken().kind != .Eof) {
            const arg = try self.parseExpression(.Lowest);
            try args.append(self.ctx.allocator, arg);

            self.skipNewlines(); // allow newlines between arguments

            if (self.currentToken().kind == .Comma) {
                self.advance(); // consume comma
                self.skipNewlines(); // allow newlines after comma
            } else {
                break;
            }
        }

        const end_span = self.currentToken().span;
        _ = try self.expect(.RParen);

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .FunctionCall = .{
                .callee = callee,
                .args = try args.toOwnedSlice(self.ctx.allocator),
            } },
            .span = Span.join(start_span, end_span),
        });
    }

    fn parseUnaryExpression(self: *Parser) !*Expr {
        const opToken = self.currentToken();
        const op = getUnaryOperator(opToken.kind) orelse return {
            std.debug.print("Error: Invalid token for unary operator {any}\n", .{opToken});
            return error.InvalidUnaryOperator;
        };

        self.advance();

        const rhs = try self.parseExpression(.Prefix);
        return self.heapAlloc(Expr, Expr{
            .kind = .{ .Unary = .{ .operator = op, .right = rhs } },
            .span = Span.join(opToken.span, rhs.span),
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
            .Identifier => |ident| {
                self.advance();
                return ident;
            },
            else => return error.ExpectedIdentifier,
        }
    }

    fn getUnaryOperator(tokenType: TokenType) ?UnaryOperator {
        return switch (tokenType) {
            .Plus => .Plus,
            .Minus => .Minus,
            .Bang => .Not,
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

    fn getBinaryOperator(tokenType: TokenType) ?BinaryOperator {
        return switch (tokenType) {
            .Plus => .Plus,
            .Minus => .Minus,
            .Star => .Multiply,
            .Slash => .Divide,
            .Caret => .Exponent,
            .DoubleEqual => .Equal,
            .NotEqual => .NotEqual,
            .LessThan => .LessThan,
            .GreaterThan => .GreaterThan,
            .LessThanOrEqual => .LessThanOrEqual,
            .GreaterThanOrEqual => .GreaterThanOrEqual,
            .KwAnd => .LogicalAnd,
            .KwOr => .LogicalOr,
            else => null,
        };
    }

    fn getTokenPrec(_: *const Parser, tokenType: TokenType) Precedence {
        return switch (tokenType) {
            .KwAnd, .KwOr => .Logical,

            .DoubleEqual, .NotEqual => .Equality,

            .LessThan, .GreaterThan, .LessThanOrEqual, .GreaterThanOrEqual => .Comparison,

            .Plus, .Minus => .Sum,

            .Star, .Slash, .Cross => .Product,

            .Caret => .Exponent,

            .LParen => .Group,

            else => .Lowest,
        };
    }

    fn currentPrec(self: *Parser) u8 {
        return @intFromEnum(self.getTokenPrec(self.currentToken().kind));
    }
};
