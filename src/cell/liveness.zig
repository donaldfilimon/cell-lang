//! Backward liveness and last-use over one `cfg.Graph`.
//!
//! A LEAF MODULE. It imports `hir` and `cfg` and nothing else. `cfg.zig`
//! builds the shape of the graph (blocks, terminators, the edges a
//! terminator implies) and deliberately does NOT store the statements that
//! ran inside a block. This module is the first consumer: it re-walks the
//! same `hir.Fn` `cfg.build` walked, in the same order, recovering per-block
//! "what happened" (which slots were read, which were written) and pairing
//! that with the graph's successor/predecessor edges to answer two
//! questions:
//!
//!   1. LIVENESS: is a slot's current value still needed by some path
//!      forward from a given point.
//!   2. LAST USE: for a specific read of a slot, is there any path forward
//!      from right after that read which reads the slot again before it is
//!      overwritten or the function ends. If not, this is the slot's last
//!      use along every continuation from here -- the actual deliverable, a
//!      non-lexical loan model and a precise drop pass both need exactly
//!      this query. Liveness is the means to compute it, not the end.
//!
//! WHAT THIS PRODUCES. `analyze` returns a `Result`: `live_in`/`live_out`,
//! one `[]bool` per block (indexed by slot, sized `f.bindings.len`), plus
//! `last_uses`, a flat list of `{block, op_index, slot}` naming every read
//! this module found that is provably dead afterward on every continuing
//! path. `op_index` indexes into the per-block sequence of "ops" (a def or a
//! use of one slot, in the program order this module's walk visits them) --
//! an internal detail of this module's own walk, not a `cfg.Block` field.
//!
//! HOW BLOCKS ARE CORRELATED AGAINST THE HIR. `cfg.zig`'s module doc
//! comment says a consumer that needs to know what ran in a block
//! correlates it against the HIR "by walking the same tree the builder
//! walks, in the same order." This module's `Walker` does exactly that: it
//! mirrors `cfg.Builder`'s control-flow skeleton function-for-function
//! (`walkStmts`/`walkStmt`/`walkExpr`/`walkIf`/`walkMatch`/`walkWhile`,
//! calling its own `newBlock` at the identical points `cfg.Builder.newBlock`
//! is called), so the block ids it assigns land on the same integers
//! `cfg.build` assigned for the same `hir.Fn`. It does NOT rebuild edges
//! (the graph already has them); it only rebuilds "what ran where."
//! `analyze` checks the two block counts agree (`error.GraphMismatch` if
//! not; see that error's own doc comment for why this is a checked error
//! and not a `std.debug.assert`), since a silent drift here would misalign
//! every op list against the wrong `cfg.Block`, and there is no
//! independent way to catch that ourselves once analysis proceeds. This
//! duplication is real (two independent traversals of the same shape can
//! drift if one changes without the other), and it is the price of
//! `cfg.Block` deliberately not storing statements, as documented there.
//! The tests below exercise every branch that traversal can take
//! (straight-line, if with and without else, while with a back edge,
//! break, continue, non-exhaustive match, a fully-diverging if inside a
//! loop) specifically so a drift would be caught here rather than downstream.
//!
//! WHAT THIS DOES NOT CATCH. The block-count check catches a `Walker` that
//! allocates a different NUMBER of blocks than `cfg.build` did. It cannot
//! catch a `Walker` that allocates the same number in a different ORDER
//! (for instance, swapping which of `then_id`/`join_id` is allocated
//! first in `walkIf`): the counts would still agree, so the check would
//! not fire, and every op list would silently point at the wrong block
//! from then on. `cfg.Block` carries no per-block fact (no statement, no
//! source span, nothing) this module could compare against to catch an
//! order drift independently; the only real defense against it is that
//! `Walker`'s allocation order is written to match `cfg.Builder`'s
//! line-for-line, and the tests below would need to break in a way that
//! happens to still assert something true for a silent order-swap to slip
//! through un-noticed here. This is a structural hole, not an oversight
//! this module chose to leave: it belongs to whoever writes the first
//! consumer of `Result`, who will need either a stronger correlation
//! primitive from `cfg.zig` (a per-block token `Walker` and `cfg.Builder`
//! could both stamp and compare) or enough end-to-end testing against
//! real compiled output to catch a wrong answer downstream.
//!
//! WHAT COUNTS AS A DEF OR A USE, AND WHICH FORMS WERE ACTUALLY BUILT.
//! Enumerated exhaustively over `hir.Stmt.Kind` and `hir.Expr.Kind`, not
//! partially:
//!
//!   - `let(slot, value)`: `value` (if present) is walked first, then
//!     `slot` is a def. A `let` with no initializer is still a def (an
//!     uninitialized declaration point), even though nothing currently
//!     parses one.
//!   - `assign(place, value)`: `value` is walked first (matching
//!     `cfg.zig`, which never inspects `place` at all, only `value`). Then:
//!     `place.path.len == 0` (`x = v`, a full overwrite) is a def. A
//!     nonempty path (`x.f = v`) needs `x`'s current value to reach the
//!     field, so it is treated as a USE, not a def: it neither requires nor
//!     produces a prior full value the way a `let` does, and killing
//!     liveness for `x` here would be unsound (a later read of `x` still
//!     needs whatever survived the partial write).
//!   - `ref(slot)`: a use. This is the only place a use comes from.
//!   - every other `Expr.Kind` (`int_const`, `float_const`, `bool_const`,
//!     `string_const`, `unresolved_ref`, `enum_const`, `binary`, `unary`,
//!     `call`, `field`, `struct_lit`, `list_lit`, `block`, `if_expr`,
//!     `match_expr`) carries no def or use of its own; it is walked only to
//!     reach the `ref`s and sub-blocks nested inside it, in the same
//!     sub-expression order `cfg.zig` walks them (left-to-right for
//!     `binary`, callee-then-args for `call`, and so on).
//!   - `Pattern.Kind.binding(slot)` (a match arm's `case x => ...`) is a
//!     def, even though `cfg.zig` never looks at a pattern at all (patterns
//!     carry no control flow, so `cfg.zig` has no reason to). This module
//!     places that def at the start of the arm's body block, matching
//!     where `llvmemit.zig` and `mlirmit.zig` actually store the scrutinee
//!     into the bound slot: after the guard, not before. `typecheck.zig`
//!     rejects a guard on a binding pattern outright ("a guard on a binding
//!     pattern is not implemented yet"), so a checked program never
//!     exercises "guard reads the binding" at all; this module still
//!     defines the slot only at the body regardless, matching the total,
//!     tolerant HIR this module -- like `cfg.zig` -- accepts. No other
//!     `Pattern.Kind` (`wildcard`, `enum_variant`, `int`, `float`, `string`,
//!     `bool`) introduces a slot; that is the whole `Kind` union, so this
//!     is complete, not merely the forms that happened to come to mind.
//!     The `pattern_matches_all` switch below is `else`-armed rather than
//!     compiler-enforced exhaustive, matching `cfg.zig`'s identical switch
//!     exactly: a deliberate choice to keep the two in lockstep rather than
//!     make only this copy safer, since drifting them apart would be its
//!     own source of the same "same shape, quietly diverged" defect this
//!     module already works to avoid elsewhere. If `cfg.zig`'s switch is
//!     ever made exhaustive, change this one the same way in the same
//!     change.
//!   - Parameters are never given an explicit def op. A read of a
//!     parameter before any local def in its function is therefore live-in
//!     to the entry block by construction, which is the correct fact (a
//!     parameter's value exists before the function starts and needs no
//!     def inside it).
//!
//! WHAT THIS MODULE TOLERATES FROM `cfg.zig`'S OWN DOCUMENTED LIMIT.
//! `cfg.zig`'s `deadJoinOrLive` is one-hop: it asks "does this join have
//! any predecessor," not "is that predecessor itself reachable," so a
//! match arm whose GUARD diverges (a guard containing its own `return`,
//! structurally possible even though no surface syntax produces it today)
//! still gets its `body_id` walked and still gets an edge wired from
//! `body_id` into the arm join if the body itself does not diverge --
//! exactly mirroring what `cfg.build` itself does for the same input, edge
//! for edge. This module does not compute its own reachability on top of
//! `cfg.zig`'s; it walks in lockstep with `cfg.Builder`'s unconditional
//! `self.cur = body_id` and lives with the same one-hop limit. The only
//! direction this can err is toward calling a slot live when it is provably
//! dead (an over-approximation): a value that is actually unreachable can
//! never be under-counted as dead by a one-hop predecessor check, only
//! over-counted as live through a phantom edge. That is the safe direction
//! for a drop pass to inherit; this module does not attempt to remove it.
//!
//! WHY THE FIXPOINT TERMINATES. `live_in`/`live_out` are `[]bool` of fixed
//! length (`f.bindings.len`) per block. Each sweep recomputes
//! `live_out[b]` as the union (`or`) of `live_in` over `b`'s successors,
//! then recomputes `live_in[b]` from `live_out[b]` by walking `b`'s ops in
//! reverse (a def clears a bit, a use sets one). Both steps are monotone:
//! turning a bit on in any successor's `live_in` can only turn bits on
//! (never off) in the result, and re-deriving `live_in` from a `live_out`
//! that gained a bit can only gain bits itself (a `.def` on that bit still
//! clears it back to false regardless of the extra bit; a `.use` sets it
//! regardless; if neither op touches it, it passes through unchanged) --
//! see `transferBlock`. So the whole sweep is a monotone map on a lattice
//! bounded above by "every slot live in every block," a finite set with at
//! most `2 * nblocks * nslots` bits. A sweep that changes nothing is a
//! fixpoint; a sweep that changes something can only ever turn bits on, so
//! there are at most that many sweeps before one changes nothing. The loop
//! below is exactly "sweep until a sweep changes nothing."
//!
//! CFG SHAPES THIS MODULE'S FIXPOINT MUST NOT BREAK ON, PER THE TASK BRIEF.
//! A join downstream of two fully-diverging branches gets a real
//! `cfg.Block` with zero predecessors and zero successors (`cfg.zig` never
//! wires an edge into or out of it once its arms diverge). Such a block's
//! `live_in`/`live_out` simply stay `false` forever: nothing ever unions
//! into it (no predecessor reads its `live_in`... rather, no OTHER block
//! has it as a successor, so its `live_in` is never read by anyone), and it
//! has no successors to union from, so it can never itself introduce a
//! change. It is inert, not a special case the fixpoint needs to detect.
//!
//! WHAT THIS PASS DOES NOT DO. It has zero consumers, exactly as `cfg.zig`
//! did before this module. It does not make any drop precise, does not fix
//! any leak, and does not implement non-lexical loans: it computes the
//! dataflow fact both of those need and stops there. A future drop pass
//! would walk the same `hir.Fn` a third time (or extend this module's
//! `Walker` to also record where a scope ends) and consult `last_uses` at
//! each point it is about to keep a value alive past where this module says
//! nothing needs it.

const std = @import("std");
const hir = @import("hir.zig");
const cfg = @import("cfg.zig");

const LivenessError = std.mem.Allocator.Error || error{
    /// `Walker`'s own block count did not match `g.blocks.len`. This can
    /// only mean the correlation described in the module doc comment
    /// failed for this `f`/`g` pair: either `g` was not built from `f` (a
    /// caller error), or `Walker`'s traversal drifted from `cfg.Builder`'s.
    /// Continuing past this would misalign every op list against the
    /// wrong `cfg.Block`, which is silent corruption in the worst
    /// direction this module can produce: a slot that is actually live
    /// could read as dead in the wrong block, and a consumer trusting
    /// that frees a value still needed or ends a loan early. This must
    /// hold in every build mode, including `ReleaseFast`, where a bare
    /// `std.debug.assert` compiles out and an out-of-bounds index into
    /// `w.blocks.items` can read unwritten (but in-capacity) arena memory
    /// that happens to decode as a plausible, empty op list rather than
    /// trapping -- a wrong answer that reads as a pass. See the module doc
    /// comment's "WHAT THIS DOES NOT CATCH" for the residual hole this
    /// check does NOT close (an allocation-order drift that keeps the
    /// same block count).
    GraphMismatch,
};

/// One occurrence of a slot in the op stream: either a definition (the slot
/// now holds a new value) or a use (a read of whatever value the slot
/// currently holds).
const Op = union(enum) {
    def: u32,
    use: u32,
};

/// A read that is provably dead afterward on every path forward from it:
/// the actual deliverable this module exists to compute.
pub const LastUse = struct {
    block: u32,
    /// Position of the read within `block`'s op sequence, in the program
    /// order this module's `Walker` visited them. Meaningful only
    /// alongside the `Result` it came from.
    op_index: u32,
    slot: u32,
};

pub const Result = struct {
    /// Number of slots this analysis covers; every `[]bool` below has this
    /// length. Equal to the `f.bindings.len` passed to `analyze`.
    slot_count: u32,
    /// `live_in[b][s]`: true when block `b` may read slot `s`'s value
    /// before overwriting it, or some successor of `b` needs it live-in.
    /// Indexed by `cfg.Block.id`, which `cfg.build` guarantees equals the
    /// block's index in `cfg.Graph.blocks`.
    live_in: [][]bool,
    /// `live_out[b][s]`: true when some successor of `b` needs slot `s`
    /// live-in.
    live_out: [][]bool,
    /// Every use this module found that is a last use: after it, no path
    /// forward reads that slot again before it is redefined or the
    /// function ends.
    last_uses: []LastUse,
};

/// Build the graph's op-level correlation and run the backward fixpoint.
///
/// `f.body` must be non-null and `g` must be `(try cfg.build(allocator,
/// f)).?` for the same `f`: this function does not rebuild the graph, only
/// the per-block op lists the graph's own type deliberately omits.
///
/// `allocator` should be an arena, matching `cfg.build` and `hir.lower`:
/// nothing here is freed individually.
pub fn analyze(allocator: std.mem.Allocator, f: *const hir.Fn, g: *const cfg.Graph) LivenessError!Result {
    const body = f.body.?;

    var w: Walker = .{ .allocator = allocator };
    const entry = try w.newBlock();
    w.cur = entry;
    try w.walkStmts(body);

    // See the module doc comment and `LivenessError.GraphMismatch`: a
    // silent drift between this walk and `cfg.build`'s own would misalign
    // every op list against the wrong `cfg.Block`, and nothing downstream
    // could detect that on its own. This was a `std.debug.assert` until
    // review demonstrated it compiles out in `ReleaseFast`: a
    // deliberately-broken walk (one fewer block than `cfg.build` for an
    // `if`/`else`) still exited 0 with every test green, because the
    // out-of-bounds read this mismatch enables landed inside the
    // `ArrayList`'s spare capacity on unwritten arena memory that happened
    // to decode as an empty op list -- which is what an empty else-arm's
    // op list should look like anyway, so the wrong answer was
    // accidentally right. An error return holds in every build mode,
    // matching the fix `74f8e63` made to the same defect class in the
    // drop pass.
    if (w.blocks.items.len != g.blocks.len) return error.GraphMismatch;

    const nblocks = g.blocks.len;
    const nslots = f.bindings.len;

    const live_in = try allocator.alloc([]bool, nblocks);
    const live_out = try allocator.alloc([]bool, nblocks);
    for (0..nblocks) |i| {
        live_in[i] = try allocator.alloc(bool, nslots);
        live_out[i] = try allocator.alloc(bool, nslots);
        @memset(live_in[i], false);
        @memset(live_out[i], false);
    }

    const scratch_out = try allocator.alloc(bool, nslots);
    const scratch_in = try allocator.alloc(bool, nslots);

    // The fixpoint. See the module doc comment for why this halts.
    var changed = true;
    while (changed) {
        changed = false;
        for (g.blocks, 0..) |blk, i| {
            @memset(scratch_out, false);
            for (blk.succs) |s| {
                for (0..nslots) |slot| {
                    if (live_in[s][slot]) scratch_out[slot] = true;
                }
            }
            if (!std.mem.eql(bool, scratch_out, live_out[i])) {
                changed = true;
                @memcpy(live_out[i], scratch_out);
            }

            transferBlock(w.blocks.items[i].items, live_out[i], scratch_in);
            if (!std.mem.eql(bool, scratch_in, live_in[i])) {
                changed = true;
                @memcpy(live_in[i], scratch_in);
            }
        }
    }

    // Second pass: last uses. Walk each block's ops in reverse ONE more
    // time, from its now-final `live_out`, recording every use found live
    // (nothing later needs the slot) at the moment just before this use
    // sets it. `scratch_in` is reused as per-block scratch; nothing here
    // depends on its value entering this loop.
    var last_uses: std.ArrayList(LastUse) = .empty;
    for (g.blocks, 0..) |_, i| {
        const ops = w.blocks.items[i].items;
        @memcpy(scratch_in, live_out[i]);
        var j = ops.len;
        while (j > 0) {
            j -= 1;
            switch (ops[j]) {
                .def => |s| scratch_in[s] = false,
                .use => |s| {
                    if (!scratch_in[s]) {
                        try last_uses.append(allocator, .{
                            .block = @intCast(i),
                            .op_index = @intCast(j),
                            .slot = s,
                        });
                    }
                    scratch_in[s] = true;
                },
            }
        }
    }

    return Result{
        .slot_count = @intCast(nslots),
        .live_in = live_in,
        .live_out = live_out,
        .last_uses = last_uses.items,
    };
}

/// Derives `out_live_in` from `live_out` by walking `ops` in reverse: a def
/// clears the slot's bit (nothing before it in this block needs the value
/// a later read might have seen), a use sets it (something here needs
/// whatever value is current). See the module doc comment for why this
/// makes the whole per-block step monotone.
fn transferBlock(ops: []const Op, live_out: []const bool, out_live_in: []bool) void {
    @memcpy(out_live_in, live_out);
    var i = ops.len;
    while (i > 0) {
        i -= 1;
        switch (ops[i]) {
            .def => |s| out_live_in[s] = false,
            .use => |s| out_live_in[s] = true,
        }
    }
}

// ---------------------------------------------------------------------------
// The walker
// ---------------------------------------------------------------------------

/// Mirrors `cfg.Builder`'s control-flow skeleton exactly (same functions,
/// same order of `newBlock` calls), but records ops instead of edges, and
/// tracks "did this if/match's join actually get reached" with a plain
/// boolean instead of predecessor counts, since op-list correlation never
/// needs predecessor sets. See the module doc comment.
const Walker = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(std.ArrayList(Op)) = .empty,
    /// The block currently open, or null when the path reaching here has
    /// already diverged and nothing reachable follows until the next
    /// merge point. Same meaning as `cfg.Builder.cur`.
    cur: ?u32 = null,
    /// Depth of enclosing `while` loops, mirroring the assertion
    /// `cfg.Builder.lowerJump` makes (a fixture violating this is a bug in
    /// the fixture, not a case to handle silently). This module does not
    /// need loop target ids (a jump produces no op; it only ends the
    /// current path), so it tracks depth alone rather than the
    /// `cond`/`exit` pair `cfg.Builder.LoopCtx` carries.
    loop_depth: u32 = 0,

    fn newBlock(self: *Walker) LivenessError!u32 {
        const id: u32 = @intCast(self.blocks.items.len);
        try self.blocks.append(self.allocator, .empty);
        return id;
    }

    fn addOp(self: *Walker, block: u32, op: Op) LivenessError!void {
        try self.blocks.items[block].append(self.allocator, op);
    }

    fn walkStmts(self: *Walker, stmts: []const hir.Stmt) LivenessError!void {
        for (stmts) |stmt| {
            if (self.cur == null) return;
            try self.walkStmt(stmt);
        }
    }

    fn walkStmt(self: *Walker, stmt: hir.Stmt) LivenessError!void {
        switch (stmt.kind) {
            .let => |l| {
                if (l.value) |v| try self.walkExpr(&v);
                if (self.cur) |c| try self.addOp(c, .{ .def = l.slot });
            },
            .assign => |a| {
                try self.walkExpr(&a.value);
                if (self.cur) |c| {
                    if (a.place.path.len == 0) {
                        try self.addOp(c, .{ .def = a.place.slot });
                    } else {
                        try self.addOp(c, .{ .use = a.place.slot });
                    }
                }
            },
            .expr => |e| try self.walkExpr(&e),
            .ret => |maybe| {
                if (maybe) |e| try self.walkExpr(&e);
                self.cur = null;
            },
            .while_loop => |w| try self.walkWhile(w),
            .brk => self.jump(),
            .cont => self.jump(),
        }
    }

    fn jump(self: *Walker) void {
        if (self.cur == null) return;
        std.debug.assert(self.loop_depth > 0);
        self.cur = null;
    }

    fn walkWhile(self: *Walker, w: anytype) LivenessError!void {
        if (self.cur == null) return;

        const cond_id = try self.newBlock();
        self.cur = cond_id;
        try self.walkExpr(&w.cond);
        if (self.cur == null) return;

        const body_id = try self.newBlock();
        const exit_id = try self.newBlock();

        self.loop_depth += 1;
        self.cur = body_id;
        try self.walkStmts(w.body);
        self.loop_depth -= 1;

        // Whatever the body ended on (or diverged into) is irrelevant to
        // what runs next: a while's normal continuation is always the
        // condition's false edge, matching `cfg.Builder.lowerWhile`
        // unconditionally setting `self.cur = exit_id` at the end.
        self.cur = exit_id;
    }

    fn walkExpr(self: *Walker, e: *const hir.Expr) LivenessError!void {
        if (self.cur == null) return;
        switch (e.kind) {
            .block => |bl| try self.walkBlock(bl),
            .if_expr => |ie| try self.walkIf(ie),
            .match_expr => |me| try self.walkMatch(me),
            .binary => |bin| {
                try self.walkExpr(bin.left);
                try self.walkExpr(bin.right);
            },
            .unary => |u| try self.walkExpr(u.operand),
            .call => |c| {
                try self.walkExpr(c.callee);
                for (c.args) |*a| try self.walkExpr(a);
            },
            .field => |f| try self.walkExpr(f.base),
            .struct_lit => |sl| for (sl.fields) |*fv| try self.walkExpr(fv),
            .list_lit => |elems| for (elems) |*el| try self.walkExpr(el),
            .ref => |slot| try self.addOp(self.cur.?, .{ .use = slot }),
            .int_const,
            .float_const,
            .bool_const,
            .string_const,
            .unresolved_ref,
            .enum_const,
            => {},
        }
    }

    fn walkBlock(self: *Walker, bl: anytype) LivenessError!void {
        try self.walkStmts(bl.stmts);
        if (self.cur != null) {
            if (bl.tail) |t| try self.walkExpr(t);
        }
    }

    fn walkIf(self: *Walker, ie: anytype) LivenessError!void {
        try self.walkExpr(ie.cond);
        if (self.cur == null) return;

        const then_id = try self.newBlock();
        const join_id = try self.newBlock();
        const else_id: u32 = if (ie.else_body != null) try self.newBlock() else join_id;

        // Mirrors `cfg.Builder.deadJoinOrLive`: with no else, the
        // not-taken edge IS the join (`else_id == join_id`), wired
        // unconditionally regardless of whether the then-arm diverges, so
        // the join is reachable from the start in that case.
        var join_reachable = ie.else_body == null;

        self.cur = then_id;
        try self.walkExpr(ie.then_body);
        if (self.cur != null) join_reachable = true;

        if (ie.else_body) |eb| {
            self.cur = else_id;
            try self.walkExpr(eb);
            if (self.cur != null) join_reachable = true;
        }

        self.cur = if (join_reachable) join_id else null;
    }

    fn walkMatch(self: *Walker, me: anytype) LivenessError!void {
        try self.walkExpr(me.scrutinee);
        if (self.cur == null) return;

        const join_id = try self.newBlock();
        var join_reachable = false;

        for (me.arms) |arm| {
            const pattern_matches_all = switch (arm.pattern.kind) {
                .wildcard, .binding => true,
                else => false,
            };
            const catch_all = arm.guard == null and pattern_matches_all;

            const body_id = try self.newBlock();

            if (catch_all) {
                // No test, no guard: the pattern can never fail and there
                // is no guard to run first.
            } else if (pattern_matches_all) {
                // `_ if c => ...` (or a guarded binding pattern, which
                // `typecheck.zig` rejects but this module, like `cfg.zig`,
                // is total over): the guard is the only decision point.
                const guard_id = try self.newBlock();
                _ = try self.newBlock(); // next_id: a pure test point, never itself the site of an op.
                self.cur = guard_id;
                try self.walkExpr(arm.guard.?);
            } else {
                _ = try self.newBlock(); // next_id
                if (arm.guard) |g| {
                    const guard_id = try self.newBlock();
                    self.cur = guard_id;
                    try self.walkExpr(g);
                }
            }

            // Unconditional, matching `cfg.Builder.lowerMatch` exactly:
            // `arm.body` is walked into `body_id` even when the guard just
            // diverged and no edge was ever wired into `body_id` in the
            // real graph. See "WHAT THIS MODULE TOLERATES" above.
            self.cur = body_id;
            if (arm.pattern.kind == .binding) {
                try self.addOp(body_id, .{ .def = arm.pattern.kind.binding });
            }
            try self.walkExpr(arm.body);
            if (self.cur != null) join_reachable = true;

            if (catch_all) break;
        }

        self.cur = if (join_reachable) join_id else null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_span: hir.Span = .{ .start = 0, .end = 0, .line = 0, .column = 0 };

var no_fieldsels: [0]hir.FieldSel = .{};

fn dummyBinding(slot: u32) hir.Binding {
    return .{
        .name = "s",
        .ty = .int,
        .ownership = .owned,
        .mutable = true,
        .is_param = false,
        .slot = slot,
    };
}

fn testFn(body: []hir.Stmt, bindings: []hir.Binding) hir.Fn {
    return .{
        .name = "f",
        .symbol = "cell_f",
        .param_count = 0,
        .bindings = bindings,
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

fn refExpr(slot: u32) hir.Expr {
    return .{ .ty = .int, .span = test_span, .kind = .{ .ref = slot } };
}

fn letStmt(slot: u32, value: ?hir.Expr) hir.Stmt {
    return .{ .span = test_span, .kind = .{ .let = .{ .slot = slot, .value = value } } };
}

fn assignStmt(slot: u32, value: hir.Expr) hir.Stmt {
    return .{ .span = test_span, .kind = .{ .assign = .{
        .place = .{ .slot = slot, .path = &no_fieldsels, .ty = .int },
        .value = value,
    } } };
}

fn retStmt(value: ?hir.Expr) hir.Stmt {
    return .{ .span = test_span, .kind = .{ .ret = value } };
}

fn exprStmt(e: hir.Expr) hir.Stmt {
    return .{ .span = test_span, .kind = .{ .expr = e } };
}

/// A block-expression wrapping exactly one statement and no tail value,
/// matching `cfg.zig`'s own `oneStmtBlock` helper.
fn oneStmtBlock(s: *hir.Stmt) hir.Expr {
    return unitExpr(.{ .block = .{ .stmts = s[0..1], .tail = null } });
}

fn findBlock(g: cfg.Graph, id: u32) cfg.Block {
    for (g.blocks) |b| {
        if (b.id == id) return b;
    }
    unreachable;
}

fn allFalse(v: []const bool) bool {
    for (v) |x| if (x) return false;
    return true;
}

fn hasLastUse(last_uses: []const LastUse, block: u32, slot: u32) bool {
    for (last_uses) |lu| {
        if (lu.block == block and lu.slot == slot) return true;
    }
    return false;
}

test "straight-line: a slot written then read has its last use at the read, and is dead after" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = [_]hir.Binding{ dummyBinding(0), dummyBinding(1) };
    var stmts = [_]hir.Stmt{
        letStmt(0, intExpr(1)),
        letStmt(1, refExpr(0)),
        retStmt(refExpr(1)),
    };
    const f = testFn(&stmts, &bindings);

    const g = (try cfg.build(a, &f)).?;
    const r = try analyze(a, &f, &g);

    try std.testing.expectEqual(@as(usize, 1), g.blocks.len);
    // Both slots are defined and used entirely inside the one block, so
    // nothing is live crossing its boundary.
    try std.testing.expect(allFalse(r.live_in[0]));
    try std.testing.expect(allFalse(r.live_out[0]));

    // Exactly two last uses: the read of slot 0 (feeding slot 1's let) and
    // the read of slot 1 (the return). Nothing else reads anything.
    try std.testing.expectEqual(@as(usize, 2), r.last_uses.len);
    try std.testing.expect(hasLastUse(r.last_uses, 0, 0));
    try std.testing.expect(hasLastUse(r.last_uses, 0, 1));
}

test "a slot live across an if, read only in one branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = [_]hir.Binding{dummyBinding(0)};

    var then_stmts = [_]hir.Stmt{exprStmt(refExpr(0))};
    var then_body = unitExpr(.{ .block = .{ .stmts = &then_stmts, .tail = null } });
    var else_body = unitExpr(.{ .block = .{ .stmts = &.{}, .tail = null } });
    var cond = boolExpr(true);
    const if_e = unitExpr(.{ .if_expr = .{
        .cond = &cond,
        .then_body = &then_body,
        .else_body = &else_body,
    } });
    var stmts = [_]hir.Stmt{
        letStmt(0, intExpr(1)),
        exprStmt(if_e),
    };
    const f = testFn(&stmts, &bindings);

    const g = (try cfg.build(a, &f)).?;
    const r = try analyze(a, &f, &g);

    const entry = findBlock(g, g.entry);
    try std.testing.expectEqual(cfg.Terminator.branch, entry.term);
    const then_b = findBlock(g, entry.succs[0]);
    const else_b = findBlock(g, entry.succs[1]);
    try std.testing.expectEqual(then_b.succs[0], else_b.succs[0]);
    const join = findBlock(g, then_b.succs[0]);

    // The read is upward-exposed in the then block: live-in there, and
    // that is a last use (nothing after it reads slot 0 again).
    try std.testing.expect(r.live_in[then_b.id][0]);
    try std.testing.expect(hasLastUse(r.last_uses, then_b.id, 0));
    // Not read in the else arm or the join.
    try std.testing.expect(!r.live_in[else_b.id][0]);
    try std.testing.expect(!r.live_in[join.id][0]);
    // The entry must still keep it live going into the branch: at least
    // one successor (then) needs it, and liveness at a branch point is the
    // union over successors, the safe direction.
    try std.testing.expect(r.live_out[entry.id][0]);
}

test "an if with no else at all still reaches what follows it, through the implicit not-taken edge" {
    // Every other if-shaped test above gives BOTH arms, so the no-else
    // shape (`else_id == join_id`, wired unconditionally regardless of
    // whether the then-arm diverges) was untested until this test:
    // exactly the "enumerated some forms, asserted all" trap this
    // repository has already found elsewhere. The then-arm here diverges
    // (an early return), and there is no else at all, so the statement
    // after the if is reached only through the implicit not-taken edge.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = [_]hir.Binding{dummyBinding(0)};

    var ret_stmt = retStmt(null);
    var then_body = oneStmtBlock(&ret_stmt);
    var if_cond = boolExpr(true);
    const if_e = unitExpr(.{ .if_expr = .{
        .cond = &if_cond,
        .then_body = &then_body,
        .else_body = null,
    } });
    var stmts = [_]hir.Stmt{
        letStmt(0, intExpr(1)),
        exprStmt(if_e),
        retStmt(refExpr(0)),
    };
    const f = testFn(&stmts, &bindings);

    const g = (try cfg.build(a, &f)).?;
    const r = try analyze(a, &f, &g);

    const entry = findBlock(g, g.entry);
    const then_b = findBlock(g, entry.succs[0]);
    const join = findBlock(g, entry.succs[1]); // no else: not-taken IS the join
    try std.testing.expectEqual(cfg.Terminator.ret, then_b.term);

    // The trailing return lands in the join block and reads slot 0 there.
    try std.testing.expect(r.live_in[join.id][0]);
    try std.testing.expect(hasLastUse(r.last_uses, join.id, 0));
    // The diverging then-arm never reads it.
    try std.testing.expect(allFalse(r.live_in[then_b.id]));
    // Entry must keep it live out, since the not-taken path needs it even
    // though the taken path (then) does not.
    try std.testing.expect(r.live_out[entry.id][0]);
}

test "a back edge: a slot read at the top of a while body and written at the bottom is live across the whole loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = [_]hir.Binding{dummyBinding(0)};

    var loop_body = [_]hir.Stmt{
        exprStmt(refExpr(0)),
        assignStmt(0, intExpr(2)),
    };
    var loop_cond = boolExpr(true);
    var stmts = [_]hir.Stmt{
        letStmt(0, intExpr(1)),
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = loop_cond, .body = &loop_body } } },
    };
    const f = testFn(&stmts, &bindings);
    _ = &loop_cond;

    const g = (try cfg.build(a, &f)).?;
    const r = try analyze(a, &f, &g);

    const entry = findBlock(g, g.entry);
    const cond_b = findBlock(g, entry.succs[0]);
    const body_b = findBlock(g, cond_b.succs[0]);
    const exit_b = findBlock(g, cond_b.succs[1]);

    // Live from the moment it is defined in entry, all the way around the
    // back edge into the condition test, and into the body again.
    try std.testing.expect(r.live_out[entry.id][0]);
    try std.testing.expect(r.live_in[cond_b.id][0]);
    try std.testing.expect(r.live_in[body_b.id][0]);
    try std.testing.expect(r.live_out[body_b.id][0]);
    // Nothing after the loop reads it.
    try std.testing.expect(!r.live_in[exit_b.id][0]);
    try std.testing.expect(!r.live_out[exit_b.id][0]);
}

test "break and continue: liveness reaches the loop exit through both" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = [_]hir.Binding{dummyBinding(0)};

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
        letStmt(0, intExpr(1)),
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = loop_cond, .body = &loop_body } } },
        retStmt(refExpr(0)),
    };
    const f = testFn(&stmts, &bindings);
    _ = &loop_cond;

    const g = (try cfg.build(a, &f)).?;
    const r = try analyze(a, &f, &g);

    const entry = findBlock(g, g.entry);
    const cond_b = findBlock(g, entry.succs[0]);
    const body_b = findBlock(g, cond_b.succs[0]);
    const exit_b = findBlock(g, cond_b.succs[1]);
    const then_b = findBlock(g, body_b.succs[0]); // break
    const else_b = findBlock(g, body_b.succs[1]); // continue

    // The slot is read only after the loop (the trailing return), reached
    // via the break's target (exit) and, on the next lap, via continue's
    // target (cond) and back around. It must be live through the whole
    // loop, including the branch that dispatches break vs continue.
    try std.testing.expect(r.live_in[exit_b.id][0]);
    try std.testing.expect(r.live_out[then_b.id][0]); // break target is live
    try std.testing.expect(r.live_out[else_b.id][0]); // continue target is live
    try std.testing.expect(r.live_out[body_b.id][0]);
    try std.testing.expect(r.live_in[cond_b.id][0]);
    try std.testing.expect(r.live_out[entry.id][0]);
    // The read after the loop is the last use.
    try std.testing.expect(hasLastUse(r.last_uses, exit_b.id, 0));
}

test "a slot dead before a return on one path and live on another" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = [_]hir.Binding{dummyBinding(0)};

    var ret_stmt = retStmt(null);
    var then_body = oneStmtBlock(&ret_stmt);
    var else_stmt = exprStmt(refExpr(0));
    var else_body = oneStmtBlock(&else_stmt);
    var if_cond = boolExpr(true);
    const if_e = unitExpr(.{ .if_expr = .{
        .cond = &if_cond,
        .then_body = &then_body,
        .else_body = &else_body,
    } });
    var stmts = [_]hir.Stmt{
        letStmt(0, intExpr(1)),
        exprStmt(if_e),
        retStmt(null),
    };
    const f = testFn(&stmts, &bindings);

    const g = (try cfg.build(a, &f)).?;
    const r = try analyze(a, &f, &g);

    const entry = findBlock(g, g.entry);
    const then_b = findBlock(g, entry.succs[0]);
    const else_b = findBlock(g, entry.succs[1]);

    try std.testing.expectEqual(cfg.Terminator.ret, then_b.term);
    // Dead immediately in the returning arm: it never reads slot 0.
    try std.testing.expect(allFalse(r.live_in[then_b.id]));
    try std.testing.expect(allFalse(r.live_out[then_b.id]));
    // Live in the other arm, which does read it.
    try std.testing.expect(r.live_in[else_b.id][0]);
    // The branch point must still carry it, since AT LEAST ONE successor
    // needs it: the union over successors is the safe direction, even
    // though the other successor (then) does not need it at all.
    try std.testing.expect(r.live_out[entry.id][0]);
}

test "the zero-predecessor join shape does not destabilize the fixpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = [_]hir.Binding{dummyBinding(0)};

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
        letStmt(0, intExpr(1)),
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = loop_cond, .body = &loop_body } } },
        retStmt(refExpr(0)),
    };
    const f = testFn(&stmts, &bindings);
    _ = &loop_cond;

    const g = (try cfg.build(a, &f)).?;
    const r = try analyze(a, &f, &g);

    const entry = findBlock(g, g.entry);
    const cond_b = findBlock(g, entry.succs[0]);
    const exit_b = findBlock(g, cond_b.succs[1]);

    // The dead join: allocated, unreachable, zero predecessors (same shape
    // `cfg.zig`'s own test asserts).
    var dead_join: ?cfg.Block = null;
    for (g.blocks) |b| {
        if (b.term == .unreachable_ and b.preds.len == 0) dead_join = b;
    }
    try std.testing.expect(dead_join != null);

    // It never affects anyone else's fixpoint: both its own sets stay
    // empty, and the read after the loop (reached only via the two break
    // edges, not through the dead join) is still correctly live all the
    // way back to entry.
    try std.testing.expect(allFalse(r.live_in[dead_join.?.id]));
    try std.testing.expect(allFalse(r.live_out[dead_join.?.id]));
    try std.testing.expect(r.live_in[exit_b.id][0]);
    try std.testing.expect(r.live_out[entry.id][0]);
}

test "a match arm's binding pattern is a def at the start of its body, not before" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // slot 0: the scrutinee source. slot 1: the arm's binding pattern.
    var bindings = [_]hir.Binding{ dummyBinding(0), dummyBinding(1) };

    var arm_body = refExpr(1);
    var arms = [_]hir.Arm{
        .{
            .pattern = .{ .kind = .{ .binding = 1 }, .span = test_span },
            .guard = null,
            .body = &arm_body,
            .span = test_span,
        },
    };
    var scrutinee = refExpr(0);
    const match_e = unitExpr(.{ .match_expr = .{ .scrutinee = &scrutinee, .arms = &arms } });
    var stmts = [_]hir.Stmt{
        letStmt(0, intExpr(1)),
        retStmt(match_e),
    };
    const f = testFn(&stmts, &bindings);

    const g = (try cfg.build(a, &f)).?;
    const r = try analyze(a, &f, &g);

    const entry = findBlock(g, g.entry);
    // A single unguarded binding arm is a catch-all: no test/guard block,
    // scrutinee evaluated in entry, body reached directly. Three blocks:
    // entry, the match's join, and the arm body.
    try std.testing.expectEqual(@as(usize, 3), g.blocks.len);
    const body_b = findBlock(g, entry.succs[0]);

    // Slot 1 (the binding) is defined and read entirely inside the body:
    // never live-in to entry. Slot 0 (the scrutinee) is read by
    // `me.scrutinee` itself, which this module's walk records into entry
    // (the block open when `walkMatch` starts, before any new block is
    // allocated), so it is a last use right there and dead going out.
    try std.testing.expect(!r.live_in[entry.id][1]);
    try std.testing.expect(!r.live_out[entry.id][1]);
    try std.testing.expect(!r.live_out[entry.id][0]);
    try std.testing.expect(hasLastUse(r.last_uses, entry.id, 0));

    // Slot 1's read in the body is a last use, and slot 1 is dead going
    // into the body (it is defined there, not received from entry).
    try std.testing.expect(!r.live_in[body_b.id][1]);
    try std.testing.expect(hasLastUse(r.last_uses, body_b.id, 1));
}

test "analyze returns error.GraphMismatch rather than silently misaligning op lists" {
    // `g` must be `cfg.build`'s own graph for the SAME `f` passed to
    // `analyze` (see `analyze`'s doc comment). This deliberately violates
    // that contract the way a caller could by accident -- pairing a
    // one-block straight-line graph with a four-block if/else function --
    // to reach `error.GraphMismatch` through a real call rather than by
    // sabotaging `Walker` internally. See the module doc comment's
    // `LivenessError.GraphMismatch` for why this must be a checked error
    // in every build mode rather than a `std.debug.assert`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var small_bindings = [_]hir.Binding{};
    var small_stmts = [_]hir.Stmt{retStmt(null)};
    const f_small = testFn(&small_stmts, &small_bindings);
    const g_small = (try cfg.build(a, &f_small)).?;
    try std.testing.expectEqual(@as(usize, 1), g_small.blocks.len);

    var big_bindings = [_]hir.Binding{dummyBinding(0)};
    var then_body = unitExpr(.{ .block = .{ .stmts = &.{}, .tail = null } });
    var else_body = unitExpr(.{ .block = .{ .stmts = &.{}, .tail = null } });
    var cond = boolExpr(true);
    const if_e = unitExpr(.{ .if_expr = .{
        .cond = &cond,
        .then_body = &then_body,
        .else_body = &else_body,
    } });
    var big_stmts = [_]hir.Stmt{exprStmt(if_e)};
    const f_big = testFn(&big_stmts, &big_bindings);
    const g_big = (try cfg.build(a, &f_big)).?;
    try std.testing.expectEqual(@as(usize, 4), g_big.blocks.len);

    // f_big walked against g_small: 4 real blocks vs. a 1-block graph.
    try std.testing.expectError(error.GraphMismatch, analyze(a, &f_big, &g_small));
}
