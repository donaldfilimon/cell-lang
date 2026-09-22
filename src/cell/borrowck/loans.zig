//! Place reads and moves, loan creation, R3a revival, and loan conflicts
//! (R4, R5, R6).
//! Part of the borrow checker; the rules and their rationale are in the module header of `../borrowck.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const bk_model = @import("model.zig");
const bk_root = @import("../borrowck.zig");
const Checker = bk_root.Checker;
const Error = bk_model.Error;
const LoanKind = bk_model.LoanKind;
const Binding = bk_model.Binding;
const Place = bk_model.Place;
const Dead = bk_model.Dead;
const Loan = bk_model.Loan;
const pathPrefix = bk_model.pathPrefix;

// ── the four primitive operations on a place ────────────────────────

/// R2 and R5: reading a place that is dead, or that is exclusively
/// borrowed, is an error.
pub fn readPlace(self: *Checker, place: Place) Error!void {
    if (self.findDead(place)) |d| {
        try self.reportUseAfterMove(d, place.span);
        return;
    }
    if (try self.findBlockingLoan(place, .shared)) |loan| {
        if (loan.kind == .exclusive) {
            try self.diagnostics.err(
                self.allocator,
                place.span,
                try self.msg("cannot use '{s}' while it is exclusively borrowed", .{place.display}),
            );
            try self.noteLoanScope(loan);
        }
    }
}

/// R2, R3 and R6.
pub fn movePlace(self: *Checker, place: Place, note: []const u8) Error!void {
    const b = self.bindingById(place.binding).?;

    // R12 and R10: a `copy` place duplicates and an `arc` place retains,
    // so neither is made dead by a move position.
    if (self.isDuplicable(b, place.path)) {
        try self.readPlace(place);
        return;
    }

    if (self.findDead(place)) |d| {
        try self.reportUseAfterMove(d, place.span);
        return;
    }

    // R3: a borrow does not own its value, and neither does a field of one.
    if (b.ownership == .shared or b.ownership == .exclusive) {
        try self.diagnostics.err(
            self.allocator,
            place.span,
            try self.msg(
                "cannot move out of '{s}': it is {s} borrow, not an owner",
                .{ place.display, if (b.ownership == .exclusive) "an exclusive" else "a shared" },
            ),
        );
        return;
    }

    // R6: a live loan anywhere on the path blocks the move.
    if (try self.findBlockingLoan(place, .exclusive)) |loan| {
        const message = if (loan.path.len > place.path.len)
            try self.msg(
                "cannot move '{s}': its field '{s}' is borrowed",
                .{ place.display, loan.display },
            )
        else
            try self.msg("cannot move '{s}' while it is borrowed", .{place.display});
        try self.diagnostics.err(self.allocator, place.span, message);
        try self.noteLoanScope(loan);
        return;
    }

    try self.dead.append(self.allocator, .{
        .binding = place.binding,
        .path = place.path,
        .display = place.display,
        .span = place.span,
        .note = note,
    });
    // See the doc comment on `moved`: every real move is recorded here
    // too, and unlike `dead` this record is permanent for the binding's
    // whole function, surviving a later R3a revival.
    try self.moved.put(self.allocator, place.binding, {});
    try self.moved_paths.append(self.allocator, .{ .binding = place.binding, .path = place.path });
}

/// R4, R5 and R6. `lexical` selects the loan's scope: true for a loan
/// bound to a name, false for one that dies with its statement or `if`.
pub fn createLoan(
    self: *Checker,
    place: Place,
    kind: LoanKind,
    lexical: bool,
    holder: ?[]const u8,
) Error!void {
    if (self.findDead(place)) |d| {
        try self.reportUseAfterMove(d, place.span);
        return;
    }

    // R9, the exclusive-borrow half, and this is the ONE choke point every
    // exclusive loan passes through: `&mut s`, `exclusive s` as a call
    // argument, `grow(&mut s)`, `let exclusive e = &mut s` and
    // `let exclusive e = s` all arrive here. Enforcing it at each of those
    // sites instead is the enumeration this file has been caught by four
    // times; one gate is the point.
    //
    // What was measured before this, all at exit 0 from `cell check`:
    //
    //   let arc s = "x"           grow(exclusive s)
    //                             emitted `cell_grow(((cell_string_t *)s.ptr))`,
    //                             a mutable pointer INTO the shared box,
    //                             clean at `-Wall -Wextra -Werror`.
    //   let arc s = "x"           grow(&mut s)              same emit
    //   var arc s = "x"           let exclusive e = &mut s  accepted
    //   H { arc h: String }       grow(&mut b.h)
    //                             emitted `cell_grow(((cell_string_t *)&b.h.ptr))`,
    //                             a `cell_string_t *` aimed at the handle's
    //                             own pointer field. Silent.
    //
    // `docs/SPEC.md` 4.1.4 claimed mutation through `arc` was "not
    // permitted in this revision" while all four compiled, which is the
    // one direction of documentation error this repository cannot afford:
    // an overclaimed safety guarantee.
    //
    // A `shared` loan of an `arc` place stays legal, and deliberately so:
    // R10's table makes `arc` to a `shared` parameter a borrow of the
    // pointee with no retain, and R8 keeps it inside the block.
    if (kind == .exclusive) {
        if (try self.refuseArcShared(
            try self.arcReach(place, .whole),
            place,
            .borrow_exclusive,
        )) return;
    }

    if (try self.findBlockingLoan(place, kind)) |loan| {
        // R4: two shared loans of the same place are fine, and the only
        // pair `findConflictingLoan` lets through.
        try self.diagnostics.err(
            self.allocator,
            place.span,
            try self.msg(
                "cannot borrow '{s}' as {s}: it is already borrowed as {s}",
                .{ place.display, kind.word(), loan.kind.word() },
            ),
        );
        try self.noteLoanScope(loan);
        return;
    }

    const loan: Loan = .{
        .binding = place.binding,
        .path = place.path,
        .display = place.display,
        .kind = kind,
        .span = place.span,
        .holder = holder,
        .block_index = if (self.open_blocks.items.len == 0) 0 else self.open_blocks.items.len - 1,
        .stmt_index = if (self.open_blocks.items.len == 0)
            0
        else
            self.open_blocks.items[self.open_blocks.items.len - 1].index,
        .lexical = lexical,
    };
    if (lexical) {
        try self.block_loans.append(self.allocator, loan);
    } else {
        try self.temp_loans.append(self.allocator, loan);
    }
}

/// The innermost visible match-arm binding that aliases a place rooted
/// at `binding`, for R7's write clause. Every entry of `bindings` is in
/// scope (scopes shrink it on pop), so a plain scan is the visibility
/// test.
pub fn visibleArmAliasOf(self: *const Checker, binding: u32) ?*const Binding {
    var i = self.bindings.items.len;
    while (i > 0) {
        i -= 1;
        const b = &self.bindings.items[i];
        if (b.arm_origin != .alias) continue;
        if (b.arm_scrutinee_binding) |root| if (root == binding) return b;
    }
    return null;
}

/// R3a: assigning to a place revives it and everything under it.
/// A field revival also retracts matching `moved_paths` entries from
/// drop queries (`pathPrefix`, same as `dead`), so `fieldWasMoved`
/// returns false and the new value is released. A whole-binding
/// `path == ""` is left in place: assigning `p.a` must not look like
/// a whole move of `p` (that double-frees after `let owned q = p`).
/// A sibling path is not a prefix and is left in place.
pub fn revive(self: *Checker, place: Place) void {
    var revived_dead = false;
    var i: usize = 0;
    while (i < self.dead.items.len) {
        const d = self.dead.items[i];
        if (d.binding == place.binding and pathPrefix(place.path, d.path)) {
            _ = self.dead.swapRemove(i);
            revived_dead = true;
            continue;
        }
        i += 1;
    }
    if (!revived_dead) return;
    for (self.moved_paths.items) |*m| {
        if (m.binding != place.binding or m.path.len == 0) continue;
        if (pathPrefix(place.path, m.path)) m.revived = true;
    }
}

// ── queries ─────────────────────────────────────────────────────────

/// The dead place overlapping `place`, in either direction: reading
/// `buf.len` after `buf` moved is an error, and so is reading `buf` after
/// `buf.data` moved.
pub fn findDead(self: *const Checker, place: Place) ?Dead {
    for (self.dead.items) |d| {
        if (d.binding != place.binding) continue;
        if (pathPrefix(d.path, place.path) or pathPrefix(place.path, d.path)) return d;
    }
    return null;
}

/// A dead place that strictly contains `place`, used to tell a write into
/// a moved-out value from the revival of R3a.
pub fn deadStrictPrefixOf(self: *const Checker, place: Place) ?Dead {
    for (self.dead.items) |d| {
        if (d.binding != place.binding) continue;
        if (d.path.len < place.path.len and pathPrefix(d.path, place.path)) return d;
    }
    return null;
}

/// Whether `loan` conflicts with taking `kind` on `place`, ignoring
/// whether the loan is still live. Shared against shared never conflicts
/// (R4); everything else does. `findBlockingLoan` adds the liveness half.
pub fn loanConflicts(loan: Loan, place: Place, kind: LoanKind) bool {
    if (loan.binding != place.binding) return false;
    // R6: disjoint field paths never conflict.
    if (!pathPrefix(loan.path, place.path) and !pathPrefix(place.path, loan.path)) return false;
    if (loan.kind == .shared and kind == .shared) return false;
    return true;
}

// ── place construction ──────────────────────────────────────────────

/// The place an expression denotes, or null when it denotes no place (a
/// literal, a call result, an unknown identifier).
pub fn placeOf(self: *Checker, e: *const ast.Expr) Error!?Place {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(self.allocator);

    var cursor = e;
    while (true) {
        switch (cursor.kind) {
            .annotated => |a| {
                cursor = a.value;
            },
            .field => |f| {
                try segments.append(self.allocator, f.name);
                cursor = f.base;
            },
            .ident => |name| {
                const b = self.lookup(name) orelse return null;
                std.mem.reverse([]const u8, segments.items);
                const gpa = self.arena.allocator();
                const path = try std.mem.join(gpa, ".", segments.items);
                const display = if (path.len == 0)
                    name
                else
                    try std.fmt.allocPrint(gpa, "{s}.{s}", .{ name, path });
                return .{
                    .binding = b.id,
                    .path = path,
                    .display = display,
                    .span = e.span,
                };
            },
            else => return null,
        }
    }
}
