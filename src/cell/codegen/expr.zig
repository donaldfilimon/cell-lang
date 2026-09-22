//! Expression lowering: value expressions and value slots, operators, wraps,
//! calls, and struct and list literals.
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
const Dest = cg_model.Dest;
const Callee = cg_model.Callee;
const optBase = cg_helpers.optBase;
const optBaseForPayload = cg_helpers.optBaseForPayload;
const unwrapAnnotated = cg_helpers.unwrapAnnotated;
const resultBase = cg_helpers.resultBase;
const listReader = cg_helpers.listReader;
const endsInJump = cg_helpers.endsInJump;
const blockExit = cg_helpers.blockExit;
const collectIdents = cg_helpers.collectIdents;
const reachFromStmts = cg_helpers.reachFromStmts;

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
pub fn emitValueExpr(self: *Generator, e: *const ast.Expr, want: ?CType, indent: usize) EmitError!void {
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

/// The names a value block's tail can still reach once its value has
/// left the braces: every identifier the tail uses, plus, to a fixpoint,
/// every identifier used by a `let` that declares a reached name or by
/// an assignment into one, at any nesting depth inside the block. See
/// `emitValueBlockDrops` for why this is transitive.
pub fn tailReach(self: *Generator, stmts: []const ast.Stmt, tail: *const ast.Expr) Alloc!std.ArrayList([]const u8) {
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
pub fn emitValueInto(self: *Generator, e: *const ast.Expr, dest: Dest, indent: usize) EmitError!void {
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
pub fn emitBinary(self: *Generator, b: anytype, indent: usize) EmitError!void {
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
pub fn emitCond(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
    var c = e;
    while (c.kind == .annotated) c = c.kind.annotated.value;
    switch (c.kind) {
        .binary => |b| try self.emitBinary(b, indent),
        else => try self.emitExpr(e, indent),
    }
}

pub fn emitExpr(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
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
pub fn emitIndex(self: *Generator, ix: anytype, indent: usize) EmitError!void {
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
pub fn emitWrap(self: *Generator, wrap_e: *const ast.Expr, want: ?CType, indent: usize) EmitError!void {
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
pub fn emitUnary(self: *Generator, op: ast.UnaryOp, operand: *const ast.Expr, indent: usize) EmitError!void {
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
pub fn emitCall(self: *Generator, c: anytype, indent: usize) EmitError!void {
    try self.emitCallValued(c, indent, true);
}

/// `value_used` is false only from `emitDiscarded`, the two leaves
/// that emit an expression as a statement. See that function for why
/// the distinction has to exist.
pub fn emitCallValued(self: *Generator, c: anytype, indent: usize, value_used: bool) EmitError!void {
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
pub fn writeCallExpr(
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

pub fn emitStructLit(self: *Generator, sl: anytype, indent: usize) EmitError!void {
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
pub fn emitListLit(
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
    // The normalization is for the INFERRED path only. A declared type
    // that lowers to `void*` is this backend's deliberate "visible rather
    // than silently wrong", and quietly turning it into an int64 buffer
    // would be the opposite. `inferredListElem` also turns a string view
    // into the owning element the declared `[String]` path builds.
    const elem = want_elem orelse cg_helpers.inferredListElem(try self.inferExpr(&items[0]));
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
pub fn emitFloat(self: *Generator, v: f64) EmitError!void {
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
pub fn emitStringLiteral(self: *Generator, s: []const u8) EmitError!void {
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
