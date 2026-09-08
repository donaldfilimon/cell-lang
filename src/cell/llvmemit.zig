//! Textual LLVM IR emission from `hir.Module`.
//!
//! SCOPE, AND WHY IT IS SCALAR-FIRST.
//!
//! The C backend gets its calling convention for free: it writes C, and the C
//! compiler places aggregates according to the platform ABI. This backend
//! writes LLVM IR, so the moment a function takes or returns an aggregate that
//! crosses the C boundary, *we* are choosing the convention, and an LLVM
//! `{ptr, i64}` parameter is not what AAPCS64 does with a `cell_str_t`.
//!
//! Two facts make that worse and are measured, not assumed:
//!
//!   1. The host here is arm64 (AAPCS64), not System V x86-64.
//!   2. Every aggregate CONSTRUCTOR in `runtime/cell_rt.h` is `static inline`
//!      -- `cell_str_from_parts`, `cell_str_empty`, `cell_string_as_str`,
//!      `cell_slice_empty`, the whole `CELL_DEFINE_OPTIONAL` family, every
//!      `cell_ok_*`. A `static inline` function has no symbol, so this backend
//!      cannot call any of them. It would have to materialize those structs
//!      itself, from layouts derived from the header rather than guessed.
//!
//! So this slice crosses the C boundary only through SCALAR-ABI symbols:
//! `cell_print_int(int64_t)`, `cell_assert(bool)`, `cell_panic(const char*)`,
//! `cell_cxx_probe()`, `cell_swift_probe()`. Cell-to-Cell calls inside one
//! module are ABI-consistent by construction whatever their shape, so struct
//! locals and struct-passing between Cell functions are in scope.
//!
//! Anything out of scope emits a `cannot lower` diagnostic AT ITS SPAN and
//! stops. It does not emit plausible-looking wrong IR. That distinction is the
//! whole point: a diagnostic is a fact about the compiler, a wrong store is a
//! crash in someone's program.
//!
//! SSA. Slots are allocas, loaded and stored at every use. That is naive on
//! purpose: `opt -passes=mem2reg` promotes them, and the alternative is
//! building dominance and phi placement in a frontend that does not need it.
//!
//! NO TARGET TRIPLE IS EMITTED. Measured: `clang -x ir` warns
//! `-Woverride-module` when the IR carries a triple and the driver supplies
//! one. Letting the driver decide keeps the same text working on any host.

const std = @import("std");
const Io = std.Io;
const ast = @import("ast.zig");
const hir = @import("hir.zig");
const types = @import("types.zig");
const diag = @import("diag.zig");
const abi = @import("abi.zig");

pub const EmitError = Io.Writer.Error || std.mem.Allocator.Error;

/// An emitted LLVM value: its textual operand and its LLVM type.
/// An emitted value is ALWAYS a value, never an address.
///
/// It used to carry a `ptr_to` field: when set, `text` was the address of an
/// aggregate rather than the aggregate, and `emitExpr`'s `.ref` arm set it for
/// every borrowed binding. Two consumers knew about it and the rest did not,
/// so a borrow reaching any other value position handed over POINTER BITS
/// where an aggregate belonged. Measured at 9e591ab, both silent:
///
///     let copy c = b          stored an 8-byte address into a struct slot
///     sum(copy b)             loaded 16 bytes out of an 8-byte alloca and
///                             passed the pointer as the argument
///
/// and a program that prints 84 through the C and MLIR backends printed
/// 18400323745 through this one.
///
/// The invariant replaces the enumeration. An address is now produced only by
/// the three functions that are ASKED for one, each of them total:
/// `placeAddress` for an assignment target, `argPlaceAddress` for a call
/// argument, and `borrowAddress` for a borrow binding's initializer. Every
/// other position gets a value by construction, so a position nobody thought
/// about cannot receive an address. The cost is a second load at a borrowed
/// field read, which `mem2reg` and `instcombine` remove.
const Value = struct {
    text: []const u8,
    ty: []const u8,

    const void_value: Value = .{ .text = "", .ty = "void" };

    fn isVoid(self: Value) bool {
        return std.mem.eql(u8, self.ty, "void");
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

    temp: u32 = 0,
    label: u32 = 0,
    strings: std.ArrayList(StringGlobal) = .empty,
    /// Slot -> alloca operand, for the function being emitted.
    slots: std.ArrayList([]const u8) = .empty,
    /// Slot -> pointee LLVM type, when the slot holds an ADDRESS rather than a
    /// value. EVERY borrow the ABI passes by pointer is stored this way, a
    /// parameter and a local alike, because an `exclusive` borrow must write
    /// through to the lender's object and a copy would silently drop every
    /// mutation.
    ///
    /// "a parameter and a local alike" is the correction. This was filled in
    /// only for parameters, gated on `i < f.param_count`, which made a claim
    /// about PARAMETERS and applied it to every binding: `let exclusive e =
    /// &mut buf` got a struct-shaped slot, was initialized with a loaded COPY
    /// of the lender, and handed that copy's address to every later call. The
    /// C backend spells the same binding `cell_Buffer *e = &buf;` and printed
    /// 38 where this backend printed 37, with no diagnostic from either.
    slot_ptr_to: std.ArrayList(?[]const u8) = .empty,
    /// Slot -> the type of a whole value written into the slot's STORAGE:
    /// `ptr` for a borrow slot, the binding's ownership-aware type otherwise.
    /// Empty when the binding's type was already refused, which is the one
    /// case `storeValue` declines silently because a diagnostic already stands
    /// against that binding.
    ///
    /// Recorded rather than re-derived. `emitFn` decides a slot's shape once,
    /// and every previous defect in this file came from a second derivation of
    /// the same question drifting from the first.
    slot_ty: std.ArrayList([]const u8) = .empty,
    current_fn: []const u8 = "",
    /// The return type as the body computes it, and as the ABI writes it.
    /// They differ whenever the ABI coerces, e.g. a 16-byte non-HFA struct is
    /// computed as %cell_T and returned as [2 x i64].
    ret_natural: []const u8 = "void",
    ret_abi: []const u8 = "void",
    /// The sret pointer's name while emitting a function that returns an
    /// aggregate indirectly, or null.
    sret: ?[]const u8 = null,
    /// Set once a terminator has been written into the current basic block, so
    /// a second one is not appended. LLVM rejects a block with two.
    terminated: bool = false,
    /// Set when a non-exhaustive match emitted a panic call. The declaration
    /// has to follow the bodies, because that is when this is known, and
    /// bodies are buffered for exactly this reason.
    uses_panic: bool = false,
    /// Set when a string pattern needed memcmp, so its declaration is emitted.
    uses_memcmp: bool = false,
    /// Where a `break` and a `continue` jump, for the innermost enclosing
    /// loop. Null outside a loop, which the typechecker already rejects.
    break_label: ?[]const u8 = null,
    continue_label: ?[]const u8 = null,

    const StringGlobal = struct { name: []const u8, bytes: []const u8 };

    fn run(self: *Emitter) EmitError!void {
        try self.out.print("; LLVM IR generated by the Cell compiler\n", .{});
        try self.out.print("; module: {s}\n\n", .{self.module.path});

        // The runtime's own aggregates, spelled exactly as clang lays them
        // out (measured, see abi.zig). Emitted unconditionally: LLVM drops an
        // unused named type silently, so this costs nothing when a module has
        // no strings, and it keeps the definitions in one place.
        try self.out.writeAll(
            \\%cell_str = type { ptr, i64 }
            \\%cell_string = type { ptr, i64, i64 }
            \\%cell_slice = type { ptr, i64, i64 }
            \\%cell_opt_i64 = type { i8, i64 }
            \\%cell_opt_u64 = type { i8, i64 }
            \\%cell_opt_i32 = type { i8, i32 }
            \\%cell_opt_f64 = type { i8, double }
            \\%cell_opt_bool = type { i8, i8 }
            \\%cell_opt_byte = type { i8, i8 }
            \\%cell_opt_str = type { i8, %cell_str }
            \\
            \\
        );

        for (self.module.structs) |s| {
            try self.out.print("%cell_{s} = type {{ ", .{s.name});
            for (s.fields, 0..) |f, i| {
                if (i != 0) try self.out.writeAll(", ");
                // Per-field OWNERSHIP, matching abi.structLayout. Rendering a
                // field by type alone let a struct with an `arc String` field
                // be emitted while abi called the same struct unclassified.
                const t = self.llTypeOwned(f.ty, f.ownership) orelse {
                    try self.unsupported(.none, "struct field type");
                    try self.out.writeAll("i8*");
                    continue;
                };
                try self.out.writeAll(t);
            }
            try self.out.writeAll(" }\n");
        }
        if (self.module.structs.len != 0) try self.out.writeAll("\n");

        // Enums are int32_t typedefs in the C ABI, so they are i32 here.
        // No LLVM type definition is needed; the mapping is in llType.

        // Bodies first, into a scratch buffer, so string globals and the
        // declarations they require are known before anything is printed.
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

        for (self.strings.items) |g| {
            try self.out.print(
                "@{s} = private unnamed_addr constant [{d} x i8] c\"",
                .{ g.name, g.bytes.len },
            );
            for (g.bytes) |b| {
                if (b >= 0x20 and b < 0x7f and b != '"' and b != '\\') {
                    try self.out.writeByte(b);
                } else {
                    try self.out.print("\\{X:0>2}", .{b});
                }
            }
            try self.out.writeAll("\"\n");
        }
        if (self.strings.items.len != 0) try self.out.writeAll("\n");

        for (self.module.fns) |*f| {
            if (f.body == null) try self.emitDeclare(f);
        }
        // cell_panic is called by the non-exhaustive-match path, which is
        // generated rather than declared in the source, so its declaration is
        // generated too. Without this the module references an undefined
        // symbol and clang refuses it outright.
        if (self.uses_panic and self.module.findFn("panic") == null) {
            try self.out.writeAll("declare void @cell_panic(ptr)\n");
        }
        // memcmp is real libc, unlike cell_str_eq which is `static inline`
        // and has no symbol. It is the one runtime helper this backend can
        // actually call.
        if (self.uses_memcmp) {
            try self.out.writeAll("declare i32 @memcmp(ptr, ptr, i64)\n");
        }
        if (self.module.fns.len != 0) try self.out.writeAll("\n");

        try self.out.writeAll(body_buf.items);

        // A module with a qualifying `main` gets a C entry point, so the
        // emitted object links into an executable the same way the C backend's
        // output does. codegen.zig applies the same rule.
        for (self.module.fns) |*f| {
            if (!std.mem.eql(u8, f.name, "main")) continue;
            if (f.body == null or f.param_count != 0) continue;
            try self.out.writeAll(
                \\define i32 @main() {
                \\entry:
                \\  call void @cell_main()
                \\  ret i32 0
                \\}
                \\
            );
            break;
        }
    }

    fn emitDeclare(self: *Emitter, f: *const hir.Fn) EmitError!void {
        if (unsupportedReturnOwnership(f.ret, f.ret_ownership)) |what| {
            try self.unsupported(f.span, what);
            return;
        }
        const sret = abi.classifyReturn(self.module, f.ret) == .indirect;
        const ret = abi.renderReturn(self.arena, self.module, f.ret) orelse {
            try self.unsupported(f.span, "declared return type");
            return;
        };
        try self.out.print("declare {s} @{s}(", .{ ret, f.symbol });
        if (sret) {
            // An aggregate too large for registers is returned through a
            // caller-allocated buffer, passed as a hidden FIRST parameter. The
            // function itself returns void. `sret(T)` is what tells LLVM this
            // is that convention rather than an ordinary pointer argument.
            const natural = self.llTypeOwned(f.ret, .owned) orelse "i8";
            try self.out.print("ptr sret({s})", .{natural});
            if (f.param_count != 0) try self.out.writeAll(", ");
        }
        for (f.params(), 0..) |p, i| {
            if (i != 0) try self.out.writeAll(", ");
            const t = abi.renderParam(self.arena, self.module, p.ty, p.ownership) orelse {
                try self.unsupported(f.span, "declared parameter type");
                return;
            };
            try self.out.writeAll(t);
            // A C `_Bool` is passed zero-extended. Getting this wrong on a
            // boundary call is silent and platform-specific, so it is spelled.
            if (p.ty.tag() == .boolean) try self.out.writeAll(" zeroext");
        }
        try self.out.writeAll(")\n");
    }

    fn emitFn(self: *Emitter, f: *const hir.Fn) EmitError!void {
        const body = f.body orelse return;
        if (unsupportedReturnOwnership(f.ret, f.ret_ownership)) |what| {
            try self.unsupported(f.span, what);
            return;
        }
        const uses_sret = abi.classifyReturn(self.module, f.ret) == .indirect;
        const ret = abi.renderReturn(self.arena, self.module, f.ret) orelse {
            try self.unsupported(f.span, "return type");
            return;
        };
        // The natural in-memory type of the return, which is what the body
        // computes. It differs from `ret` whenever the ABI coerces.
        //
        // OWNERSHIP-AWARE, and that correction is load-bearing. This read
        // `llType(f.ret)`, the bare spelling, which for a String return is the
        // 16-byte borrowed view `%cell_str` while the sret buffer this
        // function actually writes is the 24-byte owning `%cell_string`. The
        // disagreement was invisible because a String return always takes the
        // sret branch, which stored whatever the body computed without ever
        // comparing it. HIR now carries the declared return ownership, and
        // the guard above refuses nonprimitive shared representations before
        // this owning ABI path. `.owned` is therefore deliberate here.
        const ret_natural = self.llTypeOwned(f.ret, .owned) orelse ret;

        self.temp = 0;
        self.label = 0;
        self.terminated = false;
        self.current_fn = f.name;
        self.slots.clearRetainingCapacity();
        try self.slots.resize(self.arena, f.bindings.len);
        self.slot_ptr_to.clearRetainingCapacity();
        try self.slot_ptr_to.resize(self.arena, f.bindings.len);
        for (self.slot_ptr_to.items) |*p| p.* = null;
        self.slot_ty.clearRetainingCapacity();
        try self.slot_ty.resize(self.arena, f.bindings.len);
        for (self.slot_ty.items) |*p| p.* = "";
        self.ret_natural = ret_natural;
        self.ret_abi = ret;
        self.sret = if (uses_sret) "%sret" else null;

        try self.out.print("define {s} @{s}(", .{ ret, f.symbol });
        if (uses_sret) {
            const natural = self.llTypeOwned(f.ret, .owned) orelse "i8";
            try self.out.print("ptr sret({s}) %sret", .{natural});
            if (f.param_count != 0) try self.out.writeAll(", ");
        }
        for (f.params(), 0..) |p, i| {
            if (i != 0) try self.out.writeAll(", ");
            const t = abi.renderParam(self.arena, self.module, p.ty, p.ownership) orelse {
                try self.unsupported(f.span, "parameter type");
                return;
            };
            try self.out.print("{s} %arg{d}", .{ t, i });
        }
        try self.out.writeAll(") {\nentry:\n");

        // Every binding gets a stack slot. mem2reg promotes the ones that can
        // be, which is every one that is never address-taken.
        for (f.bindings, 0..) |b, i| {
            const name = try std.fmt.allocPrint(self.arena, "%slot{d}", .{i});
            self.slots.items[i] = name;
            const t = self.llTypeOwned(b.ty, b.ownership) orelse {
                // No fallback. An unnameable type gets a diagnostic and an i8
                // placeholder that nothing stores through, because the
                // diagnostic already makes this module non-emittable.
                try self.unsupported(f.span, try std.fmt.allocPrint(
                    self.arena,
                    "type of binding '{s}'",
                    .{b.name},
                ));
                try self.out.print("  {s} = alloca i8\n", .{name});
                continue;
            };
            // A BORROW THE ABI PASSES BY POINTER, whatever binds it. Its slot
            // holds the lender's address, so it is one word rather than the
            // whole aggregate.
            //
            // The `i < f.param_count` this once carried is the defect: it
            // enumerated parameters and asserted a property of every borrow,
            // so a `let exclusive e = &mut buf` local was bound to a COPY and
            // every write through it was lost. The question is asked of the
            // BINDING now, which is the only thing that decides what the slot
            // holds, and `emitLet` below fills a ref slot with an address
            // exactly where a value slot gets a value.
            //
            // The pointee is `t`, the OWNERSHIP-AWARE type, and not
            // `llType(b.ty)`: the two disagree for `String`, where the bare
            // spelling is the 16-byte borrowed view `%cell_str` and an
            // `exclusive String` points at the 24-byte owning `%cell_string`.
            // Taking the bare one would size the write through the borrow at
            // 16 bytes, which is the second half of the ABI divergence this
            // change closes.
            const is_ref = self.borrowsByPointer(b.ty, b.ownership);
            if (is_ref) self.slot_ptr_to.items[i] = t;
            // What the slot's STORAGE holds, which is the address for a borrow
            // and the object otherwise. Recorded here, where the alloca is
            // written, so the store side cannot disagree with the alloca side.
            self.slot_ty.items[i] = if (is_ref) "ptr" else t;
            try self.out.print("  {s} = alloca {s}\n", .{ name, if (is_ref) "ptr" else t });
        }
        // THE PARAMETER PROLOGUE IS EXEMPT FROM `storeValue`, deliberately, and
        // it is one of only two places in this file that are. `%argN` is not a
        // computed value: it is the ABI's spelling of one, already coerced by
        // the caller, and the four stores below write it into correctly sized
        // memory whose type may legitimately differ (a `[2 x i64]` argument
        // into a `%cell_str` slot is what clang itself emits). Nothing here
        // converts between a borrowed view and an owning value, which is the
        // one thing the guard exists to catch. The other exemption is
        // `coerceArg`, for the same reason in the other direction.
        for (f.params(), 0..) |p, i| {
            const natural = self.llTypeOwned(p.ty, p.ownership) orelse continue;
            switch (abi.classifyParam(self.module, p.ty, p.ownership)) {
                .direct => {
                    if (self.slot_ptr_to.items[i] != null) {
                        // A borrowed aggregate. Keep the ADDRESS: an
                        // `exclusive` borrow must write through to the
                        // caller's object, and copying it in would silently
                        // drop every mutation.
                        //
                        // The slot's shape was already decided in the binding
                        // loop above, so this READS that decision rather than
                        // re-deriving it. Two independent derivations of "is
                        // this slot a pointer" is how the alloca and the store
                        // get to disagree.
                        try self.out.print("  store ptr %arg{d}, ptr {s}\n", .{ i, self.slots.items[i] });
                    } else {
                        try self.out.print("  store {s} %arg{d}, ptr {s}\n", .{ natural, i, self.slots.items[i] });
                    }
                },
                // A coerced aggregate arrives as [n x i64] or [n x double] and
                // the slot is the natural struct. Storing the coerced value
                // straight into it is legal and is what clang does: pointers
                // are opaque, so the alloca is just correctly sized memory.
                .coerce_int, .coerce_float => {
                    const coerced = abi.renderParam(self.arena, self.module, p.ty, p.ownership) orelse continue;
                    try self.out.print("  store {s} %arg{d}, ptr {s}\n", .{ coerced, i, self.slots.items[i] });
                },
                .indirect => {
                    // Passed as a pointer to a caller-owned copy, but owned by
                    // us, so copy it in.
                    const tmp = try self.nextTemp();
                    try self.out.print("  {s} = load {s}, ptr %arg{d}\n", .{ tmp, natural, i });
                    try self.out.print("  store {s} {s}, ptr {s}\n", .{ natural, tmp, self.slots.items[i] });
                },
                .unclassified => continue,
            }
        }

        for (body) |stmt| try self.emitStmt(&stmt);

        // A function whose body falls off the end still needs a terminator.
        if (!self.terminated) {
            if (std.mem.eql(u8, ret, "void")) {
                try self.out.writeAll("  ret void\n");
            } else {
                try self.out.print("  ret {s} zeroinitializer\n", .{ret});
            }
        }
        try self.out.writeAll("}\n\n");
    }

    // -- the placement guard -------------------------------------------------

    /// THE GUARD. A computed value may be placed only where a value of its own
    /// rendered type is expected; anything else is refused at the span.
    ///
    /// WHY ONE PREDICATE RATHER THAN A CHECK PER CONSTRUCT. `str` and `String`
    /// are two different runtime types: a literal is the 16-byte borrowed view
    /// `%cell_str`, an owned `String` is the 24-byte owning `%cell_string`, and
    /// turning the first into the second is a real call to
    /// `cell_string_from_str` that copies the characters. This backend cannot
    /// make that call (see the header: every aggregate constructor in
    /// `runtime/cell_rt.h` is `static inline` and has no symbol), so it must
    /// refuse. It did not. It ACCEPTED the conversion at six separate
    /// positions and emitted a 16-byte store into 24 bytes of storage, leaving
    /// `cap` uninitialized and `.ptr` aimed at a static literal that the drop
    /// path would eventually free.
    ///
    /// Six positional checks would have closed six holes and left the seventh
    /// open, which is the reasoning failure `AGENTS.md` records sixteen times
    /// over: enumerate some forms of a construct, assert the property of all of
    /// them. So the question is asked ONCE, of type identity, at the moment a
    /// value meets a destination, and a position nobody anticipated fails
    /// closed instead of writing somewhere plausible.
    ///
    /// WHAT IT MUST NOT SEE. The ABI legitimately re-spells a value on its way
    /// into a register or a hidden buffer: a 16-byte non-HFA struct is computed
    /// as `%cell_str` and PASSED as `[2 x i64]`, and a 24-byte one is passed as
    /// a `ptr` to a caller-owned copy. Those are `coerceArg` and the parameter
    /// prologue, and they are compared against the NATURAL type before the
    /// coercion rather than after it. After it is too late and it is a real
    /// hole rather than a theoretical one: `coerceArg(v, "ptr")` returns
    /// `.ty = "ptr"` whatever it was handed, so a guard placed downstream of it
    /// would compare `ptr` against `ptr`, pass, and let `g(owned "ab")` spill
    /// a 16-byte alloca for a callee that reads 24 bytes out of it.
    fn fits(
        self: *Emitter,
        span: hir.Span,
        val_ty: []const u8,
        dest_ty: []const u8,
        what: []const u8,
    ) EmitError!bool {
        if (std.mem.eql(u8, val_ty, dest_ty)) return true;
        // The explanation is appended only for the pairing it is TRUE of.
        // Printing it for every mismatch would attach a String story to, say,
        // an i64 where a struct belongs, which is a different defect and would
        // send the next reader to the wrong module.
        const string_pair = std.mem.eql(u8, val_ty, "%cell_str") and
            std.mem.eql(u8, dest_ty, "%cell_string");
        const why: []const u8 = if (string_pair)
            " (converting a borrowed view into an owning value needs" ++
                " cell_string_from_str, which this backend cannot call)"
        else
            "";
        try self.unsupported(span, try std.fmt.allocPrint(
            self.arena,
            "a value of type {s} where {s} is expected, in {s}{s}",
            .{ val_ty, dest_ty, what, why },
        ));
        return false;
    }

    /// The ONE place a computed value is written to memory. Every store of a
    /// language-level value goes through here, so the guard cannot be bypassed
    /// by adding a position; the only raw stores left in this file are the
    /// parameter prologue and `coerceArg`, both of them ABI coercions marked as
    /// such at their site.
    ///
    /// The store is written with the DESTINATION's type, not the value's. They
    /// are equal by the time it runs, and naming the destination is what makes
    /// that obvious to the next reader.
    fn storeValue(
        self: *Emitter,
        span: hir.Span,
        val: Value,
        dest_ty: []const u8,
        dest: []const u8,
        what: []const u8,
    ) EmitError!void {
        // An empty destination type means the BINDING was already refused, in
        // `emitFn`, where its alloca became an `i8` placeholder. A second
        // diagnostic at every write to it would bury the first, and the module
        // is non-emittable either way.
        if (dest_ty.len == 0) return;
        if (!try self.fits(span, val.ty, dest_ty, what)) return;
        try self.out.print("  store {s} {s}, ptr {s}\n", .{ dest_ty, val.text, dest });
    }

    /// The type of a whole value written into a slot's storage.
    fn slotType(self: *Emitter, slot: u32) []const u8 {
        if (slot >= self.slot_ty.items.len) return "";
        return self.slot_ty.items[slot];
    }

    // -- statements ---------------------------------------------------------

    fn emitStmt(self: *Emitter, stmt: *const hir.Stmt) EmitError!void {
        if (self.terminated) return;
        switch (stmt.kind) {
            .let => |l| {
                // A REF SLOT WANTS AN ADDRESS, and a value slot wants a value.
                // Which one this is was decided in `emitFn`; asking again here
                // is how the two used to disagree.
                if (l.slot < self.slot_ptr_to.items.len and
                    self.slot_ptr_to.items[l.slot] != null)
                {
                    // `let exclusive e = &mut buf` binds the LENDER's address,
                    // the way the C backend emits `cell_Buffer *e = &buf;`.
                    // A borrow with no initializer has no lender to point at,
                    // so it is refused rather than left holding whatever the
                    // alloca happened to contain.
                    const v = l.value orelse {
                        try self.unsupported(stmt.span, "a borrow binding with no initializer");
                        return;
                    };
                    const addr = (try self.borrowAddress(&v)) orelse return;
                    try self.storeValue(
                        v.span,
                        .{ .text = addr, .ty = "ptr" },
                        self.slotType(l.slot),
                        self.slots.items[l.slot],
                        "a borrow binding",
                    );
                    return;
                }
                if (l.value) |v| {
                    const val = try self.emitExpr(&v);
                    if (!val.isVoid()) {
                        try self.storeValue(
                            v.span,
                            val,
                            self.slotType(l.slot),
                            self.slots.items[l.slot],
                            "a binding's initializer",
                        );
                    }
                }
            },
            .assign => |a| {
                // Classify BEFORE emitting the value, so a refusal does not
                // leave dead instructions in a module nobody will lower.
                const dest_kind = self.assignDest(&a.place);
                if (dest_kind == .refuse) {
                    try self.unsupported(stmt.span, dest_kind.refuse);
                    return;
                }
                const val = try self.emitExpr(&a.value);
                if (val.isVoid()) return;
                const dest = try self.placeAddress(&a.place);
                switch (dest_kind) {
                    // The two live arms carry the destination's type, so the
                    // write through a borrow and the write into a place are
                    // now checked by the same predicate rather than by one
                    // hand-written comparison that only the borrow case had.
                    .into_place => |dest_ty| try self.storeValue(
                        a.value.span,
                        val,
                        dest_ty,
                        dest,
                        "an assignment",
                    ),
                    .through_slot => |pointee| try self.storeValue(
                        a.value.span,
                        val,
                        pointee,
                        dest,
                        "a write through a borrow",
                    ),
                    .refuse => unreachable, // handled above
                }
            },
            .expr => |e| _ = try self.emitExpr(&e),
            .while_loop => |w| {
                const cond_b = try self.nextLabel("loop.cond");
                const body_b = try self.nextLabel("loop.body");
                const end_b = try self.nextLabel("loop.end");

                // The condition needs its own block, because a back edge has
                // to branch somewhere and LLVM blocks are single-entry.
                try self.out.print("  br label %{s}\n", .{cond_b});
                try self.out.print("{s}:\n", .{cond_b});
                self.terminated = false;
                const cond = try self.emitExpr(&w.cond);
                if (cond.isVoid()) return;
                try self.out.print(
                    "  br i1 {s}, label %{s}, label %{s}\n",
                    .{ cond.text, body_b, end_b },
                );

                try self.out.print("{s}:\n", .{body_b});
                self.terminated = false;
                const saved_break = self.break_label;
                const saved_continue = self.continue_label;
                self.break_label = end_b;
                self.continue_label = cond_b;
                for (w.body) |s2| try self.emitStmt(&s2);
                self.break_label = saved_break;
                self.continue_label = saved_continue;
                if (!self.terminated) try self.out.print("  br label %{s}\n", .{cond_b});

                try self.out.print("{s}:\n", .{end_b});
                self.terminated = false;
            },
            .brk => {
                const target = self.break_label orelse return;
                try self.out.print("  br label %{s}\n", .{target});
                self.terminated = true;
            },
            .cont => {
                const target = self.continue_label orelse return;
                try self.out.print("  br label %{s}\n", .{target});
                self.terminated = true;
            },
            .ret => |maybe| {
                if (maybe) |e| {
                    const val = try self.emitExpr(&e);
                    if (val.isVoid()) {
                        try self.out.writeAll("  ret void\n");
                    } else if (!try self.fits(e.span, val.ty, self.ret_natural, "a return value")) {
                        // ONE check for all three return conventions below,
                        // asked before the branch rather than inside it. The
                        // sret arm is where `return "ab"` from a `-> String`
                        // used to write a 16-byte borrowed view into the
                        // caller's 24-byte owning buffer, and it was the arm
                        // with no comparison of any kind.
                        //
                        // The block still gets a terminator. A diagnostic
                        // should not also leave invalid IR behind, even in a
                        // module nobody will lower.
                        if (std.mem.eql(u8, self.ret_abi, "void")) {
                            try self.out.writeAll("  ret void\n");
                        } else {
                            try self.out.print("  ret {s} zeroinitializer\n", .{self.ret_abi});
                        }
                    } else if (self.sret) |dest| {
                        // The value goes into the caller's buffer, and the
                        // function itself returns nothing.
                        try self.out.print("  store {s} {s}, ptr {s}\n", .{ self.ret_natural, val.text, dest });
                        try self.out.writeAll("  ret void\n");
                    } else if (!std.mem.eql(u8, self.ret_abi, self.ret_natural)) {
                        // The ABI returns a coerced form, e.g. a 16-byte
                        // non-HFA struct computed as %cell_T and returned as
                        // [2 x i64]. Round-trip through memory, which is what
                        // clang does and what keeps this correct without a
                        // bitcast that opaque pointers no longer allow.
                        const slot = try self.nextTemp();
                        try self.out.print("  {s} = alloca {s}\n", .{ slot, self.ret_natural });
                        try self.out.print("  store {s} {s}, ptr {s}\n", .{ val.ty, val.text, slot });
                        const out = try self.nextTemp();
                        try self.out.print("  {s} = load {s}, ptr {s}\n", .{ out, self.ret_abi, slot });
                        try self.out.print("  ret {s} {s}\n", .{ self.ret_abi, out });
                    } else {
                        try self.out.print("  ret {s} {s}\n", .{ val.ty, val.text });
                    }
                } else {
                    try self.out.writeAll("  ret void\n");
                }
                self.terminated = true;
            },
        }
    }

    /// Where a write to a place LANDS, as a TOTAL verdict.
    ///
    /// The shape matters more than the three cases. Every predicate this file
    /// has got wrong was an enumeration whose unlisted forms fell through to
    /// "store it in the slot", and silence is what an unenumerated form
    /// produces. So the undecidable case is `refuse`, and a shape nobody
    /// anticipated fails closed with a `cannot lower` diagnostic rather than
    /// writing somewhere plausible. `mlirmit.assignDest` is the same shape for
    /// the same reason.
    const AssignDest = union(enum) {
        /// `placeAddress` names the right address. An owned or `copy` binding,
        /// a borrowed primitive, or a FIELD write through a borrow, which
        /// `placeAddress` already walks through the slot's pointer. Carries the
        /// DESTINATION's type, which the value must match exactly: it used to
        /// carry nothing and the store simply used the value's own type, so
        /// `s = "cd"` on an owned `String` local wrote sixteen bytes into
        /// twenty-four with nothing to compare against.
        into_place: []const u8,
        /// A whole-value write through a borrow. Carries the pointee type,
        /// which the value must match exactly.
        through_slot: []const u8,
        /// This backend will not say where the write lands. Carries the
        /// diagnostic text.
        refuse: []const u8,
    };

    fn assignDest(self: *Emitter, place: *const hir.Place) AssignDest {
        if (place.slot >= self.slots.items.len) {
            return .{ .refuse = "assignment to a binding with no slot" };
        }
        // THE REFUSAL THAT SAT HERE IS GONE, LIFTED WITH ITS TWIN.
        //
        // It declined a whole-value write through a borrowed `String`, `[T]`
        // or `T?` even though the machinery below lowers it, purely to keep
        // this backend's verdict equal to `mlirmit.zig`'s, which passed those
        // three by value and so held a copy the lender could never see. That
        // file asks `abi.classifyParam` now and passes them by pointer, so
        // both backends write through to the lender and neither has anything
        // left to refuse. `examples/exclusive_aggregates.cell` is the corpus
        // entry the note asked for: it writes through all three and prints an
        // answer a lost write cannot produce.
        if (place.path.len != 0) return .{ .into_place = self.placeDestType(place) };
        if (self.slot_ptr_to.items[place.slot]) |pointee| return .{ .through_slot = pointee };
        return .{ .into_place = self.slotType(place.slot) };
    }

    /// The type of a whole value written to a place: the LAST field selected,
    /// with its declared ownership, or the slot's own storage when nothing is
    /// selected.
    ///
    /// The field's ownership is read rather than assumed, the same way
    /// `emitFn` renders a struct definition, because `owned name: String` and
    /// `shared name: String` are different sizes and only the declaration
    /// says which one a field is.
    fn placeDestType(self: *Emitter, place: *const hir.Place) []const u8 {
        const sel = place.path[place.path.len - 1];
        const s = self.module.findStruct(sel.struct_name) orelse return "";
        if (sel.index >= s.fields.len) return "";
        const f = s.fields[sel.index];
        return self.llTypeOwned(f.ty, f.ownership) orelse "";
    }

    /// The address a borrow binding's initializer names, or null having
    /// already reported why not.
    ///
    /// Total by construction: `argPlaceAddress` answers for the forms that
    /// HAVE an address (a binding, a field of one, and the four sigil borrow
    /// spellings that wrap either) and null for everything else, so a
    /// temporary is refused rather than bound.
    ///
    /// It deliberately does NOT reuse `emitCall`'s spill path. That one
    /// stores a temporary into a fresh alloca and hands over its address,
    /// which is right for an argument, where nothing outlives the call and can
    /// observe a write back, and exactly wrong for a BINDING: `let exclusive e
    /// = mk()` would bind a copy that the initializer cannot see written.
    fn borrowAddress(self: *Emitter, e: *const hir.Expr) EmitError!?[]const u8 {
        if (try self.argPlaceAddress(e)) |addr| return addr;
        try self.unsupported(e.span, "a borrow of a value that has no address");
        return null;
    }

    /// The address of an assignable place: its slot, walked through any field
    /// selections with `getelementptr`.
    fn placeAddress(self: *Emitter, place: *const hir.Place) EmitError![]const u8 {
        var addr = self.slots.items[place.slot];
        // A borrow's slot holds the lender's ADDRESS, not the object, so the
        // object is one load away. Reading a field already knew this;
        // WRITING one did not, and indexed the slot itself. `b.len = b.len + 5`
        // inside
        // `bump(exclusive b: Buffer)` therefore read the caller's `len`
        // correctly, added to it correctly, and stored the result over the
        // POINTER VARIABLE, leaving the caller's object untouched. Silent, and
        // at a field offset past the first it would also be a stack overwrite.
        if (place.slot < self.slot_ptr_to.items.len and self.slot_ptr_to.items[place.slot] != null) {
            const loaded = try self.nextTemp();
            try self.out.print("  {s} = load ptr, ptr {s}\n", .{ loaded, addr });
            addr = loaded;
        }
        for (place.path) |sel| {
            const t = try std.fmt.allocPrint(self.arena, "%cell_{s}", .{sel.struct_name});
            const next = try self.nextTemp();
            try self.out.print(
                "  {s} = getelementptr inbounds {s}, ptr {s}, i32 0, i32 {d}\n",
                .{ next, t, addr, sel.index },
            );
            addr = next;
        }
        return addr;
    }

    // -- expressions --------------------------------------------------------

    fn emitExpr(self: *Emitter, e: *const hir.Expr) EmitError!Value {
        switch (e.kind) {
            .int_const => |v| return .{
                .text = try std.fmt.allocPrint(self.arena, "{d}", .{v}),
                .ty = self.llType(e.ty) orelse "i64",
            },
            .bool_const => |v| return .{
                .text = if (v) "true" else "false",
                .ty = "i1",
            },
            .float_const => |v| return .{
                // LLVM accepts a decimal float literal for `double`. Printing
                // enough digits to round-trip matters: a truncated literal is a
                // silently different program.
                .text = try std.fmt.allocPrint(self.arena, "{d:.17}", .{v}),
                .ty = self.llType(e.ty) orelse "double",
            },
            .string_const => |bytes| {
                // A literal is a BORROWED view: a pointer to static bytes plus
                // a length, which is exactly cell_str_t. The runtime's
                // cell_str_from_parts is `static inline` and has no symbol, so
                // the struct is materialized here instead of called.
                const g = try self.internString(bytes);
                const a = try self.nextTemp();
                try self.out.print(
                    "  {s} = insertvalue %cell_str undef, ptr @{s}, 0\n",
                    .{ a, g },
                );
                const b = try self.nextTemp();
                try self.out.print(
                    "  {s} = insertvalue %cell_str {s}, i64 {d}, 1\n",
                    .{ b, a, bytes.len },
                );
                return .{ .text = b, .ty = "%cell_str" };
            },
            .enum_const => |ec| return .{
                .text = try std.fmt.allocPrint(self.arena, "{d}", .{ec.value}),
                .ty = "i32",
            },
            .unresolved_ref => |name| {
                try self.unsupported(e.span, try std.fmt.allocPrint(
                    self.arena,
                    "unresolved identifier '{s}'",
                    .{name},
                ));
                return Value.void_value;
            },
            .ref => |slot| {
                // A KNOWN TYPE LIE, DELIBERATELY LEFT IN PLACE, and the reason
                // an owned String cannot round-trip through a binding.
                //
                // `llType(.string)` is the BORROWED view `%cell_str`, whatever
                // the slot holds, so reading an owning `%cell_string` binding
                // yields a value this backend then calls 16 bytes wide. The
                // slot's real type is in `slot_ty`. Before the placement guard
                // that was silent wrong code: `let owned s: String = make()
                // return s` emitted `load %cell_str, ptr %slot0` off a
                // `%cell_string` alloca and stored 16 bytes into a 24-byte
                // sret buffer, never copying `cap`. It is now REFUSED, which
                // is the right verdict reached through a misleading message:
                // the diagnostic says "borrowed view to owning value" while
                // the source was already owning.
                //
                // Loading `slot_ty` here instead is NOT the fix on its own. It
                // would flip `inspect(shared s)` for an owned `s`, which works
                // today only because `%cell_str` is a layout prefix of
                // `%cell_string`; making that correct needs a
                // `cell_string_as_str` equivalent, and that is `static inline`
                // in `runtime/cell_rt.h` too. Lift it in both backends at
                // once, with `mlirmit.zig`'s identical note, or the two split
                // on a verdict.
                const t = self.llType(e.ty) orelse {
                    try self.unsupported(e.span, "type of a binding");
                    return Value.void_value;
                };
                // A borrowed aggregate's slot holds the lender's ADDRESS, so
                // reading it as a VALUE is two loads: the slot yields the
                // address, the address yields the object.
                //
                // This used to return the address with a `ptr_to` tag and let
                // consumers deal with it. Two did and the rest did not, so
                // `let copy c = b` stored an address into a struct slot and
                // `sum(copy b)` passed pointer bits: a program printing 84
                // through the C backend printed 18400323745 through this one.
                // Loading here is what makes every value position correct
                // without any of them knowing that borrows exist. The
                // positions that genuinely want the address ask
                // `placeAddress`, `argPlaceAddress` or `borrowAddress`
                // instead, and none of them route through here.
                if (slot < self.slot_ptr_to.items.len) {
                    if (self.slot_ptr_to.items[slot]) |pointee| {
                        const addr = try self.nextTemp();
                        try self.out.print("  {s} = load ptr, ptr {s}\n", .{ addr, self.slots.items[slot] });
                        const loaded = try self.nextTemp();
                        try self.out.print("  {s} = load {s}, ptr {s}\n", .{ loaded, pointee, addr });
                        return .{ .text = loaded, .ty = pointee };
                    }
                }
                const tmp = try self.nextTemp();
                try self.out.print("  {s} = load {s}, ptr {s}\n", .{ tmp, t, self.slots.items[slot] });
                return .{ .text = tmp, .ty = t };
            },
            .binary => |b| return self.emitBinary(e, b.op, b.left, b.right),
            .unary => |u| return self.emitUnary(e, u.op, u.operand),
            .call => |c| {
                if (unsupportedReturnOwnership(e.ty, c.ret_ownership)) |what| {
                    try self.unsupported(e.span, what);
                    return Value.void_value;
                }
                return self.emitCall(e, c.symbol, c.args);
            },
            .field => |f| {
                const base = try self.emitExpr(f.base);
                if (base.isVoid()) return base;
                // THE SAME TYPE LIE as `.ref` above, one level in, and here it
                // produced IR clang rejects outright rather than merely wrong
                // IR. `f.sel.ty` carries no ownership, so an `owned name:
                // String` field reads as `%cell_str` while the `extractvalue`
                // that produced it genuinely yields the struct's declared
                // `%cell_string`. Measured on `pub fn f() -> String { let
                // owned b = mk() return b.name }` before the guard:
                //
                //   error: '%3' defined with type '%cell_string' but expected
                //   '%cell_str'
                //
                // so this shape was accepted by the emitter and could not be
                // compiled. It is refused now. The real fix is to read the
                // declared field's ownership, the way `emitStructLit` and
                // `placeDestType` already do, and it belongs with the `.ref`
                // lift above rather than on its own.
                const t = self.llType(f.sel.ty) orelse {
                    try self.unsupported(e.span, "field type");
                    return Value.void_value;
                };
                // `base` is always the aggregate now, never its address: the
                // `.ref` arm above loads through a borrow rather than handing
                // one out. So one rule covers a borrowed base and an owned
                // one, and there is no second path to keep in step. The extra
                // load that costs is removed by mem2reg plus instcombine.
                const tmp = try self.nextTemp();
                try self.out.print(
                    "  {s} = extractvalue {s} {s}, {d}\n",
                    .{ tmp, base.ty, base.text, f.sel.index },
                );
                return .{ .text = tmp, .ty = t };
            },
            .struct_lit => |sl| return self.emitStructLit(e, sl.name, sl.fields),
            .list_lit => |elems| {
                if (elems.len != 0) {
                    // A non-empty literal needs a constant global for its
                    // elements. Nothing in the corpus has one, so it is
                    // refused by name rather than half-built.
                    try self.unsupported(e.span, "a non-empty list literal is not lowered to LLVM IR yet");
                    return Value.void_value;
                }
                // cell_slice_empty() is `static inline` and has no symbol, so
                // the empty header is materialized here: null, 0, 0.
                const a = try self.nextTemp();
                try self.out.print("  {s} = insertvalue %cell_slice undef, ptr null, 0\n", .{a});
                const b = try self.nextTemp();
                try self.out.print("  {s} = insertvalue %cell_slice {s}, i64 0, 1\n", .{ b, a });
                const c = try self.nextTemp();
                try self.out.print("  {s} = insertvalue %cell_slice {s}, i64 0, 2\n", .{ c, b });
                return .{ .text = c, .ty = "%cell_slice" };
            },
            .block => |b| {
                for (b.stmts) |s| try self.emitStmt(&s);
                if (b.tail) |t| return self.emitExpr(t);
                return Value.void_value;
            },
            .if_expr => |ie| return self.emitIf(e, ie.cond, ie.then_body, ie.else_body),
            .match_expr => |me| return self.emitMatch(e, me.scrutinee, me.arms),
        }
    }

    fn emitBinary(
        self: *Emitter,
        e: *const hir.Expr,
        op: ast.BinaryOp,
        left_e: *const hir.Expr,
        right_e: *const hir.Expr,
    ) EmitError!Value {
        // `and` / `or` short-circuit, so they are branches, not instructions.
        if (op == .and_op or op == .or_op) return self.emitShortCircuit(op, left_e, right_e);

        const left = try self.emitExpr(left_e);
        const right = try self.emitExpr(right_e);
        if (left.isVoid() or right.isVoid()) return Value.void_value;

        const float = isFloatType(left.ty);
        const unsigned = left_e.ty.tag() == .uint or left_e.ty.tag() == .byte;

        const mnemonic: []const u8 = switch (op) {
            .add => if (float) "fadd" else "add nsw",
            .sub => if (float) "fsub" else "sub nsw",
            .mul => if (float) "fmul" else "mul nsw",
            .div => if (float) "fdiv" else if (unsigned) "udiv" else "sdiv",
            // Ordered comparisons: an operand that is NaN compares false,
            // which is what a source-level `<` means.
            .eq => if (float) "fcmp oeq" else "icmp eq",
            .ne => if (float) "fcmp one" else "icmp ne",
            .lt => if (float) "fcmp olt" else if (unsigned) "icmp ult" else "icmp slt",
            .le => if (float) "fcmp ole" else if (unsigned) "icmp ule" else "icmp sle",
            .gt => if (float) "fcmp ogt" else if (unsigned) "icmp ugt" else "icmp sgt",
            .ge => if (float) "fcmp oge" else if (unsigned) "icmp uge" else "icmp sge",
            .and_op, .or_op => unreachable,
        };

        const tmp = try self.nextTemp();
        try self.out.print(
            "  {s} = {s} {s} {s}, {s}\n",
            .{ tmp, mnemonic, left.ty, left.text, right.text },
        );
        const result_ty = self.llType(e.ty) orelse left.ty;
        return .{ .text = tmp, .ty = result_ty };
    }

    /// `a and b` evaluates `b` only when `a` is true. Lowered as a branch into
    /// a slot rather than as a phi, matching the alloca discipline above.
    fn emitShortCircuit(
        self: *Emitter,
        op: ast.BinaryOp,
        left_e: *const hir.Expr,
        right_e: *const hir.Expr,
    ) EmitError!Value {
        const dest = try self.nextTemp();
        try self.out.print("  {s} = alloca i1\n", .{dest});

        const left = try self.emitExpr(left_e);
        if (left.isVoid()) return Value.void_value;
        try self.storeValue(left_e.span, left, "i1", dest, "a short-circuit operand");

        const rhs_label = try self.nextLabel("sc.rhs");
        const end_label = try self.nextLabel("sc.end");
        if (op == .and_op) {
            try self.out.print("  br i1 {s}, label %{s}, label %{s}\n", .{ left.text, rhs_label, end_label });
        } else {
            try self.out.print("  br i1 {s}, label %{s}, label %{s}\n", .{ left.text, end_label, rhs_label });
        }

        try self.out.print("{s}:\n", .{rhs_label});
        const right = try self.emitExpr(right_e);
        if (!right.isVoid()) {
            try self.storeValue(right_e.span, right, "i1", dest, "a short-circuit operand");
        }
        try self.out.print("  br label %{s}\n", .{end_label});

        try self.out.print("{s}:\n", .{end_label});
        const tmp = try self.nextTemp();
        try self.out.print("  {s} = load i1, ptr {s}\n", .{ tmp, dest });
        return .{ .text = tmp, .ty = "i1" };
    }

    fn emitUnary(
        self: *Emitter,
        e: *const hir.Expr,
        op: ast.UnaryOp,
        operand_e: *const hir.Expr,
    ) EmitError!Value {
        // `&x` and `&mut x` are borrows. Ownership is a compile-time property
        // checked by borrowck; at the value level they are the operand.
        if (op == .ref_shared or op == .ref_exclusive) return self.emitExpr(operand_e);

        const operand = try self.emitExpr(operand_e);
        if (operand.isVoid()) return operand;
        const tmp = try self.nextTemp();
        switch (op) {
            .neg => {
                if (isFloatType(operand.ty)) {
                    try self.out.print("  {s} = fneg {s} {s}\n", .{ tmp, operand.ty, operand.text });
                } else {
                    try self.out.print("  {s} = sub nsw {s} 0, {s}\n", .{ tmp, operand.ty, operand.text });
                }
                return .{ .text = tmp, .ty = operand.ty };
            },
            .not => {
                try self.out.print("  {s} = xor i1 {s}, true\n", .{ tmp, operand.text });
                return .{ .text = tmp, .ty = "i1" };
            },
            .ref_shared, .ref_exclusive => unreachable,
        }
        _ = e;
    }

    /// Whether `(ty, own)` is a BORROW PASSED BY POINTER: the one parameter
    /// class whose `ptr` spelling means "the lender's own object" rather than
    /// "a copy the callee may do as it likes with".
    ///
    /// `abi.renderParam` cannot answer this and must not be asked. It renders
    /// a borrow's `.direct = "ptr"` and `.indirect` (any aggregate over 16
    /// bytes, in EVERY ownership mode) as the same four characters, and the
    /// two have opposite call-site rules: an indirect argument is a copy the
    /// CALLER allocates and the callee is entitled to scribble on, so handing
    /// it the caller's own storage would trade the lost-write defect below for
    /// an unwanted-write one. Only the classification tells them apart, so
    /// this asks `abi.classifyParam` and both the declaration site in `emitFn`
    /// and the call site in `emitCall` go through here.
    ///
    /// THE `struct_type` GATE THAT USED TO OPEN THIS IS GONE, and it was the
    /// second half of the same divergence. `codegen.applyOwnership` makes
    /// EVERY non-primitive `exclusive` parameter a pointer, `String`, `[T]`
    /// and `T?` included, so restricting the question to structs left those
    /// three passing a spilled copy at the call site and taking a lost write.
    /// `[T]` hid it best: at 24 bytes it was already `.indirect`, so it was
    /// already rendered `ptr` and the SPELLING agreed while the MEANING did
    /// not. The question belongs entirely to `abi.classifyParam` now, which is
    /// the module that mirrors `applyOwnership`.
    fn borrowsByPointer(self: *Emitter, ty: hir.Ty, own: hir.Ownership) bool {
        return switch (abi.classifyParam(self.module, ty, own)) {
            .direct => |spelling| std.mem.eql(u8, spelling, "ptr"),
            else => false,
        };
    }

    /// The ADDRESS of the place an argument names, or null when it names no
    /// place and is therefore a temporary.
    ///
    /// `.unary` with `ref_shared` or `ref_exclusive` is transparent here, the
    /// same way `emitUnary` forwards those two ops straight to their operand
    /// and the same way `mlirmit.placeSlot` unwraps them. That is not
    /// tidiness. The five borrow spellings this language defines as identical
    /// do NOT reach a backend as one shape: `grow(exclusive buf)` arrives as
    /// `.ref` because `hir.lower` consumes the written prefix, while
    /// `grow(&mut buf)`, `grow(&var buf)` and `grow(&exclusive buf)` arrive
    /// wrapped. Matching only the bare `.ref` would hand over the caller's
    /// object for one spelling and a lost-mutation COPY for the other three,
    /// which is precisely the divergence `examples/borrows.cell` exists to
    /// forbid, and it would be invisible in any check that reads one spelling.
    ///
    /// A `.field` chain is walked with `getelementptr`, the same way
    /// `placeAddress` walks an assignment target, because `bump(exclusive
    /// o.inner)` is a place too and was losing its writes identically.
    fn argPlaceAddress(self: *Emitter, e: *const hir.Expr) EmitError!?[]const u8 {
        switch (e.kind) {
            .unary => |u| {
                if (u.op != .ref_shared and u.op != .ref_exclusive) return null;
                return self.argPlaceAddress(u.operand);
            },
            .ref => |slot| {
                if (slot >= self.slots.items.len) return null;
                // A borrowed parameter's slot holds the caller's ADDRESS
                // rather than the object, so the address is one load away.
                // Forwarding it onwards, `outer(exclusive b)` calling
                // `bump(exclusive b)`, has to reach the ORIGINAL object or the
                // write dies one frame further out instead of at this one.
                if (slot < self.slot_ptr_to.items.len and self.slot_ptr_to.items[slot] != null) {
                    const addr = try self.nextTemp();
                    try self.out.print("  {s} = load ptr, ptr {s}\n", .{ addr, self.slots.items[slot] });
                    return addr;
                }
                return self.slots.items[slot];
            },
            .field => |f| {
                // The struct is read off the SELECTION, not re-derived from
                // the base's type, so this indexes the same layout
                // `placeAddress` does and cannot drift from it.
                const owner = try std.fmt.allocPrint(self.arena, "%cell_{s}", .{f.sel.struct_name});
                const base = (try self.argPlaceAddress(f.base)) orelse return null;
                const gep = try self.nextTemp();
                try self.out.print(
                    "  {s} = getelementptr inbounds {s}, ptr {s}, i32 0, i32 {d}\n",
                    .{ gep, owner, base, f.sel.index },
                );
                return gep;
            },
            else => return null,
        }
    }

    /// Coerce an argument from its natural in-memory form into the form the
    /// ABI passes it in.
    ///
    /// Needed because a value is COMPUTED as, say, `%cell_str` but PASSED as
    /// `[2 x i64]`. Emitting the natural form at the call site while the
    /// declaration says the coerced one is a type mismatch LLVM rejects
    /// outright, which is how this was caught.
    ///
    /// The round trip through memory is what clang does, and it is what stays
    /// correct now that opaque pointers have removed bitcast between
    /// aggregates.
    fn coerceArg(self: *Emitter, v: Value, want: []const u8) EmitError!Value {
        if (std.mem.eql(u8, v.ty, want)) return v;
        const slot = try self.nextTemp();
        try self.out.print("  {s} = alloca {s}\n", .{ slot, v.ty });
        try self.out.print("  store {s} {s}, ptr {s}\n", .{ v.ty, v.text, slot });
        // An indirect argument IS the address, so no reload.
        if (std.mem.eql(u8, want, "ptr")) return .{ .text = slot, .ty = "ptr" };
        const out = try self.nextTemp();
        try self.out.print("  {s} = load {s}, ptr {s}\n", .{ out, want, slot });
        return .{ .text = out, .ty = want };
    }

    fn emitCall(
        self: *Emitter,
        e: *const hir.Expr,
        symbol: ?[]const u8,
        args: []const hir.Expr,
    ) EmitError!Value {
        const sym = symbol orelse {
            try self.unsupported(e.span, "a computed callee is not lowered to LLVM IR yet");
            return Value.void_value;
        };

        var vals = try self.arena.alloc(Value, args.len);
        const modes = switch (e.kind) {
            .call => |c| c.modes,
            else => &[_]hir.ArgMode{},
        };
        for (args, 0..) |a, i| {
            // A borrowed struct parameter is the CALLER'S OWN OBJECT, and that
            // is answered BEFORE emitExpr runs, because emitExpr would `load`
            // the aggregate and every route from a loaded value back to memory
            // is a copy. `coerceArg` below then spilled that copy to a fresh
            // alloca and passed ITS address, so `bump(exclusive buf)` mutated a
            // temporary that died at the call and `print_int(buf.len)` printed
            // the original number. Nothing failed: the wrong answer was simply
            // printed. The C backend spells this `&buf` in `emitArgLike`, and
            // `runtime/cell_rt.h` section 7 with `docs/OWNERSHIP.md` R1 define
            // `exclusive` as the callee mutating the caller's value, so a copy
            // here breaks the ownership model's central promise silently.
            if (i < modes.len and self.borrowsByPointer(a.ty, modes[i].param)) {
                if (try self.argPlaceAddress(&a)) |addr| {
                    vals[i] = .{ .text = addr, .ty = "ptr" };
                    continue;
                }
                // No place: a temporary with no home of its own, which falls
                // through to the spill below. That copy costs no correctness,
                // because nothing can observe a write back through it.
            }
            var v = try self.emitExpr(&a);
            if (v.isVoid()) return Value.void_value;
            // Place the argument the way the CALLEE's parameter is declared,
            // not the way the value happens to be computed.
            //
            // `v` is a VALUE, always. The branch that used to sit here asked
            // whether it was secretly an address and, if the callee also
            // wanted `ptr`, forwarded it. That branch could fire for an
            // `.indirect` parameter too, which renders as the same four
            // characters and means the opposite thing: the caller allocates a
            // copy and the callee may scribble on it. Handing over the
            // lender's storage there is an unwanted write rather than a lost
            // one. It is gone with `Value.ptr_to`, and a borrow that really is
            // wanted by pointer took the `argPlaceAddress` path above.
            if (i < modes.len) {
                // GUARD FIRST, COERCE SECOND, and the order is the whole point.
                //
                // `coerceArg` re-spells a value for the ABI, and for an
                // `.indirect` parameter it spills to an alloca and returns
                // `.ty = "ptr"` WHATEVER it was handed. A guard downstream of
                // it therefore compares `ptr` against `ptr` and passes, which
                // is not a theoretical hole: `owned String` is 24 bytes and so
                // is passed indirectly, so `g(owned "ab")` would spill a
                // 16-byte `%cell_str` alloca and hand its address to a callee
                // that reads 24 bytes out of it. Comparing against the
                // parameter's NATURAL type, before any coercion, is what makes
                // the legitimate re-spellings invisible to the guard while the
                // conversion this backend cannot perform is not.
                const natural = self.llTypeOwned(a.ty, modes[i].param) orelse {
                    try self.unsupported(a.span, "an argument whose parameter type this backend cannot render");
                    return Value.void_value;
                };
                if (!try self.fits(a.span, v.ty, natural, "a call argument")) return Value.void_value;
                if (abi.renderParam(self.arena, self.module, a.ty, modes[i].param)) |want| {
                    v = try self.coerceArg(v, want);
                }
            }
            vals[i] = v;
        }

        // A call's result is an OWNED value, which matters for String: the
        // callee hands back a cell_string_t, not a borrowed cell_str_t.
        const natural = self.llTypeOwned(e.ty, .owned) orelse {
            try self.unsupported(e.span, "call return type");
            return Value.void_value;
        };
        const ret = abi.renderReturn(self.arena, self.module, e.ty) orelse {
            try self.unsupported(e.span, "call return type");
            return Value.void_value;
        };
        const via_sret = abi.classifyReturn(self.module, e.ty) == .indirect;

        // An sret callee writes into a buffer WE allocate and returns void, so
        // the result has to exist before the call rather than after it.
        var sret_slot: []const u8 = "";
        if (via_sret) {
            sret_slot = try self.nextTemp();
            try self.out.print("  {s} = alloca {s}\n", .{ sret_slot, natural });
        }

        const is_void = std.mem.eql(u8, ret, "void");
        var result: []const u8 = "";
        if (!is_void) {
            result = try self.nextTemp();
            try self.out.print("  {s} = ", .{result});
        } else {
            try self.out.writeAll("  ");
        }
        try self.out.print("call {s} @{s}(", .{ ret, sym });
        if (via_sret) {
            try self.out.print("ptr sret({s}) {s}", .{ natural, sret_slot });
            if (vals.len != 0) try self.out.writeAll(", ");
        }
        for (vals, 0..) |v, i| {
            if (i != 0) try self.out.writeAll(", ");
            try self.out.print("{s} {s}", .{ v.ty, v.text });
        }
        try self.out.writeAll(")\n");

        if (via_sret) {
            const loaded = try self.nextTemp();
            try self.out.print("  {s} = load {s}, ptr {s}\n", .{ loaded, natural, sret_slot });
            return .{ .text = loaded, .ty = natural };
        }
        if (is_void) return Value.void_value;
        // The ABI may have returned a coerced form; the rest of the body wants
        // the natural one.
        if (!std.mem.eql(u8, ret, natural)) {
            const slot = try self.nextTemp();
            try self.out.print("  {s} = alloca {s}\n", .{ slot, natural });
            try self.out.print("  store {s} {s}, ptr {s}\n", .{ ret, result, slot });
            const back = try self.nextTemp();
            try self.out.print("  {s} = load {s}, ptr {s}\n", .{ back, natural, slot });
            return .{ .text = back, .ty = natural };
        }
        return .{ .text = result, .ty = natural };
    }

    fn emitStructLit(
        self: *Emitter,
        e: *const hir.Expr,
        name: []const u8,
        fields: []const hir.Expr,
    ) EmitError!Value {
        const ty = try std.fmt.allocPrint(self.arena, "%cell_{s}", .{name});
        const decl = self.module.findStruct(name) orelse {
            try self.unsupported(e.span, try std.fmt.allocPrint(
                self.arena,
                "struct literal for undeclared type '{s}'",
                .{name},
            ));
            return Value.void_value;
        };
        // Built with insertvalue rather than an alloca so the result is a
        // first-class value that can be returned or passed directly.
        var acc: []const u8 = "undef";
        for (fields, 0..) |f, i| {
            const v = try self.emitExpr(&f);
            if (v.isVoid()) return Value.void_value;
            // A FIELD IS A DESTINATION TOO, and it was the position with the
            // least to say for itself: the insertvalue was written with the
            // VALUE's type at the field's index, so `B { name: "ab" }` for
            // `owned name: String` inserted a `%cell_str` into a slot the
            // struct definition above spells `%cell_string`.
            if (i >= decl.fields.len) {
                try self.unsupported(f.span, "more initializers than the struct declares fields");
                return Value.void_value;
            }
            const field = decl.fields[i];
            const want = self.llTypeOwned(field.ty, field.ownership) orelse {
                try self.unsupported(f.span, "struct field type");
                return Value.void_value;
            };
            if (!try self.fits(f.span, v.ty, want, "a struct literal field")) return Value.void_value;
            const tmp = try self.nextTemp();
            try self.out.print(
                "  {s} = insertvalue {s} {s}, {s} {s}, {d}\n",
                .{ tmp, ty, acc, want, v.text, i },
            );
            acc = tmp;
        }
        return .{ .text = acc, .ty = ty };
    }

    fn emitIf(
        self: *Emitter,
        e: *const hir.Expr,
        cond_e: *const hir.Expr,
        then_e: *const hir.Expr,
        else_e: ?*const hir.Expr,
    ) EmitError!Value {
        const produces_value = else_e != null and e.ty.tag() != .unit;
        var dest: []const u8 = "";
        var dest_ty: []const u8 = "";
        if (produces_value) {
            dest_ty = self.llType(e.ty) orelse "i64";
            dest = try self.nextTemp();
            try self.out.print("  {s} = alloca {s}\n", .{ dest, dest_ty });
        }

        const cond = try self.emitExpr(cond_e);
        if (cond.isVoid()) return Value.void_value;

        const then_label = try self.nextLabel("if.then");
        const else_label = try self.nextLabel("if.else");
        const end_label = try self.nextLabel("if.end");

        try self.out.print(
            "  br i1 {s}, label %{s}, label %{s}\n",
            .{ cond.text, then_label, if (else_e != null) else_label else end_label },
        );

        try self.out.print("{s}:\n", .{then_label});
        self.terminated = false;
        const then_val = try self.emitExpr(then_e);
        if (produces_value and !then_val.isVoid()) {
            try self.storeValue(then_e.span, then_val, dest_ty, dest, "an if branch's value");
        }
        if (!self.terminated) try self.out.print("  br label %{s}\n", .{end_label});

        if (else_e) |eb| {
            try self.out.print("{s}:\n", .{else_label});
            self.terminated = false;
            const else_val = try self.emitExpr(eb);
            if (produces_value and !else_val.isVoid()) {
                try self.storeValue(eb.span, else_val, dest_ty, dest, "an else branch's value");
            }
            if (!self.terminated) try self.out.print("  br label %{s}\n", .{end_label});
        }

        try self.out.print("{s}:\n", .{end_label});
        self.terminated = false;

        if (!produces_value) return Value.void_value;
        const tmp = try self.nextTemp();
        try self.out.print("  {s} = load {s}, ptr {s}\n", .{ tmp, dest_ty, dest });
        return .{ .text = tmp, .ty = dest_ty };
    }

    /// Compare a `cell_str_t` against a literal, producing an i1.
    ///
    /// Faithful to `cell_str_eq` (runtime/cell_rt.h:184), which cannot be
    /// called because it is `static inline` and has no symbol. Its order
    /// matters and is preserved: lengths first, then the empty case, then the
    /// null guard, and only then memcmp. Calling memcmp on a null pointer or
    /// with a mismatched length would be undefined behaviour, so the guards
    /// are not decoration.
    fn emitStringEq(self: *Emitter, scrutinee: Value, literal: []const u8) EmitError!Value {
        const len = try self.nextTemp();
        try self.out.print("  {s} = extractvalue %cell_str {s}, 1\n", .{ len, scrutinee.text });
        const len_eq = try self.nextTemp();
        try self.out.print("  {s} = icmp eq i64 {s}, {d}\n", .{ len_eq, len, literal.len });

        // An empty pattern matches exactly when the scrutinee is empty, and
        // cell_str_eq returns true there without touching either pointer.
        if (literal.len == 0) return .{ .text = len_eq, .ty = "i1" };

        self.uses_memcmp = true;
        const g = try self.internString(literal);

        const res = try self.nextTemp();
        try self.out.print("  {s} = alloca i1\n", .{res});
        try self.out.print("  store i1 false, ptr {s}\n", .{res});

        const cmp_b = try self.nextLabel("streq.cmp");
        const mem_b = try self.nextLabel("streq.mem");
        const end_b = try self.nextLabel("streq.end");

        try self.out.print("  br i1 {s}, label %{s}, label %{s}\n", .{ len_eq, cmp_b, end_b });

        try self.out.print("{s}:\n", .{cmp_b});
        const ptr = try self.nextTemp();
        try self.out.print("  {s} = extractvalue %cell_str {s}, 0\n", .{ ptr, scrutinee.text });
        const is_null = try self.nextTemp();
        try self.out.print("  {s} = icmp eq ptr {s}, null\n", .{ is_null, ptr });
        try self.out.print("  br i1 {s}, label %{s}, label %{s}\n", .{ is_null, end_b, mem_b });

        try self.out.print("{s}:\n", .{mem_b});
        const r = try self.nextTemp();
        try self.out.print(
            "  {s} = call i32 @memcmp(ptr {s}, ptr @{s}, i64 {d})\n",
            .{ r, ptr, g, literal.len },
        );
        const eq = try self.nextTemp();
        try self.out.print("  {s} = icmp eq i32 {s}, 0\n", .{ eq, r });
        try self.out.print("  store i1 {s}, ptr {s}\n", .{ eq, res });
        try self.out.print("  br label %{s}\n", .{end_b});

        try self.out.print("{s}:\n", .{end_b});
        self.terminated = false;
        const out = try self.nextTemp();
        try self.out.print("  {s} = load i1, ptr {s}\n", .{ out, res });
        return .{ .text = out, .ty = "i1" };
    }

    fn emitMatch(
        self: *Emitter,
        e: *const hir.Expr,
        scrutinee_e: *const hir.Expr,
        arms: []const hir.Arm,
    ) EmitError!Value {
        const scrutinee = try self.emitExpr(scrutinee_e);
        if (scrutinee.isVoid()) return Value.void_value;

        const produces_value = e.ty.tag() != .unit;
        var dest: []const u8 = "";
        var dest_ty: []const u8 = "";
        if (produces_value) {
            dest_ty = self.llType(e.ty) orelse "i64";
            dest = try self.nextTemp();
            try self.out.print("  {s} = alloca {s}\n", .{ dest, dest_ty });
        }

        const end_label = try self.nextLabel("match.end");

        for (arms) |arm| {
            const body_label = try self.nextLabel("match.arm");
            const next_label = try self.nextLabel("match.next");

            // A guarded arm is never a catch-all: `_ if c` can fail, and
            // treating it as unconditional would drop the panic.
            const catch_all = arm.guard == null and switch (arm.pattern.kind) {
                .wildcard, .binding => true,
                else => false,
            };
            const pattern_matches_all = switch (arm.pattern.kind) {
                .wildcard, .binding => true,
                else => false,
            };

            if (catch_all) {
                try self.out.print("  br label %{s}\n", .{body_label});
            } else if (pattern_matches_all) {
                // The pattern matches everything, so the guard is the test.
                const g = try self.emitExpr(arm.guard.?);
                if (g.isVoid()) return Value.void_value;
                try self.out.print(
                    "  br i1 {s}, label %{s}, label %{s}\n",
                    .{ g.text, body_label, next_label },
                );
            } else {
                // A string pattern is not a single comparison, so it is
                // computed first and the arm chain branches on the result.
                var cmp: []const u8 = undefined;
                if (arm.pattern.kind == .string) {
                    const eq = try self.emitStringEq(scrutinee, arm.pattern.kind.string);
                    if (eq.isVoid()) return Value.void_value;
                    cmp = eq.text;
                } else {
                    const test_val: ?Value = switch (arm.pattern.kind) {
                        .int => |v| Value{
                            .text = try std.fmt.allocPrint(self.arena, "{d}", .{v}),
                            .ty = scrutinee.ty,
                        },
                        .bool => |v| Value{ .text = if (v) "true" else "false", .ty = "i1" },
                        .enum_variant => |ev| Value{
                            .text = try std.fmt.allocPrint(self.arena, "{d}", .{ev.value}),
                            .ty = "i32",
                        },
                        .float, .string => null,
                        .wildcard, .binding => unreachable,
                    };
                    const tv = test_val orelse {
                        try self.unsupported(arm.span, "this match pattern is not lowered to LLVM IR yet");
                        return Value.void_value;
                    };
                    const c = try self.nextTemp();
                    try self.out.print(
                        "  {s} = icmp eq {s} {s}, {s}\n",
                        .{ c, scrutinee.ty, scrutinee.text, tv.text },
                    );
                    cmp = c;
                }
                if (arm.guard) |g_expr| {
                    // The guard gets its own block, because it must be
                    // evaluated ONLY when the pattern matched. Folding it into
                    // one condition would evaluate it unconditionally, and a
                    // guard may call a function.
                    const guard_label = try self.nextLabel("match.guard");
                    try self.out.print(
                        "  br i1 {s}, label %{s}, label %{s}\n",
                        .{ cmp, guard_label, next_label },
                    );
                    try self.out.print("{s}:\n", .{guard_label});
                    self.terminated = false;
                    const g = try self.emitExpr(g_expr);
                    if (g.isVoid()) return Value.void_value;
                    try self.out.print(
                        "  br i1 {s}, label %{s}, label %{s}\n",
                        .{ g.text, body_label, next_label },
                    );
                } else {
                    try self.out.print(
                        "  br i1 {s}, label %{s}, label %{s}\n",
                        .{ cmp, body_label, next_label },
                    );
                }
            }

            try self.out.print("{s}:\n", .{body_label});
            self.terminated = false;
            // A binding pattern binds the scrutinee into its own slot.
            if (arm.pattern.kind == .binding) {
                const slot = arm.pattern.kind.binding;
                try self.storeValue(
                    arm.span,
                    scrutinee,
                    self.slotType(slot),
                    self.slots.items[slot],
                    "a match binding pattern",
                );
            }
            const body_val = try self.emitExpr(arm.body);
            if (produces_value and !body_val.isVoid()) {
                try self.storeValue(arm.body.span, body_val, dest_ty, dest, "a match arm's value");
            }
            if (!self.terminated) try self.out.print("  br label %{s}\n", .{end_label});

            try self.out.print("{s}:\n", .{next_label});
            self.terminated = false;

            if (catch_all) {
                // Arms after a catch-all are unreachable. Emitting them anyway
                // would be dead code; stopping here keeps the IR honest.
                break;
            }
        }

        // Falling out of every arm means no pattern matched. The C backend
        // panics here (codegen emits cell_panic with the function name), and
        // this backend does the same so the two agree on behavior.
        const msg = try std.fmt.allocPrint(
            self.arena,
            "non-exhaustive match in {s}",
            .{self.current_fn},
        );
        const g = try self.internString(msg);
        self.uses_panic = true;
        try self.out.print("  call void @cell_panic(ptr @{s})\n", .{g});
        try self.out.writeAll("  unreachable\n");

        try self.out.print("{s}:\n", .{end_label});
        self.terminated = false;

        if (!produces_value) return Value.void_value;
        const tmp = try self.nextTemp();
        try self.out.print("  {s} = load {s}, ptr {s}\n", .{ tmp, dest_ty, dest });
        return .{ .text = tmp, .ty = dest_ty };
    }

    // -- helpers ------------------------------------------------------------

    /// The LLVM type for a Cell type, or null when this backend cannot carry
    /// it yet. Null is always turned into a diagnostic by the caller; it is
    /// never silently replaced with a plausible type.
    fn llType(self: *Emitter, ty: hir.Ty) ?[]const u8 {
        return switch (ty) {
            .unit => "void",
            .int, .uint => "i64",
            .int32 => "i32",
            .float => "double",
            .float32 => "float",
            .boolean => "i1",
            .byte => "i8",
            // An enum is an int32_t typedef in the C ABI (SPEC 10.3), so the
            // two backends agree on its width.
            .enum_type => "i32",
            // Named, not null. An earlier version returned null here and let
            // callers fall back to "i64", which allocated 8 bytes for a slot
            // that then took a 16-byte store. That is the exact failure this
            // backend claims not to have: wrong output instead of a refusal.
            .struct_type => |n| std.fmt.allocPrint(self.arena, "%cell_{s}", .{n}) catch null,
            // A bare String in expression position is a borrowed view: that is
            // what a literal is, and what codegen emits for one. A BINDING's
            // String may be owning instead, which is why slots and parameters
            // go through llTypeOwned below rather than here.
            .string => "%cell_str",
            // One type-erased header for every element type, per cell_rt.h
            // section 3: elem_size travels at the call site, not in the type.
            .list => "%cell_slice",
            .optional => |inner| blk: {
                const base = abi.optionalBase(inner.*) orelse break :blk null;
                break :blk std.fmt.allocPrint(self.arena, "%{s}", .{base}) catch null;
            },
            .result, .func, .unknown => null,
        };
    }

    /// The in-memory LLVM type of a binding, which for a String depends on
    /// ownership: `shared` is a borrowed cell_str_t, `owned` an owning
    /// cell_string_t.
    fn llTypeOwned(self: *Emitter, ty: hir.Ty, own: hir.Ownership) ?[]const u8 {
        if (ty.tag() == .string) return abi.stringStruct(own);
        return self.llType(ty);
    }

    fn nextTemp(self: *Emitter) EmitError![]const u8 {
        const t = try std.fmt.allocPrint(self.arena, "%{d}", .{self.temp});
        self.temp += 1;
        return t;
    }

    fn nextLabel(self: *Emitter, prefix: []const u8) EmitError![]const u8 {
        const l = try std.fmt.allocPrint(self.arena, "{s}.{d}", .{ prefix, self.label });
        self.label += 1;
        return l;
    }

    fn internString(self: *Emitter, bytes: []const u8) EmitError![]const u8 {
        for (self.strings.items) |g| {
            if (std.mem.eql(u8, g.bytes, bytes)) return g.name;
        }
        const name = try std.fmt.allocPrint(self.arena, ".cellstr.{d}", .{self.strings.items.len});
        try self.strings.append(self.arena, .{ .name = name, .bytes = bytes });
        return name;
    }

    fn unsupported(self: *Emitter, span: hir.Span, what: []const u8) EmitError!void {
        try self.diagnostics.err(
            self.arena,
            span,
            try std.fmt.allocPrint(self.arena, "cannot lower to LLVM IR: {s}", .{what}),
        );
    }

    fn unsupportedReturnOwnership(ty: hir.Ty, ownership: hir.Ownership) ?[]const u8 {
        const nonprimitive = switch (ty) {
            .unit, .int, .int32, .uint, .float, .float32, .boolean, .byte, .enum_type => false,
            .unknown, .string, .optional, .list, .result, .struct_type, .func => true,
        };
        if (!nonprimitive) return null;
        return switch (ownership) {
            .owned, .copy => null,
            .arc => "arc return type",
            .shared => "shared return type",
            .exclusive => "exclusive return type",
        };
    }
};

fn isFloatType(t: []const u8) bool {
    return std.mem.eql(u8, t, "double") or std.mem.eql(u8, t, "float");
}

// ---------------------------------------------------------------------------
// Tests
//
// The structural tests below pin the shape of the emitted text. The last two
// are the ones that matter: they compile the emitted IR and RUN it, because
// this repository treats "the output looked right" as no evidence at all. IR
// that clang accepts can still compute the wrong answer, and only running it
// catches that.
// ---------------------------------------------------------------------------

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

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

test "a function lowers to a define with alloca slots for its parameters" {
    var e = try emitSource(
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "define i64 @cell_add(i64 %arg0, i64 %arg1)");
    try expectContains(e.text, "%slot0 = alloca i64");
    try expectContains(e.text, "store i64 %arg0, ptr %slot0");
    try expectContains(e.text, "add nsw i64");
}

test "a struct local allocas the struct type, not a machine word" {
    // This exact case was a real defect: llType returned null for a struct and
    // the caller fell back to "i64", so a 16-byte store went into an 8-byte
    // slot. The test exists to keep that fallback from coming back.
    var e = try emitSource(
        \\pub struct Point { copy x: Float, copy y: Float }
        \\pub fn main() {
        \\  let owned p = Point { x: 1.0, y: 2.0 }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "%cell_Point = type { double, double }");
    try expectContains(e.text, "%slot0 = alloca %cell_Point");
    try expectContains(e.text, "insertvalue %cell_Point");
}

test "a bodyless declaration becomes a declare, and a Bool parameter is zeroext" {
    var e = try emitSource(
        \\pub fn assert(copy cond: Bool);
        \\pub fn print_int(copy value: Int);
    );
    defer e.deinit();
    try expectContains(e.text, "declare void @cell_assert(i1 zeroext)");
    try expectContains(e.text, "declare void @cell_print_int(i64)");
}

test "a module with a zero-parameter main gets a C entry point" {
    var e = try emitSource(
        \\pub fn main() { }
    );
    defer e.deinit();
    try expectContains(e.text, "define i32 @main()");
    try expectContains(e.text, "call void @cell_main()");
}

test "a non-exhaustive match panics and declares the runtime symbol it calls" {
    // The panic call is generated rather than declared in the source, so its
    // declaration has to be generated too. Without it the module references an
    // undefined symbol and clang refuses the whole file.
    var e = try emitSource(
        \\pub enum Color { Red, Green }
        \\pub fn f(copy c: Color) -> Int {
        \\  return match c { Color.Red => 1, }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "declare void @cell_panic(ptr)");
    try expectContains(e.text, "call void @cell_panic(ptr @.cellstr.0)");
    try expectContains(e.text, "unreachable");
}

test "unsigned division uses udiv, signed uses sdiv" {
    var e = try emitSource(
        \\pub fn s(copy a: Int, copy b: Int) -> Int { return a / b }
        \\pub fn u(copy a: UInt, copy b: UInt) -> UInt { return a / b }
    );
    defer e.deinit();
    try expectContains(e.text, "sdiv i64");
    try expectContains(e.text, "udiv i64");
}

test "arc is still refused with a diagnostic rather than emitted wrongly" {
    // [T] USED to be here and now lowers as a cell_slice_t, so this moved to
    // the type that is still genuinely unplaceable: `arc` has no retain and
    // release insertion (OWNERSHIP R11), so placing a cell_arc_t correctly
    // would be lowering half a feature. When R11 lands this test should go red
    // and become a capability test, the way its predecessors did.
    var e = try emitSource(
        \\pub fn g(arc s: String) -> Int;
    );
    defer e.deinit();
    try std.testing.expect(e.bag.hasErrors());
    var found = false;
    for (e.bag.list.items) |d| {
        if (std.mem.indexOf(u8, d.message, "cannot lower to LLVM IR") != null) found = true;
    }
    try std.testing.expect(found);
}

test "arc return declarations definitions and calls are refused from HIR ownership" {
    var declaration = try emitSource(
        \\pub fn external() -> arc String;
    );
    defer declaration.deinit();
    try expectDiagnosticContains(&declaration.bag, "cannot lower to LLVM IR: arc return type");

    var definition = try emitSource(
        \\pub fn values() -> arc [Int] { return [] }
    );
    defer definition.deinit();
    try expectDiagnosticContains(&definition.bag, "cannot lower to LLVM IR: arc return type");

    var callee = hir.Expr{ .ty = .unit, .span = .none, .kind = .{ .int_const = 0 } };
    var statements = [_]hir.Stmt{.{
        .span = .none,
        .kind = .{ .ret = .{
            .ty = .{ .struct_type = "Box" },
            .span = .none,
            .kind = .{ .call = .{
                .symbol = "cell_external",
                .callee = &callee,
                .args = &.{},
                .modes = &.{},
                .ret_ownership = .arc,
            } },
        } },
    }};
    var functions = [_]hir.Fn{.{
        .name = "caller",
        .symbol = "cell_caller",
        .param_count = 0,
        .bindings = &.{},
        .ret = .{ .struct_type = "Box" },
        .ret_ownership = .owned,
        .body = &statements,
        .is_public = true,
        .span = .none,
    }};
    var structs = [_]hir.Struct{.{ .name = "Box", .fields = &.{}, .is_public = true }};
    var module = hir.Module{ .path = "direct.hir", .structs = &structs, .enums = &.{}, .fns = &functions };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var buf: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);
    var bag: diag.Bag = .init("direct.hir", "");
    defer bag.deinit(allocator);
    try emitModule(allocator, &module, &writer, &bag);
    try expectDiagnosticContains(&bag, "cannot lower to LLVM IR: arc return type");
}

test "return ownership guard preserves primitives and refuses nonprimitive borrows" {
    var primitive = try emitSource(
        \\pub fn ai() -> arc Int { return 1 }
        \\pub fn sb() -> shared Bool;
        \\pub fn ef() -> exclusive Float;
        \\pub fn os() -> String;
        \\pub fn cs() -> copy String;
    );
    defer primitive.deinit();
    try std.testing.expect(!primitive.bag.hasErrors());

    var borrowed = try emitSource(
        \\pub fn shared_string() -> shared String;
        \\pub fn exclusive_list() -> exclusive [Int];
    );
    defer borrowed.deinit();
    try expectDiagnosticContains(&borrowed.bag, "shared return type");
    try expectDiagnosticContains(&borrowed.bag, "exclusive return type");
}

fn expectDiagnosticContains(bag: *const diag.Bag, needle: []const u8) !void {
    for (bag.list.items) |d| {
        if (std.mem.indexOf(u8, d.message, needle) != null) return;
    }
    return error.MissingDiagnostic;
}

/// Compile emitted IR, link it against the real runtime, run it, and return
/// what it printed. Uses `cc`, not `zig cc`: measured, `zig cc -x ir` fails
/// outright with "language not recognized: ir".
fn runEmitted(text: []const u8) ![]const u8 {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.ll", .data = text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const root = cwd_buf[0..cwd_len];
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{root});
    defer gpa.free(rt_c);
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{root});
    defer gpa.free(include);

    const obj = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-Wno-override-module", "-x", "ir", "prog.ll", "-c", "-o", "prog.o" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(obj.stdout);
    defer gpa.free(obj.stderr);
    if (!obj.term.success()) {
        std.debug.print("clang rejected emitted IR:\n{s}\n--- ir ---\n{s}\n", .{ obj.stderr, text });
        return error.ClangRejectedEmittedIr;
    }

    const link = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "prog.o", rt_c, "-I", include, "-o", "prog" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(link.stdout);
    defer gpa.free(link.stderr);
    if (!link.term.success()) {
        std.debug.print("link failed:\n{s}\n", .{link.stderr});
        return error.LinkFailed;
    }

    const run = try std.process.run(gpa, io, .{
        .argv = &.{"./prog"},
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(run.stderr);
    if (!run.term.success()) {
        gpa.free(run.stdout);
        return error.ProgramFailed;
    }
    return run.stdout;
}

test "emitted IR compiles, links against the runtime, and prints the right answer" {
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
    try std.testing.expect(!e.bag.hasErrors());

    const out = try runEmitted(e.text);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("42\n", out);
}

test "control flow and match produce the same answer the C backend does" {
    // choose(3) is 4 and classify(Green) is 20, so this prints 24. The C
    // backend was run on the identical source and printed 24 too; that
    // agreement is the point of having a second backend at all.
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

    const out = try runEmitted(e.text);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("24\n", out);
}

test "an HFA struct parameter uses the AAPCS64 coerced form" {
    // The defect this fixes. Measured with clang: a {double, double}
    // parameter is [2 x double], not the struct type. Passing it directly was
    // invisible while both sides of a call were Cell, and wrong the moment it
    // crossed to C.
    var e = try emitSource(
        \\pub struct Point { copy x: Float, copy y: Float }
        \\pub fn getx(copy p: Point) -> Float { return p.x }
    );
    defer e.deinit();
    try expectContains(e.text, "define double @cell_getx([2 x double]");
}

test "a borrowed struct parameter is a pointer and its fields are read through it" {
    // Matches what the C backend emits for the SIGNATURE: `const cell_Buffer
    // *b`. The parameter is the lender's address and the slot is one word.
    //
    // The FIELD READ changed shape, and deliberately. It used to be a
    // `getelementptr` through the borrow, keyed on a `ptr_to` tag riding on
    // the emitted value. That tag was the second defect in this file: two
    // consumers honoured it and the rest silently received pointer bits. The
    // `.ref` arm loads through the borrow now, so a field read is the same
    // `extractvalue` an owned struct gets and there is no second path to keep
    // in step. `mem2reg` plus `instcombine` fold the extra load back to the
    // same load of the field, so this is not a code-quality regression at -O1.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn read(shared b: Buffer) -> Int { return b.len }
    );
    defer e.deinit();
    try expectContains(e.text, "define i64 @cell_read(ptr");
    try expectContains(e.text, "%slot0 = alloca ptr");
    try expectContains(e.text, "load %cell_Buffer, ptr");
    try expectContains(e.text, "extractvalue %cell_Buffer");
}

test "a non-HFA struct of 16 bytes coerces to integer words" {
    var e = try emitSource(
        \\pub struct Pair { copy a: Int, copy b: Int }
        \\pub fn first(copy v: Pair) -> Int { return v.a }
    );
    defer e.deinit();
    try expectContains(e.text, "define i64 @cell_first([2 x i64]");
}

test "a struct return over 16 bytes uses sret" {
    // Too large for registers, so it comes back through a caller-allocated
    // buffer passed as a hidden first parameter, and the function returns
    // void. This test previously asserted the case was REFUSED; sret is now
    // implemented, so it asserts the convention instead.
    var e = try emitSource(
        \\pub struct Big { copy a: Int, copy b: Int, copy c: Int }
        \\pub fn make() -> Big { return Big { a: 1, b: 2, c: 3 } }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "define void @cell_make(ptr sret(%cell_Big) %sret)");
    try expectContains(e.text, "store %cell_Big");
    try expectContains(e.text, "ret void");
}

test "a borrowed struct crosses to C as a pointer, with the right value" {
    // THE regression test, and it guards a MEASURED defect rather than a
    // suspected one.
    //
    // The C backend declares `int64_t cell_read(const cell_Buffer *b)`. Before
    // this change the LLVM backend passed the struct BY VALUE for the same
    // signature. Linking those two together and calling across reads the
    // pointer as an integer: measured, a `len` of 42 came back as
    // 6098707152.
    //
    // A wrong calling convention is invisible Cell-to-Cell, because both
    // halves share it. Only a real C boundary shows it, which is why this test
    // compiles a C driver that declares the function the way the C backend
    // does.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn read(shared b: Buffer) -> Int { return b.len }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "prog.ll", .data = e.text });
    try tmp.dir.writeFile(io, .{ .sub_path = "drv.c", .data =
        \\#include <stdio.h>
        \\typedef struct { long long len; } Buffer;
        \\extern long long cell_read(const Buffer *b);
        \\int main(void) {
        \\    Buffer b = { 42 };
        \\    printf("%lld\n", cell_read(&b));
        \\    return 0;
        \\}
    });

    const obj = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-Wno-override-module", "-x", "ir", "prog.ll", "-c", "-o", "prog.o" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(obj.stdout);
    defer gpa.free(obj.stderr);
    if (!obj.term.success()) {
        std.debug.print("clang rejected emitted IR:\n{s}\n--- ir ---\n{s}\n", .{ obj.stderr, e.text });
        return error.ClangRejectedEmittedIr;
    }

    const link = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "prog.o", "drv.c", "-o", "prog" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(link.stdout);
    defer gpa.free(link.stderr);
    if (!link.term.success()) {
        std.debug.print("link failed:\n{s}\n", .{link.stderr});
        return error.LinkFailed;
    }

    const run = try std.process.run(gpa, io, .{ .argv = &.{"./prog"}, .cwd = .{ .dir = tmp.dir } });
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    if (!run.term.success()) return error.ProgramFailed;
    // Passing the struct by value here yields the POINTER reinterpreted as an
    // integer, not 42.
    try std.testing.expectEqualStrings("42\n", run.stdout);
}

test "a shared String parameter is passed as two words" {
    // codegen maps `shared String` to cell_str_t, a 16-byte borrowed
    // {ptr, len} view, which AAPCS64 passes as [2 x i64].
    var e = try emitSource(
        \\pub fn slen(shared s: String) -> Int;
    );
    defer e.deinit();
    try expectContains(e.text, "%cell_str = type { ptr, i64 }");
    try expectContains(e.text, "declare i64 @cell_slen([2 x i64])");
}

test "a string literal materializes a cell_str_t rather than calling the runtime" {
    // cell_str_from_parts is `static inline` and has no symbol, so the struct
    // is built here with insertvalue.
    var e = try emitSource(
        \\pub fn slen(shared s: String) -> Int;
        \\pub fn f() -> Int { return slen(shared "hello") }
    );
    defer e.deinit();
    try expectContains(e.text, "@.cellstr.0 = private unnamed_addr constant [5 x i8] c\"hello\"");
    try expectContains(e.text, "insertvalue %cell_str undef, ptr @.cellstr.0, 0");
    try expectContains(e.text, "insertvalue %cell_str %0, i64 5, 1");
}

test "an argument is coerced to the form the callee declares" {
    // The value is COMPUTED as %cell_str and PASSED as [2 x i64]. Emitting the
    // natural form at a call site whose declaration says the coerced one is a
    // type mismatch clang rejects outright, which is how this was caught.
    var e = try emitSource(
        \\pub fn slen(shared s: String) -> Int;
        \\pub fn f() -> Int { return slen(shared "hi") }
    );
    defer e.deinit();
    try expectContains(e.text, "load [2 x i64], ptr");
    try expectContains(e.text, "call i64 @cell_slen([2 x i64]");
}

test "a String return comes back through sret as an owning cell_string" {
    // A return carries no ownership annotation and codegen treats `-> String`
    // as owning, so it is a 24-byte cell_string_t, too large for registers.
    var e = try emitSource(
        \\pub fn make() -> String;
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "declare void @cell_make(ptr sret(%cell_string))");
}

test "an optional lowers to the runtime's tagged instance" {
    // Int? is cell_opt_i64_t, `{ bool has_value; int64_t value; }`, 16 bytes,
    // so it coerces to two words. String? is 24 and goes indirect.
    var e = try emitSource(
        \\pub fn f(shared v: Int?) -> Bool;
        \\pub fn g(shared s: String?) -> Bool;
    );
    defer e.deinit();
    try expectContains(e.text, "%cell_opt_i64 = type { i8, i64 }");
    try expectContains(e.text, "declare i1 @cell_f([2 x i64])");
    try expectContains(e.text, "declare i1 @cell_g(ptr)");
}

test "a struct returned through sret and consumed again computes correctly" {
    // End to end: a 24-byte struct built in one function, returned via sret,
    // passed indirectly into another, and summed. 7 * 3 = 21.
    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub struct Big { copy a: Int, copy b: Int, copy c: Int }
        \\pub fn make(copy n: Int) -> Big { return Big { a: n, b: n, c: n } }
        \\pub fn sum(copy v: Big) -> Int { return v.a + v.b + v.c }
        \\pub fn main() { print_int(sum(copy make(copy 7))) }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    const out = try runEmitted(e.text);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("21\n", out);
}

test "a String reaches the real runtime and prints" {
    // End to end against runtime/cell_rt.c, whose cell_println takes a real
    // cell_str_t. If the ABI were wrong the pointer and length would arrive
    // swapped or garbled and this would crash or print nothing.
    var e = try emitSource(
        \\pub fn println(shared msg: String);
        \\pub fn main() { println(shared "hello from Cell via LLVM") }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    const out = try runEmitted(e.text);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello from Cell via LLVM\n", out);
}

test "a string pattern compares length, guards null, then calls memcmp" {
    // Faithful to cell_str_eq (runtime/cell_rt.h:184), which cannot be called
    // because it is `static inline`. The ORDER is the point: calling memcmp on
    // a null pointer or with a mismatched length is undefined behaviour.
    var e = try emitSource(
        \\pub fn f(shared s: String) -> Int { return match s { "yes" => 1, _ => 0, } }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "declare i32 @memcmp(ptr, ptr, i64)");
    try expectContains(e.text, "icmp eq i64"); // length first
    try expectContains(e.text, "icmp eq ptr"); // then the null guard
    try expectContains(e.text, "call i32 @memcmp("); // only then memcmp
}

test "an empty string pattern needs no memcmp at all" {
    // cell_str_eq returns true for two empty strings without touching either
    // pointer, so the lowering must not call memcmp with length 0.
    var e = try emitSource(
        \\pub fn f(shared s: String) -> Int { return match s { "" => 1, _ => 0, } }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    if (std.mem.indexOf(u8, e.text, "@memcmp") != null) {
        std.debug.print("unexpected memcmp for an empty pattern:\n{s}\n", .{e.text});
        return error.UnexpectedMemcmp;
    }
}

test "string matching computes the same answers the C backend does" {
    // The C backend prints 1 2 3 9 for this program, including the empty case.
    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub fn classify(shared s: String) -> Int {
        \\  return match s { "yes" => 1, "no" => 2, "" => 3, _ => 9, }
        \\}
        \\pub fn main() {
        \\  print_int(classify(shared "yes"))
        \\  print_int(classify(shared "no"))
        \\  print_int(classify(shared ""))
        \\  print_int(classify(shared "other"))
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    const out = try runEmitted(e.text);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("1\n2\n3\n9\n", out);
}

test "a [Byte] field and an empty list literal lower" {
    var e = try emitSource(
        \\pub struct Buffer { owned data: [Byte], copy len: Int }
        \\pub fn main() { let owned b = Buffer { data: [], len: 9 } }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "%cell_slice = type { ptr, i64, i64 }");
    try expectContains(e.text, "insertvalue %cell_slice undef, ptr null, 0");
}

test "an exclusive borrow writes through to the CALLER's object, in every spelling" {
    // THE miscompile test, and it is a RUN rather than a read, because this
    // defect was invisible in every check that did not execute the program.
    //
    // `coerceArg` spilled the loaded aggregate to a fresh alloca and passed
    // THAT address, so `bump(exclusive buf)` incremented a temporary which
    // died at the call. The program did not crash, refuse, or warn: it printed
    // the wrong number. `tools/check.sh` was green throughout, because its
    // backend-agreement stage compares emit VERDICTS and both backends accept
    // this program, while its execution stage ran four examples and none of
    // them wrote through a borrow.
    //
    // All five unique-borrow spellings are exercised, not one. `exclusive buf`
    // reaches emitCall as `.ref` because `hir.lower` consumes the written
    // prefix, while `&mut`, `&var`, `&exclusive` and the keyword-plus-sigil
    // form arrive wrapped in `.unary{ref_exclusive}`. A fix that matched only
    // the bare `.ref` would write through for one spelling and lose the write
    // for the other four, which is the divergence examples/borrows.cell exists
    // to forbid, and the arithmetic here would catch it: each spelling adds 1,
    // so any single one going missing prints 41 rather than 42.
    //
    // It also pins the CALLEE half. `placeAddress` indexed the parameter's
    // slot directly, but a borrowed parameter's slot holds the caller's
    // ADDRESS, so `b.len = b.len + 5` read the right value and stored the
    // result over the pointer variable. Both halves have to be right for this
    // to print 42; either one alone still prints 37.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn print_int(copy value: Int);
        \\pub fn bump(exclusive b: Buffer) { b.len = b.len + 1 }
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 37 }
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

    const out = try runEmitted(e.text);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("42\n", out);
}

test "every borrow spelling passes the SAME operand, the caller's own slot" {
    // The run above proves the answer; this proves the SHAPE, and the two
    // catch different regressions. A future change could keep the answer right
    // by some other route while reintroducing a per-spelling difference, and
    // examples/borrows.cell exists precisely to forbid that: the seven calls
    // there must be indistinguishable in the emitted IR.
    //
    // The C backend spells all seven `&buf` (measured, in its own emitted C),
    // and the MLIR backend passes the one slot for all of them since 78eadb2.
    // This is the third backend agreeing on the same thing rather than merely
    // being accepted alongside them.
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
        \\  grow(&exclusive buf)
        \\  grow(exclusive &buf)
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());

    // The exact text the defect produced: a second alloca of the struct, in a
    // function that declares exactly one Buffer. Pinned so it cannot come back
    // by another route.
    var allocas: usize = 0;
    var calls: usize = 0;
    var it = std.mem.splitScalar(u8, e.text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");
        if (std.mem.indexOf(u8, trimmed, "alloca %cell_Buffer") != null) allocas += 1;
        if (!std.mem.startsWith(u8, trimmed, "call void @cell_look") and
            !std.mem.startsWith(u8, trimmed, "call void @cell_grow")) continue;
        calls += 1;
        if (std.mem.indexOf(u8, trimmed, "(ptr %slot0)") == null) {
            std.debug.print("call does not pass the caller's slot:\n{s}\nin:\n{s}\n", .{ trimmed, e.text });
            return error.BorrowArgumentIsACopy;
        }
    }
    try std.testing.expectEqual(@as(usize, 7), calls);
    try std.testing.expectEqual(@as(usize, 1), allocas);
}

test "an indirect aggregate parameter still gets a caller-owned copy" {
    // The other half of the rule, and the reason `borrowsByPointer` asks
    // abi.classifyParam instead of reading the four characters `renderParam`
    // prints. `Big` is 24 bytes, so it is passed `.indirect`: the CALLER
    // allocates a copy and hands over its address, and the callee is entitled
    // to write to that memory. Both spell `ptr`. Passing the caller's own
    // storage here would have traded a lost-write defect for an unwanted-write
    // one, which is why the call site classifies rather than string-matches.
    var e = try emitSource(
        \\pub struct Big { copy a: Int, copy b: Int, copy c: Int }
        \\pub fn take(copy v: Big) -> Int { return v.a }
        \\pub fn main() {
        \\  let owned big = Big { a: 1, b: 2, c: 3 }
        \\  let copy n = take(copy big)
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "define i64 @cell_take(ptr %arg0)");
    // Three allocas of %cell_Big across the module: the callee's own slot (it
    // copies the argument in), the caller's `big` binding, and the
    // caller-owned copy the call site hands over. If this ever reads two, the
    // copy was elided and `cell_take` can scribble on `big`.
    var allocas: usize = 0;
    var it = std.mem.splitScalar(u8, e.text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "alloca %cell_Big") != null) allocas += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), allocas);
}

test "a borrow bound to a NAME writes through to the lender, not to a copy" {
    // THE DEFECT: the slot-shape predicate read `i < f.param_count and ...`,
    // a claim about PARAMETERS applied to every binding. A let-bound borrow
    // got a struct-shaped slot, was initialized with a loaded COPY of the
    // lender, and handed that copy's address to every later call, so the
    // write landed in the copy. This printed 37 where the C backend, which
    // spells the same binding `cell_Buffer *e = &buf;`, printed 41.
    //
    // Four spellings rather than five: the keyword form
    // `let exclusive e = exclusive buf` is a copy in the C backend today (see
    // the test below and examples/write_through_named.cell), so pinning five
    // here would pin a disagreement with the reference backend.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int, copy step: Int }
        \\pub fn print_int(copy value: Int);
        \\pub fn bump(exclusive b: Buffer) {
        \\  b = Buffer { len: b.len + b.step, step: b.step }
        \\}
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 37, step: 1 }
        \\  let exclusive e1 = &mut buf
        \\  bump(exclusive e1)
        \\  let exclusive e2 = &var buf
        \\  bump(exclusive e2)
        \\  let exclusive e3 = &exclusive buf
        \\  bump(exclusive e3)
        \\  let exclusive e4 = exclusive &buf
        \\  bump(exclusive e4)
        \\  print_int(buf.len)
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());

    // The slot is one word holding an address, not a copy of the struct.
    try expectContains(e.text, "%slot1 = alloca ptr");
    try expectContains(e.text, "store ptr %slot0, ptr %slot1");

    const out = try runEmitted(e.text);
    defer std.testing.allocator.free(out);
    // 41, not 37: a lost write costs one per spelling, so 40, 39, 38 and 37
    // each name a count of broken spellings.
    try std.testing.expectEqualStrings("41\n", out);
}

test "the five unique-borrow spellings emit byte-identical IR in a let" {
    // examples/borrows.cell declares the five identical, and they do NOT
    // reach a backend as one shape: `exclusive buf` arrives as a bare
    // reference because hir.lower consumes the written prefix, while `&mut`,
    // `&var`, `&exclusive` and `exclusive &buf` arrive wrapped in a unary
    // borrow node. A backend that handles one and not the others splits the
    // group with nothing said, which is invisible to any check that reads a
    // single spelling.
    //
    // Note what this test does NOT say. All five agree HERE, and the C
    // backend disagrees with all of them on the keyword form: `codegen.zig`
    // emits `cell_Buffer e = buf;` for `let exclusive e = exclusive buf` and
    // `cell_Buffer *e = &buf;` for the other four, while `borrowck.zig`
    // creates a real exclusive loan for all five. That is a defect in
    // codegen.zig, outside this file, and it is recorded rather than matched.
    const spellings = [_][]const u8{
        "exclusive buf",
        "&mut buf",
        "&var buf",
        "&exclusive buf",
        "exclusive &buf",
    };
    var first: ?[]const u8 = null;
    var first_emitted: ?Emitted = null;
    defer if (first_emitted) |*fe| fe.deinit();

    for (spellings) |sp| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\pub struct Buffer {{ copy len: Int, copy step: Int }}
            \\pub fn print_int(copy value: Int);
            \\pub fn bump(exclusive b: Buffer) {{
            \\  b = Buffer {{ len: b.len + b.step, step: b.step }}
            \\}}
            \\pub fn main() {{
            \\  var owned buf = Buffer {{ len: 37, step: 1 }}
            \\  let exclusive e = {s}
            \\  bump(exclusive e)
            \\  print_int(buf.len)
            \\}}
        , .{sp});
        defer std.testing.allocator.free(src);

        var e = try emitSource(src);
        try std.testing.expect(!e.bag.hasErrors());
        if (first) |want| {
            defer e.deinit();
            if (!std.mem.eql(u8, want, e.text)) {
                std.debug.print("spelling '{s}' emits different IR\n", .{sp});
                return error.SpellingsDisagree;
            }
        } else {
            first = e.text;
            first_emitted = e;
        }
    }
}

test "a borrow consumed BY VALUE is loaded through, not handed over" {
    // THE SECOND DEFECT, and the one the first fix would have INTRODUCED had
    // it stopped at making the slot hold an address. `Value` carried a
    // `ptr_to` tag saying "this operand is really an address"; two consumers
    // knew about it and the rest did not, so a borrow reaching any other
    // value position handed over pointer bits. Both shapes below were silent:
    // `let copy c = b` stored the address into a struct-shaped slot, and
    // `sum(copy b)` loaded sixteen bytes out of an eight-byte alloca and
    // passed the pointer. This program printed 18400323745 where the C and
    // MLIR backends printed 84.
    //
    // The fix is the invariant, not the two positions: an emitted value is
    // always a value, and the three functions that are ASKED for an address
    // are the only producers of one.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int, copy step: Int }
        \\pub fn print_int(copy value: Int);
        \\pub fn sum(copy b: Buffer) -> Int { return b.len + b.step }
        \\pub fn doubled(exclusive b: Buffer) -> Int {
        \\  let copy c = b
        \\  return sum(copy c) + sum(copy b)
        \\}
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 40, step: 2 }
        \\  print_int(doubled(exclusive buf))
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());

    const out = try runEmitted(e.text);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("84\n", out);
}

test "a let-bound borrow consumed by value reads the lender, not its address" {
    // The same question asked of a LOCAL rather than a parameter, which is a
    // different slot and was reachable only once a let-bound borrow started
    // holding an address. At HEAD this program was correct BECAUSE the
    // let-bound borrow was a copy; fixing that alone would have broken it.
    // Measured: with the binding fix applied and this one reverted, it prints
    // a number in the billions.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int, copy step: Int }
        \\pub fn print_int(copy value: Int);
        \\pub fn sum(copy b: Buffer) -> Int { return b.len + b.step }
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 40, step: 2 }
        \\  let exclusive e = &mut buf
        \\  let copy c = e
        \\  print_int(sum(copy c) + sum(copy e) - 42)
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());

    const out = try runEmitted(e.text);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("42\n", out);
}

test "a borrow of a value with no address is refused, not bound to a copy" {
    // `borrowAddress` deliberately does not reuse the call site's spill path.
    // That one stores a temporary into a fresh alloca and hands over its
    // address, which is right for an argument, where nothing outlives the
    // call and can observe a write back, and exactly wrong for a binding.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn mk() -> Buffer { return Buffer { len: 1 } }
        \\pub fn grow(exclusive b: Buffer) { b = Buffer { len: b.len + 1 } }
        \\pub fn main() {
        \\  let exclusive e = &mut mk()
        \\  grow(exclusive e)
        \\}
    );
    defer e.deinit();
    try std.testing.expect(e.bag.hasErrors());
}

test "an exclusive String is a pointer, and a write through one LANDS" {
    // THE THIRD DEFECT, and it lived in the module whose header says every
    // fact in it was measured. `abi.classifyParam` placed `exclusive String`
    // BY VALUE as `[2 x i64]` while `codegen.applyOwnership` emitted
    // `cell_string_t *` and wrote through it. This backend followed abi.zig,
    // accepted the program, gave the binding a 16-byte `%cell_str` slot and
    // stored a 24-byte `%cell_string` into it: eight bytes past the end of
    // the alloca, plus a write the caller could never see.
    //
    // THE EXPECTATION HERE CHANGED, and the change is the point. This test
    // used to assert `hasErrors()`: the declaration was already a pointer, but
    // the WRITE was refused, purely so this backend's verdict matched
    // `mlirmit.zig`, which still passed these three aggregates by value and
    // therefore held a copy the lender could not see. That file asks
    // `abi.classifyParam` now, so both backends pass a pointer and both write
    // through it, and there is nothing left for either to refuse. The refusal
    // was never a limitation of the lowering; the comment it carried said so
    // and asked for exactly this pair of changes in one commit.
    //
    // `make` IS BODYLESS, and that is a correction rather than a tidy-up. It
    // read `-> String { return "abcdefg" }`, which the placement guard now
    // refuses in its own right, so the test would have gone on measuring the
    // wrong thing.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn reset(exclusive s: String) { s = make() }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try expectContains(e.text, "define void @cell_reset(ptr %arg0)");
    // The slot holds the caller's ADDRESS, so the write is two steps: load the
    // address out of the slot, then store the whole 24-byte owning value
    // through it. A store INTO `%slot0` would be the lost write this closes.
    try expectContains(e.text, "%2 = load ptr, ptr %slot0");
    try expectContains(e.text, "store %cell_string %1, ptr %2");

    // Reading through one is still lowered, which is where mlirmit.zig also
    // stands, so the two backends agree on the parameter and on the write.
    var ok = try emitSource(
        \\pub fn peek(exclusive s: String) -> Int { return 7 }
    );
    defer ok.deinit();
    try std.testing.expect(!ok.bag.hasErrors());
    try expectContains(ok.text, "define i64 @cell_peek(ptr %arg0)");
    // One word for the address, not a 16-byte view of a 24-byte object.
    try expectContains(ok.text, "%slot0 = alloca ptr");
}

test "the borrowed-view to owning-String conversion is refused at EVERY position" {
    // THE FOURTH DEFECT, and the one this file's own contract forbade. A
    // literal is a 16-byte borrowed `%cell_str`; an owned `String` is a
    // 24-byte owning `%cell_string`; turning the first into the second is a
    // call to `cell_string_from_str` that copies the characters. That symbol
    // cannot be called from here, so the conversion has to be refused.
    //
    // It was not. Measured at 2298fa9, all six programs below passed
    // `cell check` and emitted IR, and `pub fn f() { let owned s: String =
    // "ab" }` produced:
    //
    //     %slot0 = alloca %cell_string     ; 24 bytes
    //     store %cell_str %1, ptr %slot0   ; 16 bytes written
    //
    // leaving `cap` uninitialized and `.ptr` aimed at a static literal. The
    // conversion HAD been noticed once, for `-> arc String`, and the same
    // question was never asked of its siblings.
    //
    // THE TABLE IS EVIDENCE, NOT THE FIX. The fix is one predicate, `fits`,
    // asked wherever a value meets a destination; six positional checks would
    // have closed six holes and left the seventh. The seventh is here too:
    // `-> arc String` is now refused earlier from its return contract, before
    // this conversion can be considered.
    const cases = [_][]const u8{
        // 1. a literal returned from an owning-String function
        \\pub fn f() -> String { return "ab" }
        ,
        // 2. a literal in a `let owned` initializer
        \\pub fn f() { let owned s: String = "ab" }
        ,
        // 3. the same in a `var owned`
        \\pub fn f() { var owned s: String = "ab" }
        ,
        // 4. a literal passed to an `owned String` parameter
        \\pub fn g(owned s: String);
        \\pub fn f() { g(owned "ab") }
        ,
        // 5. a literal in an owning-String struct field
        \\pub struct B { owned name: String }
        \\pub fn f() { let owned b = B { name: "ab" } }
        ,
        // 6. a literal ASSIGNED to an owning-String local. `make` is bodyless
        //    on purpose: a literal in the initializer would refuse there and
        //    mask the assignment, which is the position under test.
        \\pub fn make() -> String;
        \\pub fn f() { var owned s: String = make() s = "cd" }
        ,
        // 7. the seventh shape, the one that was half-handled.
        \\pub fn f() -> arc String { return "ab" }
        ,
    };
    for (cases, 0..) |src, i| {
        var e = try emitSource(src);
        defer e.deinit();
        if (!e.bag.hasErrors()) {
            std.debug.print("case {d} was ACCEPTED:\n{s}\nemitted:\n{s}\n", .{ i + 1, src, e.text });
            return error.ConversionAccepted;
        }
        // The diagnostic must name BOTH types. "cannot lower" alone would pass
        // against a refusal for some unrelated reason, which is how a table
        // like this stops testing what it claims to.
        var named = false;
        for (e.bag.list.items) |d| {
            if (std.mem.indexOf(u8, d.message, "%cell_str where %cell_string") != null or
                (i == 6 and std.mem.indexOf(u8, d.message, "arc return type") != null)) named = true;
        }
        if (!named) {
            std.debug.print("case {d} refused without naming the conversion:\n", .{i + 1});
            for (e.bag.list.items) |d| std.debug.print("  {s}\n", .{d.message});
            return error.RefusalDoesNotNameTheConversion;
        }
    }
}

test "the guard does not refuse the ABI's own re-spellings, or a matching String" {
    // The other half of a total guard, and the half that makes it safe to
    // have one. `coerceArg` and the parameter prologue legitimately change a
    // value's spelling on its way into a register or a hidden buffer, and the
    // guard must not see any of it. That is why the call-argument check
    // compares against the parameter's NATURAL type BEFORE the coercion:
    // `coerceArg(v, "ptr")` returns `.ty = "ptr"` whatever it was handed, so a
    // check placed after it would compare `ptr` to `ptr` and let case 4 of the
    // table above straight through.
    const cases = [_][]const u8{
        // A borrowed view into a borrowed-view parameter, coerced to [2 x i64].
        \\pub fn slen(shared s: String) -> Int;
        \\pub fn f() -> Int { return slen(shared "hi") }
        ,
        // A borrowed-view binding: no conversion, so no refusal.
        \\pub fn f() { let shared s: String = "ab" }
        ,
        // An OWNING String from a call into an owning binding, which is the
        // pairing that already agrees and must keep lowering.
        \\pub fn make() -> String;
        \\pub fn f() { let owned s: String = make() }
        ,
        // A 24-byte struct passed indirectly: natural type matches, then
        // coerceArg spills it to a `ptr`.
        \\pub struct Big { copy a: Int, copy b: Int, copy c: Int }
        \\pub fn take(copy v: Big) -> Int { return v.a }
        \\pub fn f() -> Int { let owned b = Big { a: 1, b: 2, c: 3 } return take(copy b) }
        ,
        // An HFA struct, which the ABI passes as [2 x double].
        \\pub struct Point { copy x: Float, copy y: Float }
        \\pub fn getx(copy p: Point) -> Float { return p.x }
        \\pub fn f() -> Float { return getx(copy Point { x: 1.0, y: 2.0 }) }
        ,
    };
    for (cases, 0..) |src, i| {
        var e = try emitSource(src);
        defer e.deinit();
        if (e.bag.hasErrors()) {
            std.debug.print("case {d} was REFUSED:\n{s}\n", .{ i + 1, src });
            for (e.bag.list.items) |d| std.debug.print("  {s}\n", .{d.message});
            return error.LegitimateProgramRefused;
        }
    }
}
