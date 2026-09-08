//! A control-flow graph over one `hir.Fn`.
//!
//! A LEAF MODULE. It imports `hir` and nothing else, so it is testable
//! standalone and does not smuggle codegen or backend knowledge into a
//! structure that is meant to be backend-agnostic.
//!
//! WHY THIS EXISTS. `docs/OWNERSHIP.md` R16 says an `owned` place is
//! destroyed at the end of its scope, but `codegen.zig` emits zero drop
//! calls: Cell allocates and never frees. Inserting drops correctly means
//! knowing every path out of a scope, and Cell has four kinds of exit --
//! `return`, `break`, `continue`, and the panic emitted for a
//! non-exhaustive `match` -- any of which can leave a scope without
//! reaching its lexical end. `docs/OWNERSHIP.md` section 0.3 chose lexical
//! scoping specifically to avoid needing a CFG, and loops broke that: a
//! `while` body's end is not the last place control passes through it, a
//! back edge is. This module builds the graph a later drop-insertion pass
//! walks; nothing consumes it yet.
//!
//! WHAT A BLOCK IS, AND WHAT IT DELIBERATELY DOES NOT CARRY. A `Block` here
//! is a shape: an id, its terminator, and the edges the terminator implies.
//! It does NOT store the statements that ran inside it. That is not an
//! oversight -- the type is specified by the task that created this module,
//! and a shape-only graph is enough to prove the properties this module is
//! tested against (every block terminates once, `preds`/`succs` agree,
//! loops produce back edges, `break`/`continue` target the right blocks,
//! a non-exhaustive `match` does not look like a normal exit). A consumer
//! that needs to know what ran in a block correlates it against the HIR by
//! walking the same tree this builder walks, in the same order; this module
//! does not provide that correlation, because doing so would mean choosing
//! a representation for "the statements of a block" that no consumer has
//! asked for yet.
//!
//! `preds` is stored rather than derived from `succs` on demand, because
//! liveness (a backward analysis, and the reason this module exists) walks
//! a graph from its exits toward its entry, and recomputing predecessors
//! per query is the wrong shape for that.
//!
//! WHAT IT DELIBERATELY DOES NOT DO. It does not run the checker and does
//! not reject anything: like `hir.zig`'s own lowering, it is total over
//! whatever HIR shape reaches it, including one hand-built by a test that
//! never touched a parser. It does not fold constants, so a literal `true`
//! or `false` condition still produces a real two-successor branch; this
//! module has no opinion about which paths are reachable, only about what
//! the source's control-flow keywords imply structurally. It does not
//! eliminate an `if`/`match` join that ends up unreachable (every arm
//! diverged) -- the block is still allocated -- but it does seal that join
//! `.unreachable_` and refuses to hand it back as a live continuation
//! (`Builder.deadJoinOrLive`), specifically so a `while` wrapped around it
//! cannot mistake a block nothing can enter for the reachable end of its
//! body and wire a phantom back edge into its condition block from it.

const std = @import("std");
const hir = @import("hir.zig");

/// The only way any builder method can fail. Named explicitly, rather than
/// left for Zig to infer per function, because the lowering functions below
/// call each other in a genuine cycle (a statement can hold an expression
/// that holds a block that holds statements again), and an inferred error
/// set cannot be resolved across a cycle of `anytype` functions.
const CfgError = std.mem.Allocator.Error;

/// One node: a straight-line run of statements with a single entry and a
/// single terminator.
pub const Block = struct {
    id: u32,
    /// Successor block ids, in the order the terminator branches to them.
    succs: []u32,
    /// Predecessor block ids. Stored rather than derived, because backward
    /// analyses (liveness, which Task 2 builds) need them and recomputing
    /// them per query is the wrong shape.
    preds: []u32,
    term: Terminator,
};

pub const Terminator = union(enum) {
    /// Falls through to a single successor.
    goto,
    /// Two successors: taken, then not-taken.
    branch,
    /// Leaves the function.
    ret,
    /// Does not return: the non-exhaustive-match panic.
    unreachable_,
};

pub const Graph = struct {
    blocks: []Block,
    entry: u32,
    /// Every block whose terminator is `.ret`. A drop pass needs all of them.
    exits: []u32,
};

/// Build the graph for `f`. Returns null when `f.body` is null (a bodyless
/// declaration has no control flow).
///
/// `allocator` should be an arena, as elsewhere in this compiler: every
/// block and edge list is allocated from it and nothing is freed
/// individually.
pub fn build(allocator: std.mem.Allocator, f: *const hir.Fn) !?Graph {
    const body = f.body orelse return null;

    var b: Builder = .{ .allocator = allocator };
    const entry = try b.newBlock();
    b.cur = entry;
    try b.lowerStmts(body);

    // A function whose body falls off the end still needs a terminator on
    // its last block. `llvmemit.zig` emits `ret void` / `ret zeroinitializer`
    // for exactly this case; this is the same fact at the graph level, and
    // `typecheck.zig` already refuses a missing `return` for anything but a
    // unit-returning function, so falling off the end is a real, accepted
    // program shape here, not a bug this module is papering over.
    if (b.cur) |c| {
        b.seal(c, .ret);
        try b.exits.append(allocator, c);
    }

    const blocks = try allocator.alloc(Block, b.blocks.items.len);
    for (b.blocks.items, 0..) |*built, i| {
        blocks[i] = .{
            .id = @intCast(i),
            // `.items` rather than a copy: `built`'s lists were allocated
            // from the same arena the caller owns, matching how
            // `hir.Lowerer.run` hands back `self.structs.items` directly.
            .succs = built.succs.items,
            .preds = built.preds.items,
            // Every block this builder creates is sealed exactly once along
            // some path before this point. A null here is a bug in the
            // builder, not a malformed input, so it is worth crashing on
            // rather than inventing a terminator.
            .term = built.term orelse unreachable,
        };
    }

    return Graph{
        .blocks = blocks,
        .entry = entry,
        .exits = b.exits.items,
    };
}

// ---------------------------------------------------------------------------
// The builder
// ---------------------------------------------------------------------------

const Builder = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(BlockBuilder) = .empty,
    loops: std.ArrayList(LoopCtx) = .empty,
    exits: std.ArrayList(u32) = .empty,
    /// The block currently open for appending, or null when the path
    /// reaching here has already diverged (`return`, `break`, `continue`, or
    /// a non-exhaustive `match`'s fallthrough) and nothing reachable follows
    /// until the next merge point creates a fresh block.
    cur: ?u32 = null,

    const BlockBuilder = struct {
        succs: std.ArrayList(u32) = .empty,
        preds: std.ArrayList(u32) = .empty,
        term: ?Terminator = null,
    };

    /// `cond` is the block continue jumps to; `exit` is the block break
    /// jumps to. Both are allocated before the loop body is lowered, because
    /// a `break`/`continue` inside the body must be able to name them.
    const LoopCtx = struct { cond: u32, exit: u32 };

    fn newBlock(self: *Builder) CfgError!u32 {
        const id: u32 = @intCast(self.blocks.items.len);
        try self.blocks.append(self.allocator, .{});
        return id;
    }

    fn addEdge(self: *Builder, from: u32, to: u32) CfgError!void {
        try self.blocks.items[from].succs.append(self.allocator, to);
        try self.blocks.items[to].preds.append(self.allocator, from);
    }

    /// Sets `block`'s terminator. Asserts it was unset: every block this
    /// builder creates is sealed exactly once, and a double-seal means some
    /// path was walked twice, which is exactly the bug rule 1 (one
    /// terminator per block) exists to catch.
    fn seal(self: *Builder, block: u32, term: Terminator) void {
        std.debug.assert(self.blocks.items[block].term == null);
        self.blocks.items[block].term = term;
    }

    /// A join block (the merge point after an `if`/`match`) ends up with no
    /// real predecessor exactly when every arm that could reach it
    /// diverged first. That join must not be handed back as a live `cur`:
    /// a caller such as `lowerWhile`'s back-edge check tests only whether
    /// `cur` is non-null, not whether it is reachable, and would otherwise
    /// wire a phantom edge from a block nothing can ever enter into a real,
    /// live block (the loop's condition), corrupting its predecessor set.
    ///
    /// Sealing it `.unreachable_` here, rather than leaving it open for
    /// whatever runs next to seal, keeps rule 1 (every block terminates
    /// once) satisfied without ever exposing the dead block as `cur`. It is
    /// excluded from `exits` for the same reason the match-panic block is:
    /// nothing ever runs it, so it is not a real function exit a drop pass
    /// should visit.
    ///
    /// **This check is ONE-HOP and not transitive, and a consumer must know
    /// that.** It asks only whether this join has zero predecessors. A join
    /// whose only predecessor is itself unreachable -- a guard that always
    /// diverges, say -- has a predecessor count of one and is handed back as
    /// live. So a block reachable from here is not thereby reachable from
    /// `entry`, and a consumer that needs real reachability must compute it
    /// rather than infer it from a non-null `cur`.
    ///
    /// The direction is the safe one and that is why it is left: a genuinely
    /// dead join is treated as live, which is exactly the pre-check behaviour
    /// for every case, so nothing regressed. It over-approximates
    /// reachability, and over-approximating is what a drop pass and a
    /// liveness pass both want. `src/cell/liveness.zig` tolerates it
    /// deliberately and says so in its own module doc comment. This caveat
    /// lived only in a task report until 2026-09-07; it belongs here, next to
    /// the code that has it.
    fn deadJoinOrLive(self: *Builder, join_id: u32) ?u32 {
        if (self.blocks.items[join_id].preds.items.len == 0) {
            self.seal(join_id, .unreachable_);
            return null;
        }
        return join_id;
    }

    // -- statements -----------------------------------------------------
    //
    // A NOTE FOR WHOEVER BUILDS ON THIS GRAPH, recorded 2026-09-07 from a
    // review of `lowerMatch`. That function was fixed so a guarded catch-all
    // gets a single decision point, and so a join with no real predecessors is
    // sealed rather than handed back as `cur`. The same shape exists in
    // principle for `lowerIf`'s branches: an arm or branch body is lowered
    // even when the edge into it was never added, because lowering walks the
    // HIR tree rather than following edges. It is not a defect today -- a body
    // lowered into a block nothing enters contributes blocks that no path
    // reaches, and both `deadJoinOrLive` above and a liveness fixpoint
    // over-approximate harmlessly past it. It is written down because a
    // consumer that assumes "every block in the graph is reachable" would be
    // wrong, and that assumption is easy to make and hard to see.

    fn lowerStmts(self: *Builder, stmts: []const hir.Stmt) CfgError!void {
        for (stmts) |stmt| {
            // A statement after `return`/`break`/`continue` in the same list
            // is unreachable. Stopping here, rather than lowering it into
            // whatever block happens to be open, is what keeps it from
            // silently joining the next block -- there is no open block for
            // it to join, because there is no such block.
            if (self.cur == null) return;
            try self.lowerStmt(stmt);
        }
    }

    fn lowerStmt(self: *Builder, stmt: hir.Stmt) CfgError!void {
        switch (stmt.kind) {
            .let => |l| if (l.value) |v| try self.lowerExprValue(&v),
            .assign => |a| try self.lowerExprValue(&a.value),
            .expr => |e| try self.lowerExprValue(&e),
            .ret => |maybe| {
                if (maybe) |e| try self.lowerExprValue(&e);
                if (self.cur) |c| {
                    self.seal(c, .ret);
                    try self.exits.append(self.allocator, c);
                    self.cur = null;
                }
            },
            .while_loop => |w| try self.lowerWhile(w),
            .brk => try self.lowerJump(.brk),
            .cont => try self.lowerJump(.cont),
        }
    }

    fn lowerJump(self: *Builder, kind: enum { brk, cont }) CfgError!void {
        const c = self.cur orelse return;
        // `break`/`continue` outside a loop are already rejected by
        // `typecheck.zig`, so a loop context is always open here; a fixture
        // that violates this is a bug in the fixture, and the assert says so
        // plainly instead of building a silently wrong graph.
        std.debug.assert(self.loops.items.len > 0);
        const target = self.loops.items[self.loops.items.len - 1];
        const to = switch (kind) {
            .brk => target.exit,
            .cont => target.cond,
        };
        try self.addEdge(c, to);
        self.seal(c, .goto);
        self.cur = null;
    }

    fn lowerWhile(self: *Builder, w: anytype) CfgError!void {
        if (self.cur == null) return;
        const entry_block = self.cur.?;

        // The condition needs its own block: a back edge from the body has
        // to land somewhere, and re-running the last statement of whatever
        // block preceded the loop is not that.
        const cond_id = try self.newBlock();
        try self.addEdge(entry_block, cond_id);
        self.seal(entry_block, .goto);

        self.cur = cond_id;
        try self.lowerExprValue(&w.cond);
        // A condition that itself diverges on every path (nested control
        // flow that always returns) leaves nothing reachable after it. Every
        // block that ran while evaluating it was already sealed on the way
        // there, `cond_id` included, so there is nothing left to seal here.
        const test_block = self.cur orelse return;

        const body_id = try self.newBlock();
        const exit_id = try self.newBlock();
        try self.addEdge(test_block, body_id);
        try self.addEdge(test_block, exit_id);
        self.seal(test_block, .branch);

        try self.loops.append(self.allocator, .{ .cond = cond_id, .exit = exit_id });
        self.cur = body_id;
        try self.lowerStmts(w.body);
        _ = self.loops.pop();

        // The back edge: whatever block the body ended on (if it did not
        // itself diverge) loops around to re-test the condition. This, and
        // not any tree shape, is what makes the result a graph.
        if (self.cur) |c| {
            try self.addEdge(c, cond_id);
            self.seal(c, .goto);
        }

        self.cur = exit_id;
    }

    // -- expressions ------------------------------------------------------

    /// Walks `e` for the control flow it may carry. Most expression kinds
    /// are leaves as far as this module is concerned; the three named in the
    /// brief (`block`, `if_expr`, `match_expr`) are not, and everything else
    /// that can hold a nested expression is still walked, because ownership
    /// gives Cell no reason to forbid writing one of those three inside a
    /// call argument or a struct literal field.
    fn lowerExprValue(self: *Builder, e: *const hir.Expr) CfgError!void {
        if (self.cur == null) return;
        switch (e.kind) {
            .block => |bl| try self.lowerBlock(bl),
            .if_expr => |ie| try self.lowerIf(ie),
            .match_expr => |me| try self.lowerMatch(me),
            .binary => |bin| {
                try self.lowerExprValue(bin.left);
                try self.lowerExprValue(bin.right);
            },
            .unary => |u| try self.lowerExprValue(u.operand),
            .call => |c| {
                try self.lowerExprValue(c.callee);
                for (c.args) |*a| try self.lowerExprValue(a);
            },
            .field => |f| try self.lowerExprValue(f.base),
            .struct_lit => |sl| for (sl.fields) |*fv| try self.lowerExprValue(fv),
            .list_lit => |elems| for (elems) |*el| try self.lowerExprValue(el),
            .int_const,
            .float_const,
            .bool_const,
            .string_const,
            .ref,
            .unresolved_ref,
            .enum_const,
            => {},
        }
    }

    fn lowerBlock(self: *Builder, bl: anytype) CfgError!void {
        try self.lowerStmts(bl.stmts);
        if (self.cur != null) {
            if (bl.tail) |t| try self.lowerExprValue(t);
        }
    }

    fn lowerIf(self: *Builder, ie: anytype) CfgError!void {
        try self.lowerExprValue(ie.cond);
        if (self.cur == null) return;
        const branch_block = self.cur.?;

        const then_id = try self.newBlock();
        const join_id = try self.newBlock();
        // No else means the "not taken" edge IS the join: there is no code
        // to run, so allocating an empty else block just to goto the join
        // would be a block this module could never justify to rule 1.
        const else_id: u32 = if (ie.else_body != null) try self.newBlock() else join_id;

        try self.addEdge(branch_block, then_id);
        try self.addEdge(branch_block, else_id);
        self.seal(branch_block, .branch);

        self.cur = then_id;
        try self.lowerExprValue(ie.then_body);
        if (self.cur) |c| {
            try self.addEdge(c, join_id);
            self.seal(c, .goto);
        }

        if (ie.else_body) |eb| {
            self.cur = else_id;
            try self.lowerExprValue(eb);
            if (self.cur) |c| {
                try self.addEdge(c, join_id);
                self.seal(c, .goto);
            }
        }

        self.cur = self.deadJoinOrLive(join_id);
    }

    fn lowerMatch(self: *Builder, me: anytype) CfgError!void {
        try self.lowerExprValue(me.scrutinee);
        if (self.cur == null) return;

        const join_id = try self.newBlock();
        // The first arm is tested in the same block the scrutinee finished
        // in; only a failed test needs a fresh block to test the next arm.
        var test_block = self.cur.?;
        var saw_catch_all = false;

        for (me.arms) |arm| {
            // The pattern alone matching everything is not the same fact as
            // the arm being a catch-all: a guard can still reject it. Both
            // booleans are needed, and both come straight from
            // `codegen.isDefaultArm` / `llvmemit.zig` / `mlirmit.zig`, which
            // compute exactly this pair for exactly this reason.
            const pattern_matches_all = switch (arm.pattern.kind) {
                .wildcard, .binding => true,
                else => false,
            };
            const catch_all = arm.guard == null and pattern_matches_all;

            const body_id = try self.newBlock();

            if (catch_all) {
                try self.addEdge(test_block, body_id);
                self.seal(test_block, .goto);
                saw_catch_all = true;
            } else if (pattern_matches_all) {
                // `_ if c => ...` (or a guarded binding): the pattern itself
                // can never fail, so testing it would add a
                // `test_block -> next_id` edge that no runtime value could
                // ever take. The guard is the ONLY decision point here,
                // exactly as the three existing backends emit it (their
                // `pattern_matches_all` branch skips the comparison and
                // branches on the guard alone).
                const guard_id = try self.newBlock();
                const next_id = try self.newBlock();
                try self.addEdge(test_block, guard_id);
                self.seal(test_block, .goto);

                self.cur = guard_id;
                try self.lowerExprValue(arm.guard.?);
                if (self.cur) |gc| {
                    try self.addEdge(gc, body_id);
                    try self.addEdge(gc, next_id);
                    self.seal(gc, .branch);
                }
                test_block = next_id;
            } else {
                const next_id = try self.newBlock();
                if (arm.guard) |g| {
                    // The guard gets its own block: it may itself hold
                    // control flow (or, in a later language version, a call
                    // with a visible side effect), and it must run only when
                    // the pattern already matched.
                    const guard_id = try self.newBlock();
                    try self.addEdge(test_block, guard_id);
                    try self.addEdge(test_block, next_id);
                    self.seal(test_block, .branch);

                    self.cur = guard_id;
                    try self.lowerExprValue(g);
                    if (self.cur) |gc| {
                        try self.addEdge(gc, body_id);
                        try self.addEdge(gc, next_id);
                        self.seal(gc, .branch);
                    }
                } else {
                    try self.addEdge(test_block, body_id);
                    try self.addEdge(test_block, next_id);
                    self.seal(test_block, .branch);
                }
                test_block = next_id;
            }

            self.cur = body_id;
            try self.lowerExprValue(arm.body);
            if (self.cur) |c| {
                try self.addEdge(c, join_id);
                self.seal(c, .goto);
            }

            if (catch_all) break;
        }

        // No catch-all arm means some input reaches no arm at runtime. Both
        // the LLVM and MLIR backends panic there (`cell_panic` then
        // `unreachable`), and `test_block` is exactly that fallthrough: it
        // must not become an exit, or a drop pass would try to run cleanup
        // after a call that never returns.
        if (!saw_catch_all) self.seal(test_block, .unreachable_);

        self.cur = self.deadJoinOrLive(join_id);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_span: hir.Span = .{ .start = 0, .end = 0, .line = 0, .column = 0 };

/// No test fixture below needs a real binding table: this module never reads
/// `Fn.bindings`, only `Fn.body`. One shared empty slice avoids re-deriving
/// the `[]Binding` (a mutable slice, so `&.{}` will not coerce to it, the
/// same trap `abi.zig`'s `emptyModule` works around for `Module.structs`).
var no_bindings: [0]hir.Binding = .{};

fn testFn(body: []hir.Stmt) hir.Fn {
    return .{
        .name = "f",
        .symbol = "cell_f",
        .param_count = 0,
        .bindings = &no_bindings,
        .ret = .unit,
        .body = body,
        .is_public = false,
        .span = test_span,
    };
}

fn unitExpr(kind: hir.Expr.Kind) hir.Expr {
    return .{ .ty = .unit, .span = test_span, .kind = kind };
}

fn boolExpr(v: bool) hir.Expr {
    return .{ .ty = .boolean, .span = test_span, .kind = .{ .bool_const = v } };
}

fn intExpr(v: i64) hir.Expr {
    return .{ .ty = .int, .span = test_span, .kind = .{ .int_const = v } };
}

fn letStmt(value: hir.Expr) hir.Stmt {
    return .{ .span = test_span, .kind = .{ .let = .{ .slot = 0, .value = value } } };
}

fn retStmt(value: ?hir.Expr) hir.Stmt {
    return .{ .span = test_span, .kind = .{ .ret = value } };
}

fn exprStmt(e: hir.Expr) hir.Stmt {
    return .{ .span = test_span, .kind = .{ .expr = e } };
}

/// A block-expression wrapping exactly one statement and no tail value,
/// e.g. the `{ break; }` an `if`'s arm needs since `if_expr`'s arms are
/// single expressions, not statement lists.
fn oneStmtBlock(s: *hir.Stmt) hir.Expr {
    return unitExpr(.{ .block = .{ .stmts = s[0..1], .tail = null } });
}

fn findBlock(g: Graph, id: u32) Block {
    for (g.blocks) |b| {
        if (b.id == id) return b;
    }
    unreachable;
}

fn contains(haystack: []const u32, needle: u32) bool {
    for (haystack) |v| {
        if (v == needle) return true;
    }
    return false;
}

/// Rule 2: if `b` is in `a.succs`, then `a` is in `b.preds`, checked in both
/// directions over the whole graph rather than at one hand-picked edge.
fn assertPredsSuccsAgree(g: Graph) !void {
    for (g.blocks) |a| {
        for (a.succs) |succ_id| {
            const succ = findBlock(g, succ_id);
            try std.testing.expect(contains(succ.preds, a.id));
        }
        for (a.preds) |pred_id| {
            const pred = findBlock(g, pred_id);
            try std.testing.expect(contains(pred.succs, a.id));
        }
    }
}

test "a straight-line body is one block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var stmts = [_]hir.Stmt{
        letStmt(intExpr(1)),
        letStmt(intExpr(2)),
        retStmt(null),
    };
    const f = testFn(&stmts);

    const g = (try build(a, &f)).?;
    try std.testing.expectEqual(@as(usize, 1), g.blocks.len);
    try std.testing.expectEqual(Terminator.ret, g.blocks[0].term);
    try std.testing.expectEqual(@as(usize, 1), g.exits.len);
    try std.testing.expectEqual(g.entry, g.exits[0]);
}

test "a straight-line body that falls off the end still terminates, as .ret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var stmts = [_]hir.Stmt{letStmt(intExpr(1))};
    const f = testFn(&stmts);

    const g = (try build(a, &f)).?;
    try std.testing.expectEqual(@as(usize, 1), g.blocks.len);
    try std.testing.expectEqual(Terminator.ret, g.blocks[0].term);
    try std.testing.expect(contains(g.exits, g.entry));
}

test "a bodyless declaration has no graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const f: hir.Fn = .{
        .name = "f",
        .symbol = "cell_f",
        .param_count = 0,
        .bindings = &no_bindings,
        .ret = .unit,
        .body = null,
        .is_public = false,
        .span = test_span,
    };
    try std.testing.expect(try build(a, &f) == null);
}

test "an if with both arms produces a branch and a join" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var then_body = unitExpr(.{ .block = .{ .stmts = &.{}, .tail = null } });
    var else_body = unitExpr(.{ .block = .{ .stmts = &.{}, .tail = null } });
    var cond = boolExpr(true);
    const if_e = unitExpr(.{ .if_expr = .{
        .cond = &cond,
        .then_body = &then_body,
        .else_body = &else_body,
    } });
    var stmts = [_]hir.Stmt{exprStmt(if_e)};
    const f = testFn(&stmts);

    const g = (try build(a, &f)).?;
    try assertPredsSuccsAgree(g);

    const branch = findBlock(g, g.entry);
    try std.testing.expectEqual(Terminator.branch, branch.term);
    try std.testing.expectEqual(@as(usize, 2), branch.succs.len);

    const then_b = findBlock(g, branch.succs[0]);
    const else_b = findBlock(g, branch.succs[1]);
    try std.testing.expectEqual(Terminator.goto, then_b.term);
    try std.testing.expectEqual(Terminator.goto, else_b.term);
    try std.testing.expectEqual(then_b.succs[0], else_b.succs[0]);

    const join = findBlock(g, then_b.succs[0]);
    try std.testing.expectEqual(@as(usize, 2), join.preds.len);
    try std.testing.expectEqual(Terminator.ret, join.term);

    // branch, then, else, join: no block is missing and none is extra.
    try std.testing.expectEqual(@as(usize, 4), g.blocks.len);
}

test "preds and succs agree on a function containing an if inside a while" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var then_body = unitExpr(.{ .block = .{ .stmts = &.{}, .tail = null } });
    var cond2 = boolExpr(false);
    const if_e = unitExpr(.{ .if_expr = .{
        .cond = &cond2,
        .then_body = &then_body,
        .else_body = null,
    } });
    var loop_body = [_]hir.Stmt{exprStmt(if_e)};
    var loop_cond = boolExpr(true);
    var stmts = [_]hir.Stmt{
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = loop_cond, .body = &loop_body } } },
        retStmt(null),
    };
    const f = testFn(&stmts);
    _ = &loop_cond;

    const g = (try build(a, &f)).?;
    try assertPredsSuccsAgree(g);
    // The whole point of this fixture: it must actually have a cycle, or the
    // preds/succs check above is exercising a tree and proves nothing extra
    // over the simpler if-only test.
    var has_back_edge = false;
    for (g.blocks) |b| {
        for (b.succs) |s| {
            if (s < b.id) has_back_edge = true;
        }
    }
    try std.testing.expect(has_back_edge);
}

test "a while produces a back edge from the body's end to the condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var loop_body = [_]hir.Stmt{letStmt(intExpr(1))};
    var loop_cond = boolExpr(true);
    var stmts = [_]hir.Stmt{
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = loop_cond, .body = &loop_body } } },
    };
    const f = testFn(&stmts);
    _ = &loop_cond;

    const g = (try build(a, &f)).?;
    try assertPredsSuccsAgree(g);

    const entry = findBlock(g, g.entry);
    try std.testing.expectEqual(Terminator.goto, entry.term);
    const cond_b = findBlock(g, entry.succs[0]);
    try std.testing.expectEqual(Terminator.branch, cond_b.term);
    try std.testing.expectEqual(@as(usize, 2), cond_b.succs.len);

    const body_b = findBlock(g, cond_b.succs[0]);
    try std.testing.expectEqual(Terminator.goto, body_b.term);
    // The back edge, which is rule 3: the body's end names the condition
    // block as ITS successor, which is what makes this a graph, not a tree.
    try std.testing.expectEqual(cond_b.id, body_b.succs[0]);
    // And the condition block now has two predecessors: the one-time
    // entry, and the repeating back edge from the body.
    try std.testing.expectEqual(@as(usize, 2), cond_b.preds.len);
}

test "break targets the loop exit, continue targets the condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var brk_stmt = hir.Stmt{ .span = test_span, .kind = .brk };
    var cont_stmt = hir.Stmt{ .span = test_span, .kind = .cont };
    var then_body = oneStmtBlock(&brk_stmt);
    var else_body = oneStmtBlock(&cont_stmt);
    var if_cond = boolExpr(true);
    const if_e = unitExpr(.{ .if_expr = .{
        .cond = &if_cond,
        .then_body = &then_body,
        .else_body = &else_body,
    } });
    var loop_body = [_]hir.Stmt{exprStmt(if_e)};
    var loop_cond = boolExpr(true);
    var stmts = [_]hir.Stmt{
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = loop_cond, .body = &loop_body } } },
    };
    const f = testFn(&stmts);
    _ = &loop_cond;

    const g = (try build(a, &f)).?;
    try assertPredsSuccsAgree(g);

    const entry = findBlock(g, g.entry);
    const cond_b = findBlock(g, entry.succs[0]);
    const body_b = findBlock(g, cond_b.succs[0]);
    const exit_b = findBlock(g, cond_b.succs[1]);

    try std.testing.expectEqual(Terminator.branch, body_b.term);
    const then_b = findBlock(g, body_b.succs[0]);
    const else_b = findBlock(g, body_b.succs[1]);

    try std.testing.expectEqual(Terminator.goto, then_b.term);
    try std.testing.expectEqual(exit_b.id, then_b.succs[0]);

    try std.testing.expectEqual(Terminator.goto, else_b.term);
    try std.testing.expectEqual(cond_b.id, else_b.succs[0]);
}

test "a fully-diverging if/else inside a loop leaves the condition block's preds free of the dead join" {
    // Both arms break, so the if's own join is reachable from nowhere: the
    // if never falls through to it. Before `deadJoinOrLive`, `lowerIf`
    // still handed that dead join back as `cur`, and `lowerWhile`'s
    // back-edge check (which only asks "is cur non-null", not "is cur
    // reachable") wired a phantom back edge from it into the condition
    // block, on top of the real edge from the loop's entry.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var brk1 = hir.Stmt{ .span = test_span, .kind = .brk };
    var brk2 = hir.Stmt{ .span = test_span, .kind = .brk };
    var then_body = oneStmtBlock(&brk1);
    var else_body = oneStmtBlock(&brk2);
    var if_cond = boolExpr(true);
    const if_e = unitExpr(.{ .if_expr = .{
        .cond = &if_cond,
        .then_body = &then_body,
        .else_body = &else_body,
    } });
    var loop_body = [_]hir.Stmt{exprStmt(if_e)};
    var loop_cond = boolExpr(true);
    var stmts = [_]hir.Stmt{
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = loop_cond, .body = &loop_body } } },
    };
    const f = testFn(&stmts);
    _ = &loop_cond;

    const g = (try build(a, &f)).?;
    try assertPredsSuccsAgree(g);

    const entry = findBlock(g, g.entry);
    const cond_b = findBlock(g, entry.succs[0]);

    // Every path through the body breaks; nothing loops back. Exactly one
    // predecessor (the loop's one-time entry), never the dead join.
    try std.testing.expectEqual(@as(usize, 1), cond_b.preds.len);
    try std.testing.expectEqual(entry.id, cond_b.preds[0]);

    // The dead join itself: allocated, sealed, unreachable, and excluded
    // from exits, not silently dropped.
    var dead_join: ?Block = null;
    for (g.blocks) |b| {
        if (b.term == .unreachable_ and b.preds.len == 0) dead_join = b;
    }
    try std.testing.expect(dead_join != null);
    try std.testing.expect(!contains(g.exits, dead_join.?.id));
}

test "an early return inside a loop appears in exits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ret_stmt = retStmt(intExpr(1));
    var then_body = oneStmtBlock(&ret_stmt);
    var if_cond = boolExpr(true);
    const if_e = unitExpr(.{ .if_expr = .{
        .cond = &if_cond,
        .then_body = &then_body,
        .else_body = null,
    } });
    var loop_body = [_]hir.Stmt{exprStmt(if_e)};
    var loop_cond = boolExpr(true);
    var stmts = [_]hir.Stmt{
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = loop_cond, .body = &loop_body } } },
        retStmt(null),
    };
    const f = testFn(&stmts);
    _ = &loop_cond;

    const g = (try build(a, &f)).?;
    try assertPredsSuccsAgree(g);

    const entry = findBlock(g, g.entry);
    const cond_b = findBlock(g, entry.succs[0]);
    const body_b = findBlock(g, cond_b.succs[0]);
    // body_b is the if's branch block; its taken (then) successor is the
    // block holding the early return.
    const then_b = findBlock(g, body_b.succs[0]);

    try std.testing.expectEqual(Terminator.ret, then_b.term);
    try std.testing.expect(contains(g.exits, then_b.id));
    // Exactly two exits: the early return, and the implicit one after the
    // loop where the function falls off the end.
    try std.testing.expectEqual(@as(usize, 2), g.exits.len);
}

test "a non-exhaustive match produces an .unreachable_ block that is not in exits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var arm_body = intExpr(1);
    var arms = [_]hir.Arm{
        .{
            .pattern = .{ .kind = .{ .int = 1 }, .span = test_span },
            .guard = null,
            .body = &arm_body,
            .span = test_span,
        },
    };
    var scrutinee = intExpr(0);
    const match_e = unitExpr(.{ .match_expr = .{ .scrutinee = &scrutinee, .arms = &arms } });
    var stmts = [_]hir.Stmt{exprStmt(match_e)};
    const f = testFn(&stmts);

    const g = (try build(a, &f)).?;
    try assertPredsSuccsAgree(g);

    var found_unreachable = false;
    for (g.blocks) |b| {
        if (b.term == .unreachable_) {
            found_unreachable = true;
            try std.testing.expect(!contains(g.exits, b.id));
        }
    }
    try std.testing.expect(found_unreachable);
}

test "a guarded catch-all-looking arm still panics on fallthrough" {
    // `_ if false => ...` matches everything syntactically but the guard can
    // still reject it, so it must NOT suppress the non-exhaustive panic.
    // This is the fact `isDefaultArm` exists to get right in the emitters.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var guard = boolExpr(false);
    var arm_body = intExpr(1);
    var arms = [_]hir.Arm{
        .{
            .pattern = .{ .kind = .wildcard, .span = test_span },
            .guard = &guard,
            .body = &arm_body,
            .span = test_span,
        },
    };
    var scrutinee = intExpr(0);
    const match_e = unitExpr(.{ .match_expr = .{ .scrutinee = &scrutinee, .arms = &arms } });
    var stmts = [_]hir.Stmt{exprStmt(match_e)};
    const f = testFn(&stmts);

    const g = (try build(a, &f)).?;
    try assertPredsSuccsAgree(g);

    var found_unreachable = false;
    for (g.blocks) |b| if (b.term == .unreachable_) {
        found_unreachable = true;
    };
    try std.testing.expect(found_unreachable);
}

test "a guarded catch-all-looking arm is a single decision point, not a phantom pattern-test edge" {
    // `_ if c => ...`: the pattern can never fail, so a naive
    // implementation that still tests it produces a
    // `test_block -> panic_block` edge no runtime value can ever take, on
    // top of the real `guard_block -> panic_block` edge. This checks the
    // test block itself: it must `.goto` straight into the guard, not
    // `.branch` around it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var guard = boolExpr(false);
    var arm_body = intExpr(1);
    var arms = [_]hir.Arm{
        .{
            .pattern = .{ .kind = .wildcard, .span = test_span },
            .guard = &guard,
            .body = &arm_body,
            .span = test_span,
        },
    };
    var scrutinee = intExpr(0);
    const match_e = unitExpr(.{ .match_expr = .{ .scrutinee = &scrutinee, .arms = &arms } });
    var stmts = [_]hir.Stmt{exprStmt(match_e)};
    const f = testFn(&stmts);

    const g = (try build(a, &f)).?;
    try assertPredsSuccsAgree(g);

    // This match is the only statement, so the test block is the entry.
    const test_b = findBlock(g, g.entry);
    try std.testing.expectEqual(Terminator.goto, test_b.term);
    try std.testing.expectEqual(@as(usize, 1), test_b.succs.len);

    const guard_b = findBlock(g, test_b.succs[0]);
    try std.testing.expectEqual(Terminator.branch, guard_b.term);

    var panic: ?Block = null;
    for (g.blocks) |b| if (b.term == .unreachable_) {
        panic = b;
    };
    // The panic block's only predecessor is the guard. A direct edge from
    // the test block (skipping the guard entirely) is exactly the phantom
    // edge this test exists to rule out.
    try std.testing.expectEqual(@as(usize, 1), panic.?.preds.len);
    try std.testing.expectEqual(guard_b.id, panic.?.preds[0]);
}

test "an unguarded catch-all arm removes the panic block entirely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var arm_body = intExpr(1);
    var arms = [_]hir.Arm{
        .{
            .pattern = .{ .kind = .wildcard, .span = test_span },
            .guard = null,
            .body = &arm_body,
            .span = test_span,
        },
    };
    var scrutinee = intExpr(0);
    const match_e = unitExpr(.{ .match_expr = .{ .scrutinee = &scrutinee, .arms = &arms } });
    var stmts = [_]hir.Stmt{exprStmt(match_e)};
    const f = testFn(&stmts);

    const g = (try build(a, &f)).?;
    try assertPredsSuccsAgree(g);

    for (g.blocks) |b| {
        try std.testing.expect(b.term != .unreachable_);
    }
}

test "nested control flow: an if inside a while inside a match arm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var brk_stmt = hir.Stmt{ .span = test_span, .kind = .brk };
    var if_then = oneStmtBlock(&brk_stmt);
    var if_cond = boolExpr(true);
    const if_e = unitExpr(.{ .if_expr = .{
        .cond = &if_cond,
        .then_body = &if_then,
        .else_body = null,
    } });
    var loop_body = [_]hir.Stmt{exprStmt(if_e)};
    var loop_cond = boolExpr(true);
    var arm_stmts = [_]hir.Stmt{
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = loop_cond, .body = &loop_body } } },
    };
    _ = &loop_cond;
    var arm_body = unitExpr(.{ .block = .{ .stmts = &arm_stmts, .tail = null } });

    var arms = [_]hir.Arm{
        .{
            .pattern = .{ .kind = .wildcard, .span = test_span },
            .guard = null,
            .body = &arm_body,
            .span = test_span,
        },
    };
    var scrutinee = intExpr(0);
    const match_e = unitExpr(.{ .match_expr = .{ .scrutinee = &scrutinee, .arms = &arms } });
    var stmts = [_]hir.Stmt{exprStmt(match_e)};
    const f = testFn(&stmts);

    const g = (try build(a, &f)).?;
    try assertPredsSuccsAgree(g);

    var has_back_edge = false;
    for (g.blocks) |b| {
        for (b.succs) |s| {
            if (s < b.id) has_back_edge = true;
        }
    }
    try std.testing.expect(has_back_edge);
    for (g.blocks) |b| {
        try std.testing.expect(b.term != .unreachable_);
    }
}
