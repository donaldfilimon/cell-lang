//! Type lowering (`lowerType`, `applyOwnership`, `namedType`), type inference,
//! callee and declaration lookup, and the local table (`pushLocal`).
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
const Callee = cg_model.Callee;
const OptionalInst = cg_model.OptionalInst;
const eq = cg_helpers.eq;
const intrinsicSymbol = cg_helpers.intrinsicSymbol;
const optBaseForPayload = cg_helpers.optBaseForPayload;
const scalarSlug = cg_helpers.scalarSlug;
const listOptional = cg_helpers.listOptional;

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
pub fn baseType(self: *Generator, ty: *const ast.TypeExpr) Alloc!CType {
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

pub fn applyOwnership(self: *Generator, base: CType, own: ast.Ownership) Alloc!CType {
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

pub fn pointerTo(self: *Generator, base: CType, is_const: bool) Alloc!CType {
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

pub fn namedType(self: *Generator, n: []const u8) Alloc!CType {
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
pub fn resultSlug(self: *Generator, ty: *const ast.TypeExpr, is_ok: bool) Alloc!?[]const u8 {
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
pub fn optionalInstance(self: *Generator, inner: *const ast.TypeExpr) Alloc!OptionalInst {
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

pub fn inferExpr(self: *Generator, e: *const ast.Expr) Alloc!CType {
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
            const p = try self.arena.create(CType);
            p.* = cg_helpers.inferredListElem(try self.inferExpr(&items[0]));
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
pub fn resolveCallee(self: *Generator, callee: *const ast.Expr, argc: usize) Alloc!Callee {
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

pub fn findFn(self: *Generator, name: []const u8) ?ast.FnDef {
    for (self.module.items) |item| {
        switch (item.kind) {
            .fn_def => |f| if (eq(f.name, name)) return f,
            else => {},
        }
    }
    return null;
}

pub fn findStruct(self: *Generator, name: []const u8) ?ast.StructDef {
    for (self.module.items) |item| {
        switch (item.kind) {
            .struct_def => |s| if (eq(s.name, name)) return s,
            else => {},
        }
    }
    return null;
}

pub fn findEnum(self: *Generator, name: []const u8) ?ast.EnumDef {
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
pub fn enumVariantOf(self: *Generator, base: *const ast.Expr, field: []const u8) ?[]const u8 {
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
pub fn pushScratchLocal(self: *Generator, name: []const u8, ty: CType, ownership: ast.Ownership) Alloc!void {
    try self.locals.append(self.arena, .{
        .name = name,
        .ty = ty,
        .ownership = ownership,
        .id = 0,
        .droppable = false,
    });
}

pub fn lookupLocal(self: *Generator, name: []const u8) ?CType {
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
pub fn pushLocal(
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

pub fn nextTemp(self: *Generator) Alloc![]const u8 {
    const name = try std.fmt.allocPrint(self.arena, "_cell_t{d}", .{self.temp_counter});
    self.temp_counter += 1;
    return name;
}

pub fn writeIndent(self: *Generator, n: usize) EmitError!void {
    var i: usize = 0;
    while (i < n) : (i += 1) try self.writer.writeAll("  ");
}
