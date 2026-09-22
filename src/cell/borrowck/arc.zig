//! R9 and R10 (`arc`): `arcUniqueSource`'s total verdict, the six arc-unique
//! consumption sites, move-into-arc, and R7's match-arm alias sources.
//! Part of the borrow checker; the rules and their rationale are in the module header of `../borrowck.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const Span = ast.Span;
const bk_model = @import("model.zig");
const bk_root = @import("../borrowck.zig");
const Checker = bk_root.Checker;
const Error = bk_model.Error;
const Place = bk_model.Place;
const typeStructName = bk_model.typeStructName;
const findField = bk_model.findField;

/// What R10 needs to know about an expression that is about to be
/// consumed in an `owned` position, which is to say made UNIQUE.
///
/// **The verdict is total, and the totality is the whole point.** This
/// used to be `Error!?Place`, so every expression form the classifier did
/// not recognise as `arc` came back `null` and was PERMITTED. That makes
/// silence mean "safe", and silence is exactly what an unenumerated form
/// produces. Here silence is `.unknown`, which is REFUSED. Acceptance is
/// the direction that needs proof: a refusal costs a program that can be
/// spelled another way, an acceptance costs a double free.
pub const ArcSource = union(enum) {
    /// Provably not `arc`. Every arm that returns this states why.
    not_arc,
    /// An `arc` place. Nameable, so the diagnostic names it.
    arc_place: Site,
    /// `arc` with no place behind it: a call whose declared return type is
    /// `arc`. The caller's temporary drops that box, so making its pointee
    /// unique frees the same buffer twice.
    arc_value: Site,
    /// Ownership could not be decided here. Refused, not permitted.
    unknown: Site,

    pub const Site = struct {
        /// For `arc_place` and `arc_value`, a name the message quotes.
        /// For `unknown`, a noun phrase the message does not quote.
        display: []const u8,
        span: Span,
    };

    /// Combine two branch verdicts. An `arc` verdict from any branch wins,
    /// because any branch may be the one taken; otherwise an `unknown`
    /// wins over `not_arc` for the same reason.
    fn join(a: ArcSource, b: ArcSource) ArcSource {
        return switch (a) {
            .arc_place => a,
            .arc_value => switch (b) {
                .arc_place => b,
                else => a,
            },
            .unknown => switch (b) {
                .arc_place, .arc_value => b,
                else => a,
            },
            .not_arc => b,
        };
    }
};

/// Classify what an `owned` position would make unique. **One function,
/// used by all six of R10's consumption sites**, rather than a seventh
/// copy of the question at a seventh call site.
///
/// WHY IT EXISTS, and the three axes it has now been widened along. R10's
/// refusal was first spelled as `placeOf(e)` followed by an `arc` test, at
/// each position separately, which asks only whether the expression IS an
/// `arc` place.
///
/// 1. **Expression shape**, place versus value. A `match` is valued and is
///    not a place, so `placeOf` returned null and all four positions let
///    it through: `take(owned xs)` was refused while
///    `take(owned match c { 0 => xs, _ => xs })` was accepted, for the
///    same binding and the same semantic operation. Closed by looking
///    THROUGH the value positions. Measured at `23353e9^`: the emitted C
///    unboxed the arc into an `owned` parameter, and it was masked rather
///    than crashing, because the `cell_arc_clone` in the value temporary
///    was never released.
/// 2. **Arc source**, a binding's annotation versus a signature's return
///    type. `take(owned fresh())` with `fresh() -> arc [Int]` was accepted
///    because no place and no expression shape carries the `arc`-ness.
///    That one was NOT masked: `460b9a3` gave the unbound call temporary
///    its `cell_arc_drop`, so from that commit onward it was an
///    AddressSanitizer double free at exit 134, seven commits before the
///    axis-1 fix claimed to be landing ahead of any such change. Closed by
///    `.call` reading the callee's return type.
/// 3. **Consumption site.** Four positions were enumerated and a property
///    of every consumption asserted. A list-literal element and a `return`
///    are consumptions that were never asked. Closed by asking at both.
///
/// THE SHAPE OF THE MISS, since every one of the three is the same shape:
/// a derivation that enumerated some forms of a construct and asserted a
/// property of all of them. The structural answer is not a longer
/// enumeration, it is a verdict with no permissive default, which is what
/// `.unknown` is.
///
/// The switch is exhaustive with no `else` arm, and it is exhaustive over
/// the FIELDS of each variant it descends into, not only over the variants
/// themselves: a `match` visits every arm, an `if` visits both branches, a
/// `unary` splits on its operator. Those are different claims, and
/// treating them as one is what hid a match GUARD from `exprUsesName` in
/// this same file.
///
/// `if` and `block` cannot reach a typed `owned` position today, because
/// typecheck gives both the type `()`. They are handled anyway: an
/// ownership rule enforced by an accident of the type checker is exactly
/// the fragility R10's own text objects to elsewhere, and borrowck runs
/// independently of typecheck, so its own tests reach them.
pub fn arcUniqueSource(self: *Checker, e: *const ast.Expr) Error!ArcSource {
    if (try self.placeOf(e)) |place| {
        const site: ArcSource.Site = .{ .display = place.display, .span = place.span };
        const unresolved: ArcSource = .{ .unknown = .{
            .display = try self.msg("the place '{s}'", .{place.display}),
            .span = place.span,
        } };
        const b = self.bindingById(place.binding) orelse
            // A place whose binding id does not resolve. It should not
            // happen, and if it does the annotation is unreadable.
            return unresolved;
        const own = self.placeOwnership(b, place.path) orelse
            // A field path whose struct type could not be resolved, so the
            // annotation that decides this was never read. `checkLet`
            // infers that type from a declared type, a struct literal and
            // a call's return type; a `match` or block initializer in an
            // unannotated `let` still lands here.
            return unresolved;
        if (own == .arc) return .{ .arc_place = site };
        // A place with a declared, resolved, non-`arc` annotation. It is
        // still a place, so there is no value position underneath it.
        return .not_arc;
    }
    return switch (e.kind) {
        // A scalar or string literal is a fresh value with no handle
        // behind it. `arc` is a property of a binding or a signature, and
        // a literal has neither.
        .int, .float, .string, .bool => .not_arc,
        // A struct or list literal constructs a fresh record or buffer.
        // Whatever its ELEMENTS are is the list-literal site's question,
        // asked there; the literal itself is unique by construction.
        .struct_lit, .list_lit => .not_arc,
        // Every binary operator in this grammar is arithmetic, comparison
        // or logic, and yields a fresh scalar.
        .binary => .not_arc,
        .unary => |u| switch (u.op) {
            // A fresh scalar.
            .neg, .not => .not_arc,
            // A borrow. The value is a reference to the pointee and not
            // an `arc` handle, so it cannot be the thing a box frees
            // twice. Consuming a borrow in an `owned` position is R15's
            // annotation disagreement and R9's mutation rule, not R10's.
            .ref_shared, .ref_exclusive => .not_arc,
        },
        .call => |c| try self.arcCallResult(c.callee, e.span),
        .annotated => |a| try self.arcUniqueSource(a.value),
        // An `ident` reaching here means `lookup` failed: the name is not
        // in scope, so nothing decides its ownership.
        .ident => |n| .{ .unknown = .{
            .display = try self.msg("the unresolved name '{s}'", .{n}),
            .span = e.span,
        } },
        // A `field` reaching here is rooted at something that is not a
        // binding. Two very different things wear that shape, and the
        // first was found by the gate rather than by reasoning:
        //
        //   * `Quadrant.First`, a qualified ENUM VARIANT. The base names a
        //     type, not a binding, so `placeOf` fails. A variant in this
        //     grammar carries no payload (see ast.Pattern's comment), so
        //     it is a unit constant and can never be an `arc` box.
        //   * `fresh().len`, a field of a temporary. The base's ownership
        //     was not resolved, so neither is the field's.
        .field => |f| blk: {
            if (f.base.kind == .ident and
                self.enums.contains(f.base.kind.ident)) break :blk .not_arc;
            break :blk .{ .unknown = .{
                .display = try self.msg("the field '{s}' of a temporary value", .{f.name}),
                .span = e.span,
            } };
        },
        // A Byte? copy of one element; not an arc handle.
        .index => .not_arc,
        .if_expr => |i| blk: {
            const then_v = try self.arcUniqueSource(i.then_body);
            // A missing `else` yields unit on that path, which is not
            // `arc` and is not unknown.
            const else_v: ArcSource = if (i.else_body) |eb|
                try self.arcUniqueSource(eb)
            else
                .not_arc;
            break :blk ArcSource.join(then_v, else_v);
        },
        .match_expr => |m| blk: {
            var acc: ArcSource = .not_arc;
            for (m.arms) |arm| {
                if (wrapPayloadBody(arm)) {
                    acc = ArcSource.join(acc, .not_arc);
                    continue;
                }
                acc = ArcSource.join(acc, try self.arcUniqueSource(arm.body));
            }
            break :blk acc;
        },
        // A block's value is its trailing expression statement. A block
        // that ends in anything else (or in nothing) yields unit.
        //
        // A tail naming one of the block's OWN `let`s cannot resolve
        // here: this walk runs without the block's scope, on purpose.
        // Every `owned` consumption site opens a block with
        // `openBlockTail` before asking, so a block reaching this arm
        // sits under an `if` or `match` arm (or a borrow operand), and
        // the message names that route.
        .block => |stmts| blk: {
            if (stmts.len == 0) break :blk .not_arc;
            const last = &stmts[stmts.len - 1];
            if (last.kind != .expr) break :blk .not_arc;
            if (blockLocalTail(stmts)) |name| break :blk .{ .unknown = .{
                .display = try self.msg("the block-local binding '{s}' reached through a branch", .{name}),
                .span = last.kind.expr.span,
            } };
            break :blk try self.arcUniqueSource(&last.kind.expr);
        },
        // A fresh value with no handle behind it, like a literal.
        .wrap => .not_arc,
    };
}

/// R10 axis 2: the `arc`-ness of a CALL RESULT, which comes from the
/// callee's declared return type rather than from any binding annotation.
///
/// `-> arc [Int]` parses as `TypeExpr.ref` with `.arc` ownership, the same
/// node `typeIsBorrow` reads for `shared` and `exclusive`. A call whose
/// return type is `arc` hands back a box the caller's temporary will
/// `cell_arc_drop`; unboxing that temporary into an `owned` position hands
/// the same buffer to a holder that frees it, and the glue frees it again.
///
/// A callee this checker cannot resolve is `.unknown` and therefore
/// refused. `cell check` already errors on an unknown callee in the
/// typechecker, so no program that was otherwise accepted is lost; what is
/// gained is that a future indirect-call form does not silently inherit a
/// permissive default.
pub fn arcCallResult(self: *Checker, callee: *const ast.Expr, span: Span) Error!ArcSource {
    const name: []const u8 = switch (callee.kind) {
        .ident => |n| n,
        else => return .{ .unknown = .{
            .display = "the result of an indirect call",
            .span = span,
        } },
    };
    const sig = self.fns.get(name) orelse return .{ .unknown = .{
        .display = try self.msg("the result of the unresolved callee '{s}'", .{name}),
        .span = span,
    } };
    const rt = sig.return_type orelse
        // No declared return type: the call yields unit, and unit is not
        // an `arc` box.
        return .not_arc;
    const is_arc = switch (rt) {
        .ref => |r| r.ownership == .arc,
        // A plain, optional, list or result type carries no ownership
        // prefix, so R1 makes it `owned`.
        .name, .optional, .list, .result, .unit => false,
    };
    if (!is_arc) return .not_arc;
    return .{ .arc_value = .{
        .display = try self.msg("{s}()", .{name}),
        .span = span,
    } };
}

/// R2.b: what an `owned` consumption position takes ownership OF.
///
/// **The verdict is total, for the same reason `ArcSource`'s is and after
/// the same defect.** R2 enumerates the forms that MOVE a place, and every
/// one of its consumption sites asked `placeOf` first: a place moved, and
/// anything else fell through to `checkExpr`, which only READS. That is an
/// enumeration of PLACE initializers standing in for a claim about every
/// initializer, which is R10 axis 1 recurring in the rule R10 is a special
/// case of. `placeOf` returns null for a `match`, so
///
///     let owned s2: String = match c { 0 => s1, _ => s1 }
///
/// read `s1` instead of moving it. `wasMoved(s1)` stayed false, codegen's
/// `pendingDrops` therefore dropped BOTH `s1` and `s2`, and the leaf
/// emitted a bitwise `_cell_t0 = s1;` so the two headers hold one buffer:
/// `cell check` exit 0, `cc -fsanitize=address` exit 0, running it exit
/// 134, `AddressSanitizer: attempting double-free`. Measured at
/// `0e82266` at four sites, all four live.
///
/// **Silence must not mean "read it".** `.unknown` is REFUSED. A shape
/// nobody enumerated is exactly what produces silence here, and the cost
/// of the two directions is not symmetric: a refusal costs a program that
/// can be spelled with an explicit binding, an acceptance costs a double
/// free.
///
/// **A place reached THROUGH a branch is never `.place`.** Promoting it to
/// a move is the wrong repair and is not available: a `match` yielding a
/// place from two arms is two potential moves of one value, and deciding
/// which one happened is the dataflow question `docs/OWNERSHIP.md` 0.3
/// deliberately does not answer. `ownedMoveBranch` performs that promotion
/// to `.unknown`, so no recursive arm can hand a movable place back up.
///
/// The switch is exhaustive with no `else` arm, and exhaustive over the
/// FIELDS of each variant it descends into rather than only over the
/// variants: a `match` visits every arm, an `if` visits both branches, a
/// `unary` splits on its operator. Those are different claims and treating
/// them as one is what hid a match GUARD from `exprUsesName` in this file.
pub const OwnedMove = union(enum) {
    /// Provably hands over no place an existing binding still holds: a
    /// literal, a fresh scalar, a borrow, a fresh aggregate, or a call's
    /// temporary. Every arm that returns this states why.
    no_owned_place,
    /// The expression IS a place. Moved, exactly as before this rule
    /// existed. This is the ONLY verdict that moves, and it is reachable
    /// only from the top of `ownedMoveSource`, never from a branch.
    place: Place,
    /// A value shape that may give up an owned place, on a path this
    /// checker does not resolve. Refused, not read.
    unknown: ArcSource.Site,
    /// **R7.** The expression is a place rooted at a match-arm binding
    /// that ALIASES a scrutinee place. Consuming it hands over a buffer
    /// the scrutinee's own drop frees again, because R7 does not move the
    /// scrutinee. Refused at every site that would MOVE a `.place`, and
    /// read at the two sites that already only read one.
    ///
    /// A separate variant rather than a reuse of `.unknown` on purpose:
    /// this switch has no `else` arm anywhere it is consumed, so adding it
    /// made every consumption site a compile error until it answered. That
    /// is the enumeration done by the compiler instead of by the author,
    /// which is the failure mode this file has hit four times.
    aliases_place: ArcSource.Site,

    /// Combine two branch verdicts. `.unknown` from any branch wins,
    /// because any branch may be the one taken.
    ///
    /// `.place` cannot appear on either side: every recursive call in a
    /// branch position goes through `ownedMoveBranch`, which promotes it.
    /// It is still handled rather than left to an `else`, and it is
    /// handled by REFUSING to let it out, so that if a future arm forgets
    /// the promotion the result is an over-refusal and not a move the
    /// caller cannot justify.
    fn join(a: OwnedMove, b: OwnedMove) OwnedMove {
        return switch (a) {
            // `.aliases_place` joins with `.unknown` and `.place`: all
            // three are verdicts a branch must not hand back as movable,
            // and letting one win is the over-refusing direction.
            .unknown, .place, .aliases_place => a,
            .no_owned_place => b,
        };
    }
};

/// `ownedMoveSource` in a BRANCH position, where a place is not movable.
/// See `OwnedMove`'s comment for why the promotion is the fix and a move
/// is not.
/// True when this arm's body is the wrap-pattern payload itself. That
/// payload is a scalar copy (spec B.2), so it owns nothing and is not
/// `arc`. Asked during `ownedMoveSource`/`arcUniqueSource` of a match,
/// which run BEFORE `checkMatch` declares the binding; a lookup of the
/// name would otherwise fail closed as "unresolved".
pub fn wrapPayloadBody(arm: ast.MatchArm) bool {
    if (arm.pattern.kind != .wrap_pattern) return false;
    const name = arm.pattern.kind.wrap_pattern.binding orelse return false;
    var body: *const ast.Expr = arm.body;
    while (body.kind == .annotated) body = body.kind.annotated.value;
    return body.kind == .ident and std.mem.eql(u8, body.kind.ident, name);
}

pub fn ownedMoveBranch(self: *Checker, e: *const ast.Expr) Error!OwnedMove {
    return switch (try self.ownedMoveSource(e)) {
        .no_owned_place => .no_owned_place,
        .place => |p| .{ .unknown = .{
            .display = try self.msg("the place '{s}' reached through a branch", .{p.display}),
            .span = p.span,
        } },
        .unknown => |s| .{ .unknown = s },
        // Promoted to `.unknown` for the same reason `.place` is: the two
        // sites that read a `.place` rather than moving it must not start
        // reading one reached through a branch either, and `.unknown` is
        // the verdict every site already refuses. The display already
        // names the arm binding and its scrutinee, so nothing is lost.
        .aliases_place => |s| .{ .unknown = s },
    };
}

/// R7's one question, asked once, at the single point every `owned`
/// consumption site routes through. See `OwnedMove.aliases_place`.
///
/// It sits above the `.place` return rather than beside it because a
/// place rooted at an aliasing arm binding IS a place: `placeOf` resolves
/// it, R2's move list covers it, and moving it is exactly the defect.
/// Asking here means a consumption site added later inherits the answer
/// without knowing R7 exists.
pub fn armAlias(self: *Checker, place: Place) Error!?ArcSource.Site {
    const b = self.bindingById(place.binding) orelse return null;
    switch (b.arm_origin) {
        .not_an_arm, .temp => return null,
        .alias => {},
    }
    const scrutinee = b.arm_scrutinee orelse "the scrutinee";
    return .{
        .display = try self.msg(
            "the match binding '{s}' aliasing '{s}'",
            .{ place.display, scrutinee },
        ),
        .span = place.span,
    };
}

pub fn ownedMoveSource(self: *Checker, e: *const ast.Expr) Error!OwnedMove {
    if (try self.placeOf(e)) |place| {
        if (try self.armAlias(place)) |site| return .{ .aliases_place = site };
        return .{ .place = place };
    }
    return switch (e.kind) {
        // A literal is a fresh value with no binding behind it.
        .int, .float, .string, .bool => .no_owned_place,
        // Every binary operator in this grammar is arithmetic, comparison
        // or logic, and yields a fresh scalar.
        .binary => .no_owned_place,
        .unary => |u| switch (u.op) {
            // A fresh scalar.
            .neg, .not => .no_owned_place,
            // A borrow does not own its referent, so consuming it hands
            // over nothing that a drop would free twice. Consuming a
            // borrow in an `owned` position is R18 at a `let`, R3's
            // move-out-of-a-borrow at a move, and R15's annotation
            // disagreement at a call; all three run elsewhere and none of
            // them is this question.
            //
            // CORRECTED: this comment used to name only R3 and R15 and
            // say "both of which run elsewhere". At the `let` position
            // nothing ran, and that sentence is exactly the assumption
            // the double free lived in. R18 is the check that now does.
            .ref_shared, .ref_exclusive => .no_owned_place,
        },
        // A struct or list literal builds a FRESH record or buffer, so the
        // aggregate itself gives up nothing. What its elements give up is
        // the element sites' question, asked there.
        .struct_lit, .list_lit => .no_owned_place,
        // A call's result is a temporary the callee produced, not a place
        // the caller still holds.
        .call => .no_owned_place,
        // `placeOf` already peels `.annotated`, so reaching here means the
        // operand is not a place: `owned mk()` is the call arm above and
        // `owned match ...` is the match arm below. Recursing therefore
        // adds no move that `placeOf` was not already making, which
        // matters because a NEW move would change what codegen's
        // `pendingDrops` frees. Measured at `0e82266`:
        // `let owned s2: String = owned s1` already reports use-after-move
        // on `s1`, and `owned match c { 0 => s1, _ => s1 }` was exit 134.
        .annotated => |a| try self.ownedMoveSource(a.value),
        // An `ident` reaching here means `lookup` failed: the name is not
        // in scope, so nothing decides what it owns.
        .ident => |n| .{ .unknown = .{
            .display = try self.msg("the unresolved name '{s}'", .{n}),
            .span = e.span,
        } },
        // A `field` reaching here is rooted at something that is not a
        // binding. Two different things wear that shape, as
        // `arcUniqueSource` records:
        //
        //   * `Quadrant.First`, a qualified ENUM VARIANT. A variant in
        //     this grammar carries no payload, so it is a unit constant
        //     and owns nothing.
        //   * `mk_box().s`, a field of a temporary. Which place that
        //     temporary's field came from is not resolved here.
        .field => |f| blk: {
            if (f.base.kind == .ident and
                self.enums.contains(f.base.kind.ident)) break :blk .no_owned_place;
            break :blk .{ .unknown = .{
                .display = try self.msg("the field '{s}' of a temporary value", .{f.name}),
                .span = e.span,
            } };
        },
        // Indexing copies a byte; it is not an owned place and does not
        // move the base. The read is `checkExpr`'s.
        .index => .no_owned_place,
        .if_expr => |i| blk: {
            const then_v = try self.ownedMoveBranch(i.then_body);
            // A missing `else` yields unit on that path, which owns
            // nothing and is not unknown.
            const else_v: OwnedMove = if (i.else_body) |eb|
                try self.ownedMoveBranch(eb)
            else
                .no_owned_place;
            break :blk OwnedMove.join(then_v, else_v);
        },
        .match_expr => |m| blk: {
            var acc: OwnedMove = .no_owned_place;
            for (m.arms) |arm| {
                if (wrapPayloadBody(arm)) {
                    acc = OwnedMove.join(acc, .no_owned_place);
                    continue;
                }
                acc = OwnedMove.join(acc, try self.ownedMoveBranch(arm.body));
            }
            break :blk acc;
        },
        // A block's value is its trailing expression statement. A block
        // that ends in anything else, or in nothing, yields unit. A tail
        // naming one of the block's own `let`s is unresolvable here, as
        // `arcUniqueSource`'s arm explains; no consumption site reaches
        // this arm with its own block any more (`openBlockTail`), only a
        // branch does.
        .block => |stmts| blk: {
            if (stmts.len == 0) break :blk .no_owned_place;
            const last = &stmts[stmts.len - 1];
            if (last.kind != .expr) break :blk .no_owned_place;
            if (blockLocalTail(stmts)) |name| break :blk .{ .unknown = .{
                .display = try self.msg("the block-local binding '{s}' reached through a branch", .{name}),
                .span = last.kind.expr.span,
            } };
            break :blk try self.ownedMoveBranch(&last.kind.expr);
        },
        // A fresh value with no place behind it.
        .wrap => .no_owned_place,
    };
}

/// R2.b's refusal. `verb`, `prep` and `slot` name the position, so all six
/// consumption sites read as the same rule, the way `refuseArcUnique`'s do.
///
/// It is a refusal and not a move, and that is not a conservative default
/// chosen for taste. Moving would require deciding which path produced the
/// value, and `docs/OWNERSHIP.md` 0.3 chose a checker with no control-flow
/// graph. Reading, which is what happened before this rule, is the one
/// answer that is definitely wrong: the source is dropped at its scope end
/// and the consumer frees the same buffer.
pub fn refuseUnknownMove(
    self: *Checker,
    s: ArcSource.Site,
    verb: []const u8,
    prep: []const u8,
    slot: []const u8,
    slot_name: ?[]const u8,
) Error!void {
    const message = if (slot_name) |n|
        try self.msg(
            "cannot {s} {s} {s} 'owned' {s} '{s}': which owned place it gives up cannot be resolved here",
            .{ verb, s.display, prep, slot, n },
        )
    else
        try self.msg(
            "cannot {s} {s} {s} an 'owned' {s}: which owned place it gives up cannot be resolved here",
            .{ verb, s.display, prep, slot },
        );
    try self.diagnostics.err(self.allocator, s.span, message);
    try self.diagnostics.note(
        self.allocator,
        s.span,
        "R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path",
    );
}

/// R7's refusal. Its own function and not `refuseUnknownMove`, because
/// that one's note tells the reader to "bind the value to a name first",
/// and here the name IS the problem: the arm binding is the alias.
///
/// It is a refusal and not a move of the scrutinee, and that is a scoped
/// decision rather than the end state. Moving the scrutinee is the better
/// semantics and would additionally make a later `take(owned s1)` report
/// use-after-move for the right reason; it is recorded as the designed
/// follow-up in `docs/OWNERSHIP.md` R7. It is not done here because it
/// changes `wasMoved` for every arm binding and codegen's `pendingDrops`
/// reads that, which is the exact shape of the three fixes in this
/// repository that each shipped a new silent miscompile in their own first
/// commit.
pub fn refuseScrutineeAlias(
    self: *Checker,
    s: ArcSource.Site,
    verb: []const u8,
    prep: []const u8,
    slot: []const u8,
    slot_name: ?[]const u8,
) Error!void {
    const message = if (slot_name) |n|
        try self.msg(
            "cannot {s} {s} {s} 'owned' {s} '{s}': the scrutinee still owns the value",
            .{ verb, s.display, prep, slot, n },
        )
    else
        try self.msg(
            "cannot {s} {s} {s} an 'owned' {s}: the scrutinee still owns the value",
            .{ verb, s.display, prep, slot },
        );
    try self.diagnostics.err(self.allocator, s.span, message);
    try self.diagnostics.note(
        self.allocator,
        s.span,
        "R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again",
    );
}

/// R10: an `arc` place may not be made unique. `verb` and `slot` name the
/// position, so every one of them reads as the same rule.
///
/// It is a REFUSAL and not a retain, and that is not a stylistic call.
/// `owned [T]` and `shared [T]` lower to the SAME C type (`cell_slice_t`
/// by value), so the C backend's unbox compiles clean at
/// `-Wall -Wextra -Werror` and then `runtime/cell_rt.h` section 7 makes
/// the `owned` holder free the buffer while `cell_slice_drop_glue` frees
/// the same buffer again when the box dies. `cell_arc_clone` increments a
/// refcount, and the buffer is not what the refcount governs, so no
/// retain can fix it. Measured as an AddressSanitizer double free at the
/// parameter, `let` and assignment positions alike.
///
/// The `owned String` analogue is a loud C type error instead, because
/// `owned String` and `shared String` do NOT share a C type. Refusing it
/// here too is deliberate: one rule that holds for every type beats a
/// rule whose enforcement depends on which two C types happen to
/// coincide.
/// Returns true when it refused, so the caller can stop treating the
/// expression as an ordinary move. `.not_arc` is the ONLY verdict that
/// passes; `.unknown` is refused with its own wording, so a reader can
/// tell "this is `arc`" from "this could not be proven not to be".
/// R10's move-into-`arc` direction, refused as UNIMPLEMENTED rather than
/// enforced as illegal. The mirror of `refuseArcUnique` above, and the
/// distinction matters: that one refuses `arc` into `owned` because no
/// retain can make it sound, while this one refuses `owned` into `arc`
/// because the feature is not built. R10's table calls this row legal and
/// says the source is "moved into a fresh `arc` box", and
/// `docs/OWNERSHIP.md` has said since it was written that move-into-`arc`
/// is not implemented in the checker. Those two sentences were reconciled
/// by a diagnostic on 2026-09-16.
///
/// WHAT IT WAS BEFORE, and why making it compile was the wrong fix. The
/// sweep (`tools/sweep-backends.sh`, 88 probed) reported exactly four
/// rows, all one shape: `let arc String = param`, `let arc [Int] = param`,
/// `let arc Int? = param`, `assign arc <- owned String`, each
/// `C UNCOMPILABLE: initializing 'cell_arc_t'`. `cell check` accepted them
/// and `cc` refused them, so the tempting fix was to box the place in
/// codegen, where `emitArcConversion` already has the boxing and declines
/// only because `isPlace(arg)` is true.
///
/// **Measured before touching it: `view(p)` after `let arc a = p` is
/// ACCEPTED, while the same use after `let owned q = p` is refused as a
/// move.** The source is not consumed. Boxing the place would therefore
/// have handed the `arc` box a buffer the source still frees at its own
/// scope end, which is a double free manufactured by the fix. The `cc`
/// type error was the only thing holding that program back, exactly as it
/// was for the match-arm gap closed in `fc4c81d` the same night.
///
/// Implementing it properly means consuming the source when it is boxed.
/// Who releases the box was R11 row 1's question, answered 2026-09-16,
/// and the same day `let arc` began moving a whole `owned` `String` or
/// list binding (`boxableOwnedBinding`, asked by the `let` site BEFORE
/// this refusal). Every other source and position still refuses here,
/// and the refusal is narrow: only an `owned` place is caught. A fresh value still boxes
/// (`let arc a = make()` compiles and is correct), an `arc` source is the
/// legal retain, and a `shared` source is a view that
/// `cell_arc_from_string(cell_string_from_str(p))` copies rather than
/// aliases, all three verified.
/// The one source `let arc`, a direct `-> arc T` return and an assignment
/// into a whole `arc` binding may move into a box: a whole `owned` binding
/// whose resolved type is `String` or a list, the two shapes the runtime
/// boxes by taking the header (`cell_arc_from_string`,
/// `cell_arc_from_slice`). Null for anything else, including an
/// unresolved type, so the caller falls through to the refusal.
pub fn boxableOwnedBinding(self: *Checker, v: *const ast.Expr) Error!?Place {
    const place = switch (try self.ownedMoveSource(v)) {
        .place => |p| p,
        else => return null,
    };
    if (place.path.len != 0) return null;
    const b = self.bindingById(place.binding) orelse return null;
    if (b.ownership != .owned) return null;
    const ty = b.ty orelse return null;
    return switch (ty) {
        .list => place,
        .name => |n| if (std.mem.eql(u8, n, "String")) place else null,
        else => null,
    };
}

pub fn refuseUnimplementedArcMove(
    self: *Checker,
    v: *const ast.Expr,
    verb: []const u8,
    prep: []const u8,
    slot: []const u8,
    slot_name: ?[]const u8,
) Error!bool {
    // NOT peeled here. The caller peels, exactly once per path, and this
    // function must not: `openBlockTail` calls `pushScope` and
    // `checkStmt` over the block's statements, so peeling a second time
    // DECLARES every block binding again and drifts `next_binding_id`
    // away from the ids codegen agreed to. A revision that peeled here
    // for tidiness crashed two codegen tests with SIGABRT on exactly that
    // assertion. The peel belongs where the scope is owned.

    // Asked through `ownedMoveSource`, not a bare `placeOf`, and that is
    // the whole difference between this refusal and an incomplete one.
    // `placeOf` returns null for a `match` and for a block, so a first
    // version of this function that used it refused `let arc a = s` while
    // ACCEPTING `let arc a = match 1 { _ => s }`, which is the same
    // program wearing a value position. Measured under AddressSanitizer
    // at that revision: `let owned s = make()` then
    // `let arc a = match 1 { _ => s }` emitted
    // `cell_arc_from_string(...)` followed by `cell_string_free(&s)` and
    // died `exit 134`, `attempting double-free ... in cell_string_free`.
    // It is the same escape hatch R10's owned direction records one
    // screen up, and the sweep cannot see it because every row the sweep
    // generates is direct.
    // `.place` yields a bare name, so it reads as "'owned' place 's'";
    // `.unknown` already yields a phrase ("the place 's' reached through
    // a branch"), so prefixing it would read "'owned' place the place
    // 's' reached...". The subject is spelled at the site that knows.
    const site: struct { display: []const u8, span: Span } = switch (try self.ownedMoveSource(v)) {
        // A literal, a fresh scalar, a borrow, a fresh aggregate, or a
        // call's temporary. Boxing one is correct and compiles today:
        // `let arc a = make()` is the shape every arc test uses.
        .no_owned_place => return false,
        .place => |place| blk: {
            const b = self.bindingById(place.binding) orelse return false;
            const own = self.placeOwnership(b, place.path) orelse return false;
            // `arc` into `arc` is the legal retain, and a `shared` source
            // is a view that `cell_arc_from_string(cell_string_from_str(
            // p))` COPIES rather than aliases. Both verified to compile
            // and run; neither is this rule's business.
            if (own != .owned) return false;
            break :blk .{ .display = try self.msg("'owned' place '{s}'", .{place.display}), .span = place.span };
        },
        .unknown => |s| .{ .display = s.display, .span = s.span },
        .aliases_place => |s| .{ .display = s.display, .span = s.span },
    };

    const message = if (slot_name) |n|
        try self.msg(
            "cannot {s} {s} {s} 'arc' {s} '{s}': moving an owned place into an 'arc' box is not implemented",
            .{ verb, site.display, prep, slot, n },
        )
    else
        try self.msg(
            "cannot {s} {s} {s} an 'arc' {s}: moving an owned place into an 'arc' box is not implemented",
            .{ verb, site.display, prep, slot },
        );
    try self.diagnostics.err(self.allocator, site.span, message);
    try self.diagnostics.note(
        self.allocator,
        site.span,
        "R10 designs this as a move into a fresh 'arc' box, but the checker does not consume the source, so the box and the source's own drop free the same buffer; bind a fresh value to the 'arc' place, or start from an 'arc' source",
    );
    return true;
}

pub fn refuseArcUnique(
    self: *Checker,
    src: ArcSource,
    verb: []const u8,
    prep: []const u8,
    slot: []const u8,
    slot_name: ?[]const u8,
) Error!bool {
    switch (src) {
        .not_arc => return false,
        .arc_place, .arc_value => |s| {
            const message = if (slot_name) |n|
                try self.msg(
                    "cannot {s} 'arc' value '{s}' {s} 'owned' {s} '{s}': ownership is shared and cannot be made unique",
                    .{ verb, s.display, prep, slot, n },
                )
            else
                try self.msg(
                    "cannot {s} 'arc' value '{s}' {s} an 'owned' {s}: ownership is shared and cannot be made unique",
                    .{ verb, s.display, prep, slot },
                );
            try self.diagnostics.err(self.allocator, s.span, message);
            try self.diagnostics.note(
                self.allocator,
                s.span,
                "an 'owned' holder frees the value, and the 'arc' box would free it again",
            );
        },
        .unknown => |s| {
            const message = if (slot_name) |n|
                try self.msg(
                    "cannot {s} {s} {s} 'owned' {s} '{s}': its ownership cannot be resolved here",
                    .{ verb, s.display, prep, slot, n },
                )
            else
                try self.msg(
                    "cannot {s} {s} {s} an 'owned' {s}: its ownership cannot be resolved here",
                    .{ verb, s.display, prep, slot },
                );
            try self.diagnostics.err(self.allocator, s.span, message);
            try self.diagnostics.note(
                self.allocator,
                s.span,
                "R10 refuses what it cannot prove is not 'arc': an 'arc' value made unique is freed twice",
            );
        },
    }
    return true;
}

/// R9: what an `exclusive` borrow of, or a write through, a place would
/// reach. The verdict is TOTAL for the same reason `ArcSource`'s is: a
/// step whose annotation cannot be read is `.unresolved` and is REFUSED,
/// not permitted. Silence must not mean safe.
pub const ArcReach = union(enum) {
    /// Every step this depth asked about has a resolved, non-`arc`
    /// annotation.
    not_arc,
    /// A step is `arc`. `display` names that step, which is the whole
    /// place for a bare binding and a strict prefix for a field path.
    arc: ArcSource.Site,
    /// A step's annotation could not be read. Refused.
    unresolved: ArcSource.Site,
};

/// How far along a place's chain the R9 question runs. The two sites ask
/// DIFFERENT questions and the difference is not cosmetic.
pub const ReachDepth = enum {
    /// Every step, the final field included. An exclusive BORROW asks
    /// this: `&mut b.h` with `arc h: String` hands the callee a mutable
    /// pointer built from the handle itself. Measured, it emitted
    /// `cell_grow(((cell_string_t *)&b.h.ptr))`, a `cell_string_t *`
    /// aimed at the box pointer, and `cc` accepted it silently.
    whole,
    /// Every step but the last. An ASSIGNMENT asks this: writing
    /// `b.h = ...` where `h` is `arc` REBINDS that handle, which is R11's
    /// leak and not a mutation of the pointee, while writing `b.h.x = ...`
    /// mutates the shared value through it. A consequence worth stating,
    /// because it bounds the over-refusal: a one-segment write such as
    /// `b.len = b.len + 1` through an `exclusive b: Buffer` asks only
    /// about the binding, so no struct has to resolve and `.unresolved`
    /// cannot reach it.
    strict_prefix,
};

/// Walk a place's chain and report the first `arc` step, or the first step
/// whose annotation is unreadable.
///
/// The binding itself is the empty-path prefix and is always asked, at
/// both depths. That matters: `let arc s` then `&mut s` has no field path
/// at all, and it is the plainest form of the rule.
pub fn arcReach(self: *Checker, place: Place, depth: ReachDepth) Error!ArcReach {
    const b = self.bindingById(place.binding) orelse return .{ .unresolved = .{
        .display = try self.msg("the place '{s}'", .{place.display}),
        .span = place.span,
    } };
    // The binding is the empty-path prefix. It is a STRICT prefix only
    // when there is a field path after it, which is why this cannot be
    // hoisted above the depth split: `var arc b` then `b = other` rebinds
    // the handle and is R11's leak, while `b.len = 2` writes through it
    // and is R9's rule. The accepted-case test caught this being hoisted.
    if (place.path.len == 0) {
        return switch (depth) {
            .whole => if (b.ownership == .arc) .{ .arc = .{
                .display = b.name,
                .span = place.span,
            } } else .not_arc,
            .strict_prefix => .not_arc,
        };
    }
    if (b.ownership == .arc) return .{ .arc = .{ .display = b.name, .span = place.span } };

    var total: usize = 1;
    for (place.path) |ch| {
        if (ch == '.') total += 1;
    }
    const limit = switch (depth) {
        .whole => total,
        .strict_prefix => total - 1,
    };
    if (limit == 0) return .not_arc;

    var current: ?[]const u8 = b.struct_name;
    var prefix: []const u8 = b.name;
    var it = std.mem.splitScalar(u8, place.path, '.');
    var i: usize = 0;
    while (it.next()) |segment| : (i += 1) {
        if (i == limit) break;
        const unreadable: ArcReach = .{ .unresolved = .{
            .display = try self.msg("the field '{s}' of '{s}'", .{ segment, prefix }),
            .span = place.span,
        } };
        const struct_name = current orelse return unreadable;
        const def = self.structs.get(struct_name) orelse return unreadable;
        const field = findField(def, segment) orelse return unreadable;
        prefix = try self.msg("{s}.{s}", .{ prefix, segment });
        if (field.ownership == .arc) return .{ .arc = .{
            .display = prefix,
            .span = place.span,
        } };
        current = typeStructName(&field.ty);
    }
    return .not_arc;
}

/// R9: an `arc` value grants shared access only. One function for both
/// enforcement sites, so they cannot drift apart the way R10's four
/// hand-written copies did.
///
/// It is a REFUSAL and there is nothing to insert instead. `arc` shares
/// one value between holders and Cell has no interior mutability, so a
/// mutable pointer into the box is a data race and an aliasing violation
/// at once; no clone or retain changes that, because the holders are meant
/// to observe the SAME value.
///
/// Returns true when it refused.
pub fn refuseArcShared(
    self: *Checker,
    reach: ArcReach,
    place: Place,
    op: enum { borrow_exclusive, assign },
) Error!bool {
    switch (reach) {
        .not_arc => return false,
        .arc => |s| {
            const same = std.mem.eql(u8, s.display, place.display);
            const message = switch (op) {
                .borrow_exclusive => if (same)
                    try self.msg(
                        "cannot borrow '{s}' as exclusive: 'arc' grants shared access only",
                        .{place.display},
                    )
                else
                    try self.msg(
                        "cannot borrow '{s}' as exclusive: it is reached through the 'arc' handle '{s}', which grants shared access only",
                        .{ place.display, s.display },
                    ),
                .assign => if (same)
                    try self.msg(
                        "cannot assign through '{s}': 'arc' grants shared access only",
                        .{place.display},
                    )
                else
                    try self.msg(
                        "cannot assign to '{s}': it is reached through the 'arc' handle '{s}', which grants shared access only",
                        .{ place.display, s.display },
                    ),
            };
            try self.diagnostics.err(self.allocator, place.span, message);
            try self.diagnostics.note(
                self.allocator,
                place.span,
                "mutation through 'arc' needs interior mutability, which Cell does not have yet",
            );
        },
        .unresolved => |s| {
            const message = switch (op) {
                .borrow_exclusive => try self.msg(
                    "cannot borrow '{s}' as exclusive: the ownership of {s} cannot be resolved here",
                    .{ place.display, s.display },
                ),
                .assign => try self.msg(
                    "cannot assign to '{s}': the ownership of {s} cannot be resolved here",
                    .{ place.display, s.display },
                ),
            };
            try self.diagnostics.err(self.allocator, place.span, message);
            try self.diagnostics.note(
                self.allocator,
                place.span,
                "R9 refuses what it cannot prove is not 'arc': a unique reference into a shared value mutates every holder",
            );
        },
    }
    return true;
}

/// R9 in a VALUE position, which is axis 1 of R10's history repeating in a
/// new rule. `createLoan` is the choke point for every exclusive loan, and
/// a loan is only ever created for a PLACE, so an exclusive borrow of a
/// VALUE never reached it: `grow(&mut fresh())` with
/// `fresh() -> arc String` was accepted at exit 0 and emitted
/// `cell_grow(((cell_string_t *)&cell_fresh().ptr))`.
///
/// That emit is LOUD, and loud for every type rather than by the
/// coincidence of two C types: `cc` refuses to take the address of an
/// rvalue. It is refused here anyway, on the argument `refuseArcUnique`
/// already makes, that a rule holding for every type beats one whose
/// enforcement depends on what the backend happens to emit.
///
/// Two sites reach it, and both are needed. A bare `&mut <value>` arrives
/// through `checkExpr`'s unary arm; `grow(&mut fresh())` does NOT, because
/// `checkCall` peels the sigil itself and then calls `checkExpr` on the
/// operand rather than on the unary. Fixing only the first left the
/// measured program still accepted, which is this file's failure mode
/// caught inside its own fix.
///
/// `arcUniqueSource` is R10's classifier and answers the question both
/// rules need here, "is this expression an `arc` handle", with a total
/// verdict whose undecidable case is refused.
pub fn refuseArcValueBorrow(self: *Checker, operand: *const ast.Expr) Error!bool {
    switch (try self.arcUniqueSource(operand)) {
        .not_arc => return false,
        .arc_place, .arc_value => |s| {
            try self.diagnostics.err(
                self.allocator,
                s.span,
                try self.msg(
                    "cannot borrow '{s}' as exclusive: 'arc' grants shared access only",
                    .{s.display},
                ),
            );
            try self.diagnostics.note(
                self.allocator,
                s.span,
                "mutation through 'arc' needs interior mutability, which Cell does not have yet",
            );
        },
        .unknown => |s| {
            try self.diagnostics.err(
                self.allocator,
                s.span,
                try self.msg(
                    "cannot borrow {s} as exclusive: its ownership cannot be resolved here",
                    .{s.display},
                ),
            );
            try self.diagnostics.note(
                self.allocator,
                s.span,
                "R9 refuses what it cannot prove is not 'arc': a unique reference into a shared value mutates every holder",
            );
        },
    }
    return true;
}

/// The name of a block's tail when that tail is a bare identifier declared
/// by one of the block's own `let` statements; null otherwise. Purely
/// syntactic, so the ownership-source walks can name what they cannot
/// resolve without declaring anything.
pub fn blockLocalTail(stmts: []const ast.Stmt) ?[]const u8 {
    if (stmts.len == 0) return null;
    const last = &stmts[stmts.len - 1];
    if (last.kind != .expr or last.kind.expr.kind != .ident) return null;
    const name = last.kind.expr.kind.ident;
    for (stmts[0 .. stmts.len - 1]) |st| {
        if (st.kind == .let and std.mem.eql(u8, st.kind.let.name, name)) return name;
    }
    return null;
}
