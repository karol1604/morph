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

        while (self.currentToken().kind != .Eof) {
            // const expr = try self.parseExpression(.Lowest);
            const expr = try self.parseTopLevelExpression();
            try res.append(self.ctx.allocator, expr);

            if (self.currentToken().kind == .Semicolon) {
                self.advance(); // Eat the ';'
            } else if (self.currentToken().kind != .Eof) {
                std.debug.print("Expected semicolon between expressions, found {f}\n", .{self.currentToken().kind});
                return error.ExpectedSemicolon;
            }
        }

        return try res.toOwnedSlice(self.ctx.allocator);
    }

    fn parseTopLevelExpression(self: *Parser) !*Expr {
        if (self.currentToken().kind != .Identifier) {
            return try self.parseExpression(.Lowest);
        }
        switch (self.peekToken().kind) {
            .Colon => return try self.parseFunctionTypeSignature(),
            .LParen => {
                if (self.isFunctionDefinition()) {
                    std.debug.print("Parsing function definition...\n", .{});
                    return try self.parseFunctionDefinition();
                    // return error.FunctionDefNotSupported;
                }
                return try self.parseExpression(.Lowest); // function call
            },
            else => return try self.parseExpression(.Lowest),
        }
    }

    fn parseFunctionDefinition(self: *Parser) !*Expr {
        const name = try self.parseIdentifier(); // consumes the name
        _ = try self.expect(.LParen);

        var params: std.ArrayList([]const u8) = .empty;

        while (self.currentToken().kind != .RParen) {
            const param = try self.parseIdentifier();
            if (std.meta.activeTag(param.kind) != .Identifier) {
                return error.ExpectedIdentifier;
            }
            try params.append(self.ctx.allocator, param.kind.Identifier);

            if (self.currentToken().kind == .Comma) {
                self.advance(); // consume comma
            } else {
                break;
            }
        }

        _ = try self.expect(.RParen);
        _ = try self.expect(.DoubleRightArrow);

        const body = try self.parseExpression(.Lowest);
        if (std.meta.activeTag(body.kind) != .Block) {
            // require semicolon if body is not a block
            _ = try self.expect(.Semicolon);
        }

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .FunctionDef = .{
                .name = name.kind.Identifier,
                .params = try params.toOwnedSlice(self.ctx.allocator),
                .body = body,
            } },
            .span = Span.join(name.span, body.span),
        });
    }

    fn isFunctionDefinition(self: *const Parser) bool {
        var offset: usize = 1;

        if (self.current + offset >= self.tokens.len) return false;
        if (self.tokens[self.current + offset].kind != .LParen) return false;

        offset += 1;
        var openParens: usize = 1;
        while (self.current + offset < self.tokens.len and openParens > 0) : (offset += 1) {
            const tok = self.tokens[self.current + offset];
            if (tok.kind == .LParen) {
                openParens += 1;
            } else if (tok.kind == .RParen) {
                openParens -= 1;
            }
        }

        if (self.current + offset < self.tokens.len) {
            return self.tokens[self.current + offset].kind == .DoubleRightArrow;
        }

        return false;
    }

    // FIXME: remove the `pub`
    pub fn parseExpression(self: *Parser, prec: Precedence) anyerror!*Expr {
        var expr = switch (self.currentToken().kind) {
            .IntLiteral => try self.parseIntLiteral(),
            .Identifier => try self.parseIdentifierOrFunctionCall(),
            .KwTrue, .KwFalse => try self.parseBoolLiteral(),
            .KwLet => try self.parseVariableDecl(),
            .Plus, .Minus, .Bang => try self.parseUnaryExpression(),
            .LParen => try self.parseGroupExpression(),
            .LBrace => try self.parseBlockExpression(),
            else => {
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

    fn parseFunctionTypeSignature(self: *Parser) !*Expr {
        const name = try self.parseIdentifier(); // consumes the name
        _ = try self.expect(.Colon);

        const domain = try self.parseTypeExpression(.Lowest);

        _ = try self.expect(.RightArrow);

        const codomain = try self.parseTypeExpression(.Lowest);

        // const semicl = try self.expect(.Semicolon);

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .FunctionTypeSignature = .{
                .name = name.kind.Identifier,
                .domain = domain,
                .codomain = codomain,
            } },
            .span = Span.join(name.span, codomain.span),
        });
    }

    fn parseTypeExpression(self: *Parser, prec: Precedence) !*Expr {
        var left = try self.parseTypePrefix();

        while (self.currentToken().kind != .Eof and self.currentPrec() > @intFromEnum(prec)) {
            const tok = self.currentToken();
            std.debug.print("TOK: {f}\n", .{tok});

            // Only allow Type-valid operators here
            var op: BinaryOperator = undefined;
            switch (tok.kind) {
                .Cross => {
                    op = .TypeProduct;
                }, // `×` symbol
                .Caret => {
                    op = .Exponent;
                }, // `^` symbol
                else => return left,
            }

            self.advance();

            // Recurse for the right side
            const right = try self.parseTypeExpression(self.getTokenPrec(tok.kind));

            left = try self.heapAlloc(Expr, .{
                .kind = .{ .Binary = .{
                    .left = left,
                    .operator = op,
                    .right = right,
                } },
                .span = Span.join(left.span, right.span),
            });
        }

        return left;
    }

    fn parseTypePrefix(self: *Parser) !*Expr {
        switch (self.currentToken().kind) {
            .Identifier => return try self.parseIdentifier(),
            .IntLiteral => return try self.parseIntLiteral(),
            .LParen => return try self.parseTypeGroupExpression(),
            else => {
                std.debug.print("CURRENT: {f}\n", .{self.currentToken()});
                return error.ExpectedType;
            },
        }
    }

    fn parseTypeGroupExpression(self: *Parser) anyerror!*Expr {
        self.advance(); // consume the left paren
        const expr = try self.parseTypeExpression(.Lowest);
        if (self.currentToken().kind != .RParen) {
            return error.UnclosedLParen;
        }
        self.advance(); // consume right paren
        return expr;
    }

    fn parseBinaryExpression(self: *Parser, lhs: *const Expr, op: BinaryOperator, prec: Precedence) !*Expr {
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
        // exprs followed by `;` have their values discarded
        // the last expression without ';' becomes the block's value (tail)
        // empty blocks evaluate to unit
        const startSpan = self.currentToken().span;
        self.advance(); // consume the left brace

        var statements: std.ArrayList(*Expr) = .empty;
        var tail: ?*Expr = null;

        while (self.currentToken().kind != .RBrace and self.currentToken().kind != .Eof) {
            // Parse the expression
            const expr = try self.parseExpression(.Lowest);

            if (self.currentToken().kind == .Semicolon) {
                // Case 1: expr; -> value is discarded
                self.advance(); // eat semicolon
                try statements.append(self.ctx.allocator, expr);
            } else {
                // Case 2: expr -> potentially the tail
                tail = expr;
                // If we don't see a '}', it's a syntax error (missing semicolon)
                if (self.currentToken().kind != .RBrace) {
                    return error.ExpectedSemicolon;
                }
            }
        }

        const endSpan = self.currentToken().span;
        _ = try self.expect(.RBrace);

        return self.heapAlloc(Expr, .{
            .kind = .{ .Block = .{ .stmts = try statements.toOwnedSlice(self.ctx.allocator), .tail = tail } },
            .span = Span.join(startSpan, endSpan),
        });
    }

    fn parseGroupExpression(self: *Parser) !*Expr {
        self.advance(); // consume the left paren
        const expr = try self.parseExpression(.Lowest);
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

        var ty: ?[]const u8 = null;
        if (self.currentToken().kind == .In) {
            self.advance(); // consume the `in`
            ty = try self.expectIdent();
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

        var args: std.ArrayList(*const Expr) = .empty;

        while (self.currentToken().kind != .RParen and self.currentToken().kind != .Eof) {
            const arg = try self.parseExpression(.Lowest);
            try args.append(self.ctx.allocator, arg);

            if (self.currentToken().kind == .Comma) {
                self.advance(); // consume comma
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

    fn currentToken(self: *Parser) Token {
        return self.tokens[self.current];
    }

    fn advance(self: *Parser) void {
        if (self.current < self.tokens.len - 1) {
            self.current += 1;
        }
    }

    fn peekToken(self: *Parser) Token {
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

    fn getTokenPrec(_: *Parser, tokenType: TokenType) Precedence {
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
