//! Statement and block walk, `while` loops, and R2.a's revival and jump clauses.
//! Part of the borrow checker; the rules and their rationale are in the module header of `../borrowck.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const Span = ast.Span;
const bk_model = @import("model.zig");
const bk_root = @import("../borrowck.zig");
const Checker = bk_root.Checker;
const Error = bk_model.Error;
const MovedPath = bk_model.MovedPath;
const AssignLiveness = bk_model.AssignLiveness;
const LoopFrame = bk_model.LoopFrame;
const sameKeys = bk_model.sameKeys;
const containsDead = bk_model.containsDead;

/// Walk `stmts` as a block: one scope, one entry on the open-block stack.
pub fn checkBlockStmts(self: *Checker, stmts: []const ast.Stmt) Error!void {
    try self.pushScope();
    defer self.popScope();
    try self.open_blocks.append(self.allocator, .{ .stmts = stmts, .index = 0 });
    defer _ = self.open_blocks.pop();
    for (stmts, 0..) |*s, i| {
        self.open_blocks.items[self.open_blocks.items.len - 1].index = i;
        try self.checkStmt(s);
    }
    // An empty block declares nothing, so no drop point asks about it,
    // and its slice pointer is not a meaningful key.
    if (stmts.len > 0) {
        try self.recordExit(.block_end, @intFromPtr(stmts.ptr));
        // Expression-position blocks go through checkBlockStmts too
        // (`let copy n = { ... }`); codegen's value-block drop asks this
        // kind. Same key, same liveness as the statement-position end.
        try self.recordExit(.value_block_end, @intFromPtr(stmts.ptr));
    }
}

// ── statements ──────────────────────────────────────────────────────

/// `while cond { ... }`, and OWNERSHIP.md R2.a with it.
///
/// THE PROBLEM A LOOP CREATES. `docs/OWNERSHIP.md` section 0.3 chose
/// lexical loans on the stated ground that they are decidable in a single
/// pass with a scope stack and need no control-flow graph. A loop is a
/// back edge, which breaks that assumption directly:
///
///     var owned buf = make()
///     while c {
///         take(owned buf)     // fine on iteration 1
///     }                       // use-after-move on iteration 2
///
/// The single pass marks `buf` dead once and never revisits it, so nothing
/// catches the second iteration.
///
/// THE RULE, AND WHY THIS SHAPE. A place declared OUTSIDE the loop that is
/// moved INSIDE it and is still dead when the body ends would be read
/// dead on the next iteration. `dead` already tracks exactly that, and
/// R3a already REMOVES a place from `dead` when it is reassigned, so
/// "still dead at the end of the body" is precisely "moved and not
/// revived". No new machinery, and revival keeps working for free.
///
/// EVERY PATH, NOT ONE POINT (2026-09-16). The body end is only one of the
/// points that reach a next iteration or the code after the loop, and
/// checking it alone was a live double free five ways (the table in
/// `docs/OWNERSHIP.md` R2.a). So: a `continue` asks the same question
/// (`checkContinue`); the condition's moves count as loop moves, because
/// `entry_dead` is copied before it; and after the loop `dead` also holds
/// every `break` state (`saveBreakState`) and the failing-condition state,
/// which includes the entry state for a body that runs zero times.
/// "Moved in this loop" is "dead now and not dead on entry", asked of a
/// COPY of the entry state: an index into `dead` is not stable, because
/// `revive` uses `swapRemove`.
///
/// WHERE IT IS CONSERVATIVE, STATED RATHER THAN HIDDEN. A body that always
/// `break`s before reaching the move is rejected anyway, because this does
/// not track which paths reach the end. Likewise a `continue` taken after
/// a move is refused even when the next iteration assigns the place
/// before reading it (`while c { v = "x" \n if d { take(v) \n continue }
/// \n v = "y" }`), by Donald's 2026-09-16 ruling; a later divergence walk
/// may relax it. That is the same trade section 0.3
/// already made, and the same guarantee applies: every program accepted
/// under this rule is still accepted under a real control-flow analysis,
/// so tightening now and relaxing later never breaks source compatibility.
pub fn checkWhile(self: *Checker, stmt: *const ast.Stmt) Error!void {
    const w = stmt.kind.while_stmt;
    const span = stmt.span;
    // Taken before the condition: it runs on every iteration too.
    const liveness_before = self.assign_liveness.items.len;
    const field_liveness_before = self.field_assign_liveness.items.len;
    const exits_before = self.exit_liveness.items.len;
    const moved_before = self.moved_paths.items.len;
    // Taken before the condition, which can declare bindings inside a
    // value block that are as fresh per iteration as the body's own.
    const first_loop_id = self.next_binding_id;
    defer self.invalidateLoopStores(liveness_before, moved_before);
    defer invalidateLoopStoresIn(self.field_assign_liveness.items[field_liveness_before..], self.moved_paths.items[moved_before..]);
    // Errors this loop reports (R2.a, anything in the body). A rejected
    // loop keeps every in-loop exit poisoned, `return`s included.
    const errors_before = self.diagnostics.count(.err);

    // A COPY, not an index: `revive` removes entries with `swapRemove`,
    // so an index into `dead` taken here can end up past a move the body
    // made (the `swap_hide` shape in examples/rejected/skip_revival_jump.cell).
    // Taken before the condition, so a move there counts as a loop move.
    var entry_dead = try self.dead.clone(self.allocator);
    defer entry_dead.deinit(self.allocator);

    try self.checkExpr(@constCast(&w.cond));
    const moved_after_cond = self.moved_paths.items.len;

    // The state the loop leaves through a failing condition: the entry
    // state (a body that runs zero times revives nothing) plus the
    // condition's own moves. A later failing evaluation starts from a
    // back edge, whose outer dead entries are all in `entry_dead` or
    // refused as R2.a below, so this covers it too.
    var cond_dead = try self.dead.clone(self.allocator);
    defer cond_dead.deinit(self.allocator);

    // The frame is pushed after the condition: a jump in a condition's
    // value block is counted by typecheck against the enclosing loop.
    try self.loop_frames.append(self.allocator, .{
        .first_loop_id = first_loop_id,
        .entry = entry_dead.items,
    });
    var frame_popped = false;
    defer if (!frame_popped) {
        var f = self.loop_frames.pop().?;
        f.deinit(self.allocator);
    };

    // checkBlockStmts pushes the scope and the open-block entry, so a
    // binding declared in the body dies with it and a named loan created
    // there is truncated on the way out, exactly as in an `if` body.
    try self.checkBlockStmts(w.body);

    var frame = self.loop_frames.pop().?;
    frame_popped = true;
    defer frame.deinit(self.allocator);

    // Snapshot P_exit BEFORE invalidation poisons the jump bits.
    // Recorded after the poison so `after_loop` is not itself cleared.
    var after_held: std.ArrayListUnmanaged(u32) = .empty;
    defer after_held.deinit(self.allocator);
    for (self.moved_paths.items[moved_before..]) |m| {
        if (m.binding >= first_loop_id) continue;
        if (!self.bindingInCurrentBlock(m.binding)) continue;
        var seen = false;
        for (after_held.items) |h| {
            if (h == m.binding) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        if (!self.afterLoopHolds(m.binding, moved_before, moved_after_cond, exits_before)) continue;
        try after_held.append(self.allocator, m.binding);
    }

    // Skip-revival `break` (2026-09-17). Only when no binding qualified
    // for a plain `after_loop`: a `break` live for one and dead for
    // another cannot both run and skip the releases after the loop.
    var skip_held: std.ArrayListUnmanaged(u32) = .empty;
    defer skip_held.deinit(self.allocator);
    var skip_set: std.ArrayListUnmanaged(usize) = .empty;
    defer skip_set.deinit(self.allocator);
    if (after_held.items.len == 0) {
        try self.collectSkipRevival(&frame, moved_before, moved_after_cond, exits_before, first_loop_id, &skip_held, &skip_set);
    }

    // See `exit_liveness`: the back edge and every `break` can carry a
    // move of an outer binding past the revival the walk saw. A `return`
    // is spared here (2026-09-17): it leaves the function, and in an
    // ACCEPTED loop R2.a makes every iteration start with each carried
    // outer binding holding a value, so the walk's state at the
    // `return` is the state on every iteration. Re-poisoned below if
    // this loop reported an error, because codegen emits C for rejected
    // modules too.
    for (self.moved_paths.items[moved_before..]) |m| {
        if (m.binding >= first_loop_id) continue;
        try self.loop_moved.put(self.allocator, m.binding, {});
        for (self.exit_liveness.items[exits_before..]) |*entry| {
            if (entry.kind == .return_stmt) continue;
            if (entry.binding == m.binding) entry.live = false;
        }
    }

    // Anything still dead that was declared before the loop and was not
    // already dead on entry was moved in the condition or the body and
    // never revived. A move a `continue` already reported is not
    // reported again.
    for (self.dead.items) |d| {
        if (!frame.carries(d)) continue;
        if (containsDead(frame.reported.items, d)) continue;
        try self.diagnostics.err(self.arena.allocator(), d.span, try std.fmt.allocPrint(
            self.arena.allocator(),
            "'{s}' is moved inside a loop, so the next iteration would use it after the move",
            .{d.display},
        ));
        try self.diagnostics.note(self.arena.allocator(), span, try std.fmt.allocPrint(
            self.arena.allocator(),
            "'{s}' is declared outside this loop; assign to it before the end of the body to revive it",
            .{d.display},
        ));
    }

    if (self.diagnostics.count(.err) != errors_before) {
        for (self.moved_paths.items[moved_before..]) |m| {
            if (m.binding >= first_loop_id) continue;
            for (self.exit_liveness.items[exits_before..]) |*entry| {
                if (entry.kind == .return_stmt and entry.binding == m.binding) entry.live = false;
            }
        }
    }

    // The code after the loop is reached from the body end (the walk's
    // `dead`), from every `break`, and from a failing condition. Union
    // the other two in. This comes after `after_held` was computed and
    // after the R2.a report above, so both still read the body-end state:
    // `afterLoopHolds` must not see these entries, and R2.a must not
    // report a `break` move the next iteration never reaches.
    try self.unionDead(frame.break_dead.items);
    for (cond_dead.items) |d| {
        if (d.binding >= first_loop_id) continue;
        if (!containsDead(self.dead.items, d)) try self.dead.append(self.allocator, d);
    }

    // After the poison: only the outer bindings this walk proved still
    // hold a value on every exit from this loop. No record keeps the leak.
    const after_key = @intFromPtr(stmt);
    for (after_held.items) |binding| {
        try self.exit_liveness.append(self.allocator, .{
            .kind = .after_loop,
            .key = after_key,
            .binding = binding,
            .live = true,
        });
    }
    for (skip_held.items) |binding| {
        try self.exit_liveness.append(self.allocator, .{
            .kind = .after_loop_skip,
            .key = after_key,
            .binding = binding,
            .live = true,
        });
    }
    for (skip_set.items) |break_key| {
        try self.skip_breaks.append(self.allocator, .{ .break_key = break_key, .loop_key = after_key });
    }
}

/// The skip-revival rule, read off the walk BEFORE invalidation. A
/// candidate is an outer binding of the current block, moved only as a
/// whole in this loop, not moved by the condition, holding a value at
/// body end, whose every in-loop jump record is live except for this
/// loop's own `break`s. Every candidate must be dead at exactly the same
/// non-empty set of `break`s, so each `break` either skips all the
/// releases or none. Anything else leaves both lists empty (the leak).
pub fn collectSkipRevival(
    self: *const Checker,
    frame: *const LoopFrame,
    moved_before: usize,
    moved_after_cond: usize,
    exits_before: usize,
    first_loop_id: u32,
    held: *std.ArrayListUnmanaged(u32),
    set: *std.ArrayListUnmanaged(usize),
) Error!void {
    var have_set = false;
    for (self.moved_paths.items[moved_before..]) |m| {
        if (m.binding >= first_loop_id) continue;
        if (std.mem.indexOfScalar(u32, held.items, m.binding) != null) continue;
        if (!self.bindingInCurrentBlock(m.binding)) continue;
        for (self.moved_paths.items[moved_before..]) |other| {
            if (other.binding == m.binding and other.path.len != 0) return self.clearSkip(held, set);
        }
        for (self.moved_paths.items[moved_before..moved_after_cond]) |c| {
            if (c.binding == m.binding) return self.clearSkip(held, set);
        }
        for (self.dead.items) |d| {
            if (d.binding == m.binding) return self.clearSkip(held, set);
        }
        var dead_here: std.ArrayListUnmanaged(usize) = .empty;
        defer dead_here.deinit(self.allocator);
        for (self.exit_liveness.items[exits_before..]) |entry| {
            if (entry.kind != .jump or entry.binding != m.binding or entry.live) continue;
            if (std.mem.indexOfScalar(usize, frame.breaks.items, entry.key) == null) return self.clearSkip(held, set);
            if (std.mem.indexOfScalar(usize, dead_here.items, entry.key) == null) {
                try dead_here.append(self.allocator, entry.key);
            }
        }
        if (dead_here.items.len == 0) return self.clearSkip(held, set);
        if (have_set) {
            if (!sameKeys(set.items, dead_here.items)) return self.clearSkip(held, set);
        } else {
            try set.appendSlice(self.allocator, dead_here.items);
            have_set = true;
        }
        try held.append(self.allocator, m.binding);
    }
    // A `break` live for every candidate is an ordinary `break`; one
    // dead for some but not all was refused above by `sameKeys`.
}

pub fn clearSkip(_: *const Checker, held: *std.ArrayListUnmanaged(u32), set: *std.ArrayListUnmanaged(usize)) void {
    held.clearRetainingCapacity();
    set.clearRetainingCapacity();
}

/// True when `binding` was declared in the block that contains the
/// `while` currently being checked. An ancestor's binding (a var
/// outside an enclosing loop, or outside a nested block) is still
/// `< first_loop_id`, and dropping it after THIS loop would free it
/// while the enclosing loop's next iteration still uses it. Missing
/// from the current block => no `after_loop` record => leak.
pub fn bindingInCurrentBlock(self: *const Checker, binding: u32) bool {
    if (self.scopes.items.len == 0) return false;
    const mark = self.scopes.items[self.scopes.items.len - 1].bindings;
    for (self.bindings.items[mark..]) |b| {
        if (b.id == binding) return true;
    }
    return false;
}

/// P_exit for `after_loop`, read off the walk *before* invalidation.
/// All three must hold; a missing or false bit is no record, not a
/// `live = false` entry. Nested-loop jumps in `[exits_before..]` make
/// this stricter (a dead inner `continue` refuses the outer drop).
pub fn afterLoopHolds(
    self: *const Checker,
    binding: u32,
    moved_before: usize,
    moved_after_cond: usize,
    exits_before: usize,
) bool {
    for (self.moved_paths.items[moved_before..moved_after_cond]) |m| {
        if (m.binding == binding) return false;
    }
    for (self.dead.items) |d| {
        if (d.binding == binding) return false;
    }
    for (self.exit_liveness.items[exits_before..]) |entry| {
        if (entry.kind != .jump) continue;
        if (entry.binding != binding) continue;
        if (!entry.live) return false;
    }
    return true;
}

/// The same invalidation for any liveness list: an entry whose binding is
/// moved anywhere in the loop body (ANY path of it, which is conservative
/// in the leak direction for a field store) can no longer vouch.
pub fn invalidateLoopStoresIn(entries: []AssignLiveness, moves: []const MovedPath) void {
    for (entries) |*entry| {
        for (moves) |m| {
            if (m.binding == entry.binding) {
                entry.live = false;
                break;
            }
        }
    }
}

/// A store recorded inside a loop body cannot vouch for its target if
/// that binding is moved anywhere in the same body: the back edge can
/// bring the move to the store. See `assign_liveness`.
pub fn invalidateLoopStores(self: *Checker, liveness_before: usize, moved_before: usize) void {
    for (self.assign_liveness.items[liveness_before..]) |*entry| {
        for (self.moved_paths.items[moved_before..]) |m| {
            if (m.binding == entry.binding) {
                entry.live = false;
                break;
            }
        }
    }
}

/// R2.a at a `continue`: the jump reaches the next iteration, so every
/// move the frame carries is a use-after-move there, exactly as it would
/// be at the end of the body. The body end never sees this path when a
/// revival follows the `continue`.
pub fn checkContinue(self: *Checker, span: Span) Error!void {
    const n = self.loop_frames.items.len;
    // Typecheck refuses a jump outside a loop.
    if (n == 0) return;
    const frame = &self.loop_frames.items[n - 1];
    for (self.dead.items) |d| {
        if (!frame.carries(d)) continue;
        if (containsDead(frame.reported.items, d)) continue;
        try frame.reported.append(self.allocator, d);
        try self.diagnostics.err(self.arena.allocator(), d.span, try std.fmt.allocPrint(
            self.arena.allocator(),
            "'{s}' is moved inside a loop, so the next iteration would use it after the move",
            .{d.display},
        ));
        try self.diagnostics.note(self.arena.allocator(), span, try std.fmt.allocPrint(
            self.arena.allocator(),
            "this 'continue' is reached before '{s}' is assigned again",
            .{d.display},
        ));
    }
}

/// A `break` leaves the loop in the state it was taken in, which the
/// body end never sees when a revival follows it. Every outer dead
/// entry is kept, including one already dead on entry: the `break` path
/// also skips a later revival of that one.
pub fn saveBreakState(self: *Checker) Error!void {
    const n = self.loop_frames.items.len;
    // Typecheck refuses a jump outside a loop.
    if (n == 0) return;
    const frame = &self.loop_frames.items[n - 1];
    for (self.dead.items) |d| {
        if (d.binding >= frame.first_loop_id) continue;
        if (containsDead(frame.break_dead.items, d)) continue;
        try frame.break_dead.append(self.allocator, d);
    }
}

pub fn checkStmt(self: *Checker, stmt: *const ast.Stmt) Error!void {
    try self.checkStmtKind(stmt);
    // After the returned expression is checked, so a place it moves out
    // is dead here and its drop is skipped. See `exit_liveness`.
    if (stmt.kind == .return_stmt) try self.recordExit(.return_stmt, @intFromPtr(stmt));
}

pub fn checkStmtKind(self: *Checker, stmt: *const ast.Stmt) Error!void {
    // R0.3 exception 1: every loan created inside a statement and not
    // bound to a name ends when the statement completes.
    const region = self.temp_loans.items.len;
    defer self.temp_loans.shrinkRetainingCapacity(region);

    switch (stmt.kind) {
        .while_stmt => try self.checkWhile(stmt),
        // A `break` or `continue` moves nothing and borrows nothing, but
        // each is a path the body end never sees. R2.a is asked at a
        // `continue` (the next iteration), and a `break`'s state is
        // unioned into `dead` after the loop. See `checkWhile`.
        .break_stmt => {
            try self.saveBreakState();
            if (self.loop_frames.items.len > 0) {
                const frame = &self.loop_frames.items[self.loop_frames.items.len - 1];
                try frame.breaks.append(self.allocator, @intFromPtr(stmt));
            }
            try self.recordExit(.jump, @intFromPtr(stmt));
        },
        .continue_stmt => {
            try self.checkContinue(stmt.span);
            try self.recordExit(.jump, @intFromPtr(stmt));
        },
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
            if (opt.*) |*ret| {
                // R2.b: a block is opened first, so `v` below is the
                // expression this site really consumes (the block's tail
                // with the block's scope still open), not the block.
                var v: *const ast.Expr = ret;
                var depth: usize = 0;
                defer self.closeBlockTail(depth);
                // R10, the return position, and the second of the two
                // consumption sites the four-position enumeration never
                // asked at. A `-> [Int]` return slot is `owned` by R1, so
                // returning an `arc` source unboxes it and hands the
                // buffer to a caller that frees it while the box's glue
                // frees it again. Today that emission is a loud `cc` type
                // error for a list (`cell_slice_t x = cell_arc_clone(...)`
                // does not compile), which is protection by coincidence of
                // two C types, and R10's own text objects to exactly that.
                // `-> arc T` is untouched: `fresh()` returning its own
                // `arc` local is the legal arc-to-arc case.
                // R10's other direction, the return position. Peeled the
                // same way the owned branch below peels, so a block tail
                // cannot walk around it.
                if (self.fn_return_arc) |fn_name| {
                    // Peeled here, once. Exclusive with the owned branch
                    // below, which peels the same way, so the block's
                    // statements are checked exactly once either way.
                    switch (try self.openBlockTail(ret)) {
                        .not_block => {},
                        .unit => return,
                        .tail => |t| {
                            v = t.expr;
                            depth = t.depth;
                        },
                    }
                    // IMPLEMENTED for one source shape (2026-09-16), the
                    // same one `let arc` takes: a bare `owned` `String` or
                    // list binding returned DIRECTLY (not through a block
                    // tail) is moved into a fresh box. Nothing is refused
                    // or recorded here for it: the R2 move below already
                    // kills every returned place, and the C backend boxes
                    // exactly a place borrowck recorded as wholly moved
                    // (`isMovedOwnedBinding`), so the callee's drop pass
                    // skips it and the caller owns the only reference.
                    // A block tail keeps the refusal: its binding is
                    // scoped to the block, and the box path was not
                    // built or measured for that.
                    const boxable = depth == 0 and try self.boxableOwnedBinding(v) != null;
                    if (!boxable) {
                        if (try self.refuseUnimplementedArcMove(v, "return", "from", "function", fn_name)) return;
                    }
                }
                if (self.fn_return_owned) |fn_name| {
                    switch (try self.openBlockTail(ret)) {
                        .not_block => {},
                        .unit => return,
                        .tail => |t| {
                            v = t.expr;
                            depth = t.depth;
                        },
                    }
                    if (try self.refuseArcUnique(
                        try self.arcUniqueSource(v),
                        "return",
                        "from",
                        "function",
                        fn_name,
                    )) return;
                    // R2.b, the return position, the other live site the
                    // brief did not name. Measured at `0e82266`:
                    // `return match c { 0 => s1, _ => s1 }` from a
                    // `-> String` function was exit 134, the caller and
                    // the callee's scope drop freeing one buffer.
                    switch (try self.ownedMoveSource(v)) {
                        .unknown => |s| {
                            try self.refuseUnknownMove(s, "return", "from", "function", fn_name);
                            return;
                        },
                        // R7, the return position. Measured at `4698dbc`:
                        // an arm binding returned out of a `-> String`
                        // function was exit 134.
                        .aliases_place => |s| {
                            try self.refuseScrutineeAlias(s, "return", "from", "function", fn_name);
                            return;
                        },
                        // A place is moved below, unchanged.
                        .place, .no_owned_place => {},
                    }
                }
                if (try self.placeOf(v)) |place| {
                    const note = try self.msg("'{s}' was moved here by returning it", .{place.display});
                    try self.movePlace(place, note);
                } else {
                    try self.checkExpr(v);
                }
            }
        },
        .assign => |*a| try self.checkAssign(a),
    }
}
