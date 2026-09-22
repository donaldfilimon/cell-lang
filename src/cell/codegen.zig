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

/// Anything an emit step can fail with: a writer failure or an arena failure.
pub const EmitError = Io.Writer.Error || std.mem.Allocator.Error;

const Alloc = std.mem.Allocator.Error;

/// The value class a lowered C type belongs to. Ownership picks the spelling,
/// the shape decides how the value may be passed, borrowed, and accessed.
pub const Shape = enum {
    unit,
    integer,
    floating,
    boolean,
    byte,
    /// cell_str_t, a borrowed view
    str,
    /// cell_string_t, an owning heap string
    string,
    /// cell_slice_t
    slice,
    /// cell_arc_t
    arc,
    /// cell_opt_*_t
    optional,
    /// cell_result_t
    result,
    /// a Cell struct
    record,
    /// a Cell enum, an int32_t typedef
    enumeration,
    /// no declaration in scope: void*
    unknown,

    /// Primitives pass and return by value in EVERY ownership mode
    /// (cell_rt.h section 1), so no keyword may turn one into a pointer.
    /// An enum is a distinct integer type, so it counts as one.
    pub fn isPrimitive(self: Shape) bool {
        return switch (self) {
            .unit, .integer, .floating, .boolean, .byte, .enumeration => true,
            else => false,
        };
    }
};

/// A lowered C type: its spelling plus enough classification to decide how a
/// value of it is passed, borrowed, and selected from.
pub const CType = struct {
    text: []const u8,
    shape: Shape,
    /// True when `text` already ends in `*`.
    pointer: bool = false,
    /// The Cell name, for `record` and `enumeration`.
    name: []const u8 = "",
    /// The DECLARED element type, for a `slice`. Null when the type was not
    /// written down (an inferred `let`, or `CType.slice` used as a bare
    /// spelling), in which case the element type has to be inferred from the
    /// literal's first item and can disagree with what the consumer reads.
    ///
    /// `cell_slice_t` is type-erased: it carries a byte length and a stride,
    /// and nothing about it tells C what the elements are. So a list literal
    /// is the one expression whose element C type cannot be recovered from
    /// the expression itself, and getting it wrong is SILENT. `let owned zs:
    /// [String] = [a, a]` with an `arc` `a` built a buffer of `cell_arc_t`
    /// while the declared type said `cell_string_t`, passed `cell check`,
    /// compiled at `-Wall -Wextra -Werror`, and stayed clean under
    /// AddressSanitizer, because reinterpreting a refcount box pointer as a
    /// string length is type confusion rather than a memory error: a
    /// `shared [String]` callee read `len = 105690555222384`.
    ///
    /// Carrying the declared element down to `emitListLit` is what makes
    /// that loud. `applyOwnership` and `pointerTo` must preserve this field
    /// or it vanishes for `shared [T]` and `exclusive [T]`.
    elem: ?*const CType = null,
    /// What this points AT, set by `pointerTo`, which is the only thing in
    /// this file that ever sets `pointer`. Null for a non-pointer.
    ///
    /// Needed because a whole-value assignment through an `exclusive` borrow
    /// has to write the POINTEE, so it needs that type to lower the right
    /// side against. Recovering it by string surgery on `text` (stripping a
    /// leading `const ` and a trailing ` *`) would work today and break the
    /// first time a spelling changes; carrying it is exact.
    pointee: ?*const CType = null,
    /// For `optional`: the `T` of `T?`. For `result`: the ok payload. Null
    /// elsewhere. Preserved by `applyOwnership` and `pointerTo` like `elem`.
    payload: ?*const CType = null,
    /// For `result`: the `E`. Null elsewhere.
    err_payload: ?*const CType = null,

    pub const unknown: CType = .{ .text = "void*", .shape = .unknown };
    pub const void_type: CType = .{ .text = "void", .shape = .unit };
    pub const int64: CType = .{ .text = "int64_t", .shape = .integer };
    pub const float64: CType = .{ .text = "double", .shape = .floating };
    pub const boolean: CType = .{ .text = "bool", .shape = .boolean };
    pub const str: CType = .{ .text = "cell_str_t", .shape = .str };
    pub const string: CType = .{ .text = "cell_string_t", .shape = .string };
    pub const slice: CType = .{ .text = "cell_slice_t", .shape = .slice };
    pub const arc: CType = .{ .text = "cell_arc_t", .shape = .arc };
    /// The deprecated ABI-1 spelling, used only for a Result pair cell_rt.h
    /// has no instance for (see lowerType).
    pub const result: CType = .{ .text = "cell_result_t", .shape = .result };
};

/// One binding visible while emitting a function body.
const Local = struct {
    name: []const u8,
    ty: CType,
    /// The declared annotation, read straight off the AST node exactly as
    /// borrowck's own `Binding.ownership` is. Used, not `ty.shape`, to
    /// decide drop eligibility: a `shared`/`copy` local can end up with the
    /// same shape as an `owned` one when its initializer is a call (whose
    /// result type always lowers as owned; see `letType`), so shape alone
    /// cannot tell an owner from a borrow here.
    ownership: ast.Ownership,
    /// The id borrowck assigned to this exact declaration. See the module
    /// doc comment's id-numbering agreement.
    id: u32,
    /// True for a `let`/`var` local and for a parameter (R11 row 1). False
    /// for a match-arm binding, which the module doc comment excludes from
    /// dropping, and cleared by `pushLocal` when it cannot positively confirm
    /// a binding id. Only a candidate: `pendingDropsSince` still requires an
    /// `owned` or `arc` annotation and an unmoved place.
    ///
    /// This is not a return-retain question. A match-arm binding is
    /// undroppable and is still retained when returned, because it is a
    /// bitwise copy of a scrutinee this function may be releasing. A field
    /// named `is_param` once carried that distinction, and removing it on a
    /// derivation that missed the BLOCK arm body (`match s { b => { return b }
    /// }`) reopened a use-after-free; since R11 row 1 no declared binding
    /// is exempt from the retain, so the field went away with the exemption.
    droppable: bool,
};

/// Where a value-position `if`, `match`, or `block` must leave its result,
/// and the C type of that slot.
///
/// The type used to be absent, and its absence was a use-after-free. Each
/// branch assigned into the destination with a bare `emitExpr`, so an `arc`
/// place flowing out of a branch (`let arc r = if (c) { a } else { b }`)
/// aliased the box without retaining it, and scope exit then released both
/// `r` and `a`. A value slot is a position with a declared type exactly as a
/// parameter or a `let` is, so it has to answer the same conversion
/// question, and it cannot answer it without knowing the type.
const Dest = struct {
    name: []const u8,
    ty: CType,
};

/// A resolved call target. `symbol` is null when the callee is a computed
/// expression rather than a name.
const Callee = struct {
    symbol: ?[]const u8,
    def: ?ast.FnDef,
};

/// One `CELL_DEFINE_OPTIONAL` instantiation the module needs.
/// Where a struct is in the dependency-ordered typedef walk.
/// `visiting` doubles as the cycle mark: meeting it again means the module's
/// structs contain each other, which no emission order can fix.
const StructEmitState = enum { unvisited, visiting, emitted };

const OptionalInst = struct {
    /// Macro base, for example `cell_opt_Point`.
    base: []const u8,
    /// Element spelling, for example `cell_Point`.
    elem: []const u8,
    /// False for the instances cell_rt.h already defines.
    generated: bool,
};

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

    pub fn init(allocator: std.mem.Allocator, writer: *Io.Writer) Generator {
        return .{
            .allocator = allocator,
            .writer = writer,
        };
    }

    // ── module ──────────────────────────────────────────────────────────

    pub fn emitModule(self: *Generator, module: *const ast.Module) EmitError!void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        self.arena = arena_state.allocator();
        self.module = module;
        self.locals = .empty;
        self.temp_counter = 0;
        self.next_binding_id = 0;

        // One borrow-check pass over the whole module, up front, so its
        // binding ids never reset mid-module -- see the module doc
        // comment's id-numbering agreement. `checker.hasErrors()` is
        // deliberately not consulted: this backend has never validated its
        // input (there is no type checker feeding it either, per the
        // module doc comment above), and codegen still emits best-effort C
        // for a module borrowck rejects, same as before this task. Only
        // `wasMoved` is read from it.
        var checker = borrowck.Checker.init(self.allocator, module.path, null);
        defer checker.deinit();
        try checker.checkModule(module);
        self.checker = &checker;
        defer self.checker = null;

        const out = self.writer;
        try out.writeAll("// Generated by cell.\n");
        try out.writeAll("// Target ABI: runtime/cell_rt.h (callable from Zig / Swift / C++).\n");
        try out.print("// source: {s}\n\n", .{module.path});
        try out.writeAll("#include \"cell_rt.h\"\n\n");

        for (module.items) |item| {
            if (item.kind == .use_decl) try out.print("// use {s}\n", .{item.kind.use_decl});
        }

        // Enums first, unconditionally: an enum is a `typedef int32_t` with no
        // dependencies, and a struct field may name an enum while an enum can
        // never name a struct, so hoisting them cannot introduce an ordering
        // problem and removes one.
        for (module.items) |item| {
            if (item.kind == .enum_def) try self.emitEnum(item.kind.enum_def);
        }
        try self.emitStructsInDependencyOrder(module);

        try self.emitOptionalInstances();
        try self.emitDropGlue(module);
        try self.emitResultDropGlue(module);

        var wrote_prototype = false;
        for (module.items) |item| {
            if (item.kind != .fn_def) continue;
            try self.emitPrototype(item.kind.fn_def);
            wrote_prototype = true;
        }
        if (wrote_prototype) try out.writeAll("\n");

        for (module.items) |item| {
            if (item.kind != .fn_def) continue;
            if (item.kind.fn_def.body == null) continue;
            try self.emitFn(item.kind.fn_def);
        }

        try self.emitEntryPoint();
    }

    /// Struct typedefs in dependency order rather than source order.
    ///
    /// `struct A { owned b: B }` written above `struct B` used to emit
    /// `cell_A` first, and `cc` refused the module with
    /// `unknown type name 'cell_B'` while `cell check` accepted it -- a
    /// front end that passes and a back end that cannot be compiled.
    /// A field naming another struct needs that struct's typedef already
    /// emitted whether the field is a value (`cell_B b;`) or a `ref`
    /// (`cell_B *b;`), so the edge is taken from any `.name` appearing
    /// anywhere in the field's type expression. That is deliberately
    /// conservative: `[B]` lowers to the opaque `cell_slice_t` and needs no
    /// edge, but adding one only constrains the order further, and being
    /// wrong in that direction costs nothing while missing an edge emits
    /// C that does not compile.
    ///
    /// Depth-first post-order, source order among independent structs so the
    /// common case keeps emitting exactly as it did.
    ///
    /// On a cycle the back edge is dropped and both structs still emit, in
    /// post-order: `struct A { owned b: B }` with `struct B { owned a: A }`
    /// emits B then A, so a cycle IS reordered. That is worth stating
    /// precisely because the first version of this comment claimed the cycle
    /// was "left in source order", which is not what the code does -- the
    /// `visiting` arm returns rather than unwinding, so A's recursion into B
    /// completes and B is emitted first. Nothing is lost by it: a struct
    /// containing itself by value has no size in C, so no permutation
    /// compiles and `cc` reports the cycle either way. The point of the
    /// `visiting` arm is termination, not ordering.
    fn emitStructsInDependencyOrder(self: *Generator, module: *const ast.Module) EmitError!void {
        var state: std.StringHashMapUnmanaged(StructEmitState) = .empty;
        for (module.items) |item| {
            if (item.kind == .struct_def) {
                try state.put(self.arena, item.kind.struct_def.name, .unvisited);
            }
        }
        for (module.items) |item| {
            if (item.kind != .struct_def) continue;
            try self.emitStructAfterDeps(module, item.kind.struct_def, &state);
        }
    }

    fn emitStructAfterDeps(
        self: *Generator,
        module: *const ast.Module,
        s: ast.StructDef,
        state: *std.StringHashMapUnmanaged(StructEmitState),
    ) EmitError!void {
        switch (state.get(s.name) orelse .unvisited) {
            .emitted, .visiting => return, // already done, or a cycle: see the doc comment
            .unvisited => {},
        }
        try state.put(self.arena, s.name, .visiting);
        for (s.fields) |f| try self.emitDepsOfType(module, &f.ty, state);
        try state.put(self.arena, s.name, .emitted);
        try self.emitStruct(s);
    }

    fn emitDepsOfType(
        self: *Generator,
        module: *const ast.Module,
        ty: *const ast.TypeExpr,
        state: *std.StringHashMapUnmanaged(StructEmitState),
    ) EmitError!void {
        switch (ty.*) {
            .name => |n| {
                if (state.get(n) == null) return; // a builtin or an enum, not a struct in this module
                for (module.items) |item| {
                    if (item.kind != .struct_def) continue;
                    if (!std.mem.eql(u8, item.kind.struct_def.name, n)) continue;
                    try self.emitStructAfterDeps(module, item.kind.struct_def, state);
                    return;
                }
            },
            .optional => |inner| try self.emitDepsOfType(module, inner, state),
            .list => |inner| try self.emitDepsOfType(module, inner, state),
            .ref => |r| try self.emitDepsOfType(module, r.inner, state),
            .result => |r| {
                try self.emitDepsOfType(module, r.ok, state);
                try self.emitDepsOfType(module, r.err, state);
            },
            .unit => {},
        }
    }

    /// `CELL_DEFINE_OPTIONAL` lines for every optional the module names that
    /// cell_rt.h does not already instantiate. They come after the struct
    /// typedefs because an optional over a struct needs that struct first.
    fn emitOptionalInstances(self: *Generator) EmitError!void {
        var seen: std.ArrayList(OptionalInst) = .empty;
        for (self.module.items) |item| {
            switch (item.kind) {
                .fn_def => |f| {
                    for (f.params) |p| try self.collectOptionals(&p.ty, &seen);
                    if (f.return_type) |rt| try self.collectOptionals(&rt, &seen);
                    if (f.body) |body| try self.collectOptionalsInStmts(body, &seen);
                },
                .struct_def => |s| for (s.fields) |fld| try self.collectOptionals(&fld.ty, &seen),
                else => {},
            }
        }
        if (seen.items.len == 0) return;
        for (seen.items) |inst| {
            try self.writer.print("CELL_DEFINE_OPTIONAL({s}, {s})\n", .{ inst.base, inst.elem });
        }
        try self.writer.writeAll("\n");
    }

    fn collectOptionals(self: *Generator, ty: *const ast.TypeExpr, seen: *std.ArrayList(OptionalInst)) Alloc!void {
        switch (ty.*) {
            .optional => |inner| {
                const inst = try self.optionalInstance(inner);
                if (inst.generated) {
                    for (seen.items) |existing| {
                        if (std.mem.eql(u8, existing.base, inst.base)) break;
                    } else try seen.append(self.arena, inst);
                }
                try self.collectOptionals(inner, seen);
            },
            .list => |inner| try self.collectOptionals(inner, seen),
            .ref => |r| try self.collectOptionals(r.inner, seen),
            .result => |r| {
                try self.collectOptionals(r.ok, seen);
                try self.collectOptionals(r.err, seen);
            },
            .name, .unit => {},
        }
    }

    fn collectOptionalsInStmts(self: *Generator, stmts: []const ast.Stmt, seen: *std.ArrayList(OptionalInst)) Alloc!void {
        for (stmts) |s| {
            switch (s.kind) {
                .let => |l| if (l.ty) |t| try self.collectOptionals(&t, seen),
                else => {},
            }
        }
    }

    /// A C `main` that calls the Cell `main`, so a module with an entry point
    /// links into an executable. Without this there is no path from `.cell` to
    /// a program.
    fn emitEntryPoint(self: *Generator) EmitError!void {
        const def = self.findFn("main") orelse return;
        if (def.body == null) return;
        if (def.params.len != 0) return;

        const out = self.writer;
        try out.writeAll("// C entry point for the Cell `main`.\n");
        try out.writeAll("int main(void) {\n");
        const ret = if (def.return_type) |rt| try self.lowerType(&rt, .owned) else CType.void_type;
        if (ret.shape == .integer) {
            try out.writeAll("  return (int)cell_main();\n");
        } else {
            try out.writeAll("  cell_main();\n  return 0;\n");
        }
        try out.writeAll("}\n");
    }

    // ── items ───────────────────────────────────────────────────────────

    fn emitStruct(self: *Generator, s: ast.StructDef) EmitError!void {
        const out = self.writer;
        try out.print("typedef struct cell_{s} {{\n", .{s.name});
        for (s.fields) |f| {
            const ty = try self.lowerType(&f.ty, f.ownership);
            try out.writeAll("  ");
            try self.writeDecl(ty, f.name);
            try out.print("; // {s}\n", .{@tagName(f.ownership)});
        }
        try out.print("}} cell_{s};\n\n", .{s.name});
    }

    /// A payload-free Cell enum is a distinct integer type of width int32_t
    /// (cell_rt.h section 6). A bare `typedef enum` has implementation defined
    /// width, so the typedef is explicit and the constants live in an
    /// anonymous enum. They are enum constants rather than `static const`
    /// because an unused `static const` trips -Wunused-const-variable in C.
    fn emitEnum(self: *Generator, e: ast.EnumDef) EmitError!void {
        const out = self.writer;
        try out.print("typedef int32_t cell_{s};\n", .{e.name});
        if (e.variants.len == 0) {
            try out.writeAll("\n");
            return;
        }
        try out.writeAll("enum {\n");
        for (e.variants, 0..) |v, i| {
            try out.print("  cell_{s}_{s} = {d},\n", .{ e.name, v, i });
        }
        try out.writeAll("};\n\n");
    }

    fn emitPrototype(self: *Generator, f: ast.FnDef) EmitError!void {
        if (f.is_public) try self.writer.writeAll("// export\n");
        try self.writeSignature(f);
        try self.writer.writeAll(";\n");
    }

    /// The C symbol a function definition or declaration carries. Mangling is
    /// `cell_<name>`, except that a BODYLESS declaration of a runtime
    /// intrinsic takes the runtime's own spelling: a declaration means "this
    /// symbol comes from elsewhere at link time", and `assert(cond, msg)`
    /// lives there as `cell_assert_msg`. A function with a body is never
    /// renamed, because that would define over a runtime symbol.
    fn symbolFor(self: *Generator, f: ast.FnDef) Alloc![]const u8 {
        if (f.body == null) {
            if (intrinsicSymbol(f.name, f.params.len)) |sym| return sym;
        }
        return try std.fmt.allocPrint(self.arena, "cell_{s}", .{f.name});
    }

    fn emitFn(self: *Generator, f: ast.FnDef) EmitError!void {
        const body = f.body orelse return;
        const out = self.writer;

        self.locals.clearRetainingCapacity();
        self.current_fn = f.name;
        self.current_ret_ty = if (f.return_type) |rt| try self.lowerType(&rt, .owned) else CType.void_type;
        for (f.params) |p| {
            // An `owned` or `arc` parameter is the callee's to release
            // (runtime/cell_rt.h section 7), so it enters the drop pass like
            // a `let`; `pendingDropsSince` still filters on its ownership and
            // on `wasMoved`. R11 row 1, closed 2026-09-16.
            try self.pushLocal(p.name, try self.lowerType(&p.ty, p.ownership), p.ownership, true);
        }

        try self.writeSignature(f);
        try out.writeAll(" {\n");

        // -Wunused-parameter is part of -Wextra, and a Cell body is free to
        // ignore a parameter, so name the unused ones explicitly.
        for (f.params) |p| {
            if (stmtsUse(body, p.name)) continue;
            try out.print("  (void){s};\n", .{p.name});
        }

        // Not `self.emitStmts(body, 1)`: that helper pops every local it
        // sees back off `self.locals` in its own `defer` before returning,
        // which would erase the function's own top-level `let`s before
        // `emitScopeDrops` ever got to look at them. Inlined here so the
        // drop pass runs while they are still visible; `self.locals` is
        // cleared in full below regardless, so no scope actually leaks.
        self.current_after = blockExit(body);
        for (body, 0..) |_, i| {
            try self.emitStmt(&body[i], body[i + 1 ..], 1);
        }
        if (!endsInReturn(body)) try self.emitScopeDrops(1, blockExit(body));
        try out.writeAll("}\n\n");
        self.locals.clearRetainingCapacity();
    }

    fn writeSignature(self: *Generator, f: ast.FnDef) EmitError!void {
        const out = self.writer;
        const ret = if (f.return_type) |rt| try self.lowerType(&rt, .owned) else CType.void_type;
        const symbol = try self.symbolFor(f);
        if (ret.pointer) {
            try out.print("{s}{s}(", .{ ret.text, symbol });
        } else {
            try out.print("{s} {s}(", .{ ret.text, symbol });
        }
        if (f.params.len == 0) {
            // C11: an empty list is an unprototyped declaration, not a
            // zero-argument one.
            try out.writeAll("void)");
            return;
        }
        for (f.params, 0..) |p, i| {
            if (i > 0) try out.writeAll(", ");
            try self.writeDecl(try self.lowerType(&p.ty, p.ownership), p.name);
        }
        try out.writeAll(")");
    }

    fn writeDecl(self: *Generator, ty: CType, name: []const u8) EmitError!void {
        if (ty.pointer) {
            try self.writer.print("{s}{s}", .{ ty.text, name });
        } else {
            try self.writer.print("{s} {s}", .{ ty.text, name });
        }
    }

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
    fn emitStmts(self: *Generator, stmts: []const ast.Stmt, indent: usize) EmitError!void {
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

    fn emitStmt(self: *Generator, stmt: *const ast.Stmt, rest: []const ast.Stmt, indent: usize) EmitError!void {
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
    fn emitAssign(self: *Generator, a: anytype, indent: usize) EmitError!void {
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
    fn fieldStoreReleasesOld(self: *Generator, target: *const ast.Expr, want: CType) bool {
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
    fn reassignedDroppableLocal(self: *Generator, target: *const ast.Expr) ?Local {
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
    fn hasDropCall(shape: Shape) bool {
        return switch (shape) {
            .string, .slice, .arc => true,
            else => false,
        };
    }

    /// R11 row 2. Whether a value of this type is released at scope end. The
    /// three runtime shapes always are; a `record` is when it has drop glue,
    /// which `recordNeedsDrop` decides from its fields.
    fn needsDrop(self: *Generator, ty: CType) Alloc!bool {
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
    fn emitDropGlue(self: *Generator, module: *const ast.Module) EmitError!void {
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
    fn emitResultDropGlue(self: *Generator, module: *const ast.Module) EmitError!void {
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
    fn emitDropFor(self: *Generator, indent: usize, local: Local) EmitError!void {
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
    fn pendingDrops(self: *Generator, exit: ?Exit) Alloc![]const Local {
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
    fn emitScopeDrops(self: *Generator, indent: usize, exit: ?Exit) EmitError!void {
        for (try self.pendingDrops(exit)) |local| try self.emitDropFor(indent, local);
    }

    /// The block-scope drop point: the locals declared since `mark`.
    fn emitDropsSince(self: *Generator, mark: usize, indent: usize, exit: ?Exit) EmitError!void {
        for (try self.pendingDropsSince(mark, exit)) |local| try self.emitDropFor(indent, local);
    }

    /// The `break`/`continue` drop point: everything declared since the
    /// innermost enclosing `while` body opened, which includes the locals of
    /// any block, `if` branch, or arm body the jump sits inside. Outside any
    /// loop there is nothing to do; the parser does not produce a bare
    /// `break`, so the empty case is defensive rather than reachable.
    fn emitLoopExitDrops(self: *Generator, key: Exit, indent: usize) EmitError!void {
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
    fn skipLabelFor(self: *const Generator, break_key: usize) ?usize {
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

    fn emitAfterLoopDrops(self: *Generator, key: usize, indent: usize) EmitError!void {
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
    fn emitReturnStmt(self: *Generator, opt: ?ast.Expr, exit: Exit, indent: usize) EmitError!void {
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

    fn hasUntakenTemps(self: *const Generator, min_depth: usize) bool {
        for (self.owning_temps.items) |t| {
            if (t.loop_depth >= min_depth and !t.taken) return true;
        }
        return false;
    }

    /// Release the untaken temporary owning scrutinees created at loop depth
    /// `min_depth` or deeper, innermost first.
    fn emitTempReleases(self: *Generator, min_depth: usize, indent: usize) EmitError!void {
        var i = self.owning_temps.items.len;
        while (i > 0) {
            i -= 1;
            const t = self.owning_temps.items[i];
            if (t.loop_depth < min_depth or t.taken) continue;
            try self.writeIndent(indent);
            try self.writer.print("cell_drop_{s}(&{s});\n", .{ t.stem, t.name });
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
    fn emitReturnValue(self: *Generator, v: *const ast.Expr, retain: bool, indent: usize) EmitError!void {
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
    fn returnedArcNeedsRetain(self: *Generator, v: *const ast.Expr) Alloc!bool {
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
    fn letType(self: *Generator, ann: ?ast.TypeExpr, value: ?ast.Expr, own: ast.Ownership) Alloc!CType {
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

    fn emitIfStmt(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
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
    fn emitBranchStmt(self: *Generator, e: *const ast.Expr, mark: usize, after: ?Exit, indent: usize) EmitError!void {
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

    fn emitBranchEndDrops(self: *Generator, key: usize, mark: usize, after: ?Exit, indent: usize) EmitError!void {
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

    fn branchNeedsSynthesizedElse(self: *Generator, key: usize, mark: usize, after: ?Exit) EmitError!bool {
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

    fn emitMatchStmt(self: *Generator, m: anytype, indent: usize) EmitError!void {
        try self.emitMatch(m, null, indent);
    }

    /// Lower a `match` to a scrutinee temporary plus an if/else chain. When
    /// `dest` is set every arm assigns into it instead of running for effect.
    fn emitMatch(self: *Generator, m: anytype, dest: ?Dest, indent: usize) EmitError!void {
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
        const tracks_temp = scrut_is_temp and hasOwningGlue(scrut_ty);
        if (tracks_temp) {
            try self.owning_temps.append(self.arena, .{
                .name = temp,
                .stem = glueStem(scrut_ty),
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
            try self.emitArmBody(arm, temp, scrut_ty, dest, indent + 2, outer_mark, scrut_is_temp);
            tested += 1;
        }

        if (tested == 0) {
            // The first arm matches everything, so no test is emitted at all.
            if (default_arm) |arm| {
                try self.emitArmBody(arm, temp, scrut_ty, dest, indent + 1, outer_mark, scrut_is_temp);
            }
        } else {
            try self.writeIndent(indent + 1);
            try out.writeAll("} else {\n");
            if (default_arm) |arm| {
                try self.emitArmBody(arm, temp, scrut_ty, dest, indent + 2, outer_mark, scrut_is_temp);
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

    fn emitArmBody(
        self: *Generator,
        arm: ast.MatchArm,
        temp: []const u8,
        scrut_ty: CType,
        dest: ?Dest,
        indent: usize,
        arm_outer_mark: usize,
        scrut_is_temp: bool,
    ) EmitError!void {
        const mark = self.locals.items.len;
        defer self.locals.shrinkRetainingCapacity(mark);
        const outer_after = self.current_after;
        const took = arm.pattern.kind == .wrap_pattern and
            arm.pattern.kind.wrap_pattern.mode == .owned and
            ((arm.pattern.kind.wrap_pattern.ctor == .ok and resultOkOwning(scrut_ty)) or
                (arm.pattern.kind.wrap_pattern.ctor == .err and resultErrOwning(scrut_ty)) or
                (arm.pattern.kind.wrap_pattern.ctor == .some and isOwningOptional(scrut_ty)));
        if (scrut_is_temp and hasOwningGlue(scrut_ty)) {
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
        if (scrut_is_temp and hasOwningGlue(scrut_ty)) {
            if (!took) {
                try self.writeIndent(indent);
                try self.writer.print("cell_drop_{s}(&{s});\n", .{ glueStem(scrut_ty), temp });
            }
        }
    }

    /// Emit an expression for its effect, in statement position.
    fn emitEffect(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
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
    fn emitDiscarded(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
        try self.writeIndent(indent);
        switch (unwrapAnnotated(e).kind) {
            .call => |c| try self.emitCallValued(c, indent, false),
            else => try self.emitExpr(e, indent),
        }
        try self.writer.writeAll(";\n");
    }

    fn emitPatternTest(self: *Generator, p: ast.Pattern, temp: []const u8, scrut_ty: CType) EmitError!void {
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

    // ── value position ──────────────────────────────────────────────────

    /// `if`, `match`, and `block` in expression position, as a GNU statement
    /// expression. See the module comment for why.
    /// `want` is non-null only when the position being lowered into has a
    /// DECLARED type that inference cannot reproduce, which today is exactly
    /// a `[T]` whose element type is written down. It is deliberately not
    /// passed for every position: routing it everywhere would change the
    /// destination type of every value-position `if`, `match` and block at
    /// once, and the only defect that needs it is the type-erased slice
    /// element. See `CType.elem`.
    fn emitValueExpr(self: *Generator, e: *const ast.Expr, want: ?CType, indent: usize) EmitError!void {
        const out = self.writer;
        var ty = want orelse try self.inferExpr(e);
        if (ty.shape == .unit or ty.shape == .unknown) ty = CType.int64;
        const name = try self.nextTemp();
        const dest: Dest = .{ .name = name, .ty = ty };

        try out.writeAll("({\n");
        try self.writeIndent(indent + 1);
        try self.writeDecl(ty, name);
        try out.print(" = ({s}){{0}};\n", .{ty.text});
        try self.emitValueInto(e, dest, indent + 1);
        try self.writeIndent(indent + 1);
        try out.print("{s};\n", .{name});
        try self.writeIndent(indent);
        try out.writeAll("})");
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
    fn emitValueBlockDrops(self: *Generator, mark: usize, stmts: []const ast.Stmt, tail: *const ast.Expr, dest: Dest, indent: usize) EmitError!void {
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

    /// The names a value block's tail can still reach once its value has
    /// left the braces: every identifier the tail uses, plus, to a fixpoint,
    /// every identifier used by a `let` that declares a reached name or by
    /// an assignment into one, at any nesting depth inside the block. See
    /// `emitValueBlockDrops` for why this is transitive.
    fn tailReach(self: *Generator, stmts: []const ast.Stmt, tail: *const ast.Expr) Alloc!std.ArrayList([]const u8) {
        var set: std.ArrayList([]const u8) = .empty;
        _ = try collectIdents(self.arena, tail, &set);
        while (try reachFromStmts(self.arena, stmts, &set)) {}
        return set;
    }

    /// Emit `e` as statements that leave its value in `dest`.
    ///
    /// The leaf case routes through `emitConversion` rather than writing a
    /// bare assignment, because a value slot is a position with a declared
    /// type and therefore owes the same conversions that a parameter, a
    /// `let`, or a struct field does. Two reachable use-after-frees came in
    /// through here, both silent at `cell check` and clean under
    /// `-Wall -Wextra -Werror`:
    ///
    ///   let arc r = if (c > 0) { a } else { b }   // r aliased a's box
    ///   return match c { 0 => a, _ => a }         // dropped before return
    ///
    /// It routes the WHOLE funnel, not only the `arc` half, and the `str` ->
    /// owning-`String` half is reachable here in a way no list of positions
    /// predicted. `inferExpr` types a `match` from its FIRST arm, so
    ///
    ///   let owned s: String = match c { 0 => make(), _ => "x" }
    ///
    /// gives the slot the C type `cell_string_t` and then writes a
    /// `cell_str_t` literal into it from the second arm. Both that and its
    /// `return` twin passed `cell check` and emitted C that `cc` rejected,
    /// and neither appears in the six-position table the defect was recorded
    /// with. Routing the funnel is what makes them right without adding a
    /// seventh and an eighth row to a list that will be short again.
    ///
    /// What is still NOT applied is the rest of `emitArgLike`. Its
    /// address-of and dereference rules would newly compile cross-branch type
    /// mismatches that are C errors today, and one of them (`&x` on a
    /// branch-local place) would hand out a pointer that dies at the branch's
    /// closing brace. Fixing an aliasing bug is no reason to introduce a
    /// different one.
    fn emitValueInto(self: *Generator, e: *const ast.Expr, dest: Dest, indent: usize) EmitError!void {
        const out = self.writer;
        switch (e.kind) {
            .block => |stmts| {
                try self.writeIndent(indent);
                try out.writeAll("{\n");
                const mark = self.locals.items.len;
                defer self.locals.shrinkRetainingCapacity(mark);
                if (stmts.len > 0) {
                    const saved_after = self.current_after;
                    self.current_after = blockExit(stmts);
                    defer self.current_after = saved_after;
                    for (stmts[0 .. stmts.len - 1], 0..) |_, i| {
                        try self.emitStmt(&stmts[i], stmts[i + 1 ..], indent + 1);
                    }
                    const last = &stmts[stmts.len - 1];
                    switch (last.kind) {
                        .expr => |le| {
                            try self.emitValueInto(&le, dest, indent + 1);
                            try self.emitValueBlockDrops(mark, stmts, &le, dest, indent + 1);
                        },
                        else => {
                            try self.emitStmt(last, &.{}, indent + 1);
                            if (!endsInJump(stmts)) try self.emitDropsSince(mark, indent + 1, blockExit(stmts));
                        },
                    }
                }
                try self.writeIndent(indent);
                try out.writeAll("}\n");
            },
            .if_expr => |i| {
                try self.writeIndent(indent);
                try out.writeAll("if (");
                try self.emitCond(i.cond, indent);
                try out.writeAll(") {\n");
                try self.emitValueInto(i.then_body, dest, indent + 1);
                try self.writeIndent(indent);
                if (i.else_body) |eb| {
                    try out.writeAll("} else {\n");
                    try self.emitValueInto(eb, dest, indent + 1);
                    try self.writeIndent(indent);
                }
                try out.writeAll("}\n");
            },
            .match_expr => |m| try self.emitMatch(m, dest, indent),
            .annotated => |a| try self.emitValueInto(a.value, dest, indent),
            else => {
                try self.writeIndent(indent);
                try out.print("{s} = ", .{dest.name});
                if (unwrapAnnotated(e).kind == .wrap) {
                    try self.emitWrap(unwrapAnnotated(e), dest.ty, indent);
                    try out.writeAll(";\n");
                    return;
                }
                const have = try self.inferExpr(e);
                if (dest.ty.shape == .slice and !dest.ty.pointer and dest.ty.elem != null) {
                    // The other end of `emitArgLike`'s slice routing: the
                    // destination carries the declared element down, and this
                    // is where an arm body's own list literal is emitted.
                    switch (unwrapAnnotated(e).kind) {
                        .list_lit => |items| {
                            try self.emitListLit(items, dest.ty.elem.?.*, indent);
                            try out.writeAll(";\n");
                            return;
                        },
                        else => {},
                    }
                }
                if (!try self.emitConversion(e, dest.ty, have, indent)) {
                    try self.emitExpr(e, indent);
                }
                try out.writeAll(";\n");
            },
        }
    }

    // ── expressions ─────────────────────────────────────────────────────

    /// A binary expression WITHOUT its enclosing parentheses. `emitExpr`
    /// wraps it, which keeps every operand grouped as written; `emitCond`
    /// does not, because the `if (...)`/`while (...)` syntax already groups
    /// it, and `if ((a == 2))` is rejected under `-Werror` by clang's
    /// `-Wparentheses-equality` (it reads as an intended assignment).
    fn emitBinary(self: *Generator, b: anytype, indent: usize) EmitError!void {
        const out = self.writer;
        try self.emitExpr(b.left, indent);
        try out.writeAll(switch (b.op) {
            .add => " + ",
            .sub => " - ",
            .mul => " * ",
            .div => " / ",
            .eq => " == ",
            .ne => " != ",
            .lt => " < ",
            .le => " <= ",
            .gt => " > ",
            .ge => " >= ",
            .and_op => " && ",
            .or_op => " || ",
        });
        try self.emitExpr(b.right, indent);
    }

    /// The expression inside an `if (...)`, `while (...)` or match-guard
    /// `(...)` the caller has already opened. Only the top-level binary loses
    /// its parentheses; its operands are still emitted by `emitExpr`.
    fn emitCond(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
        var c = e;
        while (c.kind == .annotated) c = c.kind.annotated.value;
        switch (c.kind) {
            .binary => |b| try self.emitBinary(b, indent),
            else => try self.emitExpr(e, indent),
        }
    }

    fn emitExpr(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
        const out = self.writer;
        switch (e.kind) {
            .ident => |n| try out.writeAll(n),
            .int => |v| try out.print("{d}", .{v}),
            .float => |v| try self.emitFloat(v),
            .string => |s| try self.emitStringLiteral(s),
            .bool => |b| try out.writeAll(if (b) "true" else "false"),
            .call => |c| try self.emitCall(c, indent),
            .binary => |b| {
                try out.writeAll("(");
                try self.emitBinary(b, indent);
                try out.writeAll(")");
            },
            .unary => |u| try self.emitUnary(u.op, u.operand, indent),
            .field => |f| {
                if (self.enumVariantOf(f.base, f.name)) |enum_name| {
                    try out.print("cell_{s}_{s}", .{ enum_name, f.name });
                    return;
                }
                const base_ty = try self.inferExpr(f.base);
                try self.emitExpr(f.base, indent);
                if (base_ty.pointer) {
                    try out.print("->{s}", .{f.name});
                } else {
                    try out.print(".{s}", .{f.name});
                }
            },
            .index => |ix| try self.emitIndex(ix, indent),
            .struct_lit => |sl| try self.emitStructLit(sl, indent),
            .list_lit => |items| try self.emitListLit(items, null, indent),
            .block, .if_expr, .match_expr => try self.emitValueExpr(e, null, indent),
            .annotated => |a| try self.emitExpr(a.value, indent),
            .wrap => try self.emitWrap(e, null, indent),
        }
    }

    /// `a[i]` for String and lists of scalars. Bounds-checked runtime
    /// helpers return the element's optional; never an unchecked
    /// `xs.ptr[i]`. The list reader is picked from the element C type the
    /// list was BUILT with (`cell_slice_t` is type-erased), and an element
    /// this backend cannot name is spelled as an undeclared function so cc
    /// refuses it instead of reading the wrong stride.
    fn emitIndex(self: *Generator, ix: anytype, indent: usize) EmitError!void {
        const out = self.writer;
        const base_ty = try self.inferExpr(ix.base);
        if (base_ty.shape == .str or base_ty.shape == .string) {
            try out.writeAll("cell_str_byte_at(");
            try self.emitArgLike(ix.base, CType.str, indent);
        } else {
            try out.print("{s}(", .{listReader(base_ty.elem)});
            try self.emitArgLike(ix.base, CType.slice, indent);
        }
        try out.writeAll(", ");
        try self.emitArgLike(ix.index, CType.int64, indent);
        try out.writeAll(")");
    }

    /// `Some(e)`, `None`, `Ok(e)`, `Err(e)`. `want` is the destination's
    /// declared type when the position has one (a `let` with a written
    /// type, a return, a call argument, a field); it decides the optional
    /// instance and the Result payload field. Without it the operand's own
    /// type decides, and `None` cannot be emitted at all, which the checker
    /// already refuses.
    fn emitWrap(self: *Generator, wrap_e: *const ast.Expr, want: ?CType, indent: usize) EmitError!void {
        const out = self.writer;
        const w = wrap_e.kind.wrap;
        switch (w.ctor) {
            .none => {
                const dest = want orelse return error.WriteFailed;
                try out.print("{s}_none()", .{optBase(dest)});
            },
            .some => {
                const operand = w.operand.?;
                const dest: ?CType = if (want) |d| (if (d.shape == .optional) d else null) else null;
                // An owning String payload (sub-project 4): moved when
                // borrowck moved the place, copied when it only read it.
                const inner_op = unwrapAnnotated(operand);
                const moved = if (self.checker) |c| c.wrapMoved(@intFromPtr(operand)) else false;
                const is_place = inner_op.kind == .ident or inner_op.kind == .field;
                const op_ty = if (is_place) try self.inferExpr(inner_op) else CType.unknown;
                const copy_it = is_place and !moved and op_ty.shape == .string;
                if (dest) |d| {
                    try out.print("{s}_some(", .{optBase(d)});
                    if (copy_it and d.payload.?.shape == .string) {
                        try out.writeAll(if (op_ty.pointer) "cell_string_clone(" else "cell_string_clone(&");
                        try self.emitExpr(inner_op, indent);
                        try out.writeAll(")");
                    } else {
                        try self.emitArgLike(operand, d.payload.?.*, indent);
                    }
                    try out.writeAll(")");
                } else {
                    const inner = try self.inferExpr(operand);
                    const base = optBaseForPayload(inner) orelse return error.WriteFailed;
                    try out.print("{s}_some(", .{base});
                    if (copy_it) {
                        try out.writeAll(if (op_ty.pointer) "cell_string_clone(" else "cell_string_clone(&");
                        try self.emitExpr(inner_op, indent);
                        try out.writeAll(")");
                    } else {
                        try self.emitExpr(operand, indent);
                    }
                    try out.writeAll(")");
                }
            },
            .ok, .err => {
                const is_ok = w.ctor == .ok;
                const dest: ?CType = if (want) |d| (if (d.shape == .result) d else null) else null;
                const base = if (dest) |d| resultBase(d) else null;
                if (base == null) {
                    // No declared per-pair destination: cc must refuse it
                    // rather than guess a layout.
                    try out.writeAll(if (is_ok) "cell_res_unknown_ok(" else "cell_res_unknown_err(");
                    try self.emitExpr(w.operand.?, indent);
                    try out.writeAll(")");
                    return;
                }
                const member = if (is_ok) dest.?.payload.?.* else dest.?.err_payload.?.*;
                try out.print("{s}_{s}(", .{ base.?, if (is_ok) "ok" else "err" });
                // An owning payload (2026-09-17). borrowck MOVES a place whose
                // type it resolved (`wrapMoved`), and the header is handed
                // over. An owning place it only read keeps its header, so the
                // Result gets a copy; otherwise both would free one buffer.
                const operand = unwrapAnnotated(w.operand.?);
                const moved = if (self.checker) |c| c.wrapMoved(@intFromPtr(w.operand.?)) else false;
                const is_place = operand.kind == .ident or operand.kind == .field;
                const op_ty = if (is_place) try self.inferExpr(operand) else CType.unknown;
                if (member.shape == .string and is_place and !moved and op_ty.shape == .string) {
                    try out.writeAll(if (op_ty.pointer) "cell_string_clone(" else "cell_string_clone(&");
                    try self.emitExpr(operand, indent);
                    try out.writeAll(")");
                } else {
                    try self.emitArgLike(w.operand.?, member, indent);
                }
                try out.writeAll(")");
            },
        }
    }

    /// `&x` and `&mut x`. Ownership decides the form: a borrow of a primitive
    /// is the value itself, because cell_rt.h section 1 forbids a primitive
    /// from ever becoming a pointer. A shared borrow of an owning string is
    /// the view the ABI asks for.
    fn emitUnary(self: *Generator, op: ast.UnaryOp, operand: *const ast.Expr, indent: usize) EmitError!void {
        const out = self.writer;
        switch (op) {
            .neg => {
                try out.writeAll("-");
                try self.emitExpr(operand, indent);
            },
            .not => {
                try out.writeAll("!");
                try self.emitExpr(operand, indent);
            },
            .ref_shared => {
                const ty = try self.inferExpr(operand);
                if (ty.pointer or ty.shape.isPrimitive()) {
                    try self.emitExpr(operand, indent);
                } else if (ty.shape == .string) {
                    try out.writeAll("cell_string_as_str(&");
                    try self.emitExpr(operand, indent);
                    try out.writeAll(")");
                } else if (ty.shape == .str or ty.shape == .slice or ty.shape == .arc or
                    ty.shape == .optional or ty.shape == .result)
                {
                    // Views and handles are already the borrowed form.
                    try self.emitExpr(operand, indent);
                } else {
                    try out.writeAll("&");
                    try self.emitExpr(operand, indent);
                }
            },
            .ref_exclusive => {
                const ty = try self.inferExpr(operand);
                if (ty.pointer or ty.shape.isPrimitive()) {
                    try self.emitExpr(operand, indent);
                } else {
                    try out.writeAll("&");
                    try self.emitExpr(operand, indent);
                }
            },
        }
    }

    /// A call, with R11's missing release for an UNBOUND `arc` temporary.
    ///
    /// `inspect(shared fresh())` used to emit
    /// `cell_inspect(cell_string_as_str((const cell_string_t *)cell_fresh().ptr))`.
    /// `fresh` returns a reference the caller owns (`cell_rt.h` section 7,
    /// R11 release rule 3), the handle is never bound, and so nothing ever
    /// released it: measured at 2998 leaks / 63968 bytes over 1000
    /// iterations, the largest of R11's disclosed gaps.
    ///
    /// The release cannot go where the conversion goes. `cell_string_as_str`
    /// hands out a view INTO the box's payload, so dropping the handle
    /// inside the argument expression frees the characters the callee is
    /// about to read. The drop has to happen after the enclosing call
    /// returns, which is why the handle is hoisted into a statement
    /// expression wrapped around the WHOLE call rather than fixed inside
    /// `emitArgLike`:
    ///
    ///     ({ cell_arc_t _t0 = cell_fresh();
    ///        int64_t _t1 = cell_inspect(cell_string_as_str(... _t0.ptr));
    ///        cell_arc_drop(_t0);
    ///        _t1; })
    ///
    /// WHY THIS CANNOT OVER-DROP, which is the only direction that matters
    /// here (dropping too little leaks, dropping too much is a double free):
    ///
    ///   1. The temporary holds exactly ONE reference and it is one this
    ///      frame owns. A Cell function that returns `arc` returns it
    ///      already retained, and a C one must too, so the count this drop
    ///      decrements is the one the call handed over.
    ///   2. Nothing can alias it. The expression was never bound to a name,
    ///      never passed to an `arc` parameter (that path is `want.shape ==
    ///      .arc`, which `needsArcTemp` excludes, and it transfers the
    ///      reference instead), and never stored, because a hoist happens
    ///      only for an ARGUMENT of this one call.
    ///   3. The pointee outlives the callee's use of it. The callee received
    ///      a borrow, and R8 forbids a borrow from escaping the call, which
    ///      is the same rule that makes R11's `shared`-parameter non-retain
    ///      safe. The drop is emitted after the call statement, not before.
    ///
    /// WHAT IS DELIBERATELY NOT HOISTED, because each would be a
    /// use-after-free rather than a fix, and the leak is the safe side:
    ///
    ///   - Any position that is not a call argument. `let shared s: String =
    ///     fresh()`, a struct literal field, and a list element all keep the
    ///     unboxed VIEW alive past the statement that produced it, so a drop
    ///     at the end of that statement dangles. `emitArgLike` is shared by
    ///     all of them, which is precisely why the hoist lives here and not
    ///     there. An absence test pins the `let` form.
    ///   - Any argument that is not syntactically a call. An `if`, `match`,
    ///     or block argument reaches `emitValueExpr`, whose temporary starts
    ///     as `{0}` and stays that way when no branch assigns to it, so a
    ///     drop there could run on a null handle. Those forms still leak and
    ///     are recorded as leaking rather than handled untested.
    fn emitCall(self: *Generator, c: anytype, indent: usize) EmitError!void {
        try self.emitCallValued(c, indent, true);
    }

    /// `value_used` is false only from `emitDiscarded`, the two leaves
    /// that emit an expression as a statement. See that function for why
    /// the distinction has to exist.
    fn emitCallValued(self: *Generator, c: anytype, indent: usize, value_used: bool) EmitError!void {
        const out = self.writer;
        const callee = try self.resolveCallee(c.callee, c.args.len);

        // Pre-scan. `temps[i]` is the hoisted handle's C name, or null for
        // an argument that is emitted in place. Only a callee with a
        // declaration has parameter types, so only it can need one.
        var temps: []const ?[]const u8 = &.{};
        var hoisted = false;
        if (callee.def) |def| {
            const scan = try self.arena.alloc(?[]const u8, c.args.len);
            @memset(scan, null);
            for (c.args, 0..) |_, i| {
                if (i >= def.params.len) continue;
                const p = def.params[i];
                const want = try self.lowerType(&p.ty, p.ownership);
                if (!try self.needsArcTemp(&c.args[i], want)) continue;
                scan[i] = try self.nextTemp();
                hoisted = true;
            }
            temps = scan;
        }

        if (!hoisted) return try self.writeCallExpr(c, callee, &.{}, indent);

        const def = callee.def.?;
        const ret = if (def.return_type) |rt| try self.lowerType(&rt, .owned) else CType.void_type;

        try out.writeAll("({\n");
        for (c.args, 0..) |_, i| {
            const name = temps[i] orelse continue;
            try self.writeIndent(indent + 1);
            try out.print("cell_arc_t {s} = ", .{name});
            try self.emitExpr(&c.args[i], indent + 1);
            try out.writeAll(";\n");
        }

        // A void call, and a call whose value is discarded, both leave the
        // statement expression's value as the last drop's, which is also
        // void. Only a value-returning call in a position that USES the
        // value needs a result slot, and it must be filled BEFORE any drop
        // runs. Emitting one where the value is discarded is what tripped
        // -Wunused-value; see `emitDiscarded`.
        const result: ?[]const u8 = if (ret.shape == .unit or !value_used) null else try self.nextTemp();
        try self.writeIndent(indent + 1);
        if (result) |name| {
            try self.writeDecl(ret, name);
            try out.writeAll(" = ");
        }
        try self.writeCallExpr(c, callee, temps, indent + 1);
        try out.writeAll(";\n");

        // Reverse hoist order, matching `pendingDrops`.
        var i = c.args.len;
        while (i > 0) {
            i -= 1;
            const name = temps[i] orelse continue;
            try self.writeIndent(indent + 1);
            try out.print("cell_arc_drop({s});\n", .{name});
        }
        if (result) |name| {
            try self.writeIndent(indent + 1);
            try out.print("{s};\n", .{name});
        }
        try self.writeIndent(indent);
        try out.writeAll("})");
    }

    /// The call itself. `temps` may be empty, in which case this emits what
    /// `emitCall` always emitted, byte for byte; otherwise a non-null entry
    /// replaces that argument's handle with the hoisted temporary's name.
    fn writeCallExpr(
        self: *Generator,
        c: anytype,
        callee: Callee,
        temps: []const ?[]const u8,
        indent: usize,
    ) EmitError!void {
        const out = self.writer;
        if (callee.symbol) |sym| {
            try out.writeAll(sym);
        } else {
            try self.emitExpr(c.callee, indent);
        }
        try out.writeAll("(");
        for (c.args, 0..) |_, i| {
            if (i > 0) try out.writeAll(", ");
            const arg = &c.args[i];
            if (callee.def) |def| {
                if (i < def.params.len) {
                    const p = def.params[i];
                    const want = try self.lowerType(&p.ty, p.ownership);
                    if (i < temps.len) {
                        if (temps[i]) |name| {
                            const emitted = try self.emitUnbox(arg, name, want, indent);
                            // `needsArcTemp` already required `unboxable`.
                            std.debug.assert(emitted);
                            continue;
                        }
                    }
                    try self.emitArgLike(arg, want, indent);
                    continue;
                }
            }
            try self.emitExpr(arg, indent);
        }
        try out.writeAll(")");
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
    fn needsArcTemp(self: *Generator, arg: *const ast.Expr, want: CType) Alloc!bool {
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
    fn emitArcConversion(
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
    fn isMovedOwnedBinding(self: *Generator, arg: *const ast.Expr) bool {
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
    fn emitConversion(
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
    fn emitOwningStringConversion(
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
    fn emitUnbox(
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

    fn writeArcHandle(
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
    fn emitArgLike(self: *Generator, arg: *const ast.Expr, want: CType, indent: usize) EmitError!void {
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

    fn emitStructLit(self: *Generator, sl: anytype, indent: usize) EmitError!void {
        const out = self.writer;
        const ty = try self.namedType(sl.name);
        if (sl.fields.len == 0) {
            try out.print("({s}){{0}}", .{ty.text});
            return;
        }
        const def = self.findStruct(sl.name);
        try out.print("({s}){{ ", .{ty.text});
        for (sl.fields, 0..) |fi, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print(".{s} = ", .{fi.name});
            const want: ?CType = if (def) |d| blk: {
                for (d.fields) |fld| {
                    if (std.mem.eql(u8, fld.name, fi.name)) {
                        break :blk try self.lowerType(&fld.ty, fld.ownership);
                    }
                }
                break :blk null;
            } else null;
            if (want) |w| {
                try self.emitArgLike(&sl.fields[i].value, w, indent);
            } else {
                try self.emitExpr(&sl.fields[i].value, indent);
            }
        }
        try out.writeAll(" }");
    }

    /// `[]` is an empty header. A populated literal needs a heap buffer and a
    /// push per element, which is a statement sequence, so it lowers to the
    /// same statement expression the module comment describes.
    /// A list literal, with the DECLARED element type when the position it
    /// is being lowered into has one.
    ///
    /// `want_elem` null means the element type is inferred from the first
    /// item, which is what this always did and what an un-annotated
    /// `let zs = [1, 2]` still gets. When a declaration IS available it wins,
    /// and the difference is not cosmetic: `cell_slice_t` is type-erased, so
    /// an element type that disagrees with what the consumer reads is
    /// silent. `let owned zs: [String] = [a, a]` with an `arc` `a` built a
    /// buffer of `cell_arc_t` against a declared `cell_string_t`, and a
    /// `shared [String]` callee read a refcount box pointer as a length.
    ///
    /// This does not "fix" that program, it makes it LOUD: with the declared
    /// element in hand, each item is lowered through `emitArgLike` against
    /// `cell_string_t`, `emitArcConversion` declines the arc-to-owned-String
    /// direction (`unboxable` is false for a non-pointer `.string`), and
    /// `cc` rejects the assignment. That is the right answer, because an
    /// element of an `owned [String]` is a make-unique position: R10 refuses
    /// four such positions and this is a fifth one it does not reach.
    fn emitListLit(
        self: *Generator,
        items: []const ast.Expr,
        want_elem: ?CType,
        indent: usize,
    ) EmitError!void {
        const out = self.writer;
        if (items.len == 0) {
            try out.writeAll("cell_slice_empty()");
            return;
        }
        var elem = want_elem orelse try self.inferExpr(&items[0]);
        // The normalization is for the INFERRED path only. A declared type
        // that lowers to `void*` is this backend's deliberate "visible rather
        // than silently wrong", and quietly turning it into an int64 buffer
        // would be the opposite.
        if (want_elem == null and (elem.shape == .unknown or elem.shape == .unit)) elem = CType.int64;
        const list = try self.nextTemp();
        const slot = try self.nextTemp();

        try out.writeAll("({\n");
        try self.writeIndent(indent + 1);
        try out.print("cell_slice_t {s} = cell_slice_alloc(sizeof({s}), {d});\n", .{ list, elem.text, items.len });
        try self.writeIndent(indent + 1);
        try self.writeDecl(elem, slot);
        try out.print(" = ({s}){{0}};\n", .{elem.text});
        for (items, 0..) |_, i| {
            try self.writeIndent(indent + 1);
            try out.print("{s} = ", .{slot});
            try self.emitArgLike(&items[i], elem, indent + 1);
            try out.writeAll(";\n");
            try self.writeIndent(indent + 1);
            try out.print("(void)cell_slice_push(&{s}, sizeof({s}), &{s});\n", .{ list, elem.text, slot });
        }
        try self.writeIndent(indent + 1);
        try out.print("{s};\n", .{list});
        try self.writeIndent(indent);
        try out.writeAll("})");
    }

    /// A float literal always carries a decimal point, so the emitted C is a
    /// double constant rather than an int that happens to convert.
    fn emitFloat(self: *Generator, v: f64) EmitError!void {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0";
        try self.writer.writeAll(text);
        for (text) |ch| {
            if (ch == '.' or ch == 'e' or ch == 'E' or ch == 'n' or ch == 'i') return;
        }
        try self.writer.writeAll(".0");
    }

    /// A Cell string is a length-prefixed view, not a C string (cell_rt.h
    /// section 2). The parser has already decoded SPEC 2.8 escapes, so `s`
    /// is the payload bytes. They are re-escaped here for a C string
    /// literal and the length is the decoded byte count.
    fn emitStringLiteral(self: *Generator, s: []const u8) EmitError!void {
        const out = self.writer;
        try out.writeAll("cell_str_from_parts(\"");
        for (s) |ch| {
            switch (ch) {
                '"' => try out.writeAll("\\\""),
                '\\' => try out.writeAll("\\\\"),
                '\n' => try out.writeAll("\\n"),
                '\r' => try out.writeAll("\\r"),
                '\t' => try out.writeAll("\\t"),
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try out.writeByte(ch),
                else => try out.print("\\{o:0>3}", .{ch}),
            }
        }
        try out.print("\", {d})", .{s.len});
    }

    // ── types ───────────────────────────────────────────────────────────

    /// Lower a Cell type under an ownership mode, per cell_rt.h section 7.
    pub fn lowerType(self: *Generator, ty: *const ast.TypeExpr, own: ast.Ownership) Alloc!CType {
        switch (ty.*) {
            .ref => |r| return try self.lowerType(r.inner, r.ownership),
            else => {},
        }
        const base = try self.baseType(ty);
        return try self.applyOwnership(base, own);
    }

    /// The by-value form of a type, before ownership is applied.
    fn baseType(self: *Generator, ty: *const ast.TypeExpr) Alloc!CType {
        return switch (ty.*) {
            .unit => CType.void_type,
            .name => |n| try self.namedType(n),
            .list => |inner| blk: {
                // R1: an element carries no annotation, so it is `owned`.
                const elem = try self.arena.create(CType);
                elem.* = try self.lowerType(inner, .owned);
                break :blk .{ .text = CType.slice.text, .shape = .slice, .elem = elem };
            },
            .optional => |inner| blk: {
                const inst = try self.optionalInstance(inner);
                const p = try self.arena.create(CType);
                p.* = try self.lowerType(inner, .copy);
                break :blk .{
                    .text = try std.fmt.allocPrint(self.arena, "{s}_t", .{inst.base}),
                    .shape = .optional,
                    .payload = p,
                };
            },
            .result => |r| blk: {
                const ok = try self.arena.create(CType);
                ok.* = try self.lowerType(r.ok, .copy);
                const err = try self.arena.create(CType);
                err.* = try self.lowerType(r.err, .copy);
                const text = if (try self.resultSlug(r.ok, true)) |os|
                    if (try self.resultSlug(r.err, false)) |es|
                        try std.fmt.allocPrint(self.arena, "cell_res_{s}_{s}_t", .{ os, es })
                    else
                        CType.result.text
                else
                    CType.result.text;
                break :blk .{ .text = text, .shape = .result, .payload = ok, .err_payload = err };
            },
            .ref => |r| try self.lowerType(r.inner, r.ownership),
        };
    }

    fn applyOwnership(self: *Generator, base: CType, own: ast.Ownership) Alloc!CType {
        if (base.shape.isPrimitive()) return base;
        return switch (own) {
            .arc => CType.arc,
            .exclusive => try self.pointerTo(base, false),
            .shared => switch (base.shape) {
                .string => CType.str,
                .record, .unknown => try self.pointerTo(base, true),
                else => base,
            },
            .owned, .copy => base,
        };
    }

    fn pointerTo(self: *Generator, base: CType, is_const: bool) Alloc!CType {
        const text = if (is_const)
            try std.fmt.allocPrint(self.arena, "const {s} *", .{base.text})
        else
            try std.fmt.allocPrint(self.arena, "{s} *", .{base.text});
        const pointee = try self.arena.create(CType);
        pointee.* = base;
        return .{
            .text = text,
            .shape = base.shape,
            .pointer = true,
            .name = base.name,
            .elem = base.elem,
            .pointee = pointee,
            .payload = base.payload,
            .err_payload = base.err_payload,
        };
    }

    fn namedType(self: *Generator, n: []const u8) Alloc!CType {
        if (eq(n, "Int") or eq(n, "Int64")) return CType.int64;
        if (eq(n, "Int8")) return .{ .text = "int8_t", .shape = .integer };
        if (eq(n, "Int16")) return .{ .text = "int16_t", .shape = .integer };
        if (eq(n, "Int32")) return .{ .text = "int32_t", .shape = .integer };
        if (eq(n, "UInt") or eq(n, "UInt64")) return .{ .text = "uint64_t", .shape = .integer };
        if (eq(n, "UInt8")) return .{ .text = "uint8_t", .shape = .integer };
        if (eq(n, "UInt16")) return .{ .text = "uint16_t", .shape = .integer };
        if (eq(n, "UInt32")) return .{ .text = "uint32_t", .shape = .integer };
        if (eq(n, "Float") or eq(n, "Float64")) return CType.float64;
        if (eq(n, "Float32")) return .{ .text = "float", .shape = .floating };
        if (eq(n, "Bool")) return CType.boolean;
        if (eq(n, "Byte")) return .{ .text = "uint8_t", .shape = .byte };
        if (eq(n, "String")) return CType.string;
        if (eq(n, "Unit")) return CType.void_type;

        if (self.findStruct(n) != null) {
            return .{
                .text = try std.fmt.allocPrint(self.arena, "cell_{s}", .{n}),
                .shape = .record,
                .name = n,
            };
        }
        if (self.findEnum(n) != null) {
            return .{
                .text = try std.fmt.allocPrint(self.arena, "cell_{s}", .{n}),
                .shape = .enumeration,
                .name = n,
            };
        }
        return CType.unknown;
    }

    /// A Result side's slug: a scalar name, a payload-free enum (`i32`), or
    /// unit on the Ok side. Null for anything cell_rt.h does not define.
    fn resultSlug(self: *Generator, ty: *const ast.TypeExpr, is_ok: bool) Alloc!?[]const u8 {
        switch (ty.*) {
            .unit => return if (is_ok) "unit" else null,
            .name => |n| {
                if (scalarSlug(n)) |s| return s;
                // An owning String payload, on either side (sub-projects 2
                // and 3, 2026-09-17).
                if (eq(n, "String")) return "string";
                const base = try self.namedType(n);
                if (base.shape == .enumeration) return "i32";
                return null;
            },
            .ref => |r| return try self.resultSlug(r.inner, is_ok),
            else => return null,
        }
    }

    /// Which `CELL_DEFINE_OPTIONAL` instance covers `T?`. cell_rt.h predefines
    /// the scalar instances; anything else is instantiated at the top of the
    /// module. `UInt8?` is `cell_opt_u8`, not `cell_opt_byte`.
    fn optionalInstance(self: *Generator, inner: *const ast.TypeExpr) Alloc!OptionalInst {
        switch (inner.*) {
            .name => |n| {
                if (eq(n, "Int") or eq(n, "Int64")) return .{ .base = "cell_opt_i64", .elem = "int64_t", .generated = false };
                if (eq(n, "Int8")) return .{ .base = "cell_opt_i8", .elem = "int8_t", .generated = false };
                if (eq(n, "Int16")) return .{ .base = "cell_opt_i16", .elem = "int16_t", .generated = false };
                if (eq(n, "Int32")) return .{ .base = "cell_opt_i32", .elem = "int32_t", .generated = false };
                if (eq(n, "UInt") or eq(n, "UInt64")) return .{ .base = "cell_opt_u64", .elem = "uint64_t", .generated = false };
                if (eq(n, "UInt8")) return .{ .base = "cell_opt_u8", .elem = "uint8_t", .generated = false };
                if (eq(n, "UInt16")) return .{ .base = "cell_opt_u16", .elem = "uint16_t", .generated = false };
                if (eq(n, "UInt32")) return .{ .base = "cell_opt_u32", .elem = "uint32_t", .generated = false };
                if (eq(n, "Float") or eq(n, "Float64")) return .{ .base = "cell_opt_f64", .elem = "double", .generated = false };
                if (eq(n, "Bool")) return .{ .base = "cell_opt_bool", .elem = "bool", .generated = false };
                if (eq(n, "Byte")) return .{ .base = "cell_opt_byte", .elem = "uint8_t", .generated = false };
                // An owning String? (sub-project 4, 2026-09-17); the view
                // optional `cell_opt_str` stays in the header for hosts.
                if (eq(n, "String")) return .{ .base = "cell_opt_string", .elem = "cell_string_t", .generated = false };
                const base = try self.namedType(n);
                if (base.shape == .unknown) return .{ .base = "cell_opt_ptr", .elem = "void *", .generated = false };
                return .{
                    .base = try std.fmt.allocPrint(self.arena, "cell_opt_{s}", .{n}),
                    .elem = base.text,
                    .generated = true,
                };
            },
            .list => return .{ .base = "cell_opt_list", .elem = "cell_slice_t", .generated = true },
            else => return .{ .base = "cell_opt_ptr", .elem = "void *", .generated = false },
        }
    }

    // ── local type inference ────────────────────────────────────────────

    fn inferExpr(self: *Generator, e: *const ast.Expr) Alloc!CType {
        switch (e.kind) {
            .ident => |n| return self.lookupLocal(n) orelse CType.unknown,
            .int => return CType.int64,
            .float => return CType.float64,
            .bool => return CType.boolean,
            .string => return CType.str,
            .binary => |b| switch (b.op) {
                .eq, .ne, .lt, .le, .gt, .ge, .and_op, .or_op => return CType.boolean,
                else => {
                    const left = try self.inferExpr(b.left);
                    if (left.shape != .unknown) return left;
                    return try self.inferExpr(b.right);
                },
            },
            .unary => |u| switch (u.op) {
                .not => return CType.boolean,
                .neg => return try self.inferExpr(u.operand),
                .ref_shared => {
                    const inner = try self.inferExpr(u.operand);
                    if (inner.pointer or inner.shape.isPrimitive()) return inner;
                    if (inner.shape == .string) return CType.str;
                    if (inner.shape == .record or inner.shape == .unknown) return try self.pointerTo(inner, true);
                    return inner;
                },
                .ref_exclusive => {
                    const inner = try self.inferExpr(u.operand);
                    if (inner.pointer or inner.shape.isPrimitive()) return inner;
                    return try self.pointerTo(inner, false);
                },
            },
            .call => |c| {
                const callee = try self.resolveCallee(c.callee, c.args.len);
                if (callee.def) |def| {
                    if (def.return_type) |rt| return try self.lowerType(&rt, .owned);
                    return CType.void_type;
                }
                if (callee.symbol) |sym| {
                    if (eq(sym, "cell_print") or eq(sym, "cell_println") or
                        eq(sym, "cell_assert") or eq(sym, "cell_assert_msg") or
                        eq(sym, "cell_panic")) return CType.void_type;
                }
                return CType.unknown;
            },
            .field => |f| {
                if (self.enumVariantOf(f.base, f.name)) |enum_name| {
                    return try self.namedType(enum_name);
                }
                const base = try self.inferExpr(f.base);
                if (base.shape != .record) return CType.unknown;
                const def = self.findStruct(base.name) orelse return CType.unknown;
                for (def.fields) |fld| {
                    if (eq(fld.name, f.name)) return try self.lowerType(&fld.ty, fld.ownership);
                }
                return CType.unknown;
            },
            .index => |ix| {
                const base = try self.inferExpr(ix.base);
                const p = try self.arena.create(CType);
                if (base.shape == .str or base.shape == .string) {
                    p.* = .{ .text = "uint8_t", .shape = .byte };
                    return .{ .text = "cell_opt_byte_t", .shape = .optional, .payload = p };
                }
                const elem = base.elem orelse return CType.unknown;
                const opt = listOptional(elem.text) orelse return CType.unknown;
                p.* = elem.*;
                return .{ .text = opt, .shape = .optional, .payload = p };
            },
            .struct_lit => |sl| return try self.namedType(sl.name),
            .list_lit => |items| {
                // Carry the element the literal will be BUILT with, by the
                // same rule `emitListLit` applies, so an inferred `let` can
                // be indexed with the right stride.
                if (items.len == 0) return CType.slice;
                var elem = try self.inferExpr(&items[0]);
                if (elem.shape == .unknown or elem.shape == .unit) elem = CType.int64;
                const p = try self.arena.create(CType);
                p.* = elem;
                return .{ .text = CType.slice.text, .shape = .slice, .elem = p };
            },
            .block => |stmts| {
                if (stmts.len == 0) return CType.void_type;
                // The tail may name a `let` the block itself declares, and
                // inference runs BEFORE the block is emitted, so those names
                // are not in `self.locals` yet: `let arc r = { let arc a =
                // "x" \n a }` inferred `a` as unknown, fell to int64, and
                // emitted an `int64_t r` that cc refused (found 2026-09-15).
                // Scratch locals make them visible for the duration of this
                // inference only; see `pushScratchLocal` for why they must
                // not go through `pushLocal`.
                const mark = self.locals.items.len;
                defer self.locals.shrinkRetainingCapacity(mark);
                for (stmts[0 .. stmts.len - 1]) |s| {
                    switch (s.kind) {
                        .let => |l| try self.pushScratchLocal(l.name, try self.letType(l.ty, l.value, l.ownership), l.ownership),
                        else => {},
                    }
                }
                const last = stmts[stmts.len - 1];
                return switch (last.kind) {
                    .expr => |le| try self.inferExpr(&le),
                    else => CType.void_type,
                };
            },
            .if_expr => |i| return try self.inferExpr(i.then_body),
            .match_expr => |m| {
                if (m.arms.len == 0) return CType.void_type;
                // A binding pattern names the scrutinee inside the arm, and
                // `emitArmBody` declares it with the SCRUTINEE's type. This
                // inference has to agree or the two disagree silently:
                // `match s { x => x }` inferred `unknown` from `x` (no local
                // of that name exists here), `emitValueExpr` fell back to
                // `CType.int64`, and `cc` then rejected the whole module with
                // `assigning to 'int64_t' from incompatible type
                // 'cell_string_t'` -- `cell check` accepting a program the
                // backend cannot compile, the same class as the struct
                // typedef-order gap. Measured on `let shared c = match s { x
                // => x }` over an owned `String`; it reached `shared` and
                // `copy` alike, so it was never only an ownership-rule gap.
                // `.owned` and the scratch push mirror `emitArmBody`, whose
                // comment explains why this binding is never droppable.
                const mark = self.locals.items.len;
                defer self.locals.shrinkRetainingCapacity(mark);
                if (m.arms[0].pattern.kind == .binding) {
                    try self.pushScratchLocal(
                        m.arms[0].pattern.kind.binding,
                        try self.inferExpr(m.scrutinee),
                        .owned,
                    );
                } else if (m.arms[0].pattern.kind == .wrap_pattern) {
                    const wp = m.arms[0].pattern.kind.wrap_pattern;
                    if (wp.binding) |name| {
                        const scrut = try self.inferExpr(m.scrutinee);
                        const payload: CType = switch (wp.ctor) {
                            .some, .ok => if (scrut.payload) |p| p.* else CType.unknown,
                            .err => if (scrut.err_payload) |p| p.* else CType.unknown,
                            .none => CType.unknown,
                        };
                        try self.pushScratchLocal(name, payload, .copy);
                    }
                }
                return try self.inferExpr(m.arms[0].body);
            },
            .annotated => |a| return try self.inferExpr(a.value),
            .wrap => |w| switch (w.ctor) {
                .some => {
                    const inner = try self.inferExpr(w.operand.?);
                    const p = try self.arena.create(CType);
                    p.* = inner;
                    const base = optBaseForPayload(inner) orelse return CType.unknown;
                    return .{ .text = try std.fmt.allocPrint(self.arena, "{s}_t", .{base}), .shape = .optional, .payload = p };
                },
                .none => return CType.unknown,
                .ok, .err => return CType.result,
            },
        }
    }

    /// Resolve a callee to its mangled C symbol. Every Cell function is
    /// `cell_<name>`, which is also how the runtime spells its intrinsics, so
    /// `print` lands on `cell_print` with no special case. `assert` is the one
    /// exception: C has no overloading, so the two-argument form goes to
    /// `cell_assert_msg`.
    fn resolveCallee(self: *Generator, callee: *const ast.Expr, argc: usize) Alloc!Callee {
        switch (callee.kind) {
            .ident => |n| {
                if (self.findFn(n)) |def| {
                    return .{ .symbol = try self.symbolFor(def), .def = def };
                }
                // Nothing declares it here, so it is either a runtime
                // intrinsic or an external symbol under the usual mangling.
                if (intrinsicSymbol(n, argc)) |sym| return .{ .symbol = sym, .def = null };
                return .{
                    .symbol = try std.fmt.allocPrint(self.arena, "cell_{s}", .{n}),
                    .def = null,
                };
            },
            .field => {
                // There is no module resolution, so a dotted callee is mangled
                // by joining its segments: `io.print` is `cell_io_print`,
                // which fails at link time rather than emitting invalid C.
                var parts: std.ArrayList([]const u8) = .empty;
                var cursor = callee;
                while (cursor.kind == .field) {
                    try parts.append(self.arena, cursor.kind.field.name);
                    cursor = cursor.kind.field.base;
                }
                if (cursor.kind != .ident) return .{ .symbol = null, .def = null };
                var name: []const u8 = try std.fmt.allocPrint(self.arena, "cell_{s}", .{cursor.kind.ident});
                var i = parts.items.len;
                while (i > 0) {
                    i -= 1;
                    name = try std.fmt.allocPrint(self.arena, "{s}_{s}", .{ name, parts.items[i] });
                }
                return .{ .symbol = name, .def = null };
            },
            else => return .{ .symbol = null, .def = null },
        }
    }

    // ── lookup and scratch ──────────────────────────────────────────────

    fn findFn(self: *Generator, name: []const u8) ?ast.FnDef {
        for (self.module.items) |item| {
            switch (item.kind) {
                .fn_def => |f| if (eq(f.name, name)) return f,
                else => {},
            }
        }
        return null;
    }

    fn findStruct(self: *Generator, name: []const u8) ?ast.StructDef {
        for (self.module.items) |item| {
            switch (item.kind) {
                .struct_def => |s| if (eq(s.name, name)) return s,
                else => {},
            }
        }
        return null;
    }

    fn findEnum(self: *Generator, name: []const u8) ?ast.EnumDef {
        for (self.module.items) |item| {
            switch (item.kind) {
                .enum_def => |e| if (eq(e.name, name)) return e,
                else => {},
            }
        }
        return null;
    }

    /// `Color.Red` parses as a field selection on the identifier `Color`.
    /// When that identifier is shadowed by no local and names a declared enum
    /// that has this variant, the whole expression is the enum constant.
    fn enumVariantOf(self: *Generator, base: *const ast.Expr, field: []const u8) ?[]const u8 {
        if (base.kind != .ident) return null;
        const name = base.kind.ident;
        if (self.lookupLocal(name) != null) return null;
        const def = self.findEnum(name) orelse return null;
        for (def.variants) |v| {
            if (eq(v, field)) return def.name;
        }
        return null;
    }

    /// An INFERENCE-ONLY local: visible to `lookupLocal` while an enclosing
    /// `inferExpr` runs, and gone (shrunk back by that caller's `defer`)
    /// before any emission. It deliberately bypasses `pushLocal`, because
    /// `pushLocal` advances `next_binding_id`, which must move only at the
    /// three points that mirror borrowck's `declare` (module doc comment);
    /// advancing it during inference would drift every later binding's id,
    /// and `pendingDrops` would then be asking `wasMoved` about the wrong
    /// place. `droppable` is false so that even if one of these outlived its
    /// inference, no drop could be spelled for it.
    fn pushScratchLocal(self: *Generator, name: []const u8, ty: CType, ownership: ast.Ownership) Alloc!void {
        try self.locals.append(self.arena, .{
            .name = name,
            .ty = ty,
            .ownership = ownership,
            .id = 0,
            .droppable = false,
        });
    }

    fn lookupLocal(self: *Generator, name: []const u8) ?CType {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (eq(self.locals.items[i].name, name)) return self.locals.items[i].ty;
        }
        return null;
    }

    /// `droppable` is true from the `let`/`var` and parameter call sites; see
    /// `Local.droppable`. Assigns the next id from `next_binding_id`,
    /// which must be incremented here and only here, at exactly the three
    /// call sites that mirror borrowck's own `declare` (see the module doc
    /// comment).
    fn pushLocal(
        self: *Generator,
        name: []const u8,
        ty: CType,
        ownership: ast.Ownership,
        droppable: bool,
    ) Alloc!void {
        const id = self.next_binding_id;
        self.next_binding_id += 1;

        // Confirm this id still names this binding on borrowck's side, and
        // let the ANSWER decide whether this local may be dropped at all.
        //
        // An assert alone was not enough, for three reasons. It is compiled
        // out entirely in ReleaseFast and ReleaseSmall (it survives Debug
        // and ReleaseSafe, so tests do catch drift). The earlier
        // `if (bindingName(id)) |declared|` form skipped the check in
        // SILENCE whenever the lookup returned null, which is exactly what
        // drift PAST borrowck's highest id produces. And an assert only
        // DETECTS: `pendingDrops` went on to trust `wasMoved(id)` either
        // way. A `wasMoved` answer about the wrong binding is the one
        // failure this design cannot absorb -- "not moved" about some other
        // place frees a place that really was moved, the double free the
        // whole conservative approach exists to prevent.
        //
        // So require POSITIVE confirmation, in every build mode. Without it
        // we do not know whether this binding was moved, and the module doc
        // comment's asymmetry dictates the answer: not dropping a live
        // place leaks, dropping a moved one corrupts. Choose the leak.
        //
        // Residual, stated rather than hidden: drift that lands on a
        // DIFFERENT binding sharing this name still passes, which shadowing
        // makes possible. That is strictly narrower than the hole it
        // replaces, not a closed door.
        var may_drop = droppable;
        if (droppable) {
            const declared = if (self.checker) |c| c.bindingName(id) else null;
            if (declared) |d| {
                const agrees = eq(d, name);
                std.debug.assert(agrees); // loud in Debug and ReleaseSafe
                if (!agrees) may_drop = false; // safe in ReleaseFast/Small
            } else {
                may_drop = false;
            }
        }
        try self.locals.append(self.arena, .{
            .name = name,
            .ty = ty,
            .ownership = ownership,
            .id = id,
            .droppable = may_drop,
        });
    }

    fn nextTemp(self: *Generator) Alloc![]const u8 {
        const name = try std.fmt.allocPrint(self.arena, "_cell_t{d}", .{self.temp_counter});
        self.temp_counter += 1;
        return name;
    }

    fn writeIndent(self: *Generator, n: usize) EmitError!void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.writer.writeAll("  ");
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Runtime intrinsics whose C symbol is not `cell_<name>` for every arity.
/// `print`, `println`, and `panic` already land on their runtime names under
/// the normal mangling; `assert` does not, because C has no overloading and
/// the message-carrying form is a separate symbol.
fn intrinsicSymbol(name: []const u8, arity: usize) ?[]const u8 {
    if (eq(name, "assert")) return if (arity == 2) "cell_assert_msg" else "cell_assert";
    return null;
}

/// A pattern that matches everything, so it closes an if/else chain.
/// Whether an arm closes the chain. A pattern that matches everything only
/// does so when no guard can reject it.
/// Whether `emitMatch` will read its scrutinee temporary: some arm it
/// reaches (every arm up to and including the first unguarded default) is a
/// pattern test or a binding copy.
fn scrutineeTempRead(arms: []const ast.MatchArm) bool {
    for (arms) |arm| {
        if (arm.pattern.kind == .binding) return true;
        if (!isDefaultPattern(arm.pattern)) return true;
        if (isDefaultArm(arm)) return false;
    }
    return false;
}

fn isDefaultArm(arm: ast.MatchArm) bool {
    return arm.guard == null and isDefaultPattern(arm.pattern);
}

fn isDefaultPattern(p: ast.Pattern) bool {
    return switch (p.kind) {
        .wildcard, .binding => true,
        else => false,
    };
}

/// An addressable expression, the only kind `&` may be applied to.
/// Strip every `.annotated` wrapper. A written ownership prefix is kept on
/// the AST as one of these (see the module doc comment's rule 3), so
/// `observe(arc label)` reaches here as a wrapper around the identifier.
/// `cell_opt_i64_t` -> `cell_opt_i64`, the constructor prefix.
fn optBase(ty: CType) []const u8 {
    std.debug.assert(ty.shape == .optional);
    return ty.text[0 .. ty.text.len - "_t".len];
}

/// The predefined `cell_opt_*` instance for a scalar C type, by spelling.
fn optBaseForPayload(t: CType) ?[]const u8 {
    const map = .{
        .{ "int64_t", "cell_opt_i64" },   .{ "uint64_t", "cell_opt_u64" },
        .{ "int8_t", "cell_opt_i8" },     .{ "int16_t", "cell_opt_i16" },
        .{ "int32_t", "cell_opt_i32" },   .{ "uint16_t", "cell_opt_u16" },
        .{ "uint32_t", "cell_opt_u32" },  .{ "double", "cell_opt_f64" },
        .{ "bool", "cell_opt_bool" },     .{ "uint8_t", "cell_opt_byte" },
        .{ "float", "cell_opt_Float32" },     .{ "cell_string_t", "cell_opt_string" },
    };
    inline for (map) |row| if (std.mem.eql(u8, t.text, row[0])) return row[1];
    return null;
}

fn unwrapAnnotated(e: *const ast.Expr) *const ast.Expr {
    var current = e;
    while (true) {
        switch (current.kind) {
            .annotated => |a| current = a.value,
            else => return current,
        }
    }
}

fn isPlace(e: *const ast.Expr) bool {
    return switch (e.kind) {
        .ident, .field => true,
        .annotated => |a| isPlace(a.value),
        else => false,
    };
}

/// The borrow sigil at the head of an expression, ignoring any written
/// ownership prefix wrapped around it. `&buf`, `&mut buf`, `&var buf` and
/// `&exclusive buf` all answer here, and so does `exclusive &buf`, because a
/// written prefix is an `.annotated` wrapper (see the module doc comment's
/// rule 3).
///
/// The OPERAND is what this returns, not the sigil's own kind. Which mode the
/// resulting binding is in is the `let`'s declared annotation and not the
/// sigil: `examples/borrows.cell` states the rule for the argument position as
/// "the KEYWORD WINS", and `emitArgLike` already emits `&buf` for both
/// `grow(exclusive &buf)` and `grow(exclusive buf)`. `letType` applies the
/// same rule to a binding.
///
/// Deliberately a private twin of `borrowck.refKind` rather than a call into
/// it. That one is file-private and returns the sigil's kind, which this side
/// does not use; keeping a two-line copy here is cheaper than widening
/// borrowck's surface for a caller that wants less than it offers.
fn borrowOperand(e: *const ast.Expr) ?*const ast.Expr {
    return switch (e.kind) {
        .annotated => |a| borrowOperand(a.value),
        .unary => |u| switch (u.op) {
            .ref_shared, .ref_exclusive => u.operand,
            else => null,
        },
        else => null,
    };
}

/// Whether a `let` with this initializer and this declared ownership is a
/// binding that REFERS to an existing place, rather than one holding a value
/// of its own.
///
/// A MIRROR OF `borrowck.checkLetInit`, clause for clause and in its order,
/// the way `llvmemit.borrowedByPointer` mirrors `codegen.applyOwnership` row
/// for row. That function is the language's definition of a named loan, and
/// the two must not drift: when it says a `let` creates a loan, the C backend
/// must spell that binding as a reference to the lender, and when it does not,
/// the binding is a value. The five miscompiles `letType` documents were all
/// this predicate being absent, so codegen answered the question from the
/// initializer's spelling and disagreed with the checker about what the
/// program meant.
///
///     checkLetInit clause 1   refKind(v) over a place -> named loan
///     checkLetInit clause 2   `shared`/`exclusive` over a place -> named loan
///     everything after        an ordinary expression, no named loan
///
/// borrowck exposes no query for "is binding N a loan holder", so this is a
/// mirror rather than an assertion against the real answer. If one is ever
/// added, `pushLocal` is where the two should be cross-checked, beside the
/// binding-id agreement it already asserts there.
///
/// Total by construction: two recognised shapes and a catch-all, and the
/// catch-all is the by-value answer. An initializer form nobody enumerated
/// cannot become a reference by accident, only a copy, which is the safe
/// direction here.
fn isNamedLoan(v: *const ast.Expr, own: ast.Ownership) bool {
    if (borrowOperand(v)) |operand| return isPlace(operand);
    if (own == .shared or own == .exclusive) return isPlace(v);
    return false;
}

/// True when `emitUnbox` has a spelling for `want`, which is exactly the
/// three conditions it tests, in the order it tests them. Kept as one
/// predicate because two callers need the answer: `emitUnbox` itself, and
/// `emitCall`'s pre-scan, which must not hoist an argument the emitter would
/// then decline to unbox (the hoisted temporary would be declared, dropped,
/// and never read, and the argument would fall through to a C type error
/// with a `cell_arc_drop` of a live handle beside it).
fn unboxable(want: CType) bool {
    return want.shape == .str or (want.shape == .slice and !want.pointer) or want.pointer;
}

/// True when a function body's LAST top-level statement is a `return`, so
/// the end-of-body drop point `emitFn` would reach afterward is unreachable
/// C. `emitReturnStmt` has already emitted every drop that return owes, so
/// what `emitScopeDrops` writes there is a byte-identical duplicate that no
/// execution can reach.
///
/// This decides where a drop is WRITTEN, never whether one is owed, so it
/// cannot over-drop in either direction: deleting statements after a
/// `return` removes code the program never runs, and the drops before the
/// `return` are untouched. Removing them would be the dangerous direction
/// and this does not do that.
///
/// It is deliberately the narrowest test that is exactly right rather than
/// the widest one that is arguably right. A body ending in an `if` whose
/// branches all `return`, or in a `while (true)` with no `break`, also
/// terminates, and both are left alone: each needs a derivation over the
/// FORMS of a construct, and this file's history is that such derivations
/// enumerate some forms and assert a property of all of them. A
/// `.return_stmt` needs no derivation. The cost of the narrow test is a dead
/// `cell_arc_drop` in the shapes it declines, which is what was already
/// emitted, so nothing regresses.
fn endsInReturn(body: []const ast.Stmt) bool {
    if (body.len == 0) return false;
    return switch (body[body.len - 1].kind) {
        .return_stmt => true,
        else => false,
    };
}

/// The per-instantiation Result slug for a Cell scalar type name (cell_rt.h
/// ABI 2). Mirrors abi.resultMember; the parity test pins the two.
fn scalarSlug(n: []const u8) ?[]const u8 {
    if (eq(n, "Int") or eq(n, "Int64")) return "i64";
    if (eq(n, "Int8")) return "i8";
    if (eq(n, "Int16")) return "i16";
    if (eq(n, "Int32")) return "i32";
    if (eq(n, "UInt") or eq(n, "UInt64")) return "u64";
    if (eq(n, "UInt8")) return "u8";
    if (eq(n, "UInt16")) return "u16";
    if (eq(n, "UInt32")) return "u32";
    if (eq(n, "Float") or eq(n, "Float64")) return "f64";
    if (eq(n, "Float32")) return "f32";
    if (eq(n, "Bool")) return "bool";
    if (eq(n, "Byte")) return "byte";
    return null;
}

/// `cell_res_i64_i32` for `cell_res_i64_i32_t`; null for the legacy
/// pass-through spelling, which has no per-pair constructors.
fn resultBase(t: CType) ?[]const u8 {
    if (!std.mem.startsWith(u8, t.text, "cell_res_")) return null;
    return t.text[0 .. t.text.len - 2];
}

/// An owning String? (sub-project 4, 2026-09-17).
fn isOwningOptional(t: CType) bool {
    return t.shape == .optional and std.mem.eql(u8, t.text, "cell_opt_string_t");
}

/// Whether a value of this aggregate type owns heap memory and is released
/// through per-module glue (`cell_drop_<stem>`).
fn hasOwningGlue(t: CType) bool {
    return isOwningResult(t) or isOwningOptional(t);
}

/// `res_i64_string` for `cell_res_i64_string_t`, `opt_string` for
/// `cell_opt_string_t`: the part after `cell_drop_`.
fn glueStem(t: CType) []const u8 {
    return t.text["cell_".len .. t.text.len - "_t".len];
}

/// A Result with an owning String side (sub-projects 2 and 3, 2026-09-17):
/// it owns heap memory and has per-module release glue.
fn isOwningResult(t: CType) bool {
    return resultOkOwning(t) or resultErrOwning(t);
}

fn resultOkOwning(t: CType) bool {
    return t.shape == .result and std.mem.startsWith(u8, t.text, "cell_res_string_");
}

fn resultErrOwning(t: CType) bool {
    return t.shape == .result and std.mem.startsWith(u8, t.text, "cell_res_") and
        std.mem.endsWith(u8, t.text, "_string_t");
}

/// The bounds-checked runtime reader for a list built with `elem`.
fn listReader(elem: ?*const CType) []const u8 {
    const e = elem orelse return "cell_index_of_unknown_element";
    if (eq(e.text, "uint8_t")) return "cell_bytes_at";
    if (eq(e.text, "int64_t")) return "cell_list_i64_at";
    if (eq(e.text, "int32_t")) return "cell_list_i32_at";
    if (eq(e.text, "double")) return "cell_list_f64_at";
    if (eq(e.text, "bool")) return "cell_list_bool_at";
    return "cell_index_of_unsupported_element";
}

/// The optional C type `listReader` returns for `elem_text`.
fn listOptional(elem_text: []const u8) ?[]const u8 {
    if (eq(elem_text, "uint8_t")) return "cell_opt_byte_t";
    if (eq(elem_text, "int64_t")) return "cell_opt_i64_t";
    if (eq(elem_text, "int32_t")) return "cell_opt_i32_t";
    if (eq(elem_text, "double")) return "cell_opt_f64_t";
    if (eq(elem_text, "bool")) return "cell_opt_bool_t";
    return null;
}

/// True when the block's last statement leaves it by a jump that has
/// already emitted the block's drops (`return` via `pendingDrops`, `break`
/// and `continue` via `emitLoopExitDrops`), so `emitStmts` must not emit
/// them a second time after unreachable code.
/// Whether a match arm body always leaves (`return`/`break`/`continue` as
/// its last statement), so its end is unreachable.
fn armDiverges(e: *const ast.Expr) bool {
    const inner = unwrapAnnotated(e);
    return switch (inner.kind) {
        .block => |stmts| endsInJump(stmts),
        else => false,
    };
}

fn endsInJump(body: []const ast.Stmt) bool {
    if (body.len == 0) return false;
    return switch (body[body.len - 1].kind) {
        .return_stmt, .break_stmt, .continue_stmt => true,
        else => false,
    };
}

/// A drop point, spelled the way borrowck keyed it in `exit_liveness`.
const Exit = struct {
    kind: borrowck.ExitKind,
    key: usize,
};

const OwningTemp = struct {
    name: []const u8,
    stem: []const u8,
    loop_depth: usize,
    taken: bool = false,
};

const SkipLabel = struct {
    loop_key: usize,
    id: usize,
};

/// The fall-through end of `body`. Null for an empty block, which borrowck
/// does not record and which declares nothing to drop.
fn blockExit(body: []const ast.Stmt) ?Exit {
    if (body.len == 0) return null;
    return .{ .kind = .block_end, .key = @intFromPtr(body.ptr) };
}

/// Mirrors `borrowck.branchKeyOf`: a block body's statement slice, else
/// the expression itself.
fn branchKey(e: *const ast.Expr) usize {
    return switch (e.kind) {
        .block => |stmts| if (stmts.len > 0) @intFromPtr(stmts.ptr) else @intFromPtr(e),
        else => @intFromPtr(e),
    };
}

// ── use analysis, for the (void) casts that keep -Wextra quiet ───────────

fn exprUses(e: *const ast.Expr, name: []const u8) bool {
    return switch (e.kind) {
        .ident => |n| eq(n, name),
        .int, .float, .string, .bool => false,
        .call => |c| blk: {
            if (exprUses(c.callee, name)) break :blk true;
            for (c.args, 0..) |_, i| {
                if (exprUses(&c.args[i], name)) break :blk true;
            }
            break :blk false;
        },
        .binary => |b| exprUses(b.left, name) or exprUses(b.right, name),
        .unary => |u| exprUses(u.operand, name),
        .field => |f| exprUses(f.base, name),
        .index => |ix| exprUses(ix.base, name) or exprUses(ix.index, name),
        .struct_lit => |sl| blk: {
            for (sl.fields, 0..) |_, i| {
                if (exprUses(&sl.fields[i].value, name)) break :blk true;
            }
            break :blk false;
        },
        .list_lit => |items| blk: {
            for (items, 0..) |_, i| {
                if (exprUses(&items[i], name)) break :blk true;
            }
            break :blk false;
        },
        .block => |stmts| stmtsUse(stmts, name),
        .if_expr => |i| blk: {
            if (exprUses(i.cond, name)) break :blk true;
            if (exprUses(i.then_body, name)) break :blk true;
            if (i.else_body) |eb| break :blk exprUses(eb, name);
            break :blk false;
        },
        .match_expr => |m| blk: {
            if (exprUses(m.scrutinee, name)) break :blk true;
            for (m.arms) |arm| {
                if (exprUses(arm.body, name)) break :blk true;
            }
            break :blk false;
        },
        .annotated => |a| exprUses(a.value, name),
        .wrap => |w| if (w.operand) |o| exprUses(o, name) else false,
    };
}

fn nameIn(set: []const []const u8, name: []const u8) bool {
    for (set) |n| if (eq(n, name)) return true;
    return false;
}

/// Adds every identifier `e` mentions to `set`; true when something new was
/// added. Nested statement lists are walked in full.
fn collectIdents(arena: std.mem.Allocator, e: *const ast.Expr, set: *std.ArrayList([]const u8)) Alloc!bool {
    var added = false;
    switch (e.kind) {
        .ident => |n| if (!nameIn(set.items, n)) {
            try set.append(arena, n);
            added = true;
        },
        .int, .float, .string, .bool => {},
        .call => |c| {
            if (try collectIdents(arena, c.callee, set)) added = true;
            for (c.args, 0..) |_, i| if (try collectIdents(arena, &c.args[i], set)) {
                added = true;
            };
        },
        .binary => |b| {
            if (try collectIdents(arena, b.left, set)) added = true;
            if (try collectIdents(arena, b.right, set)) added = true;
        },
        .unary => |u| if (try collectIdents(arena, u.operand, set)) {
            added = true;
        },
        .field => |f| if (try collectIdents(arena, f.base, set)) {
            added = true;
        },
        .index => |ix| {
            if (try collectIdents(arena, ix.base, set)) added = true;
            if (try collectIdents(arena, ix.index, set)) added = true;
        },
        .struct_lit => |sl| for (sl.fields, 0..) |_, i| if (try collectIdents(arena, &sl.fields[i].value, set)) {
            added = true;
        },
        .list_lit => |items| for (items, 0..) |_, i| if (try collectIdents(arena, &items[i], set)) {
            added = true;
        },
        .block => |stmts| if (try collectIdentsStmts(arena, stmts, set)) {
            added = true;
        },
        .if_expr => |i| {
            if (try collectIdents(arena, i.cond, set)) added = true;
            if (try collectIdents(arena, i.then_body, set)) added = true;
            if (i.else_body) |eb| if (try collectIdents(arena, eb, set)) {
                added = true;
            };
        },
        .match_expr => |m| {
            if (try collectIdents(arena, m.scrutinee, set)) added = true;
            for (m.arms) |arm| if (try collectIdents(arena, arm.body, set)) {
                added = true;
            };
        },
        .annotated => |a| if (try collectIdents(arena, a.value, set)) {
            added = true;
        },
        .wrap => |w| if (w.operand) |o| {
            if (try collectIdents(arena, o, set)) added = true;
        },
    }
    return added;
}

fn collectIdentsStmts(arena: std.mem.Allocator, stmts: []const ast.Stmt, set: *std.ArrayList([]const u8)) Alloc!bool {
    var added = false;
    for (stmts, 0..) |_, i| {
        const st = &stmts[i];
        switch (st.kind) {
            .let => |l| if (l.value) |*v| if (try collectIdents(arena, v, set)) {
                added = true;
            },
            .expr => |*e| if (try collectIdents(arena, e, set)) {
                added = true;
            },
            .return_stmt => |*opt| if (opt.*) |*v| if (try collectIdents(arena, v, set)) {
                added = true;
            },
            .assign => |*a| {
                if (try collectIdents(arena, &a.target, set)) added = true;
                if (try collectIdents(arena, &a.value, set)) added = true;
            },
            .while_stmt => |*w| {
                if (try collectIdents(arena, &w.cond, set)) added = true;
                if (try collectIdentsStmts(arena, w.body, set)) added = true;
            },
            .break_stmt, .continue_stmt => {},
        }
    }
    return added;
}

/// One round of `tailReach`'s fixpoint over a statement list: a `let` whose
/// name is reached feeds its initializer's identifiers in; an assignment
/// whose target root is reached feeds its value's in; nested statement
/// lists (a bare block, `if`/`match` bodies, a `while` body) are walked for
/// the same two shapes. True when the round added a name.
fn reachFromStmts(arena: std.mem.Allocator, stmts: []const ast.Stmt, set: *std.ArrayList([]const u8)) Alloc!bool {
    var added = false;
    for (stmts, 0..) |_, i| {
        const st = &stmts[i];
        switch (st.kind) {
            .let => |l| if (nameIn(set.items, l.name)) {
                if (l.value) |*v| if (try collectIdents(arena, v, set)) {
                    added = true;
                };
            },
            .assign => |*a| if (rootIdent(&a.target)) |root| {
                if (nameIn(set.items, root)) {
                    if (try collectIdents(arena, &a.value, set)) added = true;
                }
            },
            .expr => |*e| if (try reachFromExpr(arena, e, set)) {
                added = true;
            },
            .while_stmt => |*w| if (try reachFromStmts(arena, w.body, set)) {
                added = true;
            },
            .return_stmt, .break_stmt, .continue_stmt => {},
        }
    }
    return added;
}

fn reachFromExpr(arena: std.mem.Allocator, e: *const ast.Expr, set: *std.ArrayList([]const u8)) Alloc!bool {
    return switch (e.kind) {
        .block => |stmts| try reachFromStmts(arena, stmts, set),
        .if_expr => |i| blk: {
            var added = try reachFromExpr(arena, i.then_body, set);
            if (i.else_body) |eb| if (try reachFromExpr(arena, eb, set)) {
                added = true;
            };
            break :blk added;
        },
        .match_expr => |m| blk: {
            var added = false;
            for (m.arms) |arm| if (try reachFromExpr(arena, arm.body, set)) {
                added = true;
            };
            break :blk added;
        },
        .annotated => |a| try reachFromExpr(arena, a.value, set),
        else => false,
    };
}

/// The binding an assignment target is rooted at (`x`, `x.f`, `owned x`).
fn rootIdent(e: *const ast.Expr) ?[]const u8 {
    return switch (e.kind) {
        .ident => |n| n,
        .field => |f| rootIdent(f.base),
        .annotated => |a| rootIdent(a.value),
        .unary => |u| rootIdent(u.operand),
        else => null,
    };
}

fn stmtsUse(stmts: []const ast.Stmt, name: []const u8) bool {
    for (stmts, 0..) |_, i| {
        if (stmtUses(&stmts[i], name)) return true;
    }
    return false;
}

fn stmtUses(s: *const ast.Stmt, name: []const u8) bool {
    return switch (s.kind) {
        .let => |l| if (l.value) |v| exprUses(&v, name) else false,
        .expr => |e| exprUses(&e, name),
        .return_stmt => |opt| if (opt) |v| exprUses(&v, name) else false,
        .assign => |a| targetReads(&a.target, name) or exprUses(&a.value, name),
        // A loop's condition is re-read on every iteration, so a binding used
        // only there is genuinely used and must not get a `(void)` cast.
        .while_stmt => |w| exprUses(&w.cond, name) or stmtsUse(w.body, name),
        .break_stmt, .continue_stmt => false,
    };
}

/// Whether an assignment target READS `name`. `x = e` only writes x, and a
/// binding that is written and never read still trips
/// -Wunused-but-set-variable, so it needs the same `(void)` cast an unused one
/// gets. `x.f = e` does read x, because the store goes through it.
fn targetReads(e: *const ast.Expr, name: []const u8) bool {
    return switch (e.kind) {
        .ident => false,
        .annotated => |a| targetReads(a.value, name),
        else => exprUses(e, name),
    };
}

// ── tests ───────────────────────────────────────────────────────────────

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

/// Parse `src` and return the emitted C. The buffer is caller owned so the
/// returned slice stays valid.
fn emitForTest(arena: std.mem.Allocator, buf: []u8, src: []const u8) ![]const u8 {
    var lex = lexer.Lexer.init(src, "t.cell");
    const toks = try lex.tokenizeAll(arena);
    var p = parser.Parser.init(arena, toks.items, "t.cell");
    var module = try p.parseModule();
    var w = Io.Writer.fixed(buf);
    var gen = Generator.init(arena, &w);
    try gen.emitModule(&module);
    return w.buffered();
}

const TestEmit = struct {
    arena: std.heap.ArenaAllocator,
    buf: []u8,
    text: []const u8,

    fn deinit(self: *TestEmit) void {
        std.testing.allocator.free(self.buf);
        self.arena.deinit();
    }
};

fn emitSource(src: []const u8) !TestEmit {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const buf = try std.testing.allocator.alloc(u8, 64 * 1024);
    errdefer std.testing.allocator.free(buf);
    const text = try emitForTest(arena.allocator(), buf, src);
    return .{ .arena = arena, .buf = buf, .text = text };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\nexpected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.NotFound;
    }
}

/// The definition of one emitted function, from its signature line to its
/// closing brace, so a text assertion about one body is not satisfied or
/// broken by another. Since R11 row 1 closed, a callee with an `owned` or
/// `arc` parameter releases it, so a text-wide `expectAbsent` on a free
/// also matches every such callee in the same source.
fn fnDef(haystack: []const u8, name: []const u8) ![]const u8 {
    var buf: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, " cell_{s}(", .{name});
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, needle)) |at| {
        const eol = std.mem.indexOfScalarPos(u8, haystack, at, '\n') orelse break;
        if (haystack[eol - 1] == '{') {
            const end = std.mem.indexOfPos(u8, haystack, eol, "\n}\n") orelse break;
            return haystack[at .. end + 3];
        }
        from = eol;
    }
    std.debug.print("\nno definition of cell_{s} in:\n{s}\n", .{ name, haystack });
    return error.NotFound;
}

/// The emitted translation unit compiles as an object at
/// `-Wall -Wextra -Werror`, the flags the gate's sanitized stage uses.
fn expectCompiles(text: []const u8) !void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{cwd_buf[0..cwd_len]});
    defer gpa.free(include);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            "cc",     "-std=c11", "-Wall", "-Wextra", "-Werror", "-c",
            "body.c", "-I",       include, "-o",      "body.o",
        },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ result.stderr, text });
        return error.CcRejectedEmittedC;
    }
}

fn expectAbsent(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("\nexpected NOT to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.Found;
    }
}

/// How many times `needle` appears, for the assertions where ONE is the
/// answer and two is a double free. `expectContains` cannot tell those apart,
/// and a drop test that only asks "is the free there" passes just as happily
/// when it is there twice.
/// The trimmed line immediately before the first `jump` must be `prev`:
/// how a drop-before-jump test asks its question without hardcoding the
/// indentation of a `while` body nested in an `if`.
fn expectLineBefore(haystack: []const u8, jump: []const u8, prev: []const u8) !void {
    const at = std.mem.indexOf(u8, haystack, jump) orelse {
        std.debug.print("\nexpected to find:\n{s}\nin:\n{s}\n", .{ jump, haystack });
        return error.NotFound;
    };
    const line_start = if (std.mem.lastIndexOfScalar(u8, haystack[0..at], '\n')) |i| i + 1 else 0;
    const prev_end = if (line_start > 0) line_start - 1 else 0;
    const prev_start = if (std.mem.lastIndexOfScalar(u8, haystack[0..prev_end], '\n')) |i| i + 1 else 0;
    const got = std.mem.trim(u8, haystack[prev_start..prev_end], " ");
    if (!std.mem.eql(u8, got, prev)) {
        std.debug.print("\nexpected the line before:\n{s}\nto be:\n{s}\nbut it was:\n{s}\nin:\n{s}\n", .{ jump, prev, got, haystack });
        return error.WrongLineBefore;
    }
}

fn expectOccurrences(haystack: []const u8, needle: []const u8, want: usize) !void {
    const got = std.mem.count(u8, haystack, needle);
    if (got != want) {
        std.debug.print(
            "\nexpected {d} occurrence(s) of:\n{s}\nbut found {d}, in:\n{s}\n",
            .{ want, needle, got, haystack },
        );
        return error.WrongCount;
    }
}

test "every module includes the runtime header" {
    var e = try emitSource("pub fn f(copy v: Int) -> Int;");
    defer e.deinit();
    try expectContains(e.text, "#include \"cell_rt.h\"");
}

test "Int8 Int16 UInt8 UInt16 UInt32 lower to their C types" {
    var e = try emitSource(
        \\pub fn take_int8(copy v: Int8) -> Int8;
        \\pub fn take_int16(copy v: Int16) -> Int16;
        \\pub fn take_uint8(copy v: UInt8) -> UInt8;
        \\pub fn take_uint16(copy v: UInt16) -> UInt16;
        \\pub fn take_uint32(copy v: UInt32) -> UInt32;
        \\pub fn maybe_u32(copy v: UInt32?) -> Bool;
        \\pub fn maybe_u8(copy v: UInt8?) -> Bool;
        \\pub fn maybe_byte(copy v: Byte?) -> Bool;
    );
    defer e.deinit();
    try expectContains(e.text, "int8_t cell_take_int8(int8_t v);");
    try expectContains(e.text, "int16_t cell_take_int16(int16_t v);");
    try expectContains(e.text, "uint8_t cell_take_uint8(uint8_t v);");
    try expectContains(e.text, "uint16_t cell_take_uint16(uint16_t v);");
    try expectContains(e.text, "uint32_t cell_take_uint32(uint32_t v);");
    try expectContains(e.text, "bool cell_maybe_u32(cell_opt_u32_t v);");
    try expectContains(e.text, "bool cell_maybe_u8(cell_opt_u8_t v);");
    try expectContains(e.text, "bool cell_maybe_byte(cell_opt_byte_t v);");
}

test "ownership selects the parameter type for each mode" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  copy len: Int
        \\}
        \\pub fn by_copy(copy v: Int) -> Int;
        \\pub fn by_shared_primitive(shared v: Int) -> Int;
        \\pub fn by_exclusive_primitive(exclusive v: Int) -> Int;
        \\pub fn by_shared_string(shared s: String) -> Int;
        \\pub fn by_owned_string(owned s: String) -> Int;
        \\pub fn by_exclusive_string(exclusive s: String) -> Int;
        \\pub fn by_arc_string(arc s: String) -> Int;
        \\pub fn by_shared_struct(shared b: Buffer) -> Int;
        \\pub fn by_exclusive_struct(exclusive b: Buffer) -> Int;
        \\pub fn by_owned_struct(owned b: Buffer) -> Int;
        \\pub fn by_shared_list(shared xs: [Byte]) -> Int;
        \\pub fn by_exclusive_list(exclusive xs: [Byte]) -> Int;
    );
    defer e.deinit();

    // Primitives stay by value in every mode: cell_rt.h section 1.
    try expectContains(e.text, "int64_t cell_by_copy(int64_t v);");
    try expectContains(e.text, "int64_t cell_by_shared_primitive(int64_t v);");
    try expectContains(e.text, "int64_t cell_by_exclusive_primitive(int64_t v);");

    try expectContains(e.text, "int64_t cell_by_shared_string(cell_str_t s);");
    try expectContains(e.text, "int64_t cell_by_owned_string(cell_string_t s);");
    try expectContains(e.text, "int64_t cell_by_exclusive_string(cell_string_t *s);");
    try expectContains(e.text, "int64_t cell_by_arc_string(cell_arc_t s);");

    try expectContains(e.text, "int64_t cell_by_shared_struct(const cell_Buffer *b);");
    try expectContains(e.text, "int64_t cell_by_exclusive_struct(cell_Buffer *b);");
    try expectContains(e.text, "int64_t cell_by_owned_struct(cell_Buffer b);");

    try expectContains(e.text, "int64_t cell_by_shared_list(cell_slice_t xs);");
    try expectContains(e.text, "int64_t cell_by_exclusive_list(cell_slice_t *xs);");
}

test "a struct lowers each field by its own ownership" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  owned data: [Byte]
        \\  copy len: Int
        \\  shared name: String
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\typedef struct cell_Buffer {
        \\  cell_slice_t data; // owned
        \\  int64_t len; // copy
        \\  cell_str_t name; // shared
        \\} cell_Buffer;
    );
}

test "an enum is an int32_t typedef, not an implementation defined enum" {
    var e = try emitSource(
        \\pub enum Color {
        \\  Red,
        \\  Green,
        \\  Blue,
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\typedef int32_t cell_Color;
        \\enum {
        \\  cell_Color_Red = 0,
        \\  cell_Color_Green = 1,
        \\  cell_Color_Blue = 2,
        \\};
    );
    try expectAbsent(e.text, "typedef enum");
}

/// `first` must appear before `second`. An ordering test that only asserted
/// both are present would pass in the exact arrangement `cc` rejects, which
/// is how the forward-reference gap survived: `cell check` said ok and no
/// test looked at the order.
fn expectBefore(haystack: []const u8, first: []const u8, second: []const u8) !void {
    const a = std.mem.indexOf(u8, haystack, first) orelse {
        std.debug.print("\nexpected to find:\n{s}\nin:\n{s}\n", .{ first, haystack });
        return error.NotFound;
    };
    const b = std.mem.indexOf(u8, haystack, second) orelse {
        std.debug.print("\nexpected to find:\n{s}\nin:\n{s}\n", .{ second, haystack });
        return error.NotFound;
    };
    if (a >= b) {
        std.debug.print("\nexpected:\n{s}\nbefore:\n{s}\nin:\n{s}\n", .{ first, second, haystack });
        return error.WrongOrder;
    }
}

test "a struct field naming a later struct emits that struct's typedef first" {
    // `cell check` accepts this and source order emitted `cell_A` first, so
    // `cc` refused the module with `unknown type name 'cell_B'`.
    var e = try emitSource(
        \\pub struct A { owned b: B }
        \\pub struct B { owned name: String }
    );
    defer e.deinit();
    try expectBefore(e.text, "} cell_B;", "typedef struct cell_A {");
}

test "a ref field takes the same ordering edge as a value field" {
    // `shared b: B` lowers to `cell_B *`, which still needs the typedef.
    var e = try emitSource(
        \\pub struct A { shared b: B }
        \\pub struct B { copy x: Int }
    );
    defer e.deinit();
    try expectBefore(e.text, "} cell_B;", "typedef struct cell_A {");
}

test "independent structs keep source order" {
    // The reorder must be minimal: structs that do not reference each other
    // emit exactly as they did before the dependency walk existed.
    var e = try emitSource(
        \\pub struct First { copy x: Int }
        \\pub struct Second { copy y: Int }
    );
    defer e.deinit();
    try expectBefore(e.text, "} cell_First;", "typedef struct cell_Second {");
}

test "a struct cycle terminates, emits both typedefs, and drops the back edge" {
    // No emission order compiles a by-value cycle, so the pass must not hang
    // or drop a struct; it leaves the cycle for `cc` to report.
    //
    // The order assertion documents what the DFS actually does rather than
    // stating a requirement: A is visited first, recurses into B, B's edge
    // back to A meets `visiting` and returns, so B completes and emits first.
    // It is pinned because the first version of this test asserted only that
    // both were present, and that blindness let the doc comment claim for a
    // while that a cycle was "left in source order" when it is not.
    var e = try emitSource(
        \\pub struct A { owned b: B }
        \\pub struct B { owned a: A }
    );
    defer e.deinit();
    try expectContains(e.text, "} cell_A;");
    try expectContains(e.text, "} cell_B;");
    try expectBefore(e.text, "} cell_B;", "typedef struct cell_A {");
}

test "an enum a struct field names is emitted before the struct" {
    var e = try emitSource(
        \\pub struct Tagged { copy c: Color }
        \\pub enum Color { Red, Green }
    );
    defer e.deinit();
    try expectBefore(e.text, "typedef int32_t cell_Color;", "typedef struct cell_Tagged {");
}

test "a match arm's binding pattern carries the scrutinee's type into inference" {
    // `match s { x => x }` used to infer nothing from `x`, so `emitValueExpr`
    // fell back to `CType.int64` and `cc` rejected the module with
    // `assigning to 'int64_t' from incompatible type 'cell_string_t'`.
    // Asserting the DECLARED TYPE of the destination rather than merely that
    // a match was emitted: the wrong type is what compiled, not a missing
    // statement, so a presence-only test would pass on the broken output.
    var e = try emitSource(
        \\pub fn make() -> String {
        \\    return "hello"
        \\}
        \\pub fn demo() -> Int {
        \\    let owned s = make()
        \\    let shared c = match s { x => x }
        \\    return 0
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t c = ({");
    try expectAbsent(e.text, "int64_t c = ({");
}

test "a scalar scrutinee is not over-typed by that inference" {
    // The other direction of the same change: the arm binding must take the
    // scrutinee's type, not a resource type by default.
    var e = try emitSource(
        \\pub fn demo() -> Int {
        \\    let copy n = 7
        \\    let copy c = match n { x => x }
        \\    return c
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t c = ({");
}

test "an arm body that is not the binding still infers from the body" {
    // Pins that the fix did not reroute every match through the scrutinee:
    // a literal arm body keeps its own type, which is what already worked.
    var e = try emitSource(
        \\pub fn make() -> String {
        \\    return "hello"
        \\}
        \\pub fn demo() -> Int {
        \\    let owned s = make()
        \\    let shared c = match s { x => "lit" }
        \\    return 0
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_str_t c = ({");
}

test "a zero-parameter function is prototyped with void" {
    var e = try emitSource("pub fn tick();");
    defer e.deinit();
    try expectContains(e.text, "void cell_tick(void);");
}

test "an optional lowers to the tagged runtime type, not void*" {
    var e = try emitSource(
        \\pub struct Point { copy x: Int }
        \\pub fn maybe_int(shared v: Int?) -> Bool;
        \\pub fn maybe_point(shared p: Point?) -> Bool;
    );
    defer e.deinit();
    try expectContains(e.text, "CELL_DEFINE_OPTIONAL(cell_opt_Point, cell_Point)");
    try expectContains(e.text, "bool cell_maybe_int(cell_opt_i64_t v);");
    try expectContains(e.text, "bool cell_maybe_point(cell_opt_Point_t p);");
}

test "a list parameter lowers to a slice, not void*" {
    var e = try emitSource("pub fn count(shared xs: [Byte]) -> Int;");
    defer e.deinit();
    try expectContains(e.text, "int64_t cell_count(cell_slice_t xs);");
    try expectAbsent(e.text, "void*");
}

test "postfix indexing of String and [Byte] calls the bounds-checked helpers" {
    var e = try emitSource(
        \\pub fn f(shared s: String, shared xs: [Byte], copy i: Int) -> Byte? {
        \\  return s[i]
        \\}
        \\pub fn g(shared xs: [Byte]) -> Byte? {
        \\  return xs[0]
        \\}
        \\pub fn h(owned s: String, copy i: Int) -> Byte? {
        \\  return s[i]
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_str_byte_at(s, i)");
    try expectContains(e.text, "cell_bytes_at(xs, 0)");
    try expectContains(e.text, "cell_str_byte_at(cell_string_as_str(&s), i)");
    try expectAbsent(e.text, ".ptr[");
}

test "calls are mangled and reach the runtime intrinsics" {
    var e = try emitSource(
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
        \\pub fn main() {
        \\  let copy n = add(shared 40, shared 2)
        \\  print("hi")
        \\  println("hi")
        \\  assert(true)
        \\  assert(true, "boom")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t n = cell_add(40, 2);");
    try expectContains(e.text, "cell_print(cell_str_from_parts(\"hi\", 2));");
    try expectContains(e.text, "cell_println(cell_str_from_parts(\"hi\", 2));");
    try expectContains(e.text, "cell_assert(true);");
    try expectContains(e.text, "cell_assert_msg(true, cell_str_from_parts(\"boom\", 4));");
    // A shared primitive argument is passed by value, never addressed.
    try expectAbsent(e.text, "cell_add(&40, &2)");
}

test "a bodyless declaration of an intrinsic takes the runtime spelling" {
    var e = try emitSource(
        \\pub fn assert(shared cond: Bool, shared msg: String);
        \\pub fn main() {
        \\  assert(true, "boom")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "void cell_assert_msg(bool cond, cell_str_t msg);");
    try expectContains(e.text, "cell_assert_msg(true, cell_str_from_parts(\"boom\", 4));");
    try expectAbsent(e.text, "void cell_assert(bool cond, cell_str_t msg)");
}

test "a defined function is never renamed onto a runtime symbol" {
    var e = try emitSource(
        \\pub fn assert(shared cond: Bool, shared msg: String) {
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "void cell_assert(bool cond, cell_str_t msg) {");
    try expectAbsent(e.text, "cell_assert_msg");
}

test "a string literal decodes escapes then re-escapes them for C" {
    var quote = try emitSource(
        \\pub fn main() {
        \\  print("a\"b")
        \\}
    );
    defer quote.deinit();
    // `"a\"b"` is three bytes a"b. The C literal re-escapes the quote.
    try expectContains(quote.text, "cell_str_from_parts(\"a\\\"b\", 3)");

    var nl = try emitSource(
        \\pub fn main() {
        \\  print("\n")
        \\}
    );
    defer nl.deinit();
    try expectContains(nl.text, "cell_str_from_parts(\"\\n\", 1)");

    var bs = try emitSource(
        \\pub fn main() {
        \\  print("\\")
        \\}
    );
    defer bs.deinit();
    try expectContains(bs.text, "cell_str_from_parts(\"\\\\\", 1)");
}

test "a shared borrow of a primitive drops the ampersand" {
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn take_int(shared v: Int) -> Int;
        \\pub fn take_buf(shared b: Buffer) -> Int;
        \\pub fn main() {
        \\  let copy n = 1
        \\  let owned b = Buffer { len: 0 }
        \\  let copy x = take_int(&n)
        \\  let copy y = take_buf(&b)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_take_int(n);");
    try expectContains(e.text, "cell_take_buf(&b);");
}

test "a call site is lowered against the callee's parameter ownership" {
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn grow(exclusive buf: Buffer, shared extra: Int) {
        \\  let copy new_len = buf.len + extra
        \\  buf.len = new_len
        \\}
        \\pub fn read_only(shared b: Buffer) -> Int {
        \\  return b.len
        \\}
        \\pub fn main() {
        \\  let owned buf = Buffer { len: 0 }
        \\  grow(exclusive buf, shared 16)
        \\  let copy n = read_only(shared buf)
        \\}
    );
    defer e.deinit();
    // Emission still follows the callee signature, so `exclusive buf`
    // becomes `&buf` because `grow` takes `exclusive Buffer`.
    try expectContains(e.text, "cell_grow(&buf, 16);");
    try expectContains(e.text, "cell_read_only(&buf);");
    // Inside grow, buf is a pointer, so field selection uses `->`.
    try expectContains(e.text, "int64_t new_len = (buf->len + extra);");
    try expectContains(e.text, "buf->len = new_len;");
}

test "a struct literal becomes a designated compound literal" {
    var e = try emitSource(
        \\pub struct Point {
        \\  copy x: Float64
        \\  copy y: Float64
        \\}
        \\pub fn main() {
        \\  let owned p = Point { x: 1.0, y: 2.0 }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_Point p = (cell_Point){ .x = 1.0, .y = 2.0 };");
}

test "list literals lower to slice headers" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  owned data: [Byte]
        \\  copy len: Int
        \\}
        \\pub fn main() {
        \\  let owned b = Buffer { data: [], len: 0 }
        \\  let owned xs = [1, 2]
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, ".data = cell_slice_empty()");
    try expectContains(e.text, "cell_slice_t _cell_t0 = cell_slice_alloc(sizeof(int64_t), 2);");
    try expectContains(e.text, "(void)cell_slice_push(&_cell_t0, sizeof(int64_t), &_cell_t1);");
}

test "statement position if is plain C" {
    var e = try emitSource(
        \\pub fn pick(shared c: Bool) -> Int {
        \\  if (c) { return 1 } else { return 2 }
        \\  return 0
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\  if (c) {
        \\    return 1;
        \\  } else {
        \\    return 2;
        \\  }
    );
    try expectAbsent(e.text, "/*if*/");
}

test "expression position if becomes a statement expression" {
    var e = try emitSource(
        \\pub fn pick(shared c: Bool) -> Int {
        \\  let copy v = if (c) { 1 } else { 2 }
        \\  return v
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t v = ({");
    try expectContains(e.text, "_cell_t0 = 1;");
    try expectContains(e.text, "_cell_t0 = 2;");
}

test "a match whose reached arms never read the scrutinee voids its temporary" {
    // Measured 2026-09-16: `let arc a = match c { _ => make() }` emitted
    // `int64_t _cell_t4 = c;` with no reader and failed -Werror. The
    // scrutinee is still evaluated; only the unused-variable warning goes.
    var e = try emitSource(
        \\pub fn f(copy c: Int) -> Int {
        \\  return match c { _ => 7 }
        \\}
        \\pub fn g(copy c: Int, copy b: Bool) -> Int {
        \\  return match c { _ if b => 1, _ => 2 }
        \\}
        \\pub fn h(copy c: Int) -> Int {
        \\  return match c { 1 => 1, _ => 2 }
        \\}
        \\pub fn k(copy c: Int) -> Int {
        \\  return match c { x => x }
        \\}
    );
    defer e.deinit();
    try expectContains(try fnDef(e.text, "f"), "(void)_cell_t");
    try expectContains(try fnDef(e.text, "g"), "(void)_cell_t");
    try expectAbsent(try fnDef(e.text, "h"), "(void)_cell_t");
    try expectAbsent(try fnDef(e.text, "k"), "(void)_cell_t");
    try expectCompiles(e.text);
}

test "TYPE-06: a Result with an owning String error is its own instance and is released" {
    // Until sub-project 3 (2026-09-17) this pair was the ABI-1 `cell_result_t`
    // pass-through and was never dropped (a leak). It now has an instance and
    // release glue: a returned value moves, an ignored owned one is released.
    var e = try emitSource(
        \\pub fn read() -> Result<Int, String>;
        \\pub fn relay() -> Result<Int, String> {
        \\  return read()
        \\}
        \\pub fn keep(owned r: Result<Int, String>) -> Result<Int, String> {
        \\  return r
        \\}
        \\pub fn ignore(owned r: Result<Int, String>) -> Int {
        \\  return 1
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_res_i64_string_t cell_read(void);");
    try expectContains(e.text, "if (!r->ok) cell_string_free(&r->as.err);");
    try expectContains(try fnDef(e.text, "relay"), "return cell_read();");
    try expectContains(try fnDef(e.text, "keep"), "return r;");
    try expectAbsent(try fnDef(e.text, "keep"), "cell_drop_res_i64_string(&r);");
    try expectOccurrences(try fnDef(e.text, "ignore"), "cell_drop_res_i64_string(&r);", 1);
    try expectAbsent(e.text, "cell_arc_drop");
    try expectCompiles(e.text);
}

test "match lowers to a scrutinee temporary and an if chain" {
    var e = try emitSource(
        \\pub enum Color { Red, Green, Blue }
        \\pub fn describe(shared c: Color) -> Int {
        \\  return match c {
        \\    Color.Red => 1,
        \\    Green => 2,
        \\    _ => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_Color _cell_t1 = c;");
    try expectContains(e.text, "if (_cell_t1 == cell_Color_Red) {");
    try expectContains(e.text, "} else if (_cell_t1 == cell_Color_Green) {");
    try expectAbsent(e.text, "/*match*/");
}

test "an equality condition gets one pair of parentheses, not two" {
    // `if ((a == 2))` is rejected by clang's -Wparentheses-equality under
    // -Werror. Every condition site goes through `emitCond`: statement and
    // value `if`, `else if`, `while`, a guard-only arm and a pattern arm's
    // `&& (guard)`. Operands keep their own parentheses.
    var e = try emitSource(
        \\pub enum Color { Red, Green }
        \\pub fn stmt(copy a: Int, copy b: Int) -> Int {
        \\  var i = 0
        \\  while i != a {
        \\    i = i + 1
        \\  }
        \\  if a == 2 {
        \\    return 1
        \\  } else if a != b {
        \\    return 2
        \\  }
        \\  if (a + 1) == (b - 1) {
        \\    return 3
        \\  }
        \\  return 0
        \\}
        \\pub fn value(copy a: Int) -> Int {
        \\  let copy v = if a == 3 { 4 } else { 5 }
        \\  return v
        \\}
        \\pub fn guarded(copy c: Color, copy n: Int) -> Int {
        \\  return match c {
        \\    Color.Green if n == 5 => 7,
        \\    _ => 0,
        \\  }
        \\}
        \\pub fn guard_only(copy n: Int) -> Int {
        \\  return match n {
        \\    _ if n == 1 => 1,
        \\    _ => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "while (i != a) {");
    try expectContains(e.text, "if (a == 2) {");
    try expectContains(e.text, "} else if (a != b) {");
    try expectContains(e.text, "if ((a + 1) == (b - 1)) {");
    try expectContains(e.text, "if (a == 3) {");
    try expectContains(e.text, "&& (n == 5)) {");
    try expectContains(e.text, "if (n == 1) {");
    try expectAbsent(e.text, "((a == 2))");
    try expectAbsent(e.text, "((n == 5))");
    try expectCompiles(e.text);
}

test "a match without a catch-all arm panics instead of inventing a value" {
    var e = try emitSource(
        \\pub fn describe(shared n: Int) -> Int {
        \\  return match n {
        \\    1 => 10,
        \\    2 => 20,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_panic(cell_str_from_cstr(\"non-exhaustive match in describe\"));");
}

test "a match arm binding is declared and kept quiet when unused" {
    var e = try emitSource(
        \\pub fn describe(shared n: Int) -> Int {
        \\  return match n {
        \\    1 => 10,
        \\    other => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t other = _cell_t1;");
    try expectContains(e.text, "(void)other;");
}

test "unused parameters and locals are named so -Wextra stays quiet" {
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn take(owned b: Buffer) {
        \\}
        \\pub fn main() {
        \\  let copy unused = 1
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "void cell_take(cell_Buffer b) {\n  (void)b;\n}");
    try expectContains(e.text, "(void)unused;");
}

test "a qualified enum variant in expression position is the enum constant" {
    var e = try emitSource(
        \\pub enum Color { Red, Green, Blue }
        \\pub fn describe(copy c: Color) -> Int;
        \\pub fn main() {
        \\  let copy n = describe(Color.Green)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_describe(cell_Color_Green)");
}

test "a binding that is only assigned still gets a (void) cast" {
    // -Wunused-but-set-variable fires on a write-only binding, so a plain
    // assignment target does not count as a use.
    var e = try emitSource(
        \\pub fn f() {
        \\  var counter: Int = 0
        \\  counter = 1
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t counter = 0;\n  (void)counter;\n  counter = 1;");
}

test "a module with a main gets a C entry point" {
    var e = try emitSource(
        \\pub fn main() {
        \\  print("hi")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\int main(void) {
        \\  cell_main();
        \\  return 0;
        \\}
    );
}

test "a module without a main gets no C entry point" {
    var e = try emitSource("pub fn helper(copy v: Int) -> Int;");
    defer e.deinit();
    try expectAbsent(e.text, "int main(void)");
}

test "the hello example emits runtime-backed C" {
    // The example file itself cannot be read from here: @embedFile is limited
    // to the module root at src/, so the source is inlined.
    var e = try emitSource(
        \\use std.io
        \\
        \\pub struct Point {
        \\  copy x: Float64
        \\  copy y: Float64
        \\}
        \\
        \\pub enum Color {
        \\  Red,
        \\  Green,
        \\  Blue,
        \\}
        \\
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
        \\
        \\pub fn main() {
        \\  let owned p = Point { x: 1.0, y: 2.0 }
        \\  let copy n = add(shared 40, shared 2)
        \\  print("hello from cell")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "#include \"cell_rt.h\"");
    try expectContains(e.text, "cell_print(");
    try expectContains(e.text, "int64_t cell_add(int64_t a, int64_t b) {");
    try expectContains(e.text, "cell_Point p = (cell_Point){ .x = 1.0, .y = 2.0 };");
    try expectContains(e.text, "int main(void) {");
}

test "generated C for a function body compiles with cc -c" {
    var e = try emitSource(
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
        \\pub fn print_int(copy value: Int);
        \\pub fn main() {
        \\  let copy n = add(shared 40, shared 2)
        \\  print_int(n)
        \\}
    );
    defer e.deinit();

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{cwd_buf[0..cwd_len]});
    defer gpa.free(include);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-std=c11", "-Wall", "-Wextra", "-c", "body.c", "-I", include, "-o", "body.o" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ result.stderr, e.text });
        return error.CcRejectedEmittedC;
    }
}

test "a match guard is ANDed into the arm's test" {
    var e = try emitSource(
        \\pub enum Color { Red, Green }
        \\pub fn f(copy c: Color, copy n: Int) -> Int {
        \\  return match c { Color.Green if n > 5 => 7, _ => 0, }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "== cell_Color_Green && (");
}

test "a guarded catch-all arm still leaves the non-exhaustive panic in place" {
    // `_ if c` can fail, so dropping the panic would let an unmatched value
    // fall through with a made-up result. This is the whole reason a guarded
    // arm is not treated as a default.
    var e = try emitSource(
        \\pub fn f(copy n: Int) -> Int {
        \\  return match n { _ if n > 5 => 7, }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_panic(cell_str_from_cstr(\"non-exhaustive match in f\")");
}

test "an unguarded catch-all still removes the panic" {
    var e = try emitSource(
        \\pub fn f(copy n: Int) -> Int {
        \\  return match n { 1 => 1, _ => 0, }
        \\}
    );
    defer e.deinit();
    if (std.mem.indexOf(u8, e.text, "non-exhaustive") != null) {
        std.debug.print("unexpected panic:\n{s}\n", .{e.text});
        return error.UnexpectedPanic;
    }
}

// ── drop insertion (task 3) ───────────────────────────────────────────────
//
// The first two are the safety tests, and come first on purpose: they pin
// the double-free guard before anything else pins the feature working at
// all. Every scenario here was probed against the real `cell emit` output
// before being written down, and the first two were also verified by fault
// injection -- see the task report -- by temporarily deleting the
// `wasMoved` check in `pendingDrops` and confirming a real double free (a
// `main()` that assigns one owned local's value onto another, then lets
// both reach scope exit) aborts, then restoring the check and confirming
// the same program exits clean.

test "a whole-value assignment through an exclusive borrow writes the POINTEE" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  copy len: Int
        \\}
        \\pub fn make() -> String;
        \\pub fn reset(exclusive b: Buffer) {
        \\  b = Buffer { len: 42 }
        \\}
        \\pub fn set_str(exclusive s: String) {
        \\  s = make()
        \\}
    );
    defer e.deinit();
    // An `exclusive` parameter lowers to a pointer, and writing the whole
    // value through it means writing what it points at. Both of these passed
    // `cell check` and emitted the value into the POINTER: `cc` refused with
    // `assigning to 'cell_Buffer *' from incompatible type 'cell_Buffer';
    // take the address with &`. Two forms, a record and a string, because
    // the record is the reported one and the string is the same defect
    // reached through a different `applyOwnership` branch.
    try expectContains(e.text, "  *b = (cell_Buffer){ .len = 42 };");
    try expectContains(e.text, "  *s = cell_make();");
}

test "a FIELD assignment through an exclusive borrow is unchanged" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  copy len: Int
        \\}
        \\pub fn bump(exclusive b: Buffer) {
        \\  b.len = b.len + 5
        \\}
        \\pub fn local() {
        \\  var owned b = Buffer { len: 1 }
        \\  b = Buffer { len: 2 }
        \\}
    );
    defer e.deinit();
    // The two neighbours the dereference must not touch. A `.field` target
    // gets the FIELD's type from `inferExpr` and `emitExpr` already spells
    // the base with `->`, and an owned local is not a pointer at all. Adding
    // a `*` to either would be a fresh miscompile rather than a fix, so both
    // are pinned by exact text.
    try expectContains(e.text, "  b->len = (b->len + 5);");
    try expectContains(e.text, "  b = (cell_Buffer){ .len = 2 };");
    try expectAbsent(e.text, "*b->len");
}

test "a write through an exclusive borrow reaches the caller, compiled and run" {
    // The assertion emitted text cannot make. The reporting agent measured
    // that the MLIR backend prints 37 for this shape, i.e. it silently drops
    // the write, so "it compiles" is not evidence that the caller sees it.
    // Only running it and reading the caller's own value back distinguishes
    // a write through the borrow from a write to a copy.
    //
    // The printed 47 decomposes as 42 + 5, and both halves are measurements:
    // `reset` replaces the whole value through the borrow, and `bump` then
    // adds 5 through the field path. If the whole-value write went to a copy
    // this prints 6, and if either write were dropped it prints 6 or 43.
    // No host is needed: `cell_print_int` is in the runtime.
    var e = try emitSource(
        \\pub struct Buffer {
        \\  copy len: Int
        \\}
        \\pub fn print_int(copy value: Int);
        \\pub fn reset(exclusive b: Buffer) {
        \\  b = Buffer { len: 42 }
        \\}
        \\pub fn bump(exclusive b: Buffer) {
        \\  b.len = b.len + 5
        \\}
        \\pub fn main() {
        \\  let owned buf = Buffer { len: 1 }
        \\  reset(exclusive buf)
        \\  bump(exclusive buf)
        \\  print_int(buf.len)
        \\}
    );
    defer e.deinit();
    // Both sides of the call, because the adjacent LLVM fix a few hours ago
    // turned out to be TWO bugs, one per side, and either alone still
    // printed the wrong number.
    try expectContains(e.text, "  *b = (cell_Buffer){ .len = 42 };");
    try expectContains(e.text, "  cell_reset(&buf);");

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const root = cwd_buf[0..cwd_len];
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{root});
    defer gpa.free(include);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{root});
    defer gpa.free(rt_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{
            "cc",    "-std=c11",                     "-Wall",  "-Wextra", "-Werror",
            "-g",    "-fsanitize=address,undefined", "body.c", rt_c,      "-I",
            include, "-o",                           "body",
        },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(cc_result.stdout);
    defer gpa.free(cc_result.stderr);
    if (!cc_result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ cc_result.stderr, e.text });
        return error.CcRejectedEmittedC;
    }

    const run_result = try std.process.run(gpa, io, .{
        .argv = &.{"./body"},
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    if (!run_result.term.success()) {
        std.debug.print(
            "the emitted program did not exit cleanly:\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    // 6 means the whole-value write went to a copy the caller never sees.
    try std.testing.expectEqualStrings("47\n", run_result.stdout);
}

test "a moved value is not dropped" {
    // The double-free guard: `s` is moved into `take` (borrowck's call-site
    // move, R1/R2), so it must never reach `cell_string_free`.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\  let owned s = make()
        \\  take(owned s)
        \\}
    );
    defer e.deinit();
    try expectAbsent(try fnDef(e.text, "f"), "cell_string_free");
}

test "a value moved in one branch of an if is released on the other" {
    // R16 residual 1: the merge still records `s` moved, so the scope-end
    // drop skips it. The non-moving branch now releases it at its own end.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn take(owned s: String) { }
        \\pub fn f(shared c: Bool) {
        \\  let owned s = make()
        \\  if (c) {
        \\    take(owned s)
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&s);", 1);
    try expectContains(f, "} else {\n    cell_string_free(&s);\n  }");
}

test "a value moved only AFTER an if or match is not released inside it" {
    // Found 2026-09-17 while grounding IR String step (b). The branch-end
    // release (1eaed84, extended to match arms in 38e33a2) asked "moved
    // somewhere in the function" and "dead at the enclosing block's end",
    // so a value moved by a statement AFTER an unrelated if/match was freed
    // at the end of every branch, and the later move read a freed header:
    // `print_int(e + take(ns))` printed 1 in C where LLVM printed 43, with
    // AddressSanitizer silent because the free zeroes the header. The fix
    // asks borrowck whether the value is still held right after the merge
    // (`ExitKind.after_branch`); only a value some branch moved is released.
    var e = try emitSource(
        \\pub struct Pair { owned a: String, owned b: String }
        \\pub fn make() -> String;
        \\pub fn pair() -> Pair;
        \\pub fn print_int(copy value: Int);
        \\pub fn take(owned s: String) -> Int;
        \\pub fn eat(owned p: Pair) -> Int;
        \\pub fn f(copy flag: Bool) {
        \\  let owned s = make()
        \\  let owned p = pair()
        \\  let owned q = pair()
        \\  if flag { print_int(1) } else { print_int(0) }
        \\  match flag {
        \\    true => print_int(2),
        \\    false => print_int(3),
        \\  }
        \\  let copy e = match flag {
        \\    true => 1,
        \\    false => 0,
        \\  }
        \\  if flag { print_int(4) } else if e > 0 { print_int(5) }
        \\  print_int(e + take(s) + eat(p) + take(q.a))
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectAbsent(f, "cell_string_free(&s);");
    try expectAbsent(f, "cell_drop_Pair(&p);");
    try expectAbsent(f, "cell_string_free(&q.a);");
    // q.b is still released once, at function end.
    try expectOccurrences(f, "cell_string_free(&q.b);", 1);
}

test "a value moved on one branch is still released on the other, after the fix" {
    // The case the branch-end release exists for must survive the
    // after_branch guard: moved in `then`, held in `else`, dead after.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn take(owned s: String) -> Int;
        \\pub fn print_int(copy value: Int);
        \\pub fn f(copy flag: Bool) {
        \\  let owned s = make()
        \\  match flag {
        \\    true => print_int(take(s)),
        \\    false => print_int(0),
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&s);", 1);
}

test "a value revived in a loop and read after it is not released at the loop exit" {
    // Found 2026-09-17 while grounding IR String step (c). The after-loop
    // release held back only when the enclosing block end recorded the
    // value live, and `loop_moved` forces that record false, so a READ
    // after the loop was never considered: C emitted
    // `cell_string_free(&s); cell_print(cell_string_as_str(&s));` and
    // printed an empty line where LLVM and MLIR printed "again". Silent:
    // the free zeroes the header, so ASan and the malloc counter saw nothing.
    // Now a binding mentioned after the loop (in the rest of any enclosing
    // block, or anywhere in an enclosing loop body) is not released there;
    // it leaks instead, the safe direction, until the drop is precise.
    var e = try emitSource(
        \\pub fn print(shared msg: String);
        \\pub fn take(owned s: String);
        \\pub fn str_len(shared s: String) -> Int;
        \\pub fn f() {
        \\  var owned s: String = "first"
        \\  var j = 0
        \\  while j < 2 {
        \\    take(owned s)
        \\    s = "again"
        \\    j = j + 1
        \\  }
        \\  print(shared s)
        \\}
        \\pub fn g(copy flag: Bool) -> Int {
        \\  var owned t: String = "x"
        \\  if flag {
        \\    var j = 0
        \\    while j < 2 {
        \\      take(owned t)
        \\      t = "y"
        \\      j = j + 1
        \\    }
        \\  }
        \\  return str_len(shared t)
        \\}
        \\pub fn h() {
        \\  var owned u: String = "p"
        \\  var j = 0
        \\  while j < 2 {
        \\    take(owned u)
        \\    u = "q"
        \\    j = j + 1
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectAbsent(f, "cell_string_free(&s);\n  cell_print");
    const g = try fnDef(e.text, "g");
    try expectAbsent(g, "cell_string_free(&t);");
    // Not read after the loop: the after-loop release is still right.
    const h = try fnDef(e.text, "h");
    try expectOccurrences(h, "cell_string_free(&u);", 1);
}

test "a value moved by being returned is not dropped" {
    // The third of borrowck's four move sites (`movePlace` is called from
    // the `return` arm), and until now the only one with no test. It is the
    // site where a wrong drop is worst: emitting a free here would lower to
    // `tmp = s; cell_string_free(&s); return tmp;`, handing every caller a
    // struct whose buffer this function already released -- a use after
    // free at the CALL site, where nothing in this file would see it.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() -> String {
        \\  let owned s = make()
        \\  return s
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free");
}

test "a value moved into another let binding is not dropped, but its new owner is" {
    // The last untested move site: `let owned b = a` moves `a` into `b`.
    // This pins both halves of the transfer in one program, which neither
    // safety test above does: the source must NOT be freed (it no longer
    // owns anything) and the destination MUST be (it now does). A single
    // `expectAbsent` on "cell_string_free" would pass vacuously if drops
    // stopped firing altogether, so the positive half is what keeps this
    // test honest.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned a = make()
        \\  let owned b = a
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_free(&b);");
    try expectAbsent(e.text, "cell_string_free(&a);");
}

test "an unmoved owned String local is freed at scope end" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned s = make()
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_free(&s);");
}

test "a record with one owning field moved out releases the other field, not the moved one" {
    // The partial-move leak. `p.a` is moved into `m`, so `m` owns that
    // buffer and releases it; `p.b` is still `p`'s, and before
    // `moved_paths` nothing released it because the whole record was
    // skipped. Counted, not just searched for: a free of `p.a` here would be
    // a double free, and `expectContains` passes just as happily on two.
    var e = try emitSource(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f() {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\  let owned m: String = p.a
        \\}
    );
    defer e.deinit();
    try expectOccurrences(e.text, "cell_string_free(&p.b);", 1);
    try expectAbsent(e.text, "cell_string_free(&p.a);");
    try expectAbsent(e.text, "cell_drop_Pair(&p);");
    try expectOccurrences(e.text, "cell_string_free(&m);", 1);
}

test "a record whose only owning field was moved out releases nothing of its own" {
    // The case the old all-or-nothing skip happened to get RIGHT, pinned so
    // the partial drop cannot regress it: the one droppable field is gone,
    // so releasing it, or calling the glue, would free `m`'s buffer twice.
    var e = try emitSource(
        \\pub struct One {
        \\    owned a: String
        \\    copy n: Int
        \\}
        \\pub fn f() {
        \\  let owned p: One = One { a: "x", n: 1 }
        \\  let owned m: String = p.a
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free(&p.a);");
    try expectAbsent(e.text, "cell_drop_One(&p);");
    try expectOccurrences(e.text, "cell_string_free(&m);", 1);
}

test "a field moved on only one branch of an if is released on the other" {
    // Residual 1 at field granularity. The merge still records `p.a` moved,
    // so the scope-end partial drop skips it. The non-moving branch now
    // releases it at its own end. `p.b` was never moved and is released
    // once at scope end. The whole record is never dropped on the else
    // path: that would double-free `p.b` with the later partial drop.
    // Falsified 2026-09-16: freeing `cell_drop_Pair(&p)` on the else path,
    // freeing `p.a` at scope end as well as else, or freeing `p.a` on the
    // then path, each AddressSanitizer double free at exit 134. Restored.
    var e = try emitSource(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f(shared c: Bool) {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\  if (c) {
        \\    take(owned p.a)
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&p.a);", 1);
    try expectContains(f, "} else {\n    cell_string_free(&p.a);\n  }");
    try expectOccurrences(f, "cell_string_free(&p.b);", 1);
    try expectAbsent(f, "cell_drop_Pair(&p);");
}

test "a record moved as a whole after nothing else is still not dropped at all" {
    // `wasWhollyMoved` is the gate that keeps the partial path from ever
    // touching a record that went away entirely; `q` now owns both fields.
    var e = try emitSource(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f() {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\  let owned q: Pair = p
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_drop_Pair(&p);");
    try expectAbsent(e.text, "&p.a");
    try expectAbsent(e.text, "&p.b");
    try expectOccurrences(e.text, "cell_drop_Pair(&q);", 1);
}

test "a record with nothing moved still goes through its drop glue" {
    // The partial path is taken only when borrowck recorded a move under
    // the binding; an untouched record keeps the one glue call R11 row 2
    // introduced, rather than an inline expansion of it.
    var e = try emitSource(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f() {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\}
    );
    defer e.deinit();
    try expectOccurrences(e.text, "cell_drop_Pair(&p);", 1);
    try expectAbsent(e.text, "fields moved out");
}

test "a skip-revival continue does not free a field taken before the jump" {
    // The walk still sees `p.a = "c"` after `continue`, which retracts
    // `fieldWasMoved`. Freeing `p.a` at the jump would double-free with
    // `take`. Dead at this jump => skip; `p.b` is still released.
    var e = try emitSource(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\  var i = 0
        \\  while i < 1 {
        \\    var owned p: Pair = Pair { a: "x", b: "y" }
        \\    take(owned p.a)
        \\    if i < 1 { continue }
        \\    p.a = "c"
        \\    i = i + 1
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_string_free(&p.b);");
    try expectLineBefore(f, "continue;", "cell_string_free(&p.b);");
}

test "a field revived after it was moved is released at scope end" {
    // R16 field revival. `take(owned p.a)` marks `a` moved; `p.a = "c"`
    // revives it. Before, `moved_paths` stayed set, so the partial drop
    // skipped the new value. `p.b` was never moved. Still partial: no
    // whole-record glue (that would double-free if `a` had not revived).
    var e = try emitSource(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\  var owned p: Pair = Pair { a: "x", b: "y" }
        \\  take(owned p.a)
        \\  p.a = "c"
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&p.a);", 1);
    try expectOccurrences(f, "cell_string_free(&p.b);", 1);
    try expectAbsent(f, "cell_drop_Pair(&p);");
}

test "a moved field of a nested record releases the sibling, not the moved field" {
    // `p.inner.a` moves only part of `p.inner`. Recursing the partial drop
    // frees `p.inner.b` and skips `p.inner.a` (`m` owns that buffer). The
    // whole-inner glue and the outer glue stay absent: either would free
    // `m` a second time. Falsified 2026-09-16 by emitting
    // `cell_drop_Inner(&p.inner)` (and separately `cell_string_free(&p.inner.a)`)
    // on this program: AddressSanitizer double free of `m`, exit 134.
    // Restored; the sibling free is the remaining owning field, not glue.
    var e = try emitSource(
        \\pub struct Inner {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub struct Outer {
        \\    owned inner: Inner
        \\    owned tag: String
        \\}
        \\pub fn f() {
        \\  let owned p: Outer = Outer { inner: Inner { a: "x", b: "y" }, tag: "t" }
        \\  let owned m: String = p.inner.a
        \\}
    );
    defer e.deinit();
    try expectOccurrences(e.text, "cell_string_free(&p.inner.b);", 1);
    try expectAbsent(e.text, "cell_string_free(&p.inner.a);");
    try expectAbsent(e.text, "cell_drop_Inner(&p.inner);");
    try expectAbsent(e.text, "cell_drop_Outer(&p);");
    try expectOccurrences(e.text, "cell_string_free(&p.tag);", 1);
    try expectOccurrences(e.text, "cell_string_free(&m);", 1);
}

test "an unmoved arc local gets cell_arc_drop, by value with no ampersand" {
    var e = try emitSource(
        \\pub fn f(arc p: String) {
        \\  let arc s = p
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_drop(s);");
    try expectAbsent(e.text, "cell_arc_drop(&s)");
}

// ── arc retain insertion, OWNERSHIP.md R11 (task 4b) ────────────────────

test "an arc binding is a cell_arc_t and a literal initializer is boxed" {
    var e = try emitSource(
        \\pub fn f() {
        \\  let arc s = "x"
        \\}
    );
    defer e.deinit();
    // R11 rule 1: the box does not exist yet, so this is cell_arc_new by way
    // of the from_string helper, not a clone. cell_string_from_str copies the
    // literal's characters onto the heap, so the box owns them outright.
    try expectContains(e.text,
        \\  cell_arc_t s = cell_arc_from_string(cell_string_from_str(cell_str_from_parts("x", 1)));
    );
    try expectAbsent(e.text, "cell_arc_clone");
}

test "an arc place passed to an arc parameter is cloned at the call site" {
    var e = try emitSource(
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn f(arc n: String) -> Int {
        \\  return observe(arc n)
        \\}
    );
    defer e.deinit();
    // Written with the `arc n` prefix on purpose: that reaches codegen as an
    // `.annotated` wrapper, and a retain rule that failed to see through it
    // would silently skip the clone at exactly the spelling examples/arc.cell
    // uses. R11 rule 2. The parameter's own reference is released after
    // the call (R11 row 1), so the clone is what keeps the callee's alive.
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_observe(cell_arc_clone(n));");
    try expectBefore(f, "cell_observe(cell_arc_clone(n));", "cell_arc_drop(n);");
    try expectOccurrences(f, "cell_arc_drop(n);", 1);
}

test "an arc place passed to a shared parameter is NOT cloned" {
    var e = try emitSource(
        \\pub fn inspect(shared name: String) -> Int;
        \\pub fn f(arc n: String) -> Int {
        \\  return inspect(shared n)
        \\}
    );
    defer e.deinit();
    // R11's one deliberate non-retain. The borrow cannot escape the call
    // (R8), so the caller's own reference already covers it. This assertion
    // is the one that catches over-retaining, which the safety asymmetry
    // otherwise encourages, so the absence is asserted explicitly.
    try expectAbsent(e.text, "cell_arc_clone");
    const call = "cell_inspect(cell_string_as_str((const cell_string_t *)n.ptr));";
    try expectContains(e.text, call);
    // The parameter's own release comes after the borrow ends.
    try expectBefore(e.text, call, "cell_arc_drop(n);");
}

test "an arc place bound to a new arc binding is cloned, not re-boxed" {
    var e = try emitSource(
        \\pub fn f(arc p: String) {
        \\  let arc s = p
        \\}
    );
    defer e.deinit();
    // R11 rule 3: both p and s are live afterward, so s needs its own
    // reference. Re-boxing would build a second box over the same pointee and
    // free it twice.
    try expectContains(e.text, "cell_arc_t s = cell_arc_clone(p);");
    try expectAbsent(e.text, "cell_arc_from_string");
}

test "an arc place stored in a struct field is cloned" {
    var e = try emitSource(
        \\pub struct Session {
        \\  arc name: String
        \\}
        \\pub fn f(arc n: String) {
        \\  let owned s = Session { name: n }
        \\}
    );
    defer e.deinit();
    // R11 rule 4. The struct's own reference is released by its generated
    // glue at scope end since 2026-09-15 (row 2), so this retain is balanced
    // by `cell_drop_Session`; the retain itself is what this test pins.
    try expectContains(e.text, "(cell_Session){ .name = cell_arc_clone(n) }");
}

test "a call that returns arc is bound without a second retain" {
    var e = try emitSource(
        \\pub fn fresh() -> arc String;
        \\pub fn f() {
        \\  let arc b = fresh()
        \\}
    );
    defer e.deinit();
    // A returned arc arrives ALREADY retained (R11 release rule 3, and
    // cell_rt.h section 7), so cloning it here would leak one reference. The
    // retain is gated on the argument being a place for exactly this reason.
    try expectContains(e.text, "cell_arc_t b = cell_fresh();");
    try expectAbsent(e.text, "cell_arc_clone");
}

test "a returned arc local is retained before the drop that would free it" {
    var e = try emitSource(
        \\pub fn f() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
    );
    defer e.deinit();
    // Borrowck never makes an arc place dead (isDuplicable, R10 by design),
    // so a returned arc local is always still in pendingDrops and the drop
    // runs between the return temporary's initialization and the return
    // itself. Without the clone the count reaches zero and the caller
    // receives a freed box: exactly the use-after-free direction the
    // ownership rules forbid. R11 release rule 2's "except the one being
    // returned", paid for on the retain side because the drop pass is not
    // this task's to change.
    try expectContains(e.text,
        \\  cell_arc_t _cell_t0 = cell_arc_clone(s);
        \\  cell_arc_drop(s);
        \\  return _cell_t0;
    );
}

test "a value returned where the declared return type is arc IS boxed" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn lit() -> arc String {
        \\  return "x"
        \\}
        \\pub fn from_call() -> arc String {
        \\  return make()
        \\}
        \\pub fn from_list() -> arc [Int] {
        \\  return [1, 2, 3]
        \\}
    );
    defer e.deinit();
    // A `return` lowers a value into the function's DECLARED return type, so
    // it owes R11 rule 1 exactly as a `let`, a call argument, a struct field
    // and a list element do. It was the one such position that never asked,
    // and `emitArcConversion`'s doc comment asserted there was no second
    // position to keep in step. All three of these passed `cell check` and
    // were caught only by `cc`.
    //
    // Three forms, all run: a literal, a call result, and a list literal.
    // Each is boxed rather than cloned because the box does not exist yet.
    try expectContains(e.text, "return cell_arc_from_string(cell_string_from_str(cell_str_from_parts(\"x\", 1)));");
    try expectContains(e.text, "return cell_arc_from_string(cell_make());");
    try expectContains(e.text, "return cell_arc_from_slice(({");
}

test "an arc place returned where a non-arc type is declared stays a loud C type error" {
    var e = try emitSource(
        \\pub fn f(arc xs: [Int]) -> [Int] {
        \\  return xs
        \\}
        \\pub fn g(arc s: String) -> String {
        \\  return s
        \\}
    );
    defer e.deinit();
    // The direction that must NOT be routed through the conversion, and the
    // test that stops someone completing the symmetry. `unboxable` is TRUE
    // for `cell_slice_t`, so routing the unbox here would make `f` COMPILE,
    // emitting `(*(const cell_slice_t *)xs.ptr)`. docs/OWNERSHIP.md R10
    // documents that exact emission and why it is a double free: `owned [T]`
    // and `shared [T]` are the same C type, the callee frees the buffer, and
    // the box's drop glue frees the same buffer again. A refcount does not
    // govern the buffer, so no retain fixes it.
    //
    // borrowck refuses both returns as R10 make-unique positions today,
    // and this C type error is the second, independent refusal behind it.
    // Keeping it loud is the whole point. Since R11 row 1 the parameter is
    // released, so the return goes through a retained temporary, and the
    // temporary's C type is still the declared non-`arc` one.
    try expectContains(e.text, "cell_slice_t _cell_t0 = cell_arc_clone(xs);");
    try expectContains(e.text, "cell_string_t _cell_t1 = cell_arc_clone(s);");
    try expectAbsent(e.text, "unbox");
}

test "an owned String or list binding assigned to an arc var is moved into the box" {
    // R10's move-into-arc at assignment, implemented 2026-09-16. The
    // reassignment pre-drop releases the old box, then stores the new one,
    // which boxes the moved source; the source has no release of its own.
    var e = try emitSource(
        \\pub fn f(owned p: String) {
        \\  var arc a: String = "x"
        \\  a = p
        \\}
        \\pub fn g(owned xs: [Int]) {
        \\  var arc b: [Int] = [1]
        \\  b = xs
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_arc_t _cell_t0 = cell_arc_from_string(p);");
    try expectLineBefore(f, "cell_arc_drop(a);", "cell_arc_t _cell_t0 = cell_arc_from_string(p);");
    try expectLineBefore(f, "a = _cell_t0;", "cell_arc_drop(a);");
    try expectAbsent(f, "cell_string_free(&p);");
    const g = try fnDef(e.text, "g");
    try expectContains(g, "cell_arc_from_slice(xs);");
    try expectAbsent(g, "cell_slice_free(&xs);");
    try expectCompiles(e.text);
}

test "an owned String or list binding returned as arc is moved into the box" {
    // R10's move-into-arc at `return`, implemented 2026-09-16 after `let`.
    // Until then this test pinned `cell_arc_t _cell_t0 = p;`, a loud C type
    // error, because borrowck refused the program and the drop pass still
    // spelled a release for `p`. borrowck now accepts a whole `owned`
    // `String` or list binding returned directly and moves it (the ordinary
    // R2 return move), so `emitArcConversion`'s `isMovedOwnedBinding` boxes
    // exactly that place, nothing frees it, and the caller owns the box. No
    // retain: `returnedArcNeedsRetain` asks about an `arc`-typed place, and
    // `p` is a `String`.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() -> arc String {
        \\  let owned p = make()
        \\  return p
        \\}
        \\pub fn g(owned xs: [Int]) -> arc [Int] {
        \\  return xs
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "return cell_arc_from_string(p);");
    try expectAbsent(f, "cell_string_free(&p);");
    try expectAbsent(f, "cell_arc_clone");
    const g = try fnDef(e.text, "g");
    try expectContains(g, "return cell_arc_from_slice(xs);");
    try expectAbsent(g, "cell_slice_free(&xs);");
    try expectCompiles(e.text);
}

test "a returned arc parameter is retained once and released once" {
    var e = try emitSource(
        \\pub fn share(arc n: String) -> arc String {
        \\  return n
        \\}
    );
    defer e.deinit();
    // R11 rule 3 with row 1 closed: the parameter is released at scope
    // end like any `arc` local, so the returned reference is a fresh
    // retain taken before that release. 1 -> 2 -> 1, and the caller owns
    // the one left.
    const f = try fnDef(e.text, "share");
    try expectContains(f, "cell_arc_t _cell_t0 = cell_arc_clone(n);");
    try expectBefore(f, "cell_arc_clone(n);", "cell_arc_drop(n);");
    try expectOccurrences(f, "cell_arc_clone", 1);
    try expectOccurrences(f, "cell_arc_drop", 1);
    try expectContains(f, "return _cell_t0;");
}

test "a returned arc match-arm binding is retained: return inside a BLOCK arm body" {
    var e = try emitSource(
        \\pub fn f() -> arc String {
        \\  let arc s = "aaa"
        \\  match s { b => { return b } }
        \\  return s
        \\}
    );
    defer e.deinit();
    // THE REGRESSION TEST. `Local.is_param` was once removed after a derivation
    // concluded that a match-arm binding could not reach
    // `returnedArcNeedsRetain`. That derivation checked `b => return b`
    // (rejected: `return` is not an expression) and a trailing `match`
    // (rejected: not a return), and missed this third form: an arm body may
    // be a BLOCK, and a block's contents are statements. `cell check` exits 0
    // here, the emitted C compiled at -Werror, and the binding was returned
    // without a retain while `cell_arc_drop(s)` freed the box.
    // AddressSanitizer: heap-use-after-free, exit 134.
    try expectContains(e.text,
        \\    cell_arc_t _cell_t1 = cell_arc_clone(b);
        \\    cell_arc_drop(s);
        \\    return _cell_t1;
    );
}

test "a returned arc match-arm binding is retained: nested if inside a block arm body" {
    var e = try emitSource(
        \\pub fn f(shared c: Int) -> arc String {
        \\  let arc s = "aaa"
        \\  match s {
        \\    b => { if (c > 0) { return b } else { return b } }
        \\  }
        \\  return s
        \\}
    );
    defer e.deinit();
    // The second reachable form of the same escape. Both branches of the
    // nested `if` are returns of the arm binding, and both were bare.
    try expectContains(e.text,
        \\      cell_arc_t _cell_t1 = cell_arc_clone(b);
        \\      cell_arc_drop(s);
        \\      return _cell_t1;
    );
    try expectContains(e.text,
        \\      cell_arc_t _cell_t2 = cell_arc_clone(b);
        \\      cell_arc_drop(s);
        \\      return _cell_t2;
    );
}

test "an owned String or list binding stored in a struct-literal arc field is moved into the box" {
    // R10's move-into-arc at a struct-literal field, implemented
    // 2026-09-16. The literal takes the fresh box and the record's drop
    // glue releases it (R11 row 2); the source has no drop of its own
    // because borrowck moved it.
    var e = try emitSource(
        \\pub struct Box {
        \\  arc s: String
        \\  arc xs: [Int]
        \\}
        \\pub fn make() -> String;
        \\pub fn f(owned ys: [Int]) {
        \\  let owned a = make()
        \\  let owned b = Box { s: a, xs: ys }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, ".s = cell_arc_from_string(a)");
    try expectContains(f, ".xs = cell_arc_from_slice(ys)");
    try expectAbsent(f, "cell_string_free(&a);");
    try expectAbsent(f, "cell_slice_free(&ys);");
    try expectContains(f, "cell_drop_Box(");
    try expectCompiles(e.text);
}

test "an owned String or list binding passed to an arc parameter is moved into the box" {
    // R10's move-into-arc at a call argument, implemented 2026-09-16. The
    // box is handed to the callee at count 1 and the callee releases it
    // (R11 row 1), exactly as a boxed literal argument is; the source has
    // no drop of its own because borrowck moved it.
    var e = try emitSource(
        \\pub fn keep(arc s: String);
        \\pub fn keep_list(arc xs: [Int]);
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned a = make()
        \\  keep(a)
        \\}
        \\pub fn g(owned xs: [Int]) {
        \\  keep_list(xs)
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_keep(cell_arc_from_string(a));");
    try expectAbsent(f, "cell_string_free(&a);");
    try expectAbsent(f, "cell_arc_drop");
    const g = try fnDef(e.text, "g");
    try expectContains(g, "cell_keep_list(cell_arc_from_slice(xs));");
    try expectAbsent(g, "cell_slice_free(&xs);");
    try expectCompiles(e.text);
}

test "an owned String or list binding bound as arc is moved into the box" {
    // R10's move-into-arc at `let`, implemented 2026-09-16. Until then this
    // test pinned the opposite: `cell_arc_t b = a;`, a loud C type error,
    // because borrowck did not consume `a` and boxing it would have freed the
    // buffer twice. borrowck now moves `a` (`boxableOwnedBinding`), so the
    // box takes the header and `a` has no drop of its own.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn list() -> [Int];
        \\pub fn f() {
        \\  let owned a = make()
        \\  let arc b = a
        \\}
        \\pub fn g(owned xs: [Int]) {
        \\  let arc b = xs
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_arc_t b = cell_arc_from_string(a);");
    try expectAbsent(f, "cell_string_free(&a);");
    try expectOccurrences(f, "cell_arc_drop(b);", 1);
    const g = try fnDef(e.text, "g");
    try expectContains(g, "cell_arc_t b = cell_arc_from_slice(xs);");
    try expectAbsent(g, "cell_slice_free(&xs);");
    try expectCompiles(e.text);
}

test "a returned arc FIELD is retained when the function drops nothing" {
    var e = try emitSource(
        \\pub struct Session {
        \\  arc name: String
        \\  copy id: Int
        \\}
        \\pub fn peek(shared s: Session) -> arc String {
        \\  return s.name
        \\}
    );
    defer e.deinit();
    // The `pendingDrops` empty branch of `emitReturnStmt`, which used not to
    // consult the retain rule at all. R11 release rule 3 is categorical: a
    // returned `arc` is returned ALREADY RETAINED. Without the clone this
    // hands the caller the record's own reference, the caller releases it,
    // and the record is left pointing at a freed box: reproduced under
    // AddressSanitizer as a heap-use-after-free in `cell_arc_drop`.
    try expectContains(e.text, "  return cell_arc_clone(s->name);");
}

test "a returned arc FIELD is retained when the function also drops a local" {
    var e = try emitSource(
        \\pub struct Session {
        \\  arc name: String
        \\  copy id: Int
        \\}
        \\pub fn peek(shared s: Session) -> arc String {
        \\  let arc extra = "x"
        \\  return s.name
        \\}
    );
    defer e.deinit();
    // The other branch. Both are asserted because the first version of this
    // rule declined a `.field` root inside `returnedArcNeedsRetain` itself,
    // so BOTH branches emitted the bare field and only one of them was even
    // reached by the earlier tests.
    try expectContains(e.text,
        \\  cell_arc_t _cell_t0 = cell_arc_clone(s->name);
        \\  cell_arc_drop(extra);
        \\  return _cell_t0;
    );
}

test "a shadowed arc local is dropped once, naming the inner binding" {
    var e = try emitSource(
        \\pub fn shadowed(shared k: Int) -> Int {
        \\  let arc s = "outer"
        \\  if (k > 0) {
        \\    let arc s = "inner"
        \\    return 1
        \\  }
        \\  return 2
        \\}
    );
    defer e.deinit();
    // `emitDropFor` spells a drop by NAME, so two visible bindings sharing
    // one name emitted two identical `cell_arc_drop(s)` calls, both
    // resolving to the INNER `s`: a double free of the inner box and a leak
    // of the outer one. Measured under AddressSanitizer before the fix.
    // Suppressing the unnameable outer drop leaks it instead, which is the
    // correct side of this backend's asymmetry. Note `cell check` only WARNS
    // about shadowing, so nothing upstream prevents this source.
    try expectContains(e.text,
        \\    int64_t _cell_t0 = 1;
        \\    cell_arc_drop(s);
        \\    return _cell_t0;
    );
    try expectAbsent(e.text,
        \\    cell_arc_drop(s);
        \\    cell_arc_drop(s);
    );
}

test "an arc place flowing out of an if-expression branch is cloned" {
    var e = try emitSource(
        \\pub fn f(shared c: Int) {
        \\  let arc a = "aaa"
        \\  let arc b = "bbb"
        \\  let arc r = if (c > 0) { a } else { b }
        \\}
    );
    defer e.deinit();
    // A VALUE position, not a place position. The retain rules were derived
    // by searching return-position places, and this escaped all of them: the
    // branch assigned into the statement expression's temporary with a bare
    // `emitExpr`, so `r` aliased `a`'s box and scope exit released both.
    // Reproduced as a heap-use-after-free in `cell_arc_drop`, exit 134,
    // while `cell check` exited 0 and `cc -Wall -Wextra -Werror` was silent.
    try expectContains(e.text, "_cell_t0 = cell_arc_clone(a);");
    try expectContains(e.text, "_cell_t0 = cell_arc_clone(b);");
}

test "an arc place flowing out of a match arm in return position is cloned" {
    var e = try emitSource(
        \\pub fn pick(shared c: Int) -> arc String {
        \\  let arc a = "aaa"
        \\  return match c {
        \\    0 => a,
        \\    _ => a
        \\  }
        \\}
    );
    defer e.deinit();
    // The same leak of the same abstraction, one step further in: a `match`
    // IS valued in return position (an `if` there is rejected by typecheck),
    // but it is not a PLACE, so `returnedArcNeedsRetain` never fired and
    // `cell_arc_drop(a)` ran before the `return`. The retain belongs in the
    // arm, not at the return, because that is where the aliasing happens.
    try expectContains(e.text, "_cell_t1 = cell_arc_clone(a);");
    try expectContains(e.text,
        \\  cell_arc_drop(a);
        \\  return _cell_t0;
    );
}

test "an unbound arc call result is hoisted out of the call and released after it" {
    var e = try emitSource(
        \\pub fn inspect(shared name: String) -> Int;
        \\pub fn fresh() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
        \\pub fn f() -> Int {
        \\  return inspect(shared fresh())
        \\}
    );
    defer e.deinit();
    // R11's largest disclosed gap, measured at 2998 leaks / 63968 bytes over
    // 1000 iterations. `fresh` hands back a reference this frame owns, the
    // handle was never bound, and the emitted C read `.ptr` off the call's
    // return value and let the handle go.
    //
    // The whole statement expression is asserted, not just the drop, because
    // ORDER is what makes this safe rather than a use-after-free: the
    // unboxed `cell_str_t` points into the box's payload, so the drop must
    // come after `cell_inspect` returns. A drop emitted inside the argument
    // instead would free the characters the callee is reading.
    try expectContains(e.text,
        \\  return ({
        \\    cell_arc_t _cell_t1 = cell_fresh();
        \\    int64_t _cell_t2 = cell_inspect(cell_string_as_str((const cell_string_t *)_cell_t1.ptr));
        \\    cell_arc_drop(_cell_t1);
        \\    _cell_t2;
        \\  });
    );
}

test "two unbound arc call results in one call are both released, in reverse order" {
    var e = try emitSource(
        \\pub fn note(shared a: String, shared b: String);
        \\pub fn fresh() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
        \\pub fn f() {
        \\  note(shared fresh(), shared fresh())
        \\}
    );
    defer e.deinit();
    // Two things one argument cannot show. Both handles are hoisted rather
    // than only the first, and a VOID callee gets no result slot, so the
    // statement expression's value is the last drop's, which is also void.
    // `cc -Wall -Wextra -Werror` accepts that; a stray result temporary of
    // type `void` would not compile at all.
    try expectContains(e.text,
        \\    cell_arc_t _cell_t1 = cell_fresh();
        \\    cell_arc_t _cell_t2 = cell_fresh();
        \\    cell_note(cell_string_as_str((const cell_string_t *)_cell_t1.ptr), cell_string_as_str((const cell_string_t *)_cell_t2.ptr));
        \\    cell_arc_drop(_cell_t2);
        \\    cell_arc_drop(_cell_t1);
    );
}

test "a hoisted call whose value is DISCARDED emits no result slot" {
    var e = try emitSource(
        \\pub fn inspect(shared name: String) -> Int;
        \\pub fn fresh() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
        \\pub fn bare() {
        \\  inspect(shared fresh())
        \\}
    );
    defer e.deinit();
    // A regression the hoist itself introduced, caught by compiling a form
    // the corpus does not contain rather than by any gate. `-Wunused-value`
    // is part of `-Wall` and fires on a statement expression's trailing
    // result when the statement expression's own value is discarded, so
    // `int64_t _t = cell_inspect(...); ... _t;` made source that compiled
    // before the hoist stop compiling at `-Wall -Wextra -Werror`.
    //
    // With the value discarded there is nothing to carry across the drops,
    // so the result slot is omitted and this ends on a void `cell_arc_drop`
    // exactly as the void-callee case already did. The release is unchanged,
    // which is the part that must not regress.
    try expectContains(e.text,
        \\void cell_bare(void) {
        \\  ({
        \\    cell_arc_t _cell_t1 = cell_fresh();
        \\    cell_inspect(cell_string_as_str((const cell_string_t *)_cell_t1.ptr));
        \\    cell_arc_drop(_cell_t1);
        \\  });
        \\}
    );
}

test "a hoist nested inside another hoist composes, inner released first" {
    var e = try emitSource(
        \\pub fn inspect(shared name: String) -> Int;
        \\pub fn wrap(shared s: String) -> arc String {
        \\  let arc b = s
        \\  return b
        \\}
        \\pub fn fresh() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
        \\pub fn f() -> Int {
        \\  return inspect(shared wrap(shared fresh()))
        \\}
    );
    defer e.deinit();
    // The other form the corpus does not contain: a hoisted argument whose
    // own expression needs a hoist. It falls out of the recursion rather
    // than being handled, and the nesting is what pins that the inner
    // handle is released inside the initializer of the outer one, before
    // the outer call runs, and that each release names its own temporary.
    try expectContains(e.text,
        \\  return ({
        \\    cell_arc_t _cell_t2 = ({
        \\      cell_arc_t _cell_t3 = cell_fresh();
        \\      cell_arc_t _cell_t4 = cell_wrap(cell_string_as_str((const cell_string_t *)_cell_t3.ptr));
        \\      cell_arc_drop(_cell_t3);
        \\      _cell_t4;
        \\    });
        \\    int64_t _cell_t5 = cell_inspect(cell_string_as_str((const cell_string_t *)_cell_t2.ptr));
        \\    cell_arc_drop(_cell_t2);
        \\    _cell_t5;
        \\  });
    );
}

test "an arc call result unboxed OUTSIDE a call argument is NOT hoisted or released" {
    var e = try emitSource(
        \\pub fn fresh() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
        \\pub fn f() {
        \\  let shared v: String = fresh()
        \\}
    );
    defer e.deinit();
    // The boundary of the fix above, and the test that catches the next
    // person moving the hoist down into `emitArgLike` where every unbox
    // would reach it. `v` is a view INTO the box's payload and it outlives
    // the statement that produced it, so a `cell_arc_drop` here would leave
    // `v` dangling for the rest of the scope. This form still leaks the box,
    // deliberately: a leak is the safe side of this backend's asymmetry and
    // a use-after-free is not.
    //
    // The WHOLE function is spelled out rather than just the unbox, because
    // the absence is the claim and a `cell_arc_drop` could otherwise sit on
    // any line this assertion does not name. A bare
    // `expectAbsent("cell_arc_drop")` cannot say it: `fresh`'s own body is
    // in the same emitted module and legitimately contains one.
    try expectContains(e.text,
        \\void cell_f(void) {
        \\  cell_str_t v = cell_string_as_str((const cell_string_t *)cell_fresh().ptr);
        \\  (void)v;
        \\}
    );
    try expectAbsent(e.text, "cell_arc_drop(_cell_t");
}

test "an arc call result passed to an arc parameter is transferred, not hoisted" {
    var e = try emitSource(
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn fresh() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
        \\pub fn f() -> Int {
        \\  return observe(arc fresh())
        \\}
    );
    defer e.deinit();
    // The adjacent path the hoist must not touch. Here the reference is
    // HANDED to the callee, which releases it per cell_rt.h section 7, so
    // hoisting and dropping it in this frame would be a double free. The
    // absence is what pins that, and the whole function is spelled out to
    // say it: a bare `expectAbsent("cell_arc_drop")` would fail on `fresh`'s
    // own legitimate drop in the same emitted module.
    try expectContains(e.text,
        \\int64_t cell_f(void) {
        \\  return cell_observe(cell_fresh());
        \\}
    );
    try expectAbsent(e.text, "cell_arc_drop(_cell_t");
}

test "no drop is emitted after a body-terminating return" {
    var e = try emitSource(
        \\pub fn f() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
    );
    defer e.deinit();
    // `emitReturnStmt` already emits every drop that `return` owes, and
    // `emitFn` then ran `emitScopeDrops` again at the end of the body, so a
    // second identical `cell_arc_drop(s);` sat after the `return` where no
    // execution reaches it. Harmless under `-Wall -Wextra` (clang does not
    // put `-Wunreachable-code` in either), but it is emitted dead code.
    //
    // The positive half is what keeps this honest: an `expectAbsent` alone
    // would pass just as well if the drop pass stopped firing altogether.
    try expectContains(e.text,
        \\  cell_arc_drop(s);
        \\  return _cell_t0;
        \\}
    );
    try expectAbsent(e.text,
        \\  return _cell_t0;
        \\  cell_arc_drop(s);
    );
}

test "a list literal uses the DECLARED element type, making a mismatch loud" {
    var e = try emitSource(
        \\pub fn takes(shared zs: [String]) -> Int;
        \\pub fn build() -> Int {
        \\  let arc a = "hello"
        \\  let owned zs: [String] = [a, a]
        \\  return takes(shared zs)
        \\}
    );
    defer e.deinit();
    // `cell_slice_t` is type-erased, so a list literal is the one expression
    // whose element C type cannot be recovered from the expression itself,
    // and getting it wrong is SILENT. This program built a buffer of
    // `cell_arc_t` against a declared `[String]`, passed `cell check`,
    // compiled at `-Wall -Wextra -Werror`, and stayed clean under
    // AddressSanitizer, because reinterpreting a refcount box pointer as a
    // string is type confusion rather than a memory error. Both types happen
    // to be 24 bytes here, so even the stride matched and only the fields
    // lied: a `shared [String]` callee read `len = 105690555222384`.
    //
    // The fix does not make this program work, it makes it FAIL LOUDLY. An
    // element of an `owned [String]` is a make-unique position, R10 refuses
    // four such positions, and this is a fifth one R10 does not reach; the C
    // type error is what refuses it. Both halves are asserted, because the
    // stride alone would pass with the elements still assigned unconverted.
    try expectContains(e.text, "cell_slice_alloc(sizeof(cell_string_t), 2)");
    try expectContains(e.text, "cell_string_t _cell_t1 = (cell_string_t){0};");
    try expectAbsent(e.text, "sizeof(cell_arc_t)");
    // The retain is gone with the conversion: `emitArgLike` now declines
    // arc-to-owned-String instead of cloning into a mistyped slot, which is
    // also the two-references-per-list leak that rode on top of the
    // confusion.
    try expectAbsent(e.text, "cell_arc_clone");
}

test "a list literal reached through a match arm also uses the declared element type" {
    var e = try emitSource(
        \\pub fn takes(shared zs: [String]) -> Int;
        \\pub fn f(copy c: Int) -> Int {
        \\  let arc a = "hello"
        \\  let owned zs: [String] = match c {
        \\    0 => [a],
        \\    _ => [a]
        \\  }
        \\  return takes(shared zs)
        \\}
    );
    defer e.deinit();
    // The form that made the first fix incomplete, and it is reachable
    // rather than hypothetical: this passes `cell check` today. The literal
    // arrives through a value-position `match`, so it reaches
    // `emitValueInto`'s leaf rather than `emitArgLike`'s, and with only the
    // argument-position fix it inferred `cell_arc_t` all over again and
    // compiled clean. Same axis as every other finding in this file: one
    // form of a construct was handled and a second was not.
    try expectContains(e.text, "cell_slice_alloc(sizeof(cell_string_t), 1)");
    try expectAbsent(e.text, "sizeof(cell_arc_t)");
}

test "a list literal with no declared type still infers its element type" {
    var e = try emitSource(
        \\pub fn takes(shared zs: [Int]) -> Int;
        \\pub fn f() -> Int {
        \\  let owned ys = [4, 5]
        \\  return takes(shared ys)
        \\}
    );
    defer e.deinit();
    // The other side of the same change, and the one that would catch a fix
    // that simply required an annotation. Nothing declares an element type
    // here, so inference from the first item is still the answer and the
    // emitted C is unchanged.
    try expectContains(e.text, "cell_slice_alloc(sizeof(int64_t), 2)");
}

test "a declared element type survives shared and exclusive ownership" {
    var e = try emitSource(
        \\pub fn takes(shared zs: [String]) -> Int;
        \\pub fn f() -> Int {
        \\  let shared zs: [String] = ["a"]
        \\  return takes(shared zs)
        \\}
    );
    defer e.deinit();
    // `applyOwnership` and `pointerTo` build NEW CTypes, and both had to be
    // taught to carry `elem` across. If either drops it, the declared
    // element vanishes for every borrowed list and this silently reverts to
    // inference, which is how the defect looked in the first place.
    try expectContains(e.text, "cell_slice_alloc(sizeof(cell_string_t), 1)");
    try expectAbsent(e.text, "sizeof(cell_str_t)");
}

test "an owned String call result bound as arc IS boxed" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let arc b = make()
        \\}
    );
    defer e.deinit();
    // The complement of the test above: a call result is not a local the drop
    // pass will also free, so moving it into the box is safe and correct.
    try expectContains(e.text, "cell_arc_t b = cell_arc_from_string(cell_make());");
}

test "an unmoved owned [Byte] local gets cell_slice_free" {
    var e = try emitSource(
        \\pub fn f() {
        \\  let owned xs = [1, 2]
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_slice_free(&xs);");
}

test "drops happen before an early return, not only at the end of the body" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f(shared c: Bool) -> Int {
        \\  let owned s = make()
        \\  if (c) {
        \\    return 1
        \\  }
        \\  return 2
        \\}
    );
    defer e.deinit();
    // The early return, nested inside the `if`, one indent level deeper.
    try expectContains(e.text,
        \\    cell_string_free(&s);
        \\    return _cell_t0;
    );
    // The end-of-body return, back at the function's own indent level. A
    // plain literal return still needs the return-value temporary: the
    // drop has to run between computing the value and returning it (see
    // `emitReturnStmt`), and that ordering does not depend on whether this
    // particular return expression happens to read `s`.
    try expectContains(e.text,
        \\  cell_string_free(&s);
        \\  return _cell_t1;
    );
}

test "drops run in reverse declaration order" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned a = make()
        \\  let owned b = make()
        \\  let owned c = make()
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\  cell_string_free(&c);
        \\  cell_string_free(&b);
        \\  cell_string_free(&a);
    );
}

// ── block-scoped release, OWNERSHIP.md R11 row 4 (closed 2026-09-15) ────

test "an arc local declared in a while body is released at the end of every iteration" {
    // The exact shape of examples/leaks/block_scoped_local.cell, which
    // measured 3000 leaks over 1000 iterations before this drop existed.
    var e = try emitSource(
        \\pub fn f() {
        \\  var i = 0
        \\  while i < 1000 {
        \\    let arc a = "leaked-block-local"
        \\    i = i + 1
        \\  }
        \\}
    );
    defer e.deinit();
    // Once, inside the loop, after the body's last statement.
    try expectOccurrences(e.text, "cell_arc_drop(a);", 1);
    try expectContains(e.text,
        \\          i = (i + 1);
        \\          cell_arc_drop(a);
        \\  }
    );
}

test "an owned local declared in a bare block is freed at that block's closing brace" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  {
        \\    let owned s = make()
        \\  }
        \\}
    );
    defer e.deinit();
    try expectOccurrences(e.text, "cell_string_free(&s);", 1);
    try expectContains(e.text,
        \\    cell_string_free(&s);
        \\  }
        \\}
    );
}

test "a break drops the loop body's locals before jumping, and the normal exit drops them too" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f(shared k: Int) {
        \\  var i = 0
        \\  while i < 10 {
        \\    let owned s = make()
        \\    if (i == k) {
        \\      break
        \\    }
        \\    i = i + 1
        \\  }
        \\}
    );
    defer e.deinit();
    // The `break` sits inside an `if` branch inside the body: it must drop
    // since the LOOP's mark, not the branch's, so `s` is released there.
    try expectLineBefore(e.text, "break;", "cell_string_free(&s);");
    // And the `if` branch itself ends in a jump, so it emits no second drop.
    try expectOccurrences(e.text, "cell_string_free(&s);", 2);
}

test "a continue drops the loop body's locals before jumping" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f(shared k: Int) {
        \\  var i = 0
        \\  while i < 10 {
        \\    i = i + 1
        \\    let owned s = make()
        \\    if (i == k) {
        \\      continue
        \\    }
        \\  }
        \\}
    );
    defer e.deinit();
    try expectLineBefore(e.text, "continue;", "cell_string_free(&s);");
    try expectOccurrences(e.text, "cell_string_free(&s);", 2);
}

test "a loop-body local moved into an owned parameter is not dropped at the body's end" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn take(owned s: String);
        \\pub fn f() {
        \\  var i = 0
        \\  while i < 10 {
        \\    let owned s = make()
        \\    take(s)
        \\    i = i + 1
        \\  }
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free(&s)");
}

test "an arc local declared in a statement-position match arm body is released at the arm's end" {
    // OWNERSHIP.md row 4 named the match-arm form beside the block form.
    var e = try emitSource(
        \\pub fn f(shared k: Int) {
        \\  match k {
        \\    1 => {
        \\      let arc a = "arm-local"
        \\    },
        \\    _ => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectOccurrences(e.text, "cell_arc_drop(a);", 1);
}

test "an arc local that is a VALUE-position block's tail is released after the clone" {
    // CLOSED 2026-09-15 (evening): `emitValueBlockDrops`. The destination is
    // `arc`, so the tail was lowered as `cell_arc_clone(a)`, and `a`'s own
    // reference is dropped after it: 1 -> 2 -> 1, and `r`'s release frees
    // the box. examples/leaks/value_block_local.cell measures this at 0 on
    // both witnesses; it read 3000 before.
    var e = try emitSource(
        \\pub fn f() {
        \\  let arc r = {
        \\    let arc a = "inner"
        \\    a
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_t r = ({");
    try expectLineBefore(e.text, "cell_arc_drop(a);", "_cell_t0 = cell_arc_clone(a);");
    try expectContains(e.text, "cell_arc_drop(r);");
}

test "an owned local a VALUE-position block does not use in its tail is released, and the moved tail is not" {
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn f() {
        \\  let owned r = {
        \\    let owned junk = make()
        \\    let owned t = make()
        \\    t
        \\  }
        \\}
    );
    defer e.deinit();
    try expectLineBefore(e.text, "cell_string_free(&junk);", "_cell_t0 = t;");
    try expectAbsent(e.text, "cell_string_free(&t);");
    try expectContains(e.text, "cell_string_free(&r);");
}

test "an owned local READ as a list element's block tail is not released: the element would dangle" {
    // The list element site reads a block tail rather than moving it, and
    // slice elements are never released, so `t` is copied by value into the
    // buffer. Freeing it here would leave the element pointing at freed
    // memory; ASan cannot see it (elements are never read back), so this
    // assertion is the only witness. The leak is the disclosed list-element
    // gap, unchanged.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn f() {
        \\  let owned xs: [String] = [{
        \\    let owned t = make()
        \\    t
        \\  }]
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "_cell_t2 = t;");
    try expectAbsent(e.text, "cell_string_free(&t);");
}

test "a local the VALUE-position block's tail borrows is not released before the copy outside the braces" {
    // `cell_string_from_str(...)` wraps the statement expression, so the
    // view `_cell_t0` must still point at live memory at the closing brace.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn mk() -> String {
        \\  return {
        \\    let owned t = make()
        \\    &t
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "_cell_t0 = cell_string_as_str(&t);");
    try expectAbsent(e.text, "cell_string_free(&t);");
}

test "a return block whose tail is an outer owned place moves it: no drop of the source" {
    // Borrowck records the move through `openBlockTail`, so `pendingDrops`
    // at the `return` skips `s1`; the block hands the buffer to the caller
    // once. Measured 2026-09-15 under ASan with the malloc counter:
    // ALLOC=1 FREE=1 LIVE=0 for this shape, for the block-local tail below,
    // and for the plain `return s1` control.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn mk() -> String {
        \\    let owned s1 = make()
        \\    return { s1 }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "_cell_t0 = s1;");
    try expectAbsent(e.text, "cell_string_free(&s1);");
}

test "a call argument block whose tail is the block's own owned local frees nothing itself" {
    // `t` is moved into the parameter, so the value-position block emits no
    // drop for it and the callee owns the buffer (the callee releases it
    // since R11 row 1; this test pins only that the caller does not).
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn eat(owned s: String) { }
        \\pub fn main() {
        \\    eat(owned {
        \\        let owned t = make()
        \\        t
        \\    })
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_eat(({");
    try expectContains(e.text, "_cell_t0 = t;");
    try expectAbsent(e.text, "cell_string_free(&t);");
}

test "a local a VALUE-position block's tail reaches through a borrow alias is not released" {
    // 85570d6 freed `t` here: the tail names `v`, not `t`, and a by-name
    // use scan cannot see that `v` is a view of `t`. `let shared s = { ... }`
    // then held a dangling view (the emitted C had `cell_string_free(&t)`
    // before `_cell_t0` left the braces). `tailReach` follows the block's
    // own `let`s to a fixpoint, so `t` is reached and kept. The leak of `t`
    // is the exclusion's stated cost.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn inspect(shared s: String) -> Int { return 1 }
        \\pub fn f() {
        \\  let shared s = {
        \\    let owned t = make()
        \\    let shared v = &t
        \\    v
        \\  }
        \\  inspect(s)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "_cell_t0 = v;");
    try expectAbsent(e.text, "cell_string_free(&t);");
}

test "tail reach is transitive through two aliases and an assignment, and unrelated locals still drop" {
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn inspect(shared s: String) -> Int { return 1 }
        \\pub fn f() {
        \\  let shared s = {
        \\    let owned junk = make()
        \\    let owned t = make()
        \\    let shared v = &t
        \\    var shared w = v
        \\    w = v
        \\    w
        \\  }
        \\  inspect(s)
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free(&t);");
    try expectLineBefore(e.text, "cell_string_free(&junk);", "_cell_t0 = w;");
}

test "reassigning an arc var evaluates the value into a temporary, drops the old box, then stores" {
    // R11 row 5, CLOSED 2026-09-15. examples/leaks/reassigned_var.cell read
    // 3000 on both witnesses before and 0 after; the gate went red on the
    // old pin before the constant moved.
    var e = try emitSource(
        \\pub fn inspect(shared s: String) -> Int { return 1 }
        \\pub fn f() {
        \\  var arc v = "one"
        \\  v = "two"
        \\  inspect(v)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_t _cell_t0 = cell_arc_from_string(");
    try expectLineBefore(e.text, "cell_arc_drop(v);", "cell_arc_t _cell_t0 = cell_arc_from_string(cell_string_from_str(cell_str_from_parts(\"two\", 3)));");
    try expectLineBefore(e.text, "v = _cell_t0;", "cell_arc_drop(v);");
}

test "reassigning a never-moved owned var releases the old value first" {
    // Until 2026-09-16 this test pinned the opposite (no temporary, no free
    // before the store), because `[s]` copied the header without marking `s`
    // moved and a pre-drop would have freed under that element. borrowck
    // refuses that element since c314a0e, so the `arc` reassignment pre-drop
    // now covers a never-moved `owned` `String` or list var too.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn list() -> [Int] { return [1] }
        \\pub fn f() {
        \\  var owned s = make()
        \\  s = make()
        \\}
        \\pub fn g() {
        \\  var owned xs = list()
        \\  xs = list()
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    // The value goes into a temporary first (`s = mk(s)` reads the old
    // value), then the old value is released, then the store.
    try expectLineBefore(f, "cell_string_free(&s);", "cell_string_t _cell_t2 = cell_make();");
    try expectLineBefore(f, "s = _cell_t2;", "cell_string_free(&s);");
    try expectOccurrences(f, "cell_string_free(&s);", 2);
    const g = try fnDef(e.text, "g");
    try expectOccurrences(g, "cell_slice_free(&xs);", 2);
    try expectCompiles(e.text);
}

test "a field store releases the old owned String or list field first" {
    // examples/leaks/field_store_old.cell, pinned at 1000 until 2026-09-21:
    // `t.name = v` never released the old value. Same shape as the
    // whole-binding pre-drop: temporary, release, store.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn list() -> [Int] { return [1] }
        \\pub struct Tag {
        \\  owned name: String
        \\  owned xs: [Int]
        \\}
        \\pub fn f() {
        \\  var owned t = Tag { name: make(), xs: list() }
        \\  t.name = make()
        \\  t.xs = list()
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&t.name);", 1);
    try expectOccurrences(f, "cell_slice_free(&t.xs);", 1);
    try expectLineBefore(f, "t.name = _cell_t", "cell_string_free(&t.name);");
    try expectCompiles(e.text);
}

test "a field store keeps the leak when the field, or any path of its root in a loop, was moved" {
    // Three guards, each the leak direction. `revive`: the old value went to
    // `take` (R3a revival), so a pre-drop would double free it. `in_loop`: a
    // move of ANY path of `t` inside the enclosing `while` body invalidates
    // the store, conservatively (the back edge could carry it). `through`:
    // an `exclusive` root; the old value belongs to the referent and the
    // shape was not measured.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn take(owned s: String);
        \\pub struct Tag {
        \\  owned name: String
        \\  owned other: String
        \\}
        \\pub fn revive() {
        \\  var owned t = Tag { name: make(), other: make() }
        \\  take(t.name)
        \\  t.name = make()
        \\}
        \\pub fn in_loop(copy c: Int) {
        \\  var owned t = Tag { name: make(), other: make() }
        \\  var i = 0
        \\  while i < c {
        \\    t.name = make()
        \\    take(t.other)
        \\    t.other = make()
        \\    i = i + 1
        \\  }
        \\}
        \\pub fn through(exclusive t: Tag) {
        \\  t.name = make()
        \\}
    );
    defer e.deinit();
    // The scope-end drop still releases the revived field once, after the
    // store, so what must be absent is the PRE-drop shape: the value into a
    // temporary, then a free before the store.
    for ([_][]const u8{ "revive", "in_loop" }) |name| {
        const body = try fnDef(e.text, name);
        try expectAbsent(body, "_cell_t");
        try expectOccurrences(body, "cell_string_free(&t.name);", 1);
        // The one free is the scope-end release: it comes AFTER the store.
        const store = std.mem.indexOf(u8, body, "t.name = cell_make();").?;
        const free = std.mem.indexOf(u8, body, "cell_string_free(&t.name);").?;
        try std.testing.expect(store < free);
    }
    try expectAbsent(try fnDef(e.text, "through"), "cell_string_free(");
    try expectCompiles(e.text);
}

test "reassigning a moved owned var keeps no pre-drop: its old value is gone" {
    // R3a revival and a move on one branch. borrowck's `wasMoved` is
    // permanent and branch-conservative, so both answer "moved" and no
    // release is emitted before the store: the old value belongs to `take`.
    // Removing that guard was measured as an AddressSanitizer double free
    // (exit 134). The reassigned value is live at the end of both bodies,
    // so the scope-end drop releases it (borrowck's `exit_liveness`), and
    // that is the only release: it comes after the store.
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn revive() {
        \\  var owned v: String = "a"
        \\  take(v)
        \\  v = "b"
        \\}
        \\pub fn branch(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    take(v)
        \\  }
        \\  v = "b"
        \\}
    );
    defer e.deinit();
    for ([_][]const u8{ "revive", "branch" }) |name| {
        const body = try fnDef(e.text, name);
        try expectOccurrences(body, "cell_string_free(&v);", 1);
        try expectLineBefore(body, "cell_string_free(&v);", "v = cell_string_from_str(cell_str_from_parts(\"b\", 1));");
        try expectAbsent(body, "_cell_t0");
    }
    try expectCompiles(e.text);
}

test "a revived var is released at the exits where borrowck saw it live" {
    // borrowck's `exit_liveness`, 2026-09-16. Before it, `wasMoved` was
    // permanent for the scope-end drop, so every one of these leaked the
    // revived value (measured with the gate's malloc counter).
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn at_end() {
        \\  var owned v: String = "a"
        \\  take(v)
        \\  v = "b"
        \\}
        \\pub fn at_return(copy c: Int) -> Int {
        \\  var owned v: String = "a"
        \\  take(v)
        \\  if c > 0 {
        \\    return 2
        \\  }
        \\  v = "b"
        \\  return 3
        \\}
        \\pub fn in_block() {
        \\  {
        \\    var owned v: String = "a"
        \\    take(v)
        \\    v = "b"
        \\  }
        \\}
        \\pub fn param(owned s: String) {
        \\  take(s)
        \\  s = "p"
        \\}
        \\pub fn list() {
        \\  var owned xs: [Int] = [1, 2]
        \\  var owned ys: [Int] = xs
        \\  xs = [3]
        \\}
        \\pub fn loop_local(copy n: Int) {
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    var owned v: String = "a"
        \\    take(v)
        \\    if i > n {
        \\      continue
        \\    }
        \\    v = "b"
        \\  }
        \\}
    );
    defer e.deinit();
    const at_end = try fnDef(e.text, "at_end");
    try expectOccurrences(at_end, "cell_string_free(&v);", 1);
    const at_return = try fnDef(e.text, "at_return");
    // Only the `return 3` path, after the revival; `return 2` has no value.
    try expectOccurrences(at_return, "cell_string_free(&v);", 1);
    try expectLineBefore(at_return, "cell_string_free(&v);", "int64_t _cell_t0 = 3;");
    try expectContains(at_return, "return 2;");
    const in_block = try fnDef(e.text, "in_block");
    try expectOccurrences(in_block, "cell_string_free(&v);", 1);
    const param = try fnDef(e.text, "param");
    try expectOccurrences(param, "cell_string_free(&s);", 1);
    const list = try fnDef(e.text, "list");
    try expectOccurrences(list, "cell_slice_free(&xs);", 1);
    try expectOccurrences(list, "cell_slice_free(&ys);", 1);
    // Declared inside the body, so the back edge carries none of its moves:
    // the body end releases it, the `continue` path does not.
    const loop_local = try fnDef(e.text, "loop_local");
    try expectOccurrences(loop_local, "cell_string_free(&v);", 1);
    try expectLineBefore(loop_local, "cell_string_free(&v);", "v = cell_string_from_str(cell_str_from_parts(\"b\", 1));");
    try expectCompiles(e.text);
}

test "a revived var stays unreleased where the path may not hold a value" {
    // Each shape is accepted by borrowck and would be a double free if the
    // revival were trusted. `break_after` and `back_edge` were measured as
    // AddressSanitizer double frees (exit 134) with `loop_moved` and with
    // the in-loop invalidation removed, respectively.
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn one_branch(copy c: Int) {
        \\  var owned v: String = "a"
        \\  take(v)
        \\  if c > 0 {
        \\    v = "b"
        \\  }
        \\}
        \\pub fn moved_again() {
        \\  var owned v: String = "a"
        \\  take(v)
        \\  v = "b"
        \\  take(v)
        \\}
        \\pub fn break_after(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    if i > n {
        \\      break
        \\    }
        \\    v = "b"
        \\  }
        \\}
        // back_edge is refused by `cell check` since 2026-09-16 (R2.a at a `continue`); kept only for the drop decision.
        \\pub fn back_edge() {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    if i > 1 {
        \\      return
        \\    }
        \\    take(v)
        \\    if i < 2 {
        \\      continue
        \\    }
        \\    v = "b"
        \\  }
        \\}
    );
    defer e.deinit();
    // one_branch: revival on the then path is released at that branch's end.
    const one = try fnDef(e.text, "one_branch");
    try expectOccurrences(one, "cell_string_free(&v);", 1);
    for ([_][]const u8{ "moved_again", "back_edge" }) |name| {
        const body = try fnDef(e.text, name);
        try expectAbsent(body, "cell_string_free(&v);");
    }
    // break_after is the skip-revival `break` (after_loop_skip, 2026-09-17):
    // released after the loop only behind the jump that keeps the dead
    // `break` path away from it. A plain `break` would reach the release.
    const after = try fnDef(e.text, "break_after");
    try expectOccurrences(after, "cell_string_free(&v);", 1);
    try expectAbsent(after, "break;");
    try expectLineBefore(after, "cell_skip_0:;", "cell_string_free(&v);");
    try expectCompiles(e.text);
}

test "an outer var revived across a while is released after the loop" {
    // R16 after_loop, 2026-09-16. `loop_moved` still poisons in-loop jumps
    // and the function-end `block_end`; the drop is the one after `}`.
    // Guards falsified under AddressSanitizer (exit 134) then restored:
    // ignoring a dead `.jump` (`take(v); if i > n { break }; v = "b"`)
    // double-frees because C `break` runs this drop; emitting it for
    // unmoved locals double-frees with function-end; dropping the outer
    // var at `continue` (`take(v); v = "b"; continue`) is a use-after-free
    // on the next iteration; treating a condition move as live
    // (`while consume(v) { v = make() }`) double-frees because the last
    // failing condition already took `v`.
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn cross() {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    take(v)
        \\    v = "b"
        \\    i = i + 1
        \\  }
        \\}
        \\pub fn revival_then_break(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    v = "b"
        \\    if i > n {
        \\      break
        \\    }
        \\  }
        \\}
        \\pub fn skip_revival_break(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    if i > n {
        \\      break
        \\    }
        \\    v = "b"
        \\  }
        \\}
        \\pub fn untouched() {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\  }
        \\}
    );
    defer e.deinit();
    const cross = try fnDef(e.text, "cross");
    try expectOccurrences(cross, "cell_string_free(&v);", 1);
    try expectContains(cross, "}\n  cell_string_free(&v);\n}");
    const revival_break = try fnDef(e.text, "revival_then_break");
    try expectOccurrences(revival_break, "cell_string_free(&v);", 1);
    try expectContains(revival_break, "}\n  cell_string_free(&v);\n}");
    try expectAbsent(revival_break, "cell_string_free(&v);\n      break;");
    // skip-revival break (after_loop_skip, 2026-09-17): released after the
    // loop, and the dead `break` jumps past that release. A plain `break`
    // there was an AddressSanitizer double free (exit 134), measured.
    const skip = try fnDef(e.text, "skip_revival_break");
    try expectOccurrences(skip, "cell_string_free(&v);", 1);
    try expectContains(skip, "goto cell_skip_");
    try expectAbsent(skip, "break;");
    try expectContains(skip, "}\n  cell_string_free(&v);\n  cell_skip_");
    // Unmoved: function-end drops it. after_loop must not, or this is a
    // double free with the scope-end drop (measured, exit 134).
    try expectOccurrences(try fnDef(e.text, "untouched"), "cell_string_free(&v);", 1);
    try expectCompiles(e.text);
}

test "a skip-revival break is lowered as a jump only where every release agrees" {
    // after_loop_skip guards, 2026-09-17. Each negative keeps the leak (no
    // release, no goto): the var belongs to an enclosing loop's block and
    // the inner `break` is dead (`nested`; the outer loop sees a dead jump
    // that is not its own `break`), two vars are dead at different breaks
    // (`mixed`), or the loop also has a var released on every path
    // (`with_plain`); in the last two no single label serves every break.
    // `live_and_dead` and `record` are positives: a `break` that still
    // holds the value stays a `break` and runs the release, and a record
    // moved whole is released through its drop glue.
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn nested(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var j = 0
        \\  while j < 2 {
        \\    j = j + 1
        \\    var i = 0
        \\    while i < 3 {
        \\      i = i + 1
        \\      take(v)
        \\      if i > n {
        \\        break
        \\      }
        \\      v = "b"
        \\    }
        \\    v = "c"
        \\  }
        \\}
        \\pub fn live_and_dead(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    if i > 5 {
        \\      break
        \\    }
        \\    take(v)
        \\    if i > n {
        \\      break
        \\    }
        \\    v = "b"
        \\  }
        \\}
        \\pub fn mixed(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var owned w: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    if i > n {
        \\      break
        \\    }
        \\    v = "b"
        \\    take(w)
        \\    if i > 1 {
        \\      break
        \\    }
        \\    w = "b"
        \\  }
        \\}
        \\pub struct P { a: String, b: String }
        \\pub fn take_p(owned p: P);
        \\pub fn record(copy n: Int, owned p0: P) {
        \\  var owned q: P = p0
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take_p(q)
        \\    if i > n {
        \\      break
        \\    }
        \\    q = P { a: "x", b: "y" }
        \\  }
        \\}
        \\pub fn with_plain(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var owned w: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(w)
        \\    w = "b"
        \\    take(v)
        \\    if i > n {
        \\      break
        \\    }
        \\    v = "b"
        \\  }
        \\}
    );
    defer e.deinit();
    const nested = try fnDef(e.text, "nested");
    try expectAbsent(nested, "goto");
    try expectAbsent(nested, "cell_string_free(&v);");
    // A `break` still holding the value is ordinary and runs the release;
    // only the dead one jumps past it.
    const both = try fnDef(e.text, "live_and_dead");
    try expectOccurrences(both, "cell_string_free(&v);", 1);
    try expectOccurrences(both, "break;", 1);
    try expectOccurrences(both, "goto cell_skip_", 1);
    const mixed = try fnDef(e.text, "mixed");
    try expectAbsent(mixed, "goto");
    try expectAbsent(mixed, "cell_string_free(&v);");
    try expectAbsent(mixed, "cell_string_free(&w);");
    // A whole-moved record takes the same route through its drop glue.
    const rec = try fnDef(e.text, "record");
    try expectOccurrences(rec, "cell_drop_P(&q);", 1);
    try expectOccurrences(rec, "goto cell_skip_", 1);
    try expectAbsent(rec, "break;");
    const plain = try fnDef(e.text, "with_plain");
    try expectAbsent(plain, "goto");
    try expectAbsent(plain, "cell_string_free(&v);");
    try expectCompiles(e.text);
}

test "a return inside a loop releases an outer var only where it holds a value" {
    // 2026-09-17: an accepted loop's `return` records stay live. `before`
    // (live on every iteration: R2.a) and `after` (revived) release `v`
    // at the return; `between` (moved, not yet revived) must not. The
    // rejected-loop guard is pinned by `back_edge` above.
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn before(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    if i > n {
        \\      return
        \\    }
        \\    take(v)
        \\    v = "b"
        \\  }
        \\}
        \\pub fn after(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    v = "b"
        \\    if i > n {
        \\      return
        \\    }
        \\  }
        \\}
        \\pub fn between(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    if i > n {
        \\      return
        \\    }
        \\    v = "b"
        \\  }
        \\}
    );
    defer e.deinit();
    for ([_][]const u8{ "before", "after" }) |name| {
        const body = try fnDef(e.text, name);
        try expectLineBefore(body, "return;", "cell_string_free(&v);");
    }
    const between = try fnDef(e.text, "between");
    try expectLineBefore(between, "return;", "if (i > n) {");
    try expectCompiles(e.text);
}

test "indexing a list reads with the stride the list was built with" {
    // 2026-09-17. Declared, inferred and borrowed lists each pick the
    // bounds-checked reader for their element type.
    var e = try emitSource(
        \\pub fn first(shared xs: [Float]) -> Float? {
        \\  return xs[0]
        \\}
        \\pub fn main() {
        \\  let owned ns = [40, 2]
        \\  let copy a = ns[1]
        \\  let owned bs: [Bool] = [true]
        \\  let copy b = bs[0]
        \\}
    );
    defer e.deinit();
    try expectContains(try fnDef(e.text, "first"), "cell_list_f64_at(");
    const main_body = try fnDef(e.text, "main");
    try expectContains(main_body, "cell_opt_i64_t a = cell_list_i64_at(ns, 1);");
    try expectContains(main_body, "cell_opt_bool_t b = cell_list_bool_at(bs, 0);");
    try expectAbsent(e.text, "cell_index_of_");
    try expectCompiles(e.text);
}

const owning_result_prelude =
    \\pub fn take(owned s: String);
    \\pub fn view(shared s: String) -> Int;
    \\pub fn read() -> Result<String, Int32>;
    \\
;

test "an owning String Result has its own instance and per-module release glue" {
    // Owning String in Ok (2026-09-17).
    var e = try emitSource(owning_result_prelude ++
        \\pub fn relay() -> Result<String, Int32> {
        \\  return read()
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_res_string_i32_t cell_read(void);");
    try expectOccurrences(e.text, "static inline __attribute__((unused)) void cell_drop_res_string_i32(cell_res_string_i32_t *r);", 1);
    try expectContains(e.text, "if (r->ok) cell_string_free(&r->as.ok);");
    try expectCompiles(e.text);

    var plain = try emitSource(
        \\pub fn f(copy r: Result<Int, Int32>) -> Int {
        \\  return 0
        \\}
    );
    defer plain.deinit();
    try expectAbsent(plain.text, "cell_drop_res_");
}

test "Ok moves a resolved owning operand and copies one it was not told moved" {
    var e = try emitSource(owning_result_prelude ++
        \\pub fn moved(owned s: String) -> Result<String, Int32> {
        \\  return Ok(s)
        \\}
        \\pub fn make() -> String;
        \\pub fn copied(copy c: Int) -> Result<String, Int32> {
        \\  let owned s = if c > 0 { make() } else { make() }
        \\  return Ok(s)
        \\}
    );
    defer e.deinit();
    const m = try fnDef(e.text, "moved");
    try expectContains(m, "cell_res_string_i32_ok(s)");
    try expectAbsent(m, "cell_string_free(&s);");
    // borrowck cannot type `s` here, so it only read it; the header is
    // copied into the Result and `s` keeps (and releases) its own.
    const c = try fnDef(e.text, "copied");
    try expectContains(c, "cell_res_string_i32_ok(cell_string_clone(&s))");
    try expectContains(c, "cell_string_free(&s);");
    try expectCompiles(e.text);
}

test "Ok(owned ..) binds the payload and the Result is released on the other arm" {
    var e = try emitSource(owning_result_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) {
        \\  match r {
        \\    Ok(owned x) => take(x),
        \\    Err(_) => {},
        \\  }
        \\}
        \\pub fn g(owned r: Result<String, Int32>) -> Int {
        \\  return match r {
        \\    Ok(owned x) => view(x),
        \\    Err(_) => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_string_t x = _cell_t");
    try expectContains(f, ".as.ok;");
    try expectAbsent(f, "cell_string_free(&x);");
    try expectOccurrences(f, "cell_drop_res_string_i32(&r);", 1);
    const g = try fnDef(e.text, "g");
    try expectOccurrences(g, "cell_string_free(&x);", 1);
    try expectOccurrences(g, "cell_drop_res_string_i32(&r);", 1);
    try expectCompiles(e.text);
}

test "Ok(shared ..) binds a view and the Result is released after the match" {
    var e = try emitSource(owning_result_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) -> Int {
        \\  let n = match r {
        \\    Ok(shared x) => view(x),
        \\    Err(_) => 0,
        \\  }
        \\  return n
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_str_t x = cell_string_as_str(&_cell_t");
    try expectAbsent(f, "cell_string_free(&x);");
    try expectOccurrences(f, "cell_drop_res_string_i32(&r);", 1);
    try expectCompiles(e.text);
}

test "a temporary owning Result is released in every arm that does not take it" {
    var e = try emitSource(owning_result_prelude ++
        \\pub fn f() -> Int {
        \\  return match read() {
        \\    Ok(owned x) => view(x),
        \\    Err(_) => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_drop_res_string_i32(&_cell_t", 1);
    try expectCompiles(e.text);
}

test "reassigning an owning Result var releases the old value first" {
    var e = try emitSource(owning_result_prelude ++
        \\pub fn f() {
        \\  var owned r: Result<String, Int32> = read()
        \\  r = read()
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_drop_res_string_i32(&r);", 2);
    try expectCompiles(e.text);
}

test "an owning String error is bound, released per side, and copied when unresolved" {
    // Sub-project 3 (2026-09-17).
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn view(shared s: String) -> Int;
        \\pub fn make() -> String;
        \\pub fn read() -> Result<Int, String>;
        \\pub fn both() -> Result<String, String>;
        \\pub fn owned_arm(owned r: Result<Int, String>) -> Int {
        \\  return match r {
        \\    Ok(v) => v,
        \\    Err(owned e) => view(e),
        \\  }
        \\}
        \\pub fn shared_arm(owned r: Result<Int, String>) -> Int {
        \\  return match r {
        \\    Ok(v) => v,
        \\    Err(shared e) => view(e),
        \\  }
        \\}
        \\pub fn temp() -> Int {
        \\  return match read() {
        \\    Ok(v) => v,
        \\    Err(owned e) => view(e),
        \\  }
        \\}
        \\pub fn two() -> Int {
        \\  return match both() {
        \\    Ok(owned a) => view(a),
        \\    Err(shared b) => view(b),
        \\  }
        \\}
        \\pub fn unresolved(copy c: Int) -> Result<Int, String> {
        \\  let owned s = if c > 0 { make() } else { make() }
        \\  return Err(s)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "if (r->ok) cell_string_free(&r->as.ok); else cell_string_free(&r->as.err);");
    const oa = try fnDef(e.text, "owned_arm");
    try expectContains(oa, "cell_string_t e = _cell_t");
    try expectContains(oa, ".as.err;");
    try expectOccurrences(oa, "cell_string_free(&e);", 1);
    try expectOccurrences(oa, "cell_drop_res_i64_string(&r);", 1);
    const sa = try fnDef(e.text, "shared_arm");
    try expectContains(sa, "cell_str_t e = cell_string_as_str(&_cell_t");
    try expectOccurrences(sa, "cell_drop_res_i64_string(&r);", 1);
    const tp = try fnDef(e.text, "temp");
    try expectOccurrences(tp, "cell_drop_res_i64_string(&_cell_t", 1);
    const tw = try fnDef(e.text, "two");
    try expectOccurrences(tw, "cell_drop_res_string_string(&_cell_t", 1);
    const ur = try fnDef(e.text, "unresolved");
    try expectContains(ur, "cell_res_i64_string_err(cell_string_clone(&s))");
    try expectCompiles(e.text);
}

test "an owning String? is its own instance, bound, released and copied when unresolved" {
    // Sub-project 4 (2026-09-17).
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn view(shared s: String) -> Int;
        \\pub fn make() -> String;
        \\pub fn find() -> String?;
        \\pub fn wrap(owned s: String) -> String? {
        \\  return Some(s)
        \\}
        \\pub fn owned_arm(owned o: String?) -> Int {
        \\  return match o {
        \\    Some(owned x) => view(x),
        \\    None => 0,
        \\  }
        \\}
        \\pub fn shared_arm(owned o: String?) -> Int {
        \\  return match o {
        \\    Some(shared x) => view(x),
        \\    None => 0,
        \\  }
        \\}
        \\pub fn temp() -> Int {
        \\  return match find() {
        \\    Some(shared x) => view(x),
        \\    None => 0,
        \\  }
        \\}
        \\pub fn reassign() {
        \\  var owned o: String? = find()
        \\  o = find()
        \\}
        \\pub fn unresolved(copy c: Int) -> String? {
        \\  let owned s = if c > 0 { make() } else { make() }
        \\  return Some(s)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_opt_string_t cell_find(void);");
    try expectOccurrences(e.text, "static inline __attribute__((unused)) void cell_drop_opt_string(cell_opt_string_t *r);", 1);
    try expectContains(e.text, "if (r->has_value) cell_string_free(&r->value);");
    const w = try fnDef(e.text, "wrap");
    try expectContains(w, "cell_opt_string_some(s)");
    try expectAbsent(w, "cell_string_free(&s);");
    const oa = try fnDef(e.text, "owned_arm");
    try expectContains(oa, "cell_string_t x = _cell_t");
    try expectContains(oa, ".value;");
    try expectOccurrences(oa, "cell_string_free(&x);", 1);
    try expectOccurrences(oa, "cell_drop_opt_string(&o);", 1);
    const sa = try fnDef(e.text, "shared_arm");
    try expectContains(sa, "cell_str_t x = cell_string_as_str(&_cell_t");
    try expectOccurrences(sa, "cell_drop_opt_string(&o);", 1);
    // Neither arm takes the payload, so both release the temporary (the
    // glue is a no-op on `None`).
    try expectOccurrences(try fnDef(e.text, "temp"), "cell_drop_opt_string(&_cell_t", 2);
    try expectOccurrences(try fnDef(e.text, "reassign"), "cell_drop_opt_string(&o);", 2);
    try expectContains(try fnDef(e.text, "unresolved"), "cell_opt_string_some(cell_string_clone(&s))");
    try expectCompiles(e.text);
}

test "a temporary owning scrutinee is released when its arm leaves early" {
    // 2026-09-17: the residual sub-projects 2-4 recorded. A `return` releases
    // every untaken temporary; a `break`/`continue` those created inside the
    // loop it leaves; an arm that took the payload releases nothing.
    var e = try emitSource(
        \\pub fn find() -> String?;
        \\pub fn view(shared s: String) -> Int;
        \\pub fn take(owned s: String);
        \\pub fn early() -> Int {
        \\  match find() {
        \\    Some(shared x) => {
        \\      return view(x)
        \\    },
        \\    None => {},
        \\  }
        \\  return 0
        \\}
        \\pub fn taken() -> Int {
        \\  match find() {
        \\    Some(owned x) => {
        \\      take(x)
        \\      return 1
        \\    },
        \\    None => {},
        \\  }
        \\  return 0
        \\}
        \\pub fn loop_exit(copy n: Int) -> Int {
        \\  var i = 0
        \\  while i < n {
        \\    i = i + 1
        \\    match find() {
        \\      Some(_) => {
        \\        break
        \\      },
        \\      None => {
        \\        continue
        \\      },
        \\    }
        \\  }
        \\  return i
        \\}
    );
    defer e.deinit();
    const early = try fnDef(e.text, "early");
    // Before the early return (after its value is computed), and at the end
    // of the None arm.
    try expectOccurrences(early, "cell_drop_opt_string(&_cell_t", 2);
    const tk = try fnDef(e.text, "taken");
    try expectOccurrences(tk, "cell_drop_opt_string(&_cell_t", 1);
    const lx = try fnDef(e.text, "loop_exit");
    try expectOccurrences(lx, "cell_drop_opt_string(&_cell_t", 2);
    try expectCompiles(e.text);
}

test "the owned reassignment pre-drop is decided per store, not per binding" {
    // borrowck's `assign_liveness`, 2026-09-16. A move AFTER the store no
    // longer blocks it; a move BEFORE it (revival) or IN the right side
    // still does; a revived var's NEXT store releases the revived value; and
    // the scope-end drop releases a revived value (`exit_liveness`).
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn pass(owned s: String) -> String { return s }
        \\pub fn later() {
        \\  var owned v: String = "a"
        \\  v = "b"
        \\  take(v)
        \\}
        \\pub fn selfmove() {
        \\  var owned v: String = "a"
        \\  v = pass(v)
        \\}
        \\pub fn chain() {
        \\  var owned v: String = "a"
        \\  take(v)
        \\  v = "b"
        \\  v = "c"
        \\}
    );
    defer e.deinit();
    const later = try fnDef(e.text, "later");
    try expectOccurrences(later, "cell_string_free(&v);", 1);
    try expectLineBefore(later, "cell_take(v);", "v = _cell_t0;");
    // `pass` hands ownership back, so the store is a revival: no pre-drop
    // before it, and since `exit_liveness` (2026-09-16) exactly one release
    // at scope end, after it. This line asserted `expectAbsent` while the
    // revived value still leaked.
    const selfmove = try fnDef(e.text, "selfmove");
    try expectOccurrences(selfmove, "cell_string_free(&v);", 1);
    try expectLineBefore(selfmove, "cell_string_free(&v);", "v = cell_pass(v);");
    const chain = try fnDef(e.text, "chain");
    // Of the stores only "c" pre-drops, and what it releases is "b"; then
    // the scope end releases "c", which is live there (`exit_liveness`).
    // Two frees, one per value that is still owned when its slot is reused
    // or left; before 2026-09-16 the second was absent and "c" leaked.
    try expectOccurrences(chain, "cell_string_free(&v);", 2);
    try expectContains(chain, "v = cell_string_from_str(cell_str_from_parts(\"b\", 1));");
    try expectLineBefore(chain, "cell_string_free(&v);", "cell_string_t _cell_t1 = cell_string_from_str(cell_str_from_parts(\"c\", 1));");
    try expectContains(chain, "v = _cell_t1;\n  cell_string_free(&v);\n}");
    try expectCompiles(e.text);
}

test "a store inside a while body that also moves its target keeps no pre-drop" {
    // The back edge can carry a move made later in the body, including one
    // followed by `continue`, to a store earlier in the next iteration.
    // Without the loop invalidation this exact program was an
    // AddressSanitizer double free (exit 134), measured.
    // loopy is refused by `cell check` since 2026-09-16 (R2.a at a `continue`); kept only for the drop decision.
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn loopy() {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    v = "x"
        \\    i = i + 1
        \\    if i > 1 {
        \\      take(v)
        \\      continue
        \\    }
        \\    v = "y"
        \\  }
        \\}
        \\pub fn untouched() {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    v = "x"
        \\    i = i + 1
        \\  }
        \\}
    );
    defer e.deinit();
    try expectAbsent(try fnDef(e.text, "loopy"), "cell_string_free(&v);");
    // A loop that never moves its target still releases on every store,
    // plus once at scope end.
    try expectOccurrences(try fnDef(e.text, "untouched"), "cell_string_free(&v);", 2);
    try expectCompiles(e.text);
}

test "a droppable var declared without an initializer is zero-initialized" {
    // Before this the scope-end drop ran on garbage, and the reassignment
    // pre-drop would have too.
    var e = try emitSource(
        \\pub fn f() {
        \\  var arc v: String
        \\  v = "one"
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_t v = (cell_arc_t){0};");
    try expectLineBefore(e.text, "v = _cell_t0;", "cell_arc_drop(v);");
}

test "an arc field store is not a reassignment pre-drop: the record is released by its glue, not per store (row 2)" {
    // Two claims, and until 2026-09-15 this test made only the first and its
    // title made a second that is no longer true. A FIELD store does not
    // pre-drop the old box (that is the stated field-store residual: "one"
    // is overwritten unreleased). The record itself IS dropped now, through
    // R11 row 2's glue at scope end, which releases whatever the field holds
    // at that point ("two"). Asserting the glue call is what keeps this test
    // from passing vacuously: the old needle `cell_arc_drop(b.s)` was never
    // how any drop of a record would be spelled.
    var e = try emitSource(
        \\struct Box { arc s: String }
        \\pub fn f() {
        \\  var owned b = Box { s: "one" }
        \\  b.s = "two"
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_arc_drop(b.s);");
    try expectContains(e.text, "cell_drop_Box(&b);");
    try expectContains(e.text, "  cell_arc_drop(r->s);\n");
}

test "a value-position block's tail resolves through a nested block, and later bindings keep their ids" {
    // Two things at once. The nested block: inference has to push the outer
    // block's `let` as scratch and recurse for the inner one. The id
    // agreement: scratch locals bypass `pushLocal`, so `next_binding_id`
    // must not move during inference; if it drifted, `z` would no longer
    // match borrowck's name for its id, `pushLocal` would clear `droppable`,
    // and `z`'s drop would vanish.
    var e = try emitSource(
        \\pub fn f() {
        \\  let arc r = {
        \\    let arc a = "outer"
        \\    {
        \\      let arc b = a
        \\      b
        \\    }
        \\  }
        \\  let arc z = "after"
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_t r = ({");
    try expectContains(e.text, "cell_arc_drop(z);");
    try expectContains(e.text, "cell_arc_drop(r);");
}

test "an owned block tail is moved into the let, and bindings after the block keep their ids" {
    // borrowck checks the block's statements inside `openBlockTail` (the
    // `let`-only `checkOwnedLetFromBlock` at the time this test was written)
    // and never through `checkExpr(v)`, so `t` must be declared exactly once
    // on its side, in the order codegen declares it. If borrowck declared it
    // twice, `z`'s id would no longer match its name, `pushLocal`'s Debug
    // assert would fire under `zig build test`, and in release `droppable`
    // would clear and `z`'s drop would vanish.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned s = {
        \\    let owned t = make()
        \\    t
        \\  }
        \\  let arc z = "after"
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t s = ({");
    try expectOccurrences(e.text, "cell_string_free(&s);", 1);
    try expectAbsent(e.text, "cell_string_free(&t)");
    try expectContains(e.text, "cell_arc_drop(z);");
}

test "R11 row 2: a struct with an arc field gets drop glue and its local is released" {
    // The pinned fixture's shape (`examples/leaks/struct_arc_field.cell`),
    // which measured 3000 leaks on both witnesses before this and 0 after.
    var e = try emitSource(
        \\struct Session { arc name: String, copy id: Int }
        \\pub fn f() {
        \\  let owned sess = Session { name: "session", id: 1 }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "static inline __attribute__((unused)) void cell_drop_Session(cell_Session *r);");
    try expectContains(e.text, "static inline __attribute__((unused)) void cell_drop_Session(cell_Session *r) {\n  cell_arc_drop(r->name);\n}");
    try expectContains(e.text, "cell_drop_Session(&sess);");
}

test "R11 row 2: nested record glue recurses, and releases fields in reverse order" {
    // `tag` is declared after `inner`, so it is released first, matching
    // `pendingDrops`'s reverse-declaration convention for locals. The nested
    // call resolves whatever order the structs were written in, because
    // every prototype precedes every definition.
    var e = try emitSource(
        \\struct Outer { owned inner: Box, arc tag: String }
        \\struct Box { owned s: String, copy n: Int }
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned o = Outer { inner: Box { s: make(), n: 1 }, tag: "t" }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "void cell_drop_Outer(cell_Outer *r);\nstatic inline __attribute__((unused)) void cell_drop_Box(cell_Box *r);");
    try expectContains(e.text, "  cell_arc_drop(r->tag);\n  cell_drop_Box(&r->inner);\n}");
    try expectContains(e.text, "  cell_string_free(&r->s);\n}");
    try expectContains(e.text, "cell_drop_Outer(&o);");
}

test "R11 row 2: a scalar-only struct gets no glue and no drop" {
    // THE OVER-EMISSION CONTROL. `needsDrop` keys on the fields, not on the
    // shape: a record with nothing to release is not a drop candidate, and
    // emitting glue for it would be an empty function per struct.
    var e = try emitSource(
        \\struct Point { copy x: Int, copy y: Int }
        \\pub fn f() {
        \\  let owned p = Point { x: 1, y: 2 }
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_drop_Point");
}

test "R11 row 2: a struct that is moved, partially moved, or returned is not dropped" {
    // Three shapes `pendingDrops` must skip, each measured under ASan with the
    // malloc counter at the tree that added the glue. A partial move marks
    // the whole binding moved in borrowck, so the record is skipped entirely:
    // that leaks `n`'s nothing and `s`'s nothing here (the field went to
    // `eat`), and would leak a SECOND owning field if there were one, which
    // is the stated residual and the safe direction. A move into an `owned`
    // parameter hands the record to the callee, which releases it (R11 row
    // 1, so `take`'s own body does drop `b`). A returned local is the
    // caller's.
    var e = try emitSource(
        \\struct Box { owned s: String, copy n: Int }
        \\pub fn make() -> String;
        \\pub fn eat(owned s: String) { }
        \\pub fn take(owned b: Box) { }
        \\pub fn partial() {
        \\  let owned b = Box { s: make(), n: 1 }
        \\  eat(owned b.s)
        \\}
        \\pub fn moved() {
        \\  let owned b = Box { s: make(), n: 1 }
        \\  take(b)
        \\}
        \\pub fn returned() -> Box {
        \\  let owned b = Box { s: make(), n: 1 }
        \\  return b
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_eat(b.s);");
    try expectContains(e.text, "cell_take(b);");
    try expectContains(e.text, "return b;");
    try expectAbsent(try fnDef(e.text, "partial"), "cell_drop_Box(&b);");
    try expectAbsent(try fnDef(e.text, "moved"), "cell_drop_Box(&b);");
    try expectAbsent(try fnDef(e.text, "returned"), "cell_drop_Box(&b);");
    try expectOccurrences(try fnDef(e.text, "take"), "cell_drop_Box(&b);", 1);
}

test "R11 row 2: an uninitialized droppable struct var is zero-initialized, then released" {
    // Same rule as the three runtime shapes: the glue over a zeroed record is
    // three no-ops, so the scope-end drop is safe before the first write.
    var e = try emitSource(
        \\struct Box { owned s: String, copy n: Int }
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  var owned b: Box
        \\  b = Box { s: make(), n: 1 }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_Box b = (cell_Box){0};");
    try expectContains(e.text, "cell_drop_Box(&b);");
}

test "a shared or copy local is never dropped" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let shared a = make()
        \\  let copy b = make()
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free");
    try expectAbsent(e.text, "cell_slice_free");
    try expectAbsent(e.text, "cell_arc_drop");
}

test "R11 row 1: an unmoved owned parameter is released by the callee" {
    // runtime/cell_rt.h section 7: the caller relinquishes an `owned`
    // argument, so the callee frees it. Before 2026-09-16 no parameter was
    // ever dropped and every such argument leaked.
    var e = try emitSource(
        \\pub fn f(owned s: String) {
        \\}
    );
    defer e.deinit();
    try expectOccurrences(try fnDef(e.text, "f"), "cell_string_free(&s);", 1);
}

test "R11 row 1: an owned parameter moved onward or returned is not released" {
    // The double-free direction: once the parameter is moved, the new
    // holder frees it, so this frame must not.
    var e = try emitSource(
        \\pub fn sink(owned s: String) -> Int;
        \\pub fn onward(owned s: String) -> Int {
        \\  return sink(owned s)
        \\}
        \\pub fn back(owned s: String) -> String {
        \\  return s
        \\}
        \\pub fn tail(owned s: String) -> String {
        \\  return { s }
        \\}
        \\pub fn rebind(owned s: String) -> String {
        \\  let owned t: String = s
        \\  return t
        \\}
    );
    defer e.deinit();
    for ([_][]const u8{ "onward", "back", "tail", "rebind" }) |name| {
        try expectAbsent(try fnDef(e.text, name), "cell_string_free");
    }
}

test "R11 row 1: shared and copy parameters are still never released" {
    var e = try emitSource(
        \\pub fn f(shared s: String, copy n: Int) -> Int {
        \\  return n
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free");
    try expectAbsent(e.text, "cell_arc_drop");
}

test "a program that allocates and frees an owned local runs clean under cc" {
    // Owned `String` locals cannot appear in this test: constructing one
    // from a string literal hits a pre-existing, unrelated codegen gap
    // (there is no coercion from the literal's `cell_str_t` view into an
    // owned `cell_string_t`; task 4b added exactly that coercion for `arc`,
    // by way of cell_arc_from_string, and deliberately did not touch
    // `owned`), so `cc` would reject the emitted C for a reason that has
    // nothing to do with drops.
    // `[Int]` sidesteps it: every ownership mode of a list lowers to the
    // same `cell_slice_t`, so there is no literal-to-owned coercion to be
    // missing.
    //
    // `kept` is unmoved and must be freed once. `given` is moved into
    // `sink` (an `owned` parameter), so it must NOT be freed here; `sink`
    // frees it (R11 row 1, since 2026-09-16), which makes this program a
    // double-free detector for the parameter release too. What this test
    // actually proves
    // is that the emitted drop compiles and runs without corrupting the
    // heap: a real double free of `kept`'s buffer would either abort
    // (verified directly, by fault injection, on a smaller program in the
    // task report) or corrupt allocator state in a way `cc`'s own leak/
    // sanitizer-free build would not necessarily catch, so the clean exit
    // and the expected `println` output are the actual assertions.
    var e = try emitSource(
        \\pub fn make_list() -> [Int] {
        \\  return [1, 2, 3]
        \\}
        \\pub fn sink(owned xs: [Int]) {
        \\}
        \\pub fn main() {
        \\  let owned kept = make_list()
        \\  let owned given = make_list()
        \\  sink(owned given)
        \\  println("ok")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_slice_free(&kept);");
    try expectAbsent(e.text, "cell_slice_free(&given)");

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{cwd_buf[0..cwd_len]});
    defer gpa.free(include);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{cwd_buf[0..cwd_len]});
    defer gpa.free(rt_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-std=c11", "-Wall", "-Wextra", "body.c", rt_c, "-I", include, "-o", "body" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(cc_result.stdout);
    defer gpa.free(cc_result.stderr);
    if (!cc_result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ cc_result.stderr, e.text });
        return error.CcRejectedEmittedC;
    }

    const run_result = try std.process.run(gpa, io, .{
        .argv = &.{"./body"},
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    if (!run_result.term.success()) {
        std.debug.print(
            "emitted program did not exit cleanly (a double free typically aborts):\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("ok\n", run_result.stdout);
}

test "an arc program's retains and releases balance when compiled and run" {
    // The assertion that matters most for R11. Emitted-text tests can only
    // show that a clone appears where one was expected; this one links the
    // emitted C against the REAL runtime and reads the strong count back out
    // at run time, so an unbalanced retain shows up as a wrong number rather
    // than as text that happens to look right.
    //
    // The printed 7 decomposes as 2 + 5 and both halves are measurements:
    //
    //   `fresh` boxes a literal (count 1), retains it for the return so the
    //   scope drop cannot free it (1 -> 2 -> 1), and hands back that single
    //   reference. `a` therefore holds count 1.
    //
    //   `observe(arc a)` clones at the call site, so the host sees 2 and
    //   returns 2, then releases its own reference per cell_rt.h section 7,
    //   taking the count back to 1. Drop the return retain in
    //   `emitReturnStmt` and `fresh` frees the box before returning it: the
    //   count read is then garbage and this program tends to abort rather
    //   than print. Drop the call-site clone and the host reads 1, printing
    //   6 instead of 7.
    //
    //   `inspect(shared a)` must NOT clone (R8), and returns the borrowed
    //   view's length, 5. An unwanted retain here would leave the final
    //   cell_arc_drop at count 1 and leak the box, which the number cannot
    //   see; `tools/check.sh`'s note and a run under `leaks` cover that side.
    //
    // The two bodyless declarations are defined by examples/arc_host.c, the
    // same host examples/arc.cell uses, because only a C definition can read
    // cell_arc_strong_count.
    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn inspect(shared name: String) -> Int;
        \\pub fn fresh() -> arc String {
        \\  let arc s = "boxed"
        \\  return s
        \\}
        \\pub fn main() {
        \\  let arc a = fresh()
        \\  let copy n = observe(arc a)
        \\  let copy m = inspect(shared a)
        \\  print_int(n + m)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_clone(s)");
    try expectContains(e.text, "cell_observe(cell_arc_clone(a))");
    try expectContains(e.text, "cell_arc_drop(a);");

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const root = cwd_buf[0..cwd_len];
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{root});
    defer gpa.free(include);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{root});
    defer gpa.free(rt_c);
    const host_c = try std.fmt.allocPrint(gpa, "{s}/examples/arc_host.c", .{root});
    defer gpa.free(host_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-std=c11", "-Wall", "-Wextra", "body.c", host_c, rt_c, "-I", include, "-o", "body" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(cc_result.stdout);
    defer gpa.free(cc_result.stderr);
    if (!cc_result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ cc_result.stderr, e.text });
        return error.CcRejectedEmittedC;
    }

    const run_result = try std.process.run(gpa, io, .{
        .argv = &.{"./body"},
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    if (!run_result.term.success()) {
        std.debug.print(
            "emitted arc program did not exit cleanly (a released-too-early box typically aborts):\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("7\n", run_result.stdout);
}

test "a returned arc field survives the caller releasing it, compiled and run" {
    // The execution counterpart to the two emitted-text field tests. It is
    // the one that would have caught the defect: the bare `return s->name;`
    // compiled clean under `-Wall -Wextra -Werror` and passed `cell check`,
    // so only running it and reading the count back distinguishes a correct
    // retain from a missing one.
    //
    // The printed 4 decomposes as: `label` boxes the literal (1); the struct
    // literal clones it into the `arc` field (2); `peek` returns
    // `cell_arc_clone(s->name)` (3); the call site clones again for the
    // `arc` parameter (4), which is the count the host reports before
    // releasing its own reference (3). Delete the field retain and this
    // program prints 3, measured on a deliberately broken binary rather
    // than predicted.
    //
    // Two things this program does NOT show, stated because the number
    // alone invites the wrong conclusion from both. It does not show a
    // crash: broken, it still exits 0 and AddressSanitizer stays silent,
    // because nothing dereferences the record's now-dangling field
    // afterwards. Reaching the actual use-after-free takes a second `peek`
    // (see the task report's F4). And when this was written it did not show
    // a clean heap either: the record's own reference was never released,
    // since this backend did not drop a `record` shape, so the program ended
    // with the box alive at count 1. Since 2026-09-15 row 2's glue releases
    // it and `examples/arc_return_field.cell` measures 0 on both witnesses
    // under the gate's recipe; the sentence is kept because it is why
    // `examples/arc.cell` rather than this test carries the zero-leak
    // evidence. It is also the correct side of the asymmetry: before the
    // retain, the same program left the record pointing at a box the
    // caller had already freed.
    var e = try emitSource(
        \\pub struct Session {
        \\  arc name: String
        \\  copy id: Int
        \\}
        \\pub fn print_int(copy value: Int);
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn peek(shared s: Session) -> arc String {
        \\  return s.name
        \\}
        \\pub fn main() {
        \\  let arc label = "session"
        \\  let owned sess = Session { name: label, id: 1 }
        \\  let arc got = peek(shared sess)
        \\  let copy n = observe(arc got)
        \\  print_int(n)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "return cell_arc_clone(s->name);");

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const root = cwd_buf[0..cwd_len];
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{root});
    defer gpa.free(include);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{root});
    defer gpa.free(rt_c);
    const host_c = try std.fmt.allocPrint(gpa, "{s}/examples/arc_host.c", .{root});
    defer gpa.free(host_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-std=c11", "-Wall", "-Wextra", "body.c", host_c, rt_c, "-I", include, "-o", "body" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(cc_result.stdout);
    defer gpa.free(cc_result.stderr);
    if (!cc_result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ cc_result.stderr, e.text });
        return error.CcRejectedEmittedC;
    }

    const run_result = try std.process.run(gpa, io, .{
        .argv = &.{"./body"},
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    if (!run_result.term.success()) {
        std.debug.print(
            "emitted program did not exit cleanly:\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("4\n", run_result.stdout);
}

test "arc values flowing through if and match branches balance, compiled and run" {
    // The execution counterpart to the two value-position tests. Both defects
    // they cover were silent at every stage that is cheap to check: `cell
    // check` exited 0, `cc -Wall -Wextra -Werror` was silent, and only
    // running the program showed the heap-use-after-free.
    //
    // `pick` returns through a `match` arm and `main` selects through an
    // `if`, so one program exercises both value paths. Unlike the emitted-text
    // tests, this source passes `cell check` (exit 0), which is why `chosen`
    // is never passed to a typed parameter: typecheck gives EVERY
    // if-expression the type `()`, so an if-derived binding flowing into a
    // `String` parameter is rejected for an unrelated, pre-existing reason.
    // The un-annotated `let` is the form that is reachable, and it is the
    // form the defect was reported in.
    //
    // The printed 2 is the strong count `observe` was handed, and it is a
    // measurement: `a` is boxed at 1, the match arm clones for the return (2),
    // `pick`'s scope drop takes it back to 1, the call site clones for the
    // `arc` parameter (2) which is what the host reports before releasing
    // (1), and the `if` branch then clones into `chosen` (2). The three scope
    // drops take both boxes to zero; verified separately under `leaks` as
    // 0 leaks for 0 total leaked bytes and clean under ASan and UBSan.
    //
    // Remove the match-arm clone and `pick` returns a box it already freed.
    // Remove the if-branch clone and `chosen` aliases `got`, so the scope
    // drops release the same box twice. Either way this aborts instead of
    // printing, which is what `error.ProgramCrashed` reports.
    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn pick(shared c: Int) -> arc String {
        \\  let arc a = "aaa"
        \\  return match c {
        \\    0 => a,
        \\    _ => a
        \\  }
        \\}
        \\pub fn main() {
        \\  let arc got = pick(shared 0)
        \\  let copy n = observe(arc got)
        \\  let arc other = "bbb"
        \\  let arc chosen = if (1 > 0) { got } else { other }
        \\  print_int(n)
        \\}
    );
    defer e.deinit();

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const root = cwd_buf[0..cwd_len];
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{root});
    defer gpa.free(include);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{root});
    defer gpa.free(rt_c);
    const host_c = try std.fmt.allocPrint(gpa, "{s}/examples/arc_host.c", .{root});
    defer gpa.free(host_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-std=c11", "-Wall", "-Wextra", "body.c", host_c, rt_c, "-I", include, "-o", "body" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(cc_result.stdout);
    defer gpa.free(cc_result.stderr);
    if (!cc_result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ cc_result.stderr, e.text });
        return error.CcRejectedEmittedC;
    }

    const run_result = try std.process.run(gpa, io, .{
        .argv = &.{"./body"},
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    if (!run_result.term.success()) {
        std.debug.print(
            "emitted program did not exit cleanly (an unretained alias aborts here):\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("2\n", run_result.stdout);
}

test "a returned arc match-arm binding survives its scrutinee's release, run" {
    // The execution counterpart to the two block-arm-body tests. Without the
    // retain this aborts: `cell_arc_drop(s)` takes the box to zero and the
    // caller then clones a freed handle, which is where AddressSanitizer
    // reported the heap-use-after-free.
    //
    // The printed 2 is a measurement. `s` is boxed at 1, the arm binding is a
    // bitwise copy of it, the return clones (2), `f`'s scope drop of `s`
    // takes it back to 1, the call site clones for the `arc` parameter (2),
    // which is what the host reports before releasing (1), and `got`'s scope
    // drop takes it to zero.
    var e = try emitSource(
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn print_int(copy value: Int);
        \\pub fn f() -> arc String {
        \\  let arc s = "aaa"
        \\  match s { b => { return b } }
        \\  return s
        \\}
        \\pub fn main() {
        \\  let arc got = f()
        \\  let copy n = observe(arc got)
        \\  print_int(n)
        \\}
    );
    defer e.deinit();

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const root = cwd_buf[0..cwd_len];
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{root});
    defer gpa.free(include);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{root});
    defer gpa.free(rt_c);
    const host_c = try std.fmt.allocPrint(gpa, "{s}/examples/arc_host.c", .{root});
    defer gpa.free(host_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-std=c11", "-Wall", "-Wextra", "body.c", host_c, rt_c, "-I", include, "-o", "body" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(cc_result.stdout);
    defer gpa.free(cc_result.stderr);
    if (!cc_result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ cc_result.stderr, e.text });
        return error.CcRejectedEmittedC;
    }

    const run_result = try std.process.run(gpa, io, .{
        .argv = &.{"./body"},
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    if (!run_result.term.success()) {
        std.debug.print(
            "emitted program did not exit cleanly (an unretained arm binding aborts here):\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("2\n", run_result.stdout);
}

test "an unbound arc temporary's release balances, compiled and run under ASan" {
    // The execution counterpart to the hoist tests above, and the one that
    // covers BOTH directions of the asymmetry in one program, because
    // neither emitted text nor a single tool covers both.
    //
    //   OVER-DROP is caught by AddressSanitizer. `inspect(shared fresh())`
    //   holds the only reference to its box, so a drop emitted before the
    //   call rather than after it takes the count to zero and
    //   `cell_string_as_str`'s result points at freed characters. That is a
    //   heap-use-after-free, and it is the failure this whole change had to
    //   avoid.
    //
    //   UNDER-DROP is caught by the printed number. `dup(arc a)` clones at
    //   the call site and returns its own parameter, so the hoisted handle
    //   is the second reference to `a`'s box. If the hoist's release is
    //   missing, the count never comes back down and the `observe` that
    //   follows reports 3 instead of 2, printing 13 instead of 12.
    //
    // The 12 decomposes as 5 + 5 + 2: "boxed" and "count" are both five
    // characters, and `cell_observe` returns the strong count it was handed,
    // which is the caller's one reference plus its own call-site retain.
    // AddressSanitizer on macOS does not detect leaks, so the leak numbers
    // for this shape stay a `leaks` measurement outside the test suite.
    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn inspect(shared name: String) -> Int;
        \\pub fn dup(arc n: String) -> arc String {
        \\  return n
        \\}
        \\pub fn fresh() -> arc String {
        \\  let arc s = "boxed"
        \\  return s
        \\}
        \\pub fn main() {
        \\  let arc a = "count"
        \\  let copy w = inspect(shared fresh())
        \\  let copy x = inspect(shared dup(arc a))
        \\  let copy y = observe(arc a)
        \\  print_int(w + x + y)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_t _cell_t2 = cell_fresh();");
    try expectContains(e.text, "cell_arc_t _cell_t4 = cell_dup(cell_arc_clone(a));");

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const root = cwd_buf[0..cwd_len];
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{root});
    defer gpa.free(include);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{root});
    defer gpa.free(rt_c);
    const host_c = try std.fmt.allocPrint(gpa, "{s}/examples/arc_host.c", .{root});
    defer gpa.free(host_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{
            "cc", "-std=c11",                     "-Wall",  "-Wextra", "-Werror",
            "-g", "-fsanitize=address,undefined", "body.c", host_c,    rt_c,
            "-I", include,                        "-o",     "body",
        },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(cc_result.stdout);
    defer gpa.free(cc_result.stderr);
    if (!cc_result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ cc_result.stderr, e.text });
        return error.CcRejectedEmittedC;
    }

    const run_result = try std.process.run(gpa, io, .{
        .argv = &.{"./body"},
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    if (!run_result.term.success()) {
        std.debug.print(
            "the hoisted arc temporary's release is unsafe (ASan reports a use-after-free when the drop runs before the call):\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("12\n", run_result.stdout);
}

// ── `let` bindings: the annotation decides, not the initializer's shape ──
//
// FIVE MISCOMPILES LIVED IN ONE MISSING QUESTION, and `letType`'s doc comment
// says which. The tests below pin the answer at the level the defects lived
// at, the emitted DECLARATION, plus one that runs a program because the
// String case is a double free rather than a wrong number and no text
// comparison can tell those apart.
//
// The corpus half is examples/let_binding_modes.cell (records, all three
// backends, a host that counts distinct addresses because a `shared` copy has
// no other observable) and examples/let_binding_owning.cell (String and [T],
// C only). Measured against the ea36e3d compiler, the first prints 44241 in C
// where LLVM and MLIR print 14242, and the second aborts under
// AddressSanitizer at exit 134 with `attempting double-free`.

test "every unique-borrow spelling in a let initializer binds the lender" {
    // examples/borrows.cell declares these five identical, and
    // write_through.cell pins that for the ARGUMENT position. A `let`
    // initializer used to break the group in two: `exclusive buf` emitted a
    // COPY and `exclusive &buf` emitted a const pointer whose qualifier the
    // next call discarded.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn grow(exclusive b: Buffer);
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 1 }
        \\  let exclusive e1 = exclusive buf
        \\  grow(exclusive e1)
        \\  let exclusive e2 = &mut buf
        \\  grow(exclusive e2)
        \\  let exclusive e3 = &var buf
        \\  grow(exclusive e3)
        \\  let exclusive e4 = &exclusive buf
        \\  grow(exclusive e4)
        \\  let exclusive e5 = exclusive &buf
        \\  grow(exclusive e5)
        \\}
    );
    defer e.deinit();
    for ([_][]const u8{ "e1", "e2", "e3", "e4", "e5" }) |name| {
        var buf: [64]u8 = undefined;
        try expectContains(e.text, try std.fmt.bufPrint(&buf, "cell_Buffer *{s} = &buf;", .{name}));
    }
    // The two that were wrong, spelled out so a regression names itself.
    try expectAbsent(e.text, "cell_Buffer e1 = buf;");
    try expectAbsent(e.text, "const cell_Buffer *e5");
}

test "every shared spelling in a let initializer binds the lender" {
    // `let shared s = buf` emitted `cell_Buffer s = buf;`, a copy, while
    // `let shared s = &buf` emitted the pointer. borrowck creates one
    // identical shared loan for both (`checkLetInit`), so the split was the
    // backend's alone. It is invisible to any Cell-side read, because Cell
    // forbids mutating a lender while it is shared-borrowed: only the address
    // the callee is handed can tell a copy from a reference, which is what
    // examples/let_binding_modes.cell's host counts.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn look(shared b: Buffer);
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 1 }
        \\  let shared s1 = buf
        \\  look(shared s1)
        \\  let shared s2 = shared buf
        \\  look(shared s2)
        \\  let shared s3 = &buf
        \\  look(shared s3)
        \\}
    );
    defer e.deinit();
    for ([_][]const u8{ "s1", "s2", "s3" }) |name| {
        var buf: [64]u8 = undefined;
        try expectContains(e.text, try std.fmt.bufPrint(&buf, "const cell_Buffer *{s} = &buf;", .{name}));
    }
    try expectAbsent(e.text, "cell_Buffer s1 = buf;");
}

test "a copy binding of a live borrow is a snapshot, not a second name for it" {
    // The other direction of the same defect: a binding that is NOT a borrow
    // inherited the initializer's reference-ness, so `snap` ALIASED the lender
    // and saw every later write. `copy` means a value copy, and the LLVM
    // backend loads through, so C was the deviant one here too.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn grow(exclusive b: Buffer);
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 1 }
        \\  let exclusive v = &mut buf
        \\  let copy snap = v
        \\  grow(exclusive v)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_Buffer snap = *v;");
    try expectAbsent(e.text, "cell_Buffer *snap = v;");
}

test "an exclusive let over an owning place binds the header, not a shallow copy" {
    // `cell_string_t` and `cell_slice_t` are OWNING headers. A shallow copy of
    // one is not a lost write, it is a second owner of the same heap buffer,
    // and the function-scope drop then frees what the callee already freed.
    // examples/let_binding_owning.cell runs this; here it is pinned at the
    // declaration for both types at once.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn extend(exclusive s: String);
        \\pub fn fresh() -> [Int];
        \\pub fn push(exclusive xs: [Int]);
        \\pub fn main() {
        \\  var owned text = make()
        \\  let exclusive a = text
        \\  extend(exclusive a)
        \\  var owned xs = fresh()
        \\  let exclusive b = xs
        \\  push(exclusive b)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t *a = &text;");
    try expectContains(e.text, "cell_slice_t *b = &xs;");
    try expectAbsent(e.text, "cell_string_t a = text;");
    try expectAbsent(e.text, "cell_slice_t b = xs;");
}

test "a let whose initializer is not a place keeps the initializer's owned type" {
    // THE ASYMMETRY THIS FIX HAD TO PRESERVE, and the reason `isNamedLoan`
    // exists instead of an unconditional `applyOwnership`. `Local.ownership`'s
    // doc comment records that a `shared`/`copy` local initialized from a CALL
    // keeps the call's owned result type, and the drop pass reads the declared
    // annotation rather than the shape precisely so it can tell those apart.
    // A call result is not a place, so no loan is created and the binding is
    // NOT demoted to a `cell_str_t` view of a temporary nothing owns.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn fresh() -> [Int];
        \\pub fn main() {
        \\  let copy a = make()
        \\  let shared b = make()
        \\  let copy c = fresh()
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t a = cell_make();");
    try expectContains(e.text, "cell_string_t b = cell_make();");
    try expectContains(e.text, "cell_slice_t c = cell_fresh();");
    try expectAbsent(e.text, "cell_str_t b");
}

test "an arc let is answered before any dereference of the initializer" {
    // `arc` is asked first in `letType` and never reaches the deref, because
    // an `arc` is a handle by value and `applyOwnership` never makes one a
    // pointer. Pinned because moving the `arc` clause below the deref would
    // still pass every other test in this file.
    var e = try emitSource(
        \\pub fn observe(arc s: String) -> Int;
        \\pub fn main() {
        \\  let arc a = "x"
        \\  let arc b = a
        \\  let copy n = observe(arc b)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_t b = cell_arc_clone(a);");
    try expectAbsent(e.text, "cell_arc_t *b");
}

test "an exclusive String let is not a double free, run under AddressSanitizer" {
    // THE ONE THAT NEEDED RUNNING. Every other test here compares emitted
    // text, and text comparison cannot tell a wrong number from a double free.
    // Against the ea36e3d compiler this exact program aborts at exit 134 with
    // `AddressSanitizer: attempting double-free`, because `cell_string_t a =
    // text;` makes `a` and `text` two owners of one buffer: `reset` releases
    // it through `&a`, the read after that is a use after free, and the
    // function-scope `cell_string_free(&text)` frees it a second time.
    //
    // The host is written inline rather than reusing examples/arc_host.c,
    // because the operation that matters is "free the old buffer, then install
    // a new one", which is what turns a shallow copy of the header from a
    // wrong answer into a double free. A host that only appended would leave
    // the defect silent.
    var e = try emitSource(
        \\pub fn make_text() -> String;
        \\pub fn reset(exclusive s: String);
        \\pub fn text_len(shared s: String) -> Int;
        \\pub fn print_int(copy value: Int);
        \\pub fn main() {
        \\  var owned text = make_text()
        \\  let exclusive a = text
        \\  reset(exclusive a)
        \\  print_int(text_len(shared text))
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t *a = &text;");

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });
    try tmp.dir.writeFile(io, .{
        .sub_path = "host.c",
        .data =
        \\#include "cell_rt.h"
        \\cell_string_t cell_make_text(void) { return cell_string_from_cstr("hi"); }
        \\void cell_reset(cell_string_t *s) {
        \\    cell_string_t bigger = cell_string_from_cstr("hello, world");
        \\    cell_string_free(s);
        \\    *s = bigger;
        \\}
        \\int64_t cell_text_len(cell_str_t s) { return (int64_t)s.len; }
        ,
    });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const root = cwd_buf[0..cwd_len];
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{root});
    defer gpa.free(include);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{root});
    defer gpa.free(rt_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{
            "cc", "-std=c11",                     "-Wall",  "-Wextra", "-Werror",
            "-g", "-fsanitize=address,undefined", "body.c", "host.c",  rt_c,
            "-I", include,                        "-o",     "body",
        },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(cc_result.stdout);
    defer gpa.free(cc_result.stderr);
    if (!cc_result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ cc_result.stderr, e.text });
        return error.CcRejectedEmittedC;
    }

    const run_result = try std.process.run(gpa, io, .{
        .argv = &.{"./body"},
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    if (!run_result.term.success()) {
        std.debug.print(
            "an exclusive String let is not binding the lender's header (ASan reports a double free):\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    // 12 is "hello, world", which `reset` installed THROUGH the borrow. A copy
    // reads 2, the length of what `make_text` returned, if it survives at all.
    try std.testing.expectEqualStrings("12\n", run_result.stdout);
}

test "isNamedLoan mirrors borrowck.checkLetInit over every initializer shape" {
    // The predicate itself, asked directly, because the emission tests above
    // all go through `applyOwnership` and would still pass if this answered
    // correctly for the wrong reason. The table is `checkLetInit`'s two
    // clauses and its catch-all, and the catch-all is what makes this total:
    // an initializer shape nobody enumerated becomes a COPY, never a
    // reference.
    const arena_backing = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_backing);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct {
        src: []const u8,
        own: ast.Ownership,
        want: bool,
        why: []const u8,
    };
    // Each source is a whole `let` statement; the initializer is parsed out of
    // it, so the spellings here are the ones a user actually writes.
    const cases = [_]Case{
        .{ .src = "&buf", .own = .exclusive, .want = true, .why = "clause 1, shared sigil over a place" },
        .{ .src = "&mut buf", .own = .exclusive, .want = true, .why = "clause 1, unique sigil over a place" },
        .{ .src = "exclusive &buf", .own = .exclusive, .want = true, .why = "clause 1 through an annotation" },
        .{ .src = "&buf", .own = .copy, .want = true, .why = "clause 1 does not consult the annotation" },
        .{ .src = "buf", .own = .exclusive, .want = true, .why = "clause 2, keyword over a bare place" },
        .{ .src = "exclusive buf", .own = .exclusive, .want = true, .why = "clause 2 through an annotation" },
        .{ .src = "buf", .own = .shared, .want = true, .why = "clause 2, shared" },
        .{ .src = "buf.len", .own = .shared, .want = true, .why = "a field path is a place" },
        .{ .src = "buf", .own = .copy, .want = false, .why = "copy of a place is a value" },
        .{ .src = "buf", .own = .owned, .want = false, .why = "owned of a place is a move, not a loan" },
        .{ .src = "make()", .own = .exclusive, .want = false, .why = "a call result is not a place" },
        .{ .src = "Buffer { len: 1 }", .own = .exclusive, .want = false, .why = "a struct literal is not a place" },
        .{ .src = "1 + 2", .own = .exclusive, .want = false, .why = "the catch-all is by value" },
        .{ .src = "&make()", .own = .exclusive, .want = false, .why = "clause 1 still requires a place" },
    };

    for (cases) |c| {
        const src = try std.fmt.allocPrint(arena, "pub fn f() {{ let copy x = {s} }}", .{c.src});
        var lex = lexer.Lexer.init(src, "t.cell");
        const toks = try lex.tokenizeAll(arena);
        var p = parser.Parser.init(arena, toks.items, "t.cell");
        const module = try p.parseModule();
        const body = module.items[0].kind.fn_def.body.?;
        const init_expr = body[0].kind.let.value.?;
        const got = isNamedLoan(&init_expr, c.own);
        if (got != c.want) {
            std.debug.print("\nisNamedLoan(\"{s}\", .{s}) = {}, want {} ({s})\n", .{
                c.src, @tagName(c.own), got, c.want, c.why,
            });
            return error.WrongVerdict;
        }
    }
}

test "a by-value binding of an owning header keeps the loud reference spelling" {
    // THE FOURTH DEFECT, DEMONSTRATED RATHER THAN SHIPPED. The first version of
    // the `letType` rule above derived the type from the annotation for EVERY
    // mode, which turned these three from a `cc` error into a silent double
    // free: `let owned s = &mut name` is a LOAN on borrowck's side rather than
    // a move, so the lender is still dropped, and an `owned` binding of a
    // droppable shape is dropped too. Measured at that intermediate revision,
    // all three were `AddressSanitizer: attempting double-free` at exit 134,
    // and the last of them PRINTED CORRECTLY before the change.
    //
    // Keeping the pointer is not a claim that the pointer is right. It is the
    // spelling this backend already had, and it is loud: `cell_string_free(&s)`
    // against a `cell_string_t **` is a `-Werror` error, which the gate's
    // sanitizer stage compiles at.
    //
    // NOTE, added with OWNERSHIP.md R18: the two `let owned ... = &mut ...`
    // lines below no longer pass `cell check` at all, because an `owned`
    // binding may not be initialized from a borrow. This test still emits them
    // because `emitForTest` runs the parser and this backend WITHOUT borrowck,
    // which is the point: the guard is defence in depth behind a front-end
    // refusal, and it must not be deleted on the strength of that refusal.
    // `var copy c = &mut other`, the third case, is still a legal program.
    var e = try emitSource(
        \\pub fn make_text() -> String;
        \\pub fn fresh() -> [Int];
        \\pub fn reset(exclusive s: String);
        \\pub fn main() {
        \\  var owned name = make_text()
        \\  let owned s = &mut name
        \\  var owned list = fresh()
        \\  let owned xs = &mut list
        \\  var owned other = make_text()
        \\  var copy c = &mut other
        \\  reset(exclusive c)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t *s = &name;");
    try expectContains(e.text, "cell_slice_t *xs = &list;");
    try expectContains(e.text, "cell_string_t *c = &other;");
    // The shallow copies that would be silent double frees.
    try expectAbsent(e.text, "cell_string_t s = *&name;");
    try expectAbsent(e.text, "cell_slice_t xs = *&list;");
    try expectAbsent(e.text, "cell_string_t c = *&other;");
}

test "the owning-header guard is keyed on the drop call, so records still copy" {
    // The guard's boundary, both sides in one module. A record has no drop
    // CALL (`hasDropCall`), so a by-value binding of a borrowed record is a
    // real copy and defect 3 stays fixed; a String has one, so the same
    // spelling keeps the reference. Pinned together because widening the
    // guard to every shape would silently reinstate the alias this whole
    // change removes, and narrowing it to none would reinstate the double
    // free above. Since R11 row 2 a record CAN be dropped, through
    // `needsDrop`; this guard deliberately still keys on `hasDropCall`, which
    // is why that predicate was added beside it rather than widened.
    //
    // Read this before trusting the test's second half. `emitForTest` runs
    // the lexer, the parser and the generator and NO borrowck, so `emitSource`
    // emits for a program `cell check` refuses. Since c314a0e that is this
    // program: `let copy text = &mut name` resolves through the borrow to
    // `String`, and R12's binding clause refuses it (verified with `cell
    // check`). The `Buffer` half is scalar-only and stays accepted. The String
    // half is kept, as a REJECTED program, because what it pins is the
    // generator's guard and not the front end: for the three runtime shapes
    // the guard makes a `copy` of a borrow a POINTER (`cell_string_t *text`),
    // never a header copy, so R12's refusal of it is the safe direction and
    // an over-refusal, not a soundness need. Stated in OWNERSHIP.md R12.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn make_text() -> String;
        \\pub fn grow(exclusive b: Buffer);
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 1 }
        \\  let exclusive v = &mut buf
        \\  let copy snap = v
        \\  grow(exclusive v)
        \\  var owned name = make_text()
        \\  let copy text = &mut name
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_Buffer snap = *v;");
    try expectContains(e.text, "cell_string_t *text = &name;");
}

// ── str -> owning String, the funnel (defect 10) ────────────────────────
//
// EIGHT POSITIONS, and the count is the point of the section rather than a
// heading. The defect was recorded as a table of six, and the table was
// itself an instance of the reasoning failure it recorded: two more positions
// have the same cause and appear in neither the table nor the report that
// produced it. All eight route through `emitConversion`, so what these tests
// pin is one predicate observed from eight sides, not eight fixes.
//
// The three negatives at the end are the half that matters more. Turning six
// loud `cc` errors into six silent double frees is the failure mode this
// change is one commit away from at every moment, and it has happened twice
// in this file's history.

test "row 1: a literal returned from a -> String body is copied into an owning value" {
    var e = try emitSource(
        \\pub fn f() -> String {
        \\  return "ab"
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "return cell_string_from_str(cell_str_from_parts(\"ab\", 2));");
}

test "rows 2 and 3: let owned and var owned initializers convert, and are freed once each" {
    // Both spellings in one module because they are one code path
    // (`emitStmt`'s `.let` arm handles `var` too) and pinning only one of
    // them would leave the other free to drift.
    //
    // The `expectOccurrences` half is the safety half. The conversion
    // allocates, so the local must be freed exactly once; twice is the double
    // free this whole design is arranged to avoid, and `expectContains` alone
    // cannot see the difference.
    var e = try emitSource(
        \\pub fn f() {
        \\  let owned s: String = "ab"
        \\  var owned t: String = "cd"
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t s = cell_string_from_str(cell_str_from_parts(\"ab\", 2));");
    try expectContains(e.text, "cell_string_t t = cell_string_from_str(cell_str_from_parts(\"cd\", 2));");
    try expectOccurrences(e.text, "cell_string_free(&s);", 1);
    try expectOccurrences(e.text, "cell_string_free(&t);", 1);
}

test "row 4: a literal passed to an owned String parameter is copied for the callee" {
    // The callee owns and frees what it is handed (cell_rt.h section 7), so
    // handing it a view of a static literal would be a free of a non-heap
    // pointer. examples/owned_string_host.c does exactly that free, under
    // AddressSanitizer, which is what makes this more than a compile check.
    var e = try emitSource(
        \\pub fn g(owned s: String);
        \\pub fn f() {
        \\  g(owned "ab")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_g(cell_string_from_str(cell_str_from_parts(\"ab\", 2)));");
}

test "row 5: a struct literal field of declared type String converts" {
    var e = try emitSource(
        \\pub struct B { name: String }
        \\pub fn f() {
        \\  let owned b: B = B { name: "ab" }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, ".name = cell_string_from_str(cell_str_from_parts(\"ab\", 2))");
    // The field's buffer is freed through the record's generated glue (R11
    // row 2), never by name: `cell_string_free(&b...)` is still absent, and
    // until 2026-09-15 that absence was the whole assertion, which would have
    // kept passing after the glue landed while its comment called the field
    // unmanaged. Both halves are pinned now.
    try expectAbsent(e.text, "cell_string_free(&b");
    try expectContains(e.text, "cell_drop_B(&b);");
    try expectContains(e.text, "  cell_string_free(&r->name);\n");
}

test "row 6: an assignment's right side converts, with the only literal on the assignment" {
    // `make()` supplies the initializer on purpose. A literal there would
    // convert first and mask whether the ASSIGNMENT converts, which is how
    // this row hides.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  var owned s: String = make()
        \\  s = "cd"
        \\}
    );
    defer e.deinit();
    // Since 2026-09-16 the never-moved `owned` reassignment is pre-dropped,
    // so the converted value lands in the temporary rather than straight in
    // `s`, and `s` is released twice: the old value before the store, and
    // the new one at scope end.
    try expectContains(e.text, "cell_string_t _cell_t0 = cell_string_from_str(cell_str_from_parts(\"cd\", 2));");
    try expectContains(e.text, "s = _cell_t0;");
    try expectOccurrences(e.text, "cell_string_free(&s);", 2);
}

test "row 7: a match arm writing into an owning String value slot converts" {
    // NOT IN THE RECORDED TABLE OF SIX. `inferExpr` types a `match` from its
    // FIRST arm, so the first arm's `make()` makes the slot `cell_string_t`
    // and the second arm then writes a literal into it. This reaches
    // `emitValueInto`, which is a different call site from `emitArgLike`, and
    // it was found only by asking which positions route through the funnel
    // rather than by reading the table.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f(shared c: Int) {
        \\  let owned s: String = match c {
        \\    0 => make(),
        \\    _ => "x",
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "= cell_string_from_str(cell_str_from_parts(\"x\", 1));");
    try expectOccurrences(e.text, "cell_string_free(&s);", 1);
}

test "row 8: the same match arm shape at a return converts" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f(shared c: Int) -> String {
        \\  return match c {
        \\    0 => make(),
        \\    _ => "x",
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "= cell_string_from_str(cell_str_from_parts(\"x\", 1));");
}

test "row 7's slot type follows the first arm, so an all-literal match converts once outside" {
    // The other half of `inferExpr`'s first-arm rule, and it is a different
    // emission rather than a variation on the same one: with both arms
    // literal the SLOT is `cell_str_t`, so no arm converts and the single
    // conversion wraps the whole statement expression. Pinned because a
    // "fix" that converted per arm instead would still compile here and
    // would then allocate on a path that discards the result.
    var e = try emitSource(
        \\pub fn f(shared c: Int) {
        \\  let owned s: String = match c {
        \\    0 => "a",
        \\    _ => "x",
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t s = cell_string_from_str(({");
    try expectOccurrences(e.text, "cell_string_from_str", 1);
    try expectOccurrences(e.text, "cell_string_free(&s);", 1);
}

test "an OWNED String place is NOT converted, and the moved pair is freed exactly once" {
    // THE TRAP, and the reason the predicate tests `have.shape == .str`
    // rather than enumerating source expressions. An owned place is already a
    // `cell_string_t`; wrapping it in `cell_string_from_str` would not even
    // type-check, and a conversion that took ownership instead would make two
    // owners of one buffer, which is exactly why `emitArcConversion` refuses
    // to BOX an owned place. borrowck moves `s` into `t`, so the pair owes
    // ONE free, and that is what is counted here.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned s: String = make()
        \\  let owned t: String = s
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t t = s;");
    try expectAbsent(e.text, "cell_string_from_str");
    try expectOccurrences(e.text, "cell_string_free", 1);
}

test "an exclusive String destination is a pointer and is NOT converted" {
    // `exclusive String` is `cell_string_t *` and a freshly converted value
    // has no address to hand over, so this stays the loud `cc` error it is
    // today. The guard is `want.pointer`, and dropping it would emit a
    // 24-byte value where a pointer is read.
    var e = try emitSource(
        \\pub fn g(exclusive s: String);
        \\pub fn f() {
        \\  g(exclusive "ab")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_g(cell_str_from_parts(\"ab\", 2));");
    try expectAbsent(e.text, "cell_string_from_str");
}

test "an arc value returned from a -> String body is still refused by cc" {
    // The unbox direction stays unrouted. `emitReturnValue`'s guard is on
    // `have` alone now, and this pins that widening it to cover the string
    // conversion did not also open the arc-to-owned one: docs/OWNERSHIP.md
    // R10 documents that emission as a double free, and the C type error is
    // the only thing refusing it at this layer.
    var e = try emitSource(
        \\pub fn f(arc a: String) -> String {
        \\  return a
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t _cell_t0 = cell_arc_clone(a);");
    try expectAbsent(e.text, "cell_string_from_str");
}

test "a shared String parameter borrowed for a shared parameter is not converted either" {
    // The neighbouring direction, `.string` -> `.str`, which runs the other
    // way through `emitArgLike` and must be untouched by the new rule. If the
    // funnel ever answered this pair it would allocate a copy for every
    // borrow in the corpus.
    var e = try emitSource(
        \\pub fn inspect(shared v: String) -> Int;
        \\pub fn make() -> String;
        \\pub fn f() -> Int {
        \\  let owned s: String = make()
        \\  return inspect(shared s)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_inspect(cell_string_as_str(&s))");
    try expectAbsent(e.text, "cell_string_from_str");
}

test "a copy String destination converts, and the leak that follows is pinned here" {
    // THE ONE DELIBERATE DECISION IN THIS RULE, pinned rather than left in a
    // report. `copy` means an independent value, and `cell_string_from_str`
    // is exactly the deep copy R12 asks for at a copy site, so converting is
    // right. What is missing is the drop: `pendingDrops` takes only `.owned`
    // and `.arc`, so the copy is never freed.
    //
    // That leak is not introduced here and is not about literals. `var copy s
    // = make()` leaks today for the same reason, so the choice is between a
    // deep copy that leaks and a `cc` error, and this backend's stated
    // asymmetry puts a leak on the acceptable side and a double free on the
    // other. Measured under AddressSanitizer: clean, exit 0.
    var e = try emitSource(
        \\pub fn f() {
        \\  let copy s: String = "ab"
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t s = cell_string_from_str(cell_str_from_parts(\"ab\", 2));");
    try expectOccurrences(e.text, "cell_string_free", 0);
}

test "a list element is a ninth position, and it inherits the conversion by routing" {
    // THE THESIS OF THE FUNNEL, stated as a test rather than as a claim in a
    // doc comment. This position is in no table: the defect was recorded with
    // six, a value slot at a `let` and at a `return` made eight, and a
    // `[String]` element was never enumerated at any point. It converts
    // anyway, because `emitListLit` lowers each item through `emitArgLike`
    // against the DECLARED element type and `emitArgLike` asks the funnel.
    //
    // Each element is a real heap copy, and `cell_slice_free` frees the
    // buffer and not the elements, so this leaks. Same side of the same
    // asymmetry as the `copy` case above, and pre-existing: an element of an
    // `owned [String]` was never dropped by anything.
    var e = try emitSource(
        \\pub fn f() {
        \\  let owned xs: [String] = ["a", "bb"]
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "= cell_string_from_str(cell_str_from_parts(\"a\", 1));");
    try expectContains(e.text, "= cell_string_from_str(cell_str_from_parts(\"bb\", 2));");
    try expectContains(e.text, "cell_slice_alloc(sizeof(cell_string_t), 2)");
    try expectOccurrences(e.text, "cell_slice_free(&xs);", 1);
}

test "Some/None/Ok/Err lower onto the runtime constructors" {
    var e = try emitSource(
        \\pub enum E { A, B }
        \\pub fn f() -> Int {
        \\  let a: Int? = Some(1)
        \\  let b: Int? = None
        \\  let c: Int32? = Some(2)
        \\  let d: Result<Int, E> = Ok(3)
        \\  let g: Result<Int, E> = Err(E.B)
        \\  let h: Result<Byte, Int32> = Ok(4)
        \\  let i = Some(5)
        \\  return 0
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_opt_i64_t a = cell_opt_i64_some(1);");
    try expectContains(f, "cell_opt_i64_t b = cell_opt_i64_none();");
    try expectContains(f, "cell_opt_i32_t c = cell_opt_i32_some(2);");
    try expectContains(f, "cell_res_i64_i32_t d = cell_res_i64_i32_ok(3);");
    try expectContains(f, "cell_res_i64_i32_t g = cell_res_i64_i32_err(cell_E_B);");
    try expectContains(f, "cell_res_byte_i32_t h = cell_res_byte_i32_ok(4);");
    try expectContains(f, "cell_opt_i64_t i = cell_opt_i64_some(5);");
    try expectCompiles(e.text);
}

test "wrap patterns test the tag and bind the payload" {
    var e = try emitSource(
        \\pub enum E { A, B }
        \\pub fn f(copy o: Int?, copy r: Result<Byte, E>) -> Int {
        \\  let copy a = match o { Some(x) => x, None => 0 }
        \\  let copy b = match r { Ok(v) => 1, Err(code) => 2 }
        \\  return a + b
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "if (_cell_t1.has_value) {");
    try expectContains(f, "int64_t x = _cell_t1.value;");
    try expectContains(f, "} else if (!_cell_t1.has_value) {");
    try expectContains(f, "if (_cell_t3.ok) {");
    try expectContains(f, "uint8_t v = _cell_t3.as.ok;");
    try expectContains(f, "cell_E code = (cell_E)_cell_t3.as.err;");
    try expectCompiles(e.text);
}

test "a Result keeps its error at full width and its payload in its own type" {
    var e = try emitSource(
        \\pub fn big(copy n: Int) -> Result<Bool, Int> {
        \\  if n > 0 {
        \\    return Ok(true)
        \\  }
        \\  return Err(5000000000)
        \\}
        \\pub fn half(copy x: Float32) -> Result<Float32, UInt16> {
        \\  return Ok(x)
        \\}
        \\pub fn get(copy r: Result<Bool, Int>) -> Int {
        \\  return match r { Ok(v) => 1, Err(e) => e }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_res_bool_i64_t cell_big(int64_t n);");
    try expectContains(try fnDef(e.text, "big"), "return cell_res_bool_i64_err(5000000000);");
    try expectContains(try fnDef(e.text, "half"), "return cell_res_f32_u16_ok(x);");
    try expectContains(try fnDef(e.text, "get"), "int64_t e = _cell_t");
    try expectAbsent(e.text, "cell_result_t");
    try expectAbsent(e.text, "(int32_t)");
    try expectCompiles(e.text);
}

test "the C Result slugs match abi.resultMember for every scalar name" {
    const abi = @import("abi.zig");
    const types = @import("types.zig");
    const Pair = struct { name: []const u8, ty: types.Type };
    const pairs = [_]Pair{
        .{ .name = "Int", .ty = types.t_int },       .{ .name = "Int8", .ty = types.t_int8 },
        .{ .name = "Int16", .ty = types.t_int16 },   .{ .name = "Int32", .ty = types.t_int32 },
        .{ .name = "UInt", .ty = types.t_uint },     .{ .name = "UInt8", .ty = types.t_uint8 },
        .{ .name = "UInt16", .ty = types.t_uint16 }, .{ .name = "UInt32", .ty = types.t_uint32 },
        .{ .name = "Float", .ty = types.t_float },   .{ .name = "Float32", .ty = types.t_float32 },
        .{ .name = "Bool", .ty = types.t_bool },     .{ .name = "Byte", .ty = types.t_byte },
    };
    for (pairs) |p| {
        try std.testing.expectEqualStrings(abi.resultMember(p.ty).?.slug, scalarSlug(p.name).?);
    }
    try std.testing.expect(scalarSlug("String") == null);
}

test "a var moved on one branch is released at the end of the other" {
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn f(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    take(v)
        \\  } else {
        \\    c = c + 1
        \\  }
        \\}
        \\pub fn g(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    take(v)
        \\  }
        \\}
        \\pub fn both(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    take(v)
        \\  } else {
        \\    take(v)
        \\  }
        \\}
        \\pub fn neither(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    c = c + 1
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&v);", 1);
    try expectLineBefore(f, "cell_string_free(&v);", "c = (c + 1);");
    const g = try fnDef(e.text, "g");
    try expectOccurrences(g, "cell_string_free(&v);", 1);
    try expectContains(g, "} else {\n    cell_string_free(&v);\n  }");
    const both = try fnDef(e.text, "both");
    try expectAbsent(both, "cell_string_free(&v);");
    const neither = try fnDef(e.text, "neither");
    try expectOccurrences(neither, "cell_string_free(&v);", 1);
    try expectCompiles(e.text);
}

test "a revived loop-local is released at a continue" {
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn f(copy n: Int) {
        \\  var i = 0
        \\  while i < n {
        \\    i = i + 1
        \\    var owned v: String = "a"
        \\    take(v)
        \\    v = "b"
        \\    if i > 0 {
        \\      continue
        \\    }
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&v);", 2);
    try expectContains(f, "cell_string_free(&v);\n            continue;");
    try expectCompiles(e.text);
}

test "a var revived in a value block is released after the tail" {
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn f() -> Int {
        \\  let copy n = {
        \\    var owned v: String = "a"
        \\    take(v)
        \\    v = "b"
        \\    3
        \\  }
        \\  return n
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&v);", 1);
    try expectBefore(f, "= 3;", "cell_string_free(&v);");
    try expectCompiles(e.text);
}

test "a revived record is released whole at scope end" {
    var e = try emitSource(
        \\pub struct Box { owned s: String }
        \\pub fn take(owned b: Box);
        \\pub fn f() {
        \\  var owned b = Box { s: "one" }
        \\  take(b)
        \\  b = Box { s: "two" }
        \\}
        \\pub fn g() {
        \\  var owned b = Box { s: "one" }
        \\  take(b)
        \\  b = Box { s: "two" }
        \\  let owned moved: String = b.s
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_drop_Box(&b);", 1);
    // Released after the revival, not before it: a drop ahead of the store
    // would free the buffer `take` already owns.
    try expectBefore(f, "b = (cell_Box){ .s = cell_string_from_str(cell_str_from_parts(\"two\", 3)) };", "cell_drop_Box(&b);");
    // Plan D Task 5's second half: a field moved out after the revival keeps
    // the partial path. `s` is Box's only owning field, so nothing of `b` is
    // released; the moved string is released through `moved`.
    const g = try fnDef(e.text, "g");
    try expectOccurrences(g, "cell_drop_Box(&b);", 0);
    try expectOccurrences(g, "cell_string_free(&moved);", 1);
    try expectOccurrences(g, "cell_string_free(&b.s);", 0);
    try expectCompiles(e.text);
}
