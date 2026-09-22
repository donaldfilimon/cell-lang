//! Expression walk: `if`, `match`, wraps, and calls.
//! Part of the borrow checker; the rules and their rationale are in the module header of `../borrowck.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const Span = ast.Span;
const Ownership = ast.Ownership;
const bk_bindings = @import("bindings.zig");
const bk_model = @import("model.zig");
const bk_root = @import("../borrowck.zig");
const Checker = bk_root.Checker;
const Error = bk_model.Error;
const LoanKind = bk_model.LoanKind;
const ArmOrigin = bk_model.ArmOrigin;
const Dead = bk_model.Dead;
const refKind = bk_model.refKind;
const findField = bk_model.findField;
const ctorName = bk_model.ctorName;
const containsDead = bk_model.containsDead;
const branchDiverges = bk_bindings.branchDiverges;
const branchKeyOf = bk_bindings.branchKeyOf;

// ── expressions ─────────────────────────────────────────────────────

pub fn checkExpr(self: *Checker, e: *const ast.Expr) Error!void {
    switch (e.kind) {
        .int, .float, .string, .bool => {},
        .ident, .field => {
            if (try self.placeOf(e)) |place| try self.readPlace(place);
        },
        // Indexing reads the base; it does not move it. `a[i]` after a
        // move of `a` is use-after-move.
        .index => |*ix| {
            try self.checkExpr(ix.base);
            try self.checkExpr(ix.index);
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
                // R9 in a VALUE position, which is axis 1 of R10's history
                // repeating in a new rule: `createLoan` is the choke point
                // for every exclusive loan, and a loan is only created for
                // a PLACE, so `&mut fresh()` with `fresh() -> arc String`
                // never reached it. Measured: accepted at exit 0, emitting
                // `cell_grow(((cell_string_t *)&cell_fresh().ptr))`.
                //
                // That emit is LOUD, and loud for every type rather than
                // by the coincidence of two C types: `cc` refuses to take
                // the address of an rvalue. It is refused here anyway, on
                // the argument `refuseArcUnique` already makes, that a
                // rule which holds for every type beats one whose
                // enforcement depends on what the backend happens to emit.
                //
                // `arcUniqueSource` is R10's classifier and answers the
                // question both rules need here, "is this expression an
                // `arc` handle", with a total verdict.
                if (kind == .exclusive and try self.refuseArcValueBorrow(u.operand)) return;
            }
            try self.checkExpr(u.operand);
        },
        // R2's move list does not include struct or list literals, so
        // their elements are read rather than moved. See the report.
        .struct_lit => |*sl| {
            // R10, the struct-field position. Arc-to-owned conversion is
            // refused first. The resource-shape guard below separately
            // refuses shallow copies and unresolved transfers into owned
            // fields; moving such a field out was a live double free.
            const def = self.structs.get(sl.name);
            for (sl.fields) |*f| {
                // R2.b: a block value is opened first (see
                // `openBlockTail`); `v` is what this site consumes.
                var v: *const ast.Expr = &f.value;
                var depth: usize = 0;
                defer self.closeBlockTail(depth);
                if (def) |d| {
                    if (findField(d, f.name)) |fld| {
                        // R10's other direction, the struct-literal field
                        // position. The sweep does not generate it and it
                        // is not one of its four rows; found by probing
                        // the positions rather than the rows, which is the
                        // discipline this rule's own text asks for.
                        // `struct Box { arc s: String }` with
                        // `Box { s: p }` over an `owned` p was accepted by
                        // the checker and rejected by `cc` with
                        // `initializing 'void *' with an expression of
                        // incompatible type 'cell_string_t'`.
                        if (fld.ownership == .arc) {
                            // IMPLEMENTED for one source shape
                            // (2026-09-16), the fifth position: a bare
                            // `owned` `String` or list binding is MOVED
                            // into the fresh box the field holds, and the
                            // record's drop glue (R11 row 2) releases it.
                            // A block value is not opened for an `arc`
                            // field, so it keeps the refusal below with
                            // every other source shape. The field TARGET
                            // store (`r.s = p`) is the assignment site's
                            // business and stays refused there.
                            if (f.value.kind != .block) {
                                if (try self.boxableOwnedBinding(&f.value)) |src| {
                                    const note = try self.msg("'{s}' was moved here into the 'arc' field '{s}'", .{ src.display, f.name });
                                    try self.movePlace(src, note);
                                    continue;
                                }
                            }
                            if (try self.refuseUnimplementedArcMove(&f.value, "store", "in", "field", f.name)) continue;
                        }
                        if (fld.ownership == .owned) {
                            switch (try self.openBlockTail(&f.value)) {
                                .not_block => {},
                                .unit => continue,
                                .tail => |t| {
                                    v = t.expr;
                                    depth = t.depth;
                                },
                            }
                            // Asked of the whole EXPRESSION's verdict, so
                            // a value position or a call result in a field
                            // is refused too.
                            if (try self.refuseArcUnique(
                                try self.arcUniqueSource(v),
                                "store",
                                "in",
                                "field",
                                f.name,
                            )) continue;
                            switch (try self.fieldResourceShape(&fld)) {
                                .no_resources => switch (try self.ownedMoveSource(v)) {
                                    .unknown => |s| {
                                        try self.refuseUnknownMove(s, "store", "in", "field", f.name);
                                        continue;
                                    },
                                    .aliases_place, .place, .no_owned_place => {},
                                },
                                .unknown => {
                                    try self.refuseOwnedFieldTransfer(
                                        .{ .display = "a value of unresolved resource shape", .span = f.value.span },
                                        f.name,
                                        "the destination field's resource shape cannot be resolved",
                                    );
                                    continue;
                                },
                                .resources => {
                                    switch (try self.borrowSource(v)) {
                                        .not_borrow => {},
                                        .borrow => |s| {
                                            try self.refuseOwnedFieldTransfer(s, f.name, "a borrow does not transfer ownership");
                                            continue;
                                        },
                                        .unresolved => |s| {
                                            try self.refuseOwnedFieldTransfer(s, f.name, "the source cannot be proven to own a fresh value");
                                            continue;
                                        },
                                    }
                                    switch (try self.ownedMoveSource(v)) {
                                        .no_owned_place => {},
                                        .place => |p| {
                                            try self.refuseOwnedFieldTransfer(
                                                .{ .display = p.display, .span = p.span },
                                                f.name,
                                                "moving a place into an aggregate is not implemented",
                                            );
                                            continue;
                                        },
                                        .aliases_place, .unknown => |s| {
                                            try self.refuseOwnedFieldTransfer(s, f.name, "the source is not a fresh owned value");
                                            continue;
                                        },
                                    }
                                },
                            }
                        }
                    }
                }
                try self.checkExpr(v);
            }
        },
        // R10, the list-element position, and one of the two consumption
        // sites the four-position enumeration never asked at. A list
        // literal copies each element BY VALUE into a fresh buffer that
        // the list owns, so every element is made unique, and there is no
        // element-level annotation that could say otherwise. Measured
        // before this: `let owned zss: [[Int]] = [xs, xs]` with an
        // `arc [Int]` place passed `cell check` and compiled clean at
        // `-Wall -Wextra -Werror`, emitting the make-unique unbox at each
        // element. It is not a use-after-free TODAY only because slice
        // elements are never released, which is itself a disclosed gap;
        // closing that gap detonates this. Refused with the others rather
        // than left as a trap for that change.
        //
        // The refusal is context free, so it also refuses an `arc` element
        // in a list bound as `arc`. That over-refuses a program that is
        // safe today, and it is the safe direction: the buffer, not the
        // refcount, is what gets freed twice.
        .list_lit => |items| {
            for (items) |*item| {
                // R2.b: a block element is opened first (see
                // `openBlockTail`); `v` is what this site consumes.
                //
                // The watermark is read BEFORE the block opens, so a place
                // whose binding id is at or above it was declared inside
                // this element's own block. That is the discriminator the
                // resource refusal below needs: a block-local YIELDED as
                // the tail is excluded from `emitValueBlockDrops`, so the
                // element is its only owner and nothing releases it twice,
                // while an OUTER place keeps its own header and is
                // released at its own scope end. Ids are monotonic
                // (`declare`), which is what makes the comparison sound.
                const outer_watermark = self.next_binding_id;
                var v: *const ast.Expr = item;
                var depth: usize = 0;
                defer self.closeBlockTail(depth);
                switch (try self.openBlockTail(item)) {
                    .not_block => {},
                    .unit => continue,
                    .tail => |t| {
                        v = t.expr;
                        depth = t.depth;
                    },
                }
                if (try self.refuseArcUnique(
                    try self.arcUniqueSource(v),
                    "store",
                    "in",
                    "list element",
                    null,
                )) continue;
                // R2.b, the list-element position. `.unknown` ONLY, for
                // the same reason as the struct field above: a plain place
                // stays a READ, and it is not a use-after-free today only
                // because slice elements are never released. That gap is
                // disclosed in OWNERSHIP.md R11 and closing it is what
                // decides whether this position moves; turning it into a
                // move here, ahead of that, would leak instead.
                switch (try self.ownedMoveSource(v)) {
                    .unknown => |s| {
                        try self.refuseUnknownMove(s, "store", "in", "list element", null);
                        continue;
                    },
                    // A place whose type OWNS RESOURCES is refused: the
                    // element copies its header and the source keeps one,
                    // so the source's release dangles the element. See
                    // `refuseListElementMove` for the ASan measurement
                    // that falsified this site's previous justification.
                    // A place whose type resolves to no resources (`[n]`
                    // over an `Int`, `[b]` over a scalar-only record) is
                    // still a plain read, and an UNRESOLVED type still
                    // reads, because this predicate gates a refusal.
                    .place => |pl| {
                        if (pl.binding < outer_watermark) blk: {
                            const b = self.bindingById(pl.binding) orelse break :blk;
                            if (try self.placeResourceShape(b, pl.path)) |shape| {
                                if (shape == .resources) {
                                    try self.refuseListElementMove(pl);
                                    continue;
                                }
                            }
                        }
                    },
                    // R7. This arm READ until 2026-09-16, on the same
                    // retracted justification as `.place` above ("neither
                    // is a double free today, measured at `4698dbc`"). A
                    // match-arm binding is a bitwise alias of the
                    // scrutinee, the scrutinee is released at its own
                    // scope end, and the element keeps the header:
                    // `fn f() -> [String] { let owned s = make(); return
                    // match s { x => [x] } }` read by its caller reports
                    // AddressSanitizer heap-use-after-free, freed by
                    // `cell_string_free` on `s` (measured at `81e6709`).
                    // The refusal is the one every other consumption site
                    // already applies to an alias.
                    .aliases_place => |s| {
                        try self.refuseScrutineeAlias(s, "store", "in", "list element", null);
                        continue;
                    },
                    .no_owned_place => {},
                }
                try self.checkExpr(v);
            }
        },
        .block => |stmts| try self.checkBlockStmts(stmts),
        .if_expr => try self.checkIf(e),
        .match_expr => |*m| try self.checkMatch(m),
        .annotated => |a| try self.checkExpr(a.value),
        .wrap => |w| try self.checkWrap(w),
    }
}

/// R0.3 exception 2: a borrow created in the condition ends when the `if`
/// finishes, so the condition's temporary region wraps the branches too.
///
/// Branches are merged conservatively: a place moved in any branch is dead
/// afterwards, and a place revived in only one branch stays dead. That is
/// the sound answer without a control-flow graph.
pub fn checkIf(self: *Checker, expr: *const ast.Expr) Error!void {
    const i = expr.kind.if_expr;
    const region = self.temp_loans.items.len;
    defer self.temp_loans.shrinkRetainingCapacity(region);

    try self.checkExpr(i.cond);

    var entry = try self.dead.clone(self.allocator);
    defer entry.deinit(self.allocator);

    try self.checkExpr(i.then_body);
    try self.recordExit(.branch_end, branchKeyOf(i.then_body));
    var then_dead = try self.dead.clone(self.allocator);
    defer then_dead.deinit(self.allocator);

    self.dead.clearRetainingCapacity();
    try self.dead.appendSlice(self.allocator, entry.items);
    var else_diverges = false;
    if (i.else_body) |else_body| {
        try self.checkExpr(else_body);
        try self.recordExit(.branch_end, branchKeyOf(else_body));
        else_diverges = branchDiverges(else_body);
    } else {
        // Missing else: live iff not moved before the if. Keyed by the
        // if expression, matching codegen's synthesized-else drops.
        try self.recordExit(.branch_end, @intFromPtr(expr));
    }
    // A branch that always leaves by `return`, `break` or `continue`
    // never reaches the code after the `if` (2026-09-17): a `break`
    // saved its state, a `continue` met R2.a, a `return` left the
    // function. Its moves stay out of the merge.
    const then_diverges = branchDiverges(i.then_body);
    if (else_diverges) {
        self.dead.clearRetainingCapacity();
        try self.dead.appendSlice(self.allocator, if (then_diverges) entry.items else then_dead.items);
    } else if (!then_diverges) {
        try self.unionDead(then_dead.items);
    }
    try self.recordExit(.after_branch, @intFromPtr(expr));
}

pub fn checkMatch(self: *Checker, m: *const @FieldType(ast.Expr.Kind, "match_expr")) Error!void {
    const region = self.temp_loans.items.len;
    defer self.temp_loans.shrinkRetainingCapacity(region);

    // R7 (a pattern binding inherits the scrutinee's ownership) is not
    // implemented, so the scrutinee is read, not moved. The arm binding is
    // therefore an ALIAS of whatever the scrutinee names, and consuming it
    // in an `owned` position is refused rather than moved: see
    // `ArmOrigin`, `ownedMoveSource`'s `.aliases_place`, and
    // `docs/OWNERSHIP.md` R7. Moving the scrutinee instead is the designed
    // follow-up and is NOT this change; it would alter `wasMoved` for
    // every arm binding, and codegen's `pendingDrops` reads that.
    try self.checkExpr(m.scrutinee);

    // The scrutinee's STRUCT TYPE, carried to an arm binding below. Not
    // R7, and it does not touch ownership: it is only what
    // `placeOwnership` needs one level down, so a field of an arm binding
    // has an annotation to read at all.
    //
    // Same reason as the borrow propagation in `checkLet`, found the same
    // way. R9's verdict is total, so an unreadable annotation REFUSES, and
    // an arm binding declared with `struct_name = null` made
    // `use_bytes(&mut x.data)` inside `match src { x => ... }` fail with
    // "the ownership of the field 'data' of 'x' cannot be resolved here".
    // Resolving it can only turn `.unresolved` into a verdict read off a
    // real annotation; it never turns silence into acceptance.
    const scrutinee_place = try self.placeOf(m.scrutinee);

    const scrutinee_struct: ?[]const u8 = blk: {
        const p = scrutinee_place orelse break :blk null;
        const sb = self.bindingById(p.binding) orelse break :blk null;
        break :blk self.placeStructName(sb, p.path);
    };

    // R7, and the ONE question this rule asks: does anything else still
    // own what the arm binding will name?
    //
    // A scrutinee with no place behind it -- a call result, a literal, a
    // fresh aggregate -- has no other owner, so the arm binding is the
    // only handle and consuming it is a move of a temporary. That row was
    // measured correct (`match make() { x => take(owned x) }`, exit 0) and
    // refusing it too would be over-refusal with nothing to show for it.
    //
    // A scrutinee that IS a place makes an alias, full stop. There is no
    // propagation, and the first version of this rule had one that was
    // WRONG in the dangerous direction.
    //
    // It read: a scrutinee that is exactly a whole `.temp` arm binding is
    // itself a temporary with no other owner, so
    // `match fresh() { x => match x { y => take(owned y) } }` may stay
    // accepted. That is sound about ONE consumer and false about two, and
    // nesting a `match` is the only construct in this grammar that makes
    // two live handles on one value: `let owned y = x` MOVES `x`, so R2
    // catches the `let` spelling, while an arm binding COPIES it and
    // nothing did. Measured against the propagating version:
    //
    //     match fresh() { x => match x { y => take(owned y) }
    //                                  + take(owned x) }      exit 134
    //
    // R2 cannot fire there, because `x` and `y` are two different bindings
    // with two different ids. The propagation bought exactly one contrived
    // single-consumer program and kept a live double free open to do it,
    // which is the wrong side of the asymmetry this file runs on. Removing
    // it costs a documented over-refusal of that program and closes the
    // class outright.
    const arm_origin: ArmOrigin = if (scrutinee_place == null) .temp else .alias;
    // The scrutinee place's TYPE, carried to a binding-pattern arm
    // binding for the resource-shape questions only (`Binding.ty`), so
    // `match n { y => Ok(y) }` over a scalar still reads (2026-09-17).
    const scrutinee_ty: ?ast.TypeExpr = blk: {
        const p = scrutinee_place orelse break :blk null;
        const sb = self.bindingById(p.binding) orelse break :blk null;
        const pt = self.placeTypeOf(sb, p.path) orelse break :blk null;
        break :blk pt.ty;
    };

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
                .struct_name = scrutinee_struct,
                .ty = scrutinee_ty,
                .decl_span = arm.pattern.span,
                .arm_origin = arm_origin,
                .arm_scrutinee = if (scrutinee_place) |p| p.display else null,
                .arm_scrutinee_binding = if (scrutinee_place) |p| p.binding else null,
            });
        }
        if (arm.pattern.kind == .wrap_pattern) {
            const wp = arm.pattern.kind.wrap_pattern;
            if (wp.binding) |name| {
                // `Ok(owned x)` / `Ok(shared x)` (2026-09-17): an owning
                // payload. `owned` MOVES the scrutinee on this arm only,
                // so the per-arm merge leaves it maybe-dead after the
                // match and live on the other arms; `shared` borrows it
                // for the arm. Typecheck refuses a mode anywhere it
                // means nothing, so a mode here names a String payload.
                // Without a mode the payload is a scalar copied out of
                // the scrutinee (spec B.2): it aliases and owns nothing.
                const mode: ?Ownership = if (wp.ctor != .none) wp.mode else null;
                const owning = mode != null and (mode.? == .owned or mode.? == .shared);
                _ = try self.declare(.{
                    .id = 0,
                    .name = name,
                    .ownership = if (owning) mode.? else .copy,
                    .mutable = false,
                    .struct_name = null,
                    .ty = if (owning) ast.TypeExpr{ .name = "String" } else null,
                    .decl_span = arm.pattern.span,
                    .arm_origin = .temp,
                    .arm_scrutinee = null,
                    .arm_scrutinee_binding = null,
                });
                if (owning and mode.? == .owned) {
                    var body: *const ast.Expr = arm.body;
                    while (body.kind == .annotated) body = body.kind.annotated.value;
                    if (body.kind == .ident and std.mem.eql(u8, body.kind.ident, name)) {
                        try self.diagnostics.err(
                            self.allocator,
                            arm.body.span,
                            try self.msg("yielding the '{s}(owned {s})' binding directly from its arm is not implemented", .{ ctorName(wp.ctor), name }),
                        );
                        try self.diagnostics.note(
                            self.allocator,
                            arm.body.span,
                            "the arm's release of the binding and the destination's ownership of the value are not yet reconciled; consume it inside the arm instead",
                        );
                    }
                    if (scrutinee_place) |sp| {
                        try self.movePlace(sp, try self.msg("'{s}' was moved here by '{s}(owned {s})'", .{ sp.display, ctorName(wp.ctor), name }));
                    }
                } else if (owning) {
                    if (scrutinee_place) |sp| try self.createLoan(sp, .shared, true, name);
                }
            }
        }
        try self.checkExpr(arm.body);
        try self.recordExit(.branch_end, branchKeyOf(arm.body));
        self.popScope();

        // An arm that always leaves never reaches the code after the
        // match (2026-09-17, the `checkIf` rule). `merged` starts as the
        // entry state, so a match whose every arm leaves keeps it.
        if (branchDiverges(arm.body)) continue;
        for (self.dead.items) |d| {
            if (!containsDead(merged.items, d)) {
                try merged.append(self.allocator, d);
            }
        }
    }

    self.dead.clearRetainingCapacity();
    try self.dead.appendSlice(self.allocator, merged.items);
    try self.recordExit(.after_branch, @intFromPtr(m.arms.ptr));
}

pub fn unionDead(self: *Checker, other: []const Dead) Error!void {
    for (other) |d| {
        if (!containsDead(self.dead.items, d)) {
            try self.dead.append(self.allocator, d);
        }
    }
}

/// `Some(x)`, `Ok(x)`, `Err(x)`. Only `Ok` can carry an owning payload
/// (an owned `String`, 2026-09-17), and this checker has no types, so it
/// asks the operand: a place whose type resolves to resources is MOVED
/// and recorded in `wrap_moves`; a place resolving to none, or not
/// resolving at all, is read, and codegen copies an owning one it was not
/// told was moved. An alias or an undecidable value shape that may own a
/// resource is refused, as at every other consumption site.
pub fn checkWrap(self: *Checker, w: @FieldType(ast.Expr.Kind, "wrap")) Error!void {
    const o = w.operand orelse return;
    // `Ok`, `Err` (sub-project 3) and `Some` (sub-project 4) can carry an
    // owning String; `None` has no operand.
    _ = w.ctor;
    switch (try self.ownedMoveSource(o)) {
        .place => |pl| {
            const b = self.bindingById(pl.binding) orelse return self.checkExpr(o);
            if (try self.placeResourceShape(b, pl.path)) |shape| {
                if (shape == .resources) {
                    try self.movePlace(pl, try self.msg("'{s}' was moved here by 'Ok'", .{pl.display}));
                    // Keyed by the OPERAND pointer: the wrap node itself
                    // is copied by value on some paths (a `return`'s
                    // optional value), the heap operand never is.
                    try self.wrap_moves.append(self.allocator, @intFromPtr(o));
                    return;
                }
            }
            try self.checkExpr(o);
        },
        .aliases_place => |site| {
            if (try self.valueMayOwn(o)) {
                try self.refuseScrutineeAlias(site, "wrap", "in", "'Ok' payload", null);
                return;
            }
            try self.checkExpr(o);
        },
        .unknown => |site| {
            if (try self.valueMayOwn(o)) {
                try self.refuseUnknownMove(site, "wrap", "in", "'Ok' payload", null);
                return;
            }
            try self.checkExpr(o);
        },
        .no_owned_place => try self.checkExpr(o),
    }
}

/// Whether a value may hand over an owned resource: false only when every
/// place it can yield resolves to no resources, or it is a fresh value.
/// Unresolved answers true, because this gates a refusal of an
/// UNDECIDABLE shape, where reading would risk a double free.
pub fn valueMayOwn(self: *Checker, e: *const ast.Expr) Error!bool {
    if (try self.placeOf(e)) |pl| {
        const b = self.bindingById(pl.binding) orelse return true;
        const shape = (try self.placeResourceShape(b, pl.path)) orelse return true;
        return shape != .no_resources;
    }
    return switch (e.kind) {
        .int, .float, .string, .bool, .binary, .struct_lit, .list_lit, .call, .index, .wrap => false,
        .unary => false,
        .annotated => |a| try self.valueMayOwn(a.value),
        .if_expr => |i| (try self.valueMayOwn(i.then_body)) or
            (if (i.else_body) |eb| try self.valueMayOwn(eb) else false),
        .match_expr => |m| blk: {
            for (m.arms) |arm| {
                if (try self.valueMayOwn(arm.body)) break :blk true;
            }
            break :blk false;
        },
        .block => |stmts| blk: {
            if (stmts.len == 0) break :blk false;
            const last = &stmts[stmts.len - 1];
            if (last.kind != .expr) break :blk false;
            break :blk try self.valueMayOwn(&last.kind.expr);
        },
        .ident, .field => true,
    };
}

// ── calls: R1, R2, R3, R4, R5, R15 ──────────────────────────────────

pub fn checkCall(
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

        // R15. A keyword prefix on the argument is the written mode.
        // `&x` / `&mut x` are the same check when no keyword was written.
        // Do not overwrite a keyword with an inner sigil: `owned &buf`
        // is still passed as owned. Always peel to the place inside.
        var explicit: ?Ownership = null;
        var operand: *const ast.Expr = arg;
        if (arg.kind == .annotated) {
            explicit = arg.kind.annotated.ownership;
            operand = arg.kind.annotated.value;
        }
        if (refKind(arg)) |r| {
            if (explicit == null) {
                explicit = if (r.kind == .exclusive) .exclusive else .shared;
            }
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

        // R2.b: a block argument to an `owned` parameter is opened
        // first (see `openBlockTail`), and `operand` becomes its tail.
        var depth: usize = 0;
        defer self.closeBlockTail(depth);

        // R10, the call-argument position, asked on the EXPRESSION and
        // asked BEFORE the place check below. It has to be before it:
        // `placeOf` returns null for a `match`, and the early exit under
        // it is exactly how `take(owned match c { 0 => xs, _ => xs })`
        // escaped a rule that refuses `take(owned xs)`.
        if (mode == .arc) {
            // R10's other direction, the call-argument position. The
            // sweep's four rows are all bindings and assignments, so this
            // one was found by hand: `keep(p)` with `arc s` and an `owned`
            // p is accepted by the checker and rejected by `cc` exactly
            // like them. Listed shapes are not the enumeration; the
            // position is. See `refuseUnimplementedArcMove`.
            const slot_name = if (param) |p| p.name else null;
            // IMPLEMENTED for one source shape (2026-09-16), the fourth
            // position after `let`, a direct return and assignment: a
            // bare `owned` `String` or list binding passed to an `arc`
            // parameter is MOVED into a fresh box, and the callee
            // releases that box (cell_rt.h section 7, callee-releases
            // for `arc`, the same count-1 handoff a boxed literal makes).
            // A block argument is not opened for an `arc` parameter, so
            // it keeps the refusal below with every other source shape.
            if (operand.kind != .block) {
                if (try self.boxableOwnedBinding(operand)) |src| {
                    const note = if (callee_name) |n|
                        try self.msg("'{s}' was moved here into the 'arc' box passed to '{s}'", .{ src.display, n })
                    else
                        try self.msg("'{s}' was moved here into the 'arc' box passed to the call", .{src.display});
                    try self.movePlace(src, note);
                    continue;
                }
            }
            if (try self.refuseUnimplementedArcMove(operand, "pass", "to", "parameter", slot_name)) continue;
        }
        if (mode == .owned) {
            const slot_name = if (param) |p| p.name else null;
            switch (try self.openBlockTail(operand)) {
                .not_block => {},
                .unit => continue,
                .tail => |t| {
                    operand = t.expr;
                    depth = t.depth;
                },
            }
            if (try self.refuseArcUnique(
                try self.arcUniqueSource(operand),
                "pass",
                "to",
                "parameter",
                slot_name,
            )) continue;
            // R2.b, the call-argument position, and one of the two live
            // sites the brief that opened this rule did not name. Asked
            // on the peeled `operand` and BEFORE the place check below,
            // for the same reason R10's is: `placeOf` returns null for a
            // `match`, and the early exit under it is exactly how the
            // value shapes escaped. Measured at `0e82266`:
            // `take(owned match c { 0 => s1, _ => s1 })` was exit 134.
            switch (try self.ownedMoveSource(operand)) {
                .unknown => |s| {
                    try self.refuseUnknownMove(s, "pass", "to", "parameter", slot_name);
                    continue;
                },
                // R7, the call-argument position: the reproducer.
                // Measured at `4698dbc`,
                // `print_int(match s1 { x => take(owned x) })` was
                // `cell check` exit 0, `cc` exit 0, running it exit 134.
                // It also closes an R10 escape at the same site, because
                // `arcUniqueSource` reads the arm binding's own `.owned`
                // annotation and cannot see the scrutinee's `arc`:
                // `match a { x => take_list(owned x) }` over an
                // `arc [Int]` place was exit 134 while `take_list(owned a)`
                // was already refused.
                .aliases_place => |s| {
                    try self.refuseScrutineeAlias(s, "pass", "to", "parameter", slot_name);
                    continue;
                },
                // A place is moved by the `.owned` arm below, unchanged.
                .place, .no_owned_place => {},
            }
        }

        const place = try self.placeOf(operand);
        if (place == null) {
            // R9 in a value position. `checkCall` peels the `&mut` itself
            // and hands `checkExpr` the operand, so the unary arm's copy
            // of this check never sees a call argument. See
            // `refuseArcValueBorrow`.
            if (mode == .exclusive and try self.refuseArcValueBorrow(operand)) continue;
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
                // R10: an `arc` place may not be passed to an `owned`
                // parameter. This is the one clause of R10 that is
                // implemented, and it is here rather than in codegen
                // because codegen cannot refuse it: `owned [T]` and
                // `shared [T]` are the SAME C type (`cell_slice_t` by
                // value), so the emitted unbox
                // `take((*(const cell_slice_t *)xs.ptr))` compiles clean
                // and is a double free of the BUFFER. `cell_rt.h`
                // section 7 makes an `owned` callee responsible for the
                // eventual free, and `cell_slice_drop_glue` frees the
                // same buffer again when the box dies. A retain cannot
                // help: `cell_arc_clone` increments a refcount, and the
                // buffer is not what the refcount governs.
                //
                // The `arc` case already `continue`d above, on the
                // expression rather than on the place.
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
