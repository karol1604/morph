const std = @import("std");
const span = @import("span.zig");

pub const TokenType = union(enum) {
    plus,
    minus,
    star,
    slash,
    caret,
    bang,

    kw_true,
    kw_false,
    kw_let,
    kw_and,
    kw_or,
    kw_if,
    kw_then,
    kw_else,

    right_arrow,
    double_right_arrow,
    in, // ∈
    cross, // ×

    newline,
    semicolon,
    comma,
    colon,

    lparen,
    rparen,
    lsquare,
    rsquare,
    lbrace,
    rbrace,

    equal,
    not_equal,
    less_than,
    greater_than,
    less_than_or_equal,
    greater_than_or_equal,
    double_equal,

    identifier: []const u8,
    int_literal: i64,

    eof,

    pub fn format(self: TokenType, writer: *std.Io.Writer) !void {
        switch (self) {
            .plus => try writer.print("+", .{}),
            .minus => try writer.print("-", .{}),
            .star => try writer.print("*", .{}),
            .slash => try writer.print("/", .{}),
            .caret => try writer.print("^", .{}),
            .bang => try writer.print("!", .{}),

            .kw_true => try writer.print("true", .{}),
            .kw_false => try writer.print("false", .{}),
            .kw_let => try writer.print("let", .{}),
            .kw_and => try writer.print("and", .{}),
            .kw_or => try writer.print("or", .{}),
            .kw_if => try writer.print("if", .{}),
            .kw_then => try writer.print("then", .{}),
            .kw_else => try writer.print("else", .{}),

            .right_arrow => try writer.print("->", .{}),
            .double_right_arrow => try writer.print("=>", .{}),
            .in => try writer.print("∈", .{}),
            .cross => try writer.print("×", .{}),

            .newline => try writer.print("\\n", .{}),
            .semicolon => try writer.print(";", .{}),
            .comma => try writer.print(",", .{}),
            .colon => try writer.print(":", .{}),

            .lparen => try writer.print("(", .{}),
            .rparen => try writer.print(")", .{}),
            .lsquare => try writer.print("[", .{}),
            .rsquare => try writer.print("]", .{}),
            .lbrace => try writer.print("{{", .{}),
            .rbrace => try writer.print("}}", .{}),

            .equal => try writer.print("=", .{}),
            .not_equal => try writer.print("!=", .{}),
            .less_than => try writer.print("<", .{}),
            .greater_than => try writer.print(">", .{}),
            .less_than_or_equal => try writer.print("<=", .{}),
            .greater_than_or_equal => try writer.print(">=", .{}),
            .double_equal => try writer.print("==", .{}),

            .identifier => try writer.print("Ident", .{}),
            .int_literal => try writer.print("IntLiteral", .{}),
            .eof => try writer.print("EOF", .{}),
        }
    }
};

pub const Token = struct {
    kind: TokenType,
    span: span.Span,

    pub fn format(self: Token, writer: *std.Io.Writer) !void {
        switch (self.kind) {
            .identifier => |val| try writer.print("TOK_IDENT({s})", .{val}),
            .int_literal => |val| try writer.print("TOK_INT_LIT({d})", .{val}),

            .plus => try writer.print("TOK_PLUS", .{}),
            .minus => try writer.print("TOK_MINUS", .{}),
            .star => try writer.print("TOK_STAR", .{}),
            .slash => try writer.print("TOK_SLASH", .{}),
            .caret => try writer.print("TOK_CARET", .{}),
            .bang => try writer.print("TOK_BANG", .{}),

            .right_arrow => try writer.print("TOK_RIGHTARROW", .{}),
            .double_right_arrow => try writer.print("TOK_DOUBLERIGHTARROW", .{}),
            .in => try writer.print("TOK_IN", .{}),
            .cross => try writer.print("TOK_TIMES", .{}),

            .kw_true => try writer.print("KW_TRUE", .{}),
            .kw_false => try writer.print("KW_FALSE", .{}),
            .kw_let => try writer.print("KW_LET", .{}),
            .kw_and => try writer.print("KW_AND", .{}),
            .kw_or => try writer.print("KW_OR", .{}),
            .kw_if => try writer.print("KW_IF", .{}),
            .kw_then => try writer.print("KW_THEN", .{}),
            .kw_else => try writer.print("KW_ELSE", .{}),

            .newline => try writer.print("TOK_NEWLINE", .{}),
            .semicolon => try writer.print("TOK_SEMICOLON", .{}),
            .comma => try writer.print("TOK_COMMA", .{}),
            .colon => try writer.print("TOK_COLON", .{}),

            .lparen => try writer.print("TOK_LPAREN", .{}),
            .rparen => try writer.print("TOK_RPAREN", .{}),
            .lsquare => try writer.print("TOK_LSQUARE", .{}),
            .rsquare => try writer.print("TOK_RSQUARE", .{}),
            .lbrace => try writer.print("TOK_LBRACE", .{}),
            .rbrace => try writer.print("TOK_RBRACE", .{}),

            .equal => try writer.print("TOK_EQ", .{}),
            .not_equal => try writer.print("TOK_NEQ", .{}),
            .less_than => try writer.print("TOK_LT", .{}),
            .greater_than => try writer.print("TOK_GT", .{}),
            .less_than_or_equal => try writer.print("TOK_LTE", .{}),
            .greater_than_or_equal => try writer.print("TOK_GTE", .{}),
            .double_equal => try writer.print("TOK_EQEQ", .{}),

            .eof => try writer.print("TOK_EOF", .{}),
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
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "let", .kw_let },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "if", .kw_if },
    .{ "then", .kw_then },
    .{ "else", .kw_else },
});
