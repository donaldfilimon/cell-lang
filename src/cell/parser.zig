const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const diag = @import("diag.zig");

const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const Span = ast.Span;

pub const ParseError = error{
    UnexpectedToken,
    OutOfMemory,
    InvalidLiteral,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    index: usize = 0,
    path: []const u8,
    /// While true, a bare `Name {` is not a struct literal. Set while parsing
    /// an `if` condition or a `match` scrutinee, where the brace opens the
    /// body instead. Cleared inside parentheses and brackets.
    no_struct_lit: bool = false,
    /// Position and message of the failure that aborted the parse. Recorded
    /// here so a caller can render it; `root.zig` still returns only the bare
    /// error, so nothing surfaces this to the CLI yet.
    last_error: ?Failure = null,

    pub const Failure = struct {
        span: Span,
        message: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token, path: []const u8) Parser {
        return .{ .allocator = allocator, .tokens = tokens, .path = path };
    }

    pub fn parseModule(self: *Parser) ParseError!ast.Module {
        var items: std.ArrayList(ast.Item) = .empty;
        errdefer items.deinit(self.allocator);

        while (!self.check(.eof)) {
            const parsed = try self.parseItem();
            try items.append(self.allocator, parsed);
        }

        return .{
            .path = self.path,
            .items = try items.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    /// Push the recorded parse failure, if any, into a diagnostic bag.
    pub fn reportInto(self: *const Parser, bag: *diag.Bag, allocator: std.mem.Allocator) !void {
        if (self.last_error) |f| try bag.err(allocator, f.span, f.message);
    }

    fn parseItem(self: *Parser) ParseError!ast.Item {
        const start = self.current();
        const is_pub = self.match(.kw_pub);
        if (self.match(.kw_fn)) {
            return self.item(.{ .fn_def = try self.parseFn(is_pub) }, start);
        }
        if (self.match(.kw_struct)) {
            return self.item(.{ .struct_def = try self.parseStruct(is_pub) }, start);
        }
        if (self.match(.kw_enum)) {
            return self.item(.{ .enum_def = try self.parseEnum(is_pub) }, start);
        }
        if (self.match(.kw_use)) {
            const name = try self.parsePath();
            _ = self.match(.semicolon);
            return self.item(.{ .use_decl = name }, start);
        }
        return self.fail("expected item (fn/struct/enum/use)");
    }

    fn parseFn(self: *Parser, is_public: bool) ParseError!ast.FnDef {
        const name = try self.expectIdent();
        try self.expect(.l_paren);
        var params: std.ArrayList(ast.Param) = .empty;
        errdefer params.deinit(self.allocator);
        if (!self.check(.r_paren)) {
            while (true) {
                const ownership = self.parseOwnership() orelse .owned;
                const pname = try self.expectIdent();
                try self.expect(.colon);
                const ty = try self.parseType();
                try params.append(self.allocator, .{
                    .name = pname,
                    .ownership = ownership,
                    .ty = ty,
                });
                if (!self.match(.comma)) break;
            }
        }
        try self.expect(.r_paren);

        var return_type: ?ast.TypeExpr = null;
        if (self.match(.arrow)) {
            return_type = try self.parseType();
        }

        var body: ?[]ast.Stmt = null;
        if (self.match(.l_brace)) {
            body = try self.parseBlockBody();
        } else {
            _ = self.match(.semicolon);
        }

        return .{
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .body = body,
            .is_public = is_public,
        };
    }

    fn parseStruct(self: *Parser, is_public: bool) ParseError!ast.StructDef {
        const name = try self.expectIdent();
        try self.expect(.l_brace);
        var fields: std.ArrayList(ast.Field) = .empty;
        errdefer fields.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            const ownership = self.parseOwnership() orelse .owned;
            const fname = try self.expectIdent();
            try self.expect(.colon);
            const ty = try self.parseType();
            _ = self.match(.comma);
            _ = self.match(.semicolon);
            try fields.append(self.allocator, .{
                .name = fname,
                .ty = ty,
                .ownership = ownership,
            });
        }
        try self.expect(.r_brace);
        return .{
            .name = name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .is_public = is_public,
        };
    }

    fn parseEnum(self: *Parser, is_public: bool) ParseError!ast.EnumDef {
        const name = try self.expectIdent();
        try self.expect(.l_brace);
        var variants: std.ArrayList([]const u8) = .empty;
        errdefer variants.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            const v = try self.expectIdent();
            try variants.append(self.allocator, v);
            _ = self.match(.comma);
        }
        try self.expect(.r_brace);
        return .{
            .name = name,
            .variants = try variants.toOwnedSlice(self.allocator),
            .is_public = is_public,
        };
    }

    /// Parse statements up to and including the closing brace. The opening
    /// brace must already have been consumed.
    fn parseBlockBody(self: *Parser) ParseError![]ast.Stmt {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        errdefer stmts.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            try stmts.append(self.allocator, try self.parseStmt());
        }
        try self.expect(.r_brace);
        return try stmts.toOwnedSlice(self.allocator);
    }

    /// Parse `{ ... }` as a block expression. The opening brace must already
    /// have been consumed; `start` is that brace token.
    fn parseBlockExpr(self: *Parser, start: Token) ParseError!ast.Expr {
        const stmts = try self.parseBlockBody();
        return self.expr(.{ .block = stmts }, start);
    }

    fn parseStmt(self: *Parser) ParseError!ast.Stmt {
        const start = self.current();
        if (self.match(.kw_let) or self.match(.kw_var)) {
            const mutable = self.prev().kind == .kw_var or self.match(.kw_mut);
            const ownership = self.parseOwnership() orelse .owned;
            const name = try self.expectIdent();
            var ty: ?ast.TypeExpr = null;
            if (self.match(.colon)) ty = try self.parseType();
            var value: ?ast.Expr = null;
            if (self.match(.eq)) value = try self.parseExpr();
            _ = self.match(.semicolon);
            return self.stmt(.{ .let = .{
                .name = name,
                .ownership = ownership,
                .mutable = mutable,
                .ty = ty,
                .value = value,
            } }, start);
        }
        if (self.match(.kw_return)) {
            var value: ?ast.Expr = null;
            if (!self.check(.semicolon) and !self.check(.r_brace)) {
                value = try self.parseExpr();
            }
            _ = self.match(.semicolon);
            return self.stmt(.{ .return_stmt = value }, start);
        }

        // Either an assignment or a bare expression statement. Parse the
        // expression first, then look for `=`. That keeps one code path for
        // `x = e`, `x.y = e` and `f(x)` with no backtracking.
        const lhs = try self.parseExpr();
        if (self.match(.eq)) {
            const value = try self.parseExpr();
            _ = self.match(.semicolon);
            return self.stmt(.{ .assign = .{ .target = lhs, .value = value } }, start);
        }
        _ = self.match(.semicolon);
        return self.stmt(.{ .expr = lhs }, start);
    }

    fn parseExpr(self: *Parser) ParseError!ast.Expr {
        return try self.parseBinary(0);
    }

    fn parseBinary(self: *Parser, min_prec: u8) ParseError!ast.Expr {
        var left = try self.parseUnary();
        while (true) {
            const op_kind = self.current().kind;
            const prec = binaryPrec(op_kind) orelse break;
            if (prec < min_prec) break;
            const op = tokenToBinary(op_kind) orelse return self.fail("bad binary op");
            _ = self.advance();
            const right = try self.parseBinary(prec + 1);
            const left_ptr = try self.allocator.create(ast.Expr);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(ast.Expr);
            right_ptr.* = right;
            left = .{
                .kind = .{ .binary = .{ .op = op, .left = left_ptr, .right = right_ptr } },
                .span = Span.merge(left_ptr.span, right_ptr.span),
            };
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!ast.Expr {
        const start = self.current();
        if (self.match(.minus)) {
            return self.unary(.neg, try self.parseUnary(), start);
        }
        if (self.match(.bang)) {
            return self.unary(.not, try self.parseUnary(), start);
        }
        if (self.match(.amp)) {
            const exclusive = self.match(.kw_mut) or self.match(.kw_exclusive);
            const operand = try self.parseUnary();
            return self.unary(if (exclusive) .ref_exclusive else .ref_shared, operand, start);
        }
        return try self.parsePostfix();
    }

    fn unary(self: *Parser, op: ast.UnaryOp, operand: ast.Expr, start: Token) ParseError!ast.Expr {
        const p = try self.allocator.create(ast.Expr);
        p.* = operand;
        return self.expr(.{ .unary = .{ .op = op, .operand = p } }, start);
    }

    /// A primary expression followed by any number of `.field` and `(args)`
    /// suffixes, so `a.b(c).d` becomes a chain instead of a flattened name.
    fn parsePostfix(self: *Parser) ParseError!ast.Expr {
        const start = self.current();
        var e = try self.parsePrimary();
        while (true) {
            if (self.match(.dot)) {
                const name = try self.expectIdent();
                const base = try self.allocator.create(ast.Expr);
                base.* = e;
                e = self.expr(.{ .field = .{ .base = base, .name = name } }, start);
                continue;
            }
            if (self.match(.l_paren)) {
                const args = try self.parseCallArgs();
                const callee = try self.allocator.create(ast.Expr);
                callee.* = e;
                e = self.expr(.{ .call = .{ .callee = callee, .args = args } }, start);
                continue;
            }
            break;
        }
        return e;
    }

    /// Parse `expr, expr, ...)`. The opening paren must already be consumed.
    fn parseCallArgs(self: *Parser) ParseError![]ast.Expr {
        var args: std.ArrayList(ast.Expr) = .empty;
        errdefer args.deinit(self.allocator);
        const saved = self.no_struct_lit;
        self.no_struct_lit = false;
        defer self.no_struct_lit = saved;
        if (!self.check(.r_paren)) {
            while (true) {
                try args.append(self.allocator, try self.parseExpr());
                if (!self.match(.comma)) break;
            }
        }
        try self.expect(.r_paren);
        return try args.toOwnedSlice(self.allocator);
    }

    fn parsePrimary(self: *Parser) ParseError!ast.Expr {
        const start = self.current();
        // Ownership keywords are allowed as expression prefixes in call
        // arguments: `add(shared 40, shared 2)`.
        if (self.parseOwnership() != null) {
            const inner = try self.parseUnary();
            return .{ .kind = inner.kind, .span = Span.merge(tokenSpan(start), inner.span) };
        }
        if (self.match(.int)) {
            const v = std.fmt.parseInt(i64, self.prev().lexeme, 10) catch return error.InvalidLiteral;
            return self.expr(.{ .int = v }, start);
        }
        if (self.match(.float)) {
            const v = std.fmt.parseFloat(f64, self.prev().lexeme) catch return error.InvalidLiteral;
            return self.expr(.{ .float = v }, start);
        }
        if (self.match(.string)) {
            return self.expr(.{ .string = stringValue(self.prev().lexeme) }, start);
        }
        if (self.match(.kw_true)) return self.expr(.{ .bool = true }, start);
        if (self.match(.kw_false)) return self.expr(.{ .bool = false }, start);
        if (self.match(.ident)) {
            const name = self.prev().lexeme;
            if (!self.no_struct_lit and self.check(.l_brace)) {
                return try self.parseStructLit(name, start);
            }
            return self.expr(.{ .ident = name }, start);
        }
        if (self.match(.l_paren)) {
            const saved = self.no_struct_lit;
            self.no_struct_lit = false;
            const e = try self.parseExpr();
            self.no_struct_lit = saved;
            try self.expect(.r_paren);
            return .{ .kind = e.kind, .span = self.spanFrom(start) };
        }
        if (self.match(.l_bracket)) return try self.parseListLit(start);
        if (self.match(.l_brace)) return try self.parseBlockExpr(start);
        if (self.match(.kw_if)) return try self.parseIf(start);
        if (self.match(.kw_match)) return try self.parseMatch(start);
        return self.fail("expected expression");
    }

    /// `Name { field: expr, ... }`. The name is consumed; the brace is not.
    fn parseStructLit(self: *Parser, name: []const u8, start: Token) ParseError!ast.Expr {
        try self.expect(.l_brace);
        const saved = self.no_struct_lit;
        self.no_struct_lit = false;
        defer self.no_struct_lit = saved;

        var fields: std.ArrayList(ast.FieldInit) = .empty;
        errdefer fields.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            const fstart = self.current();
            const fname = try self.expectIdent();
            // `Name { x }` is shorthand for `Name { x: x }`.
            const value = if (self.match(.colon))
                try self.parseExpr()
            else
                self.expr(.{ .ident = fname }, fstart);
            try fields.append(self.allocator, .{
                .name = fname,
                .value = value,
                .span = self.spanFrom(fstart),
            });
            if (!self.match(.comma)) break;
        }
        try self.expect(.r_brace);
        return self.expr(.{ .struct_lit = .{
            .name = name,
            .fields = try fields.toOwnedSlice(self.allocator),
        } }, start);
    }

    /// `[]` or `[a, b, c]`. The opening bracket is already consumed.
    fn parseListLit(self: *Parser, start: Token) ParseError!ast.Expr {
        const saved = self.no_struct_lit;
        self.no_struct_lit = false;
        defer self.no_struct_lit = saved;

        var items: std.ArrayList(ast.Expr) = .empty;
        errdefer items.deinit(self.allocator);
        while (!self.check(.r_bracket) and !self.check(.eof)) {
            try items.append(self.allocator, try self.parseExpr());
            if (!self.match(.comma)) break;
        }
        try self.expect(.r_bracket);
        return self.expr(.{ .list_lit = try items.toOwnedSlice(self.allocator) }, start);
    }

    /// `if cond { ... } else { ... }`. The `if` keyword is already consumed.
    fn parseIf(self: *Parser, start: Token) ParseError!ast.Expr {
        const cond = try self.parseNoStructLitExpr();
        const then_start = self.current();
        try self.expect(.l_brace);
        const then_body = try self.parseBlockExpr(then_start);

        var else_body: ?*ast.Expr = null;
        if (self.match(.kw_else)) {
            const else_start = self.current();
            const e = if (self.match(.kw_if))
                try self.parseIf(else_start)
            else blk: {
                try self.expect(.l_brace);
                break :blk try self.parseBlockExpr(else_start);
            };
            const p = try self.allocator.create(ast.Expr);
            p.* = e;
            else_body = p;
        }

        const cond_ptr = try self.allocator.create(ast.Expr);
        cond_ptr.* = cond;
        const then_ptr = try self.allocator.create(ast.Expr);
        then_ptr.* = then_body;
        return self.expr(.{ .if_expr = .{
            .cond = cond_ptr,
            .then_body = then_ptr,
            .else_body = else_body,
        } }, start);
    }

    /// `match scrutinee { pattern => expr, ... }`. `match` is consumed.
    fn parseMatch(self: *Parser, start: Token) ParseError!ast.Expr {
        const scrutinee = try self.parseNoStructLitExpr();
        try self.expect(.l_brace);

        var arms: std.ArrayList(ast.MatchArm) = .empty;
        errdefer arms.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            const arm_start = self.current();
            const arm_pattern = try self.parsePattern();
            try self.expect(.fat_arrow);
            const body = try self.parseExpr();
            const body_ptr = try self.allocator.create(ast.Expr);
            body_ptr.* = body;
            try arms.append(self.allocator, .{
                .pattern = arm_pattern,
                .body = body_ptr,
                .span = self.spanFrom(arm_start),
            });
            if (!self.match(.comma)) break;
        }
        try self.expect(.r_brace);

        const scrut_ptr = try self.allocator.create(ast.Expr);
        scrut_ptr.* = scrutinee;
        return self.expr(.{ .match_expr = .{
            .scrutinee = scrut_ptr,
            .arms = try arms.toOwnedSlice(self.allocator),
        } }, start);
    }

    /// Parse an expression in a position where a following `{` opens a body
    /// rather than a struct literal.
    fn parseNoStructLitExpr(self: *Parser) ParseError!ast.Expr {
        const saved = self.no_struct_lit;
        self.no_struct_lit = true;
        defer self.no_struct_lit = saved;
        return try self.parseExpr();
    }

    fn parsePattern(self: *Parser) ParseError!ast.Pattern {
        const start = self.current();
        if (self.match(.minus)) {
            if (self.match(.int)) {
                const v = std.fmt.parseInt(i64, self.prev().lexeme, 10) catch return error.InvalidLiteral;
                return self.patternNode(.{ .int = -v }, start);
            }
            if (self.match(.float)) {
                const v = std.fmt.parseFloat(f64, self.prev().lexeme) catch return error.InvalidLiteral;
                return self.patternNode(.{ .float = -v }, start);
            }
            return self.fail("expected a number after '-' in pattern");
        }
        if (self.match(.int)) {
            const v = std.fmt.parseInt(i64, self.prev().lexeme, 10) catch return error.InvalidLiteral;
            return self.patternNode(.{ .int = v }, start);
        }
        if (self.match(.float)) {
            const v = std.fmt.parseFloat(f64, self.prev().lexeme) catch return error.InvalidLiteral;
            return self.patternNode(.{ .float = v }, start);
        }
        if (self.match(.string)) {
            return self.patternNode(.{ .string = stringValue(self.prev().lexeme) }, start);
        }
        if (self.match(.kw_true)) return self.patternNode(.{ .bool = true }, start);
        if (self.match(.kw_false)) return self.patternNode(.{ .bool = false }, start);
        if (self.match(.ident)) {
            const name = self.prev().lexeme;
            // `_` lexes as an identifier, so the wildcard is a lexeme test.
            if (std.mem.eql(u8, name, "_")) return self.patternNode(.wildcard, start);
            if (self.match(.dot)) {
                const variant = try self.expectIdent();
                return self.patternNode(.{ .enum_variant = .{
                    .enum_name = name,
                    .variant = variant,
                } }, start);
            }
            // A leading uppercase letter means a variant; anything else binds.
            if (std.ascii.isUpper(name[0])) {
                return self.patternNode(.{ .enum_variant = .{
                    .enum_name = null,
                    .variant = name,
                } }, start);
            }
            return self.patternNode(.{ .binding = name }, start);
        }
        return self.fail("expected pattern");
    }

    fn parsePath(self: *Parser) ParseError![]const u8 {
        const first = try self.expectIdent();
        if (!self.check(.dot)) return first;
        var path = first;
        while (self.match(.dot)) {
            const part = try self.expectIdent();
            path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ path, part });
        }
        return path;
    }

    fn parseType(self: *Parser) ParseError!ast.TypeExpr {
        if (self.match(.l_bracket)) {
            const inner = try self.parseType();
            try self.expect(.r_bracket);
            const p = try self.allocator.create(ast.TypeExpr);
            p.* = inner;
            return .{ .list = p };
        }
        // ownership prefix on types: shared T, exclusive T, arc T
        if (self.parseOwnership()) |own| {
            const inner = try self.parseType();
            const p = try self.allocator.create(ast.TypeExpr);
            p.* = inner;
            return .{ .ref = .{ .ownership = own, .inner = p } };
        }
        const name = try self.expectIdent();
        var ty: ast.TypeExpr = .{ .name = name };
        if (self.match(.question)) {
            const p = try self.allocator.create(ast.TypeExpr);
            p.* = ty;
            ty = .{ .optional = p };
        }
        return ty;
    }

    fn parseOwnership(self: *Parser) ?ast.Ownership {
        if (self.match(.kw_owned)) return .owned;
        if (self.match(.kw_shared)) return .shared;
        if (self.match(.kw_exclusive)) return .exclusive;
        if (self.match(.kw_arc)) return .arc;
        if (self.match(.kw_copy)) return .copy;
        return null;
    }

    fn binaryPrec(kind: TokenKind) ?u8 {
        return switch (kind) {
            .pipe_pipe => 1,
            .amp_amp => 2,
            .eq_eq, .ne => 3,
            .lt, .le, .gt, .ge => 4,
            .plus, .minus => 5,
            .star, .slash => 6,
            else => null,
        };
    }

    fn tokenToBinary(kind: TokenKind) ?ast.BinaryOp {
        return switch (kind) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .eq_eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            .amp_amp => .and_op,
            .pipe_pipe => .or_op,
            else => null,
        };
    }

    // ── span plumbing ───────────────────────────────────────────────────

    fn tokenSpan(t: Token) Span {
        return .{ .start = t.start, .end = t.end, .line = t.line, .column = t.column };
    }

    /// Span from `start` through the last token this parser consumed.
    fn spanFrom(self: *const Parser, start: Token) Span {
        const s = tokenSpan(start);
        if (self.index == 0) return s;
        const last = self.tokens[self.index - 1];
        return .{
            .start = s.start,
            .end = @max(s.end, last.end),
            .line = s.line,
            .column = s.column,
        };
    }

    fn expr(self: *const Parser, kind: ast.Expr.Kind, start: Token) ast.Expr {
        return .{ .kind = kind, .span = self.spanFrom(start) };
    }

    fn stmt(self: *const Parser, kind: ast.Stmt.Kind, start: Token) ast.Stmt {
        return .{ .kind = kind, .span = self.spanFrom(start) };
    }

    fn item(self: *const Parser, kind: ast.Item.Kind, start: Token) ast.Item {
        return .{ .kind = kind, .span = self.spanFrom(start) };
    }

    fn patternNode(self: *const Parser, kind: ast.Pattern.Kind, start: Token) ast.Pattern {
        return .{ .kind = kind, .span = self.spanFrom(start) };
    }

    // ── token cursor ────────────────────────────────────────────────────

    fn current(self: *const Parser) Token {
        if (self.index >= self.tokens.len) {
            // Past the end: report at the last real token so a truncated file
            // does not produce a 0:0 location.
            if (self.tokens.len == 0) {
                return .{ .kind = .eof, .lexeme = "", .start = 0, .end = 0, .line = 1, .column = 1 };
            }
            const last = self.tokens[self.tokens.len - 1];
            return .{
                .kind = .eof,
                .lexeme = "",
                .start = last.end,
                .end = last.end,
                .line = last.line,
                .column = last.column,
            };
        }
        return self.tokens[self.index];
    }

    fn prev(self: *const Parser) Token {
        return self.tokens[self.index - 1];
    }

    fn advance(self: *Parser) Token {
        const t = self.current();
        if (self.index < self.tokens.len) self.index += 1;
        return t;
    }

    fn check(self: *const Parser, kind: TokenKind) bool {
        return self.current().kind == kind;
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.check(kind)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!void {
        if (!self.match(kind)) return self.fail("unexpected token");
    }

    fn expectIdent(self: *Parser) ParseError![]const u8 {
        if (self.match(.ident)) return self.prev().lexeme;
        return self.fail("expected identifier");
    }

    /// Record where and why the parse failed, then return the error. Only the
    /// first failure is kept: later ones are consequences of it.
    fn fail(self: *Parser, msg: []const u8) ParseError {
        if (self.last_error == null) {
            self.last_error = .{ .span = tokenSpan(self.current()), .message = msg };
        }
        return error.UnexpectedToken;
    }
};

/// Strip the surrounding quotes from a string token's lexeme.
fn stringValue(raw: []const u8) []const u8 {
    if (raw.len >= 2) return raw[1 .. raw.len - 1];
    return "";
}

// ── tests ───────────────────────────────────────────────────────────────

const TestParse = struct {
    arena: std.heap.ArenaAllocator,
    module: ast.Module,

    fn deinit(self: *TestParse) void {
        self.arena.deinit();
    }
};

fn parseForTest(src: []const u8) !TestParse {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var lex = lexer.Lexer.init(src, "t.cell");
    const toks = try lex.tokenizeAll(alloc);
    var p = Parser.init(alloc, toks.items, "t.cell");
    const module = try p.parseModule();
    return .{ .arena = arena, .module = module };
}

/// The single statement of the single function in a parsed module.
fn onlyStmt(module: ast.Module) ast.Stmt {
    return module.items[0].kind.fn_def.body.?[0];
}

test "parse fn" {
    var tp = try parseForTest(
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
    );
    defer tp.deinit();
    try std.testing.expectEqual(@as(usize, 1), tp.module.items.len);
    try std.testing.expectEqualStrings("add", tp.module.items[0].kind.fn_def.name);
}

test "spans point at the right line and column" {
    const src =
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
        \\
        \\pub struct Point {
        \\  copy x: Float64
        \\}
    ;
    var tp = try parseForTest(src);
    defer tp.deinit();

    // Item spans start at `pub`, which is column 1 on lines 1 and 5.
    const fn_item = tp.module.items[0];
    try std.testing.expectEqual(@as(u32, 1), fn_item.span.line);
    try std.testing.expectEqual(@as(u32, 1), fn_item.span.column);
    try std.testing.expectEqualStrings("pub", src[fn_item.span.start..][0..3]);

    const struct_item = tp.module.items[1];
    try std.testing.expectEqual(@as(u32, 5), struct_item.span.line);
    try std.testing.expectEqual(@as(u32, 1), struct_item.span.column);

    // The return statement starts at `return`: line 2, column 3.
    const ret = onlyStmt(tp.module);
    try std.testing.expectEqual(@as(u32, 2), ret.span.line);
    try std.testing.expectEqual(@as(u32, 3), ret.span.column);
    try std.testing.expectEqualStrings("return a + b", src[ret.span.start..ret.span.end]);

    // The `a + b` binary expression starts at `a`: line 2, column 10.
    const sum = ret.kind.return_stmt.?;
    try std.testing.expectEqual(@as(u32, 2), sum.span.line);
    try std.testing.expectEqual(@as(u32, 10), sum.span.column);
    try std.testing.expect(sum.span.start < sum.span.end);
    try std.testing.expectEqualStrings("a + b", src[sum.span.start..sum.span.end]);
}

test "struct literal keeps its field initializers" {
    const src =
        \\pub fn main() {
        \\  let owned p = Point { x: 1.0, y: 2.0 }
        \\}
    ;
    var tp = try parseForTest(src);
    defer tp.deinit();

    const value = onlyStmt(tp.module).kind.let.value.?;
    const lit = value.kind.struct_lit;
    try std.testing.expectEqualStrings("Point", lit.name);
    try std.testing.expectEqual(@as(usize, 2), lit.fields.len);
    try std.testing.expectEqualStrings("x", lit.fields[0].name);
    try std.testing.expectEqual(@as(f64, 1.0), lit.fields[0].value.kind.float);
    try std.testing.expectEqualStrings("y", lit.fields[1].name);
    try std.testing.expectEqual(@as(f64, 2.0), lit.fields[1].value.kind.float);
    // The literal's span starts at `Point`: line 2, column 17.
    try std.testing.expectEqual(@as(u32, 2), value.span.line);
    try std.testing.expectEqual(@as(u32, 17), value.span.column);
    try std.testing.expectEqualStrings("Point { x: 1.0, y: 2.0 }", src[value.span.start..value.span.end]);
}

test "struct literal with a list field parses" {
    var tp = try parseForTest(
        \\pub fn main() {
        \\  let owned b = Buffer { data: [], len: 0 }
        \\}
    );
    defer tp.deinit();

    const lit = onlyStmt(tp.module).kind.let.value.?.kind.struct_lit;
    try std.testing.expectEqualStrings("Buffer", lit.name);
    try std.testing.expectEqual(@as(usize, 2), lit.fields.len);
    try std.testing.expectEqual(@as(usize, 0), lit.fields[0].value.kind.list_lit.len);
    try std.testing.expectEqual(@as(i64, 0), lit.fields[1].value.kind.int);
}

test "field access is an expression, not a flattened name" {
    var tp = try parseForTest(
        \\pub fn main() {
        \\  let copy n = buf.len
        \\}
    );
    defer tp.deinit();

    const value = onlyStmt(tp.module).kind.let.value.?;
    try std.testing.expectEqualStrings("len", value.kind.field.name);
    try std.testing.expectEqualStrings("buf", value.kind.field.base.kind.ident);
    try std.testing.expectEqualStrings("buf", ast.rootName(&value).?);
}

test "field assignment targets a field expression" {
    var tp = try parseForTest(
        \\pub fn main() {
        \\  buf.len = 3
        \\}
    );
    defer tp.deinit();

    const a = onlyStmt(tp.module).kind.assign;
    try std.testing.expectEqualStrings("len", a.target.kind.field.name);
    try std.testing.expectEqualStrings("buf", ast.rootName(&a.target).?);
    try std.testing.expectEqual(@as(i64, 3), a.value.kind.int);
}

test "each match pattern form parses" {
    var tp = try parseForTest(
        \\pub fn describe(shared c: Color) -> Int {
        \\  return match c {
        \\    Color.Red => 1,
        \\    Green => 2,
        \\    other => 3,
        \\    4 => 4,
        \\    "s" => 5,
        \\    true => 6,
        \\    _ => 0,
        \\  }
        \\}
    );
    defer tp.deinit();

    const m = onlyStmt(tp.module).kind.return_stmt.?.kind.match_expr;
    try std.testing.expectEqualStrings("c", m.scrutinee.kind.ident);
    try std.testing.expectEqual(@as(usize, 7), m.arms.len);

    const qualified = m.arms[0].pattern.kind.enum_variant;
    try std.testing.expectEqualStrings("Color", qualified.enum_name.?);
    try std.testing.expectEqualStrings("Red", qualified.variant);

    const bare = m.arms[1].pattern.kind.enum_variant;
    try std.testing.expect(bare.enum_name == null);
    try std.testing.expectEqualStrings("Green", bare.variant);

    try std.testing.expectEqualStrings("other", m.arms[2].pattern.kind.binding);
    try std.testing.expectEqual(@as(i64, 4), m.arms[3].pattern.kind.int);
    try std.testing.expectEqualStrings("s", m.arms[4].pattern.kind.string);
    try std.testing.expectEqual(true, m.arms[5].pattern.kind.bool);
    try std.testing.expect(m.arms[6].pattern.kind == .wildcard);

    // Arm patterns carry their own spans: `Color.Red` is line 3, column 5.
    try std.testing.expectEqual(@as(u32, 3), m.arms[0].pattern.span.line);
    try std.testing.expectEqual(@as(u32, 5), m.arms[0].pattern.span.column);
}

test "a brace after a bare match scrutinee opens the body, not a struct literal" {
    var tp = try parseForTest(
        \\pub fn f(shared c: Color) -> Int {
        \\  return match c { _ => 0 }
        \\}
    );
    defer tp.deinit();

    const m = onlyStmt(tp.module).kind.return_stmt.?.kind.match_expr;
    try std.testing.expectEqualStrings("c", m.scrutinee.kind.ident);
    try std.testing.expectEqual(@as(usize, 1), m.arms.len);
}

test "if keeps both bodies" {
    var tp = try parseForTest(
        \\pub fn f(shared flag: Bool) -> Int {
        \\  if flag { return 1 } else { return 2 }
        \\  return 0
        \\}
    );
    defer tp.deinit();

    const body = tp.module.items[0].kind.fn_def.body.?;
    try std.testing.expectEqual(@as(usize, 2), body.len);
    const i = body[0].kind.expr.kind.if_expr;
    try std.testing.expectEqualStrings("flag", i.cond.kind.ident);
    try std.testing.expectEqual(@as(usize, 1), i.then_body.kind.block.len);
    try std.testing.expectEqual(@as(usize, 1), i.else_body.?.kind.block.len);
}

test "call on a field chain parses as a postfix chain" {
    var tp = try parseForTest(
        \\pub fn main() {
        \\  io.print(1)
        \\}
    );
    defer tp.deinit();

    const call = onlyStmt(tp.module).kind.expr.kind.call;
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expectEqualStrings("print", call.callee.kind.field.name);
    try std.testing.expectEqualStrings("io", call.callee.kind.field.base.kind.ident);
}

test "a parse failure records its position and message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src =
        \\pub fn f() {
        \\  let owned x = *
        \\}
    ;
    var lex = lexer.Lexer.init(src, "t.cell");
    const toks = try lex.tokenizeAll(alloc);
    var p = Parser.init(alloc, toks.items, "t.cell");
    try std.testing.expectError(error.UnexpectedToken, p.parseModule());

    const f = p.last_error.?;
    try std.testing.expectEqualStrings("expected expression", f.message);
    try std.testing.expectEqual(@as(u32, 2), f.span.line);
    try std.testing.expectEqual(@as(u32, 17), f.span.column);
}
