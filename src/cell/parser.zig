const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");

const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

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

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token, path: []const u8) Parser {
        return .{ .allocator = allocator, .tokens = tokens, .path = path };
    }

    pub fn parseModule(self: *Parser) ParseError!ast.Module {
        var items: std.ArrayList(ast.Item) = .empty;
        errdefer items.deinit(self.allocator);

        while (!self.check(.eof)) {
            const item = try self.parseItem();
            try items.append(self.allocator, item);
        }

        return .{
            .path = self.path,
            .items = try items.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
    }

    fn parseItem(self: *Parser) ParseError!ast.Item {
        const is_pub = self.match(.kw_pub);
        if (self.match(.kw_fn)) {
            return .{ .fn_def = try self.parseFn(is_pub) };
        }
        if (self.match(.kw_struct)) {
            return .{ .struct_def = try self.parseStruct(is_pub) };
        }
        if (self.match(.kw_enum)) {
            return .{ .enum_def = try self.parseEnum(is_pub) };
        }
        if (self.match(.kw_use)) {
            const name = try self.parsePath();
            _ = self.match(.semicolon);
            return .{ .use_decl = name };
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

    fn parseBlockBody(self: *Parser) ParseError![]ast.Stmt {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        errdefer stmts.deinit(self.allocator);
        while (!self.check(.r_brace) and !self.check(.eof)) {
            try stmts.append(self.allocator, try self.parseStmt());
        }
        try self.expect(.r_brace);
        return try stmts.toOwnedSlice(self.allocator);
    }

    fn parseStmt(self: *Parser) ParseError!ast.Stmt {
        if (self.match(.kw_let) or self.match(.kw_var)) {
            const mutable = self.prev().kind == .kw_var or self.match(.kw_mut);
            const ownership = self.parseOwnership() orelse .owned;
            const name = try self.expectIdent();
            var ty: ?ast.TypeExpr = null;
            if (self.match(.colon)) ty = try self.parseType();
            var value: ?ast.Expr = null;
            if (self.match(.eq)) value = try self.parseExpr();
            _ = self.match(.semicolon);
            return .{ .let = .{
                .name = name,
                .ownership = ownership,
                .mutable = mutable,
                .ty = ty,
                .value = value,
            } };
        }
        if (self.match(.kw_return)) {
            var value: ?ast.Expr = null;
            if (!self.check(.semicolon) and !self.check(.r_brace)) {
                value = try self.parseExpr();
            }
            _ = self.match(.semicolon);
            return .{ .return_stmt = value };
        }
        // assignment: name = expr  or  name.field = expr
        if (self.check(.ident)) {
            const save = self.index;
            const name = try self.expectIdent();
            // field assign path
            var path = name;
            while (self.match(.dot)) {
                const field = try self.expectIdent();
                path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ path, field });
            }
            if (self.match(.eq)) {
                const value = try self.parseExpr();
                _ = self.match(.semicolon);
                return .{ .assign = .{ .name = path, .value = value } };
            }
            // not assignment — rewind and parse as expression
            self.index = save;
        }
        const e = try self.parseExpr();
        _ = self.match(.semicolon);
        return .{ .expr = e };
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
            _ = self.advance();
            const right = try self.parseBinary(prec + 1);
            const op = tokenToBinary(op_kind) orelse return self.fail("bad binary op");
            const left_ptr = try self.allocator.create(ast.Expr);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(ast.Expr);
            right_ptr.* = right;
            left = .{ .binary = .{ .op = op, .left = left_ptr, .right = right_ptr } };
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!ast.Expr {
        if (self.match(.minus)) {
            const operand = try self.parseUnary();
            const p = try self.allocator.create(ast.Expr);
            p.* = operand;
            return .{ .unary = .{ .op = .neg, .operand = p } };
        }
        if (self.match(.bang)) {
            const operand = try self.parseUnary();
            const p = try self.allocator.create(ast.Expr);
            p.* = operand;
            return .{ .unary = .{ .op = .not, .operand = p } };
        }
        if (self.match(.amp)) {
            const exclusive = self.match(.kw_mut) or self.match(.kw_exclusive);
            const operand = try self.parseUnary();
            const p = try self.allocator.create(ast.Expr);
            p.* = operand;
            return .{ .unary = .{
                .op = if (exclusive) .ref_exclusive else .ref_shared,
                .operand = p,
            } };
        }
        return try self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) ParseError!ast.Expr {
        // Allow ownership keywords as expression prefixes in call args: exclusive x
        if (self.parseOwnership() != null) {
            return try self.parsePrimary();
        }
        if (self.match(.int)) {
            const v = std.fmt.parseInt(i64, self.prev().lexeme, 10) catch return error.InvalidLiteral;
            return .{ .int = v };
        }
        if (self.match(.float)) {
            const v = std.fmt.parseFloat(f64, self.prev().lexeme) catch return error.InvalidLiteral;
            return .{ .float = v };
        }
        if (self.match(.string)) {
            const raw = self.prev().lexeme;
            if (raw.len >= 2) return .{ .string = raw[1 .. raw.len - 1] };
            return .{ .string = "" };
        }
        if (self.match(.kw_true)) return .{ .bool = true };
        if (self.match(.kw_false)) return .{ .bool = false };
        if (self.match(.ident)) {
            const name = self.prev().lexeme;
            // struct literal: Name { field: expr, ... }  (fields skipped in AST for MVP)
            if (self.match(.l_brace)) {
                while (!self.check(.r_brace) and !self.check(.eof)) {
                    if (self.match(.ident)) {
                        if (self.match(.colon)) {
                            _ = try self.parseExpr();
                        }
                    } else {
                        _ = try self.parseExpr();
                    }
                    _ = self.match(.comma);
                }
                try self.expect(.r_brace);
                return .{ .ident = name }; // treat as value of type Name for MVP
            }
            if (self.match(.l_paren)) {
                var args: std.ArrayList(ast.Expr) = .empty;
                errdefer args.deinit(self.allocator);
                if (!self.check(.r_paren)) {
                    while (true) {
                        try args.append(self.allocator, try self.parseExpr());
                        if (!self.match(.comma)) break;
                    }
                }
                try self.expect(.r_paren);
                const callee = try self.allocator.create(ast.Expr);
                callee.* = .{ .ident = name };
                return .{ .call = .{
                    .callee = callee,
                    .args = try args.toOwnedSlice(self.allocator),
                } };
            }
            // field access chain: a.b.c
            if (self.check(.dot)) {
                var path = name;
                while (self.match(.dot)) {
                    const field = try self.expectIdent();
                    // allocate concatenated path for display
                    const joined = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ path, field });
                    path = joined;
                }
                return .{ .ident = path };
            }
            return .{ .ident = name };
        }
        if (self.match(.l_paren)) {
            const e = try self.parseExpr();
            try self.expect(.r_paren);
            return e;
        }
        if (self.match(.l_bracket)) {
            // empty list literal [] or [expr, ...]
            while (!self.check(.r_bracket) and !self.check(.eof)) {
                _ = try self.parseExpr();
                _ = self.match(.comma);
            }
            try self.expect(.r_bracket);
            return .{ .ident = "[]" };
        }
        if (self.match(.kw_if)) {
            const cond = try self.parseExpr();
            try self.expect(.l_brace);
            _ = try self.parseBlockBody();
            const else_body: ?*ast.Expr = null;
            if (self.match(.kw_else)) {
                try self.expect(.l_brace);
                _ = try self.parseBlockBody();
            }
            const cond_ptr = try self.allocator.create(ast.Expr);
            cond_ptr.* = cond;
            const then_ptr = try self.allocator.create(ast.Expr);
            then_ptr.* = .{ .int = 0 };
            return .{ .if_expr = .{ .cond = cond_ptr, .then_body = then_ptr, .else_body = else_body } };
        }
        return self.fail("expected expression");
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

    fn current(self: *const Parser) Token {
        if (self.index >= self.tokens.len) {
            return .{ .kind = .eof, .lexeme = "", .line = 0, .column = 0 };
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

    fn fail(self: *Parser, msg: []const u8) ParseError {
        _ = self;
        _ = msg;
        return error.UnexpectedToken;
    }
};

test "parse fn" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const src =
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
    ;
    var lex = lexer.Lexer.init(src, "t.cell");
    const toks = try lex.tokenizeAll(arena);
    var p = Parser.init(arena, toks.items, "t.cell");
    const mod = try p.parseModule();
    try std.testing.expectEqual(@as(usize, 1), mod.items.len);
}
