//! `return` lowering and R11's retain side: `returnedArcNeedsRetain`, `letType`,
//! and the `emitConversion` funnel (`emitArcConversion`,
//! `emitOwningStringConversion`) with `emitArgLike`.
//! Part of the C backend; the rules and their rationale are in the module header of `../codegen.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const Alloc = std.mem.Allocator.Error;
const cg_helpers = @import("helpers.zig");
const cg_model = @import("model.zig");
const cg_root = @import("../codegen.zig");
const Generator = cg_root.Generator;
const EmitError = cg_root.EmitError;
const CType = cg_model.CType;
const eq = cg_helpers.eq;
const unwrapAnnotated = cg_helpers.unwrapAnnotated;
const isPlace = cg_helpers.isPlace;
const isNamedLoan = cg_helpers.isNamedLoan;
const unboxable = cg_helpers.unboxable;
const Exit = cg_helpers.Exit;
const hasDropCall = Generator.hasDropCall;

/// The other drop point: before every `return`. When nothing needs
/// dropping this emits exactly the C this backend always emitted for a
/// `return`, byte for byte, so the common case (no owned/arc locals in
/// scope, which is most of this file's existing tests) is untouched.
///
/// When something DOES need dropping and the return carries a value,
/// the value is evaluated into a temporary FIRST, before any drop runs,
/// then the drops run, then the temporary is returned. This ordering is
/// load-bearing: the returned expression may itself read a local this
/// function is about to drop (an unmoved `owned` local passed to a
/// `shared` parameter of some other call, for instance -- borrowck
/// never moves it, so it is exactly the kind of place this function IS
/// scheduled to drop), and dropping before evaluating would free memory
/// the return expression still needs. Emitting straight into `return
/// <expr>;` and running drops after would be worse: unreachable code
/// after a `return` never executes.
pub fn emitReturnStmt(self: *Generator, opt: ?ast.Expr, exit: Exit, indent: usize) EmitError!void {
    const out = self.writer;
    const saved = self.drop_exit;
    self.drop_exit = exit;
    defer self.drop_exit = saved;
    const to_drop = try self.pendingDrops(exit);
    const retain = if (opt) |v| try self.returnedArcNeedsRetain(&v) else false;
    if (to_drop.len == 0 and !self.hasUntakenTemps(0)) {
        try self.writeIndent(indent);
        try out.writeAll("return");
        if (opt) |v| {
            try out.writeAll(" ");
            try self.emitReturnValue(&v, retain, indent);
        }
        try out.writeAll(";\n");
        return;
    }
    if (opt) |v| {
        const temp = try self.nextTemp();
        try self.writeIndent(indent);
        try self.writeDecl(self.current_ret_ty, temp);
        try out.writeAll(" = ");
        try self.emitReturnValue(&v, retain, indent);
        try out.writeAll(";\n");
        for (to_drop) |local| try self.emitDropFor(indent, local);
        try self.emitTempReleases(0, indent);
        try self.writeIndent(indent);
        try out.print("return {s};\n", .{temp});
    } else {
        for (to_drop) |local| try self.emitDropFor(indent, local);
        try self.emitTempReleases(0, indent);
        try self.writeIndent(indent);
        try out.writeAll("return;\n");
    }
}

/// The returned expression, wrapped in the retain when one is owed.
///
/// Factored out because BOTH of `emitReturnStmt`'s branches need it and
/// only one of them used to have it. The `to_drop.len == 0` branch was
/// written to emit "exactly the C this backend always emitted, byte for
/// byte", and that guarantee still holds for every return that owes no
/// retain, which is every return in this repository's corpus except the
/// `arc` ones. It does not, and must not, hold for a returned `arc`: a
/// function with nothing to drop can still return a reference it does
/// not own, and an `arc` FIELD is exactly that case.
/// ## A `return` is a declared-type position, and it owes R11 rule 1
///
/// `emitArcConversion`'s doc comment used to say `emitArgLike` was "the
/// single place this backend lowers a value into a position with a
/// declared type" and that "there is no second place to keep in step".
/// That was false, and this function is the second place: a `return`
/// lowers a value into the function's declared return type and never
/// asked the conversion question. `pub fn h() -> arc String { return "x" }`
/// passed `cell check` and emitted `return cell_str_from_parts("x", 1);`,
/// which only `cc` caught.
///
/// The BOX direction is routed through the shared funnel, so
/// `emitArcConversion` stays the one place R11 rule 1 is spelled. The
/// same routing is what carries the `str` -> owning-`String` conversion
/// here, and it arrived by the same argument one axis over: `pub fn f()
/// -> String { return "ab" }` emitted `return cell_str_from_parts("ab",
/// 2);` from a `cell_string_t` function for as long as the guard below
/// mentioned `arc`.
///
/// THE UNBOX DIRECTION IS DELIBERATELY NOT ROUTED, and this is the whole
/// safety argument. `pub fn f(arc xs: [Int]) -> [Int] { return xs }` is
/// refused by `cc` today, and routing it would make it COMPILE:
/// `unboxable(cell_slice_t)` is true, so the conversion would emit
/// `(*(const cell_slice_t *)xs.ptr)`. `docs/OWNERSHIP.md` R10 documents
/// exactly that emission and exactly why it is a double free: `owned [T]`
/// and `shared [T]` are the same C type, the callee frees the buffer, and
/// `cell_slice_drop_glue` frees the same buffer again when the box dies.
/// A refcount does not govern the buffer, so no retain fixes it. Returning
/// an `arc` place from an `owned`-returning function is a make-unique
/// position, and R10 refuses four of those; this one it does not reach
/// yet, so the C type error is the only thing refusing it and it must
/// stay. The same holds for `-> String`, where `unboxable` is false and
/// the conversion declines on its own.
///
/// The retain stays hand-written above rather than joining the routing,
/// because it is not the same rule. `emitArcConversion`'s arc-to-arc
/// branch clones every `arc` place, and R11 rule 3's exception (a
/// parameter returned directly is handed back on the caller's own
/// retain) exists only at a `return`. Routing that direction would clone
/// a parameter and leak one reference per call. `retain` and the box are
/// mutually exclusive on `have.shape`, so they can never both fire.
pub fn emitReturnValue(self: *Generator, v: *const ast.Expr, retain: bool, indent: usize) EmitError!void {
    if (retain) {
        try self.writer.writeAll("cell_arc_clone(");
        try self.emitExpr(v, indent);
        try self.writer.writeAll(")");
        return;
    }
    const want = self.current_ret_ty;
    if (unwrapAnnotated(v).kind == .wrap) {
        return try self.emitWrap(unwrapAnnotated(v), want, indent);
    }
    const have = try self.inferExpr(v);
    // THE GUARD IS ON `have` ALONE, and it is the unbox refusal below
    // written as one condition rather than as a pair naming `want`. The
    // old spelling was `want.shape == .arc and have.shape != .arc`, which
    // also excluded the `str` -> owning-`String` direction that `-> String
    // { return "ab" }` needs, for no reason connected to `arc` at all.
    // `emitArcConversion` answers nothing when neither side is `arc`, so
    // widening this changes no `arc` program.
    if (have.shape != .arc) {
        if (try self.emitConversion(v, want, have, indent)) return;
    }
    try self.emitExpr(v, indent);
}

/// True when returning `v` owes an `arc` retain (R11 release rule 3: a
/// returned `arc` is returned ALREADY RETAINED, and the caller owns that
/// reference and must release it).
///
/// The rule has no exception since R11 row 1 closed (2026-09-16):
/// **retain every returned `arc` place this function can name.** Until
/// then a PARAMETER returned directly was exempt, because no parameter
/// was released and its caller's retain was the reference handed back.
/// Now a parameter is released at scope end like any local, so it takes
/// the local's argument below. Every returned place belongs to something
/// that outlives this return or that this return is about to release:
///
///   - a LOCAL or a PARAMETER is always still in `pendingDrops`, because
///     borrowck never makes an `arc` place dead (`isDuplicable`, R10 by
///     design), so the drop would run between the return temporary and
///     the `return`. Retaining is exactly balanced: 1 -> 2 -> 1.
///   - a FIELD (`s.name`, `s->name`) belongs to the record, which this
///     backend did not drop when this was written (it does now, through
///     R11 row 2's glue, and the argument below is unchanged by that: the
///     glue releases the record's OWN reference at its scope end, which is
///     still not the caller's). An earlier version of this function declined
///     a `.field` root, reasoning that the record is never released so
///     there is no release to balance. That reasoned about the wrong
///     quantity: what matters is the reference the CALLER is about to
///     release, not the one this frame holds. `pub fn peek(shared s:
///     Session) -> arc String { return s.name }` emitted a bare
///     `return s->name;` and died under AddressSanitizer with a
///     heap-use-after-free in `cell_arc_drop`. Retaining leaks the
///     record's own reference instead, which is the correct side.
///   - a MATCH-ARM binding is a bitwise copy of a scrutinee this
///     function may itself be dropping, so it is a local in every way
///     that matters here even though `droppable` is false for it. This
///     is why the answer never consults `droppable`.
///
/// **That last case was once thought unreachable, and removing the
/// exception's guard on that belief reopened a use-after-free.** An arm
/// body can be a BLOCK, and a block's contents are statements, so
/// `match s { b => { return b } }` parses and reaches here; a nested `if`
/// inside such a block is a second form. The two forms that ARE rejected
/// (`b => return b`, since `return` is not an expression, and a trailing
/// `match`, which is not a return) are the two the earlier derivation
/// tested. Both regression forms now have tests.
///
/// The leak this once cost (an arm binding over an `arc` PARAMETER was
/// cloned while the parameter was never released) closed with R11 row 1:
/// the parameter is released now, so the clone is exactly balanced.
pub fn returnedArcNeedsRetain(self: *Generator, v: *const ast.Expr) Alloc!bool {
    const place = unwrapAnnotated(v);
    if (!isPlace(place)) return false;
    const ty = try self.inferExpr(place);
    if (ty.shape != .arc) return false;
    switch (place.kind) {
        .ident => |n| {
            var i = self.locals.items.len;
            while (i > 0) {
                i -= 1;
                if (eq(self.locals.items[i].name, n)) return true;
            }
            // Not a binding this function declared. Nothing here can be
            // releasing it, so a retain would only leak; but nothing
            // here can vouch for it either. Unknown identifiers already
            // lower to `void*` rather than to a guess, so leave it.
            return false;
        },
        else => return true,
    }
}

/// The declared type of a `let`. An annotation wins; otherwise the
/// initializer names the OBJECT and the declared ownership decides how
/// this binding holds it; otherwise int64_t, the language's default
/// integer.
///
/// THE INITIALIZER'S SHAPE USED TO DECIDE, AND THAT WAS FIVE MISCOMPILES.
/// The rule here was "an annotation wins, otherwise the inferred type is
/// the type", with `own` consulted for `arc` alone. An initializer's
/// SPELLING therefore decided whether the binding was a reference, and the
/// spellings disagree with each other and with `borrowck.zig`:
///
///     let exclusive e = exclusive buf     cell_Buffer e = buf;
///     let exclusive e = exclusive &buf    const cell_Buffer *e = &buf;
///     let exclusive e = &mut buf          cell_Buffer *e = &buf;
///
/// all three of which borrowck treats identically, as a named exclusive
/// loan on `buf` (`checkLetInit`). The first is a COPY, so
/// `bump(exclusive e)` wrote into it and `buf.len` printed 37 where the
/// LLVM and MLIR backends printed 42: the REFERENCE backend on the wrong
/// side of a backend disagreement, silently. The second discards the
/// qualifier at the call, which `cc` catches only because the gate's
/// AddressSanitizer stage compiles at `-Werror`; nothing DESIGNED that
/// guard, and the same program passes plain `cc` with a warning.
///
/// The same defect over an OWNING type is worse than a lost write. For
/// `var owned name = make()` with `make() -> String`:
///
///     let exclusive e = name    ->  cell_string_t e = name;
///     reset(exclusive e)        ->  cell_reset(&e);
///                               ->  cell_string_free(&name);
///
/// `e` is a SHALLOW copy of an owning `cell_string_t`, so the write is
/// lost AND one heap buffer is reachable for freeing through two paths.
/// `[T]` is the same one type over: `cell_slice_t e = xs;` against a
/// `cell_slice_free(&xs)`. Both pass `cell check`.
///
/// And in the other direction, a binding that is NOT a borrow inherited
/// the initializer's reference-ness: `let copy snap = e` over a live
/// borrow emitted `cell_Buffer *snap = e;`, so the snapshot ALIASED the
/// lender and saw every later write. `copy` means a value copy, and the
/// LLVM backend loads through; C was wrong there too.
///
/// TWO BUCKETS, NOT A CASE PER SPELLING. `base` strips whatever
/// reference-ness the initializer's spelling happened to carry, and then
/// the DECLARED annotation alone decides, through the same
/// `applyOwnership` that lowers a parameter. A binding is a reference
/// exactly when `isNamedLoan` says borrowck made it one; everything else
/// is by value. The catch-all bucket being by-value is the point: an
/// initializer shape nobody enumerated cannot become a reference by
/// accident, which is the same reason `borrowck.arcUniqueSource` returns a
/// total verdict whose undecidable case is refused rather than an optional
/// whose "none" meant permit.
///
/// `arc` is answered FIRST and is untouched. It is the one mode whose C
/// spelling is not derivable from the initializer at all: `let arc label =
/// "session"` must be a `cell_arc_t` no matter that the literal infers as
/// `cell_str_t`, and before this consultation existed the binding kept the
/// view's type and the emitted C failed to compile the moment it reached
/// an `arc` parameter. Asking it before `base` also keeps a handle from
/// ever being dereferenced: an `arc` is a struct by value and
/// `applyOwnership` never makes one a pointer.
///
/// WHAT THIS DOES NOT CHANGE, and the reason the two buckets are needed
/// rather than an unconditional `applyOwnership`. `Local.ownership`'s doc
/// comment records that a `shared`/`copy` local initialized from a CALL
/// keeps the call's owned result type, and the drop pass reads the
/// declared annotation rather than the shape precisely so it can tell
/// those apart. A call result is not a place, so `isNamedLoan` is false
/// and `let shared s = make()` still lands on `cell_string_t` rather than
/// being demoted to a `cell_str_t` view of a temporary nothing owns.
/// `applyOwnership` returns a primitive unchanged, so `arc Int` and
/// `exclusive Int` stay `int64_t` here for free.
pub fn letType(self: *Generator, ann: ?ast.TypeExpr, value: ?ast.Expr, own: ast.Ownership) Alloc!CType {
    if (ann) |t| return try self.lowerType(&t, own);
    if (value) |v| {
        const inferred = try self.inferExpr(&v);
        if (inferred.shape != .unknown and inferred.shape != .unit) {
            if (own == .arc) return try self.applyOwnership(inferred, .arc);

            // The initializer names WHICH OBJECT, never whether this
            // binding refers to it. `pointerTo` is the only thing that
            // sets `pointer` (it is the sole `.pointer = true` in this
            // file) and it always sets `pointee` beside it, so `.?` here
            // cannot fire on a type this module built.
            const base = if (inferred.pointer) inferred.pointee.?.* else inferred;

            // A borrow binding refers to the lender's object, and the
            // declared mode says how.
            if ((own == .exclusive or own == .shared) and isNamedLoan(&v, own)) {
                return try self.applyOwnership(base, own);
            }

            // A BY-VALUE BINDING OF AN OWNING HEADER IS NOT A COPY, AND
            // THIS BACKEND HAS NO DEEP ONE TO EMIT. Turning a reference
            // into a value duplicates the header, and for `cell_string_t`,
            // `cell_slice_t` and `cell_arc_t` the header owns a heap
            // buffer that the duplicate then also names. What that costs
            // depends only on who frees first, and both answers are bad:
            //
            //     var owned name = make_text()
            //     let owned s = &mut name
            //
            // is a LOAN on borrowck's side, not a move (`checkLetInit`
            // clause 1 fires on the sigil and returns before the `.owned`
            // move logic), so `name` is still dropped at scope exit. An
            // `owned` binding of a droppable shape is dropped too, and the
            // two `cell_string_free`s free one buffer. Measured: a
            // by-value `s` here is an AddressSanitizer double free at exit
            // 134, and `&var`, and `[T]` through `cell_slice_free`, are
            // the same program. `var copy s = &mut name` needs no drop to
            // get there: `reset(exclusive s)` releases the shared buffer
            // through the duplicate and the lender is left dangling.
            //
            // So the reference SPELLING is kept for these, which is what
            // this backend emitted before the rule above existed, and it
            // is kept because it is LOUD rather than because it is right:
            // `cell_string_free(&s)` against a `cell_string_t **` is a
            // `cc` error at `-Werror`, and where it does compile the
            // binding aliases its lender instead of copying it, which is
            // wrong for `copy` and safe only by accident. A silent double
            // free is the one outcome that is not acceptable here.
            //
            // The correct lowering is a deep copy at R12's copy sites
            // (`cell_string_clone` and a slice equivalent), and refusing
            // the ones that cannot be spelled belongs in `borrowck.zig`,
            // which is what actually decides that `let owned s = &mut x`
            // borrows rather than moves. Neither is contained here.
            //
            // Records, enums and primitives are unaffected: `hasDropCall`
            // is false for them, so `let copy snap = <a borrow>` is a real
            // value copy, which is the whole of defect 3.
            if (inferred.pointer and hasDropCall(base.shape)) return inferred;

            return base;
        }
    }
    return CType.int64;
}

/// True when this argument is an unbound `arc` whose handle would
/// otherwise be dropped on the floor. Every clause is a restriction, and
/// `emitCall`'s doc comment gives the reason for each.
///
/// The `.call` test is the load-bearing one: it is the only argument
/// form whose `arc` value is guaranteed to be a live +1 reference this
/// frame owns, and it is the form that was measured. A place is excluded
/// because it belongs to a binding that is released elsewhere; an `if`,
/// `match`, or block is excluded because its value comes out of a
/// zero-initialised temporary.
pub fn needsArcTemp(self: *Generator, arg: *const ast.Expr, want: CType) Alloc!bool {
    switch (unwrapAnnotated(arg).kind) {
        .call => {},
        else => return false,
    }
    if (want.shape == .arc) return false;
    if (!unboxable(want)) return false;
    const have = try self.inferExpr(arg);
    return have.shape == .arc;
}

// ── arc retain and boxing (task 4b) ─────────────────────────────────

/// The retain half of `docs/OWNERSHIP.md` R11, plus the unbox that makes
/// the deliberate NON-retain expressible. Returns true when it emitted
/// `arg` itself, false to let `emitArgLike` carry on.
///
/// Every one of R11's four retain sites reaches this one function.
/// `emitArgLike` carries five positions into it: a `let` initializer
/// (rule 3), a call argument (rules 1 and 2), a struct literal field
/// (rule 4), a list element, and an assignment's right side.
///
/// AN EARLIER VERSION OF THIS PARAGRAPH ADDED "there is no second place
/// to keep in step", AND THAT WAS FALSE. A `return` lowers a value into
/// the function's declared return type, which is a declared-type
/// position by exactly the same argument, and it did not ask this
/// question: `pub fn h() -> arc String { return "x" }` emitted
/// `return cell_str_from_parts("x", 1);`. `emitReturnValue` now routes
/// the BOX direction here, and its doc comment gives the reason the
/// unbox direction must NOT be routed (it would turn R10's documented
/// double free from a C type error into compiling code).
///
/// THE ENUMERATION WAS SHORT AGAIN, AND THAT IS WHY THIS IS NO LONGER
/// THE ENTRY POINT. The paragraph above used to end "six positions reach
/// this function, and the way the seventh gets found is by someone
/// listing them again". Someone did, and found two: `emitValueInto`'s
/// value slot reaches here as well, from a `match` arm and from a block,
/// which is a seventh and an eighth. Callers now route through
/// `emitConversion`, which asks this question and the `str` ->
/// owning-`String` one together, so a ninth position inherits both
/// answers by calling the funnel rather than by appearing in a list. This
/// function is the `arc` RULE; it is not the door any more.
///
/// Three cases, in the order they are tested:
///
///   1. UNBOX, an arc value where a non-arc type is wanted. This is
///      R11's one deliberate non-retain: `inspect(shared label)` borrows
///      the pointee for the call and clones nothing, which R8 makes safe
///      because the borrow cannot escape the call. The pointee's C type
///      is recovered from `want`, not from the handle, because
///      `applyOwnership` collapses every `arc T` to the same
///      `cell_arc_t` and keeps no record of T.
///   2. RETAIN, an arc place where an arc is wanted (R11 rules 2, 3, 4).
///      Gated on `isPlace`: a call that returns `arc` hands back a
///      reference that is ALREADY retained (R11 release rule 3 and
///      cell_rt.h section 7), so cloning it too would leak one.
///   3. BOX, a non-arc value where an arc is wanted (R11 rule 1). The
///      box does not exist yet, so this is `cell_arc_new` by way of
///      `cell_arc_from_string`/`cell_arc_from_slice`, not a clone.
///
/// WHAT CASE 3 REFUSES TO DO, and why the refusal is the safe answer.
/// An `owned` String or list PLACE is not boxed unless borrowck moved it.
/// `cell_arc_from_string` MOVES its argument into the box, so boxing a
/// place the drop pass still schedules would emit a silent double free.
/// Since 2026-09-16 `checkLet` moves a whole `owned` `String` or list
/// binding bound to `let arc`, and `isMovedOwnedBinding` admits exactly
/// that place; every other place still declines. Falling through instead leaves a C type
/// error, which is loud, and which this backend's module comment already
/// prefers over plausible wrong code. A literal, a call result, and a
/// `shared` view are all boxed, because none of them is a local the drop
/// pass will also free: the view case copies through
/// `cell_string_from_str` and owns its characters outright.
///
/// THAT ENUMERATION IS INCOMPLETE BY ITS OWN TEST, found by a differential
/// sweep on 2026-09-08 and recorded rather than acted on. The test it
/// states is "not a local the drop pass will also free", and a `copy`
/// local satisfies it: `pendingDrops` skips every ownership that is not
/// `.owned` or `.arc`, so a `copy` place is never freed and boxing one
/// could not double free. It is nonetheless not boxed, so
/// `var arc x: String = mk()` then `x = <copy place>` falls through to a
/// loud `cc` type error.
///
/// This is the SAFE direction (over-refusal), which is why it is a note
/// and not a defect, and it is deliberately left alone: boxing a `copy`
/// place would move it into a box the drop pass DOES release, which
/// changes what the program frees and therefore what the `== leaks ==`
/// constants read. That is the double-free direction, and it wants its own
/// slice with its own measurement, not a drive-by.
///
/// Worth noticing where this happened: an enumeration went one case short
/// inside the very comment that exists to warn about enumerations going
/// one case short.
pub fn emitArcConversion(
    self: *Generator,
    arg: *const ast.Expr,
    want: CType,
    have: CType,
    indent: usize,
) EmitError!bool {
    const out = self.writer;

    if (have.shape == .arc and want.shape != .arc) {
        return try self.emitUnbox(arg, null, want, indent);
    }

    if (want.shape != .arc) return false;

    if (have.shape == .arc) {
        if (!isPlace(arg)) return false;
        try out.writeAll("cell_arc_clone(");
        try self.emitExpr(arg, indent);
        try out.writeAll(")");
        return true;
    }

    switch (have.shape) {
        .str => {
            try out.writeAll("cell_arc_from_string(cell_string_from_str(");
            try self.emitExpr(arg, indent);
            try out.writeAll("))");
            return true;
        },
        .string => {
            if (have.pointer) return false;
            if (isPlace(arg) and !self.isMovedOwnedBinding(arg)) return false;
            try out.writeAll("cell_arc_from_string(");
            try self.emitExpr(arg, indent);
            try out.writeAll(")");
            return true;
        },
        .slice => {
            if (have.pointer) return false;
            if (isPlace(arg) and !self.isMovedOwnedBinding(arg)) return false;
            try out.writeAll("cell_arc_from_slice(");
            try self.emitExpr(arg, indent);
            try out.writeAll(")");
            return true;
        },
        else => return false,
    }
}

/// A place `emitArcConversion` may box by moving its header: a bare
/// identifier naming an `owned` binding that borrowck recorded as wholly
/// moved. borrowck moves a place into a box only at `let arc`, at a
/// direct `-> arc T` return, by assignment into a whole `arc`
/// binding, as an argument to an `arc` parameter, and into a struct
/// literal's `arc` field (R10, `boxableOwnedBinding`), and refuses the
/// other positions, so this is the only way such a place reaches a
/// boxing conversion; the moved source is
/// then skipped by the drop pass and the box owns the buffer. Anything
/// else keeps the loud `cc` type error.
pub fn isMovedOwnedBinding(self: *Generator, arg: *const ast.Expr) bool {
    const checker = self.checker orelse return false;
    const e = unwrapAnnotated(arg);
    if (e.kind != .ident) return false;
    var i = self.locals.items.len;
    while (i > 0) {
        i -= 1;
        const local = self.locals.items[i];
        if (!eq(local.name, e.kind.ident)) continue;
        if (!local.droppable or local.ownership != .owned) return false;
        return checker.wasWhollyMoved(local.id);
    }
    return false;
}

/// THE FUNNEL. Every position that lowers a value into a destination with
/// a DECLARED TYPE asks this one function, and asks nothing else.
///
/// WHY IT EXISTS AT ALL, rather than a conversion per position. Both of
/// the conversions below were added the same way: someone found a
/// position emitting wrong C, fixed that position, and the next position
/// with the same shape stayed wrong. `emitArcConversion`'s own doc
/// comment records the second round of that ("there is no second place to
/// keep in step", which was false, and a `return` was the second place),
/// and the `str` -> owning-`String` defect was the third: the `arc` axis
/// of six positions was fixed and the plain-`String` axis of the same six
/// was never asked about. The table of six that recorded it was ALSO
/// short, measured before this function existed: `let owned s: String =
/// match c { 0 => make(), _ => "x" }` and the same shape at a `return`
/// put the literal inside a value-slot arm, which is a seventh and an
/// eighth position, and neither is any of the six.
///
/// So the enumeration is not the fix and must not be treated as one. The
/// fix is that the question is asked ONCE, of the pair (`have`, `want`),
/// and a position nobody anticipated inherits the answer by routing here
/// instead of by being listed. What a reader should verify is that every
/// declared-type position CALLS this, which is three call sites today:
/// `emitArgLike` (a `let` initializer, an assignment's right side, a call
/// argument, a struct-literal field, a list element), `emitReturnValue`
/// (the declared return type), and `emitValueInto` (a value slot a
/// block, `if`, or `match` arm writes into).
///
/// ORDER IS NOT ARBITRARY. The `arc` question is asked first because it
/// is the only one with an answer when either side is `arc`, and its
/// declines are load-bearing refusals (R10's unbox-to-owned direction
/// stays a `cc` error on purpose). `emitOwningStringConversion` sees only
/// pairs `emitArcConversion` has already declined, and it requires both
/// sides to be non-`arc` string shapes, so the two can never both fire.
pub fn emitConversion(
    self: *Generator,
    arg: *const ast.Expr,
    want: CType,
    have: CType,
    indent: usize,
) EmitError!bool {
    if (try self.emitArcConversion(arg, want, have, indent)) return true;
    return try self.emitOwningStringConversion(arg, want, have, indent);
}

/// A borrowed view where an owning `String` is wanted: `cell_str_t` ->
/// `cell_string_t`, which is a real call to `cell_string_from_str` that
/// COPIES the characters into a fresh heap buffer.
///
/// WHY THIS IS SAFE FOR EVERY SOURCE, which is the question
/// `emitArcConversion`'s case-3 refusal makes it obvious to ask. That
/// refusal exists because `cell_arc_from_string` MOVES its argument, so
/// boxing an `owned` String PLACE leaves the source local unmoved, the
/// drop pass still schedules its `cell_string_free`, and the box's glue
/// frees the same buffer: a silent double free. The same question here
/// has a different answer for a structural reason, not a case-by-case one:
///
///   1. The conversion COPIES rather than moving, so it takes no
///      ownership from the source and cannot make a second owner of one
///      buffer.
///   2. NOTHING WHOSE C TYPE IS `cell_str_t` IS EVER FREED BY THIS
///      BACKEND. `hasDropCall` is false for `.str`, so `pendingDrops`
///      cannot select such a local whatever its ownership annotation
///      says, and `emitDropFor` has no `.str` spelling to emit.
///
/// Those two together are what makes the guard a TYPE test rather than an
/// enumeration of source shapes. A literal, a `shared String` parameter
/// or local, a `shared` field selection, and a function returning
/// `shared String` are all `.str`, and clause 2 covers them without this
/// function naming any of them.
///
/// AN OWNED `String` PLACE IS NOT REACHED AND MUST NOT BE. Its `have` is
/// `.string`, not `.str`, so the first guard declines before anything is
/// written. That is the brief's trap, and it is closed by the shape of
/// the predicate rather than by a check that could be forgotten:
/// converting an owned place would emit a second owner of one buffer
/// exactly the way case 3's boxing would. `let owned t: String = s` over
/// an owned `s` therefore still emits a bare `s`, and borrowck's move of
/// `s` is what stops the pair being freed twice, unchanged by this.
///
/// WHAT THE DESTINATION SIDE COSTS, stated rather than left implicit.
/// `want.pointer` is excluded because `exclusive String` is a
/// `cell_string_t *` and a fresh value has no address to hand over; that
/// stays a `cc` error. Of the destinations that ARE accepted, three own
/// the result exactly once (an `owned` local the drop pass frees, an
/// `owned` parameter the callee frees, the declared return type the
/// caller receives), and three LEAK it: a struct field, because this
/// backend generates no per-struct drop; a list element, because
/// `cell_slice_free` frees the buffer and not the elements; and an
/// assignment target, because an assignment drops nothing first. A
/// `copy String` destination leaks too, `pendingDrops` taking only
/// `.owned` and `.arc`. All six were already the behaviour for a
/// non-literal source of the same shape, so none of them is new here, and
/// every one is on the leak side of this backend's stated asymmetry
/// rather than the corruption side.
pub fn emitOwningStringConversion(
    self: *Generator,
    arg: *const ast.Expr,
    want: CType,
    have: CType,
    indent: usize,
) EmitError!bool {
    if (have.shape != .str or have.pointer) return false;
    if (want.shape != .string or want.pointer) return false;
    try self.writer.writeAll("cell_string_from_str(");
    try self.emitExpr(arg, indent);
    try self.writer.writeAll(")");
    return true;
}

/// R11's deliberate non-retain, written once so the hoisted and the
/// un-hoisted spelling can never drift apart.
///
/// `handle` chooses where the `cell_arc_t` comes from: null emits `arg`
/// itself (the ordinary path, byte for byte what this function emitted
/// inline before it was extracted), or the C identifier of a temporary
/// `emitCall` hoisted out of the argument list. Everything else about
/// the three spellings is identical either way, which is the point: the
/// pre-scan in `emitCall` asks `unboxable` and this function answers with
/// the same three conditions in the same order, so a `want` the pre-scan
/// hoists is always a `want` this function has a spelling for.
pub fn emitUnbox(
    self: *Generator,
    arg: *const ast.Expr,
    handle: ?[]const u8,
    want: CType,
    indent: usize,
) EmitError!bool {
    const out = self.writer;
    // Anything else (an owned aggregate, say) would be a move out of a
    // shared box, which R10 forbids anyway. Fall through loud.
    if (!unboxable(want)) return false;

    // `.ptr` is `void *`, so every cast below is a widening to the
    // pointee's own type and needs no intermediate.
    if (want.shape == .str) {
        try out.writeAll("cell_string_as_str((const cell_string_t *)");
        try self.writeArcHandle(arg, handle, indent);
        try out.writeAll(".ptr)");
        return true;
    }
    if (want.shape == .slice and !want.pointer) {
        try out.writeAll("(*(const cell_slice_t *)");
        try self.writeArcHandle(arg, handle, indent);
        try out.writeAll(".ptr)");
        return true;
    }
    try out.print("(({s})", .{want.text});
    try self.writeArcHandle(arg, handle, indent);
    try out.writeAll(".ptr)");
    return true;
}

pub fn writeArcHandle(
    self: *Generator,
    arg: *const ast.Expr,
    handle: ?[]const u8,
    indent: usize,
) EmitError!void {
    if (handle) |name| return try self.writer.writeAll(name);
    try self.emitExpr(arg, indent);
}

/// Emit `arg` where a value of type `want` is required, inserting the
/// address-of, dereference, or view conversion the ABI needs. Call-site
/// ownership prefixes are `.annotated` wrappers; this still lowers from
/// the callee signature, so `grow(buf, 16)` becomes `cell_grow(&buf, 16)`
/// because `grow` takes `exclusive Buffer`, not because of a written prefix.
pub fn emitArgLike(self: *Generator, arg: *const ast.Expr, want: CType, indent: usize) EmitError!void {
    const out = self.writer;
    const have = try self.inferExpr(arg);
    if (unwrapAnnotated(arg).kind == .wrap) {
        return try self.emitWrap(unwrapAnnotated(arg), want, indent);
    }

    // The declared-type conversions are answered FIRST, before any of the
    // address-of and dereference rules below. An arc handle is a struct
    // by value, so `&x` and `*x` are never the conversion it needs, and
    // letting the pointer rule see an `arc` place bound for a
    // `shared Record` parameter would emit `&x` (the address of the
    // handle) where the pointee is wanted. The `str` -> owning-`String`
    // direction is disjoint from every rule below, including the
    // `.string` -> `.str` one at the bottom, which runs the other way.
    if (try self.emitConversion(arg, want, have, indent)) return;

    // A list literal is the one expression whose element C type is not
    // recoverable from the expression alone, because `cell_slice_t` is
    // type-erased. This is the only position that knows the declared
    // one, so it hands it down rather than letting `emitExpr` infer.
    if (want.shape == .slice and !want.pointer and want.elem != null) {
        const inner = unwrapAnnotated(arg);
        switch (inner.kind) {
            .list_lit => |items| return try self.emitListLit(items, want.elem.?.*, indent),
            // A list literal can also arrive through a value-position
            // `match` or block, and `let owned zs: [String] = match c {
            // 0 => [a], _ => [a] }` passes `cell check` today, so this is
            // reachable rather than hypothetical: without it the arm's
            // literal is emitted through `emitExpr` and infers its own
            // element type again. (A value-position `if` is typed `()`
            // by the checker and cannot reach an annotated binding, but
            // it costs nothing to carry it here too.)
            .block, .if_expr, .match_expr => return try self.emitValueExpr(inner, want, indent),
            else => {},
        }
    }

    if (want.pointer and !have.pointer and isPlace(arg)) {
        try out.writeAll("&");
        try self.emitExpr(arg, indent);
        return;
    }
    if (!want.pointer and have.pointer and want.shape == have.shape) {
        try out.writeAll("*");
        try self.emitExpr(arg, indent);
        return;
    }
    if (want.shape == .str and have.shape == .string) {
        if (have.pointer) {
            try out.writeAll("cell_string_as_str(");
            try self.emitExpr(arg, indent);
            try out.writeAll(")");
        } else if (isPlace(arg)) {
            try out.writeAll("cell_string_as_str(&");
            try self.emitExpr(arg, indent);
            try out.writeAll(")");
        } else {
            try self.emitExpr(arg, indent);
        }
        return;
    }
    try self.emitExpr(arg, indent);
}
