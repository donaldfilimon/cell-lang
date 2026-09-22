//! Borrow checker data model: loans, bindings, places, exit liveness, and the
//! small free helpers every rule family shares.
//! Part of the borrow checker; the rules and their rationale are in the module header of `../borrowck.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const Span = ast.Span;
const Ownership = ast.Ownership;

pub const Error = error{OutOfMemory};

/// Returned by `check` when the module has at least one borrow error.
pub const BorrowError = error{BorrowError};

/// How a loan reads the place it points at.
pub const LoanKind = enum {
    shared,
    exclusive,

    pub fn word(self: LoanKind) []const u8 {
        return switch (self) {
            .shared => "shared",
            .exclusive => "exclusive",
        };
    }
};

/// Whether a binding was introduced by a match arm pattern, and if so whether
/// anything ELSE still owns the value it names. R7 does not move the
/// scrutinee, so an arm binding is an ALIAS of it rather than a new owner, and
/// that is the whole of the R7 gap: `match s1 { x => take(owned x) }` moved
/// `x`, left `s1` live, and both headers held one buffer.
///
/// Three states rather than a bool, because the answer is not "is this an arm
/// binding" but "does something else still own this". A scrutinee that is not
/// a place (a call result, a literal, a fresh aggregate) has no other owner,
/// so a binding derived from it is as consumable as any temporary, and
/// `match make() { x => take(owned x) }` must keep lowering and running.
///
/// `.temp` does NOT propagate to a nested match's arm binding. See
/// `checkMatch`: the version that propagated left two live handles on one
/// temporary and a measured exit-134 double free that R2 cannot see, because
/// the two handles are two different bindings.
pub const ArmOrigin = enum {
    /// A parameter or a `let`/`var`. Not an arm binding.
    not_an_arm,
    /// An arm binding over a scrutinee with no place behind it. Nothing else
    /// owns the value, so consuming it is a move of a temporary.
    temp,
    /// An arm binding over a scrutinee that IS a place. Consuming it gives up
    /// a buffer the scrutinee's own drop will free again.
    alias,
};

/// A binding introduced by a parameter, a `let`/`var`, or a match arm pattern.
pub const Binding = struct {
    id: u32,
    name: []const u8,
    /// The declared annotation. `owned` when none was written (R1).
    ownership: Ownership,
    /// Whether the binding itself may be reassigned (R14).
    mutable: bool,
    /// Struct type name, when it could be resolved from the declaration or the
    /// initializing struct literal. Needed to read field annotations.
    struct_name: ?[]const u8,
    /// The declared or inferred TYPE, when one could be resolved. Read only by
    /// the resource-shape refusals (`checkCopyBinding`, the list-element site),
    /// and deliberately kept separate from `struct_name`: that field feeds R9
    /// and R10's total verdicts, so widening its inference would move those
    /// answers, while widening this one cannot. Null means "unresolved", which
    /// every reader treats as permit-and-disclose rather than refuse.
    ty: ?ast.TypeExpr = null,
    decl_span: Span,
    /// R7. Defaults to `.not_an_arm` so the two non-arm `declare` sites are
    /// unchanged; only `checkMatch` ever sets it.
    arm_origin: ArmOrigin = .not_an_arm,
    /// The scrutinee place this arm binding aliases, for the diagnostic.
    /// Arena-allocated by `placeOf` (or a slice of the source), so it outlives
    /// the match. Only meaningful when `arm_origin == .alias`.
    arm_scrutinee: ?[]const u8 = null,
    /// The binding the aliased scrutinee place is rooted at, for R7's write
    /// clause (`checkAssign`). Only meaningful when `arm_origin == .alias`.
    arm_scrutinee_binding: ?u32 = null,
};

/// A place: a binding plus a field path relative to it.
pub const Place = struct {
    binding: u32,
    /// `""` for the binding itself, `"len"` for `buf.len`.
    path: []const u8,
    /// `buf` or `buf.len`, for diagnostics.
    display: []const u8,
    span: Span,
};

/// One place `movePlace` moved, kept for the checker's whole life. See
/// `Checker.moved_paths`.
pub const MovedPath = struct {
    binding: u32,
    /// `""` when the binding itself moved, a dotted field path otherwise.
    path: []const u8,
    /// Set by R3a field revival. `fieldWasMoved` skips a revived path so
    /// the new value is released; the slot stays so `loop_moved`'s length
    /// snapshots still see the binding. A whole-binding `path == ""` is
    /// never marked: assigning a field must not look like a whole move.
    revived: bool = false,
};

/// See `Checker.assign_liveness`.
pub const AssignLiveness = struct {
    /// Address of the target identifier's name bytes: a stable, unique key
    /// per assignment site that codegen can compute from its own copy of the
    /// statement, because the name slice points into the source buffer.
    key: usize,
    binding: u32,
    live: bool,
};

/// The scope exits `Checker.exit_liveness` records. A codegen drop point
/// names one of them together with the same key the checker used.
pub const ExitKind = enum {
    /// The fall-through end of a block's statement list, keyed by the
    /// address of its first statement. A function body is one of these.
    block_end,
    /// A `return` statement, keyed by the statement's address.
    return_stmt,
    /// The end of one `if` branch or `match` arm body, keyed like a
    /// block end (the body's statement slice) or, for a non-block branch,
    /// by the branch expression's address. Recorded BEFORE the merge.
    /// A missing else is keyed by the `if` expression's address.
    branch_end,
    /// A `break` or `continue`, keyed by the statement's address.
    jump,
    /// The end of a value-position block, keyed by its statement slice,
    /// recorded after the tail is checked.
    value_block_end,
    /// After a `while` that moved an outer binding and then revived it on
    /// every path this walk saw. Keyed by the `while` statement's address,
    /// like a jump. Recorded AFTER `loop_moved` poisons the in-loop exits,
    /// so those stay skipped. Missing or `live = false` keeps the leak.
    after_loop,
    /// After a `while` whose outer binding is revived on every path out
    /// EXCEPT some of this loop's own `break`s, where it is dead (a
    /// skip-revival `break`, 2026-09-17). Keyed like `after_loop`. Only
    /// sound together with `skip_breaks`: codegen releases the binding
    /// after the loop and turns each listed `break` into a jump past that
    /// release, because a plain C `break` would run it on a moved buffer.
    after_loop_skip,
    /// Right AFTER an `if` or `match` merges its branches (2026-09-17).
    /// An `if` is keyed by the `if` expression's address, a `match` by the
    /// address of its arms slice (codegen receives the match by value).
    /// `live = true` means no branch moved the binding, so a branch-end
    /// release must not free it: a later move or the scope end owns it.
    /// Without this, a value moved AFTER an unrelated `if` was freed at
    /// every branch end (1eaed84, extended to match arms in 38e33a2).
    after_branch,
};

/// A `break` that must jump past the releases after its loop, recorded
/// with `ExitKind.after_loop_skip`. See `Checker.skip_breaks`.
pub const SkipBreak = struct {
    break_key: usize,
    loop_key: usize,
};

/// See `Checker.exit_liveness`.
pub const ExitLiveness = struct {
    kind: ExitKind,
    key: usize,
    binding: u32,
    live: bool,
};

/// See `Checker.exit_field_liveness`. Whole-binding liveness stays on
/// `ExitLiveness`; a field path is a sibling record, never a `liveAtExit`
/// overload. Missing or `live = false` keeps the leak.
pub const ExitFieldLiveness = struct {
    kind: ExitKind,
    key: usize,
    binding: u32,
    path: []const u8,
    live: bool,
};

/// A place whose value has been moved out (R2).
pub const Dead = struct {
    binding: u32,
    path: []const u8,
    display: []const u8,
    /// Where the move happened.
    span: Span,
    /// The `note:` text that explains the move.
    note: []const u8,
};

pub const Loan = struct {
    binding: u32,
    path: []const u8,
    display: []const u8,
    kind: LoanKind,
    span: Span,
    /// The `let` binding holding this loan, for a named (block-scoped) loan.
    holder: ?[]const u8 = null,
    /// Index into `open_blocks` of the block this loan was created in. Only
    /// meaningful for block-scoped loans.
    block_index: usize = 0,
    /// Index, within `open_blocks[block_index].stmts`, of the statement that
    /// created this loan. Only meaningful for block-scoped loans. Together
    /// with `block_index` it fixes the START of the window the NLL predicate's
    /// part (b) scans; `open_blocks[block_index].index` is its end.
    stmt_index: usize = 0,
    /// True for a loan that lasts to the end of its block, false for one that
    /// dies with its statement or its `if`.
    lexical: bool = false,
};

/// Whether a named loan still holds its referent at the statement being
/// checked, in the non-lexical sense. Only `dead` is an acceptance; both other
/// answers reject, so a bug that returns one of them can only cost precision.
pub const LoanStatus = enum {
    /// The holder is provably never reached again, so NLL ends the loan here.
    dead,
    /// The holder is mentioned again after this statement.
    live,
    /// The predicate cannot answer: the loan is a temporary, or has no holder,
    /// or the holder was mentioned before this statement in a position that
    /// may have propagated the reference somewhere this checker does not
    /// track. Distinguished from `live` only so the reason is legible.
    ineligible,
};

/// The differential oracle's answer. `not_applicable` is not "dead": it means
/// the oracle declined, and the assertion is skipped for that loan.
pub const OracleVerdict = enum { dead, live, not_applicable };

/// The oracle's name closure. A set of names, with no scope, no order and no
/// binding identity: that absence is the point.
pub const NameSet = std.StringHashMapUnmanaged(void);

/// Whether an expression sits in the one whitelisted position. Propagated DOWN
/// the walk by `oracleFindExpr`, rather than recovered by peeling upward the
/// way the checker's `argPropagatesName` does. Same whitelist, different
/// mechanism, which is the point of having two.
pub const ArgContext = enum {
    /// A direct argument of a call, or an ownership keyword or `&`/`&mut`
    /// sigil still wrapping one. R8 stops the callee keeping what it is given.
    call_arg,
    /// Everything else.
    other,
};

/// A block currently being walked, with the index of the statement in it that
/// is being checked. Used to decide whether a named loan is ever read again.
pub const OpenBlock = struct {
    stmts: []const ast.Stmt,
    index: usize,
};

/// One `while` whose body is being walked. A `break` or `continue` targets
/// the innermost `while` (SPEC 7.7), so only the top frame is consulted.
/// See `checkWhile`.
pub const LoopFrame = struct {
    /// Every binding with a smaller id was declared before the loop, so
    /// the back edge and a `break` carry its moves.
    first_loop_id: u32,
    /// `dead` as it stood before the condition's first evaluation, owned by
    /// `checkWhile`. The body is walked from this state, so an iteration
    /// that restarts with one of these entries still dead is a state the
    /// walk already checked.
    entry: []const Dead,
    /// The outer part of `dead` at every `break`, unioned into `dead` after
    /// the loop.
    break_dead: std.ArrayListUnmanaged(Dead) = .empty,
    /// The address of every `break` that leaves THIS loop (not a nested
    /// one), for the skip-revival rule in `checkWhile`.
    breaks: std.ArrayListUnmanaged(usize) = .empty,
    /// Moves R2.a already reported at a `continue`, so the body end does not
    /// report the same move twice.
    reported: std.ArrayListUnmanaged(Dead) = .empty,

    /// True when `d` is a move that the back edge or a `break` carries out
    /// of this iteration: a binding declared before the loop, moved in this
    /// loop's condition or body and not revived since.
    pub fn carries(self: *const LoopFrame, d: Dead) bool {
        return d.binding < self.first_loop_id and !containsDead(self.entry, d);
    }

    pub fn deinit(self: *LoopFrame, allocator: std.mem.Allocator) void {
        self.break_dead.deinit(allocator);
        self.breaks.deinit(allocator);
        self.reported.deinit(allocator);
    }
};

// ── free functions ──────────────────────────────────────────────────────

pub const Ref = struct { kind: LoanKind, operand: *const ast.Expr };

/// A `shared T` or `exclusive T` written in type position. `arc T` and
/// `owned T` are not borrows, so they are not R8.
pub fn typeIsBorrow(ty: *const ast.TypeExpr) ?LoanKind {
    return switch (ty.*) {
        .ref => |r| switch (r.ownership) {
            .shared => .shared,
            .exclusive => .exclusive,
            else => null,
        },
        else => null,
    };
}

/// `&x` and `&mut x`. Peels `.annotated` so a keyword prefix wrapping an
/// inner sigil (`shared &buf`) still counts as the sigil form.
pub fn refKind(e: *const ast.Expr) ?Ref {
    return switch (e.kind) {
        .annotated => |a| refKind(a.value),
        .unary => |u| switch (u.op) {
            .ref_shared => .{ .kind = .shared, .operand = u.operand },
            .ref_exclusive => .{ .kind = .exclusive, .operand = u.operand },
            else => null,
        },
        else => null,
    };
}

/// Whether `a` is a segment-wise prefix of, or equal to, `b`. The empty path
/// is a prefix of every path, so `buf` contains `buf.len` while `buf.le` does
/// not contain `buf.len`.
pub fn pathPrefix(a: []const u8, b: []const u8) bool {
    if (a.len == 0) return true;
    if (a.len > b.len) return false;
    if (!std.mem.eql(u8, a, b[0..a.len])) return false;
    return a.len == b.len or b[a.len] == '.';
}

pub fn typeStructName(ty: *const ast.TypeExpr) ?[]const u8 {
    return switch (ty.*) {
        .name => |n| n,
        .optional => |inner| typeStructName(inner),
        .ref => |r| typeStructName(r.inner),
        else => null,
    };
}

pub fn findField(def: ast.StructDef, name: []const u8) ?ast.Field {
    for (def.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

pub fn ctorName(c: ast.Ctor) []const u8 {
    return switch (c) {
        .ok => "Ok",
        .err => "Err",
        .some => "Some",
        .none => "None",
    };
}

pub fn sameKeys(a: []const usize, b: []const usize) bool {
    if (a.len != b.len) return false;
    for (a) |k| {
        if (std.mem.indexOfScalar(usize, b, k) == null) return false;
    }
    return true;
}

pub fn containsDead(list: []const Dead, d: Dead) bool {
    for (list) |x| {
        if (x.binding == d.binding and std.mem.eql(u8, x.path, d.path)) return true;
    }
    return false;
}
