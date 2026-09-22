//! `let` bindings and their initializers, block tails, and assignment.
//! Part of the borrow checker; the rules and their rationale are in the module header of `../borrowck.zig`.

const ast = @import("../ast.zig");
const Span = ast.Span;
const bk_model = @import("model.zig");
const bk_root = @import("../borrowck.zig");
const Checker = bk_root.Checker;
const Error = bk_model.Error;
const LoanKind = bk_model.LoanKind;
const refKind = bk_model.refKind;
const typeStructName = bk_model.typeStructName;

pub fn checkLet(self: *Checker, l: *const @FieldType(ast.Stmt.Kind, "let"), span: Span) Error!void {
    var struct_name: ?[]const u8 = null;
    if (l.ty) |*t| struct_name = typeStructName(t);

    if (l.value) |*v| {
        if (struct_name == null) {
            if (v.kind == .struct_lit) struct_name = v.kind.struct_lit.name;
        }
        // And from a CALL's declared return type. Without this,
        // `let owned s = make()` over `make() -> Session` leaves
        // `struct_name` null, `placeOwnership` cannot read `s.data`'s
        // annotation, and R10's total verdict calls that `unknown` and
        // REFUSES a valid program. Measured: it did exactly that, and
        // typecheck reported nothing alongside it, so the refusal was the
        // only diagnostic. A total verdict makes every unresolved
        // annotation load-bearing, which is the cost of the guarantee and
        // the reason this inference has to exist rather than being an
        // optimisation.
        //
        // Residual, stated rather than left to be rediscovered: a `match`
        // or a block yielding a struct in an UNANNOTATED `let` still
        // leaves `struct_name` null and is still refused in an `owned`
        // field consumption. Write the type (`let owned s: Session = ...`)
        // and it resolves.
        if (struct_name == null) {
            if (v.kind == .call) {
                if (v.kind.call.callee.kind == .ident) {
                    if (self.fns.get(v.kind.call.callee.kind.ident)) |sig| {
                        if (sig.return_type) |rt| struct_name = typeStructName(&rt);
                    }
                }
            }
        }
        // And ACROSS A BORROW. `let exclusive e = &mut buf` has no
        // annotation, is not a struct literal and is not a call, so `e`
        // used to carry no struct type at all, and `&mut e.len` then had
        // no field annotation to read. That is harmless while an
        // unresolved annotation means "permit"; R9's verdict is total, so
        // it would mean REFUSE, and a plain field borrow through a named
        // loan would stop compiling. Same shape as the call inference
        // above, added for the same reason.
        if (struct_name == null) {
            const referent: ?*const ast.Expr = if (refKind(v)) |r|
                r.operand
            else if (l.ownership == .shared or l.ownership == .exclusive)
                v
            else
                null;
            if (referent) |operand| {
                if (try self.placeOf(operand)) |p| {
                    if (self.bindingById(p.binding)) |rb| {
                        struct_name = self.placeStructName(rb, p.path);
                    }
                }
            }
        }
        try self.checkLetInit(l, v);
    }

    // `Binding.ty` resolves independently of `struct_name` above, and the
    // order is declared-type first so a written annotation always wins.
    var binding_ty: ?ast.TypeExpr = if (l.ty) |t| t else null;
    if (binding_ty == null) {
        if (l.value) |*v| binding_ty = try self.inferBindingType(v);
    }
    if (binding_ty == null) {
        if (struct_name) |n| binding_ty = .{ .name = n };
    }
    if (l.ownership == .copy) {
        try self.refuseResourceCopy(span, "binding", l.name, binding_ty);
    }

    _ = try self.declare(.{
        .id = 0,
        .name = l.name,
        .ownership = l.ownership,
        .mutable = l.mutable,
        .struct_name = struct_name,
        .ty = binding_ty,
        .decl_span = span,
    });
}

/// The initializer of a `let`. Four shapes matter, and the ORDER of the
/// first two is the rule rather than a detail:
///
/// * an `owned` binding initialized from a BORROW is refused (R18). This
///   is asked first, because every branch below it either creates a loan
///   or moves, and both of those are wrong answers for this shape.
/// * `&x` / `&mut x`, or a bare place under a `shared`/`exclusive`
///   annotation, creates a **named** loan that lives to the end of the
///   block. This is the loan provenance R5 asks for.
/// * a bare place under an `owned` annotation is a move (R2).
/// * anything else is an ordinary expression, and any loan inside it is a
///   temporary that dies with the statement.
pub fn checkLetInit(
    self: *Checker,
    l: *const @FieldType(ast.Stmt.Kind, "let"),
    written: *const ast.Expr,
) Error!void {
    // R2.b at the `let` position opens a block initializer first, like
    // every other `owned` consumption site; see `openBlockTail`.
    var v = written;
    var depth: usize = 0;
    defer self.closeBlockTail(depth);
    if (l.ownership == .owned or l.ownership == .arc) switch (try self.openBlockTail(written)) {
        .not_block => {},
        .unit => return,
        .tail => |t| {
            v = t.expr;
            depth = t.depth;
        },
    };
    // R18, the `let` position, and the ONE question asked about the
    // initializer's borrow-ness anywhere in this function.
    //
    // It is placed ABOVE the loan branch rather than inside it, and that
    // placement is the fix. The loan branch used to open this function and
    // never consulted `l.ownership` at all: `let owned xs = &list` became
    // a named loan and RETURNED, so the `.owned` branch below -- which
    // would have moved the lender -- was never reached. The lender was
    // therefore never moved, codegen's `pendingDrops` kept both it and the
    // binding, and one buffer was freed twice. Measured at `b61a107`:
    // `cell check` exit 0, `cc -fsanitize=address` exit 0, running it
    // `AddressSanitizer: attempting double-free` at exit 134.
    //
    // The classifier is `borrowSource`, which R14's rebinding clause
    // already uses, and reusing it is deliberate. The alternative was a
    // list of borrow SPELLINGS to reject, and a list is exactly the
    // reasoning failure this defect is an instance of: the old branch
    // matched `refKind`, which is the sigil forms, so `&list` and
    // `&mut list` crashed while `shared list` and `exclusive list` reached
    // the move below and silently moved the lender under a written
    // `shared` prefix -- a second wrong answer wearing exit 0.
    // `borrowSource`'s switch is exhaustive with no `else`, so a new
    // expression kind fails to COMPILE here rather than falling through
    // permissively, and a new borrow spelling is refused without a second
    // edit at this site.
    if (l.ownership == .owned) {
        switch (try self.borrowSource(v)) {
            .not_borrow => {},
            // `.unresolved` is deliberately NOT refused here, and the
            // reason is that this position already refuses its useful
            // half: R2.b's `ownedMoveSource` is total at this same site
            // and reports `refuseUnknownMove` for a field of a temporary
            // and an unresolved name. What is left over is a call whose
            // callee this checker cannot resolve, which borrowck sees for
            // an undeclared function that typecheck reports separately.
            // Refusing it here would make borrowck report a SECOND,
            // borrow-flavoured error for a program whose real defect is
            // an unknown name. The residual is stated rather than hidden:
            // an indirect call returning a borrow would slip through, and
            // this grammar has no function values for one to be written
            // with.
            .unresolved => {},
            .borrow => |s| {
                try self.diagnostics.err(
                    self.allocator,
                    s.span,
                    try self.msg(
                        "cannot bind {s} to the 'owned' binding '{s}': a borrow does not confer ownership",
                        .{ s.display, l.name },
                    ),
                );
                try self.diagnostics.note(
                    self.allocator,
                    s.span,
                    try self.msg(
                        "R18: an 'owned' binding is destroyed at the end of its scope (R16), so binding one to a borrow frees the lender's value twice; write 'let shared {s}' or 'let exclusive {s}' to hold the borrow",
                        .{ l.name, l.name },
                    ),
                );
                // The initializer is still walked, so a use-after-move or
                // a conflicting loan inside it is reported alongside this
                // rather than hidden behind it.
                try self.checkExpr(v);
                return;
            },
        }
    }
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
    if (l.ownership == .arc) {
        // R10's other direction, the `let` position, IMPLEMENTED for one
        // source shape (2026-09-16): a bare `owned` binding of `String`
        // or list type is MOVED into the fresh box, which the C backend
        // builds with `cell_arc_from_string`/`cell_arc_from_slice`, and
        // the moved source is no longer dropped. Every other source keeps
        // the refusal below: a field path, a branch, an `Int?`, and an
        // unresolved type. See `refuseUnimplementedArcMove`.
        if (try self.boxableOwnedBinding(v)) |place| {
            const note = try self.msg(
                "'{s}' was moved here into the 'arc' box '{s}'",
                .{ place.display, l.name },
            );
            try self.movePlace(place, note);
            return;
        }
        if (try self.refuseUnimplementedArcMove(v, "bind", "to", "binding", l.name)) return;
    }
    if (l.ownership == .owned) {
        // R10, the `let` position. Asked of the whole EXPRESSION's
        // verdict, so a value position
        // (`let owned ys: [Int] = match c { 0 => xs, _ => xs }`) and a
        // call result (`let owned ys: [Int] = fresh()`) are both refused.
        // See `arcUniqueSource`.
        if (try self.refuseArcUnique(
            try self.arcUniqueSource(v),
            "bind",
            "to",
            "binding",
            l.name,
        )) return;
        // R2.b, the `let` position, and the FIRST of the four live double
        // frees this rule closes. It replaces a bare `placeOf` here: a
        // `match` is not a place, so the old fall-through read `s1`
        // instead of moving it and `pendingDrops` freed the buffer twice.
        // See `ownedMoveSource`.
        switch (try self.ownedMoveSource(v)) {
            .place => |place| {
                // The `arc` case already returned above. `let owned ys:
                // [Int] = xs` with an `arc [Int]` source emitted
                // `cell_slice_t ys = *(...)xs.ptr;` followed by BOTH
                // `cell_slice_free(&ys)` and the box's own glue: an
                // AddressSanitizer double free, silent at `cell check` and
                // clean at `-Werror`.
                const note = try self.msg(
                    "'{s}' was moved here by binding it to '{s}'",
                    .{ place.display, l.name },
                );
                try self.movePlace(place, note);
                return;
            },
            .unknown => |s| {
                try self.refuseUnknownMove(s, "bind", "to", "binding", l.name);
                return;
            },
            // R7, the `let` position. Not a double free at `4698dbc` only
            // because an arm binding is never dropped either, so
            // `match s1 { x => { let owned y = x } }` merely aliased three
            // headers onto one buffer; it detonates the moment arm-scope
            // drops land, which is why it is refused with the live ones.
            .aliases_place => |s| {
                try self.refuseScrutineeAlias(s, "bind", "to", "binding", l.name);
                return;
            },
            .no_owned_place => {},
        }
    }
    // `copy` and `arc` bindings duplicate or retain rather than move
    // (R12, R10), so a bare place initializer is only read.
    try self.checkExpr(v);
}

/// What `openBlockTail` found at an `owned` consumption site.
pub const BlockTail = union(enum) {
    /// Not a block: consume the expression as written.
    not_block,
    /// A block yielding no value. Every statement was checked exactly
    /// once and no scope is left open. The site has nothing to consume
    /// and must RETURN (typecheck reports the unit mismatch); falling
    /// through to `checkExpr` would declare the block's `let`s a second
    /// time and break the binding-id lockstep with codegen.
    unit,
    /// The innermost tail expression, with `depth` scopes left OPEN so
    /// the site consumes it with the block's `let`s in scope. The site
    /// closes them with `closeBlockTail(depth)` when it is done.
    tail: struct { expr: *const ast.Expr, depth: usize },
};

/// A BLOCK in an `owned` consumption position is one path, not a
/// branch: its tail always evaluates, so consuming the tail is a real
/// move this checker can record, unlike an `if` or `match` whose taken
/// arm it cannot know. The block's statements are checked in a scope
/// that stays OPEN while the site consumes the tail as if it were the
/// expression written there, so a tail naming a block-local resolves
/// through `lookup` to the real binding and `movePlace` records the move
/// in `moved`, which outlives the scope (a future value-position drop
/// pass reads `wasMoved` for it). Every other tail shape gets the answer
/// it would get as a bare expression at that site: `&t` is R18 at a
/// `let`, an `arc` local is R10 naming it, a call falls to `checkExpr`.
/// A nested block tail opens again; an `owned` keyword in front of a
/// block is peeled the way `placeOf` peels it.
///
/// Done at the CONSUMPTION SITE and not inside `arcUniqueSource` /
/// `ownedMoveSource`, because those two walks run back to back over the
/// same expression and `checkExpr` may walk it a third time: declaring
/// the block's `let`s inside a walk would advance `next_binding_id` once
/// per walk and break the id lockstep with codegen. The scope and the
/// `open_blocks` entry are pushed exactly as `checkBlockStmts` does,
/// because a loan created inside the block records
/// `block_index`/`stmt_index` and is truncated by depth on the way out.
/// Each statement is checked exactly once here and the generic
/// `checkExpr` never sees an opened block, so the block's `let`s are
/// declared once, in codegen's order (statements, then the tail).
///
/// History: until 2026-09-15 a block-local tail was refused everywhere
/// ("cannot bind the unresolved name 't'"), then resolved at the `let`
/// alone (`checkOwnedLetFromBlock`, `b608d59`), and the same day at all
/// six sites through this one function. The classifier's own block arm
/// is now reached only through a branch, and its message says so.
pub fn openBlockTail(self: *Checker, e: *const ast.Expr) Error!BlockTail {
    var cur = e;
    var depth: usize = 0;
    while (true) {
        switch (cur.kind) {
            .annotated => |a| cur = a.value,
            .block => |stmts| {
                if (stmts.len == 0 or stmts[stmts.len - 1].kind != .expr) {
                    try self.checkBlockStmts(stmts);
                    self.closeBlockTail(depth);
                    return .unit;
                }
                try self.pushScope();
                try self.open_blocks.append(self.allocator, .{ .stmts = stmts, .index = 0 });
                depth += 1;
                for (stmts[0 .. stmts.len - 1], 0..) |*st, i| {
                    self.open_blocks.items[self.open_blocks.items.len - 1].index = i;
                    try self.checkStmt(st);
                }
                self.open_blocks.items[self.open_blocks.items.len - 1].index = stmts.len - 1;
                cur = &stmts[stmts.len - 1].kind.expr;
            },
            else => break,
        }
    }
    if (depth == 0) return .not_block;
    return .{ .tail = .{ .expr = cur, .depth = depth } };
}

/// Closes what `openBlockTail` left open, in the reverse of the order
/// `checkBlockStmts`'s defers run it. A `depth` of zero is a no-op, so a
/// site can `defer` this unconditionally.
pub fn closeBlockTail(self: *Checker, depth: usize) void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const blk = self.open_blocks.items[self.open_blocks.items.len - 1];
        if (blk.stmts.len > 0) {
            // After the tail is consumed, before the block's lets leave
            // scope: the value-block drop point. OOM here keeps the leak
            // rather than aborting a successful check.
            self.recordExit(.value_block_end, @intFromPtr(blk.stmts.ptr)) catch {};
        }
        _ = self.open_blocks.pop();
        self.popScope();
    }
}

/// The key codegen uses for a branch body: the block's statement slice
/// when the branch is a block, else the expression itself. Mirrored by
/// `codegen.branchKey`.
/// True only when `e` provably never falls through: a block whose last
/// statement is `return`, `break` or `continue`, or ends in an `if` with
/// an `else` whose branches both diverge, a `match` whose arms all do,
/// or a block that does.
/// Anything unproven is false, which keeps the conservative merge.
pub fn branchDiverges(e: *const ast.Expr) bool {
    switch (e.kind) {
        .block => |stmts| {
            if (stmts.len == 0) return false;
            const last = &stmts[stmts.len - 1];
            return switch (last.kind) {
                .return_stmt, .break_stmt, .continue_stmt => true,
                .expr => |*x| branchDiverges(x),
                else => false,
            };
        },
        .if_expr => |x| {
            const else_body = x.else_body orelse return false;
            return branchDiverges(x.then_body) and branchDiverges(else_body);
        },
        .match_expr => |x| {
            if (x.arms.len == 0) return false;
            for (x.arms) |arm| {
                if (!branchDiverges(arm.body)) return false;
            }
            return true;
        },
        else => return false,
    }
}

pub fn branchKeyOf(e: *const ast.Expr) usize {
    return switch (e.kind) {
        .block => |stmts| if (stmts.len > 0) @intFromPtr(stmts.ptr) else @intFromPtr(e),
        else => @intFromPtr(e),
    };
}

pub fn checkAssign(self: *Checker, a: *const @FieldType(ast.Stmt.Kind, "assign")) Error!void {
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

    // R9, the mutation half. Asked of the STRICT prefixes, so writing
    // `b.n = 2` through an `arc` binding is refused while `s = other` on
    // a `var arc s` stays legal: that one rebinds the handle, which is
    // R11's leak and not a mutation of the shared value.
    //
    // Measured before this at exit 0: `var arc b = B { n: 1 }` then
    // `b.n = 2` was accepted, and emitted `cell_arc_t b = (cell_B){...};
    // b.n = 2;`, which `cc` then refused. A loud C error is the mild end
    // of this rule; `&mut b.h` on an `arc` field was silent (see
    // `createLoan`).
    //
    // The spec's own R9 example, `pub fn rename(arc n: String) { n = "other" }`,
    // does NOT reach here: it is an empty path, so R14's immutability
    // check above fires first and reports its generic message. That is
    // unchanged and still what `examples/rejected/arc_mutation.cell`
    // pins; the explicit R9 message for a parameter rebind is still
    // designed only, and OWNERSHIP.md R9 says so.
    if (try self.refuseArcShared(
        try self.arcReach(place, .strict_prefix),
        place,
        .assign,
    )) {
        try self.checkExpr(&a.value);
        return;
    }

    // R5 applied to a write. The spec fixes the wording for reads only;
    // a write is strictly stronger than a read, so an outstanding loan of
    // either kind blocks it.
    //
    // THE FOURTH SITE. `readPlace`, `movePlace` and `createLoan` all
    // consulted the NLL predicate and this one did not, so an assignment
    // was rejected by a loan the other three had already stopped
    // rejecting. Three enumerated, a fourth missed.
    if (try self.findBlockingLoan(place, .exclusive)) |loan| {
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

    // R7's write clause (added 2026-09-15, night). An arm binding is an
    // ALIAS of the scrutinee: not a copy and not a loan, so R5's check
    // above never sees it, and codegen emits it as an unretained handle
    // copy. Writing the scrutinee while such an alias is in scope is a
    // write under an untracked view. For an `arc` var the R11 row 5
    // pre-drop takes the old box to zero at the store and the alias
    // reads freed memory: `match v { x => { v = "two" \n print(x) } }`
    // was an AddressSanitizer heap-use-after-free at 4c93571, flat and
    // inside a `while`. Refused for every ownership, not only `arc`: the
    // `owned` form leaked until 2026-09-16 and would dangle now, because
    // a never-moved `owned` var's reassignment has its own pre-drop. Asked of the ROOT
    // binding, so a write anywhere under the scrutinee's root is refused
    // while any arm alias of that root is visible; a sibling-field write
    // is over-refused, in the leak-safe direction.
    if (self.visibleArmAliasOf(place.binding)) |alias| {
        try self.diagnostics.err(
            self.allocator,
            place.span,
            try self.msg(
                "cannot assign to '{s}' while the match binding '{s}' aliases it",
                .{ place.display, alias.name },
            ),
        );
        try self.diagnostics.note(
            self.allocator,
            alias.decl_span,
            "R7: a match binding aliases the scrutinee rather than copying or borrowing it, and lasts to the end of its arm; assign after the match, or bind a copy of the value before it",
        );
        try self.checkExpr(&a.value);
        self.revive(place);
        return;
    }

    // R14's second clause: a binding that already holds a borrow may not
    // be reassigned. R14 already refuses this for a `let`, by
    // immutability; `var` reached here and nothing stopped it.
    //
    // THE STATEMENT HAS TWO MEANINGS AND THE COMPILER IMPLEMENTS BOTH,
    // DIFFERENTLY. For `var exclusive e = &mut a` then `e = &mut b`:
    //
    //   * this checker read it as a RETARGET, and read it wrong. `placeOf`
    //     returns null for a unary, so `checkExpr` made a TEMPORARY loan
    //     on `b` that died with the statement, while `e`'s named loan
    //     still pointed at `a`. After the statement there was a loan on
    //     `a` and NONE on `b`, so `take(owned b)` was accepted.
    //   * the C backend reads it as a WRITE THROUGH, and emits
    //     `*e = *&b;`, copying `b`'s value into `a`.
    //
    // The second reading is the one that runs, and it is a live double
    // free, not a stale-loan nuisance. Measured on
    //
    //     var owned a = make()   var owned b = make()
    //     var exclusive e = &mut a
    //     e = &mut b
    //
    // with `make() -> String`: the emit was `*e = *&b;` followed by
    // `cell_string_free(&b); cell_string_free(&a);`, `a` and `b` holding
    // the same buffer. AddressSanitizer: attempting double-free, exit 134.
    // `a`'s original buffer leaks in the same statement.
    //
    // So this is refused rather than modelled. Modelling the retarget
    // would mean killing `e`'s old loan, and killing a loan is the unsafe
    // direction under a name-keyed holder; modelling the write-through
    // would mean a place for `*e`, which the "places, not names" model
    // does not have (a place is a binding plus a field path, and a
    // referent is a different binding). Neither is a contained change, and
    // the language has not decided which meaning it wants. Refusing costs
    // a program that can be spelled with a fresh `let`.
    //
    // Scoped to an EMPTY path and to a borrow-producing value, so the two
    // legitimate neighbours survive: `buf.len = new_len` through an
    // `exclusive buf: Buffer` (a field write, and `examples/ownership.cell`
    // does it) and `e = B { n: 3 }` (a whole-value write-through, which
    // `runtime/cell_rt.h` section 7 defines and a codegen fix already
    // landed for). `borrowSource` is what tells those from a retarget, and
    // it is total: a value it cannot classify is refused too.
    if (place.path.len == 0 and self.holdsBorrow(b)) {
        switch (try self.borrowSource(&a.value)) {
            .not_borrow => {},
            .borrow => |s| {
                try self.diagnostics.err(
                    self.allocator,
                    place.span,
                    try self.msg(
                        "cannot assign {s} to '{s}': it already holds a borrow, and rebinding one is not defined in this revision",
                        .{ s.display, place.display },
                    ),
                );
                try self.diagnostics.note(
                    self.allocator,
                    place.span,
                    "the C backend writes THROUGH the borrow rather than retargeting it, so the two readings of this statement differ; bind a new name instead",
                );
                try self.checkExpr(&a.value);
                return;
            },
            .unresolved => |s| {
                try self.diagnostics.err(
                    self.allocator,
                    place.span,
                    try self.msg(
                        "cannot assign to '{s}', which holds a borrow: {s} cannot be classified as a value or a borrow here",
                        .{ place.display, s.display },
                    ),
                );
                try self.diagnostics.note(
                    self.allocator,
                    place.span,
                    "R14 refuses what it cannot prove is not a borrow: a retarget the checker does not see leaves a loan on the old referent and none on the new one",
                );
                try self.checkExpr(&a.value);
                return;
            },
        }
    }

    // R2.b: a block value is opened first (see `openBlockTail`), so `v`
    // is what this site consumes from here on.
    var v: *const ast.Expr = &a.value;
    var depth: usize = 0;
    defer self.closeBlockTail(depth);

    // R10's other direction, the assignment position: the sweep's
    // `assign arc <- owned String` row. See `refuseUnimplementedArcMove`.
    if (self.placeOwnership(b, place.path) == .arc) {
        // IMPLEMENTED for one source shape (2026-09-16), the same one
        // `let arc` and a direct return take: a bare `owned` `String` or
        // list binding stored into a WHOLE `arc` binding. The move is the
        // shared one at the end of this function, and the C backend's
        // reassignment pre-drop releases the old box before
        // `isMovedOwnedBinding` boxes the moved source. A field target
        // (`r.a = p`, the struct-field store) and a block value keep the
        // refusal: neither box path was built or measured.
        const boxable = place.path.len == 0 and a.value.kind != .block and
            try self.boxableOwnedBinding(&a.value) != null;
        if (!boxable) {
            if (try self.refuseUnimplementedArcMove(&a.value, "assign", "to", "place", place.display)) return;
        }
    }
    // R10, the assignment position: the same double free as the `let`
    // one, reached by writing into an already-declared `owned` place
    // instead of declaring a new one. Asked of the whole EXPRESSION's
    // verdict, so a value position and a call result are both refused.
    if (self.placeOwnership(b, place.path) == .owned) {
        switch (try self.openBlockTail(&a.value)) {
            .not_block => {},
            .unit => {
                self.revive(place);
                return;
            },
            .tail => |t| {
                v = t.expr;
                depth = t.depth;
            },
        }
        if (try self.refuseArcUnique(
            try self.arcUniqueSource(v),
            "assign",
            "to",
            "place",
            place.display,
        )) {
            self.revive(place);
            return;
        }
        // R2.b, the assignment position. Scoped to an `owned` TARGET,
        // because the double free needs the target to be dropped and
        // `pendingDrops` drops `.owned` bindings. Measured at `0e82266`:
        // `s2 = match c { 0 => s1, _ => s1 }` was exit 134.
        switch (try self.ownedMoveSource(v)) {
            .unknown => |s| {
                try self.refuseUnknownMove(s, "assign", "to", "place", place.display);
                self.revive(place);
                return;
            },
            // R7, the assignment position. Measured at `4698dbc`:
            // `match s1 { x => { d = x } }` into a `var owned d` was
            // exit 134.
            .aliases_place => |s| {
                try self.refuseScrutineeAlias(s, "assign", "to", "place", place.display);
                self.revive(place);
                return;
            },
            // A place is moved by the shared path below, unchanged.
            .place, .no_owned_place => {},
        }
    }

    if (try self.placeOf(v)) |src| {
        const note = try self.msg(
            "'{s}' was moved here by assigning it to '{s}'",
            .{ src.display, place.display },
        );
        try self.movePlace(src, note);
    } else {
        try self.checkExpr(v);
    }

    // Asked here, after the right side, and before the revival below
    // erases the answer. Only a whole-binding target named by a bare
    // identifier is recorded; everything else keeps the plain store.
    if (place.path.len == 0) {
        if (assignTargetName(&a.target)) |name| {
            try self.assign_liveness.append(self.allocator, .{
                .key = @intFromPtr(name.ptr),
                .binding = place.binding,
                .live = self.findDead(place) == null,
            });
        }
    } else if (b.ownership == .owned and self.placeOwnership(b, place.path) == .owned) {
        // A field store (see `field_assign_liveness`). `ast.rootName`
        // walks `.field` and `.annotated` only, so a deref, index or
        // call anywhere in the chain records nothing.
        if (ast.rootName(&a.target)) |root| {
            try self.field_assign_liveness.append(self.allocator, .{
                .key = @intFromPtr(root.ptr),
                .binding = place.binding,
                .live = self.findDead(place) == null,
            });
        }
    }

    // R3a: the target is live again.
    self.revive(place);
}

/// The identifier an assignment target names, through annotations.
pub fn assignTargetName(target: *const ast.Expr) ?[]const u8 {
    var t = target;
    while (t.kind == .annotated) t = t.kind.annotated.value;
    return switch (t.kind) {
        .ident => |n| n,
        else => null,
    };
}
