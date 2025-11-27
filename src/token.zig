const std = @import("std");
const span = @import("span.zig");

pub const TokenType = union(enum) {
    Plus,
    Minus,
    Star,
    Slash,
    Caret,
    Bang,

    Semicolon,

    LParen,
    RParen,
    LSquare,
    RSquare,
    LBrace,
    RBrace,

    Equal,
    NotEqual,
    LessThan,
    GreaterThan,
    LessThanOrEqual,
    GreaterThanOrEqual,
    DoubleEqual,

    Identifier: []const u8,
    IntLiteral: i64,

    Eof,

    pub fn format(self: TokenType, writer: *std.io.Writer) !void {
        _ = self;
        try writer.print("token_type_here", .{});
    }
};

pub const Token = struct {
    kind: TokenType,
    span: span.Span,

    pub fn format(self: Token, writer: *std.io.Writer) !void {
        switch (self.kind) {
            .Identifier => |val| try writer.print("TOK_IDENT({s})", .{val}),
            .IntLiteral => |val| try writer.print("TOK_INT_LIT({d})", .{val}),

            .Plus => try writer.print("TOK_PLUS", .{}),
            .Minus => try writer.print("TOK_MINUS", .{}),
            .Star => try writer.print("TOK_STAR", .{}),
            .Slash => try writer.print("TOK_SLASH", .{}),
            .Caret => try writer.print("TOK_CARET", .{}),
            .Bang => try writer.print("TOK_BANG", .{}),

            .Semicolon => try writer.print("TOK_SEMICOLON", .{}),

            .LParen => try writer.print("TOK_LPAREN", .{}),
            .RParen => try writer.print("TOK_RPAREN", .{}),
            .LSquare => try writer.print("TOK_LSQUARE", .{}),
            .RSquare => try writer.print("TOK_RSQUARE", .{}),
            .LBrace => try writer.print("TOK_LBRACE", .{}),
            .RBrace => try writer.print("TOK_RBRACE", .{}),

            .Equal => try writer.print("TOK_EQ", .{}),
            .NotEqual => try writer.print("TOK_NEQ", .{}),
            .LessThan => try writer.print("TOK_LT", .{}),
            .GreaterThan => try writer.print("TOK_GT", .{}),
            .LessThanOrEqual => try writer.print("TOK_LTE", .{}),
            .GreaterThanOrEqual => try writer.print("TOK_GTE", .{}),
            .DoubleEqual => try writer.print("TOK_EQEQ", .{}),

            .Eof => try writer.print("TOK_EOF", .{}),
            // else => try writer.print("TOK_OTHER", .{}),
        }

        try writer.print("({d}:{d}) at ({d}, {d})", .{
            self.span.start.offset,
            self.span.end.offset,
            self.span.start.col,
            self.span.end.col,
        });
    }
};
