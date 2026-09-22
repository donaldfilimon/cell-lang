//! C emission for the Cell language.
//!
//! The output targets the ABI that `runtime/cell_rt.h` documents in its
//! opening block, so emitted code compiles with `-std=c11 -Wall -Wextra` and
//! links against `runtime/cell_rt.c`. Three rules drive everything here:
//!
//!   1. Ownership selects the C type, it is not a comment. `shared String` is
//!      `cell_str_t`, `exclusive Buffer` is `cell_Buffer *`, and a primitive
//!      stays by value in every mode because cell_rt.h section 1 says so.
//!   2. Every Cell symbol is mangled `cell_<name>`, at the definition AND at
//!      the call, so `print(x)` reaches the runtime's `cell_print`.
//!   3. Call sites lower against the callee's declared parameter ownership.
//!      A written prefix such as `grow(exclusive buf, ...)` is kept on the
//!      AST as `.annotated`; emission still ignores that wrapper and uses
//!      the callee signature to decide that the argument is passed as `&buf`.
//!
//! Expression-position `if`, `match`, `block`, and non-empty list literals
//! lower to a GNU statement expression `({ ... })`. That is a Clang and GCC
//! extension rather than ISO C11: the tradeoff is that MSVC cannot compile
//! such a module, bought against preserving evaluation order and nesting
//! without a hoisting pass over every enclosing statement. Statement-position
//! `if` and `match`, which is every occurrence in `examples/`, stay ISO C.
//!
//! There is no type checker feeding this stage, so types are inferred locally
//! from parameter and field declarations, `let` annotations, literals, and
//! callee return types. An expression whose type cannot be recovered lowers to
//! `void*`, which is visible in the output rather than silently wrong.
//!
//! ## Drop insertion (task 3), and the id-numbering agreement it depends on
//!
//! `docs/OWNERSHIP.md` R16 says an `owned` place is destroyed at the end of
//! its scope. This backend makes that true for the two cases that are safe
//! to do conservatively: an unmoved `owned`/`arc` `let`/`var` local gets
//! `cell_string_free(&x)`, `cell_slice_free(&x)`, or `cell_arc_drop(x)` (the
//! only three symbols in `runtime/cell_rt.h` that are real functions rather
//! than `static inline`) at the end of the statement-position scope that
//! declared it (the function body, or since 2026-09-15 a `while` body, a
//! bare block, an `if` branch, or a `match` arm body), before every `return`,
//! and before every `break`/`continue` for the loop's scopes. "Unmoved" is
//! answered by `borrowck.zig`, not re-derived here:
//! `emitModule` runs one `borrowck.Checker` over the whole module before
//! emitting anything, and every `Local` records the id `Checker.declare`
//! assigned to the SAME source declaration, so `Checker.wasMoved` can be
//! asked directly. An `owned` or `arc` parameter IS dropped since
//! 2026-09-16 (R11 row 1): `runtime/cell_rt.h` section 7 makes the callee
//! responsible for both, so a parameter enters the pass exactly like a
//! `let`, and a parameter moved onward is skipped by the same `wasMoved`
//! check. A match-arm binding is never dropped (its C value is a bitwise
//! copy of the scrutinee temporary, and dropping it risks freeing whatever
//! the scrutinee itself still owns). A `record` (struct) shape IS dropped
//! since 2026-09-15 (R11 row 2): every struct with an `owned` or `arc`
//! field whose lowered type needs a drop gets a generated
//! `static inline void cell_drop_<Name>(cell_<Name> *r)` after the
//! typedefs, and a local of that type is released through it.
//! The predicate is `needsDrop`, deliberately separate from `hasDropCall`
//! (see that function's comment for why widening it would be wrong).
//!
//! Borrowck's move tracking is deliberately conservative -- a move on only
//! one branch of an `if` marks the place moved for the rest of the function
//! -- and that direction is exactly what a safe drop pass needs: skipping
//! the drop of a place that is still live only leaks it, while dropping a
//! place that might already be gone is a double free. This backend always
//! picks the leak. Known gaps left on purpose: a value moved on only one
//! path still leaks on every path that did not move it; a struct with
//! owning fields is never destroyed at all; `wasMoved` answers "moved
//! ANYWHERE in the function", so a `var` that is moved and later reassigned
//! (R3a revival) is never dropped either, even though it holds a fresh,
//! unmoved value at the function's end -- the revived value leaked too.
//! Both halves are closed for the cases borrowck vouches for (2026-09-16):
//! `emitAssign` releases an `owned` var's old value on a store from
//! `assign_liveness`, and `pendingDropsSince` releases a revived var at a
//! block end, `return`, `break`/`continue`, value-block end, and a revived
//! record from `exit_liveness`; a var moved inside a `while` it was declared
//! outside of is released after that while when borrowck recorded
//! `after_loop` live (2026-09-16); a nested field whose sibling was moved
//! is released by recursing `emitPartialRecordDrop` (2026-09-16); a field
//! moved on only one branch of an `if` is released on the keeping path
//! (2026-09-16) from per-field exit liveness, live here and dead after
//! the merge, never by dropping the whole record (that double-frees the
//! unmoved sibling with the later partial drop); a field revived after it
//! was moved is released at scope end (2026-09-16) because R3a retracts
//! that path from `fieldWasMoved`; a skip-revival `break` with no later
//! use is released after the loop (`after_loop_skip`, 2026-09-17), the
//! dead `break` lowered as a `goto` past that release, because a C
//! `break` there runs it on a moved buffer (ASan exit 134, measured);
//! a `return` inside an accepted loop releases what the walk saw live
//! there (2026-09-17; borrowck spares `return` records from the loop
//! poison unless the loop reported an error) (a skip-revival `continue`
//! of an outer place, and a skip-revival `break` followed by a use, are
//! refused by borrowck's R2.a since 2026-09-16; before that they were
//! accepted and ran as double frees, which no drop decision here caused);
//! and a local declared
//! inside a VALUE-position block (`emitValueInto`) is not released at
//! that block's exit, because it may be the value flowing out.
//! Why block-scoped release is safe for a local whose initializer moves an
//! OUTER place inside a loop: borrowck's R2.a refuses that program outright
//! (the back edge would use the place dead), so no accepted loop body
//! re-moves a freed buffer; an outer `arc` place is cloned into the local
//! instead, and the per-iteration drop releases exactly that clone.
//!
//! THE ID-NUMBERING AGREEMENT THIS RELIES ON. Codegen does not reuse
//! borrowck's `Binding`s; it keeps its own `next_binding_id` counter and
//! assigns an id to a `Local` at exactly the three points borrowck's own
//! `declare` runs (a function's parameters, a `let`, a match-arm binding),
//! in the same relative order, because both walk the same AST the same way:
//! parameters first, then each statement left to right, entering a block,
//! an `if`'s branches, a `match`'s arms, or a `while` body exactly where
//! borrowck does. Neither counter is ever reset except once per whole
//! module. This is why `emitModule` cannot check a module incrementally,
//! function by function, interleaved with emission: the numbering has to
//! come from ONE full pass so a later function's ids do not collide with an
//! earlier one's, exactly as borrowck's own `next_binding_id` already never
//! resets between functions. `pushLocal` double-checks this agreement with
//! a `std.debug.assert` against `Checker.bindingName` on every call (a
//! no-op in release builds), so a future edit that breaks the lockstep
//! fails loudly in tests instead of silently mis-dropping a binding.
//!
//! ## Arc retain insertion (task 4b), the other half of the same rule
//!
//! `docs/OWNERSHIP.md` R11 pairs a retain with each of those releases, and
//! `emitArcConversion` emits every one of them. This paragraph used to end
//! "it hangs off `emitArgLike`, which is the single place a value is lowered
//! into a position whose C type is declared, so there is no second place to
//! keep in step". THAT SENTENCE WAS WRONG TWICE, and both times the cost was
//! emitted C that `cc` refused: a `return` is a second such place, and
//! `emitValueInto`'s value slot is a third. The claim is now structural
//! instead of enumerated. `emitConversion` is the funnel, it asks the `arc`
//! rule and the `str` -> owning-`String` rule together, and the three
//! callers named above route through it; what a reader should check is that
//! a new declared-type position CALLS it, not that it appears in a list.
//! `letType` had to learn about `arc` first: it took
//! the initializer's inferred type and never the declared ownership, so
//! `let arc label = "session"` stayed a `cell_str_t` and `applyOwnership`'s
//! `.arc => CType.arc` was unreachable for it.
//!
//! The asymmetry that shaped this pass is the mirror of the drop pass's:
//! retaining too much leaks, retaining too little is a use after free, so
//! every judgment call goes toward the retain. The one place that reads as
//! an exception is not one: an `arc` place passed to a `shared` parameter is
//! deliberately NOT retained, which R8 makes safe because the borrow cannot
//! escape the call, and an explicit absence test pins it.
//!
//! `emitReturnStmt` carries the only retain outside that helper, and it is
//! there because the drop pass cannot see R11 release rule 2's "except the
//! one being returned": borrowck never makes an `arc` place dead
//! (`isDuplicable`, R10 by design), so a returned `arc` local is always
//! still in `pendingDrops` and would be released between the return
//! temporary and the `return` itself. The clone is exactly balanced, not a
//! leak. The rule it applies is deliberately an EXCEPTION and not a list:
//! retain every returned `arc` place except a parameter returned directly.
//! A list is what got this wrong the first time, by omitting a field.
//!
//! FIVE USE-AFTER-FREES LIVED HERE, found in two review rounds, and the
//! sentence that used to occupy this paragraph said none could. Every one was
//! introduced by the same act: turning source that had been a C type error
//! into source that compiles. Keep them named, because the next `arc` change
//! can reintroduce any of them.
//!
//!   1. A returned `arc` FIELD. `return s.name` emitted a bare
//!      `return s->name;`, handing the caller the record's own reference.
//!      Fixed by retaining every returned `arc` place that is not a
//!      parameter, on BOTH branches of `emitReturnStmt`.
//!   2. A SHADOWED `arc` local. `emitDropFor` spells a drop by NAME, so two
//!      visible bindings sharing one name emitted two identical
//!      `cell_arc_drop(s)`, both resolving to the inner binding. Fixed by
//!      `isShadowedAt`, which declines to drop a binding a later one
//!      shadows, leaking it instead.
//!   3. An `arc` place flowing out of an `if`-EXPRESSION branch.
//!      `let arc r = if (c > 0) { a } else { b }` aliased `a`'s box.
//!   4. An `arc` place flowing out of a `match` ARM in return position.
//!      `return match c { 0 => a, _ => a }` dropped `a` before returning it.
//!      A `match` is valued in return position where an `if` is not, and it
//!      is not a PLACE, so the return-position rule never saw it.
//!   5. An `arc` place passed to an `owned` parameter, now REFUSED by
//!      `borrowck.zig` under R10 rather than retained. No retain can fix it:
//!      `owned [T]` and `shared [T]` are the same C type, so the unbox
//!      compiles and the buffer is freed twice, and a refcount does not
//!      govern the buffer.
//!
//! 3 and 4 shared one root cause and one fix: `emitValueInto`'s leaf, which
//! was the only position with a declared type that did not ask the
//! conversion question. THE LESSON THAT GENERALIZES: 1 and 2 were found by
//! searching return-position PLACES, and that search is what missed 3, 4 and
//! 5. A retain rule has to be derived over positions, and a value slot is a
//! position.
//!
//! Known gaps, every one of them MEASURED as a leak with `leaks` rather than
//! argued to be one (`docs/OWNERSHIP.md` R11 carries the numbers): a Cell
//! body never released its own `arc` parameter, because no parameter was
//! dropped, so every call-site retain into one leaked a reference (CLOSED
//! 2026-09-16, pinned at 0 in the gate); a struct
//! holding an `arc` field was never dropped, so the field's retain leaked
//! (CLOSED 2026-09-15 by per-struct drop glue, pinned at 0 in the gate); an
//! `arc` value unboxed for a `shared` parameter without ever being bound
//! (`inspect(shared fresh())`) drops its handle on the floor (CLOSED
//! 2026-09-07, pinned at 0 in the gate); a block-scoped `arc` local was
//! never released at all while release was function-scoped, which inside a
//! `while` body was unbounded (CLOSED 2026-09-15 by the block-scope drop
//! point in `emitStmts`, pinned at 0 in the gate); reassigning an `arc` `var`
//! leaked the previous box (CLOSED 2026-09-15); and an `owned` String or
//! list PLACE bound as `arc` was not boxed at all, because
//! `cell_arc_from_string` moves its argument while `borrowck.zig` left the
//! source unmoved (boxed since 2026-09-16 at `let`, at a direct `-> arc`
//! return, by assignment into a whole `arc` var, as an `arc` call argument and into a struct literal's `arc` field, for a whole binding, which borrowck now moves; see
//! `isMovedOwnedBinding`). That list is what running programs
//! has found, not a proof that nothing else dangles; `docs/OWNERSHIP.md` R11
//! records exactly which positions the search covered, values as well as
//! places.

const std = @import("std");
const ast = @import("ast.zig");
const borrowck = @import("borrowck.zig");
const Io = std.Io;

const cg_model = @import("codegen/model.zig");
const cg_helpers = @import("codegen/helpers.zig");
const cg_lower = @import("codegen/lower.zig");
const cg_conversion = @import("codegen/conversion.zig");
const cg_expr = @import("codegen/expr.zig");
const cg_stmts = @import("codegen/stmts.zig");
const cg_module = @import("codegen/module.zig");
const cg_tests_support = @import("codegen/tests_support.zig");
const cg_tests_lowering = @import("codegen/tests_lowering.zig");
const cg_tests_arc = @import("codegen/tests_arc.zig");
const cg_tests_ownership = @import("codegen/tests_ownership.zig");
const cg_tests_conversions = @import("codegen/tests_conversions.zig");
pub const Shape = cg_model.Shape;
pub const CType = cg_model.CType;
const Local = cg_model.Local;
const Dest = cg_model.Dest;
const eq = cg_helpers.eq;
const resultBase = cg_helpers.resultBase;
const isOwningOptional = cg_helpers.isOwningOptional;
const hasOwningGlue = cg_helpers.hasOwningGlue;
const glueStem = cg_helpers.glueStem;
const isOwningResult = cg_helpers.isOwningResult;
const Exit = cg_helpers.Exit;
const OwningTemp = cg_helpers.OwningTemp;
const SkipLabel = cg_helpers.SkipLabel;
const nameIn = cg_helpers.nameIn;
const stmtsUse = cg_helpers.stmtsUse;

// The test files are reached only through this reference.
comptime {
    _ = cg_tests_support;
    _ = cg_tests_lowering;
    _ = cg_tests_arc;
    _ = cg_tests_ownership;
    _ = cg_tests_conversions;
}

/// Anything an emit step can fail with: a writer failure or an arena failure.
pub const EmitError = Io.Writer.Error || std.mem.Allocator.Error;

const Alloc = std.mem.Allocator.Error;

/// Emit C for a Cell module.
pub const Generator = struct {
    allocator: std.mem.Allocator,
    writer: *Io.Writer,

    /// Scratch for composed type names and temporaries. Lives for exactly one
    /// `emitModule` call, so callers keep the two-argument `init`.
    arena: std.mem.Allocator = undefined,
    module: *const ast.Module = undefined,
    locals: std.ArrayList(Local) = .empty,
    /// `self.locals.items.len` at the entry of every `while` body currently
    /// being emitted, innermost last. A `break` or `continue` leaves every
    /// scope between itself and the loop at once, so it must drop every
    /// local declared since the LOOP's mark, not since the innermost
    /// block's: `emitLoopExitDrops` reads the top of this stack.
    loop_marks: std.ArrayList(usize) = .empty,
    /// The statements that run after the one being emitted, innermost
    /// block first, and the bodies of the enclosing loops (which run again).
    /// `usedLater` reads both so an after-loop release never frees a value
    /// a later statement still reads.
    later_rests: std.ArrayList([]const ast.Stmt) = .empty,
    loop_bodies: std.ArrayList([]const ast.Stmt) = .empty,
    /// Temporary owning scrutinees of the `match`es being emitted, innermost
    /// last (2026-09-17). An early exit releases the untaken ones it leaves:
    /// a `return` all of them, a `break`/`continue` those created inside the
    /// loop it leaves. `taken` is set while emitting the arm that bound the
    /// owning payload with `owned`.
    owning_temps: std.ArrayList(OwningTemp) = .empty,
    /// Every `while` being emitted whose skip-revival `break`s jump to a
    /// label after its releases (`after_loop_skip`), innermost last.
    skip_labels: std.ArrayList(SkipLabel) = .empty,
    /// The next skip label's number, unique within the translation unit.
    next_skip_label: usize = 0,
    /// The enclosing statement list's block-end exit, for branch-end drops
    /// that ask "live here, dead after the merge".
    current_after: ?Exit = null,
    /// The `after_branch` exit of the innermost statement-position `if` or
    /// `match` whose branches are being emitted. A branch-end release is
    /// skipped for a binding borrowck recorded still held there.
    current_merge: ?Exit = null,
    /// The drop point currently being emitted. A jump after a move and
    /// before a later revival must not free the taken field; missing or
    /// not-dead keeps the leak.
    drop_exit: ?Exit = null,
    temp_counter: usize = 0,
    /// Name of the function being emitted, used in panic messages.
    current_fn: []const u8 = "",
    /// The current function's declared return type, lowered exactly as
    /// `writeSignature` lowers it (always `.owned`). Set once per `emitFn`
    /// call and read by the `return` handler, which needs it to materialize
    /// a return value into a temporary before running drops -- see
    /// `emitReturnStmt`.
    current_ret_ty: CType = CType.void_type,
    /// Borrow-check results for the module being emitted, valid only for
    /// the duration of one `emitModule` call. See the module doc comment's
    /// id-numbering agreement for what this is used for and why it is safe
    /// to run once, up front, rather than per function.
    checker: ?*borrowck.Checker = null,
    /// Mirrors `borrowck.Checker.next_binding_id`: incremented at exactly
    /// the three places `declare` runs there (see `pushLocal`), and, like
    /// that counter, reset only once per module, never per function.
    next_binding_id: u32 = 0,

    /// Whether a FIELD store may release the target's old value first. Every
    /// axis defaults to "keep the leak" unless listed as covered:
    ///
    ///   * target shape: a `.field` chain (any depth, through annotations)
    ///     rooted at an identifier. A deref, index or call in the chain
    ///     answers false (`ast.rootName` stops there, and borrowck records
    ///     nothing).
    ///   * root: an `owned` `record` local visible here, droppable (a local
    ///     or an `owned` parameter; a match-arm binding is not droppable).
    ///     An `exclusive`/`shared` root, whose old field value belongs to
    ///     the referent, is NOT covered: not measured.
    ///   * field type: an owning `String` or list, by value. A record field
    ///     with drop glue, an `arc` field (R9/R10 refuse the store), an
    ///     optional or Result field are NOT covered: not measured.
    ///   * liveness: `fieldAssignReleasesOldValue`, which is false when the
    ///     target path, a parent or a subfield was moved (R3a revival), when
    ///     the right side moved it, and when any move of the root's binding
    ///     sits in an enclosing `while` body.
    pub fn fieldStoreReleasesOld(self: *Generator, target: *const ast.Expr, want: CType) bool {
        if (want.pointee != null) return false;
        if (want.shape != .string and want.shape != .slice) return false;
        var t = target;
        while (t.kind == .annotated) t = t.kind.annotated.value;
        if (t.kind != .field) return false;
        const root = ast.rootName(t) orelse return false;
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (!eq(local.name, root)) continue;
            if (!local.droppable or local.ownership != .owned) return false;
            if (local.ty.shape != .record or local.ty.pointee != null) return false;
            const checker = self.checker orelse return false;
            return checker.fieldAssignReleasesOldValue(root.ptr);
        }
        return false;
    }

    /// The innermost visible local an assignment target names, when its old
    /// value is safe to release before the store (see `emitAssign`): a
    /// droppable `arc` binding, or a droppable `owned` `String` or list
    /// binding that borrowck never moved. A field path, a deref through a
    /// borrow, a record, a moved `owned` binding, and every other ownership
    /// answer null and keep the plain emission. A parameter is a droppable
    /// local since R11 row 1 and is covered like any other: the callee owns
    /// an `owned` or `arc` parameter's value.
    pub fn reassignedDroppableLocal(self: *Generator, target: *const ast.Expr) ?Local {
        var t = target;
        while (t.kind == .annotated) t = t.kind.annotated.value;
        if (t.kind != .ident) return null;
        const name = t.kind.ident;
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (!eq(local.name, name)) continue;
            if (!local.droppable or !(hasDropCall(local.ty.shape) or hasOwningGlue(local.ty))) return null;
            switch (local.ownership) {
                .arc => return local,
                .owned => {
                    if (local.ty.shape != .string and local.ty.shape != .slice and !hasOwningGlue(local.ty)) return null;
                    // No checker means no move facts, and without them the
                    // pre-drop cannot be proven safe: keep the leak. The
                    // checker answers per store, not per binding: whether
                    // this target still held a value here, with every
                    // enclosing loop's back edge accounted for.
                    const checker = self.checker orelse return null;
                    if (!checker.assignReleasesOldValue(name.ptr)) return null;
                    return local;
                },
                else => return null,
            }
        }
        return null;
    }

    // ── drop insertion (task 3) ────────────────────────────────────────

    /// The drop vocabulary in runtime/cell_rt.h, and ONLY that: the three
    /// shapes the runtime can release directly. A `record` is deliberately
    /// absent here even though records are dropped now (R11 row 2), because
    /// this predicate is also the key of the owning-header guard in
    /// `emitValueInto`, which makes a record COPY into a slot rather than
    /// take a pointer, and a test pins that ("records still copy"). Whether a
    /// scope exit releases a value is `needsDrop`'s question, asked of the
    /// whole type; whether the runtime has a call for a shape is this one.
    pub fn hasDropCall(shape: Shape) bool {
        return switch (shape) {
            .string, .slice, .arc => true,
            else => false,
        };
    }

    /// R11 row 2. Whether a value of this type is released at scope end. The
    /// three runtime shapes always are; a `record` is when it has drop glue,
    /// which `recordNeedsDrop` decides from its fields.
    pub fn needsDrop(self: *Generator, ty: CType) Alloc!bool {
        if (hasDropCall(ty.shape)) return true;
        if (ty.shape == .result or ty.shape == .optional) return hasOwningGlue(ty);
        if (ty.shape != .record) return false;
        return self.recordNeedsDrop(ty.name, 0);
    }

    /// A struct needs glue when some field is `owned` or `arc` AND its
    /// lowered type needs a drop, recursively through nested records. The
    /// keyword is checked FIRST and the lowering carries it: `shared [Byte]`
    /// and `owned [Byte]` both lower to `cell_slice_t`, and only the keyword
    /// says which one this struct owns; `arc Point` lowers to `cell_arc_t`
    /// while `arc Int` stays `int64_t`, and only the lowering knows which.
    /// A `copy` field of a resource-bearing type cannot exist (borrowck
    /// refuses the declaration), and a `shared`/`exclusive` field cannot
    /// either. The depth guard is for a self-referential struct the
    /// typechecker does not refuse; such a type has no finite C layout
    /// anyway, so answering "no glue" for it costs nothing real.
    fn recordNeedsDrop(self: *Generator, name: []const u8, depth: usize) Alloc!bool {
        if (depth > 16) return false;
        const def = self.findStruct(name) orelse return false;
        for (def.fields) |f| {
            if (f.ownership != .owned and f.ownership != .arc) continue;
            const fty = try self.lowerType(&f.ty, f.ownership);
            if (hasDropCall(fty.shape)) return true;
            if (fty.shape == .record and try self.recordNeedsDrop(fty.name, depth + 1)) return true;
        }
        return false;
    }

    /// The glue itself, one function per struct that `recordNeedsDrop`
    /// answers yes for. Emitted in two passes AFTER every typedef: all
    /// prototypes, then all definitions, so a nested record's glue resolves
    /// whatever order the structs were written in. (The typedefs themselves
    /// are emitted in source order and a struct naming a LATER struct by
    /// value already fails `cc` on the typedef, so glue order cannot make that
    /// case worse; it is recorded in OWNERSHIP.md as its own gap.)
    ///
    /// `static inline __attribute__((unused))`, and the attribute is not
    /// decoration: a struct that is declared and never constructed in a module
    /// (`examples/arc.cell`'s `Session`, or any helper struct a program only
    /// nests) leaves its glue uncalled, and clang's `-Wunused-function` fires
    /// on an unused `static inline` in the defining file, which `-Werror`
    /// turns into a failed build. Measured before this line was written: seven
    /// probe programs all failed `cc` on `cell_drop_Outer`. GCC-style
    /// attributes are already part of this backend's contract through
    /// `cell_rt.h` (`cell_panic` is `__attribute__((noreturn))`).
    ///
    /// Field order is REVERSE declaration order, matching `pendingDrops`'s
    /// convention for locals: a later field may reference an earlier one.
    pub fn emitDropGlue(self: *Generator, module: *const ast.Module) EmitError!void {
        const out = self.writer;
        var any = false;
        for (module.items) |item| {
            if (item.kind != .struct_def) continue;
            const sd = item.kind.struct_def;
            if (!try self.recordNeedsDrop(sd.name, 0)) continue;
            try out.print("static inline __attribute__((unused)) void cell_drop_{s}(cell_{s} *r);\n", .{ sd.name, sd.name });
            any = true;
        }
        if (any) try out.writeAll("\n");
        for (module.items) |item| {
            if (item.kind != .struct_def) continue;
            const sd = item.kind.struct_def;
            if (!try self.recordNeedsDrop(sd.name, 0)) continue;
            try out.print("// R11 row 2: drop glue for `{s}`, one release per owning field.\n", .{sd.name});
            try out.print("static inline __attribute__((unused)) void cell_drop_{s}(cell_{s} *r) {{\n", .{ sd.name, sd.name });
            var i = sd.fields.len;
            while (i > 0) {
                i -= 1;
                const f = sd.fields[i];
                if (f.ownership != .owned and f.ownership != .arc) continue;
                const fty = try self.lowerType(&f.ty, f.ownership);
                switch (fty.shape) {
                    .string => try out.print("  cell_string_free(&r->{s});\n", .{f.name}),
                    .slice => try out.print("  cell_slice_free(&r->{s});\n", .{f.name}),
                    .arc => try out.print("  cell_arc_drop(r->{s});\n", .{f.name}),
                    .record => if (try self.recordNeedsDrop(fty.name, 1)) {
                        try out.print("  cell_drop_{s}(&r->{s});\n", .{ fty.name, f.name });
                    },
                    else => {},
                }
            }
            try out.writeAll("}\n\n");
        }
    }

    /// Release glue for every owning Result pair the module names
    /// (2026-09-17), in the record glue's two-pass shape. Only the pairs
    /// written in a signature, a struct field, or a `let` annotation are
    /// collected; a pair reached otherwise has its type from one of those.
    pub fn emitResultDropGlue(self: *Generator, module: *const ast.Module) EmitError!void {
        var seen: std.ArrayList([]const u8) = .empty;
        for (module.items) |item| {
            switch (item.kind) {
                .fn_def => |f| {
                    for (f.params) |p| try self.collectOwningResults(&p.ty, &seen);
                    if (f.return_type) |rt| try self.collectOwningResults(&rt, &seen);
                    if (f.body) |body| try self.collectOwningResultsInStmts(body, &seen);
                },
                .struct_def => |sd| for (sd.fields) |fld| try self.collectOwningResults(&fld.ty, &seen),
                else => {},
            }
        }
        if (seen.items.len == 0) return;
        const out = self.writer;
        for (seen.items) |base| {
            try out.print("static inline __attribute__((unused)) void cell_drop_{s}({s}_t *r);\n", .{ base["cell_".len..], base });
        }
        try out.writeAll("\n");
        for (seen.items) |base| {
            if (eq(base, "cell_opt_string")) {
                try out.writeAll("// Owning String? (2026-09-17): release the payload only when present.\n");
                try out.writeAll("static inline __attribute__((unused)) void cell_drop_opt_string(cell_opt_string_t *r) {\n");
                try out.writeAll("  if (r->has_value) cell_string_free(&r->value);\n}\n\n");
                continue;
            }
            const ok_owns = std.mem.startsWith(u8, base, "cell_res_string_");
            const err_owns = std.mem.endsWith(u8, base, "_string");
            try out.print("// Owning String Result (2026-09-17): release the side that is present.\n", .{});
            try out.print("static inline __attribute__((unused)) void cell_drop_{s}({s}_t *r) {{\n", .{ base["cell_".len..], base });
            if (ok_owns and err_owns) {
                try out.writeAll("  if (r->ok) cell_string_free(&r->as.ok); else cell_string_free(&r->as.err);\n}\n\n");
            } else if (ok_owns) {
                try out.writeAll("  if (r->ok) cell_string_free(&r->as.ok);\n}\n\n");
            } else {
                try out.writeAll("  if (!r->ok) cell_string_free(&r->as.err);\n}\n\n");
            }
        }
    }

    fn collectOwningResults(self: *Generator, ty: *const ast.TypeExpr, seen: *std.ArrayList([]const u8)) Alloc!void {
        switch (ty.*) {
            .result => |r| {
                const t = try self.lowerType(ty, .owned);
                if (isOwningResult(t)) {
                    const base = resultBase(t).?;
                    for (seen.items) |b| {
                        if (eq(b, base)) break;
                    } else try seen.append(self.arena, base);
                }
                try self.collectOwningResults(r.ok, seen);
                try self.collectOwningResults(r.err, seen);
            },
            .optional => |inner| {
                const t = try self.lowerType(ty, .owned);
                if (isOwningOptional(t)) {
                    const base = t.text[0 .. t.text.len - "_t".len];
                    for (seen.items) |b| {
                        if (eq(b, base)) break;
                    } else try seen.append(self.arena, base);
                }
                try self.collectOwningResults(inner, seen);
            },
            .list => |inner| try self.collectOwningResults(inner, seen),
            .ref => |r| try self.collectOwningResults(r.inner, seen),
            .name, .unit => {},
        }
    }

    fn collectOwningResultsInStmts(self: *Generator, stmts: []const ast.Stmt, seen: *std.ArrayList([]const u8)) Alloc!void {
        for (stmts) |*st| {
            switch (st.kind) {
                .let => |l| {
                    if (l.ty) |t| try self.collectOwningResults(&t, seen);
                    if (l.value) |*v| try self.collectOwningResultsInExpr(v, seen);
                },
                .while_stmt => |wl| try self.collectOwningResultsInStmts(wl.body, seen),
                .expr => |*x| try self.collectOwningResultsInExpr(x, seen),
                else => {},
            }
        }
    }

    fn collectOwningResultsInExpr(self: *Generator, e: *const ast.Expr, seen: *std.ArrayList([]const u8)) Alloc!void {
        switch (e.kind) {
            .block => |stmts| try self.collectOwningResultsInStmts(stmts, seen),
            .if_expr => |i| {
                try self.collectOwningResultsInExpr(i.then_body, seen);
                if (i.else_body) |eb| try self.collectOwningResultsInExpr(eb, seen);
            },
            .match_expr => |m| for (m.arms) |arm| try self.collectOwningResultsInExpr(arm.body, seen),
            .annotated => |a| try self.collectOwningResultsInExpr(a.value, seen),
            else => {},
        }
    }

    /// One of the three drop calls, chosen by shape alone: `local.ownership`
    /// has already been checked by the caller (`pendingDrops`), so this only
    /// needs to pick the C spelling. `cell_string_free` and `cell_slice_free`
    /// take a pointer (`cell_rt.h`'s signatures); `cell_arc_drop` takes the
    /// handle by value, matching `applyOwnership`, which never makes an
    /// `arc` a pointer.
    pub fn emitDropFor(self: *Generator, indent: usize, local: Local) EmitError!void {
        try self.writeIndent(indent);
        switch (local.ty.shape) {
            .string => try self.writer.print("cell_string_free(&{s});\n", .{local.name}),
            .slice => try self.writer.print("cell_slice_free(&{s});\n", .{local.name}),
            .arc => try self.writer.print("cell_arc_drop({s});\n", .{local.name}),
            // R11 row 2: through the generated glue, by pointer like the two
            // `_free` calls. `needsDrop` admitted this local, so glue exists.
            .record => {
                if (self.checker) |c| {
                    if (c.wasWhollyMoved(local.id)) {
                        // Revived after a whole move: pendingDropsSince already
                        // required recordLiveAtExit, so the glue frees the
                        // live value.
                        try self.writer.print("cell_drop_{s}(&{s});\n", .{ local.ty.name, local.name });
                        return;
                    }
                }
                const partial = if (self.checker) |c| c.wasMoved(local.id) else false;
                if (partial) {
                    try self.emitPartialRecordDrop(indent, local);
                } else {
                    try self.writer.print("cell_drop_{s}(&{s});\n", .{ local.ty.name, local.name });
                }
            },
            // An owning Result (2026-09-17), through its per-module glue.
            .result, .optional => try self.writer.print("cell_drop_{s}(&{s});\n", .{ glueStem(local.ty), local.name }),
            else => unreachable, // needsDrop already filtered these out.
        }
    }

    /// A record some of whose fields were moved out (`let owned m = p.a`),
    /// and not the record itself: release every owning field that was NOT
    /// moved, one call each, in the glue's reverse declaration order.
    /// Nested records recurse: a path equal to `"inner"` skips that field
    /// whole, a proper `"inner."` prefix partial-drops the inner struct
    /// (skip `inner.a`, free `inner.b`). Same fail-closed skip
    /// `fieldWasMoved` already uses: an unrecognised descendant still
    /// leaks rather than being freed while something else may own a piece.
    ///
    /// Before this existed the whole record was skipped, because
    /// `pendingDrops` read the binding-level `wasMoved`, so `p.b` leaked.
    /// It never double freed; this keeps it that way by construction. A
    /// move borrowck records on only one branch of an `if` is recorded as
    /// if it happened on every path, so any doubt resolves to leaving a
    /// field unreleased, never to releasing a buffer something else now
    /// owns. The indent for the first line is already written by
    /// `emitDropFor`, which is why it gets the comment.
    fn emitPartialRecordDrop(self: *Generator, indent: usize, local: Local) EmitError!void {
        const checker = self.checker.?;
        const out = self.writer;
        // Every caller today reaches this through `pendingDrops`, which has
        // already excluded a wholly moved record. Checked again here anyway,
        // because `fieldWasMoved` deliberately ignores a whole-binding move:
        // a caller that forgot the filter would otherwise release every
        // field of a record something else now owns, a double free.
        if (checker.wasWhollyMoved(local.id)) {
            try out.print("/* {s}: moved as a whole, nothing to release */\n", .{local.name});
            return;
        }
        try out.print("/* {s}: fields moved out; releasing only unmoved owning fields */\n", .{local.name});
        try self.emitPartialFields(indent, local.id, local.name, local.ty.name, "", 0);
    }

    /// Walk one record's owning fields under `path_prefix`, releasing
    /// those not moved. `c_base` is the C access (`p`, then `p.inner`).
    /// Depth 16 matches `recordNeedsDrop`: a self-referential struct the
    /// typechecker does not refuse has no finite C layout anyway.
    fn emitPartialFields(
        self: *Generator,
        indent: usize,
        binding: u32,
        c_base: []const u8,
        struct_name: []const u8,
        path_prefix: []const u8,
        depth: usize,
    ) EmitError!void {
        if (depth > 16) return;
        const checker = self.checker.?;
        const out = self.writer;
        const def = self.findStruct(struct_name) orelse return;
        var i = def.fields.len;
        while (i > 0) {
            i -= 1;
            const f = def.fields[i];
            if (f.ownership != .owned and f.ownership != .arc) continue;
            const field_path: []const u8 = if (path_prefix.len == 0) f.name else try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path_prefix, f.name });
            if (checker.fieldWasMovedWhole(binding, field_path)) continue;
            if (self.drop_exit) |ex| {
                if (checker.fieldDeadAtExit(ex.kind, ex.key, binding, field_path)) continue;
            }
            const fty = try self.lowerType(&f.ty, f.ownership);
            if (checker.fieldWasMoved(binding, field_path)) {
                // Proper prefix only: whole was already skipped. Recurse
                // into a nested record; anything else fails closed.
                if (fty.shape == .record and try self.recordNeedsDrop(fty.name, 1)) {
                    const nested_c = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ c_base, f.name });
                    try self.emitPartialFields(indent, binding, nested_c, fty.name, field_path, depth + 1);
                }
                continue;
            }
            switch (fty.shape) {
                .string => {
                    try self.writeIndent(indent);
                    try out.print("cell_string_free(&{s}.{s});\n", .{ c_base, f.name });
                },
                .slice => {
                    try self.writeIndent(indent);
                    try out.print("cell_slice_free(&{s}.{s});\n", .{ c_base, f.name });
                },
                .arc => {
                    try self.writeIndent(indent);
                    try out.print("cell_arc_drop({s}.{s});\n", .{ c_base, f.name });
                },
                .record => if (try self.recordNeedsDrop(fty.name, 1)) {
                    try self.writeIndent(indent);
                    try out.print("cell_drop_{s}(&{s}.{s});\n", .{ fty.name, c_base, f.name });
                },
                else => {},
            }
        }
    }

    /// Every local a scope exit at THIS exact point in the walk must drop,
    /// in reverse declaration order (later bindings may reference earlier
    /// ones, so they are torn down first -- what C++ and Rust both do).
    /// `self.locals.items` already holds exactly the bindings still visible
    /// here: a nested block's own locals are gone from it by the time its
    /// `emitStmts` call returns (see that function's `defer`), so nothing
    /// extra needs to be excluded.
    ///
    /// Three checks gate a local in, matching the brief's rule exactly:
    /// `droppable` (not a parameter, not a match-arm binding -- see
    /// `Local.droppable`), an `owned` or `arc` ownership annotation (never
    /// `shared`, `exclusive`, or `copy`), and `!checker.wasMoved(id)` (never
    /// a place borrowck considers moved, maybe-moved included). A struct
    /// (`record` shape) is admitted by `needsDrop` exactly when it has drop
    /// glue (R11 row 2); a scalar-only struct is still excluded there, not by
    /// an ownership check, because a struct can be `owned` too.
    pub fn pendingDrops(self: *Generator, exit: ?Exit) Alloc![]const Local {
        return self.pendingDropsSince(0, exit);
    }

    /// `pendingDrops` restricted to the locals at index `mark` and above:
    /// the ones a block that started at `mark` owns. The same three checks
    /// gate each one in, and `isShadowedAt` still looks at EVERY later
    /// binding, so a block-local shadowed by a later block-local is
    /// suppressed exactly as at function scope.
    ///
    /// `exit` names the drop point as borrowck recorded it. A non-record
    /// local that borrowck saw moved is still dropped when borrowck vouches
    /// that it held a value at this exact exit (an R3a revival); a null exit,
    /// or one borrowck did not record, keeps the old skip and its leak.
    fn pendingDropsSince(self: *Generator, mark: usize, exit: ?Exit) Alloc![]const Local {
        const checker = self.checker orelse return &.{};
        var out: std.ArrayList(Local) = .empty;
        var i = self.locals.items.len;
        while (i > mark) {
            i -= 1;
            const local = self.locals.items[i];
            if (self.isShadowedAt(i)) continue;
            if (!local.droppable) continue;
            if (local.ownership != .owned and local.ownership != .arc) continue;
            if (!try self.needsDrop(local.ty)) continue;
            if (local.ty.shape == .record) {
                // A record with only FIELDS moved out is still partly live,
                // and `emitDropFor` releases exactly its unmoved owning
                // fields. A wholly moved record that holds a fresh value at
                // this exit (revived) is released whole.
                if (checker.wasWhollyMoved(local.id)) {
                    const e = exit orelse continue;
                    if (!checker.recordLiveAtExit(e.kind, e.key, local.id)) continue;
                }
            } else if (checker.wasMoved(local.id)) {
                // Any other shape has no field path a move can take (a `copy`
                // sub-place like `buf.len` never reaches `movePlace`'s
                // record), so any recorded move is a whole move. It is
                // released only where borrowck says it was revived.
                const e = exit orelse continue;
                if (!checker.liveAtExit(e.kind, e.key, local.id)) continue;
            }
            try out.append(self.arena, local);
        }
        return out.items;
    }

    /// True when a LATER binding reuses this one's name, so the identifier
    /// `emitDropFor` would write no longer resolves to this binding in the
    /// emitted C.
    ///
    /// `emitDropFor` spells a drop by NAME, which silently assumes every
    /// visible binding has a distinct one. Shadowing breaks that, and it
    /// breaks it in the worst direction: both entries emit the same
    /// `cell_arc_drop(s)`, both resolve to the INNER `s`, the inner box is
    /// released twice and the outer one is never released at all. That is a
    /// double free, measured under AddressSanitizer, not a theoretical one.
    ///
    /// The check is deliberately about ALL later bindings rather than only
    /// droppable ones: what decides the question is which declaration the C
    /// identifier resolves to, and a match-arm binding shadows a name just as
    /// effectively as a `let` does. A parameter never appears here, because
    /// parameters are pushed before any statement and so are never the LATER
    /// binding. Note the reverse walk reaches the innermost binding first, so
    /// the innermost one is the only one that is ever nameable, and it is the
    /// one kept.
    ///
    /// Suppressing the outer drop leaks the outer box. That is the correct
    /// side of this backend's asymmetry, and the same choice `pushLocal`
    /// already makes when it cannot positively confirm a binding id.
    /// `cell check` only WARNS about shadowing, so nothing upstream prevents
    /// this from arising.
    fn isShadowedAt(self: *const Generator, index: usize) bool {
        const name = self.locals.items[index].name;
        for (self.locals.items[index + 1 ..]) |later| {
            if (eq(later.name, name)) return true;
        }
        return false;
    }

    /// The end-of-function-body drop point: every visible local. Nested
    /// statement-position scopes release their own locals through
    /// `emitDropsSince` at the end of `emitStmts`, so by the time this runs
    /// the function's top-level `let`s are the only ones still visible.
    pub fn emitScopeDrops(self: *Generator, indent: usize, exit: ?Exit) EmitError!void {
        for (try self.pendingDrops(exit)) |local| try self.emitDropFor(indent, local);
    }

    /// The block-scope drop point: the locals declared since `mark`.
    pub fn emitDropsSince(self: *Generator, mark: usize, indent: usize, exit: ?Exit) EmitError!void {
        for (try self.pendingDropsSince(mark, exit)) |local| try self.emitDropFor(indent, local);
    }

    /// The `break`/`continue` drop point: everything declared since the
    /// innermost enclosing `while` body opened, which includes the locals of
    /// any block, `if` branch, or arm body the jump sits inside. Outside any
    /// loop there is nothing to do; the parser does not produce a bare
    /// `break`, so the empty case is defensive rather than reachable.
    pub fn emitLoopExitDrops(self: *Generator, key: Exit, indent: usize) EmitError!void {
        if (self.loop_marks.items.len == 0) return;
        const mark = self.loop_marks.items[self.loop_marks.items.len - 1];
        const saved = self.drop_exit;
        self.drop_exit = key;
        defer self.drop_exit = saved;
        try self.emitDropsSince(mark, indent, key);
        // Temporaries created inside the loop this jump leaves.
        try self.emitTempReleases(self.loop_marks.items.len, indent);
    }

    /// After a `while`: release an outer binding this loop moved and then
    /// revived on every path out (`ExitKind.after_loop`). Moved-only, and
    /// skipped when the enclosing `current_after` already holds the value
    /// (function-end will drop it). `loop_moved` still poisons in-loop
    /// jumps and the function-end `block_end`, so those stay skipped.
    ///
    /// Guards, each falsified under AddressSanitizer (exit 134) then
    /// restored: ignoring a dead `.jump` when recording after_loop
    /// (`take(v); if i > n { break }; v = "b"`) double-frees, because C
    /// `break` runs this code; emitting these drops for unmoved locals
    /// double-frees with function-end; dropping the outer var at
    /// `continue` because the jump bit was live (`take(v); v = "b";
    /// continue`) is a use-after-free on the next iteration, which is why
    /// in-loop invalidation stays; treating a condition move as live
    /// (`while consume(v) { v = make() }`) double-frees, because the last
    /// failing condition already took `v`.
    /// The label a skip-revival `break` jumps to, or null for a plain
    /// `break`. Only the innermost loop can own it: borrowck records a
    /// `break` only for the loop it leaves.
    pub fn skipLabelFor(self: *const Generator, break_key: usize) ?usize {
        const checker = self.checker orelse return null;
        const loop_key = checker.skipBreakLoop(break_key) orelse return null;
        const n = self.skip_labels.items.len;
        if (n == 0) return null;
        const top = self.skip_labels.items[n - 1];
        if (top.loop_key != loop_key) return null;
        return top.id;
    }

    /// Whether `name` is mentioned by anything that can run after the
    /// current statement: the rest of every enclosing block, and every
    /// enclosing loop body. Over-approximate on purpose (a shadowing `let`
    /// also counts): a false yes only leaks.
    fn usedLater(self: *const Generator, name: []const u8) bool {
        for (self.later_rests.items) |r| {
            if (stmtsUse(r, name)) return true;
        }
        for (self.loop_bodies.items) |b| {
            if (stmtsUse(b, name)) return true;
        }
        return false;
    }

    pub fn emitAfterLoopDrops(self: *Generator, key: usize, indent: usize) EmitError!void {
        const checker = self.checker orelse return;
        const here: Exit = .{ .kind = .after_loop, .key = key };
        const after = self.current_after;
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (self.isShadowedAt(i)) continue;
            if (!local.droppable) continue;
            if (local.ownership != .owned and local.ownership != .arc) continue;
            if (!try self.needsDrop(local.ty)) continue;
            // A later statement still reads or moves it (2026-09-17): the
            // block end is poisoned for loop-moved bindings, so this leaks.
            if (self.usedLater(local.name)) continue;
            if (local.ty.shape == .record) {
                if (!checker.wasWhollyMoved(local.id)) continue;
                if (!checker.recordLiveAtExit(here.kind, here.key, local.id) and
                    !checker.recordLiveAtExit(.after_loop_skip, here.key, local.id)) continue;
                if (after) |a| {
                    if (checker.recordLiveAtExit(a.kind, a.key, local.id)) continue;
                }
            } else {
                if (!checker.wasMoved(local.id)) continue;
                // `after_loop_skip` is sound only because each dead `break`
                // is lowered as a jump past this release (`skipLabelFor`).
                if (!checker.liveAtExit(here.kind, here.key, local.id) and
                    !checker.liveAtExit(.after_loop_skip, here.key, local.id)) continue;
                if (after) |a| {
                    if (checker.liveAtExit(a.kind, a.key, local.id)) continue;
                }
            }
            try self.emitDropFor(indent, local);
        }
    }

    pub fn hasUntakenTemps(self: *const Generator, min_depth: usize) bool {
        for (self.owning_temps.items) |t| {
            if (t.loop_depth >= min_depth and !t.taken) return true;
        }
        return false;
    }

    /// Release the untaken temporary owning scrutinees created at loop depth
    /// `min_depth` or deeper, innermost first.
    pub fn emitTempReleases(self: *Generator, min_depth: usize, indent: usize) EmitError!void {
        var i = self.owning_temps.items.len;
        while (i > 0) {
            i -= 1;
            const t = self.owning_temps.items[i];
            if (t.loop_depth < min_depth or t.taken) continue;
            try self.emitTempRelease(indent, t.ty, t.name);
        }
    }

    /// The one spelling of a temporary scrutinee's release, shared by the
    /// arm end and the early exits: an owned String through the runtime, an
    /// owning Result or `String?` through its per-module glue.
    pub fn emitTempRelease(self: *Generator, indent: usize, ty: CType, name: []const u8) EmitError!void {
        try self.writeIndent(indent);
        if (ty.shape == .string) {
            try self.writer.print("cell_string_free(&{s});\n", .{name});
        } else {
            try self.writer.print("cell_drop_{s}(&{s});\n", .{ glueStem(ty), name });
        }
    }

    /// D.2's two-condition rule at the end of one branch: a local declared
    /// OUTSIDE the branch (index below `mark`) that borrowck recorded live
    /// at this branch's end AND not live at `after` is released here.
    /// Both conditions read recorded entries; a missing record keeps the leak.
    /// A record that was not wholly moved still drops the owning fields that
    /// are live here and dead after the merge; the whole record is never
    /// freed on this path (that double-frees the unmoved sibling with the
    /// later partial drop).
    /// Held right after the enclosing if/match merge: no branch moved it,
    /// so no branch end may release it. False when there is no record.
    fn heldAfterMerge(self: *const Generator, binding: u32, whole_record: bool) bool {
        const checker = self.checker orelse return false;
        const m = self.current_merge orelse return false;
        return if (whole_record)
            checker.recordLiveAtExit(m.kind, m.key, binding)
        else
            checker.liveAtExit(m.kind, m.key, binding);
    }

    pub fn emitBranchEndDrops(self: *Generator, key: usize, mark: usize, after: ?Exit, indent: usize) EmitError!void {
        const checker = self.checker orelse return;
        const here: Exit = .{ .kind = .branch_end, .key = key };
        var i = mark;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (!local.droppable) continue;
            if (local.ownership != .owned and local.ownership != .arc) continue;
            if (!try self.needsDrop(local.ty)) continue;
            if (local.ty.shape == .record) {
                if (checker.wasWhollyMoved(local.id)) {
                    if (self.heldAfterMerge(local.id, true)) continue;
                    if (!checker.recordLiveAtExit(here.kind, here.key, local.id)) continue;
                    if (after) |a| {
                        if (checker.recordLiveAtExit(a.kind, a.key, local.id)) continue;
                    }
                    try self.emitDropFor(indent, local);
                } else {
                    try self.emitBranchEndFieldDrops(indent, local, here, after);
                }
                continue;
            }
            if (!checker.wasMoved(local.id)) continue;
            if (self.heldAfterMerge(local.id, false)) continue;
            if (!checker.liveAtExit(here.kind, here.key, local.id)) continue;
            if (after) |a| {
                if (checker.liveAtExit(a.kind, a.key, local.id)) continue;
            }
            try self.emitDropFor(indent, local);
        }
    }

    pub fn branchNeedsSynthesizedElse(self: *Generator, key: usize, mark: usize, after: ?Exit) EmitError!bool {
        const checker = self.checker orelse return false;
        const here: Exit = .{ .kind = .branch_end, .key = key };
        var i = mark;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (!local.droppable) continue;
            if (local.ownership != .owned and local.ownership != .arc) continue;
            if (!try self.needsDrop(local.ty)) continue;
            if (local.ty.shape == .record) {
                if (checker.wasWhollyMoved(local.id)) {
                    if (self.heldAfterMerge(local.id, true)) continue;
                    if (!checker.recordLiveAtExit(here.kind, here.key, local.id)) continue;
                    if (after) |a| {
                        if (checker.recordLiveAtExit(a.kind, a.key, local.id)) continue;
                    }
                    return true;
                }
                if (try self.branchEndKeepsField(local, here, after)) return true;
                continue;
            }
            if (!checker.wasMoved(local.id)) continue;
            if (self.heldAfterMerge(local.id, false)) continue;
            if (!checker.liveAtExit(here.kind, here.key, local.id)) continue;
            if (after) |a| {
                if (checker.liveAtExit(a.kind, a.key, local.id)) continue;
            }
            return true;
        }
        return false;
    }

    /// Live here and dead after the merge. Missing either record keeps the leak.
    fn fieldKeptOnBranch(
        checker: *const borrowck.Checker,
        here: Exit,
        after: ?Exit,
        binding: u32,
        path: []const u8,
    ) bool {
        if (!checker.fieldLiveAtExit(here.kind, here.key, binding, path)) return false;
        const a = after orelse return false;
        return checker.fieldDeadAtExit(a.kind, a.key, binding, path);
    }

    fn emitBranchEndFieldDrops(
        self: *Generator,
        indent: usize,
        local: Local,
        here: Exit,
        after: ?Exit,
    ) EmitError!void {
        _ = try self.walkBranchEndFields(indent, local.id, local.name, local.ty.name, "", here, after, 0, true);
    }

    fn branchEndKeepsField(self: *Generator, local: Local, here: Exit, after: ?Exit) EmitError!bool {
        return self.walkBranchEndFields(0, local.id, local.name, local.ty.name, "", here, after, 0, false);
    }

    /// Walk owning fields under `path_prefix`. A field live here and dead
    /// after the merge is released whole (or counted, when `emit` is false).
    /// A nested record with only a descendant moved recurses; a whole-field
    /// move on this branch is skipped. Same reverse-declaration order as
    /// `emitPartialFields`. Depth 16 matches `recordNeedsDrop`.
    fn walkBranchEndFields(
        self: *Generator,
        indent: usize,
        binding: u32,
        c_base: []const u8,
        struct_name: []const u8,
        path_prefix: []const u8,
        here: Exit,
        after: ?Exit,
        depth: usize,
        emit: bool,
    ) EmitError!bool {
        if (depth > 16) return false;
        const checker = self.checker orelse return false;
        const def = self.findStruct(struct_name) orelse return false;
        var any = false;
        var i = def.fields.len;
        while (i > 0) {
            i -= 1;
            const f = def.fields[i];
            if (f.ownership != .owned and f.ownership != .arc) continue;
            const field_path: []const u8 = if (path_prefix.len == 0) f.name else try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path_prefix, f.name });
            const fty = try self.lowerType(&f.ty, f.ownership);
            const held = if (self.current_merge) |m| checker.fieldLiveAtExit(m.kind, m.key, binding, field_path) else false;
            if (!held and fieldKeptOnBranch(checker, here, after, binding, field_path)) {
                if (emit) try self.emitOneFieldDrop(indent, c_base, f.name, fty);
                any = true;
                continue;
            }
            if (fty.shape == .record and checker.fieldWasMoved(binding, field_path) and !checker.fieldWasMovedWhole(binding, field_path)) {
                const nested_c = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ c_base, f.name });
                if (try self.walkBranchEndFields(indent, binding, nested_c, fty.name, field_path, here, after, depth + 1, emit)) {
                    any = true;
                }
            }
        }
        return any;
    }

    fn emitOneFieldDrop(self: *Generator, indent: usize, c_base: []const u8, name: []const u8, fty: CType) EmitError!void {
        const out = self.writer;
        switch (fty.shape) {
            .string => {
                try self.writeIndent(indent);
                try out.print("cell_string_free(&{s}.{s});\n", .{ c_base, name });
            },
            .slice => {
                try self.writeIndent(indent);
                try out.print("cell_slice_free(&{s}.{s});\n", .{ c_base, name });
            },
            .arc => {
                try self.writeIndent(indent);
                try out.print("cell_arc_drop({s}.{s});\n", .{ c_base, name });
            },
            .record => if (try self.recordNeedsDrop(fty.name, 1)) {
                try self.writeIndent(indent);
                try out.print("cell_drop_{s}(&{s}.{s});\n", .{ fty.name, c_base, name });
            },
            else => {},
        }
    }

    /// Release the locals a VALUE-position block declared, once its tail has
    /// been lowered into `dest`. This is the value-position half of the
    /// block-scoped release `emitStmts` does for statement-position blocks,
    /// and it was left out on 2026-09-15 for one reason: the block's value
    /// may BE one of those locals, and freeing it after the lowering is
    /// balanced only when the lowering copied it.
    ///
    /// The lowering into the DECLARED type happens outside these braces
    /// (`emitValueExpr` wraps the statement expression in the conversion),
    /// so anything the tail still references must survive the closing
    /// brace. `return { let owned t = make() \n &t }` emits
    /// `cell_str_t _cell_t0 = cell_string_as_str(&t)` inside and
    /// `cell_string_from_str(...)` around: free `t` inside and the view is
    /// copied from freed memory. A read tail at a list element is the same
    /// shape without the copy (`_cell_t0 = t`, and slice elements are never
    /// released). So the rule is: every local the tail can REACH is skipped.
    /// Reach is transitive through the block's own statements, and it has to
    /// be: `let shared v = &t \n v` names `t` nowhere in the tail, yet the
    /// tail's value is a view of `t`. The first version of this function
    /// (85570d6) asked `exprUses(tail, name)` alone and freed `t` under
    /// exactly that program, leaving `let shared s = { ... v }` a dangling
    /// view; caught the same night, the emitted C showed
    /// `cell_string_free(&t)` before `_cell_t0` left the braces. `tailReach`
    /// starts from the names the tail uses and adds, to a fixpoint, what
    /// every block-level `let` of a reached name and every assignment into
    /// a reached name uses, descending into nested statement lists. It is
    /// syntactic and over-approximates (a tail like `f(&t)` returning a
    /// scalar keeps `t` alive for nothing), and that is stated rather than
    /// optimised away: the cost of the over-approximation is a leak, the
    /// cost of an under-approximation is a use-after-free.
    ///
    /// ONE exception closes `examples/leaks/value_block_local.cell`: a tail
    /// that is a bare identifier naming a block-local `arc` binding, lowered
    /// into an `arc` destination. The arc-to-arc conversion CLONED it
    /// (`_cell_t0 = cell_arc_clone(a)`), so dropping `a` after is 1 -> 2 -> 1
    /// and the box is released when `dest` is. Any other destination shape
    /// (`shared`, an unknown lowered to `int64` by `emitValueExpr`) may hold
    /// the handle uncloned, so no scalar-destination shortcut is taken.
    /// A moved local (`wasMoved`) is already excluded by `pendingDropsSince`,
    /// which is how an `owned` tail moved out of the block needs no drop.
    pub fn emitValueBlockDrops(self: *Generator, mark: usize, stmts: []const ast.Stmt, tail: *const ast.Expr, dest: Dest, indent: usize) EmitError!void {
        const tail_ident: ?[]const u8 = blk: {
            var t = tail;
            while (t.kind == .annotated) t = t.kind.annotated.value;
            break :blk if (t.kind == .ident) t.kind.ident else null;
        };
        const reach = try self.tailReach(stmts, tail);
        const exit: ?Exit = if (stmts.len > 0) .{ .kind = .value_block_end, .key = @intFromPtr(stmts.ptr) } else null;
        for (try self.pendingDropsSince(mark, exit)) |local| {
            if (tail_ident) |n| {
                if (eq(n, local.name) and local.ownership == .arc and dest.ty.shape == .arc) {
                    try self.emitDropFor(indent, local);
                    continue;
                }
            }
            if (nameIn(reach.items, local.name)) continue;
            try self.emitDropFor(indent, local);
        }
    }

    // Declarations split into `codegen/*.zig`, re-exported so every
    // `Generator.name` and `self.name(...)` resolves exactly as before.
    pub const lowerType = cg_lower.lowerType;
    pub const baseType = cg_lower.baseType;
    pub const applyOwnership = cg_lower.applyOwnership;
    pub const pointerTo = cg_lower.pointerTo;
    pub const namedType = cg_lower.namedType;
    pub const resultSlug = cg_lower.resultSlug;
    pub const optionalInstance = cg_lower.optionalInstance;
    pub const inferExpr = cg_lower.inferExpr;
    pub const resolveCallee = cg_lower.resolveCallee;
    pub const findFn = cg_lower.findFn;
    pub const findStruct = cg_lower.findStruct;
    pub const findEnum = cg_lower.findEnum;
    pub const enumVariantOf = cg_lower.enumVariantOf;
    pub const pushScratchLocal = cg_lower.pushScratchLocal;
    pub const lookupLocal = cg_lower.lookupLocal;
    pub const pushLocal = cg_lower.pushLocal;
    pub const nextTemp = cg_lower.nextTemp;
    pub const writeIndent = cg_lower.writeIndent;
    pub const emitReturnStmt = cg_conversion.emitReturnStmt;
    pub const emitReturnValue = cg_conversion.emitReturnValue;
    pub const returnedArcNeedsRetain = cg_conversion.returnedArcNeedsRetain;
    pub const letType = cg_conversion.letType;
    pub const needsArcTemp = cg_conversion.needsArcTemp;
    pub const emitArcConversion = cg_conversion.emitArcConversion;
    pub const isMovedOwnedBinding = cg_conversion.isMovedOwnedBinding;
    pub const emitConversion = cg_conversion.emitConversion;
    pub const emitOwningStringConversion = cg_conversion.emitOwningStringConversion;
    pub const emitUnbox = cg_conversion.emitUnbox;
    pub const writeArcHandle = cg_conversion.writeArcHandle;
    pub const emitArgLike = cg_conversion.emitArgLike;
    pub const emitValueExpr = cg_expr.emitValueExpr;
    pub const tailReach = cg_expr.tailReach;
    pub const emitValueInto = cg_expr.emitValueInto;
    pub const emitBinary = cg_expr.emitBinary;
    pub const emitCond = cg_expr.emitCond;
    pub const emitExpr = cg_expr.emitExpr;
    pub const emitIndex = cg_expr.emitIndex;
    pub const emitWrap = cg_expr.emitWrap;
    pub const emitUnary = cg_expr.emitUnary;
    pub const emitCall = cg_expr.emitCall;
    pub const emitCallValued = cg_expr.emitCallValued;
    pub const writeCallExpr = cg_expr.writeCallExpr;
    pub const emitStructLit = cg_expr.emitStructLit;
    pub const emitListLit = cg_expr.emitListLit;
    pub const emitFloat = cg_expr.emitFloat;
    pub const emitStringLiteral = cg_expr.emitStringLiteral;
    pub const emitStmts = cg_stmts.emitStmts;
    pub const emitStmt = cg_stmts.emitStmt;
    pub const emitAssign = cg_stmts.emitAssign;
    pub const emitIfStmt = cg_stmts.emitIfStmt;
    pub const emitBranchStmt = cg_stmts.emitBranchStmt;
    pub const emitMatchStmt = cg_stmts.emitMatchStmt;
    pub const emitMatch = cg_stmts.emitMatch;
    pub const emitArmBody = cg_stmts.emitArmBody;
    pub const emitEffect = cg_stmts.emitEffect;
    pub const emitDiscarded = cg_stmts.emitDiscarded;
    pub const emitPatternTest = cg_stmts.emitPatternTest;
    pub const init = cg_module.init;
    pub const emitModule = cg_module.emitModule;
    pub const emitStructsInDependencyOrder = cg_module.emitStructsInDependencyOrder;
    pub const emitStructAfterDeps = cg_module.emitStructAfterDeps;
    pub const emitDepsOfType = cg_module.emitDepsOfType;
    pub const emitOptionalInstances = cg_module.emitOptionalInstances;
    pub const collectOptionals = cg_module.collectOptionals;
    pub const collectOptionalsInStmts = cg_module.collectOptionalsInStmts;
    pub const emitEntryPoint = cg_module.emitEntryPoint;
    pub const emitStruct = cg_module.emitStruct;
    pub const emitEnum = cg_module.emitEnum;
    pub const emitPrototype = cg_module.emitPrototype;
    pub const symbolFor = cg_module.symbolFor;
    pub const emitFn = cg_module.emitFn;
    pub const writeSignature = cg_module.writeSignature;
    pub const writeDecl = cg_module.writeDecl;
};
