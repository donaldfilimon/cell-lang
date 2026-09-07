//! Borrow and move checker for Cell.
//!
//! Implements `docs/OWNERSHIP.md` rules R1, R2, R3, R3a, R4, R5, R6, R8, R14
//! and the part of R15 the AST can still see. It is deliberately independent of
//! `typecheck.zig`: it carries its own scope stack, its own signature table,
//! and imports only `ast.zig` and `diag.zig`, so it neither depends on nor
//! disturbs the type checker.
//!
//! Two design points worth knowing before reading the code.
//!
//! **Places, not names.** A place is a binding identity plus a dotted field
//! path (`buf`, `buf.len`). Bindings get a monotonic id, so two sibling blocks
//! that each declare `let owned a` are two different places and a move in the
//! first cannot kill the second. Two places conflict when either path is a
//! segment-wise prefix of the other, which is the whole of R6.
//!
//! **Lexical loans with two narrowing exceptions** (OWNERSHIP.md 0.3). A loan
//! bound to a name lives to the end of its block and is kept in `block_loans`,
//! truncated when the scope pops. Every other loan is a temporary in
//! `temp_loans`, truncated when the region that created it closes: one region
//! per statement, and one region around a whole `if` so a borrow taken in the
//! condition survives the branches and dies with the `if`.
//!
//! Where a lexical rejection would be accepted under non-lexical lifetimes the
//! checker says so in a note, but only when it can prove the holding binding is
//! never mentioned again. An unprovable case gets no note, because a wrong
//! "this would be fine under NLL" is worse than a missing one.

const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diag.zig");

const Span = ast.Span;
const Ownership = ast.Ownership;

pub const Error = error{OutOfMemory};

/// Returned by `check` when the module has at least one borrow error.
pub const BorrowError = error{BorrowError};

/// How a loan reads the place it points at.
pub const LoanKind = enum {
    shared,
    exclusive,

    pub fn word(self: LoanKind) []const u8 {
        return switch (self) {
            .shared => "shared",
            .exclusive => "exclusive",
        };
    }
};

/// A binding introduced by a parameter, a `let`/`var`, or a match arm pattern.
const Binding = struct {
    id: u32,
    name: []const u8,
    /// The declared annotation. `owned` when none was written (R1).
    ownership: Ownership,
    /// Whether the binding itself may be reassigned (R14).
    mutable: bool,
    /// Struct type name, when it could be resolved from the declaration or the
    /// initializing struct literal. Needed to read field annotations.
    struct_name: ?[]const u8,
    decl_span: Span,
};

/// A place: a binding plus a field path relative to it.
const Place = struct {
    binding: u32,
    /// `""` for the binding itself, `"len"` for `buf.len`.
    path: []const u8,
    /// `buf` or `buf.len`, for diagnostics.
    display: []const u8,
    span: Span,
};

/// A place whose value has been moved out (R2).
const Dead = struct {
    binding: u32,
    path: []const u8,
    display: []const u8,
    /// Where the move happened.
    span: Span,
    /// The `note:` text that explains the move.
    note: []const u8,
};

const Loan = struct {
    binding: u32,
    path: []const u8,
    display: []const u8,
    kind: LoanKind,
    span: Span,
    /// The `let` binding holding this loan, for a named (block-scoped) loan.
    holder: ?[]const u8 = null,
    /// Index into `open_blocks` of the block this loan was created in. Only
    /// meaningful for block-scoped loans.
    block_index: usize = 0,
    /// True for a loan that lasts to the end of its block, false for one that
    /// dies with its statement or its `if`.
    lexical: bool = false,
};

/// A block currently being walked, with the index of the statement in it that
/// is being checked. Used to decide whether a named loan is ever read again.
const OpenBlock = struct {
    stmts: []const ast.Stmt,
    index: usize,
};

pub const Checker = struct {
    allocator: std.mem.Allocator,
    /// Owns every formatted diagnostic message, so messages outlive the walk
    /// but die with the checker.
    arena: std.heap.ArenaAllocator,
    diagnostics: diag.Bag,

    fns: std.StringHashMapUnmanaged(ast.FnDef) = .empty,
    structs: std.StringHashMapUnmanaged(ast.StructDef) = .empty,

    bindings: std.ArrayList(Binding) = .empty,
    /// Marks into `bindings` and `block_loans`, one per open scope.
    scopes: std.ArrayList(ScopeMark) = .empty,
    dead: std.ArrayList(Dead) = .empty,
    block_loans: std.ArrayList(Loan) = .empty,
    temp_loans: std.ArrayList(Loan) = .empty,
    open_blocks: std.ArrayList(OpenBlock) = .empty,
    next_binding_id: u32 = 0,
    /// Set while checking a function whose return type is a `shared` or
    /// `exclusive` borrow (R8). Cell has no lifetime parameters, so such a
    /// return is always an error. Bodyless declarations report at the
    /// function; a body reports at each returned expression (the use) and
    /// the flag stops that return from also being a move-out-of-borrow.
    fn_return_borrow: ?LoanKind = null,

    const ScopeMark = struct {
        bindings: usize,
        block_loans: usize,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        source: ?[]const u8,
    ) Checker {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .diagnostics = .init(path, source),
        };
    }

    pub fn deinit(self: *Checker) void {
        self.fns.deinit(self.allocator);
        self.structs.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.dead.deinit(self.allocator);
        self.block_loans.deinit(self.allocator);
        self.temp_loans.deinit(self.allocator);
        self.open_blocks.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const Checker) bool {
        return self.diagnostics.hasErrors();
    }

    fn msg(self: *Checker, comptime fmt: []const u8, args: anytype) Error![]const u8 {
        return try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
    }

    // ── module walk ─────────────────────────────────────────────────────

    /// Check every function body in `module`, filling `diagnostics`.
    pub fn checkModule(self: *Checker, module: *const ast.Module) Error!void {
        self.diagnostics.path = module.path;
        // Signatures first: a call may precede its callee's definition, and
        // R15 and R1 both need the parameter annotations.
        for (module.items) |*item| {
            switch (item.kind) {
                .fn_def => |f| try self.fns.put(self.allocator, f.name, f),
                .struct_def => |s| try self.structs.put(self.allocator, s.name, s),
                else => {},
            }
        }
        for (module.items) |*item| {
            switch (item.kind) {
                .fn_def => |*f| try self.checkFn(item.span, f),
                .struct_def => |s| try self.checkStructFields(item.span, s),
                else => {},
            }
        }
    }

    fn checkFn(self: *Checker, span: Span, f: *const ast.FnDef) Error!void {
        self.fn_return_borrow = null;
        if (f.return_type) |*rt| {
            if (typeIsBorrow(rt)) |kind| {
                self.fn_return_borrow = kind;
                // A bodyless `-> shared T` has no return expression to point
                // at, so the function item is the use site. A body reports at
                // each `return` instead (see checkStmt).
                if (f.body == null) try self.reportEscapingReturn(span, kind);
            }
        }
        const body = f.body orelse return;

        // A fresh scope per function. This is what keeps a parameter of one
        // function from leaking into the next (OWNERSHIP.md 0.4), without
        // depending on typecheck.zig's symbol table.
        try self.pushScope();
        defer self.popScope();
        // Each function starts from a clean move and loan state.
        self.dead.clearRetainingCapacity();

        for (f.params) |p| {
            _ = try self.declare(.{
                .id = 0,
                .name = p.name,
                .ownership = p.ownership,
                // R14 defect 3: a parameter is writable exactly when it owns
                // its value or holds an exclusive borrow. `arc` is immutable
                // by R9, `shared` by definition, `copy` because a duplicate
                // parameter is not a `var`.
                .mutable = p.ownership == .owned or p.ownership == .exclusive,
                .struct_name = typeStructName(&p.ty),
                .decl_span = .none,
            });
        }
        try self.checkBlockStmts(body);
    }

    // ── scopes ──────────────────────────────────────────────────────────

    fn pushScope(self: *Checker) Error!void {
        try self.scopes.append(self.allocator, .{
            .bindings = self.bindings.items.len,
            .block_loans = self.block_loans.items.len,
        });
    }

    fn popScope(self: *Checker) void {
        const mark = self.scopes.pop() orelse return;
        self.bindings.shrinkRetainingCapacity(mark.bindings);
        // R0.3: a named loan ends with the block that created it.
        self.block_loans.shrinkRetainingCapacity(mark.block_loans);
    }

    fn declare(self: *Checker, proto: Binding) Error!u32 {
        var b = proto;
        b.id = self.next_binding_id;
        self.next_binding_id += 1;
        try self.bindings.append(self.allocator, b);
        return b.id;
    }

    /// The innermost visible binding named `name`, so shadowing works.
    fn lookup(self: *const Checker, name: []const u8) ?*const Binding {
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.bindings.items[i].name, name)) {
                return &self.bindings.items[i];
            }
        }
        return null;
    }

    fn bindingById(self: *const Checker, id: u32) ?*const Binding {
        for (self.bindings.items) |*b| {
            if (b.id == id) return b;
        }
        return null;
    }

    /// Walk `stmts` as a block: one scope, one entry on the open-block stack.
    fn checkBlockStmts(self: *Checker, stmts: []const ast.Stmt) Error!void {
        try self.pushScope();
        defer self.popScope();
        try self.open_blocks.append(self.allocator, .{ .stmts = stmts, .index = 0 });
        defer _ = self.open_blocks.pop();
        for (stmts, 0..) |*s, i| {
            self.open_blocks.items[self.open_blocks.items.len - 1].index = i;
            try self.checkStmt(s);
        }
    }

    // ── statements ──────────────────────────────────────────────────────

    fn checkStmt(self: *Checker, stmt: *const ast.Stmt) Error!void {
        // R0.3 exception 1: every loan created inside a statement and not
        // bound to a name ends when the statement completes.
        const region = self.temp_loans.items.len;
        defer self.temp_loans.shrinkRetainingCapacity(region);

        switch (stmt.kind) {
            .let => |*l| try self.checkLet(l, stmt.span),
            .expr => |*e| try self.checkExpr(e),
            .return_stmt => |*opt| {
                if (self.fn_return_borrow) |kind| {
                    // R8 lands at the returned expression, which is the use.
                    // Do not also move the place: that would be a second
                    // diagnostic for the same escape.
                    if (opt.*) |*e| {
                        try self.reportEscapingReturn(e.span, kind);
                        if ((try self.placeOf(e)) == null) try self.checkExpr(e);
                    } else {
                        try self.reportEscapingReturn(stmt.span, kind);
                    }
                    return;
                }
                if (opt.*) |*e| {
                    if (try self.placeOf(e)) |place| {
                        const note = try self.msg("'{s}' was moved here by returning it", .{place.display});
                        try self.movePlace(place, note);
                    } else {
                        try self.checkExpr(e);
                    }
                }
            },
            .assign => |*a| try self.checkAssign(a),
        }
    }

    fn checkLet(self: *Checker, l: *const @FieldType(ast.Stmt.Kind, "let"), span: Span) Error!void {
        var struct_name: ?[]const u8 = null;
        if (l.ty) |*t| struct_name = typeStructName(t);

        if (l.value) |*v| {
            if (struct_name == null) {
                if (v.kind == .struct_lit) struct_name = v.kind.struct_lit.name;
            }
            try self.checkLetInit(l, v);
        }

        _ = try self.declare(.{
            .id = 0,
            .name = l.name,
            .ownership = l.ownership,
            .mutable = l.mutable,
            .struct_name = struct_name,
            .decl_span = span,
        });
    }

    /// The initializer of a `let`. Three shapes matter:
    ///
    /// * `&x` / `&mut x`, or a bare place under a `shared`/`exclusive`
    ///   annotation, creates a **named** loan that lives to the end of the
    ///   block. This is the loan provenance R5 asks for.
    /// * a bare place under an `owned` annotation is a move (R2).
    /// * anything else is an ordinary expression, and any loan inside it is a
    ///   temporary that dies with the statement.
    fn checkLetInit(
        self: *Checker,
        l: *const @FieldType(ast.Stmt.Kind, "let"),
        v: *const ast.Expr,
    ) Error!void {
        if (refKind(v)) |r| {
            if (try self.placeOf(r.operand)) |place| {
                try self.createLoan(place, r.kind, true, l.name);
                return;
            }
        }
        if (l.ownership == .shared or l.ownership == .exclusive) {
            if (try self.placeOf(v)) |place| {
                const kind: LoanKind = if (l.ownership == .exclusive) .exclusive else .shared;
                try self.createLoan(place, kind, true, l.name);
                return;
            }
        }
        if (l.ownership == .owned) {
            if (try self.placeOf(v)) |place| {
                const note = try self.msg(
                    "'{s}' was moved here by binding it to '{s}'",
                    .{ place.display, l.name },
                );
                try self.movePlace(place, note);
                return;
            }
        }
        // `copy` and `arc` bindings duplicate or retain rather than move
        // (R12, R10), so a bare place initializer is only read.
        try self.checkExpr(v);
    }

    fn checkAssign(self: *Checker, a: *const @FieldType(ast.Stmt.Kind, "assign")) Error!void {
        const target = try self.placeOf(&a.target);
        if (target == null) {
            try self.checkExpr(&a.target);
            try self.checkExpr(&a.value);
            return;
        }
        const place = target.?;
        const b = self.bindingById(place.binding).?;

        // R14. A write through a field path of an `exclusive` binding mutates
        // the referent, which the borrow already grants, so only a write to
        // the binding itself needs the binding to be mutable.
        const writable = if (place.path.len > 0 and b.ownership == .exclusive)
            true
        else
            b.mutable;
        if (!writable) {
            try self.diagnostics.err(
                self.allocator,
                place.span,
                try self.msg("cannot assign to immutable binding '{s}'", .{b.name}),
            );
            if (b.decl_span.line != 0) {
                try self.diagnostics.note(
                    self.allocator,
                    b.decl_span,
                    try self.msg("'{s}' is declared immutable here", .{b.name}),
                );
            }
            // R3a: an immutable assignment is an error, not a revival.
            try self.checkExpr(&a.value);
            return;
        }

        // Writing into a place whose owner was moved out is a use after move,
        // and is not the revival of R3a: only the moved place itself, or a
        // place containing it, is revived.
        if (self.deadStrictPrefixOf(place)) |d| {
            try self.reportUseAfterMove(d, place.span);
            try self.checkExpr(&a.value);
            return;
        }

        // R5 applied to a write. The spec fixes the wording for reads only;
        // a write is strictly stronger than a read, so an outstanding loan of
        // either kind blocks it.
        if (self.findConflictingLoan(place, .exclusive)) |loan| {
            try self.diagnostics.err(
                self.allocator,
                place.span,
                try self.msg(
                    "cannot assign to '{s}' while it is borrowed as {s}",
                    .{ place.display, loan.kind.word() },
                ),
            );
            try self.noteLoanScope(loan);
            try self.checkExpr(&a.value);
            return;
        }

        if (try self.placeOf(&a.value)) |src| {
            const note = try self.msg(
                "'{s}' was moved here by assigning it to '{s}'",
                .{ src.display, place.display },
            );
            try self.movePlace(src, note);
        } else {
            try self.checkExpr(&a.value);
        }

        // R3a: the target is live again.
        self.revive(place);
    }

    // ── expressions ─────────────────────────────────────────────────────

    fn checkExpr(self: *Checker, e: *const ast.Expr) Error!void {
        switch (e.kind) {
            .int, .float, .string, .bool => {},
            .ident, .field => {
                if (try self.placeOf(e)) |place| try self.readPlace(place);
            },
            .call => |*c| try self.checkCall(c, e.span),
            .binary => |*b| {
                try self.checkExpr(b.left);
                try self.checkExpr(b.right);
            },
            .unary => |*u| {
                if (u.op == .ref_shared or u.op == .ref_exclusive) {
                    const kind: LoanKind = if (u.op == .ref_exclusive) .exclusive else .shared;
                    if (try self.placeOf(u.operand)) |place| {
                        try self.createLoan(place, kind, false, null);
                        return;
                    }
                }
                try self.checkExpr(u.operand);
            },
            // R2's move list does not include struct or list literals, so
            // their elements are read rather than moved. See the report.
            .struct_lit => |*sl| {
                for (sl.fields) |*f| try self.checkExpr(&f.value);
            },
            .list_lit => |items| {
                for (items) |*item| try self.checkExpr(item);
            },
            .block => |stmts| try self.checkBlockStmts(stmts),
            .if_expr => |*i| try self.checkIf(i),
            .match_expr => |*m| try self.checkMatch(m),
        }
    }

    /// R0.3 exception 2: a borrow created in the condition ends when the `if`
    /// finishes, so the condition's temporary region wraps the branches too.
    ///
    /// Branches are merged conservatively: a place moved in any branch is dead
    /// afterwards, and a place revived in only one branch stays dead. That is
    /// the sound answer without a control-flow graph.
    fn checkIf(self: *Checker, i: *const @FieldType(ast.Expr.Kind, "if_expr")) Error!void {
        const region = self.temp_loans.items.len;
        defer self.temp_loans.shrinkRetainingCapacity(region);

        try self.checkExpr(i.cond);

        var entry = try self.dead.clone(self.allocator);
        defer entry.deinit(self.allocator);

        try self.checkExpr(i.then_body);
        var then_dead = try self.dead.clone(self.allocator);
        defer then_dead.deinit(self.allocator);

        self.dead.clearRetainingCapacity();
        try self.dead.appendSlice(self.allocator, entry.items);
        if (i.else_body) |else_body| {
            try self.checkExpr(else_body);
        }
        try self.unionDead(then_dead.items);
    }

    fn checkMatch(self: *Checker, m: *const @FieldType(ast.Expr.Kind, "match_expr")) Error!void {
        const region = self.temp_loans.items.len;
        defer self.temp_loans.shrinkRetainingCapacity(region);

        // R7 (a pattern binding inherits the scrutinee's ownership) is not
        // implemented, so the scrutinee is read, not moved.
        try self.checkExpr(m.scrutinee);

        var entry = try self.dead.clone(self.allocator);
        defer entry.deinit(self.allocator);
        var merged = try self.dead.clone(self.allocator);
        defer merged.deinit(self.allocator);

        for (m.arms) |arm| {
            self.dead.clearRetainingCapacity();
            try self.dead.appendSlice(self.allocator, entry.items);

            try self.pushScope();
            // Arm bindings are declared so they shadow rather than resolve to
            // an outer binding of the same name.
            if (arm.pattern.kind == .binding) {
                _ = try self.declare(.{
                    .id = 0,
                    .name = arm.pattern.kind.binding,
                    .ownership = .owned,
                    .mutable = false,
                    .struct_name = null,
                    .decl_span = arm.pattern.span,
                });
            }
            try self.checkExpr(arm.body);
            self.popScope();

            for (self.dead.items) |d| {
                if (!containsDead(merged.items, d)) {
                    try merged.append(self.allocator, d);
                }
            }
        }

        self.dead.clearRetainingCapacity();
        try self.dead.appendSlice(self.allocator, merged.items);
    }

    fn unionDead(self: *Checker, other: []const Dead) Error!void {
        for (other) |d| {
            if (!containsDead(self.dead.items, d)) {
                try self.dead.append(self.allocator, d);
            }
        }
    }

    // ── calls: R1, R2, R3, R4, R5, R15 ──────────────────────────────────

    fn checkCall(
        self: *Checker,
        c: *const @FieldType(ast.Expr.Kind, "call"),
        span: Span,
    ) Error!void {
        _ = span;
        const callee_name: ?[]const u8 = switch (c.callee.kind) {
            .ident => |n| n,
            else => null,
        };
        const sig: ?ast.FnDef = if (callee_name) |n| self.fns.get(n) else null;
        if (callee_name == null) try self.checkExpr(c.callee);

        for (c.args, 0..) |*arg, idx| {
            const param: ?ast.Param = if (sig) |s|
                (if (idx < s.params.len) s.params[idx] else null)
            else
                null;

            // R15. The parser keeps `&x` and `&mut x` but drops the keyword
            // spelling, so only the sigil form can be checked.
            var explicit: ?Ownership = null;
            var operand: *const ast.Expr = arg;
            if (refKind(arg)) |r| {
                explicit = if (r.kind == .exclusive) .exclusive else .shared;
                operand = r.operand;
            }
            if (explicit) |ex| {
                if (param) |p| {
                    if (ex != p.ownership) {
                        try self.diagnostics.err(
                            self.allocator,
                            arg.span,
                            try self.msg(
                                "'{s}' expects parameter '{s}' as '{s}', but the argument is passed as '{s}'",
                                .{ callee_name.?, p.name, @tagName(p.ownership), @tagName(ex) },
                            ),
                        );
                        continue;
                    }
                }
            }

            // R1: an omitted annotation takes the parameter's mode, so a bare
            // argument to an `owned` parameter moves.
            const mode: ?Ownership = explicit orelse if (param) |p| p.ownership else null;

            const place = try self.placeOf(operand);
            if (place == null) {
                try self.checkExpr(operand);
                continue;
            }
            const m = mode orelse {
                // Unknown callee: no signature, so nothing can be inferred.
                // Treat the argument as a read rather than invent a move.
                try self.readPlace(place.?);
                continue;
            };
            switch (m) {
                .owned => {
                    const note = if (callee_name) |n|
                        try self.msg(
                            "'{s}' was moved here by the call to '{s}'",
                            .{ place.?.display, n },
                        )
                    else
                        try self.msg("'{s}' was moved here by the call", .{place.?.display});
                    try self.movePlace(place.?, note);
                },
                .shared, .exclusive => {
                    const kind: LoanKind = if (m == .exclusive) .exclusive else .shared;
                    try self.createLoan(place.?, kind, false, null);
                },
                // R10 and R12 are not implemented; an `arc` or `copy`
                // argument neither moves nor borrows.
                .arc, .copy => try self.readPlace(place.?),
            }
        }
    }

    // ── the four primitive operations on a place ────────────────────────

    /// R2 and R5: reading a place that is dead, or that is exclusively
    /// borrowed, is an error.
    fn readPlace(self: *Checker, place: Place) Error!void {
        if (self.findDead(place)) |d| {
            try self.reportUseAfterMove(d, place.span);
            return;
        }
        if (self.findConflictingLoan(place, .shared)) |loan| {
            if (loan.kind == .exclusive) {
                try self.diagnostics.err(
                    self.allocator,
                    place.span,
                    try self.msg("cannot use '{s}' while it is exclusively borrowed", .{place.display}),
                );
                try self.noteLoanScope(loan);
                try self.maybeNoteNll(loan, place.span);
            }
        }
    }

    /// R2, R3 and R6.
    fn movePlace(self: *Checker, place: Place, note: []const u8) Error!void {
        const b = self.bindingById(place.binding).?;

        // R12 and R10: a `copy` place duplicates and an `arc` place retains,
        // so neither is made dead by a move position.
        if (self.isDuplicable(b, place.path)) {
            try self.readPlace(place);
            return;
        }

        if (self.findDead(place)) |d| {
            try self.reportUseAfterMove(d, place.span);
            return;
        }

        // R3: a borrow does not own its value, and neither does a field of one.
        if (b.ownership == .shared or b.ownership == .exclusive) {
            try self.diagnostics.err(
                self.allocator,
                place.span,
                try self.msg(
                    "cannot move out of '{s}': it is {s} borrow, not an owner",
                    .{ place.display, if (b.ownership == .exclusive) "an exclusive" else "a shared" },
                ),
            );
            return;
        }

        // R6: a live loan anywhere on the path blocks the move.
        if (self.findConflictingLoan(place, .exclusive)) |loan| {
            const message = if (loan.path.len > place.path.len)
                try self.msg(
                    "cannot move '{s}': its field '{s}' is borrowed",
                    .{ place.display, loan.display },
                )
            else
                try self.msg("cannot move '{s}' while it is borrowed", .{place.display});
            try self.diagnostics.err(self.allocator, place.span, message);
            try self.noteLoanScope(loan);
            try self.maybeNoteNll(loan, place.span);
            return;
        }

        try self.dead.append(self.allocator, .{
            .binding = place.binding,
            .path = place.path,
            .display = place.display,
            .span = place.span,
            .note = note,
        });
    }

    /// R4, R5 and R6. `lexical` selects the loan's scope: true for a loan
    /// bound to a name, false for one that dies with its statement or `if`.
    fn createLoan(
        self: *Checker,
        place: Place,
        kind: LoanKind,
        lexical: bool,
        holder: ?[]const u8,
    ) Error!void {
        if (self.findDead(place)) |d| {
            try self.reportUseAfterMove(d, place.span);
            return;
        }

        if (self.findConflictingLoan(place, kind)) |loan| {
            // R4: two shared loans of the same place are fine, and the only
            // pair `findConflictingLoan` lets through.
            try self.diagnostics.err(
                self.allocator,
                place.span,
                try self.msg(
                    "cannot borrow '{s}' as {s}: it is already borrowed as {s}",
                    .{ place.display, kind.word(), loan.kind.word() },
                ),
            );
            try self.noteLoanScope(loan);
            try self.maybeNoteNll(loan, place.span);
            return;
        }

        const loan: Loan = .{
            .binding = place.binding,
            .path = place.path,
            .display = place.display,
            .kind = kind,
            .span = place.span,
            .holder = holder,
            .block_index = if (self.open_blocks.items.len == 0) 0 else self.open_blocks.items.len - 1,
            .lexical = lexical,
        };
        if (lexical) {
            try self.block_loans.append(self.allocator, loan);
        } else {
            try self.temp_loans.append(self.allocator, loan);
        }
    }

    /// R3a: assigning to a place revives it and everything under it.
    fn revive(self: *Checker, place: Place) void {
        var i: usize = 0;
        while (i < self.dead.items.len) {
            const d = self.dead.items[i];
            if (d.binding == place.binding and pathPrefix(place.path, d.path)) {
                _ = self.dead.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    // ── queries ─────────────────────────────────────────────────────────

    /// The dead place overlapping `place`, in either direction: reading
    /// `buf.len` after `buf` moved is an error, and so is reading `buf` after
    /// `buf.data` moved.
    fn findDead(self: *const Checker, place: Place) ?Dead {
        for (self.dead.items) |d| {
            if (d.binding != place.binding) continue;
            if (pathPrefix(d.path, place.path) or pathPrefix(place.path, d.path)) return d;
        }
        return null;
    }

    /// A dead place that strictly contains `place`, used to tell a write into
    /// a moved-out value from the revival of R3a.
    fn deadStrictPrefixOf(self: *const Checker, place: Place) ?Dead {
        for (self.dead.items) |d| {
            if (d.binding != place.binding) continue;
            if (d.path.len < place.path.len and pathPrefix(d.path, place.path)) return d;
        }
        return null;
    }

    /// The first active loan that conflicts with taking `kind` on `place`.
    /// Shared against shared never conflicts (R4); everything else does.
    fn findConflictingLoan(self: *const Checker, place: Place, kind: LoanKind) ?Loan {
        for (self.block_loans.items) |loan| {
            if (loanConflicts(loan, place, kind)) return loan;
        }
        for (self.temp_loans.items) |loan| {
            if (loanConflicts(loan, place, kind)) return loan;
        }
        return null;
    }

    fn loanConflicts(loan: Loan, place: Place, kind: LoanKind) bool {
        if (loan.binding != place.binding) return false;
        // R6: disjoint field paths never conflict.
        if (!pathPrefix(loan.path, place.path) and !pathPrefix(place.path, loan.path)) return false;
        if (loan.kind == .shared and kind == .shared) return false;
        return true;
    }

    /// R12 and R10's exemptions, which R2 depends on: a `copy` place is
    /// duplicated and an `arc` place is retained, so neither dies.
    fn isDuplicable(self: *const Checker, b: *const Binding, path: []const u8) bool {
        const own = self.placeOwnership(b, path) orelse return false;
        return own == .copy or own == .arc;
    }

    /// The declared annotation of a place: the binding's own for an empty
    /// path, otherwise the last field's, resolved through the struct table.
    /// Null when it cannot be resolved, which is treated conservatively.
    fn placeOwnership(self: *const Checker, b: *const Binding, path: []const u8) ?Ownership {
        if (path.len == 0) return b.ownership;
        var current: ?[]const u8 = b.struct_name;
        var result: ?Ownership = null;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |segment| {
            const struct_name = current orelse return null;
            const def = self.structs.get(struct_name) orelse return null;
            const field = findField(def, segment) orelse return null;
            result = field.ownership;
            current = typeStructName(&field.ty);
        }
        return result;
    }

    // ── diagnostics helpers ─────────────────────────────────────────────

    fn reportEscapingReturn(self: *Checker, at: Span, kind: LoanKind) Error!void {
        try self.diagnostics.err(
            self.allocator,
            at,
            try self.msg(
                "cannot return {s} {s} borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call",
                .{ if (kind == .exclusive) "an" else "a", kind.word() },
            ),
        );
        try self.diagnostics.note(
            self.allocator,
            at,
            "return an 'owned' or 'arc' value instead",
        );
    }

    fn checkStructFields(self: *Checker, span: Span, s: ast.StructDef) Error!void {
        for (s.fields) |f| {
            const from_ann: ?LoanKind = switch (f.ownership) {
                .shared => .shared,
                .exclusive => .exclusive,
                else => null,
            };
            const kind = from_ann orelse typeIsBorrow(&f.ty);
            if (kind) |k| {
                try self.diagnostics.err(
                    self.allocator,
                    span,
                    try self.msg(
                        "cannot store a {s} borrow in field '{s}': Cell has no lifetime annotations, so the borrow cannot be proven to outlive the value",
                        .{ k.word(), f.name },
                    ),
                );
                try self.diagnostics.note(
                    self.allocator,
                    span,
                    "store an 'owned' or 'arc' value instead",
                );
            }
        }
    }

    fn reportUseAfterMove(self: *Checker, d: Dead, at: Span) Error!void {
        try self.diagnostics.err(
            self.allocator,
            at,
            try self.msg("use of '{s}' after it was moved", .{d.display}),
        );
        try self.diagnostics.note(self.allocator, d.span, d.note);
    }

    fn noteLoanScope(self: *Checker, loan: Loan) Error!void {
        const text = if (loan.lexical)
            try self.msg(
                "the {s} borrow starts here and lasts to the end of this block",
                .{loan.kind.word()},
            )
        else
            try self.msg(
                "the {s} borrow starts here and lasts until this statement completes",
                .{loan.kind.word()},
            );
        try self.diagnostics.note(self.allocator, loan.span, text);
    }

    /// OWNERSHIP.md 0.3 asks the checker to say when a rejection is its own
    /// conservatism. Only a named lexical loan can be the cause, and only when
    /// the holding binding is provably never mentioned again: an unprovable
    /// case gets no note.
    fn maybeNoteNll(self: *Checker, loan: Loan, at: Span) Error!void {
        if (!loan.lexical) return;
        const holder = loan.holder orelse return;
        if (self.nameUsedFrom(holder, loan.block_index)) return;
        try self.diagnostics.note(
            self.allocator,
            at,
            try self.msg(
                "this would be accepted under non-lexical lifetimes: '{s}' is never used again, but Cell ends a named borrow at the end of its block",
                .{holder},
            ),
        );
    }

    /// Whether `name` appears anywhere from the statement being checked to the
    /// end of the block that owns the loan. The statement currently being
    /// checked counts in full, and so does the statement containing an inner
    /// block, so the answer errs toward "used".
    fn nameUsedFrom(self: *const Checker, name: []const u8, from_block: usize) bool {
        if (self.open_blocks.items.len == 0) return true;
        var i = self.open_blocks.items.len;
        while (i > from_block) {
            i -= 1;
            if (i >= self.open_blocks.items.len) continue;
            const ob = self.open_blocks.items[i];
            for (ob.stmts[@min(ob.index, ob.stmts.len)..]) |*s| {
                if (stmtUsesName(s, name)) return true;
            }
        }
        return false;
    }

    // ── place construction ──────────────────────────────────────────────

    /// The place an expression denotes, or null when it denotes no place (a
    /// literal, a call result, an unknown identifier).
    fn placeOf(self: *Checker, e: *const ast.Expr) Error!?Place {
        var segments: std.ArrayList([]const u8) = .empty;
        defer segments.deinit(self.allocator);

        var cursor = e;
        while (true) {
            switch (cursor.kind) {
                .field => |f| {
                    try segments.append(self.allocator, f.name);
                    cursor = f.base;
                },
                .ident => |name| {
                    const b = self.lookup(name) orelse return null;
                    std.mem.reverse([]const u8, segments.items);
                    const gpa = self.arena.allocator();
                    const path = try std.mem.join(gpa, ".", segments.items);
                    const display = if (path.len == 0)
                        name
                    else
                        try std.fmt.allocPrint(gpa, "{s}.{s}", .{ name, path });
                    return .{
                        .binding = b.id,
                        .path = path,
                        .display = display,
                        .span = e.span,
                    };
                },
                else => return null,
            }
        }
    }
};

// ── free functions ──────────────────────────────────────────────────────

const Ref = struct { kind: LoanKind, operand: *const ast.Expr };

/// A `shared T` or `exclusive T` written in type position. `arc T` and
/// `owned T` are not borrows, so they are not R8.
fn typeIsBorrow(ty: *const ast.TypeExpr) ?LoanKind {
    return switch (ty.*) {
        .ref => |r| switch (r.ownership) {
            .shared => .shared,
            .exclusive => .exclusive,
            else => null,
        },
        else => null,
    };
}

/// `&x` and `&mut x`, the two call-site annotations the parser preserves.
fn refKind(e: *const ast.Expr) ?Ref {
    return switch (e.kind) {
        .unary => |u| switch (u.op) {
            .ref_shared => .{ .kind = .shared, .operand = u.operand },
            .ref_exclusive => .{ .kind = .exclusive, .operand = u.operand },
            else => null,
        },
        else => null,
    };
}

/// Whether `a` is a segment-wise prefix of, or equal to, `b`. The empty path
/// is a prefix of every path, so `buf` contains `buf.len` while `buf.le` does
/// not contain `buf.len`.
fn pathPrefix(a: []const u8, b: []const u8) bool {
    if (a.len == 0) return true;
    if (a.len > b.len) return false;
    if (!std.mem.eql(u8, a, b[0..a.len])) return false;
    return a.len == b.len or b[a.len] == '.';
}

fn typeStructName(ty: *const ast.TypeExpr) ?[]const u8 {
    return switch (ty.*) {
        .name => |n| n,
        .optional => |inner| typeStructName(inner),
        .ref => |r| typeStructName(r.inner),
        else => null,
    };
}

fn findField(def: ast.StructDef, name: []const u8) ?ast.Field {
    for (def.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

fn containsDead(list: []const Dead, d: Dead) bool {
    for (list) |x| {
        if (x.binding == d.binding and std.mem.eql(u8, x.path, d.path)) return true;
    }
    return false;
}

fn stmtUsesName(s: *const ast.Stmt, name: []const u8) bool {
    return switch (s.kind) {
        .let => |l| if (l.value) |v| exprUsesName(&v, name) else false,
        .expr => |e| exprUsesName(&e, name),
        .return_stmt => |opt| if (opt) |e| exprUsesName(&e, name) else false,
        .assign => |a| exprUsesName(&a.target, name) or exprUsesName(&a.value, name),
    };
}

fn exprUsesName(e: *const ast.Expr, name: []const u8) bool {
    return switch (e.kind) {
        .ident => |n| std.mem.eql(u8, n, name),
        .int, .float, .string, .bool => false,
        .call => |c| blk: {
            if (exprUsesName(c.callee, name)) break :blk true;
            for (c.args) |*a| {
                if (exprUsesName(a, name)) break :blk true;
            }
            break :blk false;
        },
        .binary => |b| exprUsesName(b.left, name) or exprUsesName(b.right, name),
        .unary => |u| exprUsesName(u.operand, name),
        .field => |f| exprUsesName(f.base, name),
        .struct_lit => |sl| blk: {
            for (sl.fields) |*f| {
                if (exprUsesName(&f.value, name)) break :blk true;
            }
            break :blk false;
        },
        .list_lit => |items| blk: {
            for (items) |*item| {
                if (exprUsesName(item, name)) break :blk true;
            }
            break :blk false;
        },
        .block => |stmts| blk: {
            for (stmts) |*s| {
                if (stmtUsesName(s, name)) break :blk true;
            }
            break :blk false;
        },
        .if_expr => |i| blk: {
            if (exprUsesName(i.cond, name)) break :blk true;
            if (exprUsesName(i.then_body, name)) break :blk true;
            if (i.else_body) |eb| {
                if (exprUsesName(eb, name)) break :blk true;
            }
            break :blk false;
        },
        .match_expr => |m| blk: {
            if (exprUsesName(m.scrutinee, name)) break :blk true;
            for (m.arms) |arm| {
                if (exprUsesName(arm.body, name)) break :blk true;
            }
            break :blk false;
        },
    };
}

/// Borrow-check `module`, rendering every diagnostic to `writer`. Deliberately
/// the same shape as `root.check`, so wiring it into the CLI is one call.
/// Returns `error.BorrowError` once the bag has been written, so a caller can
/// exit non-zero without re-inspecting it.
pub fn check(
    allocator: std.mem.Allocator,
    module: *const ast.Module,
    source: ?[]const u8,
    writer: *std.Io.Writer,
) !void {
    var checker: Checker = .init(allocator, module.path, source);
    defer checker.deinit();
    try checker.checkModule(module);
    try checker.diagnostics.printAll(writer);
    if (checker.hasErrors()) return error.BorrowError;
}

// ── tests ───────────────────────────────────────────────────────────────
//
// Every rule gets a rejection test that pins the diagnostic text, line and
// column, and an acceptance test for the shape the rule is meant to allow.
// Diagnostics are rendered without a source buffer so the assertion is one
// line per diagnostic; one test at the end supplies the source and pins the
// caret column instead.

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

const Harness = struct {
    arena: std.heap.ArenaAllocator,

    fn init() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
    }

    /// Parse and borrow-check `src`, rendering every diagnostic into `out`.
    fn run(self: *Harness, src: []const u8, out: []u8, with_source: bool) ![]u8 {
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

fn expectDiagnostics(src: []const u8, expected: []const u8) !void {
    var h: Harness = .init();
    defer h.deinit();
    var buf: [4096]u8 = undefined;
    const out = try h.run(src, &buf, false);
    try std.testing.expectEqualStrings(expected, out);
}

fn expectAccepted(src: []const u8) !void {
    try expectDiagnostics(src, "");
}

/// A `Buffer` with one `owned` field and one `copy` field, plus the four
/// helpers the rules' examples call. Kept on one line each so a test's own
/// statements start at a predictable line.
const prelude =
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
const prelude_lines = 8;

test "R1 and R2: a bare argument to an owned parameter moves, and the next use is an error" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\    take(buf)
        \\}
    ,
        \\t.cell:12:10: error: use of 'buf' after it was moved
        \\t.cell:11:10: note: 'buf' was moved here by the call to 'take'
        \\
    );
}

test "R2 accepts a move that is never followed by a use" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    read(buf)
        \\    take(buf)
        \\}
    );
}

test "R2: a move through a field kills the whole binding for later reads" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(buf.data)
        \\    read(buf)
        \\}
    ,
        \\t.cell:12:10: error: use of 'buf.data' after it was moved
        \\t.cell:11:10: note: 'buf.data' was moved here by the call to 'take'
        \\
    );
}

test "R2: a return moves the returned place" {
    try expectDiagnostics(prelude ++
        \\pub fn consume(owned b: Buffer) -> Buffer {
        \\    take(b)
        \\    return b
        \\}
    ,
        \\t.cell:11:12: error: use of 'b' after it was moved
        \\t.cell:10:10: note: 'b' was moved here by the call to 'take'
        \\
    );
}

test "R3: a whole exclusive borrow cannot be moved out of" {
    try expectDiagnostics(prelude ++
        \\pub fn steal(exclusive b: Buffer) -> Buffer {
        \\    return b
        \\}
    ,
        \\t.cell:10:12: error: cannot move out of 'b': it is an exclusive borrow, not an owner
        \\
    );
}

test "R3: an owned field of a shared borrow cannot be moved out of either" {
    try expectDiagnostics(prelude ++
        \\pub fn peek(shared b: Buffer) -> [Byte] {
        \\    return b.data
        \\}
    ,
        \\t.cell:10:12: error: cannot move out of 'b.data': it is a shared borrow, not an owner
        \\
    );
}

test "R3 accepts returning a copy field of a shared borrow" {
    // This is `read_only` from examples/ownership.cell. It is legal only
    // because `Buffer.len` is declared `copy`, which R12 exempts from R3.
    try expectAccepted(prelude ++
        \\pub fn read_only(shared b: Buffer) -> Int {
        \\    return b.len
        \\}
    );
}

test "R3a: assigning a fresh value revives a moved-from var" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\    buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\}
    );
}

test "R3a and R14: reviving a let binding is an immutable assignment, not a revival" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\    buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\}
    ,
        \\t.cell:12:5: error: cannot assign to immutable binding 'buf'
        \\t.cell:10:5: note: 'buf' is declared immutable here
        \\t.cell:13:10: error: use of 'buf' after it was moved
        \\t.cell:11:10: note: 'buf' was moved here by the call to 'take'
        \\
    );
}

test "R14: assignment to an immutable binding names it and points at the let" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let copy x = 1
        \\    x = 2
        \\}
    ,
        \\t.cell:11:5: error: cannot assign to immutable binding 'x'
        \\t.cell:10:5: note: 'x' is declared immutable here
        \\
    );
}

test "R14: a field write through an exclusive parameter is allowed" {
    // examples/ownership.cell's `grow` body. The old checker accepted this by
    // failing to look up the joined path at all; here the lookup succeeds and
    // the exclusive borrow is what grants the write.
    try expectAccepted(prelude ++
        \\pub fn widen(exclusive buf: Buffer, shared extra: Int) {
        \\    let copy new_len = buf.len + extra
        \\    buf.len = new_len
        \\}
    );
}

test "R14: a field write through an immutable let is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    buf.len = 3
        \\}
    ,
        \\t.cell:11:5: error: cannot assign to immutable binding 'buf'
        \\t.cell:10:5: note: 'buf' is declared immutable here
        \\
    );
}

test "R15: an ampersand argument whose mode differs from the parameter is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(&buf)
        \\}
    ,
        \\t.cell:11:10: error: 'take' expects parameter 'b' as 'owned', but the argument is passed as 'shared'
        \\
    );
}

test "R15: an ampersand argument matching the parameter is accepted" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    grow(&mut buf, 16)
        \\    read(&buf)
        \\}
    );
}

test "R4: any number of shared borrows may coexist" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let shared a = buf
        \\    let shared b = buf
        \\    read(&buf)
        \\}
    );
}

test "R5: a shared borrow while an exclusive one is live is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "R5: an exclusive borrow while a shared one is live is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let shared s = buf
        \\    grow(&mut buf, 1)
        \\    read_shared(s)
        \\}
    ,
        \\t.cell:12:15: error: cannot borrow 'buf' as exclusive: it is already borrowed as shared
        \\t.cell:11:20: note: the shared borrow starts here and lasts to the end of this block
        \\
    );
}

test "R5: reading the whole owner through a live exclusive borrow is rejected" {
    // R5's own example wording, naming the place as a whole. `println` has no
    // signature here, so the argument is a plain read rather than a move.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    println(buf)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:13: error: cannot use 'buf' while it is exclusively borrowed
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "R5: reading a field of the owner through a live exclusive borrow is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    let copy n = buf.len
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:18: error: cannot use 'buf.len' while it is exclusively borrowed
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "0.3: a rejection that NLL would accept says so, and one it would not stays silent" {
    // `e` is never mentioned again, so only the lexical scope keeps the loan
    // alive here. The R5 test above uses `e` afterwards and gets no such note.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf)
        \\}
    ,
        \\t.cell:12:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\t.cell:12:11: note: this would be accepted under non-lexical lifetimes: 'e' is never used again, but Cell ends a named borrow at the end of its block
        \\
    );
}

test "0.3 exception 1: a borrow created as a call argument ends with its statement" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    read(&buf)
        \\    grow(&mut buf, 16)
        \\    take(buf)
        \\}
    );
}

test "0.3 exception 2: a borrow created in a condition ends when the if finishes" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    if read(&buf) > 0 {
        \\        let copy z = 1
        \\    }
        \\    grow(&mut buf, 16)
        \\}
    );
}

test "R6: two disjoint field borrows coexist" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive d = &mut buf.data
        \\    let exclusive l = &mut buf.len
        \\    use_it(d)
        \\}
    );
}

test "R6: moving the owner while one of its fields is borrowed is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive d = &mut buf.data
        \\    take(buf)
        \\    use_it(d)
        \\}
    ,
        \\t.cell:12:10: error: cannot move 'buf': its field 'buf.data' is borrowed
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "R6: borrowing a field while the whole place is borrowed exclusively is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf.len)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:11: error: cannot borrow 'buf.len' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "places are keyed by binding identity, so sibling blocks do not share a move" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    {
        \\        let owned a = Buffer { data: [], len: 0 }
        \\        take(a)
        \\    }
        \\    {
        \\        let owned a = Buffer { data: [], len: 0 }
        \\        take(a)
        \\    }
        \\}
    );
}

test "shadowing in one block introduces a new place rather than reviving the old one" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned a = Buffer { data: [], len: 0 }
        \\    take(a)
        \\    let owned a = Buffer { data: [], len: 0 }
        \\    take(a)
        \\}
    );
}

test "a parameter of one function is not visible in the next" {
    // OWNERSHIP.md 0.4: typecheck.zig's flat symbol table leaks parameters
    // across functions. This checker's per-function scope does not.
    try expectAccepted(prelude ++
        \\pub fn first(owned b: Buffer) { take(b) }
        \\pub fn second() -> Int { return 1 }
    );
}

test "a move inside one branch of an if kills the place after the if" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    if 1 > 0 {
        \\        take(buf)
        \\    }
        \\    read(&buf)
        \\}
    ,
        \\t.cell:14:11: error: use of 'buf' after it was moved
        \\t.cell:12:14: note: 'buf' was moved here by the call to 'take'
        \\
    );
}

test "0.3 exception 2: a condition's borrow is still live inside the branches" {
    // The exception narrows a condition borrow to the end of the `if`, not to
    // the end of the condition, so the branch bodies are inside it. This is
    // the checker's conservatism showing: NLL would end the loan at the
    // comparison. There is no named holder to point at, so no NLL note.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    if read(&buf) > 0 {
        \\        take(buf)
        \\    }
        \\}
    ,
        \\t.cell:12:14: error: cannot move 'buf' while it is borrowed
        \\t.cell:11:14: note: the shared borrow starts here and lasts until this statement completes
        \\
    );
}

test "a revival inside one branch only is rejected conservatively" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\    if 1 > 0 {
        \\        buf = Buffer { data: [], len: 0 }
        \\    }
        \\    read(&buf)
        \\}
    ,
        \\t.cell:15:11: error: use of 'buf' after it was moved
        \\t.cell:11:10: note: 'buf' was moved here by the call to 'take'
        \\
    );
}

test "an unknown callee's argument is read rather than moved" {
    // Without a signature there is no parameter mode to infer from, so
    // inventing a move would reject every call to a builtin.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    println(buf)
        \\    take(buf)
        \\}
    );
}

test "examples/ownership.cell is accepted verbatim" {
    // Inlined because @embedFile cannot reach outside the module root and the
    // build's `examples` step only checks hello.cell. The text below is the
    // code of examples/ownership.cell with its comments removed.
    try expectAccepted(
        \\pub struct Buffer {
        \\    owned data: [Byte]
        \\    copy len: Int
        \\}
        \\pub fn grow(exclusive buf: Buffer, shared extra: Int) {
        \\    let copy new_len = buf.len + extra
        \\    buf.len = new_len
        \\}
        \\pub fn share_name(arc name: String) -> arc String {
        \\    return name
        \\}
        \\pub fn take(owned b: Buffer) {
        \\}
        \\pub fn read_only(shared b: Buffer) -> Int {
        \\    return b.len
        \\}
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    grow(exclusive buf, shared 16)
        \\    let copy n = read_only(shared buf)
        \\    take(owned buf)
        \\}
    );
}

test "with a source buffer the caret lands on the offending column" {
    var h: Harness = .init();
    defer h.deinit();
    const src =
        \\pub fn take(owned b: Buffer) { }
        \\pub fn main() {
        \\    let owned buf = 0
        \\    take(buf)
        \\    take(buf)
        \\}
    ;
    var buf: [1024]u8 = undefined;
    const out = try h.run(src, &buf, true);
    try std.testing.expectEqualStrings(
        \\t.cell:5:10: error: use of 'buf' after it was moved
        \\        take(buf)
        \\             ^~~
        \\t.cell:4:10: note: 'buf' was moved here by the call to 'take'
        \\        take(buf)
        \\             ^~~
        \\
    , out);
}

test "pathPrefix compares whole segments, not bytes" {
    try std.testing.expect(pathPrefix("", "len"));
    try std.testing.expect(pathPrefix("len", "len"));
    try std.testing.expect(pathPrefix("a", "a.b"));
    try std.testing.expect(!pathPrefix("a", "ab"));
    try std.testing.expect(!pathPrefix("a.b", "a"));
    try std.testing.expect(!pathPrefix("le", "len"));
}

test "R8: a function may not return a shared borrow" {
    try expectDiagnostics(prelude ++
        \\pub fn peek(shared b: Buffer) -> shared Buffer {
        \\    return b
        \\}
    ,
        \\t.cell:10:12: error: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:10:12: note: return an 'owned' or 'arc' value instead
        \\
    );
}

test "R8: a function may not return an exclusive borrow" {
    try expectDiagnostics(prelude ++
        \\pub fn leak(exclusive b: Buffer) -> exclusive Buffer {
        \\    return b
        \\}
    ,
        \\t.cell:10:12: error: cannot return an exclusive borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:10:12: note: return an 'owned' or 'arc' value instead
        \\
    );
}

test "R8: a bodyless shared-borrow return still errors at the function" {
    try expectDiagnostics(prelude ++
        \\pub fn peek(shared b: Buffer) -> shared Buffer;
    ,
        \\t.cell:9:1: error: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:9:1: note: return an 'owned' or 'arc' value instead
        \\
    );
}

test "R8: a struct field may not store a shared borrow" {
    try expectDiagnostics(
        \\pub struct View {
        \\    shared buf: Buffer
        \\}
    ,
        \\t.cell:1:1: error: cannot store a shared borrow in field 'buf': Cell has no lifetime annotations, so the borrow cannot be proven to outlive the value
        \\t.cell:1:1: note: store an 'owned' or 'arc' value instead
        \\
    );
}

test "R8 accepts returning an arc, which is not a borrow" {
    try expectAccepted(
        \\pub fn share_name(arc name: String) -> arc String {
        \\    return name
        \\}
    );
}

// The three cases below pin decisions OWNERSHIP.md leaves open for a binding
// that holds a borrow rather than a value. They are separated from the
// parameter cases above because a `let exclusive e = &mut buf` is a local, so
// it takes the `mutable` path in `checkAssign` that a parameter never reaches.

test "a write through a let-bound exclusive borrow is allowed" {
    // The borrow kind grants mutability of the referent, so the `let` being
    // immutable does not block a write through it.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    e.len = 1
        \\    use_it(e)
        \\}
    );
}

test "rebinding a let-bound exclusive borrow still needs var" {
    // Mutability of the referent is not mutability of the binding: pointing
    // `e` at something else is an ordinary R14 immutable assignment.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let owned other = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    e = &mut other
        \\}
    ,
        \\t.cell:13:5: error: cannot assign to immutable binding 'e'
        \\t.cell:12:5: note: 'e' is declared immutable here
        \\
    );
}

test "R3: a let-bound exclusive borrow cannot be moved into an owned parameter" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    take(e)
        \\}
    ,
        \\t.cell:12:10: error: cannot move out of 'e': it is an exclusive borrow, not an owner
        \\
    );
}
