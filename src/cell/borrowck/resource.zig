//! Borrow sources, R8's escaping return, struct fields, and the resource-shape
//! classifier behind R2's list clause, R12's copy clause and owning fields.
//! Part of the borrow checker; the rules and their rationale are in the module header of `../borrowck.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const Span = ast.Span;
const Ownership = ast.Ownership;
const bk_arc = @import("arc.zig");
const bk_model = @import("model.zig");
const bk_root = @import("../borrowck.zig");
const Checker = bk_root.Checker;
const Error = bk_model.Error;
const LoanKind = bk_model.LoanKind;
const Binding = bk_model.Binding;
const Place = bk_model.Place;
const Dead = bk_model.Dead;
const typeIsBorrow = bk_model.typeIsBorrow;
const typeStructName = bk_model.typeStructName;
const findField = bk_model.findField;
const ArcSource = bk_arc.ArcSource;

/// Whether an expression yields a BORROW rather than a value. Total, with
/// `.unresolved` refused, for the same reason `ArcSource` is total: this
/// question is asked in a position where accepting the wrong answer leaves
/// a stale loan, and refusing only costs a program that can be spelled
/// with a fresh name.
pub const BorrowSource = union(enum) {
    /// Provably a value. Every arm returning this states why.
    not_borrow,
    borrow: ArcSource.Site,
    unresolved: ArcSource.Site,

    /// Any branch that yields a borrow makes the whole expression one,
    /// because any branch may be the one taken; otherwise `.unresolved`
    /// wins over `.not_borrow`, for the same reason.
    fn join(a: BorrowSource, b: BorrowSource) BorrowSource {
        return switch (a) {
            .borrow => a,
            .unresolved => switch (b) {
                .borrow => b,
                else => a,
            },
            .not_borrow => b,
        };
    }
};

/// Classify the right-hand side of an assignment into a binding that
/// already holds a borrow. See the call site in `checkAssign` for why the
/// question is asked at all.
///
/// The switch is exhaustive with no `else`, and exhaustive over the FIELDS
/// of each variant it descends into rather than only over the variants: a
/// `match` visits every arm, an `if` both branches, a `unary` splits on
/// its operator. Treating those as one claim is what hid a match guard
/// from `exprUsesName` in this same file.
pub fn borrowSource(self: *Checker, e: *const ast.Expr) Error!BorrowSource {
    return switch (e.kind) {
        // A literal is a fresh value with no referent behind it.
        .int, .float, .string, .bool => .not_borrow,
        // A struct or list literal constructs a fresh aggregate. Whether
        // one of its FIELDS holds a borrow is R8's question about escaping
        // borrows, not this one: the aggregate itself is a value.
        .struct_lit, .list_lit => .not_borrow,
        // Every binary operator in this grammar yields a fresh scalar.
        .binary => .not_borrow,
        .unary => |u| switch (u.op) {
            .neg, .not => .not_borrow,
            .ref_shared, .ref_exclusive => .{ .borrow = .{
                .display = if (try self.placeOf(u.operand)) |p|
                    try self.msg("a borrow of '{s}'", .{p.display})
                else
                    "a borrow",
                .span = e.span,
            } },
        },
        // A written `shared`/`exclusive` prefix says the argument is a
        // borrow outright (R15's spelling). Any other prefix is peeled.
        .annotated => |a| switch (a.ownership) {
            .shared, .exclusive => .{ .borrow = .{
                .display = if (try self.placeOf(a.value)) |p|
                    try self.msg("a borrow of '{s}'", .{p.display})
                else
                    "a borrow",
                .span = e.span,
            } },
            .owned, .arc, .copy => try self.borrowSource(a.value),
        },
        .ident, .field => blk: {
            const place = try self.placeOf(e) orelse {
                // Not rooted at a binding in scope. A qualified enum
                // variant is a unit constant and can never be a borrow;
                // anything else is a field of a temporary, unresolved.
                if (e.kind == .field and e.kind.field.base.kind == .ident and
                    self.enums.contains(e.kind.field.base.kind.ident)) break :blk .not_borrow;
                break :blk .{ .unresolved = .{
                    .display = try self.msg("the expression at this position", .{}),
                    .span = e.span,
                } };
            };
            const b = self.bindingById(place.binding) orelse break :blk .{ .unresolved = .{
                .display = try self.msg("the place '{s}'", .{place.display}),
                .span = e.span,
            } };
            const own = self.placeOwnership(b, place.path) orelse break :blk .{ .unresolved = .{
                .display = try self.msg("the place '{s}'", .{place.display}),
                .span = e.span,
            } };
            break :blk switch (own) {
                .shared, .exclusive => .{ .borrow = .{
                    .display = try self.msg("the borrow '{s}'", .{place.display}),
                    .span = e.span,
                } },
                .owned, .arc, .copy => .not_borrow,
            };
        },
        .call => |c| blk: {
            const name: []const u8 = switch (c.callee.kind) {
                .ident => |n| n,
                else => break :blk .{ .unresolved = .{
                    .display = "the result of an indirect call",
                    .span = e.span,
                } },
            };
            const sig = self.fns.get(name) orelse break :blk .{ .unresolved = .{
                .display = try self.msg("the result of the unresolved callee '{s}'", .{name}),
                .span = e.span,
            } };
            // No declared return type is unit, which is not a borrow.
            const rt = sig.return_type orelse break :blk .not_borrow;
            break :blk if (typeIsBorrow(&rt) != null) .{ .borrow = .{
                .display = try self.msg("the borrow returned by '{s}'", .{name}),
                .span = e.span,
            } } else .not_borrow;
        },
        .if_expr => |i| blk: {
            const then_v = try self.borrowSource(i.then_body);
            // A missing `else` yields unit on that path.
            const else_v: BorrowSource = if (i.else_body) |eb|
                try self.borrowSource(eb)
            else
                .not_borrow;
            break :blk BorrowSource.join(then_v, else_v);
        },
        .match_expr => |m| blk: {
            var acc: BorrowSource = .not_borrow;
            for (m.arms) |arm| {
                acc = BorrowSource.join(acc, try self.borrowSource(arm.body));
            }
            break :blk acc;
        },
        // A block's value is its trailing expression statement.
        .block => |stmts| blk: {
            if (stmts.len == 0) break :blk .not_borrow;
            const last = &stmts[stmts.len - 1];
            if (last.kind != .expr) break :blk .not_borrow;
            break :blk try self.borrowSource(&last.kind.expr);
        },
        // A fresh value, never a place, never a borrow.
        .wrap => .not_borrow,
        .index => .not_borrow,
    };
}

/// Whether this binding holds a borrow, asked two ways because neither
/// alone is enough.
///
/// The declared annotation catches `var exclusive e = &mut a`. The holder
/// scan catches a binding whose annotation is not a borrow but which
/// `checkLetInit` still turned into a named loan, because that branch
/// creates one whenever the initializer is a `&` form REGARDLESS of the
/// annotation, so reading the annotation alone would be exactly the
/// enumeration this file has been caught by before.
///
/// The witness used to be `var owned e = &mut a`, which R18 now refuses at
/// the `let` itself, so no loan is created for it and the holder scan can
/// no longer see one. `var copy c = &mut a` and `var arc c = &mut a` still
/// reach the loan branch, so the scan is still load-bearing rather than
/// dead; the test below moved onto the `copy` spelling for that reason.
///
/// The scan is by NAME, which the loan record is keyed on, so a shadowed
/// name can match a loan that is not this binding's. That direction is
/// safe: it can only refuse an assignment, never permit one.
pub fn holdsBorrow(self: *const Checker, b: *const Binding) bool {
    if (b.ownership == .shared or b.ownership == .exclusive) return true;
    for (self.block_loans.items) |loan| {
        const holder = loan.holder orelse continue;
        if (std.mem.eql(u8, holder, b.name)) return true;
    }
    return false;
}

/// R12 and R10's exemptions, which R2 depends on: a `copy` place is
/// duplicated and an `arc` place is retained, so neither dies.
pub fn isDuplicable(self: *const Checker, b: *const Binding, path: []const u8) bool {
    const own = self.placeOwnership(b, path) orelse return false;
    return own == .copy or own == .arc;
}

/// The declared annotation of a place: the binding's own for an empty
/// path, otherwise the last field's, resolved through the struct table.
/// Null when it cannot be resolved, which is treated conservatively.
pub fn placeOwnership(self: *const Checker, b: *const Binding, path: []const u8) ?Ownership {
    if (path.len == 0) return b.ownership;
    var current: ?[]const u8 = b.struct_name;
    var result: ?Ownership = null;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |segment| {
        const struct_name = current orelse return null;
        const def = self.structs.get(struct_name) orelse return null;
        const field = findField(def, segment) orelse return null;
        result = field.ownership;
        current = typeStructName(&field.ty);
    }
    return result;
}

/// The struct type a place has, which is what `placeOwnership` needs one
/// level down. Used to carry a referent's type across a borrow in
/// `checkLet`, so that `let exclusive e = &mut buf` knows `e` names a
/// `Buffer` and `&mut e.len` can be classified rather than refused.
pub fn placeStructName(self: *const Checker, b: *const Binding, path: []const u8) ?[]const u8 {
    if (path.len == 0) return b.struct_name;
    var current: ?[]const u8 = b.struct_name;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |segment| {
        const struct_name = current orelse return null;
        const def = self.structs.get(struct_name) orelse return null;
        const field = findField(def, segment) orelse return null;
        current = typeStructName(&field.ty);
    }
    return current;
}

// ── diagnostics helpers ─────────────────────────────────────────────

pub fn reportEscapingReturn(self: *Checker, at: Span, kind: LoanKind) Error!void {
    try self.diagnostics.err(
        self.allocator,
        at,
        try self.msg(
            "cannot return {s} {s} borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call",
            .{ if (kind == .exclusive) "an" else "a", kind.word() },
        ),
    );
    try self.diagnostics.note(
        self.allocator,
        at,
        "return an 'owned' or 'arc' value instead",
    );
}

pub fn checkStructFields(self: *Checker, span: Span, s: ast.StructDef) Error!void {
    for (s.fields) |f| {
        const from_ann: ?LoanKind = switch (f.ownership) {
            .shared => .shared,
            .exclusive => .exclusive,
            else => null,
        };
        const kind = from_ann orelse typeIsBorrow(&f.ty);
        if (kind) |k| {
            try self.diagnostics.err(
                self.allocator,
                span,
                try self.msg(
                    "cannot store a {s} borrow in field '{s}': Cell has no lifetime annotations, so the borrow cannot be proven to outlive the value",
                    .{ k.word(), f.name },
                ),
            );
            try self.diagnostics.note(
                self.allocator,
                span,
                "store an 'owned' or 'arc' value instead",
            );
            continue;
        }
        if (f.ownership == .copy) {
            switch (try self.fieldResourceShape(&f)) {
                .no_resources => {},
                .resources, .unknown => {
                    try self.diagnostics.err(
                        self.allocator,
                        span,
                        try self.msg(
                            "cannot declare copy field '{s}': its type may own resources and copying its header would create two owners",
                            .{f.name},
                        ),
                    );
                    try self.diagnostics.note(
                        self.allocator,
                        span,
                        "use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported",
                    );
                },
            }
        }
    }
}

pub const ResourceShape = enum { no_resources, resources, unknown };

/// Whether an ownership keyword can change how a declared type is
/// represented. This mirrors codegen's `applyOwnership`, whose first line
/// is `if (base.shape.isPrimitive()) return base;` and whose `.arc` arm is
/// otherwise `CType.arc`. The two are one rule written in two files, so a
/// change to `Shape.isPrimitive` belongs here as well.
pub const Representation = enum { primitive, aggregate, unknown };

pub fn representationOf(self: *Checker, ty: *const ast.TypeExpr) Error!Representation {
    return switch (ty.*) {
        .unit => .primitive,
        .list, .optional, .result => .aggregate,
        // A written ownership keyword does not change what the type under
        // it IS, only how this position holds it, so ask the payload.
        .ref => |ref| try self.representationOf(ref.inner),
        .name => |name| blk: {
            if (types.fromPrimitiveName(name)) |primitive| {
                break :blk if (primitive == .string) .aggregate else .primitive;
            }
            if (self.enums.contains(name)) break :blk .primitive;
            if (self.structs.contains(name)) break :blk .aggregate;
            break :blk .unknown;
        },
    };
}

pub fn resourceShape(self: *Checker, ty: *const ast.TypeExpr) Error!ResourceShape {
    // `.owned` is the neutral answer: it is the one keyword that never
    // changes representation, so this asks the type's own shape.
    return self.resourceShapeOwned(ty, .owned);
}

/// The shape of a declared struct field, which is the type AND the keyword
/// written in front of it. Reading only the type is what let a boxed
/// scalar-only record hide inside a `copy` field.
pub fn fieldResourceShape(self: *Checker, field: *const ast.Field) Error!ResourceShape {
    return self.resourceShapeOwned(&field.ty, field.ownership);
}

pub const PlaceType = struct { ty: ast.TypeExpr, ownership: Ownership };

/// The type a place carries, when it resolved. An empty path answers with
/// the binding's own inferred type; a non-empty one walks the struct table
/// exactly as `placeOwnership` does and answers with the last field's
/// declared type AND keyword, because `shared [Byte]` and `owned [Byte]`
/// lower to the same `cell_slice_t` and only the keyword tells them apart.
pub fn placeTypeOf(self: *const Checker, b: *const Binding, path: []const u8) ?PlaceType {
    if (path.len == 0) {
        const t = b.ty orelse return null;
        return .{ .ty = t, .ownership = b.ownership };
    }
    var current: ?[]const u8 = b.struct_name;
    var result: ?PlaceType = null;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |segment| {
        const struct_name = current orelse return null;
        const def = self.structs.get(struct_name) orelse return null;
        const field = findField(def, segment) orelse return null;
        result = .{ .ty = field.ty, .ownership = field.ownership };
        current = typeStructName(&field.ty);
    }
    return result;
}

/// The resource shape of a place. Null means its type could not be
/// resolved, which every caller discloses rather than refuses: this
/// predicate gates REFUSALS, so an unresolved answer must not invent one.
pub fn placeResourceShape(self: *Checker, b: *const Binding, path: []const u8) Error!?ResourceShape {
    const t = self.placeTypeOf(b, path) orelse return null;
    return try self.resourceShapeOwned(&t.ty, t.ownership);
}

/// The type of a `let` initializer, for `Binding.ty`. Only shapes whose
/// type is readable WITHOUT a typechecker are answered; everything else is
/// null. Kept separate from the `struct_name` inference in `checkLet` on
/// purpose (see `Binding.ty`): widening this cannot move an R9 or R10
/// verdict, and widening that one can.
pub fn inferBindingType(self: *Checker, e: *const ast.Expr) Error!?ast.TypeExpr {
    switch (e.kind) {
        .annotated => |a| return try self.inferBindingType(a.value),
        .int => return .{ .name = "Int" },
        .float => return .{ .name = "Float" },
        .string => return .{ .name = "String" },
        .bool => return .{ .name = "Bool" },
        .struct_lit => |sl| return .{ .name = sl.name },
        .call => |c| {
            if (c.callee.kind != .ident) return null;
            const sig = self.fns.get(c.callee.kind.ident) orelse return null;
            return sig.return_type;
        },
        // A borrow's binding is not an owner, but what a `copy` of it
        // duplicates is the REFERENT's header, so answer with that.
        .unary => |u| switch (u.op) {
            .ref_shared, .ref_exclusive => return try self.inferBindingType(u.operand),
            .neg, .not => return null,
        },
        .ident, .field => {
            const place = (try self.placeOf(e)) orelse return null;
            const b = self.bindingById(place.binding) orelse return null;
            const t = self.placeTypeOf(b, place.path) orelse return null;
            return t.ty;
        },
        // An arm body that IS the arm's binding pattern hands back the
        // scrutinee, so the `let` has the scrutinee's type. Resolved by
        // shape rather than by declaring the pattern name, because that
        // name is not in scope at this point and `declare` here would
        // disturb the binding ids that `codegen.zig` agrees with.
        //
        // Narrow on purpose. It exists because codegen's own inference
        // had the same hole: `match s { x => x }` inferred nothing, the
        // temporary fell back to `int64_t`, and `cc` rejected the module.
        // Fixing only that side would have been worse than leaving both
        // broken -- the `cc` error was the sole thing stopping
        // `let copy c = match s { x => x }` over a `String`, and once the
        // C compiled, R12 would have waved through exactly the two
        // headers over one buffer it exists to refuse. Both sides move
        // together or neither does.
        .match_expr => |m| {
            if (m.arms.len == 0) return null;
            const arm = m.arms[0];
            if (arm.pattern.kind == .binding and arm.body.kind == .ident and
                std.mem.eql(u8, arm.body.kind.ident, arm.pattern.kind.binding))
            {
                return try self.inferBindingType(m.scrutinee);
            }
            return try self.inferBindingType(arm.body);
        },
        else => return null,
    }
}

/// R12's duplication clause, at the binding and parameter positions.
///
/// A `copy` place is bitwise-duplicated and never retained, so when its
/// type owns resources the duplicate is a second header over one buffer.
/// Struct FIELDS have refused this since `checkStructFields`; bindings and
/// parameters did not, and three routes reached it, all measured accepted
/// and all emitting a plain `cell_Box x = y;`: `let copy snap = buf`,
/// `let copy snap = v` through an exclusive borrow, and `fn f(copy b: Box)`.
/// They were harmless only while a `record` was never dropped. R11 row 2's
/// drop glue is exactly what turns each of them into a double free, so the
/// refusal lands ahead of it rather than after.
///
/// A null type is still PERMITTED rather than refused, and that policy is
/// unchanged; what changed is how rarely it is reached. The example this
/// comment used to give, `let copy c = s` over a bare `String` binding
/// declared without a type, is REFUSED today and was already refused when
/// this was written: `inferBindingType` resolves a call initializer from
/// the signature table and an ident from the source binding, so `s` has a
/// type and so does `c`. Measured 2026-09-16 across four shapes, all
/// refused: call initializer, binding-to-binding with and without an
/// annotation, `copy` of a `shared` parameter, and a struct field.
///
/// The route that really was open was a match: `let copy c = match s { x
/// => x }` resolved nothing, because there was no `.match_expr` arm at
/// all. There is one now, deliberately narrow. Whatever remains null is
/// permitted and disclosed in `docs/OWNERSHIP.md` R12; do not read that
/// as "nothing downstream will catch it", because for the match route
/// nothing did.
pub fn refuseResourceCopy(
    self: *Checker,
    at: Span,
    what: []const u8,
    name: []const u8,
    ty: ?ast.TypeExpr,
) Error!void {
    const t = ty orelse return;
    switch (try self.resourceShapeOwned(&t, .copy)) {
        .no_resources => return,
        .resources, .unknown => {},
    }
    try self.diagnostics.err(
        self.allocator,
        at,
        try self.msg(
            "cannot declare copy {s} '{s}': its type may own resources and copying its header would create two owners",
            .{ what, name },
        ),
    );
    try self.diagnostics.note(
        self.allocator,
        at,
        "use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported",
    );
}

/// The list-element position's R2 refusal.
///
/// `[s]` copies the element's header into the list's buffer and leaves the
/// source binding live, so the source is released at its scope end while
/// the list still holds the freed pointer. The site's own comment used to
/// argue this was safe "because slice elements are never released"; that
/// is the wrong half of the mechanism. Measured at `76128ba` with
/// AddressSanitizer: `fn mks() -> [String] { let owned s = make(); return
/// [s] }` read by the caller reports `heap-use-after-free`, freed by
/// `cell_string_free` on the SOURCE. It is a live defect today for
/// `String`, independent of R11 row 2, and row 2's drop glue would extend
/// the identical shape to every record.
pub fn refuseListElementMove(self: *Checker, p: Place) Error!void {
    try self.diagnostics.err(
        self.allocator,
        p.span,
        try self.msg(
            "cannot store '{s}' in an 'owned' list element: a list literal copies the element's header by value and the source keeps its own",
            .{p.display},
        ),
    );
    try self.diagnostics.note(
        self.allocator,
        p.span,
        "the source is released at its scope end while the list still holds the same buffer; build the element from a fresh value instead",
    );
}

pub fn resourceShapeOwned(
    self: *Checker,
    ty: *const ast.TypeExpr,
    own: ast.Ownership,
) Error!ResourceShape {
    var visiting: std.StringHashMapUnmanaged(void) = .empty;
    defer visiting.deinit(self.allocator);
    return self.resourceShapeInner(ty, own, &visiting);
}

pub fn resourceShapeInner(
    self: *Checker,
    ty: *const ast.TypeExpr,
    own: ast.Ownership,
    visiting: *std.StringHashMapUnmanaged(void),
) Error!ResourceShape {
    // An `arc` over a non-primitive payload is a `cell_arc_t` handle, and
    // a handle is a resource however scalar the thing it points at: the
    // header carries a refcount, so duplicating it makes a second owner
    // that never retained. `arc Point` emits `cell_arc_t point;` while
    // `arc Int` emits `int64_t n;` (both measured), which is why this
    // cannot be "every `arc` is a resource" -- that would reject
    // primitive ARC, which the language keeps by value on purpose.
    if (own == .arc) {
        switch (try self.representationOf(ty)) {
            .primitive => {},
            .aggregate => return .resources,
            .unknown => return .unknown,
        }
    }
    return switch (ty.*) {
        .unit => .no_resources,
        .list => .resources,
        .optional => |inner| try self.resourceShapeInner(inner, own, visiting),
        .result => |result| combineResourceShapes(
            try self.resourceShapeInner(result.ok, own, visiting),
            try self.resourceShapeInner(result.err, own, visiting),
        ),
        // A `.ref` carries its OWN keyword, which is how the qualified
        // spelling `copy point: arc Point` writes the same box that
        // `arc point: Point` does. Hand the inner type that keyword, not
        // the one from the enclosing position.
        .ref => |ref| try self.resourceShapeInner(ref.inner, ref.ownership, visiting),
        .name => |name| blk: {
            if (types.fromPrimitiveName(name)) |primitive| {
                break :blk if (primitive == .string) .resources else .no_resources;
            }
            if (self.enums.contains(name)) break :blk .no_resources;
            const def = self.structs.get(name) orelse break :blk .unknown;
            if (visiting.contains(name)) break :blk .unknown;
            try visiting.put(self.allocator, name, {});
            defer _ = visiting.remove(name);
            var shape: ResourceShape = .no_resources;
            for (def.fields) |field| {
                shape = combineResourceShapes(
                    shape,
                    // Each field's own keyword, so a nested `arc` record
                    // is seen through an outer `copy`.
                    try self.resourceShapeInner(&field.ty, field.ownership, visiting),
                );
            }
            break :blk shape;
        },
    };
}

pub fn combineResourceShapes(a: ResourceShape, b: ResourceShape) ResourceShape {
    if (a == .resources or b == .resources) return .resources;
    if (a == .unknown or b == .unknown) return .unknown;
    return .no_resources;
}

pub fn refuseOwnedFieldTransfer(
    self: *Checker,
    source: ArcSource.Site,
    field_name: []const u8,
    reason: []const u8,
) Error!void {
    try self.diagnostics.err(
        self.allocator,
        source.span,
        try self.msg(
            "cannot store {s} in owned field '{s}': {s}",
            .{ source.display, field_name, reason },
        ),
    );
    try self.diagnostics.note(
        self.allocator,
        source.span,
        "aggregate ownership transfer is not implemented; construct a fresh field value instead",
    );
}

pub fn reportUseAfterMove(self: *Checker, d: Dead, at: Span) Error!void {
    try self.diagnostics.err(
        self.allocator,
        at,
        try self.msg("use of '{s}' after it was moved", .{d.display}),
    );
    try self.diagnostics.note(self.allocator, d.span, d.note);
}
