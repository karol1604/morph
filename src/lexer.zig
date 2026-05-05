const std = @import("std");
const token = @import("token.zig");
const context = @import("context.zig");
const utils = @import("utils.zig");
const span = @import("span.zig");

const Token = token.Token;
const TokenType = token.TokenType;
const Span = span.Span;
const Location = span.Location;
const Keywords = token.Keywords;

pub const Lexer = struct {
    ctx: *context.CompilerContext,
    current_pos: usize = 0, // offset
    line: usize = 1,
    col: usize = 1,
    utf8_iter: std.unicode.Utf8Iterator,

    pub fn init(ctx: *context.CompilerContext) !Lexer {
        return Lexer{
            .ctx = ctx,
            .utf8_iter = (try std.unicode.Utf8View.init(ctx.source)).iterator(),
        };
    }

    fn isAtEnd(self: *const Lexer) bool {
        return self.current_pos >= self.ctx.source.len;
    }

    fn currentLocation(self: *const Lexer) span.Location {
        return Location{
            .line = self.line,
            .col = self.col,
            .offset = self.current_pos,
        };
    }

    fn advance(self: *Lexer) !u21 {
        const c = self.utf8_iter.nextCodepoint() orelse 0;

        const byte_len: usize = @intCast(try std.unicode.utf8CodepointSequenceLength(c));
        self.current_pos += byte_len;

        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c; //orelse 0;
    }

    fn peek(self: *const Lexer) u21 {
        var it = self.utf8_iter;
        return it.nextCodepoint() orelse 0;
    }

    fn match(self: *Lexer, expected: u21) !bool {
        if (self.isAtEnd() or self.ctx.source[self.current_pos] != expected) return false;

        _ = try self.advance();
        return true;
    }

    fn makeNumberToken(self: *Lexer, start_loc: Location) !Token {
        while (utils.isDigit(self.peek())) {
            _ = try self.advance();
        }
        const end_location = self.currentLocation();

        const tok_span = Span{
            .start = start_loc,
            .end = end_location,
        };
        const i = try std.fmt.parseInt(i64, self.ctx.source[tok_span.start.offset..tok_span.end.offset], 10);
        return Token{ .kind = .{ .int_literal = i }, .span = tok_span };
    }

    fn makeIdentifierToken(self: *Lexer, start_loc: Location) !Token {
        while (utils.isAlphaNumeric(self.peek())) {
            _ = try self.advance();
        }
        const end_location = self.currentLocation();

        const tok_span = Span{
            .start = start_loc,
            .end = end_location,
        };
        const ident_str = self.ctx.source[tok_span.start.offset..tok_span.end.offset];

        const tok_type = Keywords.get(ident_str);

        if (tok_type) |typ| {
            // try self.addToken(typ, tokSpan);
            return .{ .kind = typ, .span = tok_span };
        }

        return Token{ .kind = .{ .identifier = ident_str }, .span = tok_span };
    }

    fn makeToken(self: *Lexer) !?Token {
        const prev_loc = self.currentLocation();
        const c = try self.advance();

        const single_char_tok_span = Span{ .start = prev_loc, .end = self.currentLocation() };
        switch (c) {
            '+' => return Token{ .kind = .plus, .span = single_char_tok_span },
            '*' => return Token{ .kind = .star, .span = single_char_tok_span },
            '/' => return Token{ .kind = .slash, .span = single_char_tok_span },
            '^' => return Token{ .kind = .caret, .span = single_char_tok_span },
            '(' => return Token{ .kind = .lparen, .span = single_char_tok_span },
            ')' => return Token{ .kind = .rparen, .span = single_char_tok_span },
            '[' => return Token{ .kind = .lsquare, .span = single_char_tok_span },
            ']' => return Token{ .kind = .rsquare, .span = single_char_tok_span },
            '{' => return Token{ .kind = .lbrace, .span = single_char_tok_span },
            '}' => return Token{ .kind = .rbrace, .span = single_char_tok_span },
            ';' => return Token{ .kind = .semicolon, .span = single_char_tok_span },
            ':' => return Token{ .kind = .colon, .span = single_char_tok_span },
            ',' => return Token{ .kind = .comma, .span = single_char_tok_span },
            '∈' => return Token{ .kind = .in, .span = single_char_tok_span },
            '×' => return Token{ .kind = .cross, .span = single_char_tok_span },

            '-' => {
                if (try self.match('>')) {
                    return Token{
                        .kind = .right_arrow,
                        .span = Span{ .start = prev_loc, .end = self.currentLocation() },
                    };
                } else {
                    return Token{
                        .kind = .minus,
                        .span = Span{ .start = prev_loc, .end = self.currentLocation() },
                    };
                }
            },
            '0'...'9' => return try self.makeNumberToken(prev_loc),
            'a'...'z', 'A'...'Z', '_' => return try self.makeIdentifierToken(prev_loc),
            '<' => {
                if (try self.match('=')) {
                    return Token{
                        .kind = .less_than_or_equal,
                        .span = Span{ .start = prev_loc, .end = self.currentLocation() },
                    };
                } else {
                    return Token{
                        .kind = .less_than,
                        .span = Span{ .start = prev_loc, .end = self.currentLocation() },
                    };
                }
            },
            '>' => {
                if (try self.match('=')) {
                    return Token{
                        .kind = .greater_than_or_equal,
                        .span = Span{ .start = prev_loc, .end = self.currentLocation() },
                    };
                } else {
                    return Token{
                        .kind = .greater_than,
                        .span = Span{ .start = prev_loc, .end = self.currentLocation() },
                    };
                }
            },
            '=' => {
                if (try self.match('=')) {
                    return Token{
                        .kind = .double_equal,
                        .span = Span{ .start = prev_loc, .end = self.currentLocation() },
                    };
                } else if (try self.match('>')) {
                    return Token{
                        .kind = .double_right_arrow,
                        .span = Span{ .start = prev_loc, .end = self.currentLocation() },
                    };
                } else {
                    return Token{
                        .kind = .equal,
                        .span = Span{ .start = prev_loc, .end = self.currentLocation() },
                    };
                }
            },
            '!' => {
                if (try self.match('=')) {
                    return Token{
                        .kind = .not_equal,
                        .span = Span{ .start = prev_loc, .end = self.currentLocation() },
                    };
                } else {
                    return Token{
                        .kind = .bang,
                        .span = Span{ .start = prev_loc, .end = self.currentLocation() },
                    };
                }
            },

            else => {
                if (utils.isSpecial(c)) {
                    return try self.makeIdentifierToken(prev_loc);
                }
                // Unknown character
                return error.UnexpectedCharacter;
            },
        }
    }

    pub fn tokenize(self: *Lexer) ![]Token {
        var toks: std.ArrayList(Token) = .empty;

        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r') {
                _ = try self.advance();
                continue;
            }

            if (c == '\n') {
                const start_loc = self.currentLocation();
                _ = try self.advance();
                try toks.append(
                    self.ctx.allocator,
                    .{
                        .kind = .newline,
                        .span = Span{ .start = start_loc, .end = self.currentLocation() },
                    },
                );
                continue;
            }

            // const startLoc = self.currentLocation();
            const tok = try self.makeToken();
            if (tok) |t| try toks.append(self.ctx.allocator, t);
        }

        try toks.append(
            self.ctx.allocator,
            .{
                .kind = .eof,
                .span = Span{ .start = self.currentLocation(), .end = self.currentLocation() },
            },
        );
        return toks.toOwnedSlice(self.ctx.allocator);
    }
};
