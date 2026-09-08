//! Textual MLIR emission from `hir.Module`.
//!
//! DIALECTS, AND WHY THESE ONES.
//!
//! `func`, `arith`, `memref`, `cf`. All four are upstream, registered
//! dialects, so `mlir-opt` parses and verifies this output with
//! `allow_unregistered_dialects` off. Nothing here is a custom dialect and
//! nothing here is a placeholder operation.
//!
//! `cf` RATHER THAN `scf`, AND THIS WAS MEASURED THE HARD WAY. The first
//! version of this backend used `scf.if`, which reads better and is what a
//! structured source language suggests. It does not work here: Cell has early
//! `return`, and a `return` inside an `scf.if` region is invalid, because the
//! default dialect inside that region is not `func`. `mlir-opt` rejects it
//! with "Dialect `' not found for custom op 'return'", which is an obscure
//! message for a real structural mistake. Unstructured `cf` blocks are what a
//! front end with early exit actually wants, and they mirror the LLVM
//! backend's basic blocks one for one.
//!
//! The pipeline below is MEASURED on this machine, not quoted from
//! documentation. `mlir-opt` and `mlir-translate` are Homebrew LLVM 23.1.0 at
//! `/opt/homebrew/opt/llvm/bin`, which is not on PATH by default:
//!
//!   mlir-opt out.mlir --verify-each                        # parse + verify
//!   mlir-opt out.mlir --convert-scf-to-cf \
//!                     --expand-strided-metadata \
//!                     --finalize-memref-to-llvm \
//!                     --convert-cf-to-llvm \
//!                     --convert-func-to-llvm \
//!                     --convert-arith-to-llvm \
//!                     --reconcile-unrealized-casts -o low.mlir
//!   mlir-translate --mlir-to-llvmir low.mlir -o out.ll
//!   llc -filetype=obj out.ll -o out.o
//!   cc out.o cell_rt.o -o prog                             # prints 42
//!
//! That whole chain was run end to end before this file was written, so the
//! backend targets something known to lower rather than something that merely
//! parses.
//!
//! A NOTE ON THE REFERENCE IMPLEMENTATION. The CELL v2.0 tree emits MLIR too,
//! and its `PARITY.md` claims its semantic stage preserves the ownership
//! analysis. Its own import graph contradicts that: its `mlir.zig` imports only
//! its `hir.zig`, which holds no ownership state, and it emits `cell.alloc_local`
//! and `cell.drop` for every local unconditionally with the kind chosen by a
//! pure type-shape test. Its MLIR verification is three `grep -q` calls,
//! because `mlir-opt` was unavailable in the environment that wrote it.
//!
//! This backend therefore does NOT claim to carry ownership into MLIR. It
//! lowers values. When a `cell` dialect exists that a pass actually consumes,
//! that will be a different and larger claim, and it will need its own
//! evidence.
//!
//! SCOPE. Scalars and payload-free enums. Structs, String, `[T]`, `T?`,
//! `Result` and `arc` emit a `cannot lower` diagnostic at their span rather
//! than plausible-looking wrong IR.

const std = @import("std");
const Io = std.Io;
const ast = @import("ast.zig");
const hir = @import("hir.zig");
const abi = @import("abi.zig");
const types = @import("types.zig");
const diag = @import("diag.zig");

pub const EmitError = Io.Writer.Error || std.mem.Allocator.Error;

/// The verified lowering pipeline, exposed so a test and a CLI help text
/// cannot drift from the comment above.
pub const lowering_passes = [_][]const u8{
    "--expand-strided-metadata",
    "--finalize-memref-to-llvm",
    "--convert-cf-to-llvm",
    "--convert-func-to-llvm",
    "--convert-arith-to-llvm",
    "--reconcile-unrealized-casts",
};

const Value = struct {
    text: []const u8,
    ty: []const u8,
    /// When set, `text` is the ADDRESS of an aggregate of this type rather
    /// than the aggregate itself. A borrowed struct arrives as a pointer, the
    /// way the C backend spells `const cell_Buffer *`.
    ptr_to: ?[]const u8 = null,

    const none: Value = .{ .text = "", .ty = "" };

    fn isNone(self: Value) bool {
        return self.text.len == 0;
    }
};

pub fn emitModule(
    allocator: std.mem.Allocator,
    module: *const hir.Module,
    writer: *Io.Writer,
    diagnostics: *diag.Bag,
) EmitError!void {
    var e: Emitter = .{
        .arena = allocator,
        .out = writer,
        .module = module,
        .diagnostics = diagnostics,
    };
    try e.run();
}

const Emitter = struct {
    arena: std.mem.Allocator,
    out: *Io.Writer,
    module: *const hir.Module,
    diagnostics: *diag.Bag,

    ssa: u32 = 0,
    indent: usize = 2,
    slots: std.ArrayList([]const u8) = .empty,
    current_fn: []const u8 = "",
    /// Set once the current block has a terminator. MLIR, like LLVM, requires
    /// exactly one per block.
    returned: bool = false,
    block: u32 = 0,
    /// Where a `break` and a `continue` jump, for the innermost enclosing
    /// loop. Null outside a loop, which the typechecker already rejects.
    break_block: ?[]const u8 = null,
    continue_block: ?[]const u8 = null,
    /// Slot -> true when the slot is an `llvm.alloca` rather than a
    /// `memref.alloca`. A memref cannot hold an `!llvm.struct`: mlir-opt
    /// rejects it outright with "invalid memref element type", so aggregates
    /// use the llvm dialect's own allocation and access ops.
    slot_is_llvm: std.ArrayList(bool) = .empty,
    /// Slot -> pointee type, when the slot holds an ADDRESS. Borrowed STRUCT
    /// bindings, parameters and locals alike: an `exclusive` borrow has to
    /// write through to the caller's object, and a `let exclusive e = &mut
    /// buf` that stored the struct instead of its address handed every
    /// subsequent call a copy.
    slot_ptr_to: std.ArrayList(?[]const u8) = .empty,
    /// Slot -> true when the slot holds a BORROWED aggregate that this backend
    /// passes BY VALUE, so the slot is a copy and no write to it can reach the
    /// lender. `String`, `[T]` and `T?` are the cases: `paramType` makes only a
    /// borrowed struct an `!llvm.ptr`, while `codegen.applyOwnership` makes
    /// `exclusive String` a `cell_string_t *` and writes through it. A write
    /// here is therefore refused rather than emitted, per this backend's
    /// scalar-first contract.
    slot_borrowed_copy: std.ArrayList(bool) = .empty,
    /// String literals become llvm.mlir.global constants, emitted at module
    /// scope once the bodies that reference them are known.
    strings: std.ArrayList(StringGlobal) = .empty,

    /// Set when a string pattern needed memcmp, so its declaration is emitted.
    uses_memcmp: bool = false,
    /// The sret pointer's name while emitting a function that returns an
    /// aggregate indirectly, or null.
    sret: ?[]const u8 = null,

    const StringGlobal = struct { name: []const u8, bytes: []const u8 };

    fn run(self: *Emitter) EmitError!void {
        try self.out.print("// MLIR generated by the Cell compiler\n", .{});
        try self.out.print("// module: {s}\n", .{self.module.path});
        try self.out.print("// lower with: mlir-opt", .{});
        for (lowering_passes) |p| try self.out.print(" {s}", .{p});
        try self.out.print("\nmodule {{\n", .{});

        // Validate every DECLARED struct, not only the ones a signature
        // happens to mention.
        //
        // MLIR renders `!llvm.struct` structurally at each use, so an unused
        // struct is otherwise never examined and a module carrying an
        // unrepresentable field would be accepted here while the LLVM backend,
        // which emits type definitions up front, refuses it. Two backends
        // reaching different verdicts on one program is exactly the drift a
        // shared IR is supposed to prevent, so this checks eagerly.
        for (self.module.structs) |st| {
            if (self.structType(st.name) == null) {
                try self.unsupported(.none, try std.fmt.allocPrint(
                    self.arena,
                    "struct '{s}' has a field this backend cannot represent",
                    .{st.name},
                ));
            }
        }

        // Bodyless declarations become private func declarations, which is how
        // an external C ABI symbol is spelled in the func dialect.
        for (self.module.fns) |*f| {
            if (f.body != null) continue;
            const ret = self.mlirType(f.ret);
            if (ret == null and f.ret.tag() != .unit) {
                try self.unsupported(f.span, "declared return type");
                continue;
            }
            const sret_decl = abi.classifyReturn(self.module, f.ret) == .indirect;
            try self.out.print("  func.func private @{s}(", .{f.symbol});
            if (sret_decl) {
                // An aggregate too large for registers comes back through a
                // caller-allocated buffer passed as a hidden FIRST parameter.
                // Returning it by value here is not merely inconsistent with
                // the LLVM backend, it is WRONG at a C boundary: measured, a
                // 24-byte struct came back as 21248159473 instead of 21.
                const nat = self.mlirTypeOwned(f.ret, .owned) orelse "!llvm.struct<()>";
                try self.out.print("!llvm.ptr {{llvm.sret = {s}}}", .{nat});
                if (f.param_count != 0) try self.out.writeAll(", ");
            }
            var ok = true;
            for (f.params(), 0..) |p, i| {
                if (i != 0) try self.out.writeAll(", ");
                const t = self.paramType(p.ty, p.ownership) orelse {
                    ok = false;
                    break;
                };
                try self.out.writeAll(t);
            }
            if (!ok) {
                try self.unsupported(f.span, "declared parameter type");
                try self.out.writeAll(")\n");
                continue;
            }
            try self.out.writeAll(")");
            if (!sret_decl) {
                if (ret) |r| try self.out.print(" -> {s}", .{r});
            }
            try self.out.writeAll("\n");
        }

        // Bodies into a scratch buffer first, so the string globals they
        // reference are known before anything is printed. Same reason the LLVM
        // backend buffers.
        var body_buf: std.ArrayList(u8) = .empty;
        defer body_buf.deinit(self.arena);
        var body_writer = Io.Writer.Allocating.fromArrayList(self.arena, &body_buf);
        const saved = self.out;
        self.out = &body_writer.writer;
        for (self.module.fns) |*f| {
            if (f.body != null) try self.emitFn(f);
        }
        body_buf = body_writer.toArrayList();
        self.out = saved;

        // memcmp is real libc, unlike cell_str_eq which is `static inline`
        // and has no symbol.
        if (self.uses_memcmp) {
            try self.out.writeAll("  func.func private @memcmp(!llvm.ptr, !llvm.ptr, i64) -> i32\n");
        }
        for (self.strings.items) |g| {
            try self.out.print("  llvm.mlir.global private constant @{s}(\"", .{g.name});
            for (g.bytes) |b| {
                if (b >= 0x20 and b < 0x7f and b != '"' and b != '\\') {
                    try self.out.writeByte(b);
                } else {
                    try self.out.print("\\{X:0>2}", .{b});
                }
            }
            try self.out.writeAll("\") {addr_space = 0 : i32}\n");
        }

        try self.out.writeAll(body_buf.items);
        try self.out.writeAll("}\n");
    }

    fn emitFn(self: *Emitter, f: *const hir.Fn) EmitError!void {
        const body = f.body orelse return;
        const ret = self.mlirType(f.ret);
        if (ret == null and f.ret.tag() != .unit) {
            try self.unsupported(f.span, "return type");
            return;
        }

        self.ssa = 0;
        self.block = 0;
        self.indent = 2;
        self.returned = false;
        self.current_fn = f.name;
        self.slots.clearRetainingCapacity();
        try self.slots.resize(self.arena, f.bindings.len);
        self.slot_is_llvm.clearRetainingCapacity();
        try self.slot_is_llvm.resize(self.arena, f.bindings.len);
        for (self.slot_is_llvm.items) |*v| v.* = false;
        self.slot_ptr_to.clearRetainingCapacity();
        try self.slot_ptr_to.resize(self.arena, f.bindings.len);
        for (self.slot_ptr_to.items) |*v| v.* = null;
        self.slot_borrowed_copy.clearRetainingCapacity();
        try self.slot_borrowed_copy.resize(self.arena, f.bindings.len);
        for (self.slot_borrowed_copy.items) |*v| v.* = false;

        const uses_sret = abi.classifyReturn(self.module, f.ret) == .indirect;
        self.sret = if (uses_sret) "%sret" else null;
        try self.out.print("  func.func @{s}(", .{f.symbol});
        if (uses_sret) {
            const nat = self.mlirTypeOwned(f.ret, .owned) orelse "!llvm.struct<()>";
            try self.out.print("%sret: !llvm.ptr {{llvm.sret = {s}}}", .{nat});
            if (f.param_count != 0) try self.out.writeAll(", ");
        }
        for (f.params(), 0..) |p, i| {
            if (i != 0) try self.out.writeAll(", ");
            const t = self.paramType(p.ty, p.ownership) orelse {
                try self.unsupported(f.span, "parameter type");
                return;
            };
            try self.out.print("%arg{d}: {s}", .{ i, t });
        }
        try self.out.writeAll(")");
        if (!uses_sret) {
            if (ret) |r| try self.out.print(" -> {s}", .{r});
        }
        try self.out.writeAll(" {\n");
        self.indent = 4;

        for (f.bindings, 0..) |b, i| {
            // A BORROW, whatever binds it. The `i < f.param_count` this once
            // carried made the claim about parameters and applied it to every
            // binding, and a `let exclusive e = &mut buf` local therefore got
            // a struct-shaped slot, was initialized with a LOADED COPY of
            // `buf`, and handed that copy's address to every call. The write
            // then landed in the copy: 37 where the C backend, which spells
            // the same binding `cell_Buffer *e = &buf`, printed 38. Nothing
            // refused and nothing crashed. `examples/nll_dead_borrow.cell` has
            // used this shape since 41abc3b and could not catch it, because
            // its `grow` has an empty body and writes nothing.
            const borrowed = b.ownership == .shared or b.ownership == .exclusive;
            const is_ref = borrowed and b.ty.tag() == .struct_type;
            // A borrowed aggregate this backend passes by VALUE. The write
            // through it cannot reach the lender, and `emitAssign` refuses
            // rather than storing into the copy.
            self.slot_borrowed_copy.items[i] = borrowed and !is_ref and isAggregate(b.ty);
            const t = (if (is_ref) "!llvm.ptr" else self.mlirTypeOwned(b.ty, b.ownership)) orelse {
                // A binding this backend cannot type is reported once, here,
                // rather than at each use.
                try self.unsupported(f.span, "type of a local binding");
                self.slots.items[i] = "%unsupported";
                continue;
            };
            const name = try self.nextSsa();
            self.slots.items[i] = name;
            if (is_ref) {
                // Keep the LENDER's ADDRESS: an `exclusive` borrow must write
                // through to the borrowed object, and copying would drop every
                // mutation. For a parameter the address arrives in `%argN`;
                // for a local `emitLet` stores the address of the place the
                // initializer names.
                self.slot_is_llvm.items[i] = true;
                self.slot_ptr_to.items[i] = self.mlirType(b.ty) orelse "!llvm.ptr";
                const one = try self.nextSsa();
                try self.line("{s} = llvm.mlir.constant(1 : i64) : i64", .{one});
                try self.line("{s} = llvm.alloca {s} x !llvm.ptr : (i64) -> !llvm.ptr", .{ name, one });
            } else if (isAggregate(b.ty)) {
                // A memref cannot hold an !llvm.struct, so aggregates get an
                // llvm.alloca. Measured: mlir-opt rejects
                // memref<!llvm.struct<...>> with "invalid memref element type".
                self.slot_is_llvm.items[i] = true;
                const one = try self.nextSsa();
                try self.line("{s} = llvm.mlir.constant(1 : i64) : i64", .{one});
                try self.line("{s} = llvm.alloca {s} x {s} : (i64) -> !llvm.ptr", .{ name, one, t });
            } else {
                try self.line("{s} = memref.alloca() : memref<{s}>", .{ name, t });
            }
        }
        for (f.params(), 0..) |p, i| {
            const t = self.paramType(p.ty, p.ownership) orelse continue;
            try self.storeSlot(@intCast(i), t, try std.fmt.allocPrint(self.arena, "%arg{d}", .{i}));
        }

        for (body) |stmt| try self.emitStmt(&stmt);

        // func.func requires a terminator on every block.
        if (!self.returned) {
            if (uses_sret) {
                try self.line("return", .{});
            } else if (ret) |r| {
                const zero = try self.nextSsa();
                try self.line("{s} = arith.constant 0 : {s}", .{ zero, r });
                try self.line("return {s} : {s}", .{ zero, r });
            } else {
                try self.line("return", .{});
            }
        }

        self.indent = 2;
        try self.out.writeAll("  }\n");
    }

    /// Store `value` into slot `i`, using whichever dialect owns that slot.
    fn storeSlot(self: *Emitter, i: u32, ty: []const u8, value: []const u8) EmitError!void {
        if (i < self.slot_is_llvm.items.len and self.slot_is_llvm.items[i]) {
            try self.line("llvm.store {s}, {s} : {s}, !llvm.ptr", .{ value, self.slots.items[i], ty });
        } else {
            try self.line("memref.store {s}, {s}[] : memref<{s}>", .{ value, self.slots.items[i], ty });
        }
    }

    fn loadSlot(self: *Emitter, i: u32, ty: []const u8) EmitError![]const u8 {
        const out = try self.nextSsa();
        if (i < self.slot_is_llvm.items.len and self.slot_is_llvm.items[i]) {
            try self.line("{s} = llvm.load {s} : !llvm.ptr -> {s}", .{ out, self.slots.items[i], ty });
        } else {
            try self.line("{s} = memref.load {s}[] : memref<{s}>", .{ out, self.slots.items[i], ty });
        }
        return out;
    }

    fn emitStmt(self: *Emitter, stmt: *const hir.Stmt) EmitError!void {
        switch (stmt.kind) {
            .let => |l| try self.emitLet(l.slot, l.value),
            .assign => |a| try self.emitAssign(stmt, a.place, &a.value),
            .expr => |e| _ = try self.emitExpr(&e),
            .while_loop => |w| {
                const cond_b = self.nextBlock();
                const body_b = self.nextBlock();
                const end_b = self.nextBlock();

                try self.line("cf.br {s}", .{cond_b});
                try self.block_label(cond_b);
                const cond = try self.emitExpr(&w.cond);
                if (cond.isNone()) return;
                try self.line("cf.cond_br {s}, {s}, {s}", .{ cond.text, body_b, end_b });

                try self.block_label(body_b);
                const saved_break = self.break_block;
                const saved_continue = self.continue_block;
                self.break_block = end_b;
                self.continue_block = cond_b;
                for (w.body) |s2| try self.emitStmt(&s2);
                self.break_block = saved_break;
                self.continue_block = saved_continue;
                if (!self.returned) try self.line("cf.br {s}", .{cond_b});

                try self.block_label(end_b);
            },
            .brk => {
                const target = self.break_block orelse return;
                try self.line("cf.br {s}", .{target});
                self.returned = true;
            },
            .cont => {
                const target = self.continue_block orelse return;
                try self.line("cf.br {s}", .{target});
                self.returned = true;
            },
            .ret => |maybe| {
                if (maybe) |e| {
                    const val = try self.emitExpr(&e);
                    if (val.isNone()) {
                        try self.line("return", .{});
                    } else if (self.sret) |dest| {
                        try self.line("llvm.store {s}, {s} : {s}, !llvm.ptr", .{ val.text, dest, val.ty });
                        try self.line("return", .{});
                    } else {
                        try self.line("return {s} : {s}", .{ val.text, val.ty });
                    }
                } else {
                    try self.line("return", .{});
                }
                self.returned = true;
            },
        }
    }

    /// Where a write to a slot LANDS.
    ///
    /// A TOTAL verdict, deliberately, and the shape matters more than the
    /// three cases. The predicate this replaces was "does the place have a
    /// field path", an enumeration of the one form that was known to be
    /// unlowerable, and everything it did not enumerate fell through to a
    /// plain store into the slot. A borrowed slot holds the lender's ADDRESS,
    /// so that store overwrote the pointer instead of the object and the
    /// caller never saw the write. `AGENTS.md` records seven instances of
    /// exactly that reasoning failure in this repository: a derivation that
    /// enumerated some forms of a construct and asserted a property of all of
    /// them. So the undecidable case here is `refuse`, not `into_slot`, and a
    /// shape nobody anticipated fails closed with a `cannot lower` diagnostic
    /// rather than silently writing somewhere plausible.
    const AssignDest = union(enum) {
        /// Write the value into the slot itself. An owned or `copy` binding,
        /// or a borrowed PRIMITIVE, which `cell_rt.h` section 1 passes by
        /// value in every ownership mode and which the C backend also writes
        /// locally, so the two backends agree.
        into_slot,
        /// Write through the ADDRESS the slot holds, to the lender's object.
        /// Carries the pointee type; the value must match it exactly.
        through_slot: []const u8,
        /// This backend cannot say where the write would land. Refuse at the
        /// span. Carries the text for the diagnostic.
        refuse: []const u8,
    };

    fn assignDest(self: *Emitter, place: hir.Place) AssignDest {
        if (place.path.len != 0) return .{ .refuse = "assignment through a field path" };
        if (place.slot >= self.slots.items.len) {
            return .{ .refuse = "assignment to a binding with no slot" };
        }
        if (self.slot_ptr_to.items[place.slot]) |pointee| return .{ .through_slot = pointee };
        if (self.slot_borrowed_copy.items[place.slot]) {
            // `exclusive String`, `exclusive [T]` and `exclusive T?`.
            // `paramType` passes these BY VALUE while
            // `codegen.applyOwnership` makes them `cell_string_t *` and
            // friends and writes through the pointer, so the slot here is a
            // copy the lender cannot see. Emitting the store would be a
            // silent lost write AND, for `exclusive String`, a 24-byte
            // owning string stored into a 16-byte borrowed-view slot.
            //
            // DISCLOSED: `llvmemit.zig` has the identical hole and ACCEPTS
            // this shape today, so the first `examples/` entry that writes it
            // will split the gate's llvm-versus-mlir verdict stage. That is a
            // reason to fix that backend, not to emit a wrong store here.
            return .{ .refuse = "assignment to a borrowed aggregate this backend passes by value" };
        }
        return .into_slot;
    }

    fn emitAssign(
        self: *Emitter,
        stmt: *const hir.Stmt,
        place: hir.Place,
        value: *const hir.Expr,
    ) EmitError!void {
        // Classify BEFORE emitting the value: a refusal that first emits the
        // right-hand side leaves dead ops in a module nobody will lower.
        const dest = self.assignDest(place);
        if (dest == .refuse) {
            try self.unsupported(stmt.span, dest.refuse);
            return;
        }

        const val = try self.emitExpr(value);
        if (val.isNone()) return;

        switch (dest) {
            .into_slot => try self.storeSlot(place.slot, val.ty, val.text),
            .through_slot => |pointee| {
                if (!std.mem.eql(u8, val.ty, pointee)) {
                    // Borrowck refuses moving out of a borrow, so no construct
                    // reaches here with a mismatched value today. Saying so is
                    // still cheaper than the store: a pointer written where a
                    // struct belongs is exactly the defect above, one level in.
                    try self.unsupported(stmt.span, try std.fmt.allocPrint(
                        self.arena,
                        "a value of type {s} written through a borrow of {s}",
                        .{ val.ty, pointee },
                    ));
                    return;
                }
                // The slot holds the lender's address, so LOAD it and store
                // through that. Storing into the slot would overwrite the
                // pointer, which is what `reset(exclusive b) { b = Buffer {
                // len: 42 } }` did: the C backend printed 42 and this one
                // printed 37, with no diagnostic from either.
                const addr = try self.loadSlot(place.slot, "!llvm.ptr");
                try self.line("llvm.store {s}, {s} : {s}, !llvm.ptr", .{ val.text, addr, val.ty });
            },
            .refuse => unreachable, // handled above
        }
    }

    fn emitLet(self: *Emitter, slot: u32, value: ?hir.Expr) EmitError!void {
        const v = value orelse return;

        // A `let shared`/`let exclusive` of a struct binds an ADDRESS, the way
        // the C backend emits `cell_Buffer *e = &buf;`. Storing the loaded
        // struct here made the binding a COPY, and every call that then passed
        // `e` handed the callee that copy: a write through the borrow was lost
        // with no diagnostic.
        if (slot < self.slot_ptr_to.items.len and self.slot_ptr_to.items[slot] != null) {
            const addr = (try self.borrowAddress(&v)) orelse return;
            try self.line(
                "llvm.store {s}, {s} : !llvm.ptr, !llvm.ptr",
                .{ addr, self.slots.items[slot] },
            );
            return;
        }

        var val = try self.emitExpr(&v);
        if (val.isNone()) return;
        // A borrow bound where a VALUE belongs: `let copy c = s`. Storing
        // `val.text` would put the address in a struct-shaped slot and every
        // later read of `c` would see pointer bits. Load through it instead,
        // which is what this backend did before borrows in locals started
        // holding addresses, and what llvmemit.zig still emits.
        if (val.ptr_to) |pointee| val = try self.derefValue(val, pointee);
        try self.storeSlot(slot, val.ty, val.text);
    }

    /// Read the object a borrow points AT, as a value.
    ///
    /// The inverse of `borrowAddress`, and it exists because a borrow is a
    /// legal source for a value: `read(copy s)` where `s` is a borrow is what
    /// the C backend spells `cell_read(*s)`. Handing over `v.text` unloaded
    /// would put an ADDRESS where an aggregate belongs, in a slot or an
    /// operand typed for the aggregate, and mlir-opt accepts that happily
    /// because both are pointer sized. That is the same defect this file was
    /// opened to fix, one level over.
    fn derefValue(self: *Emitter, v: Value, pointee: []const u8) EmitError!Value {
        const loaded = try self.nextSsa();
        try self.line("{s} = llvm.load {s} : !llvm.ptr -> {s}", .{ loaded, v.text, pointee });
        return .{ .text = loaded, .ty = pointee };
    }

    /// The address a borrow initializer names, or null having already refused.
    ///
    /// Total by construction, and it does NOT reuse `emitArg`'s pointer path
    /// on purpose. That one spills a temporary to a fresh `llvm.alloca` and
    /// hands over its address, which is correct for a call argument, where
    /// nothing outlives the call and can observe a write back. It is exactly
    /// wrong for a binding: `let exclusive e = make()` would bind a copy that
    /// the initializer's own value cannot see written, which is the defect
    /// this function exists to remove. So a temporary is REFUSED here.
    fn borrowAddress(self: *Emitter, e: *const hir.Expr) EmitError!?[]const u8 {
        // A place with a slot of its own: its slot IS the object's address.
        // `placeSlot` unwraps the `.unary` borrow spellings, so `&mut buf`,
        // `&var buf`, `&exclusive buf` and `&buf` reach the same answer as the
        // bare `buf` that `hir.lower` produces for the keyword form.
        if (self.placeSlot(e)) |s| return self.slots.items[s];

        const v = try self.emitExpr(e);
        if (v.isNone()) return null;
        // Already an address: re-borrowing a borrow, `let exclusive f = e`.
        if (v.ptr_to != null) return v.text;

        try self.unsupported(e.span, "a borrow of a value that has no address");
        return null;
    }

    fn emitExpr(self: *Emitter, e: *const hir.Expr) EmitError!Value {
        switch (e.kind) {
            .int_const => |v| {
                const t = self.mlirType(e.ty) orelse "i64";
                const s = try self.nextSsa();
                try self.line("{s} = arith.constant {d} : {s}", .{ s, v, t });
                return .{ .text = s, .ty = t };
            },
            .bool_const => |v| {
                const s = try self.nextSsa();
                try self.line("{s} = arith.constant {d} : i1", .{ s, @intFromBool(v) });
                return .{ .text = s, .ty = "i1" };
            },
            .float_const => |v| {
                const t = self.mlirType(e.ty) orelse "f64";
                const s = try self.nextSsa();
                try self.line("{s} = arith.constant {d:.17} : {s}", .{ s, v, t });
                return .{ .text = s, .ty = t };
            },
            .enum_const => |ec| {
                const s = try self.nextSsa();
                try self.line("{s} = arith.constant {d} : i32", .{ s, ec.value });
                return .{ .text = s, .ty = "i32" };
            },
            .string_const => |bytes| {
                // A literal is a borrowed view: a pointer to static bytes plus
                // a length, which is cell_str_t. Built here rather than by
                // calling cell_str_from_parts, which is `static inline` and
                // has no symbol.
                const g = try self.internString(bytes);
                const p = try self.nextSsa();
                try self.line("{s} = llvm.mlir.addressof @{s} : !llvm.ptr", .{ p, g });
                const n = try self.nextSsa();
                try self.line("{s} = llvm.mlir.constant({d} : i64) : i64", .{ n, bytes.len });
                const u = try self.nextSsa();
                try self.line("{s} = llvm.mlir.undef : !llvm.struct<(ptr, i64)>", .{u});
                const v0 = try self.nextSsa();
                try self.line("{s} = llvm.insertvalue {s}, {s}[0] : !llvm.struct<(ptr, i64)>", .{ v0, p, u });
                const v1 = try self.nextSsa();
                try self.line("{s} = llvm.insertvalue {s}, {s}[1] : !llvm.struct<(ptr, i64)>", .{ v1, n, v0 });
                return .{ .text = v1, .ty = "!llvm.struct<(ptr, i64)>" };
            },
            .unresolved_ref => |name| {
                try self.unsupported(e.span, try std.fmt.allocPrint(
                    self.arena,
                    "unresolved identifier '{s}'",
                    .{name},
                ));
                return Value.none;
            },
            .ref => |slot| {
                if (slot < self.slot_ptr_to.items.len) {
                    if (self.slot_ptr_to.items[slot]) |pointee| {
                        const addr = try self.loadSlot(slot, "!llvm.ptr");
                        return .{ .text = addr, .ty = "!llvm.ptr", .ptr_to = pointee };
                    }
                }
                const t = self.mlirType(e.ty) orelse {
                    try self.unsupported(e.span, "type of a binding");
                    return Value.none;
                };
                return .{ .text = try self.loadSlot(slot, t), .ty = t };
            },
            .binary => |b| return self.emitBinary(e, b.op, b.left, b.right),
            .unary => |u| return self.emitUnary(u.op, u.operand),
            .call => |c| return self.emitCall(e, c.symbol, c.args),
            .block => |b| {
                for (b.stmts) |s| try self.emitStmt(&s);
                if (b.tail) |t| return self.emitExpr(t);
                return Value.none;
            },
            .if_expr => |ie| return self.emitIf(e, ie.cond, ie.then_body, ie.else_body),
            .match_expr => |me| return self.emitMatch(e, me.scrutinee, me.arms),
            .struct_lit => |sl| {
                const t = self.structType(sl.name) orelse {
                    try self.unsupported(e.span, "struct literal for an unrepresentable type");
                    return Value.none;
                };
                // llvm.mlir.undef then one insertvalue per field, which is the
                // same shape the LLVM backend emits.
                var acc = try self.nextSsa();
                try self.line("{s} = llvm.mlir.undef : {s}", .{ acc, t });
                for (sl.fields, 0..) |fe, i| {
                    const v = try self.emitExpr(&fe);
                    if (v.isNone()) return Value.none;
                    const next = try self.nextSsa();
                    try self.line("{s} = llvm.insertvalue {s}, {s}[{d}] : {s}", .{ next, v.text, acc, i, t });
                    acc = next;
                }
                return .{ .text = acc, .ty = t };
            },
            .field => |fe| {
                const base = try self.emitExpr(fe.base);
                if (base.isNone()) return base;
                const t = self.mlirType(fe.sel.ty) orelse {
                    try self.unsupported(e.span, "field type");
                    return Value.none;
                };
                if (base.ptr_to) |pointee| {
                    // Reading a field of a BORROWED aggregate goes through its
                    // address, the way the C backend writes `b->len`.
                    const gep = try self.nextSsa();
                    try self.line(
                        "{s} = llvm.getelementptr {s}[0, {d}] : (!llvm.ptr) -> !llvm.ptr, {s}",
                        .{ gep, base.text, fe.sel.index, pointee },
                    );
                    const loaded = try self.nextSsa();
                    try self.line("{s} = llvm.load {s} : !llvm.ptr -> {s}", .{ loaded, gep, t });
                    return .{ .text = loaded, .ty = t };
                }
                const out = try self.nextSsa();
                try self.line("{s} = llvm.extractvalue {s}[{d}] : {s}", .{ out, base.text, fe.sel.index, base.ty });
                return .{ .text = out, .ty = t };
            },
            .list_lit => |elems| {
                if (elems.len != 0) {
                    try self.unsupported(e.span, "a non-empty list literal is not lowered to MLIR yet");
                    return Value.none;
                }
                // cell_slice_empty() is `static inline` and has no symbol, so
                // the empty header is materialized here: null, 0, 0.
                const t = "!llvm.struct<(ptr, i64, i64)>";
                const nul = try self.nextSsa();
                try self.line("{s} = llvm.mlir.zero : !llvm.ptr", .{nul});
                const zero = try self.nextSsa();
                try self.line("{s} = llvm.mlir.constant(0 : i64) : i64", .{zero});
                const u = try self.nextSsa();
                try self.line("{s} = llvm.mlir.undef : {s}", .{ u, t });
                const v0 = try self.nextSsa();
                try self.line("{s} = llvm.insertvalue {s}, {s}[0] : {s}", .{ v0, nul, u, t });
                const v1 = try self.nextSsa();
                try self.line("{s} = llvm.insertvalue {s}, {s}[1] : {s}", .{ v1, zero, v0, t });
                const v2 = try self.nextSsa();
                try self.line("{s} = llvm.insertvalue {s}, {s}[2] : {s}", .{ v2, zero, v1, t });
                return .{ .text = v2, .ty = t };
            },
        }
    }

    fn emitBinary(
        self: *Emitter,
        e: *const hir.Expr,
        op: ast.BinaryOp,
        left_e: *const hir.Expr,
        right_e: *const hir.Expr,
    ) EmitError!Value {
        // arith has no short-circuit form, so `and`/`or` become an scf.if that
        // evaluates the right operand only on the branch that needs it.
        if (op == .and_op or op == .or_op) return self.emitShortCircuit(op, left_e, right_e);

        const left = try self.emitExpr(left_e);
        if (left.isNone()) return left;
        const right = try self.emitExpr(right_e);
        if (right.isNone()) return right;

        const float = isFloat(left.ty);
        const unsigned = left_e.ty.tag() == .uint or left_e.ty.tag() == .byte;

        const s = try self.nextSsa();
        switch (op) {
            .add, .sub, .mul, .div => {
                const mnemonic: []const u8 = switch (op) {
                    .add => if (float) "arith.addf" else "arith.addi",
                    .sub => if (float) "arith.subf" else "arith.subi",
                    .mul => if (float) "arith.mulf" else "arith.muli",
                    .div => if (float) "arith.divf" else if (unsigned) "arith.divui" else "arith.divsi",
                    else => unreachable,
                };
                try self.line("{s} = {s} {s}, {s} : {s}", .{ s, mnemonic, left.text, right.text, left.ty });
                return .{ .text = s, .ty = self.mlirType(e.ty) orelse left.ty };
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                if (float) {
                    // Ordered predicates: a NaN operand compares false, which
                    // is what a source-level comparison means.
                    const pred: []const u8 = switch (op) {
                        .eq => "oeq",
                        .ne => "one",
                        .lt => "olt",
                        .le => "ole",
                        .gt => "ogt",
                        .ge => "oge",
                        else => unreachable,
                    };
                    try self.line("{s} = arith.cmpf {s}, {s}, {s} : {s}", .{ s, pred, left.text, right.text, left.ty });
                } else {
                    const pred: []const u8 = switch (op) {
                        .eq => "eq",
                        .ne => "ne",
                        .lt => if (unsigned) "ult" else "slt",
                        .le => if (unsigned) "ule" else "sle",
                        .gt => if (unsigned) "ugt" else "sgt",
                        .ge => if (unsigned) "uge" else "sge",
                        else => unreachable,
                    };
                    try self.line("{s} = arith.cmpi {s}, {s}, {s} : {s}", .{ s, pred, left.text, right.text, left.ty });
                }
                return .{ .text = s, .ty = "i1" };
            },
            .and_op, .or_op => unreachable,
        }
    }

    fn emitShortCircuit(
        self: *Emitter,
        op: ast.BinaryOp,
        left_e: *const hir.Expr,
        right_e: *const hir.Expr,
    ) EmitError!Value {
        const slot = try self.nextSsa();
        try self.line("{s} = memref.alloca() : memref<i1>", .{slot});

        const left = try self.emitExpr(left_e);
        if (left.isNone()) return left;
        try self.line("memref.store {s}, {s}[] : memref<i1>", .{ left.text, slot });

        const rhs_b = self.nextBlock();
        const end_b = self.nextBlock();
        // `a and b` evaluates b only when a is true; `a or b` only when false.
        if (op == .and_op) {
            try self.line("cf.cond_br {s}, {s}, {s}", .{ left.text, rhs_b, end_b });
        } else {
            try self.line("cf.cond_br {s}, {s}, {s}", .{ left.text, end_b, rhs_b });
        }

        try self.block_label(rhs_b);
        const right = try self.emitExpr(right_e);
        if (!right.isNone()) {
            try self.line("memref.store {s}, {s}[] : memref<i1>", .{ right.text, slot });
        }
        if (!self.returned) try self.line("cf.br {s}", .{end_b});

        try self.block_label(end_b);
        const out = try self.nextSsa();
        try self.line("{s} = memref.load {s}[] : memref<i1>", .{ out, slot });
        return .{ .text = out, .ty = "i1" };
    }

    fn emitUnary(self: *Emitter, op: ast.UnaryOp, operand_e: *const hir.Expr) EmitError!Value {
        if (op == .ref_shared or op == .ref_exclusive) return self.emitExpr(operand_e);

        const operand = try self.emitExpr(operand_e);
        if (operand.isNone()) return operand;
        const s = try self.nextSsa();
        switch (op) {
            .neg => {
                if (isFloat(operand.ty)) {
                    try self.line("{s} = arith.negf {s} : {s}", .{ s, operand.text, operand.ty });
                } else {
                    const zero = try self.nextSsa();
                    try self.line("{s} = arith.constant 0 : {s}", .{ zero, operand.ty });
                    try self.line("{s} = arith.subi {s}, {s} : {s}", .{ s, zero, operand.text, operand.ty });
                }
                return .{ .text = s, .ty = operand.ty };
            },
            .not => {
                const one = try self.nextSsa();
                try self.line("{s} = arith.constant 1 : i1", .{one});
                try self.line("{s} = arith.xori {s}, {s} : i1", .{ s, operand.text, one });
                return .{ .text = s, .ty = "i1" };
            },
            .ref_shared, .ref_exclusive => unreachable,
        }
    }

    /// The slot an argument expression names, when it names one.
    ///
    /// `.unary` with `ref_shared` or `ref_exclusive` is transparent here, the
    /// same way `emitUnary` forwards those two ops straight to their operand
    /// and the same way `llvmemit.zig` unwraps them. That is not tidiness: the
    /// five borrow spellings this language defines as identical do NOT reach
    /// codegen as one shape. `look(shared buf)` arrives as `.ref` because
    /// `hir.lower` consumes the written prefix, while `look(&buf)`,
    /// `grow(&mut buf)`, `grow(&var buf)` and `grow(&exclusive buf)` arrive
    /// wrapped. A caller that matched only the bare `.ref` would pass the
    /// caller's object for one spelling and a copy for the other four, which is
    /// exactly the divergence `examples/borrows.cell` exists to forbid.
    fn placeSlot(self: *Emitter, e: *const hir.Expr) ?u32 {
        var current = e;
        while (true) {
            switch (current.kind) {
                .unary => |u| {
                    if (u.op != .ref_shared and u.op != .ref_exclusive) return null;
                    current = u.operand;
                },
                .ref => |slot| {
                    if (slot >= self.slots.items.len) return null;
                    // A borrowed parameter's slot holds the caller's ADDRESS,
                    // not the object, so its slot name is not the address of an
                    // aggregate. `emitExpr` already returns that pointer with
                    // `ptr_to` set, and the caller handles it before asking.
                    if (self.slot_ptr_to.items[slot] != null) return null;
                    // A scalar lives in a memref.alloca, whose name is a memref
                    // value rather than an !llvm.ptr.
                    if (!self.slot_is_llvm.items[slot]) return null;
                    return slot;
                },
                else => return null,
            }
        }
    }

    /// Emit one call argument, already shaped for the parameter it will fill.
    /// `want` is null for a callee with no signature, where there is nothing to
    /// shape it to and the natural value is all there is.
    fn emitArg(self: *Emitter, arg: *const hir.Expr, want: ?[]const u8) EmitError!Value {
        // A place passed to a pointer parameter is answered BEFORE the value is
        // emitted, because emitting it would `llvm.load` an aggregate nothing
        // then reads. Its slot IS the object's address, an `llvm.alloca`, which
        // is what the C backend spells `&buf`, and passing it is what keeps an
        // `exclusive` borrow writing through to the caller's object rather than
        // to a copy the callee's mutations die with.
        if (want) |w| {
            if (std.mem.eql(u8, w, "!llvm.ptr")) {
                if (self.placeSlot(arg)) |slot| {
                    return .{ .text = self.slots.items[slot], .ty = "!llvm.ptr" };
                }
            }
        }

        const v = try self.emitExpr(arg);
        if (v.isNone()) return v;
        const w = want orelse return v;
        if (std.mem.eql(u8, v.ty, w)) return v;

        if (std.mem.eql(u8, w, "!llvm.ptr")) {
            // Already an address: a borrowed aggregate forwarded onwards.
            if (v.ptr_to != null) return .{ .text = v.text, .ty = "!llvm.ptr", .ptr_to = v.ptr_to };

            // A temporary with no home of its own. Give it one and hand over
            // its address. Nothing can observe a write back through it, so the
            // copy costs no correctness the way it would for a place.
            const one = try self.nextSsa();
            try self.line("{s} = llvm.mlir.constant(1 : i64) : i64", .{one});
            const tmp = try self.nextSsa();
            try self.line("{s} = llvm.alloca {s} x {s} : (i64) -> !llvm.ptr", .{ tmp, one, v.ty });
            try self.line("llvm.store {s}, {s} : {s}, !llvm.ptr", .{ v.text, tmp, v.ty });
            return .{ .text = tmp, .ty = "!llvm.ptr" };
        }

        // A borrow consumed BY VALUE, `read(copy s)`. The C backend spells this
        // `cell_read(*s)`, so load through the borrow rather than passing the
        // address, which the mismatch refusal below would otherwise reject
        // outright for a shape all three backends agree on.
        if (v.ptr_to) |pointee| {
            if (std.mem.eql(u8, pointee, w)) return self.derefValue(v, w);
        }

        // Any other mismatch. No construct produces one today, so rather than
        // emit a reinterpreting spill nobody has ever measured, say so at the
        // span: refusing is this backend's contract, and a silent mismatch is
        // exactly what produced the defect this function was written to fix.
        try self.unsupported(arg.span, try std.fmt.allocPrint(
            self.arena,
            "an argument of type {s} cannot lower to a parameter declared {s}",
            .{ v.ty, w },
        ));
        return Value.none;
    }

    fn emitCall(
        self: *Emitter,
        e: *const hir.Expr,
        symbol: ?[]const u8,
        args: []const hir.Expr,
    ) EmitError!Value {
        const sym = symbol orelse {
            try self.unsupported(e.span, "a computed callee is not lowered to MLIR yet");
            return Value.none;
        };

        var vals = try self.arena.alloc(Value, args.len);
        const modes = switch (e.kind) {
            .call => |c| c.modes,
            else => &[_]hir.ArgMode{},
        };
        for (args, 0..) |a, i| {
            // Place the argument the way the CALLEE's parameter is DECLARED,
            // not the way the value happened to be computed. `paramType` is the
            // same function that printed the declaration, so the two can no
            // longer disagree; when this did not exist, a `shared Buffer`
            // parameter was declared `!llvm.ptr` and then called with an
            // `!llvm.struct<(i64)>`, and mlir-opt refused the module.
            const want: ?[]const u8 = if (i < modes.len)
                self.paramType(a.ty, modes[i].param)
            else
                null;
            vals[i] = try self.emitArg(&a, want);
            if (vals[i].isNone()) return Value.none;
        }

        const via_sret = abi.classifyReturn(self.module, e.ty) == .indirect;
        var sret_slot: []const u8 = "";
        if (via_sret) {
            // The callee writes into a buffer WE allocate and returns nothing,
            // so the result exists before the call rather than after it.
            const nat = self.mlirTypeOwned(e.ty, .owned) orelse "!llvm.struct<()>";
            const one = try self.nextSsa();
            try self.line("{s} = llvm.mlir.constant(1 : i64) : i64", .{one});
            sret_slot = try self.nextSsa();
            try self.line("{s} = llvm.alloca {s} x {s} : (i64) -> !llvm.ptr", .{ sret_slot, one, nat });
        }
        const ret = if (via_sret) null else self.mlirType(e.ty);
        var result: []const u8 = "";
        if (ret != null) {
            result = try self.nextSsa();
            try self.linePrefix();
            try self.out.print("{s} = ", .{result});
        } else {
            try self.linePrefix();
        }
        try self.out.print("call @{s}(", .{sym});
        if (via_sret) {
            try self.out.writeAll(sret_slot);
            if (vals.len != 0) try self.out.writeAll(", ");
        }
        for (vals, 0..) |v, i| {
            if (i != 0) try self.out.writeAll(", ");
            try self.out.writeAll(v.text);
        }
        try self.out.writeAll(") : (");
        if (via_sret) {
            try self.out.writeAll("!llvm.ptr");
            if (vals.len != 0) try self.out.writeAll(", ");
        }
        for (vals, 0..) |v, i| {
            if (i != 0) try self.out.writeAll(", ");
            try self.out.writeAll(v.ty);
        }
        try self.out.writeAll(") -> ");
        if (ret) |r| try self.out.writeAll(r) else try self.out.writeAll("()");
        try self.out.writeAll("\n");

        if (via_sret) {
            const nat = self.mlirTypeOwned(e.ty, .owned) orelse "!llvm.struct<()>";
            const loaded = try self.nextSsa();
            try self.line("{s} = llvm.load {s} : !llvm.ptr -> {s}", .{ loaded, sret_slot, nat });
            return .{ .text = loaded, .ty = nat };
        }
        if (ret) |r| return .{ .text = result, .ty = r };
        return Value.none;
    }

    fn emitIf(
        self: *Emitter,
        e: *const hir.Expr,
        cond_e: *const hir.Expr,
        then_e: *const hir.Expr,
        else_e: ?*const hir.Expr,
    ) EmitError!Value {
        const produces = else_e != null and e.ty.tag() != .unit;
        var slot: []const u8 = "";
        var slot_ty: []const u8 = "";
        if (produces) {
            slot_ty = self.mlirType(e.ty) orelse "i64";
            slot = try self.nextSsa();
            try self.line("{s} = memref.alloca() : memref<{s}>", .{ slot, slot_ty });
        }

        const cond = try self.emitExpr(cond_e);
        if (cond.isNone()) return Value.none;

        const then_b = self.nextBlock();
        const else_b = self.nextBlock();
        const end_b = self.nextBlock();

        try self.line("cf.cond_br {s}, {s}, {s}", .{
            cond.text,
            then_b,
            if (else_e != null) else_b else end_b,
        });

        try self.block_label(then_b);
        const then_val = try self.emitExpr(then_e);
        if (produces and !then_val.isNone()) {
            try self.line("memref.store {s}, {s}[] : memref<{s}>", .{ then_val.text, slot, slot_ty });
        }
        if (!self.returned) try self.line("cf.br {s}", .{end_b});

        if (else_e) |eb| {
            try self.block_label(else_b);
            const else_val = try self.emitExpr(eb);
            if (produces and !else_val.isNone()) {
                try self.line("memref.store {s}, {s}[] : memref<{s}>", .{ else_val.text, slot, slot_ty });
            }
            if (!self.returned) try self.line("cf.br {s}", .{end_b});
        }

        try self.block_label(end_b);

        if (!produces) return Value.none;
        const out = try self.nextSsa();
        try self.line("{s} = memref.load {s}[] : memref<{s}>", .{ out, slot, slot_ty });
        return .{ .text = out, .ty = slot_ty };
    }

    /// `match` becomes a chain of compare-and-branch blocks, one per arm,
    /// which is the same shape the LLVM backend emits and the same shape the C
    /// backend's if/else chain compiles to.
    /// Compare a string against a literal, producing an i1.
    ///
    /// Faithful to `cell_str_eq` (runtime/cell_rt.h:184), which is `static
    /// inline` and has no symbol. The order matters and is preserved: lengths,
    /// then the empty case, then the null guard, then memcmp. Calling memcmp
    /// on a null pointer or a mismatched length is undefined behaviour.
    fn emitStringEq(self: *Emitter, scrutinee: Value, literal: []const u8) EmitError!Value {
        const st = "!llvm.struct<(ptr, i64)>";
        const len = try self.nextSsa();
        try self.line("{s} = llvm.extractvalue {s}[1] : {s}", .{ len, scrutinee.text, st });
        const want = try self.nextSsa();
        try self.line("{s} = arith.constant {d} : i64", .{ want, literal.len });
        const len_eq = try self.nextSsa();
        try self.line("{s} = arith.cmpi eq, {s}, {s} : i64", .{ len_eq, len, want });

        if (literal.len == 0) return .{ .text = len_eq, .ty = "i1" };

        self.uses_memcmp = true;
        const g = try self.internString(literal);

        const res = try self.nextSsa();
        try self.line("{s} = memref.alloca() : memref<i1>", .{res});
        const false_v = try self.nextSsa();
        try self.line("{s} = arith.constant 0 : i1", .{false_v});
        try self.line("memref.store {s}, {s}[] : memref<i1>", .{ false_v, res });

        const cmp_b = self.nextBlock();
        const mem_b = self.nextBlock();
        const end_b = self.nextBlock();
        try self.line("cf.cond_br {s}, {s}, {s}", .{ len_eq, cmp_b, end_b });

        try self.block_label(cmp_b);
        const ptr = try self.nextSsa();
        try self.line("{s} = llvm.extractvalue {s}[0] : {s}", .{ ptr, scrutinee.text, st });
        const nul = try self.nextSsa();
        try self.line("{s} = llvm.mlir.zero : !llvm.ptr", .{nul});
        const is_null = try self.nextSsa();
        try self.line("{s} = llvm.icmp \"eq\" {s}, {s} : !llvm.ptr", .{ is_null, ptr, nul });
        try self.line("cf.cond_br {s}, {s}, {s}", .{ is_null, end_b, mem_b });

        try self.block_label(mem_b);
        const lit = try self.nextSsa();
        try self.line("{s} = llvm.mlir.addressof @{s} : !llvm.ptr", .{ lit, g });
        const n = try self.nextSsa();
        try self.line("{s} = arith.constant {d} : i64", .{ n, literal.len });
        const r = try self.nextSsa();
        try self.line("{s} = call @memcmp({s}, {s}, {s}) : (!llvm.ptr, !llvm.ptr, i64) -> i32", .{ r, ptr, lit, n });
        const zero = try self.nextSsa();
        try self.line("{s} = arith.constant 0 : i32", .{zero});
        const eq = try self.nextSsa();
        try self.line("{s} = arith.cmpi eq, {s}, {s} : i32", .{ eq, r, zero });
        try self.line("memref.store {s}, {s}[] : memref<i1>", .{ eq, res });
        try self.line("cf.br {s}", .{end_b});

        try self.block_label(end_b);
        const out = try self.nextSsa();
        try self.line("{s} = memref.load {s}[] : memref<i1>", .{ out, res });
        return .{ .text = out, .ty = "i1" };
    }

    fn emitMatch(
        self: *Emitter,
        e: *const hir.Expr,
        scrutinee_e: *const hir.Expr,
        arms: []const hir.Arm,
    ) EmitError!Value {
        const produces = e.ty.tag() != .unit;
        var slot: []const u8 = "";
        var slot_ty: []const u8 = "";
        if (produces) {
            slot_ty = self.mlirType(e.ty) orelse "i64";
            slot = try self.nextSsa();
            try self.line("{s} = memref.alloca() : memref<{s}>", .{ slot, slot_ty });
        }

        const scrutinee = try self.emitExpr(scrutinee_e);
        if (scrutinee.isNone()) return Value.none;

        const end_b = self.nextBlock();

        for (arms) |arm| {
            const body_b = self.nextBlock();
            const next_b = self.nextBlock();

            // A guarded arm is never a catch-all: `_ if c` can fail.
            const catch_all = arm.guard == null and switch (arm.pattern.kind) {
                .wildcard, .binding => true,
                else => false,
            };
            const pattern_matches_all = switch (arm.pattern.kind) {
                .wildcard, .binding => true,
                else => false,
            };

            if (catch_all) {
                try self.line("cf.br {s}", .{body_b});
            } else if (pattern_matches_all) {
                const g = try self.emitExpr(arm.guard.?);
                if (g.isNone()) return Value.none;
                try self.line("cf.cond_br {s}, {s}, {s}", .{ g.text, body_b, next_b });
            } else {
                // A string pattern is not a single comparison, so it is
                // computed first and the arm chain branches on the result.
                var cmp: []const u8 = undefined;
                if (arm.pattern.kind == .string) {
                    const eq = try self.emitStringEq(scrutinee, arm.pattern.kind.string);
                    if (eq.isNone()) return Value.none;
                    cmp = eq.text;
                } else {
                    const test_text: ?[]const u8 = switch (arm.pattern.kind) {
                        .int => |v| try std.fmt.allocPrint(self.arena, "{d}", .{v}),
                        .bool => |v| try std.fmt.allocPrint(self.arena, "{d}", .{@intFromBool(v)}),
                        .enum_variant => |ev| try std.fmt.allocPrint(self.arena, "{d}", .{ev.value}),
                        .float, .string => null,
                        .wildcard, .binding => unreachable,
                    };
                    const tt = test_text orelse {
                        try self.unsupported(arm.span, "this match pattern is not lowered to MLIR yet");
                        return Value.none;
                    };
                    const konst = try self.nextSsa();
                    try self.line("{s} = arith.constant {s} : {s}", .{ konst, tt, scrutinee.ty });
                    const c = try self.nextSsa();
                    try self.line("{s} = arith.cmpi eq, {s}, {s} : {s}", .{
                        c, scrutinee.text, konst, scrutinee.ty,
                    });
                    cmp = c;
                }
                if (arm.guard) |g_expr| {
                    // Its own block, so the guard runs only when the pattern
                    // matched. A guard may call a function.
                    const guard_b = self.nextBlock();
                    try self.line("cf.cond_br {s}, {s}, {s}", .{ cmp, guard_b, next_b });
                    try self.block_label(guard_b);
                    const g = try self.emitExpr(g_expr);
                    if (g.isNone()) return Value.none;
                    try self.line("cf.cond_br {s}, {s}, {s}", .{ g.text, body_b, next_b });
                } else {
                    try self.line("cf.cond_br {s}, {s}, {s}", .{ cmp, body_b, next_b });
                }
            }

            try self.block_label(body_b);
            if (arm.pattern.kind == .binding) {
                const bslot = arm.pattern.kind.binding;
                try self.storeSlot(bslot, scrutinee.ty, scrutinee.text);
            }
            const body_val = try self.emitExpr(arm.body);
            if (produces and !body_val.isNone()) {
                try self.line("memref.store {s}, {s}[] : memref<{s}>", .{ body_val.text, slot, slot_ty });
            }
            if (!self.returned) try self.line("cf.br {s}", .{end_b});

            try self.block_label(next_b);
            if (catch_all) break;
        }

        // Falling out of every arm means nothing matched. The C and LLVM
        // backends panic here, so this one does too: three backends that
        // disagree about a runtime trap are three different languages.
        // `cf.assert` rather than a call to `cell_panic`. Calling the runtime
        // would need a global string and an `llvm.mlir.global`, which drags the
        // llvm dialect into what is otherwise a clean func/arith/memref/cf
        // module.
        //
        // BE PRECISE ABOUT WHAT THIS BUYS. `cf.assert` is a registered op and
        // it lowers to an abort, so the trap is real and all three backends do
        // abort on a non-exhaustive match. But the message is an MLIR
        // attribute: it survives into the emitted MLIR, where it is readable,
        // and it does NOT reach the running program the way the C and LLVM
        // backends' `cell_panic` message does. That asymmetry is recorded here
        // rather than glossed, because a reader comparing the three backends
        // would otherwise assume the diagnostics match at runtime.
        const never = try self.nextSsa();
        try self.line("{s} = arith.constant 0 : i1", .{never});
        try self.line("cf.assert {s}, \"non-exhaustive match in {s}\"", .{ never, self.current_fn });
        try self.line("cf.br {s}", .{end_b});

        try self.block_label(end_b);

        if (!produces) return Value.none;
        const out = try self.nextSsa();
        try self.line("{s} = memref.load {s}[] : memref<{s}>", .{ out, slot, slot_ty });
        return .{ .text = out, .ty = slot_ty };
    }

    // -- helpers ------------------------------------------------------------

    /// True when a type is carried as an `!llvm.struct`, which changes how it
    /// is allocated, stored, loaded and projected.
    fn isAggregate(ty: hir.Ty) bool {
        return switch (ty.tag()) {
            .struct_type, .string, .optional, .list => true,
            else => false,
        };
    }

    /// The in-memory type of a binding. String is the one type whose size
    /// depends on ownership: `shared` is a borrowed {ptr, len}, `owned` an
    /// owning {ptr, len, cap}.
    /// The type a parameter is written as. A borrowed AGGREGATE is a pointer,
    /// matching what the C backend declares (`const cell_Buffer *`). Passing
    /// it by value is a real defect: linking that against the C signature
    /// reads the pointer as the struct's first field.
    ///
    /// A borrowed String is NOT a pointer: cell_str_t is already a borrowed
    /// view and passes by value, which cell_rt.h section 2 fixes.
    fn paramType(self: *Emitter, ty: hir.Ty, own: hir.Ownership) ?[]const u8 {
        if (ty.tag() == .struct_type) {
            switch (own) {
                .shared, .exclusive => return "!llvm.ptr",
                else => {},
            }
        }
        return self.mlirTypeOwned(ty, own);
    }

    fn mlirTypeOwned(self: *Emitter, ty: hir.Ty, own: hir.Ownership) ?[]const u8 {
        if (ty.tag() == .string) {
            return switch (own) {
                .shared, .exclusive => "!llvm.struct<(ptr, i64)>",
                .owned, .copy => "!llvm.struct<(ptr, i64, i64)>",
                .arc => null,
            };
        }
        return self.mlirType(ty);
    }

    fn mlirType(self: *Emitter, ty: hir.Ty) ?[]const u8 {
        if (ty.tag() == .struct_type) return self.structType(ty.struct_type);
        return switch (ty) {
            .int, .uint => "i64",
            .int32 => "i32",
            .float => "f64",
            .float32 => "f32",
            .boolean => "i1",
            .byte => "i8",
            .enum_type => "i32",
            // `unit` has no MLIR type: a func with no result simply omits it,
            // which the callers handle by testing for null.
            .unit => null,
            .struct_type => unreachable, // handled above
            // A String in expression position is a borrowed view, matching
            // llvmemit. A BINDING's String may be owning, which is why slots
            // and parameters go through mlirTypeOwned.
            .string => "!llvm.struct<(ptr, i64)>",
            .optional => |inner| blk: {
                const it = self.mlirType(inner.*) orelse break :blk null;
                break :blk std.fmt.allocPrint(self.arena, "!llvm.struct<(i8, {s})>", .{it}) catch null;
            },
            // One type-erased header for every element type, per cell_rt.h
            // section 3: elem_size travels at the call site, not in the type.
            .list => "!llvm.struct<(ptr, i64, i64)>",
            .result, .func, .unknown => null,
        };
    }

    /// `!llvm.struct<(i64, f64)>`. The llvm dialect's struct type is
    /// STRUCTURAL, with no name, so the whole field list is rendered at every
    /// use rather than declared once.
    fn structType(self: *Emitter, name: []const u8) ?[]const u8 {
        const decl = self.module.findStruct(name) orelse return null;
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(self.arena, "!llvm.struct<(") catch return null;
        for (decl.fields, 0..) |f, i| {
            if (i != 0) buf.appendSlice(self.arena, ", ") catch return null;
            // Per-field OWNERSHIP, not just the field's type. abi.structLayout
            // already sizes a struct this way, and rendering it without
            // ownership let a struct with an `arc String` field be emitted
            // here while abi called the same struct unclassified.
            const t = self.mlirTypeOwned(f.ty, f.ownership) orelse return null;
            buf.appendSlice(self.arena, t) catch return null;
        }
        buf.appendSlice(self.arena, ")>") catch return null;
        return buf.items;
    }

    fn internString(self: *Emitter, bytes: []const u8) EmitError![]const u8 {
        for (self.strings.items) |g| {
            if (std.mem.eql(u8, g.bytes, bytes)) return g.name;
        }
        const name = try std.fmt.allocPrint(self.arena, "cellstr{d}", .{self.strings.items.len});
        try self.strings.append(self.arena, .{ .name = name, .bytes = bytes });
        return name;
    }

    fn nextBlock(self: *Emitter) []const u8 {
        const b = std.fmt.allocPrint(self.arena, "^bb{d}", .{self.block}) catch "^bb0";
        self.block += 1;
        return b;
    }

    /// Open a new basic block. A label is written at the function's own indent
    /// rather than the statement indent, which is the conventional MLIR shape
    /// and makes the block structure readable.
    fn block_label(self: *Emitter, name: []const u8) EmitError!void {
        try self.out.splatByteAll(' ', self.indent - 2);
        try self.out.print("{s}:\n", .{name});
        self.returned = false;
    }

    fn nextSsa(self: *Emitter) EmitError![]const u8 {
        const s = try std.fmt.allocPrint(self.arena, "%{d}", .{self.ssa});
        self.ssa += 1;
        return s;
    }

    fn linePrefix(self: *Emitter) EmitError!void {
        try self.out.splatByteAll(' ', self.indent);
    }

    fn line(self: *Emitter, comptime fmt: []const u8, args: anytype) EmitError!void {
        try self.linePrefix();
        try self.out.print(fmt, args);
        try self.out.writeAll("\n");
    }

    fn unsupported(self: *Emitter, span: hir.Span, what: []const u8) EmitError!void {
        try self.diagnostics.err(
            self.arena,
            span,
            try std.fmt.allocPrint(self.arena, "cannot lower to MLIR: {s}", .{what}),
        );
    }
};

fn isFloat(t: []const u8) bool {
    return std.mem.eql(u8, t, "f64") or std.mem.eql(u8, t, "f32");
}

// ---------------------------------------------------------------------------
// Tests
//
// The execution test below needs `mlir-opt`, `mlir-translate` and `llc`, which
// are NOT on PATH on this machine: they live in the Homebrew LLVM keg. When
// they are missing the test SKIPS rather than passes, because a test that
// silently succeeds when its subject is absent is worse than no test. The
// reference implementation's MLIR verification was three `grep -q` calls for
// exactly this reason, and it is the gap this file exists to close.
// ---------------------------------------------------------------------------

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

const tool_dirs = [_][]const u8{
    "/opt/homebrew/opt/llvm/bin",
    "/usr/local/opt/llvm/bin",
    "/usr/lib/llvm/bin",
};

/// Absolute path to an LLVM/MLIR tool, or null when it is not installed.
fn findTool(gpa: std.mem.Allocator, name: []const u8) !?[]const u8 {
    for (tool_dirs) |dir| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
        const f = std.Io.Dir.cwd().openFile(std.testing.io, path, .{}) catch {
            gpa.free(path);
            continue;
        };
        f.close(std.testing.io);
        return path;
    }
    return null;
}

const Emitted = struct {
    arena: std.heap.ArenaAllocator,
    buf: []u8,
    text: []const u8,
    bag: diag.Bag,

    fn deinit(self: *Emitted) void {
        std.testing.allocator.free(self.buf);
        self.bag.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

fn emitSource(source: []const u8) !Emitted {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var lex = lexer.Lexer.init(source, "t.cell");
    const tokens = try lex.tokenizeAll(a);
    var p = parser.Parser.init(a, tokens.items, "t.cell");
    var module = try p.parseModule();

    const buf = try std.testing.allocator.alloc(u8, 64 * 1024);
    errdefer std.testing.allocator.free(buf);
    var w = Io.Writer.fixed(buf);

    var bag: diag.Bag = .init("t.cell", source);
    var lowered = try hir.lower(a, &module, &bag);
    try emitModule(a, &lowered, &w, &bag);

    return .{ .arena = arena, .buf = buf, .text = w.buffered(), .bag = bag };
}

fn expectContains(text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("wanted:\n{s}\nin:\n{s}\n", .{ needle, text });
        return error.MissingText;
    }
}

/// Lower, translate, assemble, link and RUN emitted MLIR; returns what the
/// program printed, which the caller frees.
///
/// One copy of the pipeline rather than one per test. There were two before
/// this, and a third and a fourth were about to land: a run test is the ONLY
/// assertion that catches a backend which emits a module that verifies,
/// lowers, links, runs and computes the wrong number, which is precisely the
/// defect class this file keeps producing. Duplicating a hundred lines per
/// such test is how they stop being written.
///
/// Skips rather than passes when `mlir-opt`, `mlir-translate` or `llc` is
/// absent: they live in the Homebrew LLVM keg and are not on PATH here, and a
/// test that quietly succeeds when its subject is missing is worse than none.
fn runThroughMlir(gpa: std.mem.Allocator, mlir_text: []const u8) ![]u8 {
    const io = std.testing.io;

    const mlir_opt = (try findTool(gpa, "mlir-opt")) orelse return error.SkipZigTest;
    defer gpa.free(mlir_opt);
    const mlir_translate = (try findTool(gpa, "mlir-translate")) orelse return error.SkipZigTest;
    defer gpa.free(mlir_translate);
    const llc = (try findTool(gpa, "llc")) orelse return error.SkipZigTest;
    defer gpa.free(llc);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.mlir", .data = mlir_text });
    // The MLIR path emits no C entry point of its own, so the driver supplies
    // one. That asymmetry with the LLVM backend is deliberate: `main` is a C
    // ABI concept and the func dialect has no reason to know about it.
    try tmp.dir.writeFile(io, .{
        .sub_path = "drv.c",
        .data = "extern void cell_main(void);\nint main(void){cell_main();return 0;}\n",
    });

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, mlir_opt);
    try argv.append(gpa, "m.mlir");
    for (lowering_passes) |p| try argv.append(gpa, p);
    try argv.append(gpa, "-o");
    try argv.append(gpa, "low.mlir");

    const lowered = try std.process.run(gpa, io, .{ .argv = argv.items, .cwd = .{ .dir = tmp.dir } });
    defer gpa.free(lowered.stdout);
    defer gpa.free(lowered.stderr);
    if (!lowered.term.success()) {
        std.debug.print("mlir-opt rejected emitted MLIR:\n{s}\n--- mlir ---\n{s}\n", .{ lowered.stderr, mlir_text });
        return error.MlirOptRejectedOutput;
    }

    const translated = try std.process.run(gpa, io, .{
        .argv = &.{ mlir_translate, "--mlir-to-llvmir", "low.mlir", "-o", "m.ll" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(translated.stdout);
    defer gpa.free(translated.stderr);
    if (!translated.term.success()) {
        std.debug.print("mlir-translate failed:\n{s}\n", .{translated.stderr});
        return error.MlirTranslateFailed;
    }

    const compiled = try std.process.run(gpa, io, .{
        .argv = &.{ llc, "-filetype=obj", "m.ll", "-o", "m.o" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(compiled.stdout);
    defer gpa.free(compiled.stderr);
    if (!compiled.term.success()) return error.LlcFailed;

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{cwd_buf[0..cwd_len]});
    defer gpa.free(rt_c);
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{cwd_buf[0..cwd_len]});
    defer gpa.free(include);

    const linked = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "m.o", "drv.c", rt_c, "-I", include, "-o", "prog" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(linked.stdout);
    defer gpa.free(linked.stderr);
    if (!linked.term.success()) {
        std.debug.print("link failed:\n{s}\n", .{linked.stderr});
        return error.LinkFailed;
    }

    const run = try std.process.run(gpa, io, .{ .argv = &.{"./prog"}, .cwd = .{ .dir = tmp.dir } });
    defer gpa.free(run.stderr);
    errdefer gpa.free(run.stdout);
    // BOTH signals. A program that prints the right answer and then dies is
    // not a passing program.
    if (!run.term.success()) return error.ProgramFailed;
    return run.stdout;
}

test "a function becomes a func.func with memref slots" {
    var e = try emitSource(
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "func.func @cell_add(%arg0: i64, %arg1: i64) -> i64");
    try expectContains(e.text, "memref.alloca() : memref<i64>");
    try expectContains(e.text, "arith.addi");
    try expectContains(e.text, "return");
}

test "a bodyless declaration becomes a private func.func" {
    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
    );
    defer e.deinit();
    try expectContains(e.text, "func.func private @cell_print_int(i64)");
}

test "control flow uses the cf dialect, not scf" {
    // scf.if cannot contain a `return`, and Cell has early return. This test
    // pins the choice so nobody "tidies" it back to scf.
    var e = try emitSource(
        \\pub fn choose(shared n: Int) -> Int {
        \\  if n < 10 { return n + 1 } else { return n * 2 }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cf.cond_br");
    try expectContains(e.text, "^bb");
    try std.testing.expect(std.mem.indexOf(u8, e.text, "scf.") == null);
}

test "a non-exhaustive match asserts rather than inventing a runtime symbol" {
    var e = try emitSource(
        \\pub enum Color { Red, Green }
        \\pub fn f(copy c: Color) -> Int {
        \\  return match c { Color.Red => 1, }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cf.assert");
    try expectContains(e.text, "non-exhaustive match in f");
}

test "a struct lowers to an llvm.struct with llvm.alloca for its slot" {
    // Structs used to be refused here. A memref CANNOT hold an !llvm.struct:
    // mlir-opt rejects memref<!llvm.struct<...>> with "invalid memref element
    // type", measured. So aggregates use the llvm dialect's own allocation and
    // access ops while scalars keep using memref.
    var e = try emitSource(
        \\pub struct Point { copy x: Float, copy y: Float }
        \\pub fn main() { let owned p = Point { x: 1.0, y: 2.0 } }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "!llvm.struct<(f64, f64)>");
    try expectContains(e.text, "llvm.alloca");
    try expectContains(e.text, "llvm.insertvalue");
}

test "a field read uses llvm.extractvalue" {
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn read(copy b: Buffer) -> Int { return b.len }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "llvm.extractvalue");
}

test "arc is still refused, because R11 is not implemented" {
    // [T] used to be the example here and now lowers. `arc` is the durable
    // one: retain and release are not inserted, so placing a cell_arc_t would
    // be half a feature.
    var e = try emitSource(
        \\pub fn g(arc s: String) -> Int;
    );
    defer e.deinit();
    try std.testing.expect(e.bag.hasErrors());
    var found = false;
    for (e.bag.list.items) |d| {
        if (std.mem.indexOf(u8, d.message, "cannot lower to MLIR") != null) found = true;
    }
    try std.testing.expect(found);
}

test "emitted MLIR verifies, lowers, translates, links and prints the right answer" {
    const gpa = std.testing.allocator;

    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub enum Color { Red, Green, Blue }
        \\pub fn classify(copy c: Color) -> Int {
        \\  return match c { Color.Red => 10, Color.Green => 20, _ => 30, }
        \\}
        \\pub fn choose(shared n: Int) -> Int {
        \\  if n < 10 { return n + 1 } else { return n * 2 }
        \\}
        \\pub fn main() {
        \\  let copy a = choose(shared 3)
        \\  let copy b = classify(copy Color.Green)
        \\  print_int(a + b)
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());

    const out = try runThroughMlir(gpa, e.text);
    defer gpa.free(out);
    // The C backend prints 24 for this same source. Three backends, one answer.
    try std.testing.expectEqualStrings("24\n", out);
}

test "a String lowers, and a literal builds its borrowed view" {
    var e = try emitSource(
        \\pub fn println(shared msg: String);
        \\pub fn main() { println(shared "hi") }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "llvm.mlir.global private constant @cellstr0(\"hi\")");
    try expectContains(e.text, "llvm.mlir.addressof @cellstr0");
    try expectContains(e.text, "!llvm.struct<(ptr, i64)>");
}

test "a borrowed struct is a pointer here too, matching the C backend" {
    // MLIR had the same defect the LLVM backend had: it passed a borrowed
    // aggregate by value while the C backend declares `const cell_Buffer *`.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn read(shared b: Buffer) -> Int { return b.len }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "func.func @cell_read(%arg0: !llvm.ptr)");
    try expectContains(e.text, "llvm.getelementptr");
}

test "a borrowed struct is a pointer at the CALL SITE too, in all five spellings" {
    // The test above pinned the DECLARATION and stopped there, so the call site
    // went on loading the pointee and passing it by value. Every emitted call
    // contradicted its own callee, mlir-opt refused the module outright with
    // "'func.call' op operand type mismatch", and examples/borrows.cell shipped
    // that way behind a green gate: tools/check.sh compared emit VERDICTS, and
    // an accepted module that cannot lower is still an accepted module. The
    // LLVM backend got the same program right, which is how the divergence was
    // found, because the two backends share hir.
    //
    // All five spellings are asserted, not one. `look(shared buf)` reaches
    // emitCall as .ref, while `look(&buf)` and the three unique-borrow sigils
    // reach it wrapped in .unary{ref_shared|ref_exclusive}, which emitUnary
    // forwards straight through. A fix that matched only the bare .ref would
    // pass the address for the keyword and a lost-mutation COPY for the sigils,
    // and examples/borrows.cell exists precisely to prove the five identical.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn look(shared b: Buffer) { }
        \\pub fn grow(exclusive b: Buffer) { }
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 0 }
        \\  look(shared buf)
        \\  look(&buf)
        \\  grow(exclusive buf)
        \\  grow(&mut buf)
        \\  grow(&var buf)
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "func.func @cell_look(%arg0: !llvm.ptr)");
    try expectContains(e.text, "func.func @cell_grow(%arg0: !llvm.ptr)");

    // The exact text the defect produced, pinned so it cannot come back.
    try std.testing.expect(std.mem.indexOf(u8, e.text, "(!llvm.struct<(i64)>) -> ()") == null);

    // Every call passes the SAME operand: the one slot `buf` lives in. This is
    // the assertion that catches a fix which handles some spellings and not
    // others, which a bare "mlir-opt stopped complaining" never would.
    const slot = "%0";
    var calls: usize = 0;
    var it = std.mem.splitScalar(u8, e.text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (!std.mem.startsWith(u8, trimmed, "call @cell_")) continue;
        calls += 1;
        const want = try std.fmt.allocPrint(
            e.arena.allocator(),
            "({s}) : (!llvm.ptr) -> ()",
            .{slot},
        );
        if (std.mem.indexOf(u8, trimmed, want) == null) {
            std.debug.print("call does not pass {s} as !llvm.ptr:\n{s}\nin:\n{s}\n", .{ slot, trimmed, e.text });
            return error.BorrowArgumentNotAPointer;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), calls);
}

test "a whole-value write through an exclusive borrow stores through the slot" {
    // THE SHAPE of the fix, pinned so a later "simplification" back to a plain
    // storeSlot is loud. A borrowed parameter's slot holds the CALLER's
    // address, so `b = Buffer { ... }` has to load that address and store
    // through it. Storing into the slot overwrote the pointer instead, and the
    // caller's object never changed: silent, verified by mlir-opt, linked, ran.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn reset(exclusive b: Buffer) { b = Buffer { len: 42 } }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    // The slot is loaded as a pointer, and the struct goes through THAT.
    try expectContains(e.text, "%5 = llvm.load %0 : !llvm.ptr -> !llvm.ptr");
    try expectContains(e.text, "llvm.store %4, %5 : !llvm.struct<(i64)>, !llvm.ptr");
    // The exact text the defect produced: the struct written into the slot.
    try std.testing.expect(std.mem.indexOf(
        u8,
        e.text,
        "llvm.store %4, %0 : !llvm.struct<(i64)>, !llvm.ptr",
    ) == null);
}

test "an owned local's assignment still writes the slot itself" {
    // The neighbour, pinned by exact text so the dereference above cannot
    // spread to a binding that owns its value. codegen.zig's af4134f made the
    // same pairing for the C backend and for the same reason.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn f() {
        \\  var owned b = Buffer { len: 1 }
        \\  b = Buffer { len: 2 }
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    // No dereference: the slot IS the object, so nothing loads an address.
    try std.testing.expect(std.mem.indexOf(u8, e.text, "llvm.load %0 : !llvm.ptr -> !llvm.ptr") == null);
    try expectContains(e.text, "llvm.store %7, %0 : !llvm.struct<(i64)>, !llvm.ptr");
}

test "a whole-value write through an exclusive borrow reaches the CALLER" {
    // THE ANSWER, which is the assertion that matters: the shape test above
    // would pass against a backend that emitted the right ops for the wrong
    // object. Pre-fix this program printed 1, not 37, because the whole-value
    // store of a 16-byte struct into an 8-byte pointer slot also overflowed
    // it; the one-field version printed 37. Both are wrong and neither said
    // so. `examples/write_through_whole.cell` is the corpus form and runs the
    // same arithmetic through all three backends.
    const gpa = std.testing.allocator;
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int, copy step: Int }
        \\pub fn print_int(copy value: Int);
        \\pub fn bump(exclusive b: Buffer) {
        \\  b = Buffer { len: b.len + b.step, step: b.step }
        \\}
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 37, step: 1 }
        \\  bump(exclusive buf)
        \\  bump(&mut buf)
        \\  bump(&var buf)
        \\  bump(&exclusive buf)
        \\  bump(exclusive &buf)
        \\  print_int(buf.len)
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());

    const out = try runThroughMlir(gpa, e.text);
    defer gpa.free(out);
    // 37 plus one per spelling. All five, because the five are one group:
    // 41 would mean exactly one of them lost its write.
    try std.testing.expectEqualStrings("42\n", out);
}

test "a borrow held in a LOCAL binds the lender's address, not a copy" {
    // THE OTHER SIDE OF THE CALL, and a second bug rather than a consequence
    // of the first. `let exclusive e = &mut buf` stored a LOADED COPY of `buf`
    // into a struct-shaped slot, so `bump(exclusive e)` handed the callee that
    // copy's address and the write landed in it. Measured: the C backend, which
    // spells this binding `cell_Buffer *e = &buf;`, printed 38 while this one
    // printed 37, and the write-through fix above alone still printed 37.
    //
    // examples/nll_dead_borrow.cell has used this shape since 41abc3b and could
    // never have caught it: its `grow` has an empty body and writes nothing.
    // The shape does NOT go into examples/, because llvmemit.zig has the
    // identical caller-side hole and still prints 37, and a corpus entry would
    // fail the gate's answer stage on a backend outside this file.
    const gpa = std.testing.allocator;
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn print_int(copy value: Int);
        \\pub fn bump(exclusive b: Buffer) { b = Buffer { len: b.len + 1 } }
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 37 }
        \\  let exclusive e = &mut buf
        \\  bump(exclusive e)
        \\  print_int(buf.len)
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());

    // The binding's slot holds a pointer and is initialized with an ADDRESS.
    try expectContains(e.text, "llvm.alloca %3 x !llvm.ptr : (i64) -> !llvm.ptr");
    try expectContains(e.text, "llvm.store %0, %2 : !llvm.ptr, !llvm.ptr");

    const out = try runThroughMlir(gpa, e.text);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("38\n", out);
}

test "a borrow consumed BY VALUE is loaded through, not passed as an address" {
    // The other direction of the same slot change, and it went WRONG first.
    // Once a borrow in a local held an address, `read(copy s)` reached
    // emitArg with an `!llvm.ptr` where a struct was wanted and hit the
    // mismatch refusal, an accept-to-refuse flip on a shape all three
    // backends agree on: the C backend spells it `cell_read(*s)`. And
    // `let copy c = s` was worse than a refusal, storing the ADDRESS into a
    // struct-shaped slot, which mlir-opt accepts because both are pointer
    // sized and which makes every later read of `c` see pointer bits.
    const gpa = std.testing.allocator;
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn print_int(copy value: Int);
        \\pub fn read(copy b: Buffer) -> Int { return b.len }
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 20 }
        \\  let shared s = &buf
        \\  let copy c = s
        \\  print_int(read(copy s) + c.len + 2)
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    // Two loads, not one: the slot yields the address, the address the value.
    try expectContains(e.text, "%9 = llvm.load %2 : !llvm.ptr -> !llvm.ptr");
    try expectContains(e.text, "%10 = llvm.load %9 : !llvm.ptr -> !llvm.struct<(i64)>");

    const out = try runThroughMlir(gpa, e.text);
    defer gpa.free(out);
    // 20 read through the borrow, 20 through the copy of it, plus 2.
    try std.testing.expectEqualStrings("42\n", out);
}

test "a write to a borrowed aggregate passed BY VALUE is refused, not lost" {
    // The third axis of the same defect, and the one the reported program
    // cannot show. `paramType` makes only a borrowed STRUCT an `!llvm.ptr`,
    // while `codegen.applyOwnership` makes `exclusive String` a
    // `cell_string_t *` and writes through it. So the slot here is a copy the
    // caller cannot see, and emitting the store would be a silent lost write
    // AND a 24-byte owning string stored into a 16-byte borrowed-view slot.
    //
    // Refusing is this backend's documented contract. DISCLOSED: llvmemit.zig
    // has the identical hole and accepts this shape today.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn setit(exclusive s: String) { s = make() }
    );
    defer e.deinit();
    try std.testing.expect(e.bag.hasErrors());
    var found = false;
    for (e.bag.list.items) |d| {
        if (std.mem.indexOf(u8, d.message, "passes by value") != null) found = true;
    }
    try std.testing.expect(found);
}

test "a borrowed PRIMITIVE parameter still writes its own slot, matching C" {
    // The neighbour of the refusal above. cell_rt.h section 1 passes every
    // primitive by value in every ownership mode, and codegen.applyOwnership
    // returns the base type unchanged for one, so `n = 5` writes the callee's
    // own copy in BOTH backends. Refusing it here would break agreement with a
    // backend that is right.
    var e = try emitSource(
        \\pub fn bump(exclusive n: Int) { n = 5 }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "memref.store");
}

test "assignment through a field path is still refused, and refused FIRST" {
    // Unchanged behaviour, pinned because emitAssign now classifies before it
    // emits the right-hand side. The refusal must still fire, and it must no
    // longer leave the value's ops behind in a module nobody will lower.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn bump(exclusive b: Buffer) { b.len = b.len + 5 }
    );
    defer e.deinit();
    try std.testing.expect(e.bag.hasErrors());
    var found = false;
    for (e.bag.list.items) |d| {
        if (std.mem.indexOf(u8, d.message, "field path") != null) found = true;
    }
    try std.testing.expect(found);
}

test "a let-bound borrow of a temporary is refused rather than bound to a copy" {
    // borrowck accepts `let exclusive e = mk()` today, and emitArg's pointer
    // path would happily spill the call result to a fresh alloca and hand back
    // its address. That is correct for an ARGUMENT, where nothing outlives the
    // call to observe a write back, and wrong for a BINDING. borrowAddress
    // therefore refuses instead of reusing emitArg: the undecidable case fails
    // closed.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn mk() -> Buffer;
        \\pub fn f() { let exclusive e = mk() }
    );
    defer e.deinit();
    try std.testing.expect(e.bag.hasErrors());
    var found = false;
    for (e.bag.list.items) |d| {
        if (std.mem.indexOf(u8, d.message, "no address") != null) found = true;
    }
    try std.testing.expect(found);
}

test "an unused struct with an unrepresentable field is still refused" {
    // MLIR renders !llvm.struct structurally at each USE, so an unused struct
    // was never examined and this module was accepted here while the LLVM
    // backend refused it. Two backends disagreeing about one program is the
    // drift a shared IR exists to prevent, so declared structs are validated
    // eagerly. The unrepresentable field was [Byte] until lists landed; it is
    // an arc field now, which lasts until OWNERSHIP R11.
    var e = try emitSource(
        \\pub struct Holder { arc name: String }
        \\pub fn unrelated() -> Int { return 1 }
    );
    defer e.deinit();
    try std.testing.expect(e.bag.hasErrors());
    var found = false;
    for (e.bag.list.items) |d| {
        if (std.mem.indexOf(u8, d.message, "cannot represent") != null) found = true;
    }
    try std.testing.expect(found);
}

test "a string pattern guards before calling memcmp here too" {
    var e = try emitSource(
        \\pub fn f(shared s: String) -> Int { return match s { "yes" => 1, _ => 0, } }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "func.func private @memcmp");
    try expectContains(e.text, "llvm.icmp \"eq\"");
    try expectContains(e.text, "call @memcmp(");
}

test "[T] lowers as the runtime's type-erased slice header" {
    var e = try emitSource(
        \\pub struct Buffer { owned data: [Byte], copy len: Int }
        \\pub fn main() { let owned b = Buffer { data: [], len: 9 } }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "!llvm.struct<(ptr, i64, i64)>");
    try expectContains(e.text, "llvm.mlir.zero : !llvm.ptr");
}

test "a struct return over 16 bytes uses sret, because by value is WRONG" {
    // This was not a consistency gap, it was a miscompile, and the plan said
    // otherwise until it was measured. Returning a 24-byte struct by value
    // from MLIR and calling it from C gave 21248159473 where the answer is 21.
    // The LLVM backend already used sret and was already correct.
    var e = try emitSource(
        \\pub struct Big { copy a: Int, copy b: Int, copy c: Int }
        \\pub fn make(copy n: Int) -> Big { return Big { a: n, b: n, c: n } }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "llvm.sret = !llvm.struct<(i64, i64, i64)>");
    try expectContains(e.text, "llvm.store");
}

test "an sret round trip computes the right answer through the whole pipeline" {
    const gpa = std.testing.allocator;

    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub struct Big { copy a: Int, copy b: Int, copy c: Int }
        \\pub fn make(copy n: Int) -> Big { return Big { a: n, b: n, c: n } }
        \\pub fn sum(copy v: Big) -> Int { return v.a + v.b + v.c }
        \\pub fn main() { print_int(sum(copy make(copy 7))) }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());

    const out = try runThroughMlir(gpa, e.text);
    defer gpa.free(out);
    // 7 * 3. By value this came back as 21248159473.
    try std.testing.expectEqualStrings("21\n", out);
}
