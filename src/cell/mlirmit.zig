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
    /// Slot -> pointee type, when the slot holds an ADDRESS. Borrowed
    /// aggregate parameters only: an `exclusive` borrow has to write through
    /// to the caller's object.
    slot_ptr_to: std.ArrayList(?[]const u8) = .empty,
    /// String literals become llvm.mlir.global constants, emitted at module
    /// scope once the bodies that reference them are known.
    strings: std.ArrayList(StringGlobal) = .empty,

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
            try self.out.print("  func.func private @{s}(", .{f.symbol});
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
            if (ret) |r| try self.out.print(" -> {s}", .{r});
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

        try self.out.print("  func.func @{s}(", .{f.symbol});
        for (f.params(), 0..) |p, i| {
            if (i != 0) try self.out.writeAll(", ");
            const t = self.paramType(p.ty, p.ownership) orelse {
                try self.unsupported(f.span, "parameter type");
                return;
            };
            try self.out.print("%arg{d}: {s}", .{ i, t });
        }
        try self.out.writeAll(")");
        if (ret) |r| try self.out.print(" -> {s}", .{r});
        try self.out.writeAll(" {\n");
        self.indent = 4;

        for (f.bindings, 0..) |b, i| {
            const is_ref = i < f.param_count and b.ty.tag() == .struct_type and
                (b.ownership == .shared or b.ownership == .exclusive);
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
                // Keep the caller's ADDRESS: an `exclusive` borrow must write
                // through to the caller's object, and copying would drop every
                // mutation.
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
            if (ret) |r| {
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
            .let => |l| {
                if (l.value) |v| {
                    const val = try self.emitExpr(&v);
                    if (val.isNone()) return;
                    try self.storeSlot(l.slot, val.ty, val.text);
                }
            },
            .assign => |a| {
                const val = try self.emitExpr(&a.value);
                if (val.isNone()) return;
                if (a.place.path.len != 0) {
                    try self.unsupported(stmt.span, "assignment through a field path");
                    return;
                }
                try self.storeSlot(a.place.slot, val.ty, val.text);
            },
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
            .list_lit => {
                try self.unsupported(e.span, "[T] is not lowered to MLIR yet");
                return Value.none;
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
        for (args, 0..) |a, i| {
            vals[i] = try self.emitExpr(&a);
            if (vals[i].isNone()) return Value.none;
        }

        const ret = self.mlirType(e.ty);
        var result: []const u8 = "";
        if (ret != null) {
            result = try self.nextSsa();
            try self.linePrefix();
            try self.out.print("{s} = ", .{result});
        } else {
            try self.linePrefix();
        }
        try self.out.print("call @{s}(", .{sym});
        for (vals, 0..) |v, i| {
            if (i != 0) try self.out.writeAll(", ");
            try self.out.writeAll(v.text);
        }
        try self.out.writeAll(") : (");
        for (vals, 0..) |v, i| {
            if (i != 0) try self.out.writeAll(", ");
            try self.out.writeAll(v.ty);
        }
        try self.out.writeAll(") -> ");
        if (ret) |r| try self.out.writeAll(r) else try self.out.writeAll("()");
        try self.out.writeAll("\n");

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
                const cmp = try self.nextSsa();
                try self.line("{s} = arith.cmpi eq, {s}, {s} : {s}", .{
                    cmp, scrutinee.text, konst, scrutinee.ty,
                });
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
            .struct_type, .string, .optional => true,
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
            .list, .result, .func, .unknown => null,
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
            const t = self.mlirType(f.ty) orelse return null;
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

test "[T] is still refused, because it has no representation at all" {
    // SPEC 3.3: [T] has no representation, not merely no MLIR placement.
    var e = try emitSource(
        \\pub fn f(shared xs: [Byte]) -> Int;
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
    const io = std.testing.io;

    const mlir_opt = (try findTool(gpa, "mlir-opt")) orelse return error.SkipZigTest;
    defer gpa.free(mlir_opt);
    const mlir_translate = (try findTool(gpa, "mlir-translate")) orelse return error.SkipZigTest;
    defer gpa.free(mlir_translate);
    const llc = (try findTool(gpa, "llc")) orelse return error.SkipZigTest;
    defer gpa.free(llc);

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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.mlir", .data = e.text });
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
        std.debug.print("mlir-opt rejected emitted MLIR:\n{s}\n--- mlir ---\n{s}\n", .{ lowered.stderr, e.text });
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
    defer gpa.free(run.stdout);
    if (!run.term.success()) return error.ProgramFailed;
    // The C backend prints 24 for this same source. Three backends, one answer.
    try std.testing.expectEqualStrings("24\n", run.stdout);
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

test "an unused struct with an unrepresentable field is still refused" {
    // MLIR renders !llvm.struct structurally at each USE, so an unused struct
    // was never examined and this module was accepted here while the LLVM
    // backend refused it. Two backends disagreeing about one program is the
    // drift a shared IR exists to prevent, so declared structs are validated
    // eagerly.
    var e = try emitSource(
        \\pub struct Holder { owned data: [Byte] }
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
