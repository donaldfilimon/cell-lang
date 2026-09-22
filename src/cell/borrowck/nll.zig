//! Non-lexical lifetimes for named loans (OWNERSHIP.md 0.3): `loanStatusAt`
//! and its differential cross-check `oracleDead` live together in this file on
//! purpose, because the panic on their disagreement is the safety net.
//! Part of the borrow checker; the rules and their rationale are in the module header of `../borrowck.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const Span = ast.Span;
const bk_model = @import("model.zig");
const bk_root = @import("../borrowck.zig");
const Checker = bk_root.Checker;
const Error = bk_model.Error;
const LoanKind = bk_model.LoanKind;
const Place = bk_model.Place;
const Loan = bk_model.Loan;
const LoanStatus = bk_model.LoanStatus;
const OracleVerdict = bk_model.OracleVerdict;
const NameSet = bk_model.NameSet;
const ArgContext = bk_model.ArgContext;
const loanConflicts = Checker.loanConflicts;

pub fn noteLoanScope(self: *Checker, loan: Loan) Error!void {
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

/// Whether a named loan is still holding its referent at the statement
/// being checked, in the non-lexical sense. `dead` is the only status
/// that is not a rejection, so `dead` is the only one that needs proof;
/// `live` and `ineligible` are both safe answers and are never wrong in a
/// way that admits a program.
///
/// `dead` requires BOTH halves, and each is blind to what the other sees:
///
/// **(a) Forward,** `nameUsedFrom`: the holder is not mentioned from the
/// current statement to the end of the block that owns the loan. It counts
/// the current statement in FULL and recurses into a `while`'s condition
/// and body, so a back edge and a use nested inside the current statement
/// both read as "used". That full-statement counting is also what covers
/// every block nested inside the current statement, at every depth.
///
/// **(b) Window,** `windowPropagates`: between the loan's own `let` and
/// the current statement, at the loan's OWN block level, the holder is
/// mentioned only in positions that provably cannot propagate the
/// reference. This is the region (a) structurally cannot see, because (a)
/// starts at the current statement and only ever looks forward.
///
/// The two regions together are exhaustive over the loan's live range.
/// Anything at a block level nested inside the loan's block is reached
/// through (a)'s full-statement counting of the enclosing statement, so
/// only the loan's own block has a gap for (b) to fill.
pub fn loanStatusAt(self: *Checker, loan: Loan, at: Span) Error!LoanStatus {
    // A temporary loan dies with its statement or its `if`, so the lexical
    // model already ends it as early as NLL would.
    if (!loan.lexical) return .ineligible;
    const holder = loan.holder orelse return .ineligible;
    if (self.windowPropagates(loan, holder)) return .ineligible;
    if (self.nameUsedFrom(holder, loan.block_index)) return .live;
    // The differential oracle, armed in every safety-checked build, so
    // the whole test suite and the whole example corpus exercise it
    // without a single test being written for it. See `oracleDead`.
    if (std.debug.runtime_safety) {
        switch (try self.oracleDead(loan, holder, at)) {
            .dead, .not_applicable => {},
            .live => {
                std.debug.print(
                    "borrowck NLL differential oracle disagreed\n" ++
                        "  holder: '{s}'\n" ++
                        "  loan of '{s}' at line {d} column {d}\n" ++
                        "  loanStatusAt: dead (an ACCEPTANCE)\n" ++
                        "  oracleDead:   live\n" ++
                        "The precise predicate accepted a program the " ++
                        "conservative one holds live. Trust the oracle: " ++
                        "this is the enumeration failure the oracle exists " ++
                        "to catch, and shipping it is a use-after-free.\n",
                    .{ holder, loan.display, loan.span.line, loan.span.column },
                );
                @panic("borrowck: NLL differential oracle disagreed on a loan the checker called dead");
            },
        }
    }
    return .dead;
}

/// The first loan that conflicts with taking `kind` on `place` AND that
/// non-lexical lifetimes still consider live. A conflicting loan whose
/// status is `dead` is skipped, and that skip IS the acceptance: the
/// caller sees no conflict and reports nothing.
///
/// A dead loan is deliberately left in `block_loans` rather than removed.
/// Removing it would be equivalent but would make the acceptance depend on
/// the order conflicts happen to be checked in; leaving it makes every
/// site ask the same question independently. It is also monotone: `dead`
/// means the holder is mentioned nowhere from here on, so a loan that is
/// dead at this statement is dead at every later one in the same block.
pub fn findBlockingLoan(self: *Checker, place: Place, kind: LoanKind) Error!?Loan {
    for (self.block_loans.items) |loan| {
        if (!loanConflicts(loan, place, kind)) continue;
        if (try self.loanStatusAt(loan, place.span) == .dead) continue;
        return loan;
    }
    // A temporary is never `lexical`, so it is always `ineligible` and is
    // never skipped. It is routed through the same predicate anyway so
    // there is one place that decides what ends a loan early.
    for (self.temp_loans.items) |loan| {
        if (!loanConflicts(loan, place, kind)) continue;
        if (try self.loanStatusAt(loan, place.span) == .dead) continue;
        return loan;
    }
    return null;
}

/// THE DIFFERENTIAL ORACLE, and the primary defence for the acceptance
/// above. It answers the same question as `loanStatusAt` and is written
/// to be wrong only in the safe direction.
///
/// WHY A SECOND PREDICATE AT ALL. "The loan is dead here" is a claim over
/// all forward paths, and the way this compiler has repeatedly got such
/// claims wrong is by enumerating some forms of a construct and asserting
/// a property of all of them. `loanStatusAt` is exactly that shape: two
/// scans, each with a region it cannot see, meeting at a boundary. So it
/// is checked against a predicate built the opposite way, which enumerates
/// nothing about program structure:
///
/// 1. Take the transitive closure of names, starting from the holder, over
///    the WHOLE function body, ignoring scopes, blocks, statement order
///    and control flow entirely. A binding joins the closure when its
///    `let` initializer or `assign` value mentions a name already in it.
/// 2. The loan is dead only if no name in the closure occurs anywhere
///    after the loan's own span.
///
/// It greps a function rather than walking its regions, so it has no
/// region to forget. `let exclusive f = e` puts `f` in the closure and
/// `grow(exclusive f, ...)` then holds the loan live no matter where the
/// two statements sit relative to each other.
///
/// **DEVIATION FROM THE BRIEF, DELIBERATE AND REPORTED.** The brief
/// specifies step 2 as "no name in the closure appears anywhere after the
/// loan's `let`", full stop. That is exactly right for a predicate with an
/// empty whitelist, and it CONTRADICTS the call-argument whitelist: in
/// `let exclusive e = &mut buf; grow(exclusive e, shared 1); read(&buf)`
/// the holder does appear after the `let`, so the oracle would fire on the
/// very shape the whitelist exists to accept. Both halves of the oracle
/// therefore honor the same whitelist, in step 1 as well as step 2 (if the
/// closure ignored it, `let copy n = read(shared e)` would taint `n` and
/// any later use of `n` would fire). What stays independent is the
/// implementation: `oracleFindExpr` propagates an argument CONTEXT down a
/// single walk and reports occurrence offsets, where the checker peels an
/// argument and returns a boolean. A whitelist bug is shared; a region,
/// order or control-flow bug is not, and those are the failures that
/// actually happen here.
///
/// **KNOWN HOLE, and why it is a `not_applicable` rather than a fix.**
/// The oracle is blind to shadowing, which makes it more conservative
/// everywhere except one case: a loan in an inner block whose holder name
/// is ALSO an outer binding used after that block. The checker never scans
/// outside the loan's block, correctly, because the loan cannot outlive
/// it; the oracle scans the whole function and would see the outer use.
/// Rather than teach the oracle about scopes, which is the knowledge it
/// exists not to have, it declines to answer when the holder name is
/// declared more than once in the function.
///
/// **SECOND KNOWN HOLE, narrower and stated rather than hidden.** A
/// program that uses a name OUTSIDE the block that declared it is invalid
/// (typecheck reports an unknown identifier), but this oracle would see
/// that use, call the loan live, and panic before the diagnostic is
/// printed. It needs the name to be declared exactly once, used out of
/// scope, AND to hold a loan the checker reaches a conflict on. The
/// failure is a loud panic on an already-broken program, not a wrong
/// answer on a valid one, which is the direction to fail in.
/// **WHERE THE WHITELIST APPLIES, AND WHERE IT MUST NOT.** The whitelist
/// answers "can this mention have put the reference somewhere I cannot
/// see", not "is the holder still used here". Those are the same question
/// only BEHIND the conflict:
///
/// * Between the loan's `let` and `at`, a direct call argument is fine.
///   The loan was correctly live during that call, the call ended, and R8
///   says nothing kept the reference.
/// * At or after `at`, ANY mention keeps the loan live, call argument or
///   not, because it is a use of a loan the caller is about to end.
///
/// A first version of this function whitelisted call arguments in both
/// regions, and it was caught by running it: with the match-guard hole
/// deliberately reintroduced into `exprUsesName`, the checker accepted
/// `match 1 { _ if use_it(shared e) > 0 => 1, _ => 2 }` after a
/// conflicting borrow and this oracle AGREED, because the use sits in a
/// call argument. Splitting at `at` makes it disagree, which is the whole
/// reason the oracle exists.
pub fn oracleDead(
    self: *Checker,
    loan: Loan,
    holder: []const u8,
    at: Span,
) Error!OracleVerdict {
    const f = self.current_fn orelse return .not_applicable;
    const body = f.body orelse return .not_applicable;
    if (oracleDeclarationCount(f, holder) != 1) return .not_applicable;

    var names: NameSet = .empty;
    defer names.deinit(self.allocator);
    try names.put(self.allocator, holder, {});

    var changed = true;
    while (changed) {
        changed = false;
        try oracleTaintStmts(self.allocator, body, &names, &changed);
    }

    // `+ 1` makes it strictly after: the loan's own span is the borrowed
    // place, which is not the holder, but the bound is stated exactly
    // rather than left to that coincidence.
    const after = loan.span.start +| 1;
    if (oracleFindStmts(body, &names, after, at.start) != null) return .live;
    return .dead;
}

/// Part (b). Scans the statements at the loan's own block level that lie
/// strictly between the loan's `let` and the statement being checked.
///
/// Returns true, meaning `ineligible`, when the holder is mentioned there
/// in any position other than the one whitelisted by `argPropagatesName`.
/// Returns true as well when the loan's block is no longer on the stack,
/// which cannot happen for a live block loan but must not silently read as
/// "nothing propagates" if it ever does.
pub fn windowPropagates(self: *const Checker, loan: Loan, holder: []const u8) bool {
    if (loan.block_index >= self.open_blocks.items.len) return true;
    const ob = self.open_blocks.items[loan.block_index];
    const from = @min(loan.stmt_index + 1, ob.stmts.len);
    const to = @min(ob.index, ob.stmts.len);
    if (to <= from) return false;
    for (ob.stmts[from..to]) |*s| {
        if (stmtPropagatesName(s, holder)) return true;
    }
    return false;
}

/// Whether `name` appears anywhere from the statement being checked to the
/// end of the block that owns the loan. The statement currently being
/// checked counts in full, and so does the statement containing an inner
/// block, so the answer errs toward "used".
pub fn nameUsedFrom(self: *const Checker, name: []const u8, from_block: usize) bool {
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

pub fn stmtUsesName(s: *const ast.Stmt, name: []const u8) bool {
    return switch (s.kind) {
        .let => |l| if (l.value) |v| exprUsesName(&v, name) else false,
        .expr => |e| exprUsesName(&e, name),
        .return_stmt => |opt| if (opt) |e| exprUsesName(&e, name) else false,
        .assign => |a| exprUsesName(&a.target, name) or exprUsesName(&a.value, name),
        .while_stmt => |w| blk: {
            if (exprUsesName(&w.cond, name)) break :blk true;
            for (w.body) |*b| {
                if (stmtUsesName(b, name)) break :blk true;
            }
            break :blk false;
        },
        .break_stmt, .continue_stmt => false,
    };
}

pub fn exprUsesName(e: *const ast.Expr, name: []const u8) bool {
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
        .index => |ix| exprUsesName(ix.base, name) or exprUsesName(ix.index, name),
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
                // The GUARD, not only the body. An arm has two expression
                // positions and this scanned one of them, so
                // `match n { _ if use_it(exclusive e) > 0 => 1, _ => 2 }`
                // read as "'e' is never used again" and printed a note saying
                // NLL would accept a program NLL rejects. Under the
                // acceptance this scan now gates, the same hole would have
                // ended a loan that is still held inside the guard.
                if (arm.guard) |g| {
                    if (exprUsesName(g, name)) break :blk true;
                }
                if (exprUsesName(arm.body, name)) break :blk true;
            }
            break :blk false;
        },
        .annotated => |a| exprUsesName(a.value, name),
        .wrap => |w| if (w.operand) |o| exprUsesName(o, name) else false,
    };
}

// ── the NLL predicate's part (b): the window walker ─────────────────────
//
// THE WHITELIST IS THE COMPLEMENT, AND THAT IS THE WHOLE POINT. These three
// functions do not enumerate the positions that propagate a reference and
// assume everything left over is safe. They enumerate the ONE position that
// provably cannot propagate one, and treat every other mention as propagating.
//
// The one position: a DIRECT argument of a call, after peeling a written
// ownership keyword (`.annotated`) and a `&`/`&mut` sigil. It is sound because
// R8 forbids the callee returning the borrow or storing it in a struct field,
// and Cell has no lifetime parameters, no references inside aggregates and no
// closures, so a callee has nowhere to put it. If lifetime parameters ever
// land, the test named for that invariant fails and says so.
//
// Every other mention -- a `let` initializer, an `assign` target or value, a
// `match` scrutinee, a guard, a struct-literal field, a list element, an
// `if`/`match`/block value position -- lands on the reject side by
// construction rather than by being remembered. Value positions are exactly
// the class that produced two of the `arc` use-after-frees this checker has
// already shipped and fixed.
//
// Both switches are exhaustive with NO `else` arm, like `exprUsesName` above,
// so a new AST node is a compile error here rather than a silent default to
// "safe".

/// Whether `s` mentions `name` anywhere outside the whitelisted position.
pub fn stmtPropagatesName(s: *const ast.Stmt, name: []const u8) bool {
    return switch (s.kind) {
        .let => |l| if (l.value) |v| exprPropagatesName(&v, name) else false,
        .expr => |e| exprPropagatesName(&e, name),
        .return_stmt => |opt| if (opt) |e| exprPropagatesName(&e, name) else false,
        // The TARGET counts. `e = &mut b` retargets the holder, and this
        // checker does not model that (see the report on the retarget gap), so
        // any assignment naming the holder is `ineligible`.
        .assign => |a| exprPropagatesName(&a.target, name) or exprPropagatesName(&a.value, name),
        .while_stmt => |w| blk: {
            if (exprPropagatesName(&w.cond, name)) break :blk true;
            for (w.body) |*b| {
                if (stmtPropagatesName(b, name)) break :blk true;
            }
            break :blk false;
        },
        .break_stmt, .continue_stmt => false,
    };
}

/// Whether `e` mentions `name` anywhere outside the whitelisted position.
/// Every sub-expression here is a non-whitelisted position; only
/// `argPropagatesName` opens the one exception.
pub fn exprPropagatesName(e: *const ast.Expr, name: []const u8) bool {
    return switch (e.kind) {
        .ident => |n| std.mem.eql(u8, n, name),
        .int, .float, .string, .bool => false,
        .call => |c| blk: {
            // The CALLEE is not an argument. `e(1)` is not whitelisted.
            if (exprPropagatesName(c.callee, name)) break :blk true;
            for (c.args) |*a| {
                if (argPropagatesName(a, name)) break :blk true;
            }
            break :blk false;
        },
        .binary => |b| exprPropagatesName(b.left, name) or exprPropagatesName(b.right, name),
        .unary => |u| exprPropagatesName(u.operand, name),
        .field => |f| exprPropagatesName(f.base, name),
        .index => |ix| exprPropagatesName(ix.base, name) or exprPropagatesName(ix.index, name),
        .struct_lit => |sl| blk: {
            for (sl.fields) |*f| {
                if (exprPropagatesName(&f.value, name)) break :blk true;
            }
            break :blk false;
        },
        .list_lit => |items| blk: {
            for (items) |*item| {
                if (exprPropagatesName(item, name)) break :blk true;
            }
            break :blk false;
        },
        .block => |stmts| blk: {
            for (stmts) |*s| {
                if (stmtPropagatesName(s, name)) break :blk true;
            }
            break :blk false;
        },
        .if_expr => |i| blk: {
            if (exprPropagatesName(i.cond, name)) break :blk true;
            if (exprPropagatesName(i.then_body, name)) break :blk true;
            if (i.else_body) |eb| {
                if (exprPropagatesName(eb, name)) break :blk true;
            }
            break :blk false;
        },
        .match_expr => |m| blk: {
            if (exprPropagatesName(m.scrutinee, name)) break :blk true;
            for (m.arms) |arm| {
                if (arm.guard) |g| {
                    if (exprPropagatesName(g, name)) break :blk true;
                }
                if (exprPropagatesName(arm.body, name)) break :blk true;
            }
            break :blk false;
        },
        .annotated => |a| exprPropagatesName(a.value, name),
        .wrap => |w| if (w.operand) |o| exprPropagatesName(o, name) else false,
    };
}

/// One call argument, the only whitelisted position. Peels a written
/// ownership keyword and a `&`/`&mut` sigil; if what is left is exactly a
/// bare identifier, the mention cannot propagate, whether or not it is
/// `name`. Anything else falls back to the non-whitelisted walk, so
/// `f(e.len)`, `f(g(e))`'s outer argument and `f(-e)` are all judged there.
pub fn argPropagatesName(arg: *const ast.Expr, name: []const u8) bool {
    var cursor = arg;
    while (true) {
        switch (cursor.kind) {
            .annotated => |a| cursor = a.value,
            .unary => |u| switch (u.op) {
                .ref_shared, .ref_exclusive => cursor = u.operand,
                else => return exprPropagatesName(cursor, name),
            },
            // A bare identifier handed to a callee. Either it is `name`, and
            // R8 stops the callee keeping it, or it is some other binding and
            // there is no mention of `name` here at all. Both are `false`.
            .ident => return false,
            else => return exprPropagatesName(cursor, name),
        }
    }
}

// ── the differential oracle ─────────────────────────────────────────────
//
// A second implementation of "is this loan dead", written so conservatively
// that it cannot have a missing case, and asserted against the precise one in
// every safety-checked build. `Checker.oracleDead` carries the argument for
// why it exists, the one deviation from its brief, and its one known hole.
//
// Everything below ignores scopes, blocks, statement order and control flow.
// It is a grep with a fixpoint, not an analysis.

/// How many times `name` is DECLARED in `f`: parameters, `let` statements at
/// any depth, and match-arm binding patterns. The oracle declines when this is
/// not exactly 1, because shadowing is the one thing its scope blindness gets
/// wrong in the unsafe direction for the ASSERTION (never for the language).
pub fn oracleDeclarationCount(f: *const ast.FnDef, name: []const u8) usize {
    var n: usize = 0;
    for (f.params) |p| {
        if (std.mem.eql(u8, p.name, name)) n += 1;
    }
    if (f.body) |body| n += oracleDeclCountStmts(body, name);
    return n;
}

pub fn oracleDeclCountStmts(stmts: []const ast.Stmt, name: []const u8) usize {
    var n: usize = 0;
    for (stmts) |*s| {
        switch (s.kind) {
            .let => |l| {
                if (std.mem.eql(u8, l.name, name)) n += 1;
                if (l.value) |v| n += oracleDeclCountExpr(&v, name);
            },
            .expr => |e| n += oracleDeclCountExpr(&e, name),
            .return_stmt => |opt| if (opt) |e| {
                n += oracleDeclCountExpr(&e, name);
            },
            .assign => |a| {
                n += oracleDeclCountExpr(&a.target, name);
                n += oracleDeclCountExpr(&a.value, name);
            },
            .while_stmt => |w| {
                n += oracleDeclCountExpr(&w.cond, name);
                n += oracleDeclCountStmts(w.body, name);
            },
            .break_stmt, .continue_stmt => {},
        }
    }
    return n;
}

pub fn oracleDeclCountExpr(e: *const ast.Expr, name: []const u8) usize {
    return switch (e.kind) {
        .ident, .int, .float, .string, .bool => 0,
        .call => |c| blk: {
            var n = oracleDeclCountExpr(c.callee, name);
            for (c.args) |*a| n += oracleDeclCountExpr(a, name);
            break :blk n;
        },
        .binary => |b| oracleDeclCountExpr(b.left, name) + oracleDeclCountExpr(b.right, name),
        .unary => |u| oracleDeclCountExpr(u.operand, name),
        .field => |f| oracleDeclCountExpr(f.base, name),
        .index => |ix| oracleDeclCountExpr(ix.base, name) + oracleDeclCountExpr(ix.index, name),
        .annotated => |a| oracleDeclCountExpr(a.value, name),
        .struct_lit => |sl| blk: {
            var n: usize = 0;
            for (sl.fields) |*f| n += oracleDeclCountExpr(&f.value, name);
            break :blk n;
        },
        .list_lit => |items| blk: {
            var n: usize = 0;
            for (items) |*item| n += oracleDeclCountExpr(item, name);
            break :blk n;
        },
        .block => |stmts| oracleDeclCountStmts(stmts, name),
        .if_expr => |i| blk: {
            var n = oracleDeclCountExpr(i.cond, name) + oracleDeclCountExpr(i.then_body, name);
            if (i.else_body) |eb| n += oracleDeclCountExpr(eb, name);
            break :blk n;
        },
        .match_expr => |m| blk: {
            var n = oracleDeclCountExpr(m.scrutinee, name);
            for (m.arms) |arm| {
                if (arm.pattern.kind == .binding and
                    std.mem.eql(u8, arm.pattern.kind.binding, name)) n += 1;
                if (arm.guard) |g| n += oracleDeclCountExpr(g, name);
                n += oracleDeclCountExpr(arm.body, name);
            }
            break :blk n;
        },
        .wrap => |w| if (w.operand) |o| oracleDeclCountExpr(o, name) else 0,
    };
}

/// A `strict_from` past every possible offset, so the whitelist applies
/// everywhere. Step 1 of the oracle uses it: the closure asks whether a value
/// could have CAPTURED a reference, and a direct call argument provably
/// cannot, whatever its position. Only step 2 has a conflict point to split
/// on.
pub const oracle_never_strict: u32 = std.math.maxInt(u32);

/// Step 1 of the oracle: one sweep of the taint closure. A `let` name or an
/// `assign` target joins `names` when the value mentions a name already in it
/// outside the whitelisted position. Runs to a fixpoint in `oracleDead`, so
/// statement order does not matter.
pub fn oracleTaintStmts(
    gpa: std.mem.Allocator,
    stmts: []const ast.Stmt,
    names: *NameSet,
    changed: *bool,
) Error!void {
    for (stmts) |*s| {
        switch (s.kind) {
            .let => |l| {
                if (l.value) |v| {
                    if (oracleFindExpr(&v, names, .other, 0, oracle_never_strict) != null) {
                        try oracleAdd(gpa, names, l.name, changed);
                    }
                    try oracleTaintExpr(gpa, &v, names, changed);
                }
            },
            .assign => |a| {
                if (oracleFindExpr(&a.value, names, .other, 0, oracle_never_strict) != null) {
                    if (ast.rootName(&a.target)) |n| try oracleAdd(gpa, names, n, changed);
                }
                try oracleTaintExpr(gpa, &a.target, names, changed);
                try oracleTaintExpr(gpa, &a.value, names, changed);
            },
            .expr => |e| try oracleTaintExpr(gpa, &e, names, changed),
            .return_stmt => |opt| if (opt) |e| {
                try oracleTaintExpr(gpa, &e, names, changed);
            },
            .while_stmt => |w| {
                try oracleTaintExpr(gpa, &w.cond, names, changed);
                try oracleTaintStmts(gpa, w.body, names, changed);
            },
            .break_stmt, .continue_stmt => {},
        }
    }
}

/// Reaches the `let` and `assign` statements nested inside expressions. Every
/// block in this language is an expression, so without this the closure would
/// stop at the first `if`.
pub fn oracleTaintExpr(
    gpa: std.mem.Allocator,
    e: *const ast.Expr,
    names: *NameSet,
    changed: *bool,
) Error!void {
    switch (e.kind) {
        .ident, .int, .float, .string, .bool => {},
        .call => |c| {
            try oracleTaintExpr(gpa, c.callee, names, changed);
            for (c.args) |*a| try oracleTaintExpr(gpa, a, names, changed);
        },
        .binary => |b| {
            try oracleTaintExpr(gpa, b.left, names, changed);
            try oracleTaintExpr(gpa, b.right, names, changed);
        },
        .unary => |u| try oracleTaintExpr(gpa, u.operand, names, changed),
        .field => |f| try oracleTaintExpr(gpa, f.base, names, changed),
        .index => |ix| {
            try oracleTaintExpr(gpa, ix.base, names, changed);
            try oracleTaintExpr(gpa, ix.index, names, changed);
        },
        .annotated => |a| try oracleTaintExpr(gpa, a.value, names, changed),
        .struct_lit => |sl| {
            for (sl.fields) |*f| try oracleTaintExpr(gpa, &f.value, names, changed);
        },
        .list_lit => |items| {
            for (items) |*item| try oracleTaintExpr(gpa, item, names, changed);
        },
        .block => |stmts| try oracleTaintStmts(gpa, stmts, names, changed),
        .if_expr => |i| {
            try oracleTaintExpr(gpa, i.cond, names, changed);
            try oracleTaintExpr(gpa, i.then_body, names, changed);
            if (i.else_body) |eb| try oracleTaintExpr(gpa, eb, names, changed);
        },
        .match_expr => |m| {
            try oracleTaintExpr(gpa, m.scrutinee, names, changed);
            for (m.arms) |arm| {
                if (arm.guard) |g| try oracleTaintExpr(gpa, g, names, changed);
                try oracleTaintExpr(gpa, arm.body, names, changed);
            }
        },
        .wrap => |w| if (w.operand) |o| try oracleTaintExpr(gpa, o, names, changed),
    }
}

pub fn oracleAdd(
    gpa: std.mem.Allocator,
    names: *NameSet,
    name: []const u8,
    changed: *bool,
) Error!void {
    const gop = try names.getOrPut(gpa, name);
    if (!gop.found_existing) changed.* = true;
}

/// Step 2 of the oracle: the byte offset of the first occurrence of a tainted
/// name at or after `min_start`, in a position that is not a direct call
/// argument. Null when there is none.
///
/// The context travels DOWN: a call's argument enters as `.call_arg`, only an
/// ownership keyword and a `&`/`&mut` sigil keep it, and every other node
/// resets it. That is a different mechanism from the checker's peel-upward
/// `argPropagatesName`, which is the point.
pub fn oracleFindStmts(
    stmts: []const ast.Stmt,
    names: *const NameSet,
    min_start: u32,
    strict_from: u32,
) ?u32 {
    for (stmts) |*s| {
        if (oracleFindStmt(s, names, min_start, strict_from)) |x| return x;
    }
    return null;
}

pub fn oracleFindStmt(
    s: *const ast.Stmt,
    names: *const NameSet,
    min_start: u32,
    strict_from: u32,
) ?u32 {
    return switch (s.kind) {
        .let => |l| if (l.value) |v| oracleFindExpr(&v, names, .other, min_start, strict_from) else null,
        .expr => |e| oracleFindExpr(&e, names, .other, min_start, strict_from),
        .return_stmt => |opt| if (opt) |e| oracleFindExpr(&e, names, .other, min_start, strict_from) else null,
        .assign => |a| oracleFindExpr(&a.target, names, .other, min_start, strict_from) orelse
            oracleFindExpr(&a.value, names, .other, min_start, strict_from),
        .while_stmt => |w| oracleFindExpr(&w.cond, names, .other, min_start, strict_from) orelse
            oracleFindStmts(w.body, names, min_start, strict_from),
        .break_stmt, .continue_stmt => null,
    };
}

pub fn oracleFindExpr(
    e: *const ast.Expr,
    names: *const NameSet,
    ctx: ArgContext,
    min_start: u32,
    /// The conflict's own offset. At or after it the whitelist stops applying:
    /// a use is a use. See `oracleDead` for why the two regions differ.
    strict_from: u32,
) ?u32 {
    return switch (e.kind) {
        .ident => |n| if (!names.contains(n) or e.span.start < min_start)
            null
        else if (ctx == .call_arg and e.span.start < strict_from)
            null
        else
            e.span.start,
        .int, .float, .string, .bool => null,
        .call => |c| blk: {
            // The callee is not an argument of itself.
            if (oracleFindExpr(c.callee, names, .other, min_start, strict_from)) |x| break :blk x;
            for (c.args) |*a| {
                if (oracleFindExpr(a, names, .call_arg, min_start, strict_from)) |x| break :blk x;
            }
            break :blk null;
        },
        // The two node kinds that keep the context.
        .annotated => |a| oracleFindExpr(a.value, names, ctx, min_start, strict_from),
        .unary => |u| oracleFindExpr(
            u.operand,
            names,
            if (u.op == .ref_shared or u.op == .ref_exclusive) ctx else .other,
            min_start,
            strict_from,
        ),
        .binary => |b| oracleFindExpr(b.left, names, .other, min_start, strict_from) orelse
            oracleFindExpr(b.right, names, .other, min_start, strict_from),
        .field => |f| oracleFindExpr(f.base, names, .other, min_start, strict_from),
        .index => |ix| oracleFindExpr(ix.base, names, .other, min_start, strict_from) orelse
            oracleFindExpr(ix.index, names, .other, min_start, strict_from),
        .struct_lit => |sl| blk: {
            for (sl.fields) |*f| {
                if (oracleFindExpr(&f.value, names, .other, min_start, strict_from)) |x| break :blk x;
            }
            break :blk null;
        },
        .list_lit => |items| blk: {
            for (items) |*item| {
                if (oracleFindExpr(item, names, .other, min_start, strict_from)) |x| break :blk x;
            }
            break :blk null;
        },
        .block => |stmts| oracleFindStmts(stmts, names, min_start, strict_from),
        .if_expr => |i| blk: {
            if (oracleFindExpr(i.cond, names, .other, min_start, strict_from)) |x| break :blk x;
            if (oracleFindExpr(i.then_body, names, .other, min_start, strict_from)) |x| break :blk x;
            if (i.else_body) |eb| {
                if (oracleFindExpr(eb, names, .other, min_start, strict_from)) |x| break :blk x;
            }
            break :blk null;
        },
        .match_expr => |m| blk: {
            if (oracleFindExpr(m.scrutinee, names, .other, min_start, strict_from)) |x| break :blk x;
            for (m.arms) |arm| {
                if (arm.guard) |g| {
                    if (oracleFindExpr(g, names, .other, min_start, strict_from)) |x| break :blk x;
                }
                if (oracleFindExpr(arm.body, names, .other, min_start, strict_from)) |x| break :blk x;
            }
            break :blk null;
        },
        .wrap => |w| if (w.operand) |o|
            oracleFindExpr(o, names, .other, min_start, strict_from)
        else
            null,
    };
}
