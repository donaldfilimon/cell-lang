//! Test harnesses and helpers shared by the borrow checker's test files.

const std = @import("std");
const ast = @import("../ast.zig");
const bk_root = @import("../borrowck.zig");
const Checker = bk_root.Checker;

// ── tests ───────────────────────────────────────────────────────────────
//
// Every rule gets a rejection test that pins the diagnostic text, line and
// column, and an acceptance test for the shape the rule is meant to allow.
// Diagnostics are rendered without a source buffer so the assertion is one
// line per diagnostic; one test at the end supplies the source and pins the
// caret column instead.

pub const lexer = @import("../lexer.zig");
pub const parser = @import("../parser.zig");

pub const Harness = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
    }

    /// Parse and borrow-check `src`, rendering every diagnostic into `out`.
    pub fn run(self: *Harness, src: []const u8, out: []u8, with_source: bool) ![]u8 {
        const gpa = self.arena.allocator();
        var lex = lexer.Lexer.init(src, "t.cell");
        const tokens = try lex.tokenizeAll(gpa);
        var p = parser.Parser.init(gpa, tokens.items, "t.cell");
        var module = try p.parseModule();
        var checker: Checker = .init(gpa, "t.cell", if (with_source) src else null);
        defer checker.deinit();
        try checker.checkModule(&module);
        var w = std.Io.Writer.fixed(out);
        try checker.diagnostics.printAll(&w);
        return w.buffered();
    }
};

/// Parse and borrow-check `src`, keeping the checker so a test can ask
/// `liveAtExit`. The module lives in the same arena as the checker.
///
/// The arena is heap-allocated on purpose. `arena.allocator()` captures the
/// arena's ADDRESS, and the checker keeps that allocator, so an arena held
/// by value would leave the checker pointing into `init`'s dead stack frame
/// once the harness is returned. With one harness per test that stale slot
/// happened to survive until `deinit`; a second harness in the same test
/// overwrote it and `deinit` segfaulted inside `ArenaAllocator.free`.
pub const LiveHarness = struct {
    arena: *std.heap.ArenaAllocator,
    checker: Checker,
    module: ast.Module,

    pub fn init(src: []const u8) !LiveHarness {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        errdefer std.testing.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const gpa = arena.allocator();
        var lex = lexer.Lexer.init(src, "t.cell");
        const tokens = try lex.tokenizeAll(gpa);
        var p = parser.Parser.init(gpa, tokens.items, "t.cell");
        const module = try p.parseModule();
        var checker: Checker = .init(gpa, "t.cell", src);
        errdefer checker.deinit();
        try checker.checkModule(&module);
        if (checker.diagnostics.hasErrors()) {
            var buf: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try checker.diagnostics.printAll(&w);
            std.debug.print("\nLiveHarness source was rejected:\n{s}\n", .{w.buffered()});
            return error.TestUnexpectedRejection;
        }
        return .{ .arena = arena, .checker = checker, .module = module };
    }

    pub fn deinit(self: *LiveHarness) void {
        self.checker.deinit();
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }

    pub fn binding(self: *const LiveHarness, name: []const u8) u32 {
        var id: u32 = 0;
        while (id < self.checker.next_binding_id) : (id += 1) {
            if (self.checker.bindingName(id)) |n| {
                if (std.mem.eql(u8, n, name)) return id;
            }
        }
        std.debug.print("\nno binding named {s}\n", .{name});
        unreachable;
    }

    pub fn fnBody(self: *const LiveHarness, name: []const u8) []const ast.Stmt {
        for (self.module.items) |*item| {
            switch (item.kind) {
                .fn_def => |f| {
                    if (std.mem.eql(u8, f.name, name)) return f.body.?;
                },
                else => {},
            }
        }
        std.debug.print("\nno function named {s}\n", .{name});
        unreachable;
    }

    pub fn fnBodyKey(self: *const LiveHarness, name: []const u8) usize {
        const body = self.fnBody(name);
        return @intFromPtr(body.ptr);
    }

    pub fn firstWhile(self: *const LiveHarness, name: []const u8) usize {
        return firstWhileIn(self.fnBody(name)) orelse {
            std.debug.print("\nno while in {s}\n", .{name});
            unreachable;
        };
    }

    pub fn firstJump(self: *const LiveHarness, name: []const u8) usize {
        return firstJumpIn(self.fnBody(name)) orelse {
            std.debug.print("\nno jump in {s}\n", .{name});
            unreachable;
        };
    }

    pub fn firstIf(self: *const LiveHarness, name: []const u8) *const ast.Expr {
        return firstIfIn(self.fnBody(name)) orelse {
            std.debug.print("\nno if in {s}\n", .{name});
            unreachable;
        };
    }
};

pub fn firstWhileIn(stmts: []const ast.Stmt) ?usize {
    for (stmts) |*s| {
        switch (s.kind) {
            .while_stmt => |w| {
                if (firstWhileIn(w.body)) |inner| return inner;
                return @intFromPtr(s);
            },
            .expr => |e| if (firstWhileInExpr(&e)) |k| return k,
            else => {},
        }
    }
    return null;
}

pub fn firstWhileInExpr(e: *const ast.Expr) ?usize {
    return switch (e.kind) {
        .block => |stmts| firstWhileIn(stmts),
        .if_expr => |i| firstWhileInExpr(i.then_body) orelse if (i.else_body) |eb| firstWhileInExpr(eb) else null,
        else => null,
    };
}

pub fn firstIfIn(stmts: []const ast.Stmt) ?*const ast.Expr {
    for (stmts) |*s| {
        switch (s.kind) {
            .expr => if (s.kind.expr.kind == .if_expr) return &s.kind.expr,
            .while_stmt => if (firstIfIn(s.kind.while_stmt.body)) |inner| return inner,
            else => {},
        }
    }
    return null;
}

pub fn firstJumpIn(stmts: []const ast.Stmt) ?usize {
    for (stmts) |*s| {
        switch (s.kind) {
            .break_stmt, .continue_stmt => return @intFromPtr(s),
            .while_stmt => |w| if (firstJumpIn(w.body)) |k| return k,
            .expr => |e| if (firstJumpInExpr(&e)) |k| return k,
            else => {},
        }
    }
    return null;
}

pub fn firstReturnIn(stmts: []const ast.Stmt) ?usize {
    for (stmts) |*s| {
        switch (s.kind) {
            .return_stmt => return @intFromPtr(s),
            .while_stmt => |w| if (firstReturnIn(w.body)) |k| return k,
            .expr => |e| if (firstReturnInExpr(&e)) |k| return k,
            else => {},
        }
    }
    return null;
}

pub fn firstReturnInExpr(e: *const ast.Expr) ?usize {
    return switch (e.kind) {
        .block => |stmts| firstReturnIn(stmts),
        .if_expr => |i| firstReturnInExpr(i.then_body) orelse if (i.else_body) |eb| firstReturnInExpr(eb) else null,
        else => null,
    };
}

pub fn firstJumpInExpr(e: *const ast.Expr) ?usize {
    return switch (e.kind) {
        .block => |stmts| firstJumpIn(stmts),
        .if_expr => |i| firstJumpInExpr(i.then_body) orelse if (i.else_body) |eb| firstJumpInExpr(eb) else null,
        else => null,
    };
}

pub fn expectDiagnostics(src: []const u8, expected: []const u8) !void {
    var h: Harness = .init();
    defer h.deinit();
    var buf: [4096]u8 = undefined;
    const out = try h.run(src, &buf, false);
    try std.testing.expectEqualStrings(expected, out);
}

pub fn expectAccepted(src: []const u8) !void {
    try expectDiagnostics(src, "");
}

/// `src` draws an error whose text contains `needle`.
pub fn expectRejectedWith(src: []const u8, needle: []const u8) !void {
    var h: Harness = .init();
    defer h.deinit();
    var buf: [4096]u8 = undefined;
    const out = try h.run(src, &buf, false);
    if (std.mem.indexOf(u8, out, needle) == null) {
        std.debug.print("\nexpected an error containing:\n{s}\ngot:\n{s}\n", .{ needle, out });
        return error.TestExpectedRejection;
    }
}

/// A `Buffer` with one `owned` field and one `copy` field, plus the four
/// helpers the rules' examples call. Kept on one line each so a test's own
/// statements start at a predictable line.
pub const prelude =
    \\pub struct Buffer {
    \\    owned data: [Byte]
    \\    copy len: Int
    \\}
    \\pub fn take(owned b: Buffer) { }
    \\pub fn read(shared b: Buffer) -> Int { return b.len }
    \\pub fn grow(exclusive b: Buffer, shared extra: Int) { }
    \\pub fn use_it(shared b: Buffer) -> Int { return b.len }
    \\
;
// The prelude occupies lines 1 through 8, so a test body's first line is 9.
pub const prelude_lines = 8;
