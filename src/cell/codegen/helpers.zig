//! Free AST helpers the C backend shares: pattern and arm queries, optional and
//! Result slugs, and the identifier-reach walks.
//! Part of the C backend; the rules and their rationale are in the module header of `../codegen.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const borrowck = @import("../borrowck.zig");
const Alloc = std.mem.Allocator.Error;
const cg_model = @import("model.zig");
const CType = cg_model.CType;

pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Runtime intrinsics whose C symbol is not `cell_<name>` for every arity.
/// `print`, `println`, and `panic` already land on their runtime names under
/// the normal mangling; `assert` does not, because C has no overloading and
/// the message-carrying form is a separate symbol.
pub fn intrinsicSymbol(name: []const u8, arity: usize) ?[]const u8 {
    if (eq(name, "assert")) return if (arity == 2) "cell_assert_msg" else "cell_assert";
    return null;
}

/// A pattern that matches everything, so it closes an if/else chain.
/// Whether an arm closes the chain. A pattern that matches everything only
/// does so when no guard can reject it.
/// Whether `emitMatch` will read its scrutinee temporary: some arm it
/// reaches (every arm up to and including the first unguarded default) is a
/// pattern test or a binding copy.
pub fn scrutineeTempRead(arms: []const ast.MatchArm) bool {
    for (arms) |arm| {
        if (arm.pattern.kind == .binding) return true;
        if (!isDefaultPattern(arm.pattern)) return true;
        if (isDefaultArm(arm)) return false;
    }
    return false;
}

pub fn isDefaultArm(arm: ast.MatchArm) bool {
    return arm.guard == null and isDefaultPattern(arm.pattern);
}

pub fn isDefaultPattern(p: ast.Pattern) bool {
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
/// The element type an UNANNOTATED list literal is built with, from the
/// type its first item infers to. The declared path (`let owned ss:
/// [String] = ...`) lowers `[String]` to an owning `cell_string_t` element
/// and converts each item; the inferred path used to take the item's own
/// type, so `let owned ss = ["ab", "c"]` (accepted by `cell check` as
/// `[String]`) allocated 16-byte `cell_str_t` views where a `shared
/// [String]` reader walks 24-byte owning elements. Measured: a host summing
/// `.len` printed 2256 (garbage) where the annotated twin printed 3000 per
/// 1000 calls. A string view therefore becomes the owning element here, so
/// both spellings build the same buffer; an unknown or unit item falls to
/// `int64_t`, which is what this always did.
pub fn inferredListElem(first: CType) CType {
    return switch (first.shape) {
        .unknown, .unit => CType.int64,
        .str => CType.string,
        else => first,
    };
}

pub fn optBase(ty: CType) []const u8 {
    std.debug.assert(ty.shape == .optional);
    return ty.text[0 .. ty.text.len - "_t".len];
}

/// The predefined `cell_opt_*` instance for a scalar C type, by spelling.
pub fn optBaseForPayload(t: CType) ?[]const u8 {
    const map = .{
        .{ "int64_t", "cell_opt_i64" },   .{ "uint64_t", "cell_opt_u64" },
        .{ "int8_t", "cell_opt_i8" },     .{ "int16_t", "cell_opt_i16" },
        .{ "int32_t", "cell_opt_i32" },   .{ "uint16_t", "cell_opt_u16" },
        .{ "uint32_t", "cell_opt_u32" },  .{ "double", "cell_opt_f64" },
        .{ "bool", "cell_opt_bool" },     .{ "uint8_t", "cell_opt_byte" },
        .{ "float", "cell_opt_Float32" }, .{ "cell_string_t", "cell_opt_string" },
    };
    inline for (map) |row| if (std.mem.eql(u8, t.text, row[0])) return row[1];
    return null;
}

pub fn unwrapAnnotated(e: *const ast.Expr) *const ast.Expr {
    var current = e;
    while (true) {
        switch (current.kind) {
            .annotated => |a| current = a.value,
            else => return current,
        }
    }
}

pub fn isPlace(e: *const ast.Expr) bool {
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
pub fn borrowOperand(e: *const ast.Expr) ?*const ast.Expr {
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
pub fn isNamedLoan(v: *const ast.Expr, own: ast.Ownership) bool {
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
pub fn unboxable(want: CType) bool {
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
pub fn endsInReturn(body: []const ast.Stmt) bool {
    if (body.len == 0) return false;
    return switch (body[body.len - 1].kind) {
        .return_stmt => true,
        else => false,
    };
}

/// The per-instantiation Result slug for a Cell scalar type name (cell_rt.h
/// ABI 2). Mirrors abi.resultMember; the parity test pins the two.
pub fn scalarSlug(n: []const u8) ?[]const u8 {
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
pub fn resultBase(t: CType) ?[]const u8 {
    if (!std.mem.startsWith(u8, t.text, "cell_res_")) return null;
    return t.text[0 .. t.text.len - 2];
}

/// An owning String? (sub-project 4, 2026-09-17).
pub fn isOwningOptional(t: CType) bool {
    return t.shape == .optional and std.mem.eql(u8, t.text, "cell_opt_string_t");
}

/// Whether a value of this aggregate type owns heap memory and is released
/// through per-module glue (`cell_drop_<stem>`).
pub fn hasOwningGlue(t: CType) bool {
    return isOwningResult(t) or isOwningOptional(t);
}

/// Whether a `match` releases its temporary scrutinee `inner` of type `ty`.
/// An owning Result or `String?` (fdf36ed), or an owned String a CALL
/// returned (2026-09-17): a call's declared return type lowers `owned`, so
/// the value has no other owner. A `str` view (a literal) owns nothing, and
/// other String-typed expressions (a block, an `if`) may name an existing
/// owner, so they keep the leak.
pub fn ownsTempScrutinee(inner: *const ast.Expr, ty: CType) bool {
    if (hasOwningGlue(ty)) return true;
    return inner.kind == .call and ty.shape == .string and !ty.pointer;
}

/// `res_i64_string` for `cell_res_i64_string_t`, `opt_string` for
/// `cell_opt_string_t`: the part after `cell_drop_`.
pub fn glueStem(t: CType) []const u8 {
    return t.text["cell_".len .. t.text.len - "_t".len];
}

/// A Result with an owning String side (sub-projects 2 and 3, 2026-09-17):
/// it owns heap memory and has per-module release glue.
pub fn isOwningResult(t: CType) bool {
    return resultOkOwning(t) or resultErrOwning(t);
}

pub fn resultOkOwning(t: CType) bool {
    return t.shape == .result and std.mem.startsWith(u8, t.text, "cell_res_string_");
}

pub fn resultErrOwning(t: CType) bool {
    return t.shape == .result and std.mem.startsWith(u8, t.text, "cell_res_") and
        std.mem.endsWith(u8, t.text, "_string_t");
}

/// The bounds-checked runtime reader for a list built with `elem`.
pub fn listReader(elem: ?*const CType) []const u8 {
    const e = elem orelse return "cell_index_of_unknown_element";
    if (eq(e.text, "uint8_t")) return "cell_bytes_at";
    if (eq(e.text, "int64_t")) return "cell_list_i64_at";
    if (eq(e.text, "int32_t")) return "cell_list_i32_at";
    if (eq(e.text, "double")) return "cell_list_f64_at";
    if (eq(e.text, "bool")) return "cell_list_bool_at";
    return "cell_index_of_unsupported_element";
}

/// The optional C type `listReader` returns for `elem_text`.
pub fn listOptional(elem_text: []const u8) ?[]const u8 {
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
pub fn armDiverges(e: *const ast.Expr) bool {
    const inner = unwrapAnnotated(e);
    return switch (inner.kind) {
        .block => |stmts| endsInJump(stmts),
        else => false,
    };
}

pub fn endsInJump(body: []const ast.Stmt) bool {
    if (body.len == 0) return false;
    return switch (body[body.len - 1].kind) {
        .return_stmt, .break_stmt, .continue_stmt => true,
        else => false,
    };
}

/// A drop point, spelled the way borrowck keyed it in `exit_liveness`.
pub const Exit = struct {
    kind: borrowck.ExitKind,
    key: usize,
};

pub const OwningTemp = struct {
    name: []const u8,
    ty: CType,
    loop_depth: usize,
    taken: bool = false,
};

pub const SkipLabel = struct {
    loop_key: usize,
    id: usize,
};

/// The fall-through end of `body`. Null for an empty block, which borrowck
/// does not record and which declares nothing to drop.
pub fn blockExit(body: []const ast.Stmt) ?Exit {
    if (body.len == 0) return null;
    return .{ .kind = .block_end, .key = @intFromPtr(body.ptr) };
}

/// Mirrors `borrowck.branchKeyOf`: a block body's statement slice, else
/// the expression itself.
pub fn branchKey(e: *const ast.Expr) usize {
    return switch (e.kind) {
        .block => |stmts| if (stmts.len > 0) @intFromPtr(stmts.ptr) else @intFromPtr(e),
        else => @intFromPtr(e),
    };
}

// ── use analysis, for the (void) casts that keep -Wextra quiet ───────────

pub fn exprUses(e: *const ast.Expr, name: []const u8) bool {
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

pub fn nameIn(set: []const []const u8, name: []const u8) bool {
    for (set) |n| if (eq(n, name)) return true;
    return false;
}

/// Adds every identifier `e` mentions to `set`; true when something new was
/// added. Nested statement lists are walked in full.
pub fn collectIdents(arena: std.mem.Allocator, e: *const ast.Expr, set: *std.ArrayList([]const u8)) Alloc!bool {
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

pub fn collectIdentsStmts(arena: std.mem.Allocator, stmts: []const ast.Stmt, set: *std.ArrayList([]const u8)) Alloc!bool {
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
pub fn reachFromStmts(arena: std.mem.Allocator, stmts: []const ast.Stmt, set: *std.ArrayList([]const u8)) Alloc!bool {
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

pub fn reachFromExpr(arena: std.mem.Allocator, e: *const ast.Expr, set: *std.ArrayList([]const u8)) Alloc!bool {
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
pub fn rootIdent(e: *const ast.Expr) ?[]const u8 {
    return switch (e.kind) {
        .ident => |n| n,
        .field => |f| rootIdent(f.base),
        .annotated => |a| rootIdent(a.value),
        .unary => |u| rootIdent(u.operand),
        else => null,
    };
}

pub fn stmtsUse(stmts: []const ast.Stmt, name: []const u8) bool {
    for (stmts, 0..) |_, i| {
        if (stmtUses(&stmts[i], name)) return true;
    }
    return false;
}

pub fn stmtUses(s: *const ast.Stmt, name: []const u8) bool {
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
pub fn targetReads(e: *const ast.Expr, name: []const u8) bool {
    return switch (e.kind) {
        .ident => false,
        .annotated => |a| targetReads(a.value, name),
        else => exprUses(e, name),
    };
}
