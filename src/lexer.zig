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
    currentPos: usize = 0, // offset
    line: usize = 1,
    col: usize = 1,
    utf8Iter: std.unicode.Utf8Iterator,

    pub fn init(ctx: *context.CompilerContext) !Lexer {
        return Lexer{
            .ctx = ctx,
            .utf8Iter = (try std.unicode.Utf8View.init(ctx.source)).iterator(),
        };
    }

    fn isAtEnd(self: *const Lexer) bool {
        return self.currentPos >= self.ctx.source.len;
    }

    fn currentLocation(self: *const Lexer) span.Location {
        return Location{
            .line = self.line,
            .col = self.col,
            .offset = self.currentPos,
        };
    }

    fn advance(self: *Lexer) !u21 {
        const c = self.utf8Iter.nextCodepoint() orelse 0;

        const byteLen: usize = @intCast(try std.unicode.utf8CodepointSequenceLength(c));
        self.currentPos += byteLen;

        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c; //_ orelse 0;
    }

    fn peek(self: *const Lexer) u21 {
        var it = self.utf8Iter;
        return it.nextCodepoint() orelse 0;
    }

    fn match(self: *Lexer, expected: u21) !bool {
        if (self.isAtEnd() or self.ctx.source[self.currentPos] != expected) return false;

        _ = try self.advance();
        return true;
    }

    fn makeNumberToken(self: *Lexer, startLoc: Location) !Token {
        while (utils.isDigit(self.peek())) {
            _ = try self.advance();
        }
        const endLocation = self.currentLocation();

        const tokSpan = Span{
            .start = startLoc,
            .end = endLocation,
        };
        const i = try std.fmt.parseInt(i64, self.ctx.source[tokSpan.start.offset..tokSpan.end.offset], 10);
        return Token{ .kind = .{ .IntLiteral = i }, .span = tokSpan };
    }

    fn makeIdentifierToken(self: *Lexer, startLoc: Location) !Token {
        while (utils.isAlphaNumeric(self.peek())) {
            _ = try self.advance();
        }
        const endLocation = self.currentLocation();

        const tokSpan = Span{
            .start = startLoc,
            .end = endLocation,
        };
        const identStr = self.ctx.source[tokSpan.start.offset..tokSpan.end.offset];

        const tokType = Keywords.get(identStr);

        if (tokType) |typ| {
            // try self.addToken(typ, tokSpan);
            return .{ .kind = typ, .span = tokSpan };
        }

        return Token{ .kind = .{ .Identifier = identStr }, .span = tokSpan };
    }

    fn makeToken(self: *Lexer) !?Token {
        const prevLocation = self.currentLocation();
        const c = try self.advance();

        const singleCharTokSpan = Span{ .start = prevLocation, .end = self.currentLocation() };
        switch (c) {
            '+' => return Token{ .kind = .Plus, .span = singleCharTokSpan },
            '*' => return Token{ .kind = .Star, .span = singleCharTokSpan },
            '/' => return Token{ .kind = .Slash, .span = singleCharTokSpan },
            '^' => return Token{ .kind = .Caret, .span = singleCharTokSpan },
            '(' => return Token{ .kind = .LParen, .span = singleCharTokSpan },
            ')' => return Token{ .kind = .RParen, .span = singleCharTokSpan },
            '[' => return Token{ .kind = .LSquare, .span = singleCharTokSpan },
            ']' => return Token{ .kind = .RSquare, .span = singleCharTokSpan },
            '{' => return Token{ .kind = .LBrace, .span = singleCharTokSpan },
            '}' => return Token{ .kind = .RBrace, .span = singleCharTokSpan },
            ';' => return Token{ .kind = .Semicolon, .span = singleCharTokSpan },
            ':' => return Token{ .kind = .Colon, .span = singleCharTokSpan },
            ',' => return Token{ .kind = .Comma, .span = singleCharTokSpan },
            '∈' => return Token{ .kind = .In, .span = singleCharTokSpan },
            '×' => return Token{ .kind = .Cross, .span = singleCharTokSpan },

            '-' => {
                if (try self.match('>')) {
                    return Token{ .kind = .RightArrow, .span = Span{ .start = prevLocation, .end = self.currentLocation() } };
                } else {
                    return Token{ .kind = .Minus, .span = Span{ .start = prevLocation, .end = self.currentLocation() } };
                }
            },

            '0'...'9' => {
                return try self.makeNumberToken(prevLocation);
            },

            'a'...'z', 'A'...'Z', '_' => {
                return try self.makeIdentifierToken(prevLocation);
            },

            '<' => {
                if (try self.match('=')) {
                    return Token{ .kind = .LessThanOrEqual, .span = Span{ .start = prevLocation, .end = self.currentLocation() } };
                } else {
                    return Token{ .kind = .LessThan, .span = Span{ .start = prevLocation, .end = self.currentLocation() } };
                }
            },
            '>' => {
                if (try self.match('=')) {
                    return Token{ .kind = .GreaterThanOrEqual, .span = Span{ .start = prevLocation, .end = self.currentLocation() } };
                } else {
                    return Token{ .kind = .GreaterThan, .span = Span{ .start = prevLocation, .end = self.currentLocation() } };
                }
            },
            '=' => {
                if (try self.match('=')) {
                    return Token{ .kind = .DoubleEqual, .span = Span{ .start = prevLocation, .end = self.currentLocation() } };
                } else if (try self.match('>')) {
                    return Token{ .kind = .DoubleRightArrow, .span = Span{ .start = prevLocation, .end = self.currentLocation() } };
                } else {
                    return Token{ .kind = .Equal, .span = Span{ .start = prevLocation, .end = self.currentLocation() } };
                }
            },
            '!' => {
                if (try self.match('=')) {
                    return Token{ .kind = .NotEqual, .span = Span{ .start = prevLocation, .end = self.currentLocation() } };
                } else {
                    return Token{ .kind = .Bang, .span = Span{ .start = prevLocation, .end = self.currentLocation() } };
                }
            },

            else => {
                if (utils.isSpecial(c)) {
                    return try self.makeIdentifierToken(prevLocation);
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
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                _ = try self.advance();
                continue;
            }

            // const startLoc = self.currentLocation();
            const tok = try self.makeToken();
            if (tok) |t| try toks.append(self.ctx.allocator, t);
        }

        try toks.append(
            self.ctx.allocator,
            .{ .kind = .Eof, .span = Span{ .start = self.currentLocation(), .end = self.currentLocation() } },
        );
        return toks.toOwnedSlice(self.ctx.allocator);
    }
};
