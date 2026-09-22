//! Statement lowering: statement lists, assignment, `if`, and `match`.
//! Part of the C backend; the rules and their rationale are in the module header of `../codegen.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const cg_helpers = @import("helpers.zig");
const cg_model = @import("model.zig");
const cg_root = @import("../codegen.zig");
const Generator = cg_root.Generator;
const EmitError = cg_root.EmitError;
const CType = cg_model.CType;
const Dest = cg_model.Dest;
const scrutineeTempRead = cg_helpers.scrutineeTempRead;
const isDefaultArm = cg_helpers.isDefaultArm;
const isDefaultPattern = cg_helpers.isDefaultPattern;
const unwrapAnnotated = cg_helpers.unwrapAnnotated;
const isOwningOptional = cg_helpers.isOwningOptional;
const ownsTempScrutinee = cg_helpers.ownsTempScrutinee;
const resultOkOwning = cg_helpers.resultOkOwning;
const resultErrOwning = cg_helpers.resultErrOwning;
const armDiverges = cg_helpers.armDiverges;
const endsInJump = cg_helpers.endsInJump;
const Exit = cg_helpers.Exit;
const blockExit = cg_helpers.blockExit;
const branchKey = cg_helpers.branchKey;
const exprUses = cg_helpers.exprUses;
const stmtsUse = cg_helpers.stmtsUse;

// ── statements ──────────────────────────────────────────────────────

/// A statement-position block: a `while` body, a bare `{ }`, an `if`
/// branch, or a `match` arm body reached through `emitEffect`. This is
/// the BLOCK-SCOPE drop point (OWNERSHIP.md R11 row 4, closed
/// 2026-09-15): on normal exit, every droppable local declared since
/// `mark` is released here, in reverse order, at this block's own
/// indent. A block that ends in a jump emits nothing, because the jump
/// already did it: a `return` drops everything visible through
/// `pendingDrops`, and a `break`/`continue` drops the loop's scopes
/// through `emitLoopExitDrops`.
///
/// Value-position blocks are NOT this function: `emitValueInto` owns
/// them with its own mark and does not release their locals, because a
/// block-local place can flow out as the block's value and the
/// conversion into the destination is what decides whether that flow
/// retains. That residual is pinned by a test rather than described.
pub fn emitStmts(self: *Generator, stmts: []const ast.Stmt, indent: usize) EmitError!void {
    const mark = self.locals.items.len;
    defer self.locals.shrinkRetainingCapacity(mark);
    const saved = self.current_after;
    self.current_after = blockExit(stmts);
    defer self.current_after = saved;
    for (stmts, 0..) |_, i| {
        try self.emitStmt(&stmts[i], stmts[i + 1 ..], indent);
    }
    if (!endsInJump(stmts)) try self.emitDropsSince(mark, indent, blockExit(stmts));
}

pub fn emitStmt(self: *Generator, stmt: *const ast.Stmt, rest: []const ast.Stmt, indent: usize) EmitError!void {
    const out = self.writer;
    try self.later_rests.append(self.arena, rest);
    defer _ = self.later_rests.pop();
    switch (stmt.kind) {
        .while_stmt => |w| {
            const loop_key = @intFromPtr(stmt);
            const skips = if (self.checker) |c| c.loopHasSkipBreaks(loop_key) else false;
            var skip_id: usize = 0;
            if (skips) {
                skip_id = self.next_skip_label;
                self.next_skip_label += 1;
                try self.skip_labels.append(self.arena, .{ .loop_key = loop_key, .id = skip_id });
            }
            try self.writeIndent(indent);
            try out.writeAll("while (");
            try self.emitCond(&w.cond, indent);
            try out.writeAll(") {\n");
            try self.loop_marks.append(self.arena, self.locals.items.len);
            try self.loop_bodies.append(self.arena, w.body);
            try self.emitStmts(w.body, indent + 4);
            _ = self.loop_bodies.pop();
            _ = self.loop_marks.pop();
            try self.writeIndent(indent);
            try out.writeAll("}\n");
            // R16 after_loop: an outer var this while moved and then
            // revived on every path out. Moved-only: emitDropsSince
            // would also free unmoved locals and double-free them at
            // function end (ASan exit 134, measured).
            try self.emitAfterLoopDrops(loop_key, indent);
            if (skips) {
                _ = self.skip_labels.pop();
                // A skip-revival `break` lands here, past the releases
                // above: its path already handed the value away.
                try self.writeIndent(indent);
                try out.print("cell_skip_{d}:;\n", .{skip_id});
            }
        },
        .break_stmt => {
            try self.emitLoopExitDrops(.{ .kind = .jump, .key = @intFromPtr(stmt) }, indent);
            try self.writeIndent(indent);
            if (self.skipLabelFor(@intFromPtr(stmt))) |id| {
                try out.print("goto cell_skip_{d};\n", .{id});
            } else {
                try out.writeAll("break;\n");
            }
        },
        .continue_stmt => {
            try self.emitLoopExitDrops(.{ .kind = .jump, .key = @intFromPtr(stmt) }, indent);
            try self.writeIndent(indent);
            try out.writeAll("continue;\n");
        },
        .let => |l| {
            const ty = try self.letType(l.ty, l.value, l.ownership);
            try self.writeIndent(indent);
            try self.writeDecl(ty, l.name);
            if (l.value) |v| {
                try out.writeAll(" = ");
                try self.emitArgLike(&v, ty, indent);
            } else if (try self.needsDrop(ty)) {
                // A droppable local declared without an initializer is
                // zero-initialized, so the scope-end drop (which ran on
                // garbage before 2026-09-15) and the reassignment
                // pre-drop above are both no-ops until the first write:
                // all three runtime drops return on a zeroed value
                // (`cell_arc_drop` returns on a NULL refcount, the two
                // `_free`s hand `free` a NULL), and a record's glue is
                // those same calls over zeroed fields.
                try out.print(" = ({s}){{0}}", .{ty.text});
            }
            try out.writeAll(";\n");
            try self.pushLocal(l.name, ty, l.ownership, true);
            // -Wunused-variable is part of -Wall.
            if (!stmtsUse(rest, l.name)) {
                try self.writeIndent(indent);
                try out.print("(void){s};\n", .{l.name});
            }
        },
        .return_stmt => |opt| try self.emitReturnStmt(opt, .{ .kind = .return_stmt, .key = @intFromPtr(stmt) }, indent),
        .expr => |*e| switch (e.kind) {
            .if_expr => try self.emitIfStmt(e, indent),
            .match_expr => |m| try self.emitMatchStmt(m, indent),
            .block => |b| {
                try self.writeIndent(indent);
                try out.writeAll("{\n");
                try self.emitStmts(b, indent + 1);
                try self.writeIndent(indent);
                try out.writeAll("}\n");
            },
            .annotated => |a| try self.emitEffect(a.value, indent),
            else => try self.emitDiscarded(e, indent),
        },
        .assign => |a| try self.emitAssign(a, indent),
    }
}

/// An assignment, which has to dereference when the target is a borrow.
///
/// A whole-value write through an `exclusive` borrow emitted the struct
/// into the POINTER:
///
///     pub fn reset(exclusive b: Buffer) { b = Buffer { len: 42 } }
///     -> b = (cell_Buffer){ .len = 42 };
///
/// `cell check` accepted it and `cc` refused it, `assigning to
/// 'cell_Buffer *' from incompatible type 'cell_Buffer'`. An `exclusive`
/// parameter lowers to a pointer (`applyOwnership`), and writing the
/// whole value through it means writing what it points at. The same
/// defect hit `exclusive String`, whose `s = make()` emitted
/// `s = cell_make();` against a `cell_string_t *`.
///
/// The dereference is keyed on the target's lowered type being a
/// pointer, and `pointerTo` is the only thing that makes one, so this
/// covers exactly the borrow modes and nothing else. A `.field` target is
/// unaffected: `inferExpr` gives it the FIELD's type, `emitExpr` already
/// spells the base with `->`, and R8 forbids a field from storing a
/// borrow, so a field's type is never a borrow pointer.
///
/// WHY THIS CANNOT CHANGE A PROGRAM THAT WORKS TODAY. Only two things
/// lower to a pointer here, and `borrowck.zig` refuses an assignment to
/// both of the ways one could already be reached: a `shared` borrow is
/// immutable (`cannot assign to immutable binding 'b'`), and assigning
/// one `exclusive` borrow to another is `cannot move out of 'c': it is an
/// exclusive borrow, not an owner`. So every assignment this changes was
/// a C type error, which is also why the whole class stayed invisible.
///
/// The right side is lowered against the POINTEE type, so it keeps every
/// conversion `emitArgLike` already applies rather than getting a second
/// hand-written path.
pub fn emitAssign(self: *Generator, a: anytype, indent: usize) EmitError!void {
    const out = self.writer;
    var want = try self.inferExpr(&a.target);
    // R11 row 5: reassigning an `arc` var releases the previous box.
    // Scoped to a whole-binding target naming a droppable `arc` local,
    // because that is the one target whose old value is provably live
    // and held exactly once here: borrowck never marks an `arc` place
    // moved, every alias that survives a statement is refcounted (a
    // clone at `let arc b = v`, a retain at a field store, a clone at
    // `return`), a `shared` view holds it only for the call, R4
    // refuses this assignment while a borrow of `v` is live, and R7's
    // write clause refuses it while a match-arm binding aliases `v`
    // (an arm binding is an UNRETAINED copy of the handle: without that
    // refusal `match v { x => { v = "two" \n print(x) } }` was a
    // measured heap-use-after-free at 4c93571).
    //
    // An `owned` `String` or list var is covered too, since 2026-09-16,
    // but ONLY when borrowck vouches for THIS store: the target still
    // held a value after the right side was checked, and no enclosing
    // `while` body moves it (`Checker.assignReleasesOldValue`). That is
    // the question the `arc` case never had to ask: a moved `owned`
    // var's old value belongs to whoever took it, so a pre-drop after
    // `take(v)` (R3a revival), after a move on one branch, in
    // `v = pass(v)`, or behind a loop's back edge is a double free or a
    // use after free (all three guards measured under ASan). Those keep
    // the leak. The first version asked `wasMoved` ("moved anywhere in
    // the function"), which also refused a var moved only AFTER the
    // store, and leaked its old value for no reason. The old reason for
    // excluding `owned` entirely, `[s]` copying the header without a
    // move, is gone: borrowck refuses that list element since c314a0e,
    // and a match-arm binding, a live `shared` borrow, an `owned` struct
    // field and a `shared` field are all refused before this point too.
    // The RHS goes into a temporary FIRST, because `v = v` and
    // `v = mk(v)` read the old value.
    if (self.reassignedDroppableLocal(&a.target)) |local| {
        const temp = try self.nextTemp();
        try self.writeIndent(indent);
        try self.writeDecl(want, temp);
        try out.writeAll(" = ");
        try self.emitArgLike(&a.value, want, indent);
        try out.writeAll(";\n");
        try self.emitDropFor(indent, local);
        try self.writeIndent(indent);
        try out.print("{s} = {s};\n", .{ local.name, temp });
        return;
    }
    // The FIELD-store twin (2026-09-21, closing the disclosed
    // `examples/leaks/field_store_old.cell` gap): `t.name = v` releases
    // the old field value first, under the same "borrowck vouches for
    // THIS store" rule. The right side goes into a temporary first,
    // because `t.name = mk(t.name)` reads the old value (and borrowck
    // then records the path dead, so that shape keeps the leak anyway).
    if (self.fieldStoreReleasesOld(&a.target, want)) {
        const temp = try self.nextTemp();
        try self.writeIndent(indent);
        try self.writeDecl(want, temp);
        try out.writeAll(" = ");
        try self.emitArgLike(&a.value, want, indent);
        try out.writeAll(";\n");
        try self.writeIndent(indent);
        try out.writeAll(if (want.shape == .string) "cell_string_free(&" else "cell_slice_free(&");
        try self.emitExpr(&a.target, indent);
        try out.writeAll(");\n");
        try self.writeIndent(indent);
        try self.emitExpr(&a.target, indent);
        try out.print(" = {s};\n", .{temp});
        return;
    }
    try self.writeIndent(indent);
    if (want.pointee) |pointee| {
        try out.writeAll("*");
        want = pointee.*;
    }
    try self.emitExpr(&a.target, indent);
    try out.writeAll(" = ");
    try self.emitArgLike(&a.value, want, indent);
    try out.writeAll(";\n");
}

pub fn emitIfStmt(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
    const i = e.kind.if_expr;
    const after = self.current_after;
    const saved_merge = self.current_merge;
    self.current_merge = .{ .kind = .after_branch, .key = @intFromPtr(e) };
    defer self.current_merge = saved_merge;
    const mark = self.locals.items.len;
    const out = self.writer;
    try self.writeIndent(indent);
    try out.writeAll("if (");
    try self.emitCond(i.cond, indent);
    try out.writeAll(") ");
    try self.emitBranchStmt(i.then_body, mark, after, indent);
    if (i.else_body) |eb| {
        try out.writeAll(" else ");
        try self.emitBranchStmt(eb, mark, after, indent);
    } else if (try self.branchNeedsSynthesizedElse(@intFromPtr(e), mark, after)) {
        try out.writeAll(" else {\n");
        try self.emitBranchEndDrops(@intFromPtr(e), mark, after, indent + 1);
        try self.writeIndent(indent);
        try out.writeAll("}");
    }
    try out.writeAll("\n");
}

/// One branch of a statement-position `if`. A nested `if` becomes
/// `else if` rather than a braced block.
pub fn emitBranchStmt(self: *Generator, e: *const ast.Expr, mark: usize, after: ?Exit, indent: usize) EmitError!void {
    const out = self.writer;
    switch (e.kind) {
        .block => |stmts| {
            try out.writeAll("{\n");
            try self.emitStmts(stmts, indent + 1);
            try self.emitBranchEndDrops(branchKey(e), mark, after, indent + 1);
            try self.writeIndent(indent);
            try out.writeAll("}");
        },
        .if_expr => |i| {
            try out.writeAll("if (");
            try self.emitCond(i.cond, indent);
            try out.writeAll(") ");
            try self.emitBranchStmt(i.then_body, mark, after, indent);
            if (i.else_body) |eb| {
                try out.writeAll(" else ");
                try self.emitBranchStmt(eb, mark, after, indent);
            } else if (try self.branchNeedsSynthesizedElse(@intFromPtr(e), mark, after)) {
                try out.writeAll(" else {\n");
                try self.emitBranchEndDrops(@intFromPtr(e), mark, after, indent + 1);
                try self.writeIndent(indent);
                try out.writeAll("}");
            }
        },
        .annotated => |a| try self.emitBranchStmt(a.value, mark, after, indent),
        else => {
            try out.writeAll("{\n");
            try self.writeIndent(indent + 1);
            try self.emitExpr(e, indent + 1);
            try out.writeAll(";\n");
            try self.emitBranchEndDrops(branchKey(e), mark, after, indent + 1);
            try self.writeIndent(indent);
            try out.writeAll("}");
        },
    }
}

pub fn emitMatchStmt(self: *Generator, m: anytype, indent: usize) EmitError!void {
    try self.emitMatch(m, null, indent);
}

/// Lower a `match` to a scrutinee temporary plus an if/else chain. When
/// `dest` is set every arm assigns into it instead of running for effect.
pub fn emitMatch(self: *Generator, m: anytype, dest: ?Dest, indent: usize) EmitError!void {
    const out = self.writer;
    // Keyed by the arms slice, which survives `m` being passed by value;
    // borrowck records `after_branch` under the same address.
    const saved_merge = self.current_merge;
    self.current_merge = .{ .kind = .after_branch, .key = @intFromPtr(m.arms.ptr) };
    defer self.current_merge = saved_merge;
    const scrut_ty = try self.inferExpr(m.scrutinee);
    const temp = try self.nextTemp();
    const outer_mark = self.locals.items.len;
    const scrut_inner = unwrapAnnotated(m.scrutinee);
    const scrut_is_temp = scrut_inner.kind != .ident and scrut_inner.kind != .field;
    const tracks_temp = scrut_is_temp and ownsTempScrutinee(scrut_inner, scrut_ty);
    if (tracks_temp) {
        try self.owning_temps.append(self.arena, .{
            .name = temp,
            .ty = scrut_ty,
            .loop_depth = self.loop_marks.items.len,
        });
    }
    defer if (tracks_temp) {
        _ = self.owning_temps.pop();
    };

    try self.writeIndent(indent);
    try out.writeAll("{\n");
    try self.writeIndent(indent + 1);
    try self.writeDecl(scrut_ty, temp);
    try out.writeAll(" = ");
    try self.emitExpr(m.scrutinee, indent + 1);
    try out.writeAll(";\n");
    // -Wunused-variable is part of -Wall. The temporary is read only by a
    // non-default pattern test or copied into a binding arm, so a match
    // whose reached arms are all `_` (a leading `_`, or `_ if g` guards)
    // never reads it. The scrutinee is still evaluated, for its effects.
    if (!scrutineeTempRead(m.arms)) {
        try self.writeIndent(indent + 1);
        try out.print("(void){s};\n", .{temp});
    }

    var tested: usize = 0;
    var default_arm: ?ast.MatchArm = null;
    for (m.arms) |arm| {
        // A GUARDED arm is never a default, however catch-all its pattern
        // looks: `_ if c` can fail. Treating it as one would drop the
        // panic and let an unmatched value fall through with a made-up
        // result, which is the exact failure the panic exists to prevent.
        if (isDefaultArm(arm)) {
            default_arm = arm;
            break;
        }
        try self.writeIndent(indent + 1);
        if (tested == 0) {
            try out.writeAll("if (");
        } else {
            try out.writeAll("} else if (");
        }
        if (isDefaultPattern(arm.pattern)) {
            // The pattern matches everything, so the guard IS the test.
            try self.emitCond(arm.guard.?, indent + 1);
        } else {
            try self.emitPatternTest(arm.pattern, temp, scrut_ty);
            if (arm.guard) |g| {
                try out.writeAll(" && (");
                try self.emitCond(g, indent + 1);
                try out.writeAll(")");
            }
        }
        try out.writeAll(") {\n");
        try self.emitArmBody(arm, temp, scrut_ty, dest, indent + 2, outer_mark, tracks_temp);
        tested += 1;
    }

    if (tested == 0) {
        // The first arm matches everything, so no test is emitted at all.
        if (default_arm) |arm| {
            try self.emitArmBody(arm, temp, scrut_ty, dest, indent + 1, outer_mark, tracks_temp);
        }
    } else {
        try self.writeIndent(indent + 1);
        try out.writeAll("} else {\n");
        if (default_arm) |arm| {
            try self.emitArmBody(arm, temp, scrut_ty, dest, indent + 2, outer_mark, tracks_temp);
        } else {
            // Cell has no exhaustiveness checking, so an unmatched value
            // aborts rather than falling through with a made-up result.
            try self.writeIndent(indent + 2);
            try out.print("cell_panic(cell_str_from_cstr(\"non-exhaustive match in {s}\"));\n", .{self.current_fn});
        }
        try self.writeIndent(indent + 1);
        try out.writeAll("}\n");
    }

    try self.writeIndent(indent);
    try out.writeAll("}\n");
}

pub fn emitArmBody(
    self: *Generator,
    arm: ast.MatchArm,
    temp: []const u8,
    scrut_ty: CType,
    dest: ?Dest,
    indent: usize,
    arm_outer_mark: usize,
    tracks_temp: bool,
) EmitError!void {
    const mark = self.locals.items.len;
    defer self.locals.shrinkRetainingCapacity(mark);
    const outer_after = self.current_after;
    const took_payload = arm.pattern.kind == .wrap_pattern and
        arm.pattern.kind.wrap_pattern.mode == .owned and
        ((arm.pattern.kind.wrap_pattern.ctor == .ok and resultOkOwning(scrut_ty)) or
            (arm.pattern.kind.wrap_pattern.ctor == .err and resultErrOwning(scrut_ty)) or
            (arm.pattern.kind.wrap_pattern.ctor == .some and isOwningOptional(scrut_ty)));
    // A binding arm (`x => ..`) over a temporary is an alias of it that
    // borrowck lets the body MOVE (`ArmOrigin.temp`), while this backend
    // binds a bitwise copy that is never dropped. Whether the body moved
    // it is not asked here, so a binding arm that names the value counts
    // as having taken it: a body that only reads `x` leaks the temporary,
    // one that moves it is never double freed (2026-09-17).
    const took_binding = arm.pattern.kind == .binding and
        exprUses(arm.body, arm.pattern.kind.binding);
    const took = took_payload or took_binding;
    if (tracks_temp) {
        self.owning_temps.items[self.owning_temps.items.len - 1].taken = took;
    }

    if (arm.pattern.kind == .binding) {
        const name = arm.pattern.kind.binding;
        try self.writeIndent(indent);
        try self.writeDecl(scrut_ty, name);
        try self.writer.print(" = {s};\n", .{temp});
        // Never droppable (`false`): this binding's C value is a
        // bitwise copy of the scrutinee temporary, so dropping it here
        // risks double-freeing whatever the scrutinee itself owns. See
        // the module doc comment. `.owned` is passed only to match
        // borrowck's own hardcoded assumption for this binding (R7 is
        // not implemented there either); it has no effect while
        // `droppable` is false.
        try self.pushLocal(name, scrut_ty, .owned, false);
        if (!exprUses(arm.body, name)) {
            try self.writeIndent(indent);
            try self.writer.print("(void){s};\n", .{name});
        }
    }
    if (arm.pattern.kind == .wrap_pattern) {
        const wp = arm.pattern.kind.wrap_pattern;
        if (wp.binding) |name| {
            const owning_side = (wp.ctor == .ok and resultOkOwning(scrut_ty)) or
                (wp.ctor == .err and resultErrOwning(scrut_ty)) or
                (wp.ctor == .some and isOwningOptional(scrut_ty));
            const owning_mode: ?ast.Ownership = if (owning_side) wp.mode else null;
            const payload_field: []const u8 = switch (wp.ctor) {
                .ok => "as.ok",
                .err => "as.err",
                .some, .none => "value",
            };
            const payload_ty: CType = switch (wp.ctor) {
                .some, .none => if (scrut_ty.payload) |p| p.* else CType.unknown,
                .ok => if (scrut_ty.payload) |p| p.* else CType.unknown,
                .err => if (scrut_ty.err_payload) |p| p.* else CType.unknown,
            };
            // `Ok(shared x)` binds a borrowed view of the payload.
            const ty: CType = if (owning_mode == .shared) CType.str else payload_ty;
            try self.writeIndent(indent);
            try self.writeDecl(ty, name);
            if (owning_mode) |mode| {
                if (mode == .shared) {
                    try self.writer.print(" = cell_string_as_str(&{s}.{s});\n", .{ temp, payload_field });
                } else {
                    try self.writer.print(" = {s}.{s};\n", .{ temp, payload_field });
                }
                // `owned` takes the payload's buffer and is released like
                // any owned local; `shared` never is.
                try self.pushLocal(name, ty, mode, mode == .owned);
                if (!exprUses(arm.body, name)) {
                    try self.writeIndent(indent);
                    try self.writer.print("(void){s};\n", .{name});
                }
            } else switch (wp.ctor) {
                .some, .none => try self.writer.print(" = {s}.value;\n", .{temp}),
                .ok, .err => {
                    const field = if (wp.ctor == .ok) "ok" else "err";
                    if (!std.mem.startsWith(u8, scrut_ty.text, "cell_res_")) {
                        try self.writer.writeAll(" = cell_res_unsupported_payload;\n");
                    } else if (ty.shape == .enumeration) {
                        try self.writer.print(" = ({s}){s}.as.{s};\n", .{ ty.text, temp, field });
                    } else {
                        try self.writer.print(" = {s}.as.{s};\n", .{ temp, field });
                    }
                },
            }
            if (owning_mode == null) {
                // A scalar copy: never droppable, `copy` like borrowck says.
                try self.pushLocal(name, ty, .copy, false);
                if (!exprUses(arm.body, name)) {
                    try self.writeIndent(indent);
                    try self.writer.print("(void){s};\n", .{name});
                }
            }
        }
    }

    if (dest) |d| {
        try self.emitValueInto(arm.body, d, indent);
    } else {
        try self.emitEffect(arm.body, indent);
    }

    // Arm end (2026-09-17). Skipped when the body always leaves: its
    // `return`/`break` already released what it held.
    if (armDiverges(arm.body)) return;
    const key = branchKey(arm.body);
    // The arm's own `Ok(owned ..)` binding, unless it was moved on.
    try self.emitDropsSince(mark, indent, .{ .kind = .branch_end, .key = key });
    // An outer owner this arm kept while another arm moved it.
    try self.emitBranchEndDrops(key, arm_outer_mark, outer_after, indent);
    // A temporary owning scrutinee no arm binding took.
    if (tracks_temp and !took) try self.emitTempRelease(indent, scrut_ty, temp);
}

/// Emit an expression for its effect, in statement position.
pub fn emitEffect(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
    switch (e.kind) {
        .block => |stmts| try self.emitStmts(stmts, indent),
        .if_expr => try self.emitIfStmt(e, indent),
        .match_expr => |m| try self.emitMatchStmt(m, indent),
        .annotated => |a| try self.emitEffect(a.value, indent),
        else => try self.emitDiscarded(e, indent),
    }
}

/// The two leaves that emit an expression as a statement and throw its
/// value away. Both used to be a bare `emitExpr`, and both must now tell
/// `emitCall` that the value is discarded.
///
/// `-Wunused-value` is part of `-Wall`, and it fires on the trailing
/// result expression of a GNU statement expression whose own value is
/// unused. So a hoisted call in bare statement position,
/// `pub fn main() { inspect(shared fresh()) }`, emitted
///
///     ({ ...; int64_t _t3 = cell_inspect(...); cell_arc_drop(_t2); _t3; });
///
/// and `cc -Wall -Wextra -Werror` rejected `_t3;`. That is source which
/// compiled before the hoist existed and stopped compiling after it: a
/// regression the example corpus cannot see, because no corpus file
/// discards the result of an `arc`-taking call. Told the value is
/// discarded, `emitCall` omits the result slot entirely, the statement
/// expression ends on a void `cell_arc_drop` exactly as the void-callee
/// case already did, and the drops are unaffected.
pub fn emitDiscarded(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
    // A discarded owned String CALL result has exactly one owner, this
    // statement, so it is bound to a temporary and released on the spot
    // (drop-pass spec open question 2, ruled 2026-09-21: fix in C now).
    // Only a call is admitted, by the same predicate a match scrutinee
    // uses: a str literal owns nothing, and a block or if of type String
    // may name an existing owner. Before this, `str_from_int(i)` as a
    // statement leaked its String (examples/leaks/discarded_result.cell).
    const inner = unwrapAnnotated(e);
    if (inner.kind == .call) {
        const ty = try self.inferExpr(e);
        if (ty.shape == .string and !ty.pointer) {
            const temp = try self.nextTemp();
            try self.writeIndent(indent);
            try self.writer.writeAll("{\n");
            try self.writeIndent(indent + 1);
            try self.writeDecl(ty, temp);
            try self.writer.writeAll(" = ");
            try self.emitExpr(e, indent + 1);
            try self.writer.writeAll(";\n");
            try self.emitTempRelease(indent + 1, ty, temp);
            try self.writeIndent(indent);
            try self.writer.writeAll("}\n");
            return;
        }
    }
    try self.writeIndent(indent);
    switch (inner.kind) {
        .call => |c| try self.emitCallValued(c, indent, false),
        else => try self.emitExpr(e, indent),
    }
    try self.writer.writeAll(";\n");
}

pub fn emitPatternTest(self: *Generator, p: ast.Pattern, temp: []const u8, scrut_ty: CType) EmitError!void {
    const out = self.writer;
    switch (p.kind) {
        .wildcard, .binding => try out.writeAll("true"),
        .int => |v| try out.print("{s} == {d}", .{ temp, v }),
        .float => |v| {
            try out.print("{s} == ", .{temp});
            try self.emitFloat(v);
        },
        .bool => |b| {
            if (b) {
                try out.print("{s}", .{temp});
            } else {
                try out.print("!{s}", .{temp});
            }
        },
        .string => |s| {
            try out.writeAll("cell_str_eq(");
            if (scrut_ty.shape == .string and !scrut_ty.pointer) {
                try out.print("cell_string_as_str(&{s})", .{temp});
            } else if (scrut_ty.shape == .string) {
                try out.print("cell_string_as_str({s})", .{temp});
            } else {
                try out.writeAll(temp);
            }
            try out.writeAll(", ");
            try self.emitStringLiteral(s);
            try out.writeAll(")");
        },
        .enum_variant => |ev| {
            const enum_name = ev.enum_name orelse
                (if (scrut_ty.shape == .enumeration) scrut_ty.name else "");
            if (enum_name.len == 0) {
                // No enum in scope for this pattern: emit the bare mangled
                // constant so the C compiler reports the missing name
                // instead of codegen inventing one.
                try out.print("{s} == cell_{s}", .{ temp, ev.variant });
            } else {
                try out.print("{s} == cell_{s}_{s}", .{ temp, enum_name, ev.variant });
            }
        },
        .wrap_pattern => |wp| switch (wp.ctor) {
            .some => try out.print("{s}.has_value", .{temp}),
            .none => try out.print("!{s}.has_value", .{temp}),
            .ok => try out.print("{s}.ok", .{temp}),
            .err => try out.print("!{s}.ok", .{temp}),
        },
    }
}
