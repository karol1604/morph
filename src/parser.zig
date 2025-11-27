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

    pub fn heapAlloc(self: *const Parser, comptime T: type, value: T) !*T {
        const ptr = try self.ctx.allocator.create(T);
        ptr.* = value;
        return ptr;
    }

    pub fn parse(self: *Parser) ![]*Expr {
        var res: std.ArrayList(*Expr) = .empty;

        while (self.currentToken().kind != .Eof) {
            const expr = try self.parseExpression(.Lowest);
            try res.append(self.ctx.allocator, expr);

            if (self.currentToken().kind == .Semicolon) {
                self.advance(); // Eat the ';'
            } else if (self.currentToken().kind != .Eof) {
                std.debug.print("Expected semicolon between expressions, found {s}\n", .{@tagName(self.currentToken().kind)});
                return error.ExpectedSemicolon;
            }
        }

        return try res.toOwnedSlice(self.ctx.allocator);
    }

    // FIXME: remove the `pub`
    pub fn parseExpression(self: *Parser, prec: Precedence) anyerror!*Expr {
        var expr = switch (self.currentToken().kind) {
            .IntLiteral => try self.parseIntLiteral(),
            .Identifier => try self.parseVariableIdentifier(),
            .True, .False => try self.parserBoolLiteral(),
            .Plus, .Minus, .Bang => try self.parseUnaryExpression(),
            .LParen => try self.parseGroupExpression(),
            .LBrace => try self.parseBlockExpression(),
            else => return error.UnsupportedToken,
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
        const expr = self.parseExpression(.Lowest);
        if (self.currentToken().kind != .RParen) {
            return error.UnclosedLParen;
        }
        self.advance(); // consume right paren
        return expr;
    }

    fn parserBoolLiteral(self: *Parser) !*Expr {
        const boolTok = self.currentToken();
        const val = switch (boolTok.kind) {
            .True => true,
            .False => false,
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

    fn parseVariableIdentifier(self: *Parser) !*Expr {
        const start_span = self.currentToken().span;
        const ident = try self.expectIdent();

        return self.heapAlloc(Expr, Expr{
            .kind = .{ .Identifier = ident },
            .span = Span.join(start_span, start_span),
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

    fn getUnaryOperator(tokenType: TokenType) ?UnaryOperator {
        return switch (tokenType) {
            .Plus => .Plus,
            .Minus => .Minus,
            .Bang => .Not,
            else => null,
        };
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

    fn currentToken(self: *Parser) Token {
        return self.tokens[self.current];
    }

    fn advance(self: *Parser) void {
        if (self.current < self.tokens.len - 1) {
            self.current += 1;
        }
    }

    fn getBinaryOperator(tokenType: TokenType) ?BinaryOperator {
        return switch (tokenType) {
            .Plus => .Plus,
            .Minus => .Minus,
            .Star => .Multiply,
            .Slash => .Divide,
            .DoubleEqual => .Equal,
            .NotEqual => .NotEqual,
            .LessThan => .LessThan,
            .GreaterThan => .GreaterThan,
            .LessThanOrEqual => .LessThanOrEqual,
            .GreaterThanOrEqual => .GreaterThanOrEqual,
            // .DoubleAmpersand => .LogicalAnd,
            // .DoublePipe => .LogicalOr,
            .Caret => .Exponent,
            else => null,
        };
    }

    fn getTokenPrec(_: *Parser, tokenType: TokenType) Precedence {
        return switch (tokenType) {
            // .DoubleAmpersand => .Logical,
            // .DoublePipe => .Logical,

            .DoubleEqual => .Equality,
            .NotEqual => .Equality,

            .LessThan => .Comparison,
            .GreaterThan => .Comparison,
            .LessThanOrEqual => .Comparison,
            .GreaterThanOrEqual => .Comparison,

            .Plus => .Sum,
            .Minus => .Sum,

            .Star => .Product,
            .Slash => .Product,

            .Caret => .Exponent,

            .LParen => .Group,

            else => .Lowest,
        };
    }

    fn currentPrec(self: *Parser) u8 {
        return @intFromEnum(self.getTokenPrec(self.currentToken().kind));
    }
};
