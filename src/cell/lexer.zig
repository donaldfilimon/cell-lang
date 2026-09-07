const std = @import("std");

pub const TokenKind = enum {
    // punctuation
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    comma,
    colon,
    semicolon,
    dot,
    arrow, // ->
    fat_arrow, // =>
    question, // ?
    // operators
    plus,
    minus,
    star,
    slash,
    eq,
    eq_eq,
    ne,
    lt,
    le,
    gt,
    ge,
    amp, // &
    amp_amp, // &&
    pipe_pipe, // ||
    bang,
    // keywords
    kw_fn,
    kw_let,
    kw_var,
    kw_mut,
    kw_struct,
    kw_enum,
    kw_if,
    kw_else,
    kw_match,
    kw_return,
    kw_use,
    kw_pub,
    kw_true,
    kw_false,
    kw_owned,
    kw_shared,
    kw_exclusive,
    kw_arc,
    kw_copy,
    // literals / idents
    ident,
    int,
    float,
    string,
    // special
    eof,
    invalid,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    line: u32,
    column: u32,
};

pub const Lexer = struct {
    source: []const u8,
    path: []const u8,
    index: usize = 0,
    line: u32 = 1,
    column: u32 = 1,

    pub fn init(source: []const u8, path: []const u8) Lexer {
        return .{ .source = source, .path = path };
    }

    pub fn tokenizeAll(self: *Lexer, allocator: std.mem.Allocator) !std.ArrayList(Token) {
        var tokens: std.ArrayList(Token) = .empty;
        errdefer tokens.deinit(allocator);
        while (true) {
            const tok = self.next();
            try tokens.append(allocator, tok);
            if (tok.kind == .eof or tok.kind == .invalid) break;
        }
        return tokens;
    }

    pub fn next(self: *Lexer) Token {
        self.skipTrivia();
        const start = self.index;
        const line = self.line;
        const column = self.column;
        if (self.index >= self.source.len) {
            return .{ .kind = .eof, .lexeme = "", .line = line, .column = column };
        }

        const c = self.source[self.index];
        // multi-char operators
        if (c == '-' and self.peek(1) == '>') {
            self.advance();
            self.advance();
            return self.make(.arrow, start, line, column);
        }
        if (c == '=' and self.peek(1) == '>') {
            self.advance();
            self.advance();
            return self.make(.fat_arrow, start, line, column);
        }
        if (c == '=' and self.peek(1) == '=') {
            self.advance();
            self.advance();
            return self.make(.eq_eq, start, line, column);
        }
        if (c == '!' and self.peek(1) == '=') {
            self.advance();
            self.advance();
            return self.make(.ne, start, line, column);
        }
        if (c == '<' and self.peek(1) == '=') {
            self.advance();
            self.advance();
            return self.make(.le, start, line, column);
        }
        if (c == '>' and self.peek(1) == '=') {
            self.advance();
            self.advance();
            return self.make(.ge, start, line, column);
        }
        if (c == '&' and self.peek(1) == '&') {
            self.advance();
            self.advance();
            return self.make(.amp_amp, start, line, column);
        }
        if (c == '|' and self.peek(1) == '|') {
            self.advance();
            self.advance();
            return self.make(.pipe_pipe, start, line, column);
        }

        // single-char
        const single: ?TokenKind = switch (c) {
            '(' => .l_paren,
            ')' => .r_paren,
            '{' => .l_brace,
            '}' => .r_brace,
            '[' => .l_bracket,
            ']' => .r_bracket,
            ',' => .comma,
            ':' => .colon,
            ';' => .semicolon,
            '.' => .dot,
            '?' => .question,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '=' => .eq,
            '<' => .lt,
            '>' => .gt,
            '&' => .amp,
            '!' => .bang,
            else => null,
        };
        if (single) |kind| {
            self.advance();
            return self.make(kind, start, line, column);
        }

        if (c == '"') return self.lexString(start, line, column);
        if (std.ascii.isDigit(c)) return self.lexNumber(start, line, column);
        if (isIdentStart(c)) return self.lexIdent(start, line, column);

        self.advance();
        return self.make(.invalid, start, line, column);
    }

    fn lexString(self: *Lexer, start: usize, line: u32, column: u32) Token {
        self.advance(); // opening "
        while (self.index < self.source.len and self.source[self.index] != '"') {
            if (self.source[self.index] == '\\' and self.index + 1 < self.source.len) {
                self.advance();
            }
            if (self.source[self.index] == '\n') {
                self.line += 1;
                self.column = 0;
            }
            self.advance();
        }
        if (self.index < self.source.len) self.advance(); // closing "
        return self.make(.string, start, line, column);
    }

    fn lexNumber(self: *Lexer, start: usize, line: u32, column: u32) Token {
        var is_float = false;
        while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) {
            self.advance();
        }
        if (self.index < self.source.len and self.source[self.index] == '.' and
            self.index + 1 < self.source.len and std.ascii.isDigit(self.source[self.index + 1]))
        {
            is_float = true;
            self.advance();
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) {
                self.advance();
            }
        }
        return self.make(if (is_float) .float else .int, start, line, column);
    }

    fn lexIdent(self: *Lexer, start: usize, line: u32, column: u32) Token {
        while (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
            self.advance();
        }
        const lexeme = self.source[start..self.index];
        const kind = keyword(lexeme) orelse .ident;
        return .{ .kind = kind, .lexeme = lexeme, .line = line, .column = column };
    }

    fn keyword(lexeme: []const u8) ?TokenKind {
        const map = .{
            .{ "fn", .kw_fn },
            .{ "let", .kw_let },
            .{ "var", .kw_var },
            .{ "mut", .kw_mut },
            .{ "struct", .kw_struct },
            .{ "enum", .kw_enum },
            .{ "if", .kw_if },
            .{ "else", .kw_else },
            .{ "match", .kw_match },
            .{ "return", .kw_return },
            .{ "use", .kw_use },
            .{ "pub", .kw_pub },
            .{ "true", .kw_true },
            .{ "false", .kw_false },
            .{ "owned", .kw_owned },
            .{ "shared", .kw_shared },
            .{ "exclusive", .kw_exclusive },
            .{ "arc", .kw_arc },
            .{ "copy", .kw_copy },
        };
        inline for (map) |pair| {
            if (std.mem.eql(u8, lexeme, pair[0])) return pair[1];
        }
        return null;
    }

    fn skipTrivia(self: *Lexer) void {
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.advance();
                continue;
            }
            if (c == '\n') {
                self.advance();
                self.line += 1;
                self.column = 1;
                continue;
            }
            // line comment //
            if (c == '/' and self.peek(1) == '/') {
                while (self.index < self.source.len and self.source[self.index] != '\n') {
                    self.advance();
                }
                continue;
            }
            // block comment /* */
            if (c == '/' and self.peek(1) == '*') {
                self.advance();
                self.advance();
                while (self.index + 1 < self.source.len and
                    !(self.source[self.index] == '*' and self.source[self.index + 1] == '/'))
                {
                    if (self.source[self.index] == '\n') {
                        self.line += 1;
                        self.column = 0;
                    }
                    self.advance();
                }
                if (self.index + 1 < self.source.len) {
                    self.advance();
                    self.advance();
                }
                continue;
            }
            break;
        }
    }

    fn make(self: *Lexer, kind: TokenKind, start: usize, line: u32, column: u32) Token {
        return .{
            .kind = kind,
            .lexeme = self.source[start..self.index],
            .line = line,
            .column = column,
        };
    }

    fn advance(self: *Lexer) void {
        if (self.index < self.source.len) {
            self.index += 1;
            self.column += 1;
        }
    }

    fn peek(self: *const Lexer, offset: usize) u8 {
        const i = self.index + offset;
        if (i >= self.source.len) return 0;
        return self.source[i];
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

test "lex hello" {
    const src =
        \\pub fn main() {
        \\  let owned x = 42
        \\}
    ;
    var lex = Lexer.init(src, "t.cell");
    var toks = try lex.tokenizeAll(std.testing.allocator);
    defer toks.deinit(std.testing.allocator);
    try std.testing.expect(toks.items.len > 5);
    try std.testing.expect(toks.items[0].kind == .kw_pub);
}
