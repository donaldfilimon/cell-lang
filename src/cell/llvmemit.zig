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
const Value = struct {
    text: []const u8,
    ty: []const u8,
    /// When set, `text` is the ADDRESS of an aggregate of this LLVM type
    /// rather than the aggregate itself. A borrowed struct parameter arrives
    /// as a pointer under AAPCS64 (the C backend spells it
    /// `const cell_Buffer *`), so a field read has to `getelementptr` through
    /// it instead of `extractvalue` out of it.
    ptr_to: ?[]const u8 = null,

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
    /// value. Only borrowed aggregate parameters are stored this way, because
    /// an `exclusive` borrow must write through to the caller's object; a copy
    /// would silently drop every mutation.
    slot_ptr_to: std.ArrayList(?[]const u8) = .empty,
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
        const uses_sret = abi.classifyReturn(self.module, f.ret) == .indirect;
        const ret = abi.renderReturn(self.arena, self.module, f.ret) orelse {
            try self.unsupported(f.span, "return type");
            return;
        };
        // The natural in-memory type of the return, which is what the body
        // computes. It differs from `ret` whenever the ABI coerces.
        const ret_natural = self.llType(f.ret) orelse ret;

        self.temp = 0;
        self.label = 0;
        self.terminated = false;
        self.current_fn = f.name;
        self.slots.clearRetainingCapacity();
        try self.slots.resize(self.arena, f.bindings.len);
        self.slot_ptr_to.clearRetainingCapacity();
        try self.slot_ptr_to.resize(self.arena, f.bindings.len);
        for (self.slot_ptr_to.items) |*p| p.* = null;
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
            // A borrowed aggregate parameter's slot holds a pointer, so it is
            // one word rather than the whole struct.
            const is_ref = i < f.param_count and blk: {
                const p = f.bindings[i];
                if (p.ty.tag() != .struct_type) break :blk false;
                break :blk switch (abi.classifyParam(self.module, p.ty, p.ownership)) {
                    .direct => |sp| std.mem.eql(u8, sp, "ptr"),
                    else => false,
                };
            };
            try self.out.print("  {s} = alloca {s}\n", .{ name, if (is_ref) "ptr" else t });
        }
        for (f.params(), 0..) |p, i| {
            const natural = self.llTypeOwned(p.ty, p.ownership) orelse continue;
            switch (abi.classifyParam(self.module, p.ty, p.ownership)) {
                .direct => |spelling| {
                    if (std.mem.eql(u8, spelling, "ptr") and p.ty.tag() == .struct_type) {
                        // A borrowed aggregate. Keep the ADDRESS: an
                        // `exclusive` borrow must write through to the
                        // caller's object, and copying it in would silently
                        // drop every mutation.
                        self.slot_ptr_to.items[i] = natural;
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

    // -- statements ---------------------------------------------------------

    fn emitStmt(self: *Emitter, stmt: *const hir.Stmt) EmitError!void {
        if (self.terminated) return;
        switch (stmt.kind) {
            .let => |l| {
                if (l.value) |v| {
                    const val = try self.emitExpr(&v);
                    if (!val.isVoid()) {
                        try self.out.print(
                            "  store {s} {s}, ptr {s}\n",
                            .{ val.ty, val.text, self.slots.items[l.slot] },
                        );
                    }
                }
            },
            .assign => |a| {
                const val = try self.emitExpr(&a.value);
                const dest = try self.placeAddress(&a.place);
                if (!val.isVoid()) {
                    try self.out.print("  store {s} {s}, ptr {s}\n", .{ val.ty, val.text, dest });
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
                    } else if (self.sret) |dest| {
                        // The value goes into the caller's buffer, and the
                        // function itself returns nothing.
                        try self.out.print("  store {s} {s}, ptr {s}\n", .{ val.ty, val.text, dest });
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

    /// The address of an assignable place: its slot, walked through any field
    /// selections with `getelementptr`.
    fn placeAddress(self: *Emitter, place: *const hir.Place) EmitError![]const u8 {
        var addr = self.slots.items[place.slot];
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
                const t = self.llType(e.ty) orelse {
                    try self.unsupported(e.span, "type of a binding");
                    return Value.void_value;
                };
                // A borrowed aggregate's slot holds the caller's ADDRESS, so
                // loading it gives a pointer, not the struct.
                if (slot < self.slot_ptr_to.items.len) {
                    if (self.slot_ptr_to.items[slot]) |pointee| {
                        const addr = try self.nextTemp();
                        try self.out.print("  {s} = load ptr, ptr {s}\n", .{ addr, self.slots.items[slot] });
                        return .{ .text = addr, .ty = "ptr", .ptr_to = pointee };
                    }
                }
                const tmp = try self.nextTemp();
                try self.out.print("  {s} = load {s}, ptr {s}\n", .{ tmp, t, self.slots.items[slot] });
                return .{ .text = tmp, .ty = t };
            },
            .binary => |b| return self.emitBinary(e, b.op, b.left, b.right),
            .unary => |u| return self.emitUnary(e, u.op, u.operand),
            .call => |c| return self.emitCall(e, c.symbol, c.args),
            .field => |f| {
                const base = try self.emitExpr(f.base);
                if (base.isVoid()) return base;
                const t = self.llType(f.sel.ty) orelse {
                    try self.unsupported(e.span, "field type");
                    return Value.void_value;
                };
                // Reading a field of a BORROWED aggregate goes through its
                // address, the way the C backend writes `b->len`. Using
                // extractvalue here would be an extract out of a pointer,
                // which is not valid IR.
                if (base.ptr_to) |pointee| {
                    const gep = try self.nextTemp();
                    try self.out.print(
                        "  {s} = getelementptr inbounds {s}, ptr {s}, i32 0, i32 {d}\n",
                        .{ gep, pointee, base.text, f.sel.index },
                    );
                    const loaded = try self.nextTemp();
                    try self.out.print("  {s} = load {s}, ptr {s}\n", .{ loaded, t, gep });
                    return .{ .text = loaded, .ty = t };
                }
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
        try self.out.print("  store i1 {s}, ptr {s}\n", .{ left.text, dest });

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
            try self.out.print("  store i1 {s}, ptr {s}\n", .{ right.text, dest });
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
            var v = try self.emitExpr(&a);
            if (v.isVoid()) return Value.void_value;
            // Place the argument the way the CALLEE's parameter is declared,
            // not the way the value happens to be computed.
            if (i < modes.len) {
                if (abi.renderParam(self.arena, self.module, a.ty, modes[i].param)) |want| {
                    // A borrowed struct is already an address here.
                    if (!(v.ptr_to != null and std.mem.eql(u8, want, "ptr"))) {
                        v = try self.coerceArg(v, want);
                    } else {
                        v = .{ .text = v.text, .ty = "ptr" };
                    }
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
        _ = self.module.findStruct(name) orelse {
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
            const tmp = try self.nextTemp();
            try self.out.print(
                "  {s} = insertvalue {s} {s}, {s} {s}, {d}\n",
                .{ tmp, ty, acc, v.ty, v.text, i },
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
            try self.out.print("  store {s} {s}, ptr {s}\n", .{ then_val.ty, then_val.text, dest });
        }
        if (!self.terminated) try self.out.print("  br label %{s}\n", .{end_label});

        if (else_e) |eb| {
            try self.out.print("{s}:\n", .{else_label});
            self.terminated = false;
            const else_val = try self.emitExpr(eb);
            if (produces_value and !else_val.isVoid()) {
                try self.out.print("  store {s} {s}, ptr {s}\n", .{ else_val.ty, else_val.text, dest });
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
                try self.out.print(
                    "  store {s} {s}, ptr {s}\n",
                    .{ scrutinee.ty, scrutinee.text, self.slots.items[slot] },
                );
            }
            const body_val = try self.emitExpr(arm.body);
            if (produces_value and !body_val.isVoid()) {
                try self.out.print("  store {s} {s}, ptr {s}\n", .{ body_val.ty, body_val.text, dest });
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
    // Matches what the C backend emits: `const cell_Buffer *b` and `b->len`.
    // An extractvalue here would be an extract out of a pointer, which is not
    // valid IR, so the field path has to change with the signature.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn read(shared b: Buffer) -> Int { return b.len }
    );
    defer e.deinit();
    try expectContains(e.text, "define i64 @cell_read(ptr");
    try expectContains(e.text, "getelementptr inbounds %cell_Buffer");
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
    try expectContains(e.text, "icmp eq i64");           // length first
    try expectContains(e.text, "icmp eq ptr");           // then the null guard
    try expectContains(e.text, "call i32 @memcmp(");     // only then memcmp
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
