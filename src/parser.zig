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

    pub fn parse(self: *Parser) !void {
        while (self.currentToken().kind != .Eof) {
            std.debug.print("Parsing token: {f}\n", .{self.currentToken()});
            const expr = try self.parseExpression(.Lowest);
            utils.prettyPrintExpression(expr.*);
        }
    }

    fn parseExpression(self: *Parser, prec: Precedence) anyerror!*Expr {
        var expr = switch (self.currentToken().kind) {
            .IntLiteral => try self.parseIntLiteral(),
            .Identifier => try self.parseVariableIdentifier(),
            .Plus, .Minus, .Bang => try self.parseUnaryExpression(),
            .LParen => try self.parseGroupExpression(),
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

    fn parseGroupExpression(self: *Parser) !*Expr {
        self.advance(); // consume the left paren
        const expr = self.parseExpression(.Lowest);
        if (self.currentToken().kind != .RParen) {
            return error.UnclosedLParen;
        }
        self.advance(); // consume right paren
        return expr;
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
