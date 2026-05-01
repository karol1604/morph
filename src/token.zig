const std = @import("std");
const span = @import("span.zig");

pub const TokenType = union(enum) {
    Plus,
    Minus,
    Star,
    Slash,
    Caret,
    Bang,

    KwTrue,
    KwFalse,
    KwLet,
    KwAnd,
    KwOr,
    KwIf,
    KwThen,
    KwElse,

    RightArrow,
    DoubleRightArrow,
    In, // ∈
    Cross, // ×

    Newline,
    Semicolon,
    Comma,
    Colon,

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

    pub fn format(self: TokenType, writer: *std.Io.Writer) !void {
        switch (self) {
            .Plus => try writer.print("+", .{}),
            .Minus => try writer.print("-", .{}),
            .Star => try writer.print("*", .{}),
            .Slash => try writer.print("/", .{}),
            .Caret => try writer.print("^", .{}),
            .Bang => try writer.print("!", .{}),

            .KwTrue => try writer.print("true", .{}),
            .KwFalse => try writer.print("false", .{}),
            .KwLet => try writer.print("let", .{}),
            .KwAnd => try writer.print("and", .{}),
            .KwOr => try writer.print("or", .{}),
            .KwIf => try writer.print("if", .{}),
            .KwThen => try writer.print("then", .{}),
            .KwElse => try writer.print("else", .{}),

            .RightArrow => try writer.print("->", .{}),
            .DoubleRightArrow => try writer.print("=>", .{}),
            .In => try writer.print("∈", .{}),
            .Cross => try writer.print("×", .{}),

            .Newline => try writer.print("\\n", .{}),
            .Semicolon => try writer.print(";", .{}),
            .Comma => try writer.print(",", .{}),
            .Colon => try writer.print(":", .{}),

            .LParen => try writer.print("(", .{}),
            .RParen => try writer.print(")", .{}),
            .LSquare => try writer.print("[", .{}),
            .RSquare => try writer.print("]", .{}),
            .LBrace => try writer.print("{{", .{}),
            .RBrace => try writer.print("}}", .{}),

            .Equal => try writer.print("=", .{}),
            .NotEqual => try writer.print("!=", .{}),
            .LessThan => try writer.print("<", .{}),
            .GreaterThan => try writer.print(">", .{}),
            .LessThanOrEqual => try writer.print("<=", .{}),
            .GreaterThanOrEqual => try writer.print(">=", .{}),
            .DoubleEqual => try writer.print("==", .{}),

            .Identifier => try writer.print("Ident", .{}),
            .IntLiteral => try writer.print("IntLiteral", .{}),
            .Eof => try writer.print("EOF", .{}),
        }
    }
};

pub const Token = struct {
    kind: TokenType,
    span: span.Span,

    pub fn format(self: Token, writer: *std.Io.Writer) !void {
        switch (self.kind) {
            .Identifier => |val| try writer.print("TOK_IDENT({s})", .{val}),
            .IntLiteral => |val| try writer.print("TOK_INT_LIT({d})", .{val}),

            .Plus => try writer.print("TOK_PLUS", .{}),
            .Minus => try writer.print("TOK_MINUS", .{}),
            .Star => try writer.print("TOK_STAR", .{}),
            .Slash => try writer.print("TOK_SLASH", .{}),
            .Caret => try writer.print("TOK_CARET", .{}),
            .Bang => try writer.print("TOK_BANG", .{}),

            .RightArrow => try writer.print("TOK_RIGHTARROW", .{}),
            .DoubleRightArrow => try writer.print("TOK_DOUBLERIGHTARROW", .{}),
            .In => try writer.print("TOK_IN", .{}),
            .Cross => try writer.print("TOK_TIMES", .{}),

            .KwTrue => try writer.print("KW_TRUE", .{}),
            .KwFalse => try writer.print("KW_FALSE", .{}),
            .KwLet => try writer.print("KW_LET", .{}),
            .KwAnd => try writer.print("KW_AND", .{}),
            .KwOr => try writer.print("KW_OR", .{}),
            .KwIf => try writer.print("KW_IF", .{}),
            .KwThen => try writer.print("KW_THEN", .{}),
            .KwElse => try writer.print("KW_ELSE", .{}),

            .Newline => try writer.print("TOK_NEWLINE", .{}),
            .Semicolon => try writer.print("TOK_SEMICOLON", .{}),
            .Comma => try writer.print("TOK_COMMA", .{}),
            .Colon => try writer.print("TOK_COLON", .{}),

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

pub const Keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "true", .KwTrue },
    .{ "false", .KwFalse },
    .{ "let", .KwLet },
    .{ "and", .KwAnd },
    .{ "or", .KwOr },
    .{ "if", .KwIf },
    .{ "then", .KwThen },
    .{ "else", .KwElse },
});
