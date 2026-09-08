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
//! than `static inline`) at the end of its function's body and before every
//! `return`. "Unmoved" is answered by `borrowck.zig`, not re-derived here:
//! `emitModule` runs one `borrowck.Checker` over the whole module before
//! emitting anything, and every `Local` records the id `Checker.declare`
//! assigned to the SAME source declaration, so `Checker.wasMoved` can be
//! asked directly. A parameter is never dropped (its owner is the caller
//! that made this call, and the CALLEE it was moved into is a different
//! function's problem -- see `Local.droppable`); neither is a match-arm
//! binding (its C value is a bitwise copy of the scrutinee temporary, and
//! dropping it risks freeing whatever the scrutinee itself still owns); nor
//! is a `record` (struct) shape (recursive field drops need a generated
//! per-struct function, which is a separate task).
//!
//! Borrowck's move tracking is deliberately conservative -- a move on only
//! one branch of an `if` marks the place moved for the rest of the function
//! -- and that direction is exactly what a safe drop pass needs: skipping
//! the drop of a place that is still live only leaks it, while dropping a
//! place that might already be gone is a double free. This backend always
//! picks the leak. Known gaps left on purpose: a value moved on only one
//! path still leaks on every path that did not move it; a struct with
//! owning fields is never destroyed at all; and `wasMoved` answers "moved
//! ANYWHERE in the function", so a `var` that is moved and later reassigned
//! (R3a revival) is never dropped either, even though it holds a fresh,
//! unmoved value at the function's end -- the revived value leaks too.
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
//! `emitArcConversion` emits every one of them. It hangs off `emitArgLike`
//! because that is already the single place a value is lowered into a
//! position whose C type is declared: a `let` initializer, a call argument,
//! a struct literal field, a list element, and an assignment's right side.
//! All four of R11's retain sites are one of those, so there is no second
//! place to keep in step. `letType` had to learn about `arc` first: it took
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
//! body never releases its own `arc` parameter, because no parameter is
//! dropped, so every call-site retain into one leaks a reference; a struct
//! holding an `arc` field is never dropped, so the field's retain leaks; an
//! `arc` value unboxed for a `shared` parameter without ever being bound
//! (`inspect(shared fresh())`) drops its handle on the floor; a block-scoped
//! `arc` local is never released at all, since release is function-scoped,
//! which inside a `while` body is unbounded; reassigning an `arc` `var`
//! leaks the previous box; and an `owned` String or list PLACE bound as
//! `arc` is not boxed at all, because `cell_arc_from_string` moves its
//! argument while `borrowck.zig` leaves the source unmoved, and a loud C
//! type error beats a silent double free. That list is what running programs
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

    pub const unknown: CType = .{ .text = "void*", .shape = .unknown };
    pub const void_type: CType = .{ .text = "void", .shape = .unit };
    pub const int64: CType = .{ .text = "int64_t", .shape = .integer };
    pub const float64: CType = .{ .text = "double", .shape = .floating };
    pub const boolean: CType = .{ .text = "bool", .shape = .boolean };
    pub const str: CType = .{ .text = "cell_str_t", .shape = .str };
    pub const string: CType = .{ .text = "cell_string_t", .shape = .string };
    pub const slice: CType = .{ .text = "cell_slice_t", .shape = .slice };
    pub const arc: CType = .{ .text = "cell_arc_t", .shape = .arc };
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
    /// True only for a `let`/`var` local. False for a parameter and for a
    /// match-arm binding, both of which are excluded from dropping for
    /// reasons the module doc comment gives; kept separate from the
    /// `ownership` check because a parameter can itself be `owned` and
    /// must still never be dropped.
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

        for (module.items) |item| {
            switch (item.kind) {
                .struct_def => |s| try self.emitStruct(s),
                .enum_def => |e| try self.emitEnum(e),
                else => {},
            }
        }

        try self.emitOptionalInstances();

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
            // Decision: a parameter is never dropped (see the module doc
            // comment), regardless of its own ownership annotation.
            try self.pushLocal(p.name, try self.lowerType(&p.ty, p.ownership), p.ownership, false);
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
        for (body, 0..) |_, i| {
            try self.emitStmt(&body[i], body[i + 1 ..], 1);
        }
        try self.emitScopeDrops(1);
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

    fn emitStmts(self: *Generator, stmts: []const ast.Stmt, indent: usize) EmitError!void {
        const mark = self.locals.items.len;
        defer self.locals.shrinkRetainingCapacity(mark);
        for (stmts, 0..) |_, i| {
            try self.emitStmt(&stmts[i], stmts[i + 1 ..], indent);
        }
    }

    fn emitStmt(self: *Generator, stmt: *const ast.Stmt, rest: []const ast.Stmt, indent: usize) EmitError!void {
        const out = self.writer;
        switch (stmt.kind) {
            .while_stmt => |w| {
                try self.writeIndent(indent);
                try out.writeAll("while (");
                try self.emitExpr(&w.cond, indent);
                try out.writeAll(") {\n");
                try self.emitStmts(w.body, indent + 4);
                try self.writeIndent(indent);
                try out.writeAll("}\n");
            },
            .break_stmt => {
                try self.writeIndent(indent);
                try out.writeAll("break;\n");
            },
            .continue_stmt => {
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
                }
                try out.writeAll(";\n");
                try self.pushLocal(l.name, ty, l.ownership, true);
                // -Wunused-variable is part of -Wall.
                if (!stmtsUse(rest, l.name)) {
                    try self.writeIndent(indent);
                    try out.print("(void){s};\n", .{l.name});
                }
            },
            .return_stmt => |opt| try self.emitReturnStmt(opt, indent),
            .expr => |e| switch (e.kind) {
                .if_expr => |i| try self.emitIfStmt(i, indent),
                .match_expr => |m| try self.emitMatchStmt(m, indent),
                .block => |b| {
                    try self.writeIndent(indent);
                    try out.writeAll("{\n");
                    try self.emitStmts(b, indent + 1);
                    try self.writeIndent(indent);
                    try out.writeAll("}\n");
                },
                .annotated => |a| try self.emitEffect(a.value, indent),
                else => {
                    try self.writeIndent(indent);
                    try self.emitExpr(&e, indent);
                    try out.writeAll(";\n");
                },
            },
            .assign => |a| {
                try self.writeIndent(indent);
                try self.emitExpr(&a.target, indent);
                try out.writeAll(" = ");
                const want = try self.inferExpr(&a.target);
                try self.emitArgLike(&a.value, want, indent);
                try out.writeAll(";\n");
            },
        }
    }

    // ── drop insertion (task 3) ────────────────────────────────────────

    /// The drop vocabulary in runtime/cell_rt.h: a `record` (struct) case is
    /// deliberately absent, since a struct with owning fields needs a
    /// generated per-struct drop function this task does not build (see the
    /// module doc comment).
    fn hasDropCall(shape: Shape) bool {
        return switch (shape) {
            .string, .slice, .arc => true,
            else => false,
        };
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
            else => unreachable, // hasDropCall already filtered these out.
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
    /// (`record` shape) is excluded by `hasDropCall`, not by an ownership
    /// check, because a struct can be `owned` too.
    fn pendingDrops(self: *Generator) Alloc![]const Local {
        const checker = self.checker orelse return &.{};
        var out: std.ArrayList(Local) = .empty;
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (self.isShadowedAt(i)) continue;
            if (!local.droppable) continue;
            if (local.ownership != .owned and local.ownership != .arc) continue;
            if (!hasDropCall(local.ty.shape)) continue;
            if (checker.wasMoved(local.id)) continue;
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

    /// The end-of-function-body drop point. Nested block/if/match/while
    /// exits do NOT call this: the brief's design is function-scoped, not
    /// block-scoped (see the module doc comment's "known gaps").
    fn emitScopeDrops(self: *Generator, indent: usize) EmitError!void {
        for (try self.pendingDrops()) |local| try self.emitDropFor(indent, local);
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
    fn emitReturnStmt(self: *Generator, opt: ?ast.Expr, indent: usize) EmitError!void {
        const out = self.writer;
        const to_drop = try self.pendingDrops();
        const retain = if (opt) |v| try self.returnedArcNeedsRetain(&v) else false;
        if (to_drop.len == 0) {
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
            try self.writeIndent(indent);
            try out.print("return {s};\n", .{temp});
        } else {
            for (to_drop) |local| try self.emitDropFor(indent, local);
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
    fn emitReturnValue(self: *Generator, v: *const ast.Expr, retain: bool, indent: usize) EmitError!void {
        if (!retain) return try self.emitExpr(v, indent);
        try self.writer.writeAll("cell_arc_clone(");
        try self.emitExpr(v, indent);
        try self.writer.writeAll(")");
    }

    /// True when returning `v` owes an `arc` retain (R11 release rule 3: a
    /// returned `arc` is returned ALREADY RETAINED, and the caller owns that
    /// reference and must release it).
    ///
    /// The rule is stated as an exception rather than as a list, because a
    /// list is what got this wrong the first time. **Retain every returned
    /// `arc` place except a parameter returned directly.** A parameter is
    /// the one reference this frame received pre-retained from its caller
    /// and hands straight back, so cloning it would leak. Everything else
    /// belongs to something that outlives this return or that this return is
    /// about to release:
    ///
    ///   - a LOCAL is always still in `pendingDrops`, because borrowck never
    ///     makes an `arc` place dead (`isDuplicable`, R10 by design), so the
    ///     drop would run between the return temporary and the `return`.
    ///     Retaining is exactly balanced: 1 -> 2 -> 1.
    ///   - a FIELD (`s.name`, `s->name`) belongs to the record, which this
    ///     backend never drops. An earlier version of this function declined
    ///     a `.field` root, reasoning that the record is never released so
    ///     there is no release to balance. That reasoned about the wrong
    ///     quantity: what matters is the reference the CALLER is about to
    ///     release, not the one this frame holds. `pub fn peek(shared s:
    ///     Session) -> arc String { return s.name }` emitted a bare
    ///     `return s->name;` and died under AddressSanitizer with a
    ///     heap-use-after-free in `cell_arc_drop`. Retaining leaks the
    ///     record's own reference instead, which is the correct side.
    /// The exception is spelled `!droppable`, and an earlier version added a
    /// `Local.is_param` field to spell it more precisely, on the theory that
    /// a match-arm binding is undroppable too and must still retain. **That
    /// field defended nothing and has been removed.** A match-arm binding
    /// cannot reach this function at all, measured both ways: `return` is not
    /// an expression in this grammar, so an arm body cannot contain one
    /// (`error: expected expression`), and a trailing `match` is an
    /// expression statement rather than a return (`error: missing return in
    /// function 'f'`). The only bindings that reach the `.ident` branch are
    /// parameters and `let`/`var` locals.
    ///
    /// **The landmine that leaves, stated so it is not rediscovered the hard
    /// way.** If the parser ever admits `return` inside a match arm, or a
    /// trailing expression ever becomes an implicit return, a match-arm
    /// binding of `arc` type reaches this branch, reads `!droppable` as
    /// "parameter", and is handed back without a retain while the scrutinee
    /// it copies is released. Restore a parameter-only test at that point.
    /// `docs/OWNERSHIP.md` R11 carries the same warning.
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
                    if (eq(self.locals.items[i].name, n)) return self.locals.items[i].droppable;
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
    /// initializer decides; otherwise int64_t, matching the language's default
    /// integer.
    ///
    /// The un-annotated path consults `own` for `arc` ALONE, and that
    /// asymmetry is deliberate. `arc` is the one mode whose C spelling is not
    /// derivable from the initializer: `let arc label = "session"` must be a
    /// `cell_arc_t` no matter that the literal infers as `cell_str_t`, and
    /// before this consultation existed the binding kept the view's type and
    /// the emitted C failed to compile the moment it reached an `arc`
    /// parameter. The other modes stay initializer-driven on purpose, because
    /// `Local.ownership`'s doc comment already records that a `shared`/`copy`
    /// local initialized from a call keeps the call's owned result type, and
    /// the drop pass reads the declared annotation rather than the shape
    /// precisely so that it can tell those apart. `applyOwnership` returns a
    /// primitive unchanged, so `arc Int` stays `int64_t` here for free.
    fn letType(self: *Generator, ann: ?ast.TypeExpr, value: ?ast.Expr, own: ast.Ownership) Alloc!CType {
        if (ann) |t| return try self.lowerType(&t, own);
        if (value) |v| {
            const inferred = try self.inferExpr(&v);
            if (inferred.shape != .unknown and inferred.shape != .unit) {
                if (own == .arc) return try self.applyOwnership(inferred, .arc);
                return inferred;
            }
        }
        return CType.int64;
    }

    fn emitIfStmt(self: *Generator, i: anytype, indent: usize) EmitError!void {
        const out = self.writer;
        try self.writeIndent(indent);
        try out.writeAll("if (");
        try self.emitExpr(i.cond, indent);
        try out.writeAll(") ");
        try self.emitBranchStmt(i.then_body, indent);
        if (i.else_body) |eb| {
            try out.writeAll(" else ");
            try self.emitBranchStmt(eb, indent);
        }
        try out.writeAll("\n");
    }

    /// One branch of a statement-position `if`. A nested `if` becomes
    /// `else if` rather than a braced block.
    fn emitBranchStmt(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
        const out = self.writer;
        switch (e.kind) {
            .block => |stmts| {
                try out.writeAll("{\n");
                try self.emitStmts(stmts, indent + 1);
                try self.writeIndent(indent);
                try out.writeAll("}");
            },
            .if_expr => |i| {
                try out.writeAll("if (");
                try self.emitExpr(i.cond, indent);
                try out.writeAll(") ");
                try self.emitBranchStmt(i.then_body, indent);
                if (i.else_body) |eb| {
                    try out.writeAll(" else ");
                    try self.emitBranchStmt(eb, indent);
                }
            },
            .annotated => |a| try self.emitBranchStmt(a.value, indent),
            else => {
                try out.writeAll("{\n");
                try self.writeIndent(indent + 1);
                try self.emitExpr(e, indent + 1);
                try out.writeAll(";\n");
                try self.writeIndent(indent);
                try out.writeAll("}");
            },
        }
    }

    fn emitMatchStmt(self: *Generator, m: anytype, indent: usize) EmitError!void {
        try self.emitMatch(m, null, indent);
    }

    /// Lower a `match` to a scrutinee temporary plus an if/else chain. When
    /// `dest` is set every arm assigns into it instead of running for effect.
    fn emitMatch(self: *Generator, m: anytype, dest: ?Dest, indent: usize) EmitError!void {
        const out = self.writer;
        const scrut_ty = try self.inferExpr(m.scrutinee);
        const temp = try self.nextTemp();

        try self.writeIndent(indent);
        try out.writeAll("{\n");
        try self.writeIndent(indent + 1);
        try self.writeDecl(scrut_ty, temp);
        try out.writeAll(" = ");
        try self.emitExpr(m.scrutinee, indent + 1);
        try out.writeAll(";\n");

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
                try self.emitExpr(arm.guard.?, indent + 1);
            } else {
                try self.emitPatternTest(arm.pattern, temp, scrut_ty);
                if (arm.guard) |g| {
                    try out.writeAll(" && (");
                    try self.emitExpr(g, indent + 1);
                    try out.writeAll(")");
                }
            }
            try out.writeAll(") {\n");
            try self.emitArmBody(arm, temp, scrut_ty, dest, indent + 2);
            tested += 1;
        }

        if (tested == 0) {
            // The first arm matches everything, so no test is emitted at all.
            if (default_arm) |arm| {
                try self.emitArmBody(arm, temp, scrut_ty, dest, indent + 1);
            }
        } else {
            try self.writeIndent(indent + 1);
            try out.writeAll("} else {\n");
            if (default_arm) |arm| {
                try self.emitArmBody(arm, temp, scrut_ty, dest, indent + 2);
            } else {
                // Cell has no exhaustiveness checking, so an unmatched value
                // aborts rather than falling through with a made-up result.
                try self.writeIndent(indent + 2);
                try out.print("cell_panic(\"non-exhaustive match in {s}\");\n", .{self.current_fn});
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
    ) EmitError!void {
        const mark = self.locals.items.len;
        defer self.locals.shrinkRetainingCapacity(mark);

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

        if (dest) |d| {
            try self.emitValueInto(arm.body, d, indent);
        } else {
            try self.emitEffect(arm.body, indent);
        }
    }

    /// Emit an expression for its effect, in statement position.
    fn emitEffect(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
        switch (e.kind) {
            .block => |stmts| try self.emitStmts(stmts, indent),
            .if_expr => |i| try self.emitIfStmt(i, indent),
            .match_expr => |m| try self.emitMatchStmt(m, indent),
            .annotated => |a| try self.emitEffect(a.value, indent),
            else => {
                try self.writeIndent(indent);
                try self.emitExpr(e, indent);
                try self.writer.writeAll(";\n");
            },
        }
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
        }
    }

    // ── value position ──────────────────────────────────────────────────

    /// `if`, `match`, and `block` in expression position, as a GNU statement
    /// expression. See the module comment for why.
    fn emitValueExpr(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
        const out = self.writer;
        var ty = try self.inferExpr(e);
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

    /// Emit `e` as statements that leave its value in `dest`.
    ///
    /// The leaf case routes through `emitArcConversion` rather than writing a
    /// bare assignment, because a value slot is a position with a declared
    /// type and therefore owes the same `arc` retain that a parameter, a
    /// `let`, or a struct field does. Two reachable use-after-frees came in
    /// through here, both silent at `cell check` and clean under
    /// `-Wall -Wextra -Werror`:
    ///
    ///   let arc r = if (c > 0) { a } else { b }   // r aliased a's box
    ///   return match c { 0 => a, _ => a }         // dropped before return
    ///
    /// Only the `arc` conversion is applied, not all of `emitArgLike`. The
    /// address-of and dereference rules there would newly compile
    /// cross-branch type mismatches that are C errors today, and one of them
    /// (`&x` on a branch-local place) would hand out a pointer that dies at
    /// the branch's closing brace. Fixing an aliasing bug is no reason to
    /// introduce a different one.
    fn emitValueInto(self: *Generator, e: *const ast.Expr, dest: Dest, indent: usize) EmitError!void {
        const out = self.writer;
        switch (e.kind) {
            .block => |stmts| {
                try self.writeIndent(indent);
                try out.writeAll("{\n");
                const mark = self.locals.items.len;
                defer self.locals.shrinkRetainingCapacity(mark);
                if (stmts.len > 0) {
                    for (stmts[0 .. stmts.len - 1], 0..) |_, i| {
                        try self.emitStmt(&stmts[i], stmts[i + 1 ..], indent + 1);
                    }
                    const last = &stmts[stmts.len - 1];
                    switch (last.kind) {
                        .expr => |le| try self.emitValueInto(&le, dest, indent + 1),
                        else => try self.emitStmt(last, &.{}, indent + 1),
                    }
                }
                try self.writeIndent(indent);
                try out.writeAll("}\n");
            },
            .if_expr => |i| {
                try self.writeIndent(indent);
                try out.writeAll("if (");
                try self.emitExpr(i.cond, indent);
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
                const have = try self.inferExpr(e);
                if (!try self.emitArcConversion(e, dest.ty, have, indent)) {
                    try self.emitExpr(e, indent);
                }
                try out.writeAll(";\n");
            },
        }
    }

    // ── expressions ─────────────────────────────────────────────────────

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
            .struct_lit => |sl| try self.emitStructLit(sl, indent),
            .list_lit => |items| try self.emitListLit(items, indent),
            .block, .if_expr, .match_expr => try self.emitValueExpr(e, indent),
            .annotated => |a| try self.emitExpr(a.value, indent),
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

    fn emitCall(self: *Generator, c: anytype, indent: usize) EmitError!void {
        const out = self.writer;
        const callee = try self.resolveCallee(c.callee, c.args.len);
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
                    try self.emitArgLike(arg, try self.lowerType(&p.ty, p.ownership), indent);
                    continue;
                }
            }
            try self.emitExpr(arg, indent);
        }
        try out.writeAll(")");
    }

    // ── arc retain and boxing (task 4b) ─────────────────────────────────

    /// The retain half of `docs/OWNERSHIP.md` R11, plus the unbox that makes
    /// the deliberate NON-retain expressible. Returns true when it emitted
    /// `arg` itself, false to let `emitArgLike` carry on.
    ///
    /// Every one of R11's four retain sites reaches this one function,
    /// because `emitArgLike` is already the single place this backend lowers
    /// a value into a position with a declared type: a `let` initializer
    /// (rule 3), a call argument (rules 1 and 2), a struct literal field
    /// (rule 4), a list element, and an assignment's right side. There is no
    /// second place to keep in step.
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
    /// An `owned` String or list PLACE is not boxed. `cell_arc_from_string`
    /// MOVES its argument into the box, and `borrowck.zig`'s `checkLet`
    /// moves an initializer place only for `.owned`, while an `.arc`
    /// argument merely `readPlace`s it (R10's move-into-arc is unimplemented
    /// in the front end). So the source local is still unmoved, the drop
    /// pass still schedules its `cell_string_free`, and boxing it here would
    /// emit a silent double free. Falling through instead leaves a C type
    /// error, which is loud, and which this backend's module comment already
    /// prefers over plausible wrong code. A literal, a call result, and a
    /// `shared` view are all boxed, because none of them is a local the drop
    /// pass will also free: the view case copies through
    /// `cell_string_from_str` and owns its characters outright.
    fn emitArcConversion(
        self: *Generator,
        arg: *const ast.Expr,
        want: CType,
        have: CType,
        indent: usize,
    ) EmitError!bool {
        const out = self.writer;

        if (have.shape == .arc and want.shape != .arc) {
            // `.ptr` is `void *`, so every cast below is a widening to the
            // pointee's own type and needs no intermediate.
            if (want.shape == .str) {
                try out.writeAll("cell_string_as_str((const cell_string_t *)");
                try self.emitExpr(arg, indent);
                try out.writeAll(".ptr)");
                return true;
            }
            if (want.shape == .slice and !want.pointer) {
                try out.writeAll("(*(const cell_slice_t *)");
                try self.emitExpr(arg, indent);
                try out.writeAll(".ptr)");
                return true;
            }
            if (want.pointer) {
                try out.print("(({s})", .{want.text});
                try self.emitExpr(arg, indent);
                try out.writeAll(".ptr)");
                return true;
            }
            // Anything else (an owned aggregate, say) would be a move out of
            // a shared box, which R10 forbids anyway. Fall through loud.
            return false;
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
                if (have.pointer or isPlace(arg)) return false;
                try out.writeAll("cell_arc_from_string(");
                try self.emitExpr(arg, indent);
                try out.writeAll(")");
                return true;
            },
            .slice => {
                if (have.pointer or isPlace(arg)) return false;
                try out.writeAll("cell_arc_from_slice(");
                try self.emitExpr(arg, indent);
                try out.writeAll(")");
                return true;
            },
            else => return false,
        }
    }

    /// Emit `arg` where a value of type `want` is required, inserting the
    /// address-of, dereference, or view conversion the ABI needs. Call-site
    /// ownership prefixes are `.annotated` wrappers; this still lowers from
    /// the callee signature, so `grow(buf, 16)` becomes `cell_grow(&buf, 16)`
    /// because `grow` takes `exclusive Buffer`, not because of a written prefix.
    fn emitArgLike(self: *Generator, arg: *const ast.Expr, want: CType, indent: usize) EmitError!void {
        const out = self.writer;
        const have = try self.inferExpr(arg);

        // Both arc directions are answered FIRST, before any of the
        // address-of and dereference rules below. An arc handle is a struct
        // by value, so `&x` and `*x` are never the conversion it needs, and
        // letting the pointer rule see an `arc` place bound for a
        // `shared Record` parameter would emit `&x` (the address of the
        // handle) where the pointee is wanted.
        if (try self.emitArcConversion(arg, want, have, indent)) return;

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
    fn emitListLit(self: *Generator, items: []const ast.Expr, indent: usize) EmitError!void {
        const out = self.writer;
        if (items.len == 0) {
            try out.writeAll("cell_slice_empty()");
            return;
        }
        var elem = try self.inferExpr(&items[0]);
        if (elem.shape == .unknown or elem.shape == .unit) elem = CType.int64;
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
    /// section 2). The parser strips the quotes without unescaping, so the
    /// bytes are re-escaped here exactly as they are and the length is the
    /// count of those bytes.
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
            .list => CType.slice,
            .optional => |inner| blk: {
                const inst = try self.optionalInstance(inner);
                break :blk .{
                    .text = try std.fmt.allocPrint(self.arena, "{s}_t", .{inst.base}),
                    .shape = .optional,
                };
            },
            .result => CType.result,
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
        return .{ .text = text, .shape = base.shape, .pointer = true, .name = base.name };
    }

    fn namedType(self: *Generator, n: []const u8) Alloc!CType {
        if (eq(n, "Int") or eq(n, "Int64")) return CType.int64;
        if (eq(n, "Int32")) return .{ .text = "int32_t", .shape = .integer };
        if (eq(n, "UInt") or eq(n, "UInt64")) return .{ .text = "uint64_t", .shape = .integer };
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

    /// Which `CELL_DEFINE_OPTIONAL` instance covers `T?`. cell_rt.h predefines
    /// eight; anything else is instantiated at the top of the module.
    fn optionalInstance(self: *Generator, inner: *const ast.TypeExpr) Alloc!OptionalInst {
        switch (inner.*) {
            .name => |n| {
                if (eq(n, "Int") or eq(n, "Int64")) return .{ .base = "cell_opt_i64", .elem = "int64_t", .generated = false };
                if (eq(n, "UInt") or eq(n, "UInt64")) return .{ .base = "cell_opt_u64", .elem = "uint64_t", .generated = false };
                if (eq(n, "Int32")) return .{ .base = "cell_opt_i32", .elem = "int32_t", .generated = false };
                if (eq(n, "Float") or eq(n, "Float64")) return .{ .base = "cell_opt_f64", .elem = "double", .generated = false };
                if (eq(n, "Bool")) return .{ .base = "cell_opt_bool", .elem = "bool", .generated = false };
                if (eq(n, "Byte")) return .{ .base = "cell_opt_byte", .elem = "uint8_t", .generated = false };
                if (eq(n, "String")) return .{ .base = "cell_opt_str", .elem = "cell_str_t", .generated = false };
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
            .struct_lit => |sl| return try self.namedType(sl.name),
            .list_lit => return CType.slice,
            .block => |stmts| {
                if (stmts.len == 0) return CType.void_type;
                const last = stmts[stmts.len - 1];
                return switch (last.kind) {
                    .expr => |le| try self.inferExpr(&le),
                    else => CType.void_type,
                };
            },
            .if_expr => |i| return try self.inferExpr(i.then_body),
            .match_expr => |m| {
                if (m.arms.len == 0) return CType.void_type;
                return try self.inferExpr(m.arms[0].body);
            },
            .annotated => |a| return try self.inferExpr(a.value),
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

    fn lookupLocal(self: *Generator, name: []const u8) ?CType {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (eq(self.locals.items[i].name, name)) return self.locals.items[i].ty;
        }
        return null;
    }

    /// `droppable` is true only from the `let`/`var` call site; see
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

fn expectAbsent(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("\nexpected NOT to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.Found;
    }
}

test "every module includes the runtime header" {
    var e = try emitSource("pub fn f(copy v: Int) -> Int;");
    defer e.deinit();
    try expectContains(e.text, "#include \"cell_rt.h\"");
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

test "a string literal becomes a length-prefixed view with escapes preserved" {
    var e = try emitSource(
        \\pub fn main() {
        \\  print("a\"b")
        \\}
    );
    defer e.deinit();
    // The parser does not unescape, so the value holds a backslash and the
    // emitted literal must reproduce it exactly.
    try expectContains(e.text, "cell_str_from_parts(\"a\\\\\\\"b\", 4)");
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
    try expectContains(e.text, "cell_panic(\"non-exhaustive match in describe\");");
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
    try expectContains(e.text, "cell_panic(\"non-exhaustive match in f\")");
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
    try expectAbsent(e.text, "cell_string_free");
}

test "a value moved in one branch of an if is not dropped" {
    // The conservative case: borrowck marks `s` moved for the rest of the
    // function once ANY branch moves it (see borrowck.zig's module doc
    // comment and the `moved` field), even though the `if` here has no
    // `else` and the move might not have happened. Not dropping is the
    // safe direction: a real move here would make dropping a double free,
    // so this must also stay free of `cell_string_free`.
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
    try expectAbsent(e.text, "cell_string_free");
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
    try expectContains(
        e.text,
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
    // uses. R11 rule 2.
    try expectContains(e.text, "return cell_observe(cell_arc_clone(n));");
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
    try expectContains(
        e.text,
        "return cell_inspect(cell_string_as_str((const cell_string_t *)n.ptr));",
    );
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
    // R11 rule 4. Note the struct itself is never dropped by this backend,
    // so this retain leaks; that is the documented record-shape gap in the
    // drop pass, not a defect in the retain.
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

test "a returned arc parameter is neither retained nor released" {
    var e = try emitSource(
        \\pub fn share(arc n: String) -> arc String {
        \\  return n
        \\}
    );
    defer e.deinit();
    // R11 rule 3, still holding by construction: a parameter is not
    // droppable, so this function's pendingDrops is empty and the return
    // takes the byte-for-byte unchanged path. The caller's call-site retain
    // IS the reference handed back.
    try expectContains(e.text, "  return n;\n");
    try expectAbsent(e.text, "cell_arc_clone");
    try expectAbsent(e.text, "cell_arc_drop");
}

test "an owned String place bound as arc is left as a loud C type error" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned a = make()
        \\  let arc b = a
        \\}
    );
    defer e.deinit();
    // cell_arc_from_string MOVES its argument, and borrowck's checkLet moves
    // an initializer place only for `.owned` (R10's move-into-arc is
    // unimplemented in the front end), so `a` is still scheduled for its own
    // cell_string_free. Boxing here would emit a silent double free. Not
    // boxing leaves a type error the C compiler reports, which is this
    // backend's stated preference over plausible wrong code.
    try expectAbsent(e.text, "cell_arc_from_string");
    try expectContains(e.text, "cell_arc_t b = a;");
    try expectContains(e.text, "cell_string_free(&a);");
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

test "a parameter is never dropped" {
    var e = try emitSource(
        \\pub fn f(owned s: String) {
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free");
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
    // `sink` (an `owned` parameter), so it must NOT be freed here -- `sink`
    // itself does not free it either (decision: a parameter is never
    // dropped), so it leaks, which is the accepted gap this task documents,
    // not a bug this test is checking for. What this test actually proves
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
    // (see the task report's F4). And it does not show a clean heap: the
    // record's own reference is never released, since this backend does not
    // drop a `record` shape, so this program ends with the box alive at
    // count 1. That is the disclosed struct-field leak, and it is why
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
