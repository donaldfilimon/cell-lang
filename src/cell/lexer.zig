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
    // Reserved words (SPEC 2.5). These lex as keywords but have NO parser
    // rule yet, which is the point: a program using one as a name now fails
    // with "expected item" or "expected expression" instead of silently
    // meaning something else. `while` is the case that proves it -- a block is
    // a valid expression, so `while (c) { ... }` used to parse as a call to a
    // function named `while` followed by a discarded block, and a program
    // written believing Cell has loops compiled and did nothing.
    //
    // Of these only while/break/continue are scheduled to gain rules. The rest
    // are reserved so that programs do not come to depend on them as names.
    kw_while,
    kw_for,
    kw_loop,
    kw_break,
    kw_continue,
    kw_in,
    kw_impl,
    kw_trait,
    kw_where,
    kw_type,
    kw_const,
    kw_static,
    kw_self,
    kw_Self,
    kw_as,
    kw_is,
    kw_defer,
    kw_async,
    kw_await,
    kw_yield,
    kw_import,
    kw_export,
    kw_extern,
    kw_unsafe,
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
    /// Byte offset of the first byte of the token in the source buffer.
    start: u32,
    /// Byte offset one past the last byte of the token.
    end: u32,
    /// 1-based line of the first byte.
    line: u32,
    /// 1-based column of the first byte.
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
            const at: u32 = @intCast(self.source.len);
            return .{ .kind = .eof, .lexeme = "", .start = at, .end = at, .line = line, .column = column };
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
        const kind = keyword(self.source[start..self.index]) orelse .ident;
        return self.make(kind, start, line, column);
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
            // SPEC 2.5, reserved. Keep this list and the enum above in the
            // same order as the specification's block, so a reader can diff
            // them by eye.
            .{ "while", .kw_while },
            .{ "for", .kw_for },
            .{ "loop", .kw_loop },
            .{ "break", .kw_break },
            .{ "continue", .kw_continue },
            .{ "in", .kw_in },
            .{ "impl", .kw_impl },
            .{ "trait", .kw_trait },
            .{ "where", .kw_where },
            .{ "type", .kw_type },
            .{ "const", .kw_const },
            .{ "static", .kw_static },
            .{ "self", .kw_self },
            .{ "Self", .kw_Self },
            .{ "as", .kw_as },
            .{ "is", .kw_is },
            .{ "defer", .kw_defer },
            .{ "async", .kw_async },
            .{ "await", .kw_await },
            .{ "yield", .kw_yield },
            .{ "import", .kw_import },
            .{ "export", .kw_export },
            .{ "extern", .kw_extern },
            .{ "unsafe", .kw_unsafe },
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
            .start = @intCast(start),
            .end = @intCast(self.index),
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

test "every token's byte range slices back to its own lexeme" {
    const src =
        \\pub fn add(shared a: Int) -> Int {
        \\  return a + 1
        \\}
    ;
    var lex = Lexer.init(src, "t.cell");
    var toks = try lex.tokenizeAll(std.testing.allocator);
    defer toks.deinit(std.testing.allocator);

    for (toks.items) |t| {
        try std.testing.expect(t.start <= t.end);
        try std.testing.expect(t.end <= src.len);
        try std.testing.expectEqualStrings(t.lexeme, src[t.start..t.end]);
    }
}

test "line and column survive comments, newlines and strings" {
    const src =
        \\// a leading comment
        \\pub fn f() {
        \\  let owned s = "two words"
        \\}
    ;
    var lex = Lexer.init(src, "t.cell");
    var toks = try lex.tokenizeAll(std.testing.allocator);
    defer toks.deinit(std.testing.allocator);

    // `pub` is the first token, on line 2 column 1: the comment is trivia.
    try std.testing.expectEqual(TokenKind.kw_pub, toks.items[0].kind);
    try std.testing.expectEqual(@as(u32, 2), toks.items[0].line);
    try std.testing.expectEqual(@as(u32, 1), toks.items[0].column);

    // The string literal is on line 3; `let owned s = ` puts it at column 17.
    var string_index: usize = 0;
    for (toks.items, 0..) |t, i| {
        if (t.kind == .string) string_index = i;
    }
    const s = toks.items[string_index];
    try std.testing.expectEqual(@as(u32, 3), s.line);
    try std.testing.expectEqual(@as(u32, 17), s.column);
    try std.testing.expectEqualStrings("\"two words\"", s.lexeme);

    // The closing brace is the last real token, on line 4 column 1.
    const brace = toks.items[toks.items.len - 2];
    try std.testing.expectEqual(TokenKind.r_brace, brace.kind);
    try std.testing.expectEqual(@as(u32, 4), brace.line);
    try std.testing.expectEqual(@as(u32, 1), brace.column);
}

test "the eof token sits at the end of the buffer" {
    const src = "fn f()";
    var lex = Lexer.init(src, "t.cell");
    var toks = try lex.tokenizeAll(std.testing.allocator);
    defer toks.deinit(std.testing.allocator);

    const eof = toks.items[toks.items.len - 1];
    try std.testing.expectEqual(TokenKind.eof, eof.kind);
    try std.testing.expectEqual(@as(u32, src.len), eof.start);
    try std.testing.expectEqual(@as(u32, src.len), eof.end);
}

test "SPEC 2.5's reserved words lex as keywords, not identifiers" {
    // The whole reservation is worthless if one of them silently stays an
    // identifier, because that is exactly the failure mode it exists to stop.
    const reserved = [_][]const u8{
        "while",  "for",    "loop",  "break", "continue", "in",
        "impl",   "trait",  "where", "type",  "const",    "static",
        "self",   "Self",   "as",    "is",    "defer",    "async",
        "await",  "yield",  "import", "export", "extern", "unsafe",
    };
    for (reserved) |word| {
        var lex = Lexer.init(word, "t.cell");
        var tokens = try lex.tokenizeAll(std.testing.allocator);
        defer tokens.deinit(std.testing.allocator);
        if (tokens.items[0].kind == .ident) {
            std.debug.print("'{s}' still lexes as an identifier\n", .{word});
            return error.ReservedWordLexedAsIdent;
        }
    }
}

test "Self and self are distinct, and case still matters elsewhere" {
    var lex = Lexer.init("self Self selfish", "t.cell");
    var tokens = try lex.tokenizeAll(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);
    try std.testing.expectEqual(TokenKind.kw_self, tokens.items[0].kind);
    try std.testing.expectEqual(TokenKind.kw_Self, tokens.items[1].kind);
    // A word merely starting with a reserved one is still an identifier.
    try std.testing.expectEqual(TokenKind.ident, tokens.items[2].kind);
}
