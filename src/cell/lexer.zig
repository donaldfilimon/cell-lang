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
    // Value constructors for `T?` and `Result<T, E>` (SPEC 3.2, 3.4).
    // Keywords, so a user enum can never declare a variant with one of
    // these names and the uppercase-is-a-variant pattern rule needs no
    // special case.
    kw_some,
    kw_none,
    kw_ok,
    kw_err,
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

    /// Tokenize a string literal. A backslash skips the next byte so `\"`
    /// does not end the token. Decode of `\n` and friends is the parser's
    /// job (SPEC 2.8); this walk only keeps the lexeme intact. EOF before a
    /// closing quote is `.invalid` so the parser can name it as an
    /// unterminated string rather than silently succeeding.
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
        if (self.index >= self.source.len) return self.make(.invalid, start, line, column);
        self.advance(); // closing "
        return self.make(.string, start, line, column);
    }

    /// Tokenize an integer or float. Hex (`0x1F`), binary (`0b1010`), octal
    /// (`0o17`), underscore separators (`1_000`, `0xFF_FF`), and decimal
    /// exponents (`1e9`, `1.5e-3`) are one token. A digit is required on both
    /// sides of a decimal point, so `1.` and `.5` are not floats. Malformed
    /// forms (trailing or adjacent underscores, a prefix with no digits,
    /// leftover letters, hexadecimal floats) are a single `.invalid` token
    /// rather than a number plus an identifier.
    fn lexNumber(self: *Lexer, start: usize, line: u32, column: u32) Token {
        if (self.source[self.index] == '0' and self.index + 1 < self.source.len) {
            switch (self.source[self.index + 1]) {
                'x', 'X' => return self.lexPrefixedNumber(start, line, column, 16),
                'b', 'B' => return self.lexPrefixedNumber(start, line, column, 2),
                'o', 'O' => return self.lexPrefixedNumber(start, line, column, 8),
                else => {},
            }
        }

        self.consumeNumberBody(10);

        var is_float = false;
        if (self.index < self.source.len and self.source[self.index] == '.' and
            self.index + 1 < self.source.len and std.ascii.isDigit(self.source[self.index + 1]))
        {
            is_float = true;
            self.advance();
            self.consumeNumberBody(10);
        }
        if (self.index < self.source.len and (self.source[self.index] == 'e' or self.source[self.index] == 'E')) {
            is_float = true;
            self.advance();
            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) {
                self.advance();
            }
            const exp_start = self.index;
            self.consumeNumberBody(10);
            if (self.index == exp_start) {
                self.consumeIdentContinue();
                return self.make(.invalid, start, line, column);
            }
        }

        if (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
            self.consumeIdentContinue();
            return self.make(.invalid, start, line, column);
        }

        const lexeme = self.source[start..self.index];
        if (!underscoresOk(lexeme)) return self.make(.invalid, start, line, column);
        return self.make(if (is_float) .float else .int, start, line, column);
    }

    fn lexPrefixedNumber(self: *Lexer, start: usize, line: u32, column: u32, radix: u8) Token {
        self.advance(); // 0
        self.advance(); // x/b/o
        const digits_start = self.index;
        self.consumeNumberBody(radix);

        if (radix == 16 and self.looksLikeHexFloat()) {
            self.consumeHexFloatRest();
            self.consumeIdentContinue();
            return self.make(.invalid, start, line, column);
        }

        if (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
            self.consumeIdentContinue();
            return self.make(.invalid, start, line, column);
        }

        if (self.index == digits_start or !underscoresOk(self.source[start..self.index])) {
            return self.make(.invalid, start, line, column);
        }
        return self.make(.int, start, line, column);
    }

    fn looksLikeHexFloat(self: *const Lexer) bool {
        if (self.index >= self.source.len) return false;
        const c = self.source[self.index];
        if (c == 'p' or c == 'P') return true;
        if (c == '.' and self.index + 1 < self.source.len) {
            const n = self.source[self.index + 1];
            return std.ascii.isHex(n) or n == 'p' or n == 'P' or n == '_';
        }
        return false;
    }

    fn consumeHexFloatRest(self: *Lexer) void {
        if (self.index < self.source.len and self.source[self.index] == '.') {
            self.advance();
            self.consumeNumberBody(16);
        }
        if (self.index < self.source.len and (self.source[self.index] == 'p' or self.source[self.index] == 'P')) {
            self.advance();
            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) {
                self.advance();
            }
            self.consumeNumberBody(10);
        }
    }

    fn consumeNumberBody(self: *Lexer, radix: u8) void {
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c != '_' and !isDigitInRadix(c, radix)) break;
            self.advance();
        }
    }

    fn consumeIdentContinue(self: *Lexer) void {
        while (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
            self.advance();
        }
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
            .{ "Some", .kw_some },
            .{ "None", .kw_none },
            .{ "Ok", .kw_ok },
            .{ "Err", .kw_err },
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

fn isDigitInRadix(c: u8, radix: u8) bool {
    return switch (radix) {
        2 => c == '0' or c == '1',
        8 => c >= '0' and c <= '7',
        10 => std.ascii.isDigit(c),
        16 => std.ascii.isHex(c),
        else => unreachable,
    };
}

/// Underscores must sit between two digits of the literal's radix. Leading,
/// trailing, or adjacent underscores, and an underscore next to a prefix,
/// point, sign, or exponent marker, are not a number.
fn underscoresOk(lexeme: []const u8) bool {
    var i: usize = 0;
    var radix: u8 = 10;
    if (lexeme.len >= 2 and lexeme[0] == '0') {
        switch (lexeme[1]) {
            'x', 'X' => {
                i = 2;
                radix = 16;
            },
            'b', 'B' => {
                i = 2;
                radix = 2;
            },
            'o', 'O' => {
                i = 2;
                radix = 8;
            },
            else => {},
        }
    }
    while (i < lexeme.len) : (i += 1) {
        if (lexeme[i] != '_') continue;
        if (i == 0 or i + 1 >= lexeme.len) return false;
        if (!isDigitInRadix(lexeme[i - 1], radix) or !isDigitInRadix(lexeme[i + 1], radix)) return false;
    }
    return true;
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
        "while", "for",   "loop",   "break",  "continue", "in",
        "impl",  "trait", "where",  "type",   "const",    "static",
        "self",  "Self",  "as",     "is",     "defer",    "async",
        "await", "yield", "import", "export", "extern",   "unsafe",
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

test "Some, None, Ok and Err lex as keywords, not identifiers" {
    const words = [_][]const u8{ "Some", "None", "Ok", "Err" };
    const kinds = [_]TokenKind{ .kw_some, .kw_none, .kw_ok, .kw_err };
    for (words, kinds) |word, kind| {
        var lex = Lexer.init(word, "t.cell");
        var tokens = try lex.tokenizeAll(std.testing.allocator);
        defer tokens.deinit(std.testing.allocator);
        try std.testing.expectEqual(kind, tokens.items[0].kind);
    }
    // A user identifier that merely starts the same way is untouched.
    var lex = Lexer.init("Something", "t.cell");
    var tokens = try lex.tokenizeAll(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);
    try std.testing.expectEqual(TokenKind.ident, tokens.items[0].kind);
}

fn firstToken(src: []const u8) Token {
    var lex = Lexer.init(src, "t.cell");
    return lex.next();
}

test "hex bin oct integers are one token" {
    const cases = [_]struct { src: []const u8, lexeme: []const u8 }{
        .{ .src = "0x1F", .lexeme = "0x1F" },
        .{ .src = "0X1F", .lexeme = "0X1F" },
        .{ .src = "0b1010", .lexeme = "0b1010" },
        .{ .src = "0B1010", .lexeme = "0B1010" },
        .{ .src = "0o17", .lexeme = "0o17" },
        .{ .src = "0O17", .lexeme = "0O17" },
    };
    for (cases) |c| {
        const t = firstToken(c.src);
        try std.testing.expectEqual(TokenKind.int, t.kind);
        try std.testing.expectEqualStrings(c.lexeme, t.lexeme);
    }
}

test "underscore separators are one integer token" {
    const t = firstToken("1_000");
    try std.testing.expectEqual(TokenKind.int, t.kind);
    try std.testing.expectEqualStrings("1_000", t.lexeme);

    const hex = firstToken("0xFF_FF");
    try std.testing.expectEqual(TokenKind.int, hex.kind);
    try std.testing.expectEqualStrings("0xFF_FF", hex.lexeme);
}

test "exponent forms are float tokens" {
    const cases = [_][]const u8{ "1e9", "1E9", "1.5e-3", "1.5e+3" };
    for (cases) |src| {
        const t = firstToken(src);
        try std.testing.expectEqual(TokenKind.float, t.kind);
        try std.testing.expectEqualStrings(src, t.lexeme);
    }
}

test "1. and .5 are not float literals" {
    var lex = Lexer.init("1. .5", "t.cell");
    var toks = try lex.tokenizeAll(std.testing.allocator);
    defer toks.deinit(std.testing.allocator);
    try std.testing.expectEqual(TokenKind.int, toks.items[0].kind);
    try std.testing.expectEqualStrings("1", toks.items[0].lexeme);
    try std.testing.expectEqual(TokenKind.dot, toks.items[1].kind);
    try std.testing.expectEqual(TokenKind.dot, toks.items[2].kind);
    try std.testing.expectEqual(TokenKind.int, toks.items[3].kind);
    try std.testing.expectEqualStrings("5", toks.items[3].lexeme);
}

test "malformed numbers are invalid tokens not split idents" {
    const cases = [_][]const u8{ "1_", "1__000", "0x", "0b102", "0x1p1", "0x1.0p1", "1e", "1e+", "123abc" };
    for (cases) |src| {
        const t = firstToken(src);
        try std.testing.expectEqual(TokenKind.invalid, t.kind);
        try std.testing.expectEqualStrings(src, t.lexeme);
    }
}

test "unterminated string is an invalid token" {
    const t = firstToken("\"hello");
    try std.testing.expectEqual(TokenKind.invalid, t.kind);
    try std.testing.expectEqual(@as(u32, 1), t.column);
    try std.testing.expectEqualStrings("\"hello", t.lexeme);
}
