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
pub const Shape = cg_model.Shape;
pub const CType = cg_model.CType;
const Local = cg_model.Local;
const Dest = cg_model.Dest;
const StructEmitState = cg_model.StructEmitState;
const OptionalInst = cg_model.OptionalInst;
const eq = cg_helpers.eq;
const intrinsicSymbol = cg_helpers.intrinsicSymbol;
const isNamedLoan = cg_helpers.isNamedLoan;
const endsInReturn = cg_helpers.endsInReturn;
const scalarSlug = cg_helpers.scalarSlug;
const resultBase = cg_helpers.resultBase;
const isOwningOptional = cg_helpers.isOwningOptional;
const hasOwningGlue = cg_helpers.hasOwningGlue;
const glueStem = cg_helpers.glueStem;
const isOwningResult = cg_helpers.isOwningResult;
const Exit = cg_helpers.Exit;
const OwningTemp = cg_helpers.OwningTemp;
const SkipLabel = cg_helpers.SkipLabel;
const blockExit = cg_helpers.blockExit;
const nameIn = cg_helpers.nameIn;
const stmtsUse = cg_helpers.stmtsUse;

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
    pub fn symbolFor(self: *Generator, f: ast.FnDef) Alloc![]const u8 {
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

    pub fn writeDecl(self: *Generator, ty: CType, name: []const u8) EmitError!void {
        if (ty.pointer) {
            try self.writer.print("{s}{s}", .{ ty.text, name });
        } else {
            try self.writer.print("{s} {s}", .{ ty.text, name });
        }
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
    fn emitScopeDrops(self: *Generator, indent: usize, exit: ?Exit) EmitError!void {
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
};

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

test "a temporary owned String scrutinee is released once on every path out" {
    // 2026-09-17: `match str_from_int(i) { "1" => 1, _ => 2 }` never freed
    // the temporary (examples/leaks/match_string_temp.cell, 1000). String
    // patterns bind nothing, so every arm end and every early exit releases
    // it. A binding arm (`x => ...`) is an alias borrowck lets the body move,
    // so it is treated as taken and keeps the leak rather than risk a double
    // free. A `str` scrutinee (a literal) owns nothing and is never freed.
    var e = try emitSource(
        \\pub fn str_from_int(copy v: Int) -> String;
        \\pub fn take(owned s: String);
        \\pub fn once(copy i: Int) -> Int {
        \\  return match str_from_int(i) {
        \\    "1" => 1,
        \\    _ => 2,
        \\  }
        \\}
        \\pub fn early(copy i: Int) -> Int {
        \\  match str_from_int(i) {
        \\    "1" => {
        \\      return 1
        \\    },
        \\    _ => {},
        \\  }
        \\  return 0
        \\}
        \\pub fn loop_exit(copy n: Int) -> Int {
        \\  var i = 0
        \\  while i < n {
        \\    i = i + 1
        \\    match str_from_int(i) {
        \\      "3" => {
        \\        break
        \\      },
        \\      _ => {
        \\        continue
        \\      },
        \\    }
        \\  }
        \\  return i
        \\}
        \\pub fn bound(copy i: Int) {
        \\  match str_from_int(i) {
        \\    x => take(x),
        \\  }
        \\}
        \\pub fn literal() -> Int {
        \\  return match "a" {
        \\    "a" => 1,
        \\    _ => 2,
        \\  }
        \\}
    );
    defer e.deinit();
    // One per arm end.
    try expectOccurrences(try fnDef(e.text, "once"), "cell_string_free(&_cell_t", 2);
    // Before the early return, and at the end of the `_` arm.
    try expectOccurrences(try fnDef(e.text, "early"), "cell_string_free(&_cell_t", 2);
    // Before the `break` and before the `continue`.
    try expectOccurrences(try fnDef(e.text, "loop_exit"), "cell_string_free(&_cell_t", 2);
    try expectAbsent(try fnDef(e.text, "bound"), "cell_string_free(");
    try expectAbsent(try fnDef(e.text, "literal"), "cell_string_free(");
    try expectCompiles(e.text);
}

test "a binding arm that moves a temporary owning scrutinee does not release it" {
    // 2026-09-17, measured: before the binding rule, `match lookup(i) { x =>
    // eat(x) }` released the `String?` temporary at the arm end after `eat`
    // had freed it, a double free AddressSanitizer reported (exit 134).
    // borrowck accepts the move (the scrutinee has no place), and this
    // backend binds `x` as an undropped bitwise copy, so a binding arm that
    // names the value counts as having taken it. One that never names it
    // still releases the temporary.
    var e = try emitSource(
        \\pub fn lookup(copy n: Int) -> String?;
        \\pub fn eat(owned o: String?) -> Int;
        \\pub fn moved(copy i: Int) -> Int {
        \\  return match lookup(i) {
        \\    x => eat(x),
        \\  }
        \\}
        \\pub fn unnamed(copy i: Int) -> Int {
        \\  return match lookup(i) {
        \\    x => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectAbsent(try fnDef(e.text, "moved"), "cell_drop_opt_string(&_cell_t");
    try expectOccurrences(try fnDef(e.text, "unnamed"), "cell_drop_opt_string(&_cell_t", 1);
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
