//! Borrow and move checker for Cell.
//!
//! Implements `docs/OWNERSHIP.md` rules R1, R2, R2.a, **R2.b**, R3, R3a, R4,
//! R5, R6, **R7's consumption clause**, R8, R9,
//! R14, R15 and **R18**, plus ONE clause of R10: an `arc` value may not be
//! made UNIQUE,
//! refused at six consumption sites (an `owned` parameter, an `owned`
//! binding, an assignment into an `owned` place, an `owned` struct field, a
//! list-literal element, and a `return` whose declared return type is not
//! `arc`). The rest of R10, in particular move-into-`arc`, is
//! still designed only. That single clause is here rather than in codegen
//! because codegen cannot refuse it: `owned [T]` and `shared [T]` lower to
//! the SAME C type, so the emitted conversion compiles clean and double frees
//! the buffer. Its classifier, `arcUniqueSource`, returns a TOTAL verdict:
//! a source whose ownership it cannot resolve is refused, not permitted.
//! Read that function's comment before widening it a fourth time; the three
//! widenings so far were three different axes and each escaped through the
//! same permissive default.
//!
//! **R2.b** is the general rule that one clause of R10 was a special case of:
//! an `owned` consumption position is asked of the EXPRESSION, not of a place.
//! Every site used to call `placeOf` first and fall through to `checkExpr`,
//! which only READS, so `let owned s2: String = match c { 0 => s1, _ => s1 }`
//! read `s1`, `pendingDrops` kept both bindings, and one buffer was freed
//! twice (exit 134, no `arc` anywhere in it). Enforced at the same six sites,
//! by `ownedMoveSource`, whose `.unknown` is REFUSED and whose branch arms can
//! never return a movable place. A resource-bearing owned struct field now
//! permits only a fresh value: copying a place into the field and later moving
//! the field out was a live double free even before record drops existed.
//! List elements remain a separate transfer/release boundary.
//!
//! **R7's consumption clause** closes what R2.b left open, and it is the fifth
//! instance of this file's recurring defect rather than a new kind. The
//! scrutinee of a `match` is READ, never moved, so an arm binding is an ALIAS
//! of it and not a second owner; every consumption site then asked `placeOf`,
//! got a perfectly good place rooted at the arm binding, and MOVED that,
//! leaving the scrutinee live. `match s1 { x => take(owned x) }` freed `s1`'s
//! buffer in the callee and again at the scope drop: `cell check` exit 0,
//! `cc -fsanitize=address` exit 0, running it exit 134. ELEVEN shapes were
//! measured live at `4698dbc`, including a `[Int]` scrutinee, a `shared [T]`
//! parameter as scrutinee, an arm binding nested one match deep, and an
//! `arc [Int]` place whose arm binding launders R10 (`take_list(owned a)` is
//! refused, `match a { x => take_list(owned x) }` was exit 134).
//!
//! It is enforced by ONE question, `armAlias`, asked at the top of
//! `ownedMoveSource` above its `.place` return, so every `owned` consumption
//! site inherits it and a site added later inherits it without knowing R7
//! exists. Its verdict is the `.aliases_place` variant, and adding that
//! variant is what enumerated the sites: the switches have no `else` arm, so
//! the compiler refused to build until each one answered.
//!
//! It REFUSES rather than moving the scrutinee. Moving is the better long-term
//! semantics and is recorded as the designed follow-up in `docs/OWNERSHIP.md`
//! R7; it is not done here because it changes `wasMoved` for every arm binding
//! and codegen's `pendingDrops` reads that. The distinction the refusal draws
//! is "does anything else still own this": a scrutinee that is not a place has
//! no other owner, so `match make() { x => take(owned x) }` still lowers and
//! still runs. See `ArmOrigin`, and read `checkMatch`'s comment on why that
//! answer does NOT propagate to a nested match: the version that propagated
//! was a twelfth live shape, not a precision win.
//!
//! **R18** is R3 read in the other direction: R3 refuses moving OUT of a
//! borrow, and R18 refuses binding an `owned` name TO one. It is the second
//! defect of this family found at the `let` position and the fourth in the
//! file, so the shape is worth stating once: an enumeration of the forms the
//! author had in mind, asserted over every form. `checkLetInit` opened with a
//! branch that matched `refKind` -- the SIGIL spellings -- and created a loan
//! without ever reading `l.ownership`, so `let owned xs = &list` returned
//! before the `.owned` branch could move the lender and both were dropped
//! (exit 134). The keyword spellings did not match `refKind`, fell through,
//! and silently MOVED the lender under a written `shared` prefix, which is
//! the same defect wearing exit 0. The rule is therefore enforced by ONE
//! question asked of the whole initializer, `borrowSource`, above every
//! branch that could answer differently; it is the classifier R14's rebinding
//! clause already used, and its switch is exhaustive with no `else`.
//!
//! **R9** is both halves of "`arc` grants shared access only": no `exclusive`
//! borrow of an `arc` place, refused in `createLoan` because that is the ONE
//! point every exclusive loan passes through, plus `refuseArcValueBorrow` for
//! the value positions no loan is created for; and no write THROUGH an `arc`
//! place, refused in `checkAssign` against the STRICT prefixes of the target's
//! path, so rebinding a `var arc` handle stays legal. `arcReach` is its
//! classifier and is total the same way `arcUniqueSource` is. The one form R9
//! does not own is an empty-path rebind of an immutable `arc` parameter, which
//! R14's immutability derivation still reports with R14's generic message.
//!
//! **R14 has a second clause**: a binding that already holds a borrow may not
//! be reassigned. `let` was covered by immutability; `var` was not, and
//! `e = &mut b` had two meanings, a retarget this checker modelled wrongly and
//! a write-through the C backend actually emits. Read the comment at that
//! check before relaxing it.
//!
//! It is deliberately independent of
//! `typecheck.zig`: it carries its own scope stack, its own signature table,
//! and imports only `ast.zig` and `diag.zig`, so it neither depends on nor
//! disturbs the type checker.
//!
//! Two design points worth knowing before reading the code.
//!
//! **Places, not names.** A place is a binding identity plus a dotted field
//! path (`buf`, `buf.len`). Bindings get a monotonic id, so two sibling blocks
//! that each declare `let owned a` are two different places and a move in the
//! first cannot kill the second. Two places conflict when either path is a
//! segment-wise prefix of the other, which is the whole of R6.
//!
//! **Lexical loans with two narrowing exceptions** (OWNERSHIP.md 0.3). A loan
//! bound to a name lives to the end of its block and is kept in `block_loans`,
//! truncated when the scope pops. Every other loan is a temporary in
//! `temp_loans`, truncated when the region that created it closes: one region
//! per statement, and one region around a whole `if` so a borrow taken in the
//! condition survives the branches and dies with the `if`.
//!
//! **Non-lexical lifetimes for NAMED loans, slices 1 and 2.** A named loan
//! whose holder is provably never reached again does not block a conflicting
//! read, move, borrow or assignment: `loanStatusAt` decides, all four conflict
//! sites route through `findBlockingLoan`, and `dead` is the only status that
//! accepts. It replaces the note that used to say "this would be accepted
//! under non-lexical lifetimes", which is now the acceptance itself.
//!
//! `dead` needs BOTH a forward scan and a window scan, which see disjoint
//! regions; the doc comment on `loanStatusAt` argues they are exhaustive over
//! a loan's live range, and the one on `oracleDead` explains why that argument
//! is checked at runtime by a second, deliberately stupid predicate rather
//! than trusted. Slice 3, a taint closure over derived bindings, is
//! deliberately absent: `let exclusive f = e` makes the loan `ineligible`,
//! which rejects, and rejecting is always safe here.

const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const types = @import("types.zig");

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
const ArmOrigin = enum {
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
const Binding = struct {
    id: u32,
    name: []const u8,
    /// The declared annotation. `owned` when none was written (R1).
    ownership: Ownership,
    /// Whether the binding itself may be reassigned (R14).
    mutable: bool,
    /// Struct type name, when it could be resolved from the declaration or the
    /// initializing struct literal. Needed to read field annotations.
    struct_name: ?[]const u8,
    decl_span: Span,
    /// R7. Defaults to `.not_an_arm` so the two non-arm `declare` sites are
    /// unchanged; only `checkMatch` ever sets it.
    arm_origin: ArmOrigin = .not_an_arm,
    /// The scrutinee place this arm binding aliases, for the diagnostic.
    /// Arena-allocated by `placeOf` (or a slice of the source), so it outlives
    /// the match. Only meaningful when `arm_origin == .alias`.
    arm_scrutinee: ?[]const u8 = null,
};

/// A place: a binding plus a field path relative to it.
const Place = struct {
    binding: u32,
    /// `""` for the binding itself, `"len"` for `buf.len`.
    path: []const u8,
    /// `buf` or `buf.len`, for diagnostics.
    display: []const u8,
    span: Span,
};

/// A place whose value has been moved out (R2).
const Dead = struct {
    binding: u32,
    path: []const u8,
    display: []const u8,
    /// Where the move happened.
    span: Span,
    /// The `note:` text that explains the move.
    note: []const u8,
};

const Loan = struct {
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
const LoanStatus = enum {
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
const OracleVerdict = enum { dead, live, not_applicable };

/// The oracle's name closure. A set of names, with no scope, no order and no
/// binding identity: that absence is the point.
const NameSet = std.StringHashMapUnmanaged(void);

/// Whether an expression sits in the one whitelisted position. Propagated DOWN
/// the walk by `oracleFindExpr`, rather than recovered by peeling upward the
/// way the checker's `argPropagatesName` does. Same whitelist, different
/// mechanism, which is the point of having two.
const ArgContext = enum {
    /// A direct argument of a call, or an ownership keyword or `&`/`&mut`
    /// sigil still wrapping one. R8 stops the callee keeping what it is given.
    call_arg,
    /// Everything else.
    other,
};

/// A block currently being walked, with the index of the statement in it that
/// is being checked. Used to decide whether a named loan is ever read again.
const OpenBlock = struct {
    stmts: []const ast.Stmt,
    index: usize,
};

pub const Checker = struct {
    allocator: std.mem.Allocator,
    /// Owns every formatted diagnostic message, so messages outlive the walk
    /// but die with the checker.
    arena: std.heap.ArenaAllocator,
    diagnostics: diag.Bag,

    fns: std.StringHashMapUnmanaged(ast.FnDef) = .empty,
    structs: std.StringHashMapUnmanaged(ast.StructDef) = .empty,
    /// Enum definitions, needed for one thing only: `Quadrant.First` parses as
    /// a `field` whose base is an `ident` that is NOT a binding, so `placeOf`
    /// returns null for it. R10's classifier has to tell that qualified
    /// constant apart from `fresh().len`, a field of a temporary whose
    /// ownership it genuinely cannot resolve.
    enums: std.StringHashMapUnmanaged(ast.EnumDef) = .empty,

    bindings: std.ArrayList(Binding) = .empty,
    /// Marks into `bindings` and `block_loans`, one per open scope.
    scopes: std.ArrayList(ScopeMark) = .empty,
    dead: std.ArrayList(Dead) = .empty,
    block_loans: std.ArrayList(Loan) = .empty,
    temp_loans: std.ArrayList(Loan) = .empty,
    open_blocks: std.ArrayList(OpenBlock) = .empty,
    next_binding_id: u32 = 0,
    /// Every binding id that was moved at least once, anywhere in the
    /// function that declared it (task 3: conservative drop insertion).
    ///
    /// This is a DIFFERENT question from `dead`. `dead` is a lexical,
    /// revivable snapshot: R3a removes an entry when the place is assigned a
    /// fresh value, because a later READ needs to know the place is live
    /// again. A drop pass asks a coarser question -- "did this binding's
    /// value ever get handed to someone else on some path through this
    /// function" -- and revival must NOT clear that, because dropping is a
    /// property of the whole function body, not of one program point: this
    /// set only ever grows.
    ///
    /// Populated by `movePlace`'s one success path (the same call that
    /// appends to `dead`), so it inherits the same conservatism `dead`
    /// does: a move on only one branch of an `if` still marks the binding
    /// here, because `movePlace` is called from inside that branch
    /// regardless of what the other branch does. See `wasMoved`.
    ///
    /// Never cleared, including across functions, unlike `dead`
    /// (`checkFn` resets `dead` per function but not this). That is safe
    /// rather than a leak between functions: `next_binding_id` is also
    /// never reset, so ids are unique for the lifetime of one `Checker`,
    /// and a query by id can never cross a function boundary by accident.
    moved: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Every binding's name, keyed by id, permanent for the checker's whole
    /// life -- unlike `bindings`, which is truncated when its scope pops,
    /// so it cannot answer this once a function has finished checking.
    /// Exists only so a consumer that reconstructs ids independently
    /// (codegen.zig, task 3, whose own counter has to allocate ids in the
    /// same order as `declare` below without sharing its state) can assert
    /// its name for id N still matches what N was declared under here,
    /// turning a silent numbering drift between the two files into a loud
    /// crash instead of a wrong free. See codegen.zig's module doc comment.
    names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// Set while checking a function whose return type is a `shared` or
    /// `exclusive` borrow (R8). Cell has no lifetime parameters, so such a
    /// return is always an error. Bodyless declarations report at the
    /// function; a body reports at each returned expression (the use) and
    /// the flag stops that return from also being a move-out-of-borrow.
    fn_return_borrow: ?LoanKind = null,
    /// Set while checking a function that declares a return type which is NOT
    /// `-> arc T`, which by R1 makes the return slot an `owned` one (R10, the
    /// return position). Null when the function declares no return type at
    /// all: the value is discarded there, so nothing is made unique and
    /// refusing would have no memory-safety basis. `-> arc T` is the legal
    /// `arc`-to-`arc` case and is deliberately not flagged.
    fn_return_owned: ?[]const u8 = null,
    /// The function whose body is being walked. Read only by the differential
    /// oracle, which needs the whole body and the parameter list at once,
    /// which the region-walking state above deliberately does not keep.
    current_fn: ?*const ast.FnDef = null,

    const ScopeMark = struct {
        bindings: usize,
        block_loans: usize,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        path: []const u8,
        source: ?[]const u8,
    ) Checker {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .diagnostics = .init(path, source),
        };
    }

    pub fn deinit(self: *Checker) void {
        self.fns.deinit(self.allocator);
        self.structs.deinit(self.allocator);
        self.enums.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.dead.deinit(self.allocator);
        self.moved.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.block_loans.deinit(self.allocator);
        self.temp_loans.deinit(self.allocator);
        self.open_blocks.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn hasErrors(self: *const Checker) bool {
        return self.diagnostics.hasErrors();
    }

    fn msg(self: *Checker, comptime fmt: []const u8, args: anytype) Error![]const u8 {
        return try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
    }

    // ── module walk ─────────────────────────────────────────────────────

    /// Check every function body in `module`, filling `diagnostics`.
    pub fn checkModule(self: *Checker, module: *const ast.Module) Error!void {
        self.diagnostics.path = module.path;
        // Signatures first: a call may precede its callee's definition, and
        // R15 and R1 both need the parameter annotations.
        for (module.items) |*item| {
            switch (item.kind) {
                .fn_def => |f| try self.fns.put(self.allocator, f.name, f),
                .struct_def => |s| try self.structs.put(self.allocator, s.name, s),
                .enum_def => |en| try self.enums.put(self.allocator, en.name, en),
                else => {},
            }
        }
        for (module.items) |*item| {
            switch (item.kind) {
                .fn_def => |*f| try self.checkFn(item.span, f),
                .struct_def => |s| try self.checkStructFields(item.span, s),
                else => {},
            }
        }
    }

    fn checkFn(self: *Checker, span: Span, f: *const ast.FnDef) Error!void {
        self.fn_return_borrow = null;
        self.fn_return_owned = null;
        self.current_fn = f;
        defer self.current_fn = null;
        if (f.return_type) |*rt| {
            const returns_arc = switch (rt.*) {
                .ref => |r| r.ownership == .arc,
                .name, .optional, .list, .result, .unit => false,
            };
            if (!returns_arc) self.fn_return_owned = f.name;
            if (typeIsBorrow(rt)) |kind| {
                self.fn_return_borrow = kind;
                // A bodyless `-> shared T` has no return expression to point
                // at, so the function item is the use site. A body reports at
                // each `return` instead (see checkStmt).
                if (f.body == null) try self.reportEscapingReturn(span, kind);
            }
        }
        const body = f.body orelse return;

        // A fresh scope per function. This is what keeps a parameter of one
        // function from leaking into the next (OWNERSHIP.md 0.4), without
        // depending on typecheck.zig's symbol table.
        try self.pushScope();
        defer self.popScope();
        // Each function starts from a clean move and loan state.
        self.dead.clearRetainingCapacity();

        for (f.params) |p| {
            _ = try self.declare(.{
                .id = 0,
                .name = p.name,
                .ownership = p.ownership,
                // R14 defect 3: a parameter is writable exactly when it owns
                // its value or holds an exclusive borrow. `arc` is immutable
                // by R9, `shared` by definition, `copy` because a duplicate
                // parameter is not a `var`.
                .mutable = p.ownership == .owned or p.ownership == .exclusive,
                .struct_name = typeStructName(&p.ty),
                .decl_span = .none,
            });
        }
        try self.checkBlockStmts(body);
    }

    // ── scopes ──────────────────────────────────────────────────────────

    fn pushScope(self: *Checker) Error!void {
        try self.scopes.append(self.allocator, .{
            .bindings = self.bindings.items.len,
            .block_loans = self.block_loans.items.len,
        });
    }

    fn popScope(self: *Checker) void {
        const mark = self.scopes.pop() orelse return;
        self.bindings.shrinkRetainingCapacity(mark.bindings);
        // R0.3: a named loan ends with the block that created it.
        self.block_loans.shrinkRetainingCapacity(mark.block_loans);
    }

    fn declare(self: *Checker, proto: Binding) Error!u32 {
        var b = proto;
        b.id = self.next_binding_id;
        self.next_binding_id += 1;
        try self.bindings.append(self.allocator, b);
        try self.names.put(self.allocator, b.id, b.name);
        return b.id;
    }

    /// The innermost visible binding named `name`, so shadowing works.
    fn lookup(self: *const Checker, name: []const u8) ?*const Binding {
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.bindings.items[i].name, name)) {
                return &self.bindings.items[i];
            }
        }
        return null;
    }

    fn bindingById(self: *const Checker, id: u32) ?*const Binding {
        for (self.bindings.items) |*b| {
            if (b.id == id) return b;
        }
        return null;
    }

    /// Whether `binding` was moved anywhere in the function that declared
    /// it. Conservative in the same direction `dead` already is: a move on
    /// only one branch of an `if` answers true for the whole rest of the
    /// function (see the doc comment on `moved`), so this is "maybe
    /// moved", never "definitely moved right here". A caller deciding
    /// whether to destroy a place MUST treat "maybe" as "yes": not
    /// destroying a place that is actually still live only leaks it: task
    /// 3's whole design rests on that asymmetry, spelled out in
    /// codegen.zig's module doc comment.
    ///
    /// This reads `moved`, not `bindings`, so it still answers correctly
    /// after the binding's own scope has popped and after the whole module
    /// has finished checking -- exactly the state codegen queries it in
    /// (see codegen.zig's module doc comment: it runs `checkModule` once,
    /// up front, then emits).
    pub fn wasMoved(self: *const Checker, binding: u32) bool {
        return self.moved.contains(binding);
    }

    /// The name `binding` was declared under. See the doc comment on
    /// `names` for why this exists: a numbering cross-check, not a feature
    /// borrowck itself needs.
    pub fn bindingName(self: *const Checker, binding: u32) ?[]const u8 {
        return self.names.get(binding);
    }

    /// Walk `stmts` as a block: one scope, one entry on the open-block stack.
    fn checkBlockStmts(self: *Checker, stmts: []const ast.Stmt) Error!void {
        try self.pushScope();
        defer self.popScope();
        try self.open_blocks.append(self.allocator, .{ .stmts = stmts, .index = 0 });
        defer _ = self.open_blocks.pop();
        for (stmts, 0..) |*s, i| {
            self.open_blocks.items[self.open_blocks.items.len - 1].index = i;
            try self.checkStmt(s);
        }
    }

    // ── statements ──────────────────────────────────────────────────────

    /// `while cond { ... }`, and OWNERSHIP.md R2.a with it.
    ///
    /// THE PROBLEM A LOOP CREATES. `docs/OWNERSHIP.md` section 0.3 chose
    /// lexical loans on the stated ground that they are decidable in a single
    /// pass with a scope stack and need no control-flow graph. A loop is a
    /// back edge, which breaks that assumption directly:
    ///
    ///     var owned buf = make()
    ///     while c {
    ///         take(owned buf)     // fine on iteration 1
    ///     }                       // use-after-move on iteration 2
    ///
    /// The single pass marks `buf` dead once and never revisits it, so nothing
    /// catches the second iteration.
    ///
    /// THE RULE, AND WHY THIS SHAPE. A place declared OUTSIDE the loop that is
    /// moved INSIDE it and is still dead when the body ends would be read
    /// dead on the next iteration. `dead` already tracks exactly that, and
    /// R3a already REMOVES a place from `dead` when it is reassigned, so
    /// "still dead at the end of the body" is precisely "moved and not
    /// revived". No new machinery, and revival keeps working for free.
    ///
    /// WHERE IT IS CONSERVATIVE, STATED RATHER THAN HIDDEN. A body that always
    /// `break`s before reaching the move is rejected anyway, because this does
    /// not track which paths reach the end. That is the same trade section 0.3
    /// already made, and the same guarantee applies: every program accepted
    /// under this rule is still accepted under a real control-flow analysis,
    /// so tightening now and relaxing later never breaks source compatibility.
    fn checkWhile(self: *Checker, w: anytype, span: Span) Error!void {
        try self.checkExpr(@constCast(&w.cond));

        const first_inner_id = self.next_binding_id;
        const dead_before = self.dead.items.len;

        // checkBlockStmts pushes the scope and the open-block entry, so a
        // binding declared in the body dies with it and a named loan created
        // there is truncated on the way out, exactly as in an `if` body.
        try self.checkBlockStmts(w.body);

        // Anything still dead that was declared before the loop was moved in
        // the body and never revived.
        var i = dead_before;
        while (i < self.dead.items.len) : (i += 1) {
            const d = self.dead.items[i];
            if (d.binding >= first_inner_id) continue;
            try self.diagnostics.err(self.arena.allocator(), d.span, try std.fmt.allocPrint(
                self.arena.allocator(),
                "'{s}' is moved inside a loop, so the next iteration would use it after the move",
                .{d.display},
            ));
            try self.diagnostics.note(self.arena.allocator(), span, try std.fmt.allocPrint(
                self.arena.allocator(),
                "'{s}' is declared outside this loop; assign to it before the end of the body to revive it",
                .{d.display},
            ));
        }
    }

    fn checkStmt(self: *Checker, stmt: *const ast.Stmt) Error!void {
        // R0.3 exception 1: every loan created inside a statement and not
        // bound to a name ends when the statement completes.
        const region = self.temp_loans.items.len;
        defer self.temp_loans.shrinkRetainingCapacity(region);

        switch (stmt.kind) {
            .while_stmt => |*w| try self.checkWhile(w, stmt.span),
            // A `break` or `continue` moves nothing and borrows nothing. It
            // does change which paths reach the end of the body, which R2.a
            // below deliberately ignores; see the note there.
            .break_stmt, .continue_stmt => {},
            .let => |*l| try self.checkLet(l, stmt.span),
            .expr => |*e| try self.checkExpr(e),
            .return_stmt => |*opt| {
                if (self.fn_return_borrow) |kind| {
                    // R8 lands at the returned expression, which is the use.
                    // Do not also move the place: that would be a second
                    // diagnostic for the same escape.
                    if (opt.*) |*e| {
                        try self.reportEscapingReturn(e.span, kind);
                        if ((try self.placeOf(e)) == null) try self.checkExpr(e);
                    } else {
                        try self.reportEscapingReturn(stmt.span, kind);
                    }
                    return;
                }
                if (opt.*) |*e| {
                    // R10, the return position, and the second of the two
                    // consumption sites the four-position enumeration never
                    // asked at. A `-> [Int]` return slot is `owned` by R1, so
                    // returning an `arc` source unboxes it and hands the
                    // buffer to a caller that frees it while the box's glue
                    // frees it again. Today that emission is a loud `cc` type
                    // error for a list (`cell_slice_t x = cell_arc_clone(...)`
                    // does not compile), which is protection by coincidence of
                    // two C types, and R10's own text objects to exactly that.
                    // `-> arc T` is untouched: `fresh()` returning its own
                    // `arc` local is the legal arc-to-arc case.
                    if (self.fn_return_owned) |fn_name| {
                        if (try self.refuseArcUnique(
                            try self.arcUniqueSource(e),
                            "return",
                            "from",
                            "function",
                            fn_name,
                        )) return;
                        // R2.b, the return position, the other live site the
                        // brief did not name. Measured at `0e82266`:
                        // `return match c { 0 => s1, _ => s1 }` from a
                        // `-> String` function was exit 134, the caller and
                        // the callee's scope drop freeing one buffer.
                        switch (try self.ownedMoveSource(e)) {
                            .unknown => |s| {
                                try self.refuseUnknownMove(s, "return", "from", "function", fn_name);
                                return;
                            },
                            // R7, the return position. Measured at `4698dbc`:
                            // an arm binding returned out of a `-> String`
                            // function was exit 134.
                            .aliases_place => |s| {
                                try self.refuseScrutineeAlias(s, "return", "from", "function", fn_name);
                                return;
                            },
                            // A place is moved below, unchanged.
                            .place, .no_owned_place => {},
                        }
                    }
                    if (try self.placeOf(e)) |place| {
                        const note = try self.msg("'{s}' was moved here by returning it", .{place.display});
                        try self.movePlace(place, note);
                    } else {
                        try self.checkExpr(e);
                    }
                }
            },
            .assign => |*a| try self.checkAssign(a),
        }
    }

    fn checkLet(self: *Checker, l: *const @FieldType(ast.Stmt.Kind, "let"), span: Span) Error!void {
        var struct_name: ?[]const u8 = null;
        if (l.ty) |*t| struct_name = typeStructName(t);

        if (l.value) |*v| {
            if (struct_name == null) {
                if (v.kind == .struct_lit) struct_name = v.kind.struct_lit.name;
            }
            // And from a CALL's declared return type. Without this,
            // `let owned s = make()` over `make() -> Session` leaves
            // `struct_name` null, `placeOwnership` cannot read `s.data`'s
            // annotation, and R10's total verdict calls that `unknown` and
            // REFUSES a valid program. Measured: it did exactly that, and
            // typecheck reported nothing alongside it, so the refusal was the
            // only diagnostic. A total verdict makes every unresolved
            // annotation load-bearing, which is the cost of the guarantee and
            // the reason this inference has to exist rather than being an
            // optimisation.
            //
            // Residual, stated rather than left to be rediscovered: a `match`
            // or a block yielding a struct in an UNANNOTATED `let` still
            // leaves `struct_name` null and is still refused in an `owned`
            // field consumption. Write the type (`let owned s: Session = ...`)
            // and it resolves.
            if (struct_name == null) {
                if (v.kind == .call) {
                    if (v.kind.call.callee.kind == .ident) {
                        if (self.fns.get(v.kind.call.callee.kind.ident)) |sig| {
                            if (sig.return_type) |rt| struct_name = typeStructName(&rt);
                        }
                    }
                }
            }
            // And ACROSS A BORROW. `let exclusive e = &mut buf` has no
            // annotation, is not a struct literal and is not a call, so `e`
            // used to carry no struct type at all, and `&mut e.len` then had
            // no field annotation to read. That is harmless while an
            // unresolved annotation means "permit"; R9's verdict is total, so
            // it would mean REFUSE, and a plain field borrow through a named
            // loan would stop compiling. Same shape as the call inference
            // above, added for the same reason.
            if (struct_name == null) {
                const referent: ?*const ast.Expr = if (refKind(v)) |r|
                    r.operand
                else if (l.ownership == .shared or l.ownership == .exclusive)
                    v
                else
                    null;
                if (referent) |operand| {
                    if (try self.placeOf(operand)) |p| {
                        if (self.bindingById(p.binding)) |rb| {
                            struct_name = self.placeStructName(rb, p.path);
                        }
                    }
                }
            }
            try self.checkLetInit(l, v);
        }

        _ = try self.declare(.{
            .id = 0,
            .name = l.name,
            .ownership = l.ownership,
            .mutable = l.mutable,
            .struct_name = struct_name,
            .decl_span = span,
        });
    }

    /// The initializer of a `let`. Four shapes matter, and the ORDER of the
    /// first two is the rule rather than a detail:
    ///
    /// * an `owned` binding initialized from a BORROW is refused (R18). This
    ///   is asked first, because every branch below it either creates a loan
    ///   or moves, and both of those are wrong answers for this shape.
    /// * `&x` / `&mut x`, or a bare place under a `shared`/`exclusive`
    ///   annotation, creates a **named** loan that lives to the end of the
    ///   block. This is the loan provenance R5 asks for.
    /// * a bare place under an `owned` annotation is a move (R2).
    /// * anything else is an ordinary expression, and any loan inside it is a
    ///   temporary that dies with the statement.
    fn checkLetInit(
        self: *Checker,
        l: *const @FieldType(ast.Stmt.Kind, "let"),
        v: *const ast.Expr,
    ) Error!void {
        // R18, the `let` position, and the ONE question asked about the
        // initializer's borrow-ness anywhere in this function.
        //
        // It is placed ABOVE the loan branch rather than inside it, and that
        // placement is the fix. The loan branch used to open this function and
        // never consulted `l.ownership` at all: `let owned xs = &list` became
        // a named loan and RETURNED, so the `.owned` branch below -- which
        // would have moved the lender -- was never reached. The lender was
        // therefore never moved, codegen's `pendingDrops` kept both it and the
        // binding, and one buffer was freed twice. Measured at `b61a107`:
        // `cell check` exit 0, `cc -fsanitize=address` exit 0, running it
        // `AddressSanitizer: attempting double-free` at exit 134.
        //
        // The classifier is `borrowSource`, which R14's rebinding clause
        // already uses, and reusing it is deliberate. The alternative was a
        // list of borrow SPELLINGS to reject, and a list is exactly the
        // reasoning failure this defect is an instance of: the old branch
        // matched `refKind`, which is the sigil forms, so `&list` and
        // `&mut list` crashed while `shared list` and `exclusive list` reached
        // the move below and silently moved the lender under a written
        // `shared` prefix -- a second wrong answer wearing exit 0.
        // `borrowSource`'s switch is exhaustive with no `else`, so a new
        // expression kind fails to COMPILE here rather than falling through
        // permissively, and a new borrow spelling is refused without a second
        // edit at this site.
        if (l.ownership == .owned) {
            switch (try self.borrowSource(v)) {
                .not_borrow => {},
                // `.unresolved` is deliberately NOT refused here, and the
                // reason is that this position already refuses its useful
                // half: R2.b's `ownedMoveSource` is total at this same site
                // and reports `refuseUnknownMove` for a field of a temporary
                // and an unresolved name. What is left over is a call whose
                // callee this checker cannot resolve, which borrowck sees for
                // an undeclared function that typecheck reports separately.
                // Refusing it here would make borrowck report a SECOND,
                // borrow-flavoured error for a program whose real defect is
                // an unknown name. The residual is stated rather than hidden:
                // an indirect call returning a borrow would slip through, and
                // this grammar has no function values for one to be written
                // with.
                .unresolved => {},
                .borrow => |s| {
                    try self.diagnostics.err(
                        self.allocator,
                        s.span,
                        try self.msg(
                            "cannot bind {s} to the 'owned' binding '{s}': a borrow does not confer ownership",
                            .{ s.display, l.name },
                        ),
                    );
                    try self.diagnostics.note(
                        self.allocator,
                        s.span,
                        try self.msg(
                            "R18: an 'owned' binding is destroyed at the end of its scope (R16), so binding one to a borrow frees the lender's value twice; write 'let shared {s}' or 'let exclusive {s}' to hold the borrow",
                            .{ l.name, l.name },
                        ),
                    );
                    // The initializer is still walked, so a use-after-move or
                    // a conflicting loan inside it is reported alongside this
                    // rather than hidden behind it.
                    try self.checkExpr(v);
                    return;
                },
            }
        }
        if (refKind(v)) |r| {
            if (try self.placeOf(r.operand)) |place| {
                try self.createLoan(place, r.kind, true, l.name);
                return;
            }
        }
        if (l.ownership == .shared or l.ownership == .exclusive) {
            if (try self.placeOf(v)) |place| {
                const kind: LoanKind = if (l.ownership == .exclusive) .exclusive else .shared;
                try self.createLoan(place, kind, true, l.name);
                return;
            }
        }
        if (l.ownership == .owned) {
            // R10, the `let` position. Asked of the whole EXPRESSION's
            // verdict, so a value position
            // (`let owned ys: [Int] = match c { 0 => xs, _ => xs }`) and a
            // call result (`let owned ys: [Int] = fresh()`) are both refused.
            // See `arcUniqueSource`.
            if (try self.refuseArcUnique(
                try self.arcUniqueSource(v),
                "bind",
                "to",
                "binding",
                l.name,
            )) return;
            // R2.b, the `let` position, and the FIRST of the four live double
            // frees this rule closes. It replaces a bare `placeOf` here: a
            // `match` is not a place, so the old fall-through read `s1`
            // instead of moving it and `pendingDrops` freed the buffer twice.
            // See `ownedMoveSource`.
            switch (try self.ownedMoveSource(v)) {
                .place => |place| {
                    // The `arc` case already returned above. `let owned ys:
                    // [Int] = xs` with an `arc [Int]` source emitted
                    // `cell_slice_t ys = *(...)xs.ptr;` followed by BOTH
                    // `cell_slice_free(&ys)` and the box's own glue: an
                    // AddressSanitizer double free, silent at `cell check` and
                    // clean at `-Werror`.
                    const note = try self.msg(
                        "'{s}' was moved here by binding it to '{s}'",
                        .{ place.display, l.name },
                    );
                    try self.movePlace(place, note);
                    return;
                },
                .unknown => |s| {
                    try self.refuseUnknownMove(s, "bind", "to", "binding", l.name);
                    return;
                },
                // R7, the `let` position. Not a double free at `4698dbc` only
                // because an arm binding is never dropped either, so
                // `match s1 { x => { let owned y = x } }` merely aliased three
                // headers onto one buffer; it detonates the moment arm-scope
                // drops land, which is why it is refused with the live ones.
                .aliases_place => |s| {
                    try self.refuseScrutineeAlias(s, "bind", "to", "binding", l.name);
                    return;
                },
                .no_owned_place => {},
            }
        }
        // `copy` and `arc` bindings duplicate or retain rather than move
        // (R12, R10), so a bare place initializer is only read.
        try self.checkExpr(v);
    }

    fn checkAssign(self: *Checker, a: *const @FieldType(ast.Stmt.Kind, "assign")) Error!void {
        const target = try self.placeOf(&a.target);
        if (target == null) {
            try self.checkExpr(&a.target);
            try self.checkExpr(&a.value);
            return;
        }
        const place = target.?;
        const b = self.bindingById(place.binding).?;

        // R14. A write through a field path of an `exclusive` binding mutates
        // the referent, which the borrow already grants, so only a write to
        // the binding itself needs the binding to be mutable.
        const writable = if (place.path.len > 0 and b.ownership == .exclusive)
            true
        else
            b.mutable;
        if (!writable) {
            try self.diagnostics.err(
                self.allocator,
                place.span,
                try self.msg("cannot assign to immutable binding '{s}'", .{b.name}),
            );
            if (b.decl_span.line != 0) {
                try self.diagnostics.note(
                    self.allocator,
                    b.decl_span,
                    try self.msg("'{s}' is declared immutable here", .{b.name}),
                );
            }
            // R3a: an immutable assignment is an error, not a revival.
            try self.checkExpr(&a.value);
            return;
        }

        // Writing into a place whose owner was moved out is a use after move,
        // and is not the revival of R3a: only the moved place itself, or a
        // place containing it, is revived.
        if (self.deadStrictPrefixOf(place)) |d| {
            try self.reportUseAfterMove(d, place.span);
            try self.checkExpr(&a.value);
            return;
        }

        // R9, the mutation half. Asked of the STRICT prefixes, so writing
        // `b.n = 2` through an `arc` binding is refused while `s = other` on
        // a `var arc s` stays legal: that one rebinds the handle, which is
        // R11's leak and not a mutation of the shared value.
        //
        // Measured before this at exit 0: `var arc b = B { n: 1 }` then
        // `b.n = 2` was accepted, and emitted `cell_arc_t b = (cell_B){...};
        // b.n = 2;`, which `cc` then refused. A loud C error is the mild end
        // of this rule; `&mut b.h` on an `arc` field was silent (see
        // `createLoan`).
        //
        // The spec's own R9 example, `pub fn rename(arc n: String) { n = "other" }`,
        // does NOT reach here: it is an empty path, so R14's immutability
        // check above fires first and reports its generic message. That is
        // unchanged and still what `examples/rejected/arc_mutation.cell`
        // pins; the explicit R9 message for a parameter rebind is still
        // designed only, and OWNERSHIP.md R9 says so.
        if (try self.refuseArcShared(
            try self.arcReach(place, .strict_prefix),
            place,
            .assign,
        )) {
            try self.checkExpr(&a.value);
            return;
        }

        // R5 applied to a write. The spec fixes the wording for reads only;
        // a write is strictly stronger than a read, so an outstanding loan of
        // either kind blocks it.
        //
        // THE FOURTH SITE. `readPlace`, `movePlace` and `createLoan` all
        // consulted the NLL predicate and this one did not, so an assignment
        // was rejected by a loan the other three had already stopped
        // rejecting. Three enumerated, a fourth missed.
        if (try self.findBlockingLoan(place, .exclusive)) |loan| {
            try self.diagnostics.err(
                self.allocator,
                place.span,
                try self.msg(
                    "cannot assign to '{s}' while it is borrowed as {s}",
                    .{ place.display, loan.kind.word() },
                ),
            );
            try self.noteLoanScope(loan);
            try self.checkExpr(&a.value);
            return;
        }

        // R14's second clause: a binding that already holds a borrow may not
        // be reassigned. R14 already refuses this for a `let`, by
        // immutability; `var` reached here and nothing stopped it.
        //
        // THE STATEMENT HAS TWO MEANINGS AND THE COMPILER IMPLEMENTS BOTH,
        // DIFFERENTLY. For `var exclusive e = &mut a` then `e = &mut b`:
        //
        //   * this checker read it as a RETARGET, and read it wrong. `placeOf`
        //     returns null for a unary, so `checkExpr` made a TEMPORARY loan
        //     on `b` that died with the statement, while `e`'s named loan
        //     still pointed at `a`. After the statement there was a loan on
        //     `a` and NONE on `b`, so `take(owned b)` was accepted.
        //   * the C backend reads it as a WRITE THROUGH, and emits
        //     `*e = *&b;`, copying `b`'s value into `a`.
        //
        // The second reading is the one that runs, and it is a live double
        // free, not a stale-loan nuisance. Measured on
        //
        //     var owned a = make()   var owned b = make()
        //     var exclusive e = &mut a
        //     e = &mut b
        //
        // with `make() -> String`: the emit was `*e = *&b;` followed by
        // `cell_string_free(&b); cell_string_free(&a);`, `a` and `b` holding
        // the same buffer. AddressSanitizer: attempting double-free, exit 134.
        // `a`'s original buffer leaks in the same statement.
        //
        // So this is refused rather than modelled. Modelling the retarget
        // would mean killing `e`'s old loan, and killing a loan is the unsafe
        // direction under a name-keyed holder; modelling the write-through
        // would mean a place for `*e`, which the "places, not names" model
        // does not have (a place is a binding plus a field path, and a
        // referent is a different binding). Neither is a contained change, and
        // the language has not decided which meaning it wants. Refusing costs
        // a program that can be spelled with a fresh `let`.
        //
        // Scoped to an EMPTY path and to a borrow-producing value, so the two
        // legitimate neighbours survive: `buf.len = new_len` through an
        // `exclusive buf: Buffer` (a field write, and `examples/ownership.cell`
        // does it) and `e = B { n: 3 }` (a whole-value write-through, which
        // `runtime/cell_rt.h` section 7 defines and a codegen fix already
        // landed for). `borrowSource` is what tells those from a retarget, and
        // it is total: a value it cannot classify is refused too.
        if (place.path.len == 0 and self.holdsBorrow(b)) {
            switch (try self.borrowSource(&a.value)) {
                .not_borrow => {},
                .borrow => |s| {
                    try self.diagnostics.err(
                        self.allocator,
                        place.span,
                        try self.msg(
                            "cannot assign {s} to '{s}': it already holds a borrow, and rebinding one is not defined in this revision",
                            .{ s.display, place.display },
                        ),
                    );
                    try self.diagnostics.note(
                        self.allocator,
                        place.span,
                        "the C backend writes THROUGH the borrow rather than retargeting it, so the two readings of this statement differ; bind a new name instead",
                    );
                    try self.checkExpr(&a.value);
                    return;
                },
                .unresolved => |s| {
                    try self.diagnostics.err(
                        self.allocator,
                        place.span,
                        try self.msg(
                            "cannot assign to '{s}', which holds a borrow: {s} cannot be classified as a value or a borrow here",
                            .{ place.display, s.display },
                        ),
                    );
                    try self.diagnostics.note(
                        self.allocator,
                        place.span,
                        "R14 refuses what it cannot prove is not a borrow: a retarget the checker does not see leaves a loan on the old referent and none on the new one",
                    );
                    try self.checkExpr(&a.value);
                    return;
                },
            }
        }

        // R10, the assignment position: the same double free as the `let`
        // one, reached by writing into an already-declared `owned` place
        // instead of declaring a new one. Asked of the whole EXPRESSION's
        // verdict, so a value position and a call result are both refused.
        if (self.placeOwnership(b, place.path) == .owned) {
            if (try self.refuseArcUnique(
                try self.arcUniqueSource(&a.value),
                "assign",
                "to",
                "place",
                place.display,
            )) {
                self.revive(place);
                return;
            }
            // R2.b, the assignment position. Scoped to an `owned` TARGET,
            // because the double free needs the target to be dropped and
            // `pendingDrops` drops `.owned` bindings. Measured at `0e82266`:
            // `s2 = match c { 0 => s1, _ => s1 }` was exit 134.
            switch (try self.ownedMoveSource(&a.value)) {
                .unknown => |s| {
                    try self.refuseUnknownMove(s, "assign", "to", "place", place.display);
                    self.revive(place);
                    return;
                },
                // R7, the assignment position. Measured at `4698dbc`:
                // `match s1 { x => { d = x } }` into a `var owned d` was
                // exit 134.
                .aliases_place => |s| {
                    try self.refuseScrutineeAlias(s, "assign", "to", "place", place.display);
                    self.revive(place);
                    return;
                },
                // A place is moved by the shared path below, unchanged.
                .place, .no_owned_place => {},
            }
        }

        if (try self.placeOf(&a.value)) |src| {
            const note = try self.msg(
                "'{s}' was moved here by assigning it to '{s}'",
                .{ src.display, place.display },
            );
            try self.movePlace(src, note);
        } else {
            try self.checkExpr(&a.value);
        }

        // R3a: the target is live again.
        self.revive(place);
    }

    // ── expressions ─────────────────────────────────────────────────────

    fn checkExpr(self: *Checker, e: *const ast.Expr) Error!void {
        switch (e.kind) {
            .int, .float, .string, .bool => {},
            .ident, .field => {
                if (try self.placeOf(e)) |place| try self.readPlace(place);
            },
            .call => |*c| try self.checkCall(c, e.span),
            .binary => |*b| {
                try self.checkExpr(b.left);
                try self.checkExpr(b.right);
            },
            .unary => |*u| {
                if (u.op == .ref_shared or u.op == .ref_exclusive) {
                    const kind: LoanKind = if (u.op == .ref_exclusive) .exclusive else .shared;
                    if (try self.placeOf(u.operand)) |place| {
                        try self.createLoan(place, kind, false, null);
                        return;
                    }
                    // R9 in a VALUE position, which is axis 1 of R10's history
                    // repeating in a new rule: `createLoan` is the choke point
                    // for every exclusive loan, and a loan is only created for
                    // a PLACE, so `&mut fresh()` with `fresh() -> arc String`
                    // never reached it. Measured: accepted at exit 0, emitting
                    // `cell_grow(((cell_string_t *)&cell_fresh().ptr))`.
                    //
                    // That emit is LOUD, and loud for every type rather than
                    // by the coincidence of two C types: `cc` refuses to take
                    // the address of an rvalue. It is refused here anyway, on
                    // the argument `refuseArcUnique` already makes, that a
                    // rule which holds for every type beats one whose
                    // enforcement depends on what the backend happens to emit.
                    //
                    // `arcUniqueSource` is R10's classifier and answers the
                    // question both rules need here, "is this expression an
                    // `arc` handle", with a total verdict.
                    if (kind == .exclusive and try self.refuseArcValueBorrow(u.operand)) return;
                }
                try self.checkExpr(u.operand);
            },
            // R2's move list does not include struct or list literals, so
            // their elements are read rather than moved. See the report.
            .struct_lit => |*sl| {
                // R10, the struct-field position. Arc-to-owned conversion is
                // refused first. The resource-shape guard below separately
                // refuses shallow copies and unresolved transfers into owned
                // fields; moving such a field out was a live double free.
                const def = self.structs.get(sl.name);
                for (sl.fields) |*f| {
                    if (def) |d| {
                        if (findField(d, f.name)) |fld| {
                            if (fld.ownership == .owned) {
                                // Asked of the whole EXPRESSION's verdict, so
                                // a value position or a call result in a field
                                // is refused too.
                                if (try self.refuseArcUnique(
                                    try self.arcUniqueSource(&f.value),
                                    "store",
                                    "in",
                                    "field",
                                    f.name,
                                )) continue;
                                switch (try self.fieldResourceShape(&fld)) {
                                    .no_resources => switch (try self.ownedMoveSource(&f.value)) {
                                        .unknown => |s| {
                                            try self.refuseUnknownMove(s, "store", "in", "field", f.name);
                                            continue;
                                        },
                                        .aliases_place, .place, .no_owned_place => {},
                                    },
                                    .unknown => {
                                        try self.refuseOwnedFieldTransfer(
                                            .{ .display = "a value of unresolved resource shape", .span = f.value.span },
                                            f.name,
                                            "the destination field's resource shape cannot be resolved",
                                        );
                                        continue;
                                    },
                                    .resources => {
                                        switch (try self.borrowSource(&f.value)) {
                                            .not_borrow => {},
                                            .borrow => |s| {
                                                try self.refuseOwnedFieldTransfer(s, f.name, "a borrow does not transfer ownership");
                                                continue;
                                            },
                                            .unresolved => |s| {
                                                try self.refuseOwnedFieldTransfer(s, f.name, "the source cannot be proven to own a fresh value");
                                                continue;
                                            },
                                        }
                                        switch (try self.ownedMoveSource(&f.value)) {
                                            .no_owned_place => {},
                                            .place => |p| {
                                                try self.refuseOwnedFieldTransfer(
                                                    .{ .display = p.display, .span = p.span },
                                                    f.name,
                                                    "moving a place into an aggregate is not implemented",
                                                );
                                                continue;
                                            },
                                            .aliases_place, .unknown => |s| {
                                                try self.refuseOwnedFieldTransfer(s, f.name, "the source is not a fresh owned value");
                                                continue;
                                            },
                                        }
                                    },
                                }
                            }
                        }
                    }
                    try self.checkExpr(&f.value);
                }
            },
            // R10, the list-element position, and one of the two consumption
            // sites the four-position enumeration never asked at. A list
            // literal copies each element BY VALUE into a fresh buffer that
            // the list owns, so every element is made unique, and there is no
            // element-level annotation that could say otherwise. Measured
            // before this: `let owned zss: [[Int]] = [xs, xs]` with an
            // `arc [Int]` place passed `cell check` and compiled clean at
            // `-Wall -Wextra -Werror`, emitting the make-unique unbox at each
            // element. It is not a use-after-free TODAY only because slice
            // elements are never released, which is itself a disclosed gap;
            // closing that gap detonates this. Refused with the others rather
            // than left as a trap for that change.
            //
            // The refusal is context free, so it also refuses an `arc` element
            // in a list bound as `arc`. That over-refuses a program that is
            // safe today, and it is the safe direction: the buffer, not the
            // refcount, is what gets freed twice.
            .list_lit => |items| {
                for (items) |*item| {
                    if (try self.refuseArcUnique(
                        try self.arcUniqueSource(item),
                        "store",
                        "in",
                        "list element",
                        null,
                    )) continue;
                    // R2.b, the list-element position. `.unknown` ONLY, for
                    // the same reason as the struct field above: a plain place
                    // stays a READ, and it is not a use-after-free today only
                    // because slice elements are never released. That gap is
                    // disclosed in OWNERSHIP.md R11 and closing it is what
                    // decides whether this position moves; turning it into a
                    // move here, ahead of that, would leak instead.
                    switch (try self.ownedMoveSource(item)) {
                        .unknown => |s| {
                            try self.refuseUnknownMove(s, "store", "in", "list element", null);
                            continue;
                        },
                        // R7, and it READS here, for the same reason as the
                        // struct field above: `[x]` with an aliasing `x` and
                        // `[s1]` with the scrutinee are one gap, R11's
                        // element release, and neither is a double free today
                        // (measured at `4698dbc`, exit 0).
                        .aliases_place, .place, .no_owned_place => {},
                    }
                    try self.checkExpr(item);
                }
            },
            .block => |stmts| try self.checkBlockStmts(stmts),
            .if_expr => |*i| try self.checkIf(i),
            .match_expr => |*m| try self.checkMatch(m),
            .annotated => |a| try self.checkExpr(a.value),
        }
    }

    /// R0.3 exception 2: a borrow created in the condition ends when the `if`
    /// finishes, so the condition's temporary region wraps the branches too.
    ///
    /// Branches are merged conservatively: a place moved in any branch is dead
    /// afterwards, and a place revived in only one branch stays dead. That is
    /// the sound answer without a control-flow graph.
    fn checkIf(self: *Checker, i: *const @FieldType(ast.Expr.Kind, "if_expr")) Error!void {
        const region = self.temp_loans.items.len;
        defer self.temp_loans.shrinkRetainingCapacity(region);

        try self.checkExpr(i.cond);

        var entry = try self.dead.clone(self.allocator);
        defer entry.deinit(self.allocator);

        try self.checkExpr(i.then_body);
        var then_dead = try self.dead.clone(self.allocator);
        defer then_dead.deinit(self.allocator);

        self.dead.clearRetainingCapacity();
        try self.dead.appendSlice(self.allocator, entry.items);
        if (i.else_body) |else_body| {
            try self.checkExpr(else_body);
        }
        try self.unionDead(then_dead.items);
    }

    fn checkMatch(self: *Checker, m: *const @FieldType(ast.Expr.Kind, "match_expr")) Error!void {
        const region = self.temp_loans.items.len;
        defer self.temp_loans.shrinkRetainingCapacity(region);

        // R7 (a pattern binding inherits the scrutinee's ownership) is not
        // implemented, so the scrutinee is read, not moved. The arm binding is
        // therefore an ALIAS of whatever the scrutinee names, and consuming it
        // in an `owned` position is refused rather than moved: see
        // `ArmOrigin`, `ownedMoveSource`'s `.aliases_place`, and
        // `docs/OWNERSHIP.md` R7. Moving the scrutinee instead is the designed
        // follow-up and is NOT this change; it would alter `wasMoved` for
        // every arm binding, and codegen's `pendingDrops` reads that.
        try self.checkExpr(m.scrutinee);

        // The scrutinee's STRUCT TYPE, carried to an arm binding below. Not
        // R7, and it does not touch ownership: it is only what
        // `placeOwnership` needs one level down, so a field of an arm binding
        // has an annotation to read at all.
        //
        // Same reason as the borrow propagation in `checkLet`, found the same
        // way. R9's verdict is total, so an unreadable annotation REFUSES, and
        // an arm binding declared with `struct_name = null` made
        // `use_bytes(&mut x.data)` inside `match src { x => ... }` fail with
        // "the ownership of the field 'data' of 'x' cannot be resolved here".
        // Resolving it can only turn `.unresolved` into a verdict read off a
        // real annotation; it never turns silence into acceptance.
        const scrutinee_place = try self.placeOf(m.scrutinee);

        const scrutinee_struct: ?[]const u8 = blk: {
            const p = scrutinee_place orelse break :blk null;
            const sb = self.bindingById(p.binding) orelse break :blk null;
            break :blk self.placeStructName(sb, p.path);
        };

        // R7, and the ONE question this rule asks: does anything else still
        // own what the arm binding will name?
        //
        // A scrutinee with no place behind it -- a call result, a literal, a
        // fresh aggregate -- has no other owner, so the arm binding is the
        // only handle and consuming it is a move of a temporary. That row was
        // measured correct (`match make() { x => take(owned x) }`, exit 0) and
        // refusing it too would be over-refusal with nothing to show for it.
        //
        // A scrutinee that IS a place makes an alias, full stop. There is no
        // propagation, and the first version of this rule had one that was
        // WRONG in the dangerous direction.
        //
        // It read: a scrutinee that is exactly a whole `.temp` arm binding is
        // itself a temporary with no other owner, so
        // `match fresh() { x => match x { y => take(owned y) } }` may stay
        // accepted. That is sound about ONE consumer and false about two, and
        // nesting a `match` is the only construct in this grammar that makes
        // two live handles on one value: `let owned y = x` MOVES `x`, so R2
        // catches the `let` spelling, while an arm binding COPIES it and
        // nothing did. Measured against the propagating version:
        //
        //     match fresh() { x => match x { y => take(owned y) }
        //                                  + take(owned x) }      exit 134
        //
        // R2 cannot fire there, because `x` and `y` are two different bindings
        // with two different ids. The propagation bought exactly one contrived
        // single-consumer program and kept a live double free open to do it,
        // which is the wrong side of the asymmetry this file runs on. Removing
        // it costs a documented over-refusal of that program and closes the
        // class outright.
        const arm_origin: ArmOrigin = if (scrutinee_place == null) .temp else .alias;

        var entry = try self.dead.clone(self.allocator);
        defer entry.deinit(self.allocator);
        var merged = try self.dead.clone(self.allocator);
        defer merged.deinit(self.allocator);

        for (m.arms) |arm| {
            self.dead.clearRetainingCapacity();
            try self.dead.appendSlice(self.allocator, entry.items);

            try self.pushScope();
            // Arm bindings are declared so they shadow rather than resolve to
            // an outer binding of the same name.
            if (arm.pattern.kind == .binding) {
                _ = try self.declare(.{
                    .id = 0,
                    .name = arm.pattern.kind.binding,
                    .ownership = .owned,
                    .mutable = false,
                    .struct_name = scrutinee_struct,
                    .decl_span = arm.pattern.span,
                    .arm_origin = arm_origin,
                    .arm_scrutinee = if (scrutinee_place) |p| p.display else null,
                });
            }
            try self.checkExpr(arm.body);
            self.popScope();

            for (self.dead.items) |d| {
                if (!containsDead(merged.items, d)) {
                    try merged.append(self.allocator, d);
                }
            }
        }

        self.dead.clearRetainingCapacity();
        try self.dead.appendSlice(self.allocator, merged.items);
    }

    fn unionDead(self: *Checker, other: []const Dead) Error!void {
        for (other) |d| {
            if (!containsDead(self.dead.items, d)) {
                try self.dead.append(self.allocator, d);
            }
        }
    }

    // ── calls: R1, R2, R3, R4, R5, R15 ──────────────────────────────────

    fn checkCall(
        self: *Checker,
        c: *const @FieldType(ast.Expr.Kind, "call"),
        span: Span,
    ) Error!void {
        _ = span;
        const callee_name: ?[]const u8 = switch (c.callee.kind) {
            .ident => |n| n,
            else => null,
        };
        const sig: ?ast.FnDef = if (callee_name) |n| self.fns.get(n) else null;
        if (callee_name == null) try self.checkExpr(c.callee);

        for (c.args, 0..) |*arg, idx| {
            const param: ?ast.Param = if (sig) |s|
                (if (idx < s.params.len) s.params[idx] else null)
            else
                null;

            // R15. A keyword prefix on the argument is the written mode.
            // `&x` / `&mut x` are the same check when no keyword was written.
            // Do not overwrite a keyword with an inner sigil: `owned &buf`
            // is still passed as owned. Always peel to the place inside.
            var explicit: ?Ownership = null;
            var operand: *const ast.Expr = arg;
            if (arg.kind == .annotated) {
                explicit = arg.kind.annotated.ownership;
                operand = arg.kind.annotated.value;
            }
            if (refKind(arg)) |r| {
                if (explicit == null) {
                    explicit = if (r.kind == .exclusive) .exclusive else .shared;
                }
                operand = r.operand;
            }
            if (explicit) |ex| {
                if (param) |p| {
                    if (ex != p.ownership) {
                        try self.diagnostics.err(
                            self.allocator,
                            arg.span,
                            try self.msg(
                                "'{s}' expects parameter '{s}' as '{s}', but the argument is passed as '{s}'",
                                .{ callee_name.?, p.name, @tagName(p.ownership), @tagName(ex) },
                            ),
                        );
                        continue;
                    }
                }
            }

            // R1: an omitted annotation takes the parameter's mode, so a bare
            // argument to an `owned` parameter moves.
            const mode: ?Ownership = explicit orelse if (param) |p| p.ownership else null;

            // R10, the call-argument position, asked on the EXPRESSION and
            // asked BEFORE the place check below. It has to be before it:
            // `placeOf` returns null for a `match`, and the early exit under
            // it is exactly how `take(owned match c { 0 => xs, _ => xs })`
            // escaped a rule that refuses `take(owned xs)`.
            if (mode == .owned) {
                const slot_name = if (param) |p| p.name else null;
                if (try self.refuseArcUnique(
                    try self.arcUniqueSource(operand),
                    "pass",
                    "to",
                    "parameter",
                    slot_name,
                )) continue;
                // R2.b, the call-argument position, and one of the two live
                // sites the brief that opened this rule did not name. Asked
                // on the peeled `operand` and BEFORE the place check below,
                // for the same reason R10's is: `placeOf` returns null for a
                // `match`, and the early exit under it is exactly how the
                // value shapes escaped. Measured at `0e82266`:
                // `take(owned match c { 0 => s1, _ => s1 })` was exit 134.
                switch (try self.ownedMoveSource(operand)) {
                    .unknown => |s| {
                        try self.refuseUnknownMove(s, "pass", "to", "parameter", slot_name);
                        continue;
                    },
                    // R7, the call-argument position: the reproducer.
                    // Measured at `4698dbc`,
                    // `print_int(match s1 { x => take(owned x) })` was
                    // `cell check` exit 0, `cc` exit 0, running it exit 134.
                    // It also closes an R10 escape at the same site, because
                    // `arcUniqueSource` reads the arm binding's own `.owned`
                    // annotation and cannot see the scrutinee's `arc`:
                    // `match a { x => take_list(owned x) }` over an
                    // `arc [Int]` place was exit 134 while `take_list(owned a)`
                    // was already refused.
                    .aliases_place => |s| {
                        try self.refuseScrutineeAlias(s, "pass", "to", "parameter", slot_name);
                        continue;
                    },
                    // A place is moved by the `.owned` arm below, unchanged.
                    .place, .no_owned_place => {},
                }
            }

            const place = try self.placeOf(operand);
            if (place == null) {
                // R9 in a value position. `checkCall` peels the `&mut` itself
                // and hands `checkExpr` the operand, so the unary arm's copy
                // of this check never sees a call argument. See
                // `refuseArcValueBorrow`.
                if (mode == .exclusive and try self.refuseArcValueBorrow(operand)) continue;
                try self.checkExpr(operand);
                continue;
            }
            const m = mode orelse {
                // Unknown callee: no signature, so nothing can be inferred.
                // Treat the argument as a read rather than invent a move.
                try self.readPlace(place.?);
                continue;
            };
            switch (m) {
                .owned => {
                    // R10: an `arc` place may not be passed to an `owned`
                    // parameter. This is the one clause of R10 that is
                    // implemented, and it is here rather than in codegen
                    // because codegen cannot refuse it: `owned [T]` and
                    // `shared [T]` are the SAME C type (`cell_slice_t` by
                    // value), so the emitted unbox
                    // `take((*(const cell_slice_t *)xs.ptr))` compiles clean
                    // and is a double free of the BUFFER. `cell_rt.h`
                    // section 7 makes an `owned` callee responsible for the
                    // eventual free, and `cell_slice_drop_glue` frees the
                    // same buffer again when the box dies. A retain cannot
                    // help: `cell_arc_clone` increments a refcount, and the
                    // buffer is not what the refcount governs.
                    //
                    // The `arc` case already `continue`d above, on the
                    // expression rather than on the place.
                    const note = if (callee_name) |n|
                        try self.msg(
                            "'{s}' was moved here by the call to '{s}'",
                            .{ place.?.display, n },
                        )
                    else
                        try self.msg("'{s}' was moved here by the call", .{place.?.display});
                    try self.movePlace(place.?, note);
                },
                .shared, .exclusive => {
                    const kind: LoanKind = if (m == .exclusive) .exclusive else .shared;
                    try self.createLoan(place.?, kind, false, null);
                },
                // R10 and R12 are not implemented; an `arc` or `copy`
                // argument neither moves nor borrows.
                .arc, .copy => try self.readPlace(place.?),
            }
        }
    }

    // ── the four primitive operations on a place ────────────────────────

    /// R2 and R5: reading a place that is dead, or that is exclusively
    /// borrowed, is an error.
    fn readPlace(self: *Checker, place: Place) Error!void {
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
    fn movePlace(self: *Checker, place: Place, note: []const u8) Error!void {
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
    }

    /// R4, R5 and R6. `lexical` selects the loan's scope: true for a loan
    /// bound to a name, false for one that dies with its statement or `if`.
    fn createLoan(
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

    /// R3a: assigning to a place revives it and everything under it.
    fn revive(self: *Checker, place: Place) void {
        var i: usize = 0;
        while (i < self.dead.items.len) {
            const d = self.dead.items[i];
            if (d.binding == place.binding and pathPrefix(place.path, d.path)) {
                _ = self.dead.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    // ── queries ─────────────────────────────────────────────────────────

    /// The dead place overlapping `place`, in either direction: reading
    /// `buf.len` after `buf` moved is an error, and so is reading `buf` after
    /// `buf.data` moved.
    fn findDead(self: *const Checker, place: Place) ?Dead {
        for (self.dead.items) |d| {
            if (d.binding != place.binding) continue;
            if (pathPrefix(d.path, place.path) or pathPrefix(place.path, d.path)) return d;
        }
        return null;
    }

    /// A dead place that strictly contains `place`, used to tell a write into
    /// a moved-out value from the revival of R3a.
    fn deadStrictPrefixOf(self: *const Checker, place: Place) ?Dead {
        for (self.dead.items) |d| {
            if (d.binding != place.binding) continue;
            if (d.path.len < place.path.len and pathPrefix(d.path, place.path)) return d;
        }
        return null;
    }

    /// Whether `loan` conflicts with taking `kind` on `place`, ignoring
    /// whether the loan is still live. Shared against shared never conflicts
    /// (R4); everything else does. `findBlockingLoan` adds the liveness half.
    fn loanConflicts(loan: Loan, place: Place, kind: LoanKind) bool {
        if (loan.binding != place.binding) return false;
        // R6: disjoint field paths never conflict.
        if (!pathPrefix(loan.path, place.path) and !pathPrefix(place.path, loan.path)) return false;
        if (loan.kind == .shared and kind == .shared) return false;
        return true;
    }

    /// What R10 needs to know about an expression that is about to be
    /// consumed in an `owned` position, which is to say made UNIQUE.
    ///
    /// **The verdict is total, and the totality is the whole point.** This
    /// used to be `Error!?Place`, so every expression form the classifier did
    /// not recognise as `arc` came back `null` and was PERMITTED. That makes
    /// silence mean "safe", and silence is exactly what an unenumerated form
    /// produces. Here silence is `.unknown`, which is REFUSED. Acceptance is
    /// the direction that needs proof: a refusal costs a program that can be
    /// spelled another way, an acceptance costs a double free.
    const ArcSource = union(enum) {
        /// Provably not `arc`. Every arm that returns this states why.
        not_arc,
        /// An `arc` place. Nameable, so the diagnostic names it.
        arc_place: Site,
        /// `arc` with no place behind it: a call whose declared return type is
        /// `arc`. The caller's temporary drops that box, so making its pointee
        /// unique frees the same buffer twice.
        arc_value: Site,
        /// Ownership could not be decided here. Refused, not permitted.
        unknown: Site,

        const Site = struct {
            /// For `arc_place` and `arc_value`, a name the message quotes.
            /// For `unknown`, a noun phrase the message does not quote.
            display: []const u8,
            span: Span,
        };

        /// Combine two branch verdicts. An `arc` verdict from any branch wins,
        /// because any branch may be the one taken; otherwise an `unknown`
        /// wins over `not_arc` for the same reason.
        fn join(a: ArcSource, b: ArcSource) ArcSource {
            return switch (a) {
                .arc_place => a,
                .arc_value => switch (b) {
                    .arc_place => b,
                    else => a,
                },
                .unknown => switch (b) {
                    .arc_place, .arc_value => b,
                    else => a,
                },
                .not_arc => b,
            };
        }
    };

    /// Classify what an `owned` position would make unique. **One function,
    /// used by all six of R10's consumption sites**, rather than a seventh
    /// copy of the question at a seventh call site.
    ///
    /// WHY IT EXISTS, and the three axes it has now been widened along. R10's
    /// refusal was first spelled as `placeOf(e)` followed by an `arc` test, at
    /// each position separately, which asks only whether the expression IS an
    /// `arc` place.
    ///
    /// 1. **Expression shape**, place versus value. A `match` is valued and is
    ///    not a place, so `placeOf` returned null and all four positions let
    ///    it through: `take(owned xs)` was refused while
    ///    `take(owned match c { 0 => xs, _ => xs })` was accepted, for the
    ///    same binding and the same semantic operation. Closed by looking
    ///    THROUGH the value positions. Measured at `23353e9^`: the emitted C
    ///    unboxed the arc into an `owned` parameter, and it was masked rather
    ///    than crashing, because the `cell_arc_clone` in the value temporary
    ///    was never released.
    /// 2. **Arc source**, a binding's annotation versus a signature's return
    ///    type. `take(owned fresh())` with `fresh() -> arc [Int]` was accepted
    ///    because no place and no expression shape carries the `arc`-ness.
    ///    That one was NOT masked: `460b9a3` gave the unbound call temporary
    ///    its `cell_arc_drop`, so from that commit onward it was an
    ///    AddressSanitizer double free at exit 134, seven commits before the
    ///    axis-1 fix claimed to be landing ahead of any such change. Closed by
    ///    `.call` reading the callee's return type.
    /// 3. **Consumption site.** Four positions were enumerated and a property
    ///    of every consumption asserted. A list-literal element and a `return`
    ///    are consumptions that were never asked. Closed by asking at both.
    ///
    /// THE SHAPE OF THE MISS, since every one of the three is the same shape:
    /// a derivation that enumerated some forms of a construct and asserted a
    /// property of all of them. The structural answer is not a longer
    /// enumeration, it is a verdict with no permissive default, which is what
    /// `.unknown` is.
    ///
    /// The switch is exhaustive with no `else` arm, and it is exhaustive over
    /// the FIELDS of each variant it descends into, not only over the variants
    /// themselves: a `match` visits every arm, an `if` visits both branches, a
    /// `unary` splits on its operator. Those are different claims, and
    /// treating them as one is what hid a match GUARD from `exprUsesName` in
    /// this same file.
    ///
    /// `if` and `block` cannot reach a typed `owned` position today, because
    /// typecheck gives both the type `()`. They are handled anyway: an
    /// ownership rule enforced by an accident of the type checker is exactly
    /// the fragility R10's own text objects to elsewhere, and borrowck runs
    /// independently of typecheck, so its own tests reach them.
    fn arcUniqueSource(self: *Checker, e: *const ast.Expr) Error!ArcSource {
        if (try self.placeOf(e)) |place| {
            const site: ArcSource.Site = .{ .display = place.display, .span = place.span };
            const unresolved: ArcSource = .{ .unknown = .{
                .display = try self.msg("the place '{s}'", .{place.display}),
                .span = place.span,
            } };
            const b = self.bindingById(place.binding) orelse
                // A place whose binding id does not resolve. It should not
                // happen, and if it does the annotation is unreadable.
                return unresolved;
            const own = self.placeOwnership(b, place.path) orelse
                // A field path whose struct type could not be resolved, so the
                // annotation that decides this was never read. `checkLet`
                // infers that type from a declared type, a struct literal and
                // a call's return type; a `match` or block initializer in an
                // unannotated `let` still lands here.
                return unresolved;
            if (own == .arc) return .{ .arc_place = site };
            // A place with a declared, resolved, non-`arc` annotation. It is
            // still a place, so there is no value position underneath it.
            return .not_arc;
        }
        return switch (e.kind) {
            // A scalar or string literal is a fresh value with no handle
            // behind it. `arc` is a property of a binding or a signature, and
            // a literal has neither.
            .int, .float, .string, .bool => .not_arc,
            // A struct or list literal constructs a fresh record or buffer.
            // Whatever its ELEMENTS are is the list-literal site's question,
            // asked there; the literal itself is unique by construction.
            .struct_lit, .list_lit => .not_arc,
            // Every binary operator in this grammar is arithmetic, comparison
            // or logic, and yields a fresh scalar.
            .binary => .not_arc,
            .unary => |u| switch (u.op) {
                // A fresh scalar.
                .neg, .not => .not_arc,
                // A borrow. The value is a reference to the pointee and not
                // an `arc` handle, so it cannot be the thing a box frees
                // twice. Consuming a borrow in an `owned` position is R15's
                // annotation disagreement and R9's mutation rule, not R10's.
                .ref_shared, .ref_exclusive => .not_arc,
            },
            .call => |c| try self.arcCallResult(c.callee, e.span),
            .annotated => |a| try self.arcUniqueSource(a.value),
            // An `ident` reaching here means `lookup` failed: the name is not
            // in scope, so nothing decides its ownership.
            .ident => |n| .{ .unknown = .{
                .display = try self.msg("the unresolved name '{s}'", .{n}),
                .span = e.span,
            } },
            // A `field` reaching here is rooted at something that is not a
            // binding. Two very different things wear that shape, and the
            // first was found by the gate rather than by reasoning:
            //
            //   * `Quadrant.First`, a qualified ENUM VARIANT. The base names a
            //     type, not a binding, so `placeOf` fails. A variant in this
            //     grammar carries no payload (see ast.Pattern's comment), so
            //     it is a unit constant and can never be an `arc` box.
            //   * `fresh().len`, a field of a temporary. The base's ownership
            //     was not resolved, so neither is the field's.
            .field => |f| blk: {
                if (f.base.kind == .ident and
                    self.enums.contains(f.base.kind.ident)) break :blk .not_arc;
                break :blk .{ .unknown = .{
                    .display = try self.msg("the field '{s}' of a temporary value", .{f.name}),
                    .span = e.span,
                } };
            },
            .if_expr => |i| blk: {
                const then_v = try self.arcUniqueSource(i.then_body);
                // A missing `else` yields unit on that path, which is not
                // `arc` and is not unknown.
                const else_v: ArcSource = if (i.else_body) |eb|
                    try self.arcUniqueSource(eb)
                else
                    .not_arc;
                break :blk ArcSource.join(then_v, else_v);
            },
            .match_expr => |m| blk: {
                var acc: ArcSource = .not_arc;
                for (m.arms) |arm| {
                    acc = ArcSource.join(acc, try self.arcUniqueSource(arm.body));
                }
                break :blk acc;
            },
            // A block's value is its trailing expression statement. A block
            // that ends in anything else (or in nothing) yields unit.
            .block => |stmts| blk: {
                if (stmts.len == 0) break :blk .not_arc;
                const last = &stmts[stmts.len - 1];
                if (last.kind != .expr) break :blk .not_arc;
                break :blk try self.arcUniqueSource(&last.kind.expr);
            },
        };
    }

    /// R10 axis 2: the `arc`-ness of a CALL RESULT, which comes from the
    /// callee's declared return type rather than from any binding annotation.
    ///
    /// `-> arc [Int]` parses as `TypeExpr.ref` with `.arc` ownership, the same
    /// node `typeIsBorrow` reads for `shared` and `exclusive`. A call whose
    /// return type is `arc` hands back a box the caller's temporary will
    /// `cell_arc_drop`; unboxing that temporary into an `owned` position hands
    /// the same buffer to a holder that frees it, and the glue frees it again.
    ///
    /// A callee this checker cannot resolve is `.unknown` and therefore
    /// refused. `cell check` already errors on an unknown callee in the
    /// typechecker, so no program that was otherwise accepted is lost; what is
    /// gained is that a future indirect-call form does not silently inherit a
    /// permissive default.
    fn arcCallResult(self: *Checker, callee: *const ast.Expr, span: Span) Error!ArcSource {
        const name: []const u8 = switch (callee.kind) {
            .ident => |n| n,
            else => return .{ .unknown = .{
                .display = "the result of an indirect call",
                .span = span,
            } },
        };
        const sig = self.fns.get(name) orelse return .{ .unknown = .{
            .display = try self.msg("the result of the unresolved callee '{s}'", .{name}),
            .span = span,
        } };
        const rt = sig.return_type orelse
            // No declared return type: the call yields unit, and unit is not
            // an `arc` box.
            return .not_arc;
        const is_arc = switch (rt) {
            .ref => |r| r.ownership == .arc,
            // A plain, optional, list or result type carries no ownership
            // prefix, so R1 makes it `owned`.
            .name, .optional, .list, .result, .unit => false,
        };
        if (!is_arc) return .not_arc;
        return .{ .arc_value = .{
            .display = try self.msg("{s}()", .{name}),
            .span = span,
        } };
    }

    /// R2.b: what an `owned` consumption position takes ownership OF.
    ///
    /// **The verdict is total, for the same reason `ArcSource`'s is and after
    /// the same defect.** R2 enumerates the forms that MOVE a place, and every
    /// one of its consumption sites asked `placeOf` first: a place moved, and
    /// anything else fell through to `checkExpr`, which only READS. That is an
    /// enumeration of PLACE initializers standing in for a claim about every
    /// initializer, which is R10 axis 1 recurring in the rule R10 is a special
    /// case of. `placeOf` returns null for a `match`, so
    ///
    ///     let owned s2: String = match c { 0 => s1, _ => s1 }
    ///
    /// read `s1` instead of moving it. `wasMoved(s1)` stayed false, codegen's
    /// `pendingDrops` therefore dropped BOTH `s1` and `s2`, and the leaf
    /// emitted a bitwise `_cell_t0 = s1;` so the two headers hold one buffer:
    /// `cell check` exit 0, `cc -fsanitize=address` exit 0, running it exit
    /// 134, `AddressSanitizer: attempting double-free`. Measured at
    /// `0e82266` at four sites, all four live.
    ///
    /// **Silence must not mean "read it".** `.unknown` is REFUSED. A shape
    /// nobody enumerated is exactly what produces silence here, and the cost
    /// of the two directions is not symmetric: a refusal costs a program that
    /// can be spelled with an explicit binding, an acceptance costs a double
    /// free.
    ///
    /// **A place reached THROUGH a branch is never `.place`.** Promoting it to
    /// a move is the wrong repair and is not available: a `match` yielding a
    /// place from two arms is two potential moves of one value, and deciding
    /// which one happened is the dataflow question `docs/OWNERSHIP.md` 0.3
    /// deliberately does not answer. `ownedMoveBranch` performs that promotion
    /// to `.unknown`, so no recursive arm can hand a movable place back up.
    ///
    /// The switch is exhaustive with no `else` arm, and exhaustive over the
    /// FIELDS of each variant it descends into rather than only over the
    /// variants: a `match` visits every arm, an `if` visits both branches, a
    /// `unary` splits on its operator. Those are different claims and treating
    /// them as one is what hid a match GUARD from `exprUsesName` in this file.
    const OwnedMove = union(enum) {
        /// Provably hands over no place an existing binding still holds: a
        /// literal, a fresh scalar, a borrow, a fresh aggregate, or a call's
        /// temporary. Every arm that returns this states why.
        no_owned_place,
        /// The expression IS a place. Moved, exactly as before this rule
        /// existed. This is the ONLY verdict that moves, and it is reachable
        /// only from the top of `ownedMoveSource`, never from a branch.
        place: Place,
        /// A value shape that may give up an owned place, on a path this
        /// checker does not resolve. Refused, not read.
        unknown: ArcSource.Site,
        /// **R7.** The expression is a place rooted at a match-arm binding
        /// that ALIASES a scrutinee place. Consuming it hands over a buffer
        /// the scrutinee's own drop frees again, because R7 does not move the
        /// scrutinee. Refused at every site that would MOVE a `.place`, and
        /// read at the two sites that already only read one.
        ///
        /// A separate variant rather than a reuse of `.unknown` on purpose:
        /// this switch has no `else` arm anywhere it is consumed, so adding it
        /// made every consumption site a compile error until it answered. That
        /// is the enumeration done by the compiler instead of by the author,
        /// which is the failure mode this file has hit four times.
        aliases_place: ArcSource.Site,

        /// Combine two branch verdicts. `.unknown` from any branch wins,
        /// because any branch may be the one taken.
        ///
        /// `.place` cannot appear on either side: every recursive call in a
        /// branch position goes through `ownedMoveBranch`, which promotes it.
        /// It is still handled rather than left to an `else`, and it is
        /// handled by REFUSING to let it out, so that if a future arm forgets
        /// the promotion the result is an over-refusal and not a move the
        /// caller cannot justify.
        fn join(a: OwnedMove, b: OwnedMove) OwnedMove {
            return switch (a) {
                // `.aliases_place` joins with `.unknown` and `.place`: all
                // three are verdicts a branch must not hand back as movable,
                // and letting one win is the over-refusing direction.
                .unknown, .place, .aliases_place => a,
                .no_owned_place => b,
            };
        }
    };

    /// `ownedMoveSource` in a BRANCH position, where a place is not movable.
    /// See `OwnedMove`'s comment for why the promotion is the fix and a move
    /// is not.
    fn ownedMoveBranch(self: *Checker, e: *const ast.Expr) Error!OwnedMove {
        return switch (try self.ownedMoveSource(e)) {
            .no_owned_place => .no_owned_place,
            .place => |p| .{ .unknown = .{
                .display = try self.msg("the place '{s}' reached through a branch", .{p.display}),
                .span = p.span,
            } },
            .unknown => |s| .{ .unknown = s },
            // Promoted to `.unknown` for the same reason `.place` is: the two
            // sites that read a `.place` rather than moving it must not start
            // reading one reached through a branch either, and `.unknown` is
            // the verdict every site already refuses. The display already
            // names the arm binding and its scrutinee, so nothing is lost.
            .aliases_place => |s| .{ .unknown = s },
        };
    }

    /// R7's one question, asked once, at the single point every `owned`
    /// consumption site routes through. See `OwnedMove.aliases_place`.
    ///
    /// It sits above the `.place` return rather than beside it because a
    /// place rooted at an aliasing arm binding IS a place: `placeOf` resolves
    /// it, R2's move list covers it, and moving it is exactly the defect.
    /// Asking here means a consumption site added later inherits the answer
    /// without knowing R7 exists.
    fn armAlias(self: *Checker, place: Place) Error!?ArcSource.Site {
        const b = self.bindingById(place.binding) orelse return null;
        switch (b.arm_origin) {
            .not_an_arm, .temp => return null,
            .alias => {},
        }
        const scrutinee = b.arm_scrutinee orelse "the scrutinee";
        return .{
            .display = try self.msg(
                "the match binding '{s}' aliasing '{s}'",
                .{ place.display, scrutinee },
            ),
            .span = place.span,
        };
    }

    fn ownedMoveSource(self: *Checker, e: *const ast.Expr) Error!OwnedMove {
        if (try self.placeOf(e)) |place| {
            if (try self.armAlias(place)) |site| return .{ .aliases_place = site };
            return .{ .place = place };
        }
        return switch (e.kind) {
            // A literal is a fresh value with no binding behind it.
            .int, .float, .string, .bool => .no_owned_place,
            // Every binary operator in this grammar is arithmetic, comparison
            // or logic, and yields a fresh scalar.
            .binary => .no_owned_place,
            .unary => |u| switch (u.op) {
                // A fresh scalar.
                .neg, .not => .no_owned_place,
                // A borrow does not own its referent, so consuming it hands
                // over nothing that a drop would free twice. Consuming a
                // borrow in an `owned` position is R18 at a `let`, R3's
                // move-out-of-a-borrow at a move, and R15's annotation
                // disagreement at a call; all three run elsewhere and none of
                // them is this question.
                //
                // CORRECTED: this comment used to name only R3 and R15 and
                // say "both of which run elsewhere". At the `let` position
                // nothing ran, and that sentence is exactly the assumption
                // the double free lived in. R18 is the check that now does.
                .ref_shared, .ref_exclusive => .no_owned_place,
            },
            // A struct or list literal builds a FRESH record or buffer, so the
            // aggregate itself gives up nothing. What its elements give up is
            // the element sites' question, asked there.
            .struct_lit, .list_lit => .no_owned_place,
            // A call's result is a temporary the callee produced, not a place
            // the caller still holds.
            .call => .no_owned_place,
            // `placeOf` already peels `.annotated`, so reaching here means the
            // operand is not a place: `owned mk()` is the call arm above and
            // `owned match ...` is the match arm below. Recursing therefore
            // adds no move that `placeOf` was not already making, which
            // matters because a NEW move would change what codegen's
            // `pendingDrops` frees. Measured at `0e82266`:
            // `let owned s2: String = owned s1` already reports use-after-move
            // on `s1`, and `owned match c { 0 => s1, _ => s1 }` was exit 134.
            .annotated => |a| try self.ownedMoveSource(a.value),
            // An `ident` reaching here means `lookup` failed: the name is not
            // in scope, so nothing decides what it owns.
            .ident => |n| .{ .unknown = .{
                .display = try self.msg("the unresolved name '{s}'", .{n}),
                .span = e.span,
            } },
            // A `field` reaching here is rooted at something that is not a
            // binding. Two different things wear that shape, as
            // `arcUniqueSource` records:
            //
            //   * `Quadrant.First`, a qualified ENUM VARIANT. A variant in
            //     this grammar carries no payload, so it is a unit constant
            //     and owns nothing.
            //   * `mk_box().s`, a field of a temporary. Which place that
            //     temporary's field came from is not resolved here.
            .field => |f| blk: {
                if (f.base.kind == .ident and
                    self.enums.contains(f.base.kind.ident)) break :blk .no_owned_place;
                break :blk .{ .unknown = .{
                    .display = try self.msg("the field '{s}' of a temporary value", .{f.name}),
                    .span = e.span,
                } };
            },
            .if_expr => |i| blk: {
                const then_v = try self.ownedMoveBranch(i.then_body);
                // A missing `else` yields unit on that path, which owns
                // nothing and is not unknown.
                const else_v: OwnedMove = if (i.else_body) |eb|
                    try self.ownedMoveBranch(eb)
                else
                    .no_owned_place;
                break :blk OwnedMove.join(then_v, else_v);
            },
            .match_expr => |m| blk: {
                var acc: OwnedMove = .no_owned_place;
                for (m.arms) |arm| {
                    acc = OwnedMove.join(acc, try self.ownedMoveBranch(arm.body));
                }
                break :blk acc;
            },
            // A block's value is its trailing expression statement. A block
            // that ends in anything else, or in nothing, yields unit.
            .block => |stmts| blk: {
                if (stmts.len == 0) break :blk .no_owned_place;
                const last = &stmts[stmts.len - 1];
                if (last.kind != .expr) break :blk .no_owned_place;
                break :blk try self.ownedMoveBranch(&last.kind.expr);
            },
        };
    }

    /// R2.b's refusal. `verb`, `prep` and `slot` name the position, so all six
    /// consumption sites read as the same rule, the way `refuseArcUnique`'s do.
    ///
    /// It is a refusal and not a move, and that is not a conservative default
    /// chosen for taste. Moving would require deciding which path produced the
    /// value, and `docs/OWNERSHIP.md` 0.3 chose a checker with no control-flow
    /// graph. Reading, which is what happened before this rule, is the one
    /// answer that is definitely wrong: the source is dropped at its scope end
    /// and the consumer frees the same buffer.
    fn refuseUnknownMove(
        self: *Checker,
        s: ArcSource.Site,
        verb: []const u8,
        prep: []const u8,
        slot: []const u8,
        slot_name: ?[]const u8,
    ) Error!void {
        const message = if (slot_name) |n|
            try self.msg(
                "cannot {s} {s} {s} 'owned' {s} '{s}': which owned place it gives up cannot be resolved here",
                .{ verb, s.display, prep, slot, n },
            )
        else
            try self.msg(
                "cannot {s} {s} {s} an 'owned' {s}: which owned place it gives up cannot be resolved here",
                .{ verb, s.display, prep, slot },
            );
        try self.diagnostics.err(self.allocator, s.span, message);
        try self.diagnostics.note(
            self.allocator,
            s.span,
            "R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path",
        );
    }

    /// R7's refusal. Its own function and not `refuseUnknownMove`, because
    /// that one's note tells the reader to "bind the value to a name first",
    /// and here the name IS the problem: the arm binding is the alias.
    ///
    /// It is a refusal and not a move of the scrutinee, and that is a scoped
    /// decision rather than the end state. Moving the scrutinee is the better
    /// semantics and would additionally make a later `take(owned s1)` report
    /// use-after-move for the right reason; it is recorded as the designed
    /// follow-up in `docs/OWNERSHIP.md` R7. It is not done here because it
    /// changes `wasMoved` for every arm binding and codegen's `pendingDrops`
    /// reads that, which is the exact shape of the three fixes in this
    /// repository that each shipped a new silent miscompile in their own first
    /// commit.
    fn refuseScrutineeAlias(
        self: *Checker,
        s: ArcSource.Site,
        verb: []const u8,
        prep: []const u8,
        slot: []const u8,
        slot_name: ?[]const u8,
    ) Error!void {
        const message = if (slot_name) |n|
            try self.msg(
                "cannot {s} {s} {s} 'owned' {s} '{s}': the scrutinee still owns the value",
                .{ verb, s.display, prep, slot, n },
            )
        else
            try self.msg(
                "cannot {s} {s} {s} an 'owned' {s}: the scrutinee still owns the value",
                .{ verb, s.display, prep, slot },
            );
        try self.diagnostics.err(self.allocator, s.span, message);
        try self.diagnostics.note(
            self.allocator,
            s.span,
            "R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again",
        );
    }

    /// R10: an `arc` place may not be made unique. `verb` and `slot` name the
    /// position, so every one of them reads as the same rule.
    ///
    /// It is a REFUSAL and not a retain, and that is not a stylistic call.
    /// `owned [T]` and `shared [T]` lower to the SAME C type (`cell_slice_t`
    /// by value), so the C backend's unbox compiles clean at
    /// `-Wall -Wextra -Werror` and then `runtime/cell_rt.h` section 7 makes
    /// the `owned` holder free the buffer while `cell_slice_drop_glue` frees
    /// the same buffer again when the box dies. `cell_arc_clone` increments a
    /// refcount, and the buffer is not what the refcount governs, so no
    /// retain can fix it. Measured as an AddressSanitizer double free at the
    /// parameter, `let` and assignment positions alike.
    ///
    /// The `owned String` analogue is a loud C type error instead, because
    /// `owned String` and `shared String` do NOT share a C type. Refusing it
    /// here too is deliberate: one rule that holds for every type beats a
    /// rule whose enforcement depends on which two C types happen to
    /// coincide.
    /// Returns true when it refused, so the caller can stop treating the
    /// expression as an ordinary move. `.not_arc` is the ONLY verdict that
    /// passes; `.unknown` is refused with its own wording, so a reader can
    /// tell "this is `arc`" from "this could not be proven not to be".
    fn refuseArcUnique(
        self: *Checker,
        src: ArcSource,
        verb: []const u8,
        prep: []const u8,
        slot: []const u8,
        slot_name: ?[]const u8,
    ) Error!bool {
        switch (src) {
            .not_arc => return false,
            .arc_place, .arc_value => |s| {
                const message = if (slot_name) |n|
                    try self.msg(
                        "cannot {s} 'arc' value '{s}' {s} 'owned' {s} '{s}': ownership is shared and cannot be made unique",
                        .{ verb, s.display, prep, slot, n },
                    )
                else
                    try self.msg(
                        "cannot {s} 'arc' value '{s}' {s} an 'owned' {s}: ownership is shared and cannot be made unique",
                        .{ verb, s.display, prep, slot },
                    );
                try self.diagnostics.err(self.allocator, s.span, message);
                try self.diagnostics.note(
                    self.allocator,
                    s.span,
                    "an 'owned' holder frees the value, and the 'arc' box would free it again",
                );
            },
            .unknown => |s| {
                const message = if (slot_name) |n|
                    try self.msg(
                        "cannot {s} {s} {s} 'owned' {s} '{s}': its ownership cannot be resolved here",
                        .{ verb, s.display, prep, slot, n },
                    )
                else
                    try self.msg(
                        "cannot {s} {s} {s} an 'owned' {s}: its ownership cannot be resolved here",
                        .{ verb, s.display, prep, slot },
                    );
                try self.diagnostics.err(self.allocator, s.span, message);
                try self.diagnostics.note(
                    self.allocator,
                    s.span,
                    "R10 refuses what it cannot prove is not 'arc': an 'arc' value made unique is freed twice",
                );
            },
        }
        return true;
    }

    /// R9: what an `exclusive` borrow of, or a write through, a place would
    /// reach. The verdict is TOTAL for the same reason `ArcSource`'s is: a
    /// step whose annotation cannot be read is `.unresolved` and is REFUSED,
    /// not permitted. Silence must not mean safe.
    const ArcReach = union(enum) {
        /// Every step this depth asked about has a resolved, non-`arc`
        /// annotation.
        not_arc,
        /// A step is `arc`. `display` names that step, which is the whole
        /// place for a bare binding and a strict prefix for a field path.
        arc: ArcSource.Site,
        /// A step's annotation could not be read. Refused.
        unresolved: ArcSource.Site,
    };

    /// How far along a place's chain the R9 question runs. The two sites ask
    /// DIFFERENT questions and the difference is not cosmetic.
    const ReachDepth = enum {
        /// Every step, the final field included. An exclusive BORROW asks
        /// this: `&mut b.h` with `arc h: String` hands the callee a mutable
        /// pointer built from the handle itself. Measured, it emitted
        /// `cell_grow(((cell_string_t *)&b.h.ptr))`, a `cell_string_t *`
        /// aimed at the box pointer, and `cc` accepted it silently.
        whole,
        /// Every step but the last. An ASSIGNMENT asks this: writing
        /// `b.h = ...` where `h` is `arc` REBINDS that handle, which is R11's
        /// leak and not a mutation of the pointee, while writing `b.h.x = ...`
        /// mutates the shared value through it. A consequence worth stating,
        /// because it bounds the over-refusal: a one-segment write such as
        /// `b.len = b.len + 1` through an `exclusive b: Buffer` asks only
        /// about the binding, so no struct has to resolve and `.unresolved`
        /// cannot reach it.
        strict_prefix,
    };

    /// Walk a place's chain and report the first `arc` step, or the first step
    /// whose annotation is unreadable.
    ///
    /// The binding itself is the empty-path prefix and is always asked, at
    /// both depths. That matters: `let arc s` then `&mut s` has no field path
    /// at all, and it is the plainest form of the rule.
    fn arcReach(self: *Checker, place: Place, depth: ReachDepth) Error!ArcReach {
        const b = self.bindingById(place.binding) orelse return .{ .unresolved = .{
            .display = try self.msg("the place '{s}'", .{place.display}),
            .span = place.span,
        } };
        // The binding is the empty-path prefix. It is a STRICT prefix only
        // when there is a field path after it, which is why this cannot be
        // hoisted above the depth split: `var arc b` then `b = other` rebinds
        // the handle and is R11's leak, while `b.len = 2` writes through it
        // and is R9's rule. The accepted-case test caught this being hoisted.
        if (place.path.len == 0) {
            return switch (depth) {
                .whole => if (b.ownership == .arc) .{ .arc = .{
                    .display = b.name,
                    .span = place.span,
                } } else .not_arc,
                .strict_prefix => .not_arc,
            };
        }
        if (b.ownership == .arc) return .{ .arc = .{ .display = b.name, .span = place.span } };

        var total: usize = 1;
        for (place.path) |ch| {
            if (ch == '.') total += 1;
        }
        const limit = switch (depth) {
            .whole => total,
            .strict_prefix => total - 1,
        };
        if (limit == 0) return .not_arc;

        var current: ?[]const u8 = b.struct_name;
        var prefix: []const u8 = b.name;
        var it = std.mem.splitScalar(u8, place.path, '.');
        var i: usize = 0;
        while (it.next()) |segment| : (i += 1) {
            if (i == limit) break;
            const unreadable: ArcReach = .{ .unresolved = .{
                .display = try self.msg("the field '{s}' of '{s}'", .{ segment, prefix }),
                .span = place.span,
            } };
            const struct_name = current orelse return unreadable;
            const def = self.structs.get(struct_name) orelse return unreadable;
            const field = findField(def, segment) orelse return unreadable;
            prefix = try self.msg("{s}.{s}", .{ prefix, segment });
            if (field.ownership == .arc) return .{ .arc = .{
                .display = prefix,
                .span = place.span,
            } };
            current = typeStructName(&field.ty);
        }
        return .not_arc;
    }

    /// R9: an `arc` value grants shared access only. One function for both
    /// enforcement sites, so they cannot drift apart the way R10's four
    /// hand-written copies did.
    ///
    /// It is a REFUSAL and there is nothing to insert instead. `arc` shares
    /// one value between holders and Cell has no interior mutability, so a
    /// mutable pointer into the box is a data race and an aliasing violation
    /// at once; no clone or retain changes that, because the holders are meant
    /// to observe the SAME value.
    ///
    /// Returns true when it refused.
    fn refuseArcShared(
        self: *Checker,
        reach: ArcReach,
        place: Place,
        op: enum { borrow_exclusive, assign },
    ) Error!bool {
        switch (reach) {
            .not_arc => return false,
            .arc => |s| {
                const same = std.mem.eql(u8, s.display, place.display);
                const message = switch (op) {
                    .borrow_exclusive => if (same)
                        try self.msg(
                            "cannot borrow '{s}' as exclusive: 'arc' grants shared access only",
                            .{place.display},
                        )
                    else
                        try self.msg(
                            "cannot borrow '{s}' as exclusive: it is reached through the 'arc' handle '{s}', which grants shared access only",
                            .{ place.display, s.display },
                        ),
                    .assign => if (same)
                        try self.msg(
                            "cannot assign through '{s}': 'arc' grants shared access only",
                            .{place.display},
                        )
                    else
                        try self.msg(
                            "cannot assign to '{s}': it is reached through the 'arc' handle '{s}', which grants shared access only",
                            .{ place.display, s.display },
                        ),
                };
                try self.diagnostics.err(self.allocator, place.span, message);
                try self.diagnostics.note(
                    self.allocator,
                    place.span,
                    "mutation through 'arc' needs interior mutability, which Cell does not have yet",
                );
            },
            .unresolved => |s| {
                const message = switch (op) {
                    .borrow_exclusive => try self.msg(
                        "cannot borrow '{s}' as exclusive: the ownership of {s} cannot be resolved here",
                        .{ place.display, s.display },
                    ),
                    .assign => try self.msg(
                        "cannot assign to '{s}': the ownership of {s} cannot be resolved here",
                        .{ place.display, s.display },
                    ),
                };
                try self.diagnostics.err(self.allocator, place.span, message);
                try self.diagnostics.note(
                    self.allocator,
                    place.span,
                    "R9 refuses what it cannot prove is not 'arc': a unique reference into a shared value mutates every holder",
                );
            },
        }
        return true;
    }

    /// R9 in a VALUE position, which is axis 1 of R10's history repeating in a
    /// new rule. `createLoan` is the choke point for every exclusive loan, and
    /// a loan is only ever created for a PLACE, so an exclusive borrow of a
    /// VALUE never reached it: `grow(&mut fresh())` with
    /// `fresh() -> arc String` was accepted at exit 0 and emitted
    /// `cell_grow(((cell_string_t *)&cell_fresh().ptr))`.
    ///
    /// That emit is LOUD, and loud for every type rather than by the
    /// coincidence of two C types: `cc` refuses to take the address of an
    /// rvalue. It is refused here anyway, on the argument `refuseArcUnique`
    /// already makes, that a rule holding for every type beats one whose
    /// enforcement depends on what the backend happens to emit.
    ///
    /// Two sites reach it, and both are needed. A bare `&mut <value>` arrives
    /// through `checkExpr`'s unary arm; `grow(&mut fresh())` does NOT, because
    /// `checkCall` peels the sigil itself and then calls `checkExpr` on the
    /// operand rather than on the unary. Fixing only the first left the
    /// measured program still accepted, which is this file's failure mode
    /// caught inside its own fix.
    ///
    /// `arcUniqueSource` is R10's classifier and answers the question both
    /// rules need here, "is this expression an `arc` handle", with a total
    /// verdict whose undecidable case is refused.
    fn refuseArcValueBorrow(self: *Checker, operand: *const ast.Expr) Error!bool {
        switch (try self.arcUniqueSource(operand)) {
            .not_arc => return false,
            .arc_place, .arc_value => |s| {
                try self.diagnostics.err(
                    self.allocator,
                    s.span,
                    try self.msg(
                        "cannot borrow '{s}' as exclusive: 'arc' grants shared access only",
                        .{s.display},
                    ),
                );
                try self.diagnostics.note(
                    self.allocator,
                    s.span,
                    "mutation through 'arc' needs interior mutability, which Cell does not have yet",
                );
            },
            .unknown => |s| {
                try self.diagnostics.err(
                    self.allocator,
                    s.span,
                    try self.msg(
                        "cannot borrow {s} as exclusive: its ownership cannot be resolved here",
                        .{s.display},
                    ),
                );
                try self.diagnostics.note(
                    self.allocator,
                    s.span,
                    "R9 refuses what it cannot prove is not 'arc': a unique reference into a shared value mutates every holder",
                );
            },
        }
        return true;
    }

    /// Whether an expression yields a BORROW rather than a value. Total, with
    /// `.unresolved` refused, for the same reason `ArcSource` is total: this
    /// question is asked in a position where accepting the wrong answer leaves
    /// a stale loan, and refusing only costs a program that can be spelled
    /// with a fresh name.
    const BorrowSource = union(enum) {
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
    fn borrowSource(self: *Checker, e: *const ast.Expr) Error!BorrowSource {
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
    fn holdsBorrow(self: *const Checker, b: *const Binding) bool {
        if (b.ownership == .shared or b.ownership == .exclusive) return true;
        for (self.block_loans.items) |loan| {
            const holder = loan.holder orelse continue;
            if (std.mem.eql(u8, holder, b.name)) return true;
        }
        return false;
    }

    /// R12 and R10's exemptions, which R2 depends on: a `copy` place is
    /// duplicated and an `arc` place is retained, so neither dies.
    fn isDuplicable(self: *const Checker, b: *const Binding, path: []const u8) bool {
        const own = self.placeOwnership(b, path) orelse return false;
        return own == .copy or own == .arc;
    }

    /// The declared annotation of a place: the binding's own for an empty
    /// path, otherwise the last field's, resolved through the struct table.
    /// Null when it cannot be resolved, which is treated conservatively.
    fn placeOwnership(self: *const Checker, b: *const Binding, path: []const u8) ?Ownership {
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
    fn placeStructName(self: *const Checker, b: *const Binding, path: []const u8) ?[]const u8 {
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

    fn reportEscapingReturn(self: *Checker, at: Span, kind: LoanKind) Error!void {
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

    fn checkStructFields(self: *Checker, span: Span, s: ast.StructDef) Error!void {
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

    const ResourceShape = enum { no_resources, resources, unknown };

    /// Whether an ownership keyword can change how a declared type is
    /// represented. This mirrors codegen's `applyOwnership`, whose first line
    /// is `if (base.shape.isPrimitive()) return base;` and whose `.arc` arm is
    /// otherwise `CType.arc`. The two are one rule written in two files, so a
    /// change to `Shape.isPrimitive` belongs here as well.
    const Representation = enum { primitive, aggregate, unknown };

    fn representationOf(self: *Checker, ty: *const ast.TypeExpr) Error!Representation {
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

    fn resourceShape(self: *Checker, ty: *const ast.TypeExpr) Error!ResourceShape {
        // `.owned` is the neutral answer: it is the one keyword that never
        // changes representation, so this asks the type's own shape.
        return self.resourceShapeOwned(ty, .owned);
    }

    /// The shape of a declared struct field, which is the type AND the keyword
    /// written in front of it. Reading only the type is what let a boxed
    /// scalar-only record hide inside a `copy` field.
    fn fieldResourceShape(self: *Checker, field: *const ast.Field) Error!ResourceShape {
        return self.resourceShapeOwned(&field.ty, field.ownership);
    }

    fn resourceShapeOwned(
        self: *Checker,
        ty: *const ast.TypeExpr,
        own: ast.Ownership,
    ) Error!ResourceShape {
        var visiting: std.StringHashMapUnmanaged(void) = .empty;
        defer visiting.deinit(self.allocator);
        return self.resourceShapeInner(ty, own, &visiting);
    }

    fn resourceShapeInner(
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

    fn combineResourceShapes(a: ResourceShape, b: ResourceShape) ResourceShape {
        if (a == .resources or b == .resources) return .resources;
        if (a == .unknown or b == .unknown) return .unknown;
        return .no_resources;
    }

    fn refuseOwnedFieldTransfer(
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
            "aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead",
        );
    }

    fn reportUseAfterMove(self: *Checker, d: Dead, at: Span) Error!void {
        try self.diagnostics.err(
            self.allocator,
            at,
            try self.msg("use of '{s}' after it was moved", .{d.display}),
        );
        try self.diagnostics.note(self.allocator, d.span, d.note);
    }

    fn noteLoanScope(self: *Checker, loan: Loan) Error!void {
        const text = if (loan.lexical)
            try self.msg(
                "the {s} borrow starts here and lasts to the end of this block",
                .{loan.kind.word()},
            )
        else
            try self.msg(
                "the {s} borrow starts here and lasts until this statement completes",
                .{loan.kind.word()},
            );
        try self.diagnostics.note(self.allocator, loan.span, text);
    }

    /// Whether a named loan is still holding its referent at the statement
    /// being checked, in the non-lexical sense. `dead` is the only status
    /// that is not a rejection, so `dead` is the only one that needs proof;
    /// `live` and `ineligible` are both safe answers and are never wrong in a
    /// way that admits a program.
    ///
    /// `dead` requires BOTH halves, and each is blind to what the other sees:
    ///
    /// **(a) Forward,** `nameUsedFrom`: the holder is not mentioned from the
    /// current statement to the end of the block that owns the loan. It counts
    /// the current statement in FULL and recurses into a `while`'s condition
    /// and body, so a back edge and a use nested inside the current statement
    /// both read as "used". That full-statement counting is also what covers
    /// every block nested inside the current statement, at every depth.
    ///
    /// **(b) Window,** `windowPropagates`: between the loan's own `let` and
    /// the current statement, at the loan's OWN block level, the holder is
    /// mentioned only in positions that provably cannot propagate the
    /// reference. This is the region (a) structurally cannot see, because (a)
    /// starts at the current statement and only ever looks forward.
    ///
    /// The two regions together are exhaustive over the loan's live range.
    /// Anything at a block level nested inside the loan's block is reached
    /// through (a)'s full-statement counting of the enclosing statement, so
    /// only the loan's own block has a gap for (b) to fill.
    fn loanStatusAt(self: *Checker, loan: Loan, at: Span) Error!LoanStatus {
        // A temporary loan dies with its statement or its `if`, so the lexical
        // model already ends it as early as NLL would.
        if (!loan.lexical) return .ineligible;
        const holder = loan.holder orelse return .ineligible;
        if (self.windowPropagates(loan, holder)) return .ineligible;
        if (self.nameUsedFrom(holder, loan.block_index)) return .live;
        // The differential oracle, armed in every safety-checked build, so
        // the whole test suite and the whole example corpus exercise it
        // without a single test being written for it. See `oracleDead`.
        if (std.debug.runtime_safety) {
            switch (try self.oracleDead(loan, holder, at)) {
                .dead, .not_applicable => {},
                .live => {
                    std.debug.print(
                        "borrowck NLL differential oracle disagreed\n" ++
                            "  holder: '{s}'\n" ++
                            "  loan of '{s}' at line {d} column {d}\n" ++
                            "  loanStatusAt: dead (an ACCEPTANCE)\n" ++
                            "  oracleDead:   live\n" ++
                            "The precise predicate accepted a program the " ++
                            "conservative one holds live. Trust the oracle: " ++
                            "this is the enumeration failure the oracle exists " ++
                            "to catch, and shipping it is a use-after-free.\n",
                        .{ holder, loan.display, loan.span.line, loan.span.column },
                    );
                    @panic("borrowck: NLL differential oracle disagreed on a loan the checker called dead");
                },
            }
        }
        return .dead;
    }

    /// The first loan that conflicts with taking `kind` on `place` AND that
    /// non-lexical lifetimes still consider live. A conflicting loan whose
    /// status is `dead` is skipped, and that skip IS the acceptance: the
    /// caller sees no conflict and reports nothing.
    ///
    /// A dead loan is deliberately left in `block_loans` rather than removed.
    /// Removing it would be equivalent but would make the acceptance depend on
    /// the order conflicts happen to be checked in; leaving it makes every
    /// site ask the same question independently. It is also monotone: `dead`
    /// means the holder is mentioned nowhere from here on, so a loan that is
    /// dead at this statement is dead at every later one in the same block.
    fn findBlockingLoan(self: *Checker, place: Place, kind: LoanKind) Error!?Loan {
        for (self.block_loans.items) |loan| {
            if (!loanConflicts(loan, place, kind)) continue;
            if (try self.loanStatusAt(loan, place.span) == .dead) continue;
            return loan;
        }
        // A temporary is never `lexical`, so it is always `ineligible` and is
        // never skipped. It is routed through the same predicate anyway so
        // there is one place that decides what ends a loan early.
        for (self.temp_loans.items) |loan| {
            if (!loanConflicts(loan, place, kind)) continue;
            if (try self.loanStatusAt(loan, place.span) == .dead) continue;
            return loan;
        }
        return null;
    }

    /// THE DIFFERENTIAL ORACLE, and the primary defence for the acceptance
    /// above. It answers the same question as `loanStatusAt` and is written
    /// to be wrong only in the safe direction.
    ///
    /// WHY A SECOND PREDICATE AT ALL. "The loan is dead here" is a claim over
    /// all forward paths, and the way this compiler has repeatedly got such
    /// claims wrong is by enumerating some forms of a construct and asserting
    /// a property of all of them. `loanStatusAt` is exactly that shape: two
    /// scans, each with a region it cannot see, meeting at a boundary. So it
    /// is checked against a predicate built the opposite way, which enumerates
    /// nothing about program structure:
    ///
    /// 1. Take the transitive closure of names, starting from the holder, over
    ///    the WHOLE function body, ignoring scopes, blocks, statement order
    ///    and control flow entirely. A binding joins the closure when its
    ///    `let` initializer or `assign` value mentions a name already in it.
    /// 2. The loan is dead only if no name in the closure occurs anywhere
    ///    after the loan's own span.
    ///
    /// It greps a function rather than walking its regions, so it has no
    /// region to forget. `let exclusive f = e` puts `f` in the closure and
    /// `grow(exclusive f, ...)` then holds the loan live no matter where the
    /// two statements sit relative to each other.
    ///
    /// **DEVIATION FROM THE BRIEF, DELIBERATE AND REPORTED.** The brief
    /// specifies step 2 as "no name in the closure appears anywhere after the
    /// loan's `let`", full stop. That is exactly right for a predicate with an
    /// empty whitelist, and it CONTRADICTS the call-argument whitelist: in
    /// `let exclusive e = &mut buf; grow(exclusive e, shared 1); read(&buf)`
    /// the holder does appear after the `let`, so the oracle would fire on the
    /// very shape the whitelist exists to accept. Both halves of the oracle
    /// therefore honor the same whitelist, in step 1 as well as step 2 (if the
    /// closure ignored it, `let copy n = read(shared e)` would taint `n` and
    /// any later use of `n` would fire). What stays independent is the
    /// implementation: `oracleFindExpr` propagates an argument CONTEXT down a
    /// single walk and reports occurrence offsets, where the checker peels an
    /// argument and returns a boolean. A whitelist bug is shared; a region,
    /// order or control-flow bug is not, and those are the failures that
    /// actually happen here.
    ///
    /// **KNOWN HOLE, and why it is a `not_applicable` rather than a fix.**
    /// The oracle is blind to shadowing, which makes it more conservative
    /// everywhere except one case: a loan in an inner block whose holder name
    /// is ALSO an outer binding used after that block. The checker never scans
    /// outside the loan's block, correctly, because the loan cannot outlive
    /// it; the oracle scans the whole function and would see the outer use.
    /// Rather than teach the oracle about scopes, which is the knowledge it
    /// exists not to have, it declines to answer when the holder name is
    /// declared more than once in the function.
    ///
    /// **SECOND KNOWN HOLE, narrower and stated rather than hidden.** A
    /// program that uses a name OUTSIDE the block that declared it is invalid
    /// (typecheck reports an unknown identifier), but this oracle would see
    /// that use, call the loan live, and panic before the diagnostic is
    /// printed. It needs the name to be declared exactly once, used out of
    /// scope, AND to hold a loan the checker reaches a conflict on. The
    /// failure is a loud panic on an already-broken program, not a wrong
    /// answer on a valid one, which is the direction to fail in.
    /// **WHERE THE WHITELIST APPLIES, AND WHERE IT MUST NOT.** The whitelist
    /// answers "can this mention have put the reference somewhere I cannot
    /// see", not "is the holder still used here". Those are the same question
    /// only BEHIND the conflict:
    ///
    /// * Between the loan's `let` and `at`, a direct call argument is fine.
    ///   The loan was correctly live during that call, the call ended, and R8
    ///   says nothing kept the reference.
    /// * At or after `at`, ANY mention keeps the loan live, call argument or
    ///   not, because it is a use of a loan the caller is about to end.
    ///
    /// A first version of this function whitelisted call arguments in both
    /// regions, and it was caught by running it: with the match-guard hole
    /// deliberately reintroduced into `exprUsesName`, the checker accepted
    /// `match 1 { _ if use_it(shared e) > 0 => 1, _ => 2 }` after a
    /// conflicting borrow and this oracle AGREED, because the use sits in a
    /// call argument. Splitting at `at` makes it disagree, which is the whole
    /// reason the oracle exists.
    fn oracleDead(
        self: *Checker,
        loan: Loan,
        holder: []const u8,
        at: Span,
    ) Error!OracleVerdict {
        const f = self.current_fn orelse return .not_applicable;
        const body = f.body orelse return .not_applicable;
        if (oracleDeclarationCount(f, holder) != 1) return .not_applicable;

        var names: NameSet = .empty;
        defer names.deinit(self.allocator);
        try names.put(self.allocator, holder, {});

        var changed = true;
        while (changed) {
            changed = false;
            try oracleTaintStmts(self.allocator, body, &names, &changed);
        }

        // `+ 1` makes it strictly after: the loan's own span is the borrowed
        // place, which is not the holder, but the bound is stated exactly
        // rather than left to that coincidence.
        const after = loan.span.start +| 1;
        if (oracleFindStmts(body, &names, after, at.start) != null) return .live;
        return .dead;
    }

    /// Part (b). Scans the statements at the loan's own block level that lie
    /// strictly between the loan's `let` and the statement being checked.
    ///
    /// Returns true, meaning `ineligible`, when the holder is mentioned there
    /// in any position other than the one whitelisted by `argPropagatesName`.
    /// Returns true as well when the loan's block is no longer on the stack,
    /// which cannot happen for a live block loan but must not silently read as
    /// "nothing propagates" if it ever does.
    fn windowPropagates(self: *const Checker, loan: Loan, holder: []const u8) bool {
        if (loan.block_index >= self.open_blocks.items.len) return true;
        const ob = self.open_blocks.items[loan.block_index];
        const from = @min(loan.stmt_index + 1, ob.stmts.len);
        const to = @min(ob.index, ob.stmts.len);
        if (to <= from) return false;
        for (ob.stmts[from..to]) |*s| {
            if (stmtPropagatesName(s, holder)) return true;
        }
        return false;
    }

    /// Whether `name` appears anywhere from the statement being checked to the
    /// end of the block that owns the loan. The statement currently being
    /// checked counts in full, and so does the statement containing an inner
    /// block, so the answer errs toward "used".
    fn nameUsedFrom(self: *const Checker, name: []const u8, from_block: usize) bool {
        if (self.open_blocks.items.len == 0) return true;
        var i = self.open_blocks.items.len;
        while (i > from_block) {
            i -= 1;
            if (i >= self.open_blocks.items.len) continue;
            const ob = self.open_blocks.items[i];
            for (ob.stmts[@min(ob.index, ob.stmts.len)..]) |*s| {
                if (stmtUsesName(s, name)) return true;
            }
        }
        return false;
    }

    // ── place construction ──────────────────────────────────────────────

    /// The place an expression denotes, or null when it denotes no place (a
    /// literal, a call result, an unknown identifier).
    fn placeOf(self: *Checker, e: *const ast.Expr) Error!?Place {
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
};

// ── free functions ──────────────────────────────────────────────────────

const Ref = struct { kind: LoanKind, operand: *const ast.Expr };

/// A `shared T` or `exclusive T` written in type position. `arc T` and
/// `owned T` are not borrows, so they are not R8.
fn typeIsBorrow(ty: *const ast.TypeExpr) ?LoanKind {
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
fn refKind(e: *const ast.Expr) ?Ref {
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
fn pathPrefix(a: []const u8, b: []const u8) bool {
    if (a.len == 0) return true;
    if (a.len > b.len) return false;
    if (!std.mem.eql(u8, a, b[0..a.len])) return false;
    return a.len == b.len or b[a.len] == '.';
}

fn typeStructName(ty: *const ast.TypeExpr) ?[]const u8 {
    return switch (ty.*) {
        .name => |n| n,
        .optional => |inner| typeStructName(inner),
        .ref => |r| typeStructName(r.inner),
        else => null,
    };
}

fn findField(def: ast.StructDef, name: []const u8) ?ast.Field {
    for (def.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

fn containsDead(list: []const Dead, d: Dead) bool {
    for (list) |x| {
        if (x.binding == d.binding and std.mem.eql(u8, x.path, d.path)) return true;
    }
    return false;
}

fn stmtUsesName(s: *const ast.Stmt, name: []const u8) bool {
    return switch (s.kind) {
        .let => |l| if (l.value) |v| exprUsesName(&v, name) else false,
        .expr => |e| exprUsesName(&e, name),
        .return_stmt => |opt| if (opt) |e| exprUsesName(&e, name) else false,
        .assign => |a| exprUsesName(&a.target, name) or exprUsesName(&a.value, name),
        .while_stmt => |w| blk: {
            if (exprUsesName(&w.cond, name)) break :blk true;
            for (w.body) |*b| {
                if (stmtUsesName(b, name)) break :blk true;
            }
            break :blk false;
        },
        .break_stmt, .continue_stmt => false,
    };
}

fn exprUsesName(e: *const ast.Expr, name: []const u8) bool {
    return switch (e.kind) {
        .ident => |n| std.mem.eql(u8, n, name),
        .int, .float, .string, .bool => false,
        .call => |c| blk: {
            if (exprUsesName(c.callee, name)) break :blk true;
            for (c.args) |*a| {
                if (exprUsesName(a, name)) break :blk true;
            }
            break :blk false;
        },
        .binary => |b| exprUsesName(b.left, name) or exprUsesName(b.right, name),
        .unary => |u| exprUsesName(u.operand, name),
        .field => |f| exprUsesName(f.base, name),
        .struct_lit => |sl| blk: {
            for (sl.fields) |*f| {
                if (exprUsesName(&f.value, name)) break :blk true;
            }
            break :blk false;
        },
        .list_lit => |items| blk: {
            for (items) |*item| {
                if (exprUsesName(item, name)) break :blk true;
            }
            break :blk false;
        },
        .block => |stmts| blk: {
            for (stmts) |*s| {
                if (stmtUsesName(s, name)) break :blk true;
            }
            break :blk false;
        },
        .if_expr => |i| blk: {
            if (exprUsesName(i.cond, name)) break :blk true;
            if (exprUsesName(i.then_body, name)) break :blk true;
            if (i.else_body) |eb| {
                if (exprUsesName(eb, name)) break :blk true;
            }
            break :blk false;
        },
        .match_expr => |m| blk: {
            if (exprUsesName(m.scrutinee, name)) break :blk true;
            for (m.arms) |arm| {
                // The GUARD, not only the body. An arm has two expression
                // positions and this scanned one of them, so
                // `match n { _ if use_it(exclusive e) > 0 => 1, _ => 2 }`
                // read as "'e' is never used again" and printed a note saying
                // NLL would accept a program NLL rejects. Under the
                // acceptance this scan now gates, the same hole would have
                // ended a loan that is still held inside the guard.
                if (arm.guard) |g| {
                    if (exprUsesName(g, name)) break :blk true;
                }
                if (exprUsesName(arm.body, name)) break :blk true;
            }
            break :blk false;
        },
        .annotated => |a| exprUsesName(a.value, name),
    };
}

// ── the NLL predicate's part (b): the window walker ─────────────────────
//
// THE WHITELIST IS THE COMPLEMENT, AND THAT IS THE WHOLE POINT. These three
// functions do not enumerate the positions that propagate a reference and
// assume everything left over is safe. They enumerate the ONE position that
// provably cannot propagate one, and treat every other mention as propagating.
//
// The one position: a DIRECT argument of a call, after peeling a written
// ownership keyword (`.annotated`) and a `&`/`&mut` sigil. It is sound because
// R8 forbids the callee returning the borrow or storing it in a struct field,
// and Cell has no lifetime parameters, no references inside aggregates and no
// closures, so a callee has nowhere to put it. If lifetime parameters ever
// land, the test named for that invariant fails and says so.
//
// Every other mention -- a `let` initializer, an `assign` target or value, a
// `match` scrutinee, a guard, a struct-literal field, a list element, an
// `if`/`match`/block value position -- lands on the reject side by
// construction rather than by being remembered. Value positions are exactly
// the class that produced two of the `arc` use-after-frees this checker has
// already shipped and fixed.
//
// Both switches are exhaustive with NO `else` arm, like `exprUsesName` above,
// so a new AST node is a compile error here rather than a silent default to
// "safe".

/// Whether `s` mentions `name` anywhere outside the whitelisted position.
fn stmtPropagatesName(s: *const ast.Stmt, name: []const u8) bool {
    return switch (s.kind) {
        .let => |l| if (l.value) |v| exprPropagatesName(&v, name) else false,
        .expr => |e| exprPropagatesName(&e, name),
        .return_stmt => |opt| if (opt) |e| exprPropagatesName(&e, name) else false,
        // The TARGET counts. `e = &mut b` retargets the holder, and this
        // checker does not model that (see the report on the retarget gap), so
        // any assignment naming the holder is `ineligible`.
        .assign => |a| exprPropagatesName(&a.target, name) or exprPropagatesName(&a.value, name),
        .while_stmt => |w| blk: {
            if (exprPropagatesName(&w.cond, name)) break :blk true;
            for (w.body) |*b| {
                if (stmtPropagatesName(b, name)) break :blk true;
            }
            break :blk false;
        },
        .break_stmt, .continue_stmt => false,
    };
}

/// Whether `e` mentions `name` anywhere outside the whitelisted position.
/// Every sub-expression here is a non-whitelisted position; only
/// `argPropagatesName` opens the one exception.
fn exprPropagatesName(e: *const ast.Expr, name: []const u8) bool {
    return switch (e.kind) {
        .ident => |n| std.mem.eql(u8, n, name),
        .int, .float, .string, .bool => false,
        .call => |c| blk: {
            // The CALLEE is not an argument. `e(1)` is not whitelisted.
            if (exprPropagatesName(c.callee, name)) break :blk true;
            for (c.args) |*a| {
                if (argPropagatesName(a, name)) break :blk true;
            }
            break :blk false;
        },
        .binary => |b| exprPropagatesName(b.left, name) or exprPropagatesName(b.right, name),
        .unary => |u| exprPropagatesName(u.operand, name),
        .field => |f| exprPropagatesName(f.base, name),
        .struct_lit => |sl| blk: {
            for (sl.fields) |*f| {
                if (exprPropagatesName(&f.value, name)) break :blk true;
            }
            break :blk false;
        },
        .list_lit => |items| blk: {
            for (items) |*item| {
                if (exprPropagatesName(item, name)) break :blk true;
            }
            break :blk false;
        },
        .block => |stmts| blk: {
            for (stmts) |*s| {
                if (stmtPropagatesName(s, name)) break :blk true;
            }
            break :blk false;
        },
        .if_expr => |i| blk: {
            if (exprPropagatesName(i.cond, name)) break :blk true;
            if (exprPropagatesName(i.then_body, name)) break :blk true;
            if (i.else_body) |eb| {
                if (exprPropagatesName(eb, name)) break :blk true;
            }
            break :blk false;
        },
        .match_expr => |m| blk: {
            if (exprPropagatesName(m.scrutinee, name)) break :blk true;
            for (m.arms) |arm| {
                if (arm.guard) |g| {
                    if (exprPropagatesName(g, name)) break :blk true;
                }
                if (exprPropagatesName(arm.body, name)) break :blk true;
            }
            break :blk false;
        },
        .annotated => |a| exprPropagatesName(a.value, name),
    };
}

/// One call argument, the only whitelisted position. Peels a written
/// ownership keyword and a `&`/`&mut` sigil; if what is left is exactly a
/// bare identifier, the mention cannot propagate, whether or not it is
/// `name`. Anything else falls back to the non-whitelisted walk, so
/// `f(e.len)`, `f(g(e))`'s outer argument and `f(-e)` are all judged there.
fn argPropagatesName(arg: *const ast.Expr, name: []const u8) bool {
    var cursor = arg;
    while (true) {
        switch (cursor.kind) {
            .annotated => |a| cursor = a.value,
            .unary => |u| switch (u.op) {
                .ref_shared, .ref_exclusive => cursor = u.operand,
                else => return exprPropagatesName(cursor, name),
            },
            // A bare identifier handed to a callee. Either it is `name`, and
            // R8 stops the callee keeping it, or it is some other binding and
            // there is no mention of `name` here at all. Both are `false`.
            .ident => return false,
            else => return exprPropagatesName(cursor, name),
        }
    }
}

// ── the differential oracle ─────────────────────────────────────────────
//
// A second implementation of "is this loan dead", written so conservatively
// that it cannot have a missing case, and asserted against the precise one in
// every safety-checked build. `Checker.oracleDead` carries the argument for
// why it exists, the one deviation from its brief, and its one known hole.
//
// Everything below ignores scopes, blocks, statement order and control flow.
// It is a grep with a fixpoint, not an analysis.

/// How many times `name` is DECLARED in `f`: parameters, `let` statements at
/// any depth, and match-arm binding patterns. The oracle declines when this is
/// not exactly 1, because shadowing is the one thing its scope blindness gets
/// wrong in the unsafe direction for the ASSERTION (never for the language).
fn oracleDeclarationCount(f: *const ast.FnDef, name: []const u8) usize {
    var n: usize = 0;
    for (f.params) |p| {
        if (std.mem.eql(u8, p.name, name)) n += 1;
    }
    if (f.body) |body| n += oracleDeclCountStmts(body, name);
    return n;
}

fn oracleDeclCountStmts(stmts: []const ast.Stmt, name: []const u8) usize {
    var n: usize = 0;
    for (stmts) |*s| {
        switch (s.kind) {
            .let => |l| {
                if (std.mem.eql(u8, l.name, name)) n += 1;
                if (l.value) |v| n += oracleDeclCountExpr(&v, name);
            },
            .expr => |e| n += oracleDeclCountExpr(&e, name),
            .return_stmt => |opt| if (opt) |e| {
                n += oracleDeclCountExpr(&e, name);
            },
            .assign => |a| {
                n += oracleDeclCountExpr(&a.target, name);
                n += oracleDeclCountExpr(&a.value, name);
            },
            .while_stmt => |w| {
                n += oracleDeclCountExpr(&w.cond, name);
                n += oracleDeclCountStmts(w.body, name);
            },
            .break_stmt, .continue_stmt => {},
        }
    }
    return n;
}

fn oracleDeclCountExpr(e: *const ast.Expr, name: []const u8) usize {
    return switch (e.kind) {
        .ident, .int, .float, .string, .bool => 0,
        .call => |c| blk: {
            var n = oracleDeclCountExpr(c.callee, name);
            for (c.args) |*a| n += oracleDeclCountExpr(a, name);
            break :blk n;
        },
        .binary => |b| oracleDeclCountExpr(b.left, name) + oracleDeclCountExpr(b.right, name),
        .unary => |u| oracleDeclCountExpr(u.operand, name),
        .field => |f| oracleDeclCountExpr(f.base, name),
        .annotated => |a| oracleDeclCountExpr(a.value, name),
        .struct_lit => |sl| blk: {
            var n: usize = 0;
            for (sl.fields) |*f| n += oracleDeclCountExpr(&f.value, name);
            break :blk n;
        },
        .list_lit => |items| blk: {
            var n: usize = 0;
            for (items) |*item| n += oracleDeclCountExpr(item, name);
            break :blk n;
        },
        .block => |stmts| oracleDeclCountStmts(stmts, name),
        .if_expr => |i| blk: {
            var n = oracleDeclCountExpr(i.cond, name) + oracleDeclCountExpr(i.then_body, name);
            if (i.else_body) |eb| n += oracleDeclCountExpr(eb, name);
            break :blk n;
        },
        .match_expr => |m| blk: {
            var n = oracleDeclCountExpr(m.scrutinee, name);
            for (m.arms) |arm| {
                if (arm.pattern.kind == .binding and
                    std.mem.eql(u8, arm.pattern.kind.binding, name)) n += 1;
                if (arm.guard) |g| n += oracleDeclCountExpr(g, name);
                n += oracleDeclCountExpr(arm.body, name);
            }
            break :blk n;
        },
    };
}

/// A `strict_from` past every possible offset, so the whitelist applies
/// everywhere. Step 1 of the oracle uses it: the closure asks whether a value
/// could have CAPTURED a reference, and a direct call argument provably
/// cannot, whatever its position. Only step 2 has a conflict point to split
/// on.
const oracle_never_strict: u32 = std.math.maxInt(u32);

/// Step 1 of the oracle: one sweep of the taint closure. A `let` name or an
/// `assign` target joins `names` when the value mentions a name already in it
/// outside the whitelisted position. Runs to a fixpoint in `oracleDead`, so
/// statement order does not matter.
fn oracleTaintStmts(
    gpa: std.mem.Allocator,
    stmts: []const ast.Stmt,
    names: *NameSet,
    changed: *bool,
) Error!void {
    for (stmts) |*s| {
        switch (s.kind) {
            .let => |l| {
                if (l.value) |v| {
                    if (oracleFindExpr(&v, names, .other, 0, oracle_never_strict) != null) {
                        try oracleAdd(gpa, names, l.name, changed);
                    }
                    try oracleTaintExpr(gpa, &v, names, changed);
                }
            },
            .assign => |a| {
                if (oracleFindExpr(&a.value, names, .other, 0, oracle_never_strict) != null) {
                    if (ast.rootName(&a.target)) |n| try oracleAdd(gpa, names, n, changed);
                }
                try oracleTaintExpr(gpa, &a.target, names, changed);
                try oracleTaintExpr(gpa, &a.value, names, changed);
            },
            .expr => |e| try oracleTaintExpr(gpa, &e, names, changed),
            .return_stmt => |opt| if (opt) |e| {
                try oracleTaintExpr(gpa, &e, names, changed);
            },
            .while_stmt => |w| {
                try oracleTaintExpr(gpa, &w.cond, names, changed);
                try oracleTaintStmts(gpa, w.body, names, changed);
            },
            .break_stmt, .continue_stmt => {},
        }
    }
}

/// Reaches the `let` and `assign` statements nested inside expressions. Every
/// block in this language is an expression, so without this the closure would
/// stop at the first `if`.
fn oracleTaintExpr(
    gpa: std.mem.Allocator,
    e: *const ast.Expr,
    names: *NameSet,
    changed: *bool,
) Error!void {
    switch (e.kind) {
        .ident, .int, .float, .string, .bool => {},
        .call => |c| {
            try oracleTaintExpr(gpa, c.callee, names, changed);
            for (c.args) |*a| try oracleTaintExpr(gpa, a, names, changed);
        },
        .binary => |b| {
            try oracleTaintExpr(gpa, b.left, names, changed);
            try oracleTaintExpr(gpa, b.right, names, changed);
        },
        .unary => |u| try oracleTaintExpr(gpa, u.operand, names, changed),
        .field => |f| try oracleTaintExpr(gpa, f.base, names, changed),
        .annotated => |a| try oracleTaintExpr(gpa, a.value, names, changed),
        .struct_lit => |sl| {
            for (sl.fields) |*f| try oracleTaintExpr(gpa, &f.value, names, changed);
        },
        .list_lit => |items| {
            for (items) |*item| try oracleTaintExpr(gpa, item, names, changed);
        },
        .block => |stmts| try oracleTaintStmts(gpa, stmts, names, changed),
        .if_expr => |i| {
            try oracleTaintExpr(gpa, i.cond, names, changed);
            try oracleTaintExpr(gpa, i.then_body, names, changed);
            if (i.else_body) |eb| try oracleTaintExpr(gpa, eb, names, changed);
        },
        .match_expr => |m| {
            try oracleTaintExpr(gpa, m.scrutinee, names, changed);
            for (m.arms) |arm| {
                if (arm.guard) |g| try oracleTaintExpr(gpa, g, names, changed);
                try oracleTaintExpr(gpa, arm.body, names, changed);
            }
        },
    }
}

fn oracleAdd(
    gpa: std.mem.Allocator,
    names: *NameSet,
    name: []const u8,
    changed: *bool,
) Error!void {
    const gop = try names.getOrPut(gpa, name);
    if (!gop.found_existing) changed.* = true;
}

/// Step 2 of the oracle: the byte offset of the first occurrence of a tainted
/// name at or after `min_start`, in a position that is not a direct call
/// argument. Null when there is none.
///
/// The context travels DOWN: a call's argument enters as `.call_arg`, only an
/// ownership keyword and a `&`/`&mut` sigil keep it, and every other node
/// resets it. That is a different mechanism from the checker's peel-upward
/// `argPropagatesName`, which is the point.
fn oracleFindStmts(
    stmts: []const ast.Stmt,
    names: *const NameSet,
    min_start: u32,
    strict_from: u32,
) ?u32 {
    for (stmts) |*s| {
        if (oracleFindStmt(s, names, min_start, strict_from)) |x| return x;
    }
    return null;
}

fn oracleFindStmt(
    s: *const ast.Stmt,
    names: *const NameSet,
    min_start: u32,
    strict_from: u32,
) ?u32 {
    return switch (s.kind) {
        .let => |l| if (l.value) |v| oracleFindExpr(&v, names, .other, min_start, strict_from) else null,
        .expr => |e| oracleFindExpr(&e, names, .other, min_start, strict_from),
        .return_stmt => |opt| if (opt) |e| oracleFindExpr(&e, names, .other, min_start, strict_from) else null,
        .assign => |a| oracleFindExpr(&a.target, names, .other, min_start, strict_from) orelse
            oracleFindExpr(&a.value, names, .other, min_start, strict_from),
        .while_stmt => |w| oracleFindExpr(&w.cond, names, .other, min_start, strict_from) orelse
            oracleFindStmts(w.body, names, min_start, strict_from),
        .break_stmt, .continue_stmt => null,
    };
}

fn oracleFindExpr(
    e: *const ast.Expr,
    names: *const NameSet,
    ctx: ArgContext,
    min_start: u32,
    /// The conflict's own offset. At or after it the whitelist stops applying:
    /// a use is a use. See `oracleDead` for why the two regions differ.
    strict_from: u32,
) ?u32 {
    return switch (e.kind) {
        .ident => |n| if (!names.contains(n) or e.span.start < min_start)
            null
        else if (ctx == .call_arg and e.span.start < strict_from)
            null
        else
            e.span.start,
        .int, .float, .string, .bool => null,
        .call => |c| blk: {
            // The callee is not an argument of itself.
            if (oracleFindExpr(c.callee, names, .other, min_start, strict_from)) |x| break :blk x;
            for (c.args) |*a| {
                if (oracleFindExpr(a, names, .call_arg, min_start, strict_from)) |x| break :blk x;
            }
            break :blk null;
        },
        // The two node kinds that keep the context.
        .annotated => |a| oracleFindExpr(a.value, names, ctx, min_start, strict_from),
        .unary => |u| oracleFindExpr(
            u.operand,
            names,
            if (u.op == .ref_shared or u.op == .ref_exclusive) ctx else .other,
            min_start,
            strict_from,
        ),
        .binary => |b| oracleFindExpr(b.left, names, .other, min_start, strict_from) orelse
            oracleFindExpr(b.right, names, .other, min_start, strict_from),
        .field => |f| oracleFindExpr(f.base, names, .other, min_start, strict_from),
        .struct_lit => |sl| blk: {
            for (sl.fields) |*f| {
                if (oracleFindExpr(&f.value, names, .other, min_start, strict_from)) |x| break :blk x;
            }
            break :blk null;
        },
        .list_lit => |items| blk: {
            for (items) |*item| {
                if (oracleFindExpr(item, names, .other, min_start, strict_from)) |x| break :blk x;
            }
            break :blk null;
        },
        .block => |stmts| oracleFindStmts(stmts, names, min_start, strict_from),
        .if_expr => |i| blk: {
            if (oracleFindExpr(i.cond, names, .other, min_start, strict_from)) |x| break :blk x;
            if (oracleFindExpr(i.then_body, names, .other, min_start, strict_from)) |x| break :blk x;
            if (i.else_body) |eb| {
                if (oracleFindExpr(eb, names, .other, min_start, strict_from)) |x| break :blk x;
            }
            break :blk null;
        },
        .match_expr => |m| blk: {
            if (oracleFindExpr(m.scrutinee, names, .other, min_start, strict_from)) |x| break :blk x;
            for (m.arms) |arm| {
                if (arm.guard) |g| {
                    if (oracleFindExpr(g, names, .other, min_start, strict_from)) |x| break :blk x;
                }
                if (oracleFindExpr(arm.body, names, .other, min_start, strict_from)) |x| break :blk x;
            }
            break :blk null;
        },
    };
}

/// Borrow-check `module`, rendering every diagnostic to `writer`. Deliberately
/// the same shape as `root.check`, so wiring it into the CLI is one call.
/// Returns `error.BorrowError` once the bag has been written, so a caller can
/// exit non-zero without re-inspecting it.
pub fn check(
    allocator: std.mem.Allocator,
    module: *const ast.Module,
    source: ?[]const u8,
    writer: *std.Io.Writer,
) !void {
    var checker: Checker = .init(allocator, module.path, source);
    defer checker.deinit();
    try checker.checkModule(module);
    try checker.diagnostics.printAll(writer);
    if (checker.hasErrors()) return error.BorrowError;
}

// ── tests ───────────────────────────────────────────────────────────────
//
// Every rule gets a rejection test that pins the diagnostic text, line and
// column, and an acceptance test for the shape the rule is meant to allow.
// Diagnostics are rendered without a source buffer so the assertion is one
// line per diagnostic; one test at the end supplies the source and pins the
// caret column instead.

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

const Harness = struct {
    arena: std.heap.ArenaAllocator,

    fn init() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
    }

    /// Parse and borrow-check `src`, rendering every diagnostic into `out`.
    fn run(self: *Harness, src: []const u8, out: []u8, with_source: bool) ![]u8 {
        const gpa = self.arena.allocator();
        var lex = lexer.Lexer.init(src, "t.cell");
        const tokens = try lex.tokenizeAll(gpa);
        var p = parser.Parser.init(gpa, tokens.items, "t.cell");
        var module = try p.parseModule();
        var checker: Checker = .init(gpa, "t.cell", if (with_source) src else null);
        defer checker.deinit();
        try checker.checkModule(&module);
        var w = std.Io.Writer.fixed(out);
        try checker.diagnostics.printAll(&w);
        return w.buffered();
    }
};

fn expectDiagnostics(src: []const u8, expected: []const u8) !void {
    var h: Harness = .init();
    defer h.deinit();
    var buf: [4096]u8 = undefined;
    const out = try h.run(src, &buf, false);
    try std.testing.expectEqualStrings(expected, out);
}

fn expectAccepted(src: []const u8) !void {
    try expectDiagnostics(src, "");
}

/// A `Buffer` with one `owned` field and one `copy` field, plus the four
/// helpers the rules' examples call. Kept on one line each so a test's own
/// statements start at a predictable line.
const prelude =
    \\pub struct Buffer {
    \\    owned data: [Byte]
    \\    copy len: Int
    \\}
    \\pub fn take(owned b: Buffer) { }
    \\pub fn read(shared b: Buffer) -> Int { return b.len }
    \\pub fn grow(exclusive b: Buffer, shared extra: Int) { }
    \\pub fn use_it(shared b: Buffer) -> Int { return b.len }
    \\
;
// The prelude occupies lines 1 through 8, so a test body's first line is 9.
const prelude_lines = 8;

test "R1 and R2: a bare argument to an owned parameter moves, and the next use is an error" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\    take(buf)
        \\}
    ,
        \\t.cell:12:10: error: use of 'buf' after it was moved
        \\t.cell:11:10: note: 'buf' was moved here by the call to 'take'
        \\
    );
}

test "R2 accepts a move that is never followed by a use" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    read(buf)
        \\    take(buf)
        \\}
    );
}

test "R2: a move through a field kills the whole binding for later reads" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(buf.data)
        \\    read(buf)
        \\}
    ,
        \\t.cell:12:10: error: use of 'buf.data' after it was moved
        \\t.cell:11:10: note: 'buf.data' was moved here by the call to 'take'
        \\
    );
}

test "R2: a return moves the returned place" {
    try expectDiagnostics(prelude ++
        \\pub fn consume(owned b: Buffer) -> Buffer {
        \\    take(b)
        \\    return b
        \\}
    ,
        \\t.cell:11:12: error: use of 'b' after it was moved
        \\t.cell:10:10: note: 'b' was moved here by the call to 'take'
        \\
    );
}

test "R3: a whole exclusive borrow cannot be moved out of" {
    try expectDiagnostics(prelude ++
        \\pub fn steal(exclusive b: Buffer) -> Buffer {
        \\    return b
        \\}
    ,
        \\t.cell:10:12: error: cannot move out of 'b': it is an exclusive borrow, not an owner
        \\
    );
}

test "R3: an owned field of a shared borrow cannot be moved out of either" {
    try expectDiagnostics(prelude ++
        \\pub fn peek(shared b: Buffer) -> [Byte] {
        \\    return b.data
        \\}
    ,
        \\t.cell:10:12: error: cannot move out of 'b.data': it is a shared borrow, not an owner
        \\
    );
}

test "R3 accepts returning a copy field of a shared borrow" {
    // This is `read_only` from examples/ownership.cell. It is legal only
    // because `Buffer.len` is declared `copy`, which R12 exempts from R3.
    try expectAccepted(prelude ++
        \\pub fn read_only(shared b: Buffer) -> Int {
        \\    return b.len
        \\}
    );
}

test "R18: an owned binding cannot be initialized from a sigil borrow" {
    // The live double free this rule closes, in its smallest form. Measured
    // at `b61a107` BEFORE the rule existed: `cell check` exit 0, the emitted C
    // carrying TWO `cell_slice_free` calls for one buffer, and running it
    // under AddressSanitizer `attempting double-free` at exit 134.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    let owned e = &buf
        \\    grow(exclusive buf, 1)
        \\}
    ,
        \\t.cell:11:19: error: cannot bind a borrow of 'buf' to the 'owned' binding 'e': a borrow does not confer ownership
        \\t.cell:11:19: note: R18: an 'owned' binding is destroyed at the end of its scope (R16), so binding one to a borrow frees the lender's value twice; write 'let shared e' or 'let exclusive e' to hold the borrow
        \\
    );
}

test "R18: every borrow spelling reaches the same verdict, including the two that did not crash" {
    // THE POINT OF THE RULE. `examples/borrows.cell` states that the sigil and
    // keyword spellings are the same construct, and before this rule they were
    // not treated as one: `&buf` and `&mut buf` were exit-134 double frees
    // while `shared buf` and `exclusive buf` silently MOVED the lender under a
    // written `shared` prefix and exited 0. A fix that left them split would
    // be wrong even where the split is safe-versus-safe, so the table asserts
    // one verdict rather than two.
    //
    // The binding prefix is varied too, because R1 makes an omitted annotation
    // `owned`: `let e = &buf` is the same program as `let owned e = &buf` and
    // was the same crash.
    const prefixes = [_][]const u8{ "let owned", "let", "var owned", "var" };
    const spellings = [_][]const u8{
        "&buf",
        "&mut buf",
        "&var buf",
        "&exclusive buf",
        "shared buf",
        "exclusive buf",
        "shared &buf",
        "exclusive &buf",
    };
    for (prefixes) |prefix| {
        for (spellings) |spelling| {
            var src_buf: [1024]u8 = undefined;
            const src = try std.fmt.bufPrint(&src_buf,
                \\{s}pub fn main() {{
                \\    var owned buf = Buffer {{ data: [], len: 0 }}
                \\    {s} e = {s}
                \\}}
            , .{ prelude, prefix, spelling });

            var h: Harness = .init();
            defer h.deinit();
            var out_buf: [4096]u8 = undefined;
            const out = try h.run(src, &out_buf, false);
            if (std.mem.indexOf(u8, out, "a borrow does not confer ownership") == null) {
                std.debug.print(
                    "\n`{s} e = {s}` was NOT refused by R18. Diagnostics:\n{s}\n",
                    .{ prefix, spelling, out },
                );
                return error.SpellingNotRefused;
            }
        }
    }
}

test "R18 refuses a borrow reached through a branch and a callee that returns one" {
    // `borrowSource` descends into both arms of an `if` and both sides of a
    // `match`, and reads a callee's declared return type. Neither is a
    // spelling anyone would think to enumerate, and both are refused because
    // the question is asked of the classifier rather than of a list.
    //
    // Two things this test pins that are not the rule itself. The error is
    // reported at the BRANCH that supplies the borrow (column 31, the `&buf`
    // inside the `then` arm) rather than at the `if`, because the diagnostic
    // carries the classified sub-expression's span. And R8 fires first on the
    // declaration `-> shared Buffer`: a function returning a borrow cannot be
    // declared in this language at all, so `borrowSource`'s call arm is
    // reachable only in a module R8 has already refused. That is stated here
    // rather than left to look like coverage the rule does not have.
    try expectDiagnostics(prelude ++
        \\pub fn lend(shared b: Buffer) -> shared Buffer;
        \\pub fn main() {
        \\    var copy c = 0
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    let owned e = if c == 0 { &buf } else { &buf }
        \\    let owned f = lend(shared buf)
        \\}
    ,
        \\t.cell:9:1: error: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:9:1: note: return an 'owned' or 'arc' value instead
        \\t.cell:13:31: error: cannot bind a borrow of 'buf' to the 'owned' binding 'e': a borrow does not confer ownership
        \\t.cell:13:31: note: R18: an 'owned' binding is destroyed at the end of its scope (R16), so binding one to a borrow frees the lender's value twice; write 'let shared e' or 'let exclusive e' to hold the borrow
        \\t.cell:14:19: error: cannot bind the borrow returned by 'lend' to the 'owned' binding 'f': a borrow does not confer ownership
        \\t.cell:14:19: note: R18: an 'owned' binding is destroyed at the end of its scope (R16), so binding one to a borrow frees the lender's value twice; write 'let shared f' or 'let exclusive f' to hold the borrow
        \\
    );
}

test "R18 leaves an owned binding of a value alone" {
    // The neighbours the rule must not eat, and the reason it is asked only of
    // an `owned` binding whose initializer classifies as a BORROW: a literal,
    // a fresh aggregate, a call returning a value, and a move of an owned
    // place are all still legal, and so are the `shared` and `exclusive`
    // bindings that hold a borrow properly.
    try expectAccepted(prelude ++
        \\pub fn make() -> Buffer;
        \\pub fn main() {
        \\    let owned a = Buffer { data: [], len: 0 }
        \\    let owned b = make()
        \\    let owned c = b
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    let shared s = &buf
        \\    let n = read(shared buf)
        \\    let m = s.len
        \\}
    );
}

test "R3a: assigning a fresh value revives a moved-from var" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\    buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\}
    );
}

test "R3a and R14: reviving a let binding is an immutable assignment, not a revival" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\    buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\}
    ,
        \\t.cell:12:5: error: cannot assign to immutable binding 'buf'
        \\t.cell:10:5: note: 'buf' is declared immutable here
        \\t.cell:13:10: error: use of 'buf' after it was moved
        \\t.cell:11:10: note: 'buf' was moved here by the call to 'take'
        \\
    );
}

test "R14: assignment to an immutable binding names it and points at the let" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let copy x = 1
        \\    x = 2
        \\}
    ,
        \\t.cell:11:5: error: cannot assign to immutable binding 'x'
        \\t.cell:10:5: note: 'x' is declared immutable here
        \\
    );
}

test "R14: a field write through an exclusive parameter is allowed" {
    // examples/ownership.cell's `grow` body. The old checker accepted this by
    // failing to look up the joined path at all; here the lookup succeeds and
    // the exclusive borrow is what grants the write.
    try expectAccepted(prelude ++
        \\pub fn widen(exclusive buf: Buffer, shared extra: Int) {
        \\    let copy new_len = buf.len + extra
        \\    buf.len = new_len
        \\}
    );
}

test "R14: a field write through an immutable let is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    buf.len = 3
        \\}
    ,
        \\t.cell:11:5: error: cannot assign to immutable binding 'buf'
        \\t.cell:10:5: note: 'buf' is declared immutable here
        \\
    );
}

test "R15: an ampersand argument whose mode differs from the parameter is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(&buf)
        \\}
    ,
        \\t.cell:11:10: error: 'take' expects parameter 'b' as 'owned', but the argument is passed as 'shared'
        \\
    );
}

test "R15: a keyword-prefixed ampersand argument whose mode differs is still rejected" {
    // Grammar is `primary = [ownership] unary`, so `shared &buf` is
    // `.annotated` wrapping `&buf`. The inner sigil is still R15 explicit
    // mode; peeling `.annotated` must not drop it.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(shared &buf)
        \\}
    ,
        \\t.cell:11:10: error: 'take' expects parameter 'b' as 'owned', but the argument is passed as 'shared'
        \\
    );
}

test "R15: an ampersand argument matching the parameter is accepted" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    grow(&mut buf, 16)
        \\    read(&buf)
        \\}
    );
}

test "R15: a keyword argument whose mode differs from the parameter is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(shared buf)
        \\}
    ,
        \\t.cell:11:10: error: 'take' expects parameter 'b' as 'owned', but the argument is passed as 'shared'
        \\
    );
}

test "R15: a keyword argument matching the parameter is accepted" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    grow(exclusive buf, 16)
        \\    take(owned buf)
        \\}
    );
}

test "R15: omitting the call-site prefix infers from the parameter" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\}
    );
}

test "R4: any number of shared borrows may coexist" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let shared a = buf
        \\    let shared b = buf
        \\    read(&buf)
        \\}
    );
}

test "R5: a shared borrow while an exclusive one is live is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "R5: an exclusive borrow while a shared one is live is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let shared s = buf
        \\    grow(&mut buf, 1)
        \\    read_shared(s)
        \\}
    ,
        \\t.cell:12:15: error: cannot borrow 'buf' as exclusive: it is already borrowed as shared
        \\t.cell:11:20: note: the shared borrow starts here and lasts to the end of this block
        \\
    );
}

test "R5: reading the whole owner through a live exclusive borrow is rejected" {
    // R5's own example wording, naming the place as a whole. `println` has no
    // signature here, so the argument is a plain read rather than a move.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    println(buf)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:13: error: cannot use 'buf' while it is exclusively borrowed
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "R5: reading a field of the owner through a live exclusive borrow is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    let copy n = buf.len
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:18: error: cannot use 'buf.len' while it is exclusively borrowed
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "NLL slice 1: a named loan whose holder is mentioned nowhere again is accepted" {
    // This test was a REJECTION carrying a note that said NLL would accept it.
    // It is now that acceptance. `e` is mentioned nowhere after its own `let`,
    // so the loan is dead by the time `read(&buf)` wants a shared borrow.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf)
        \\}
    );

    // MUTATION 1, the forward half. One later use of the holder and the same
    // program is rejected again. Without this the acceptance would pass even
    // if the predicate never read the forward scan at all.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );

    // MUTATION 2, the window half. One earlier mention in a value position,
    // which copies the loan into a holder used later, and it is rejected
    // again. `f` stays `ineligible` rather than being followed: slice 3 is
    // deliberately absent.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    let exclusive f = e
        \\    read(&buf)
        \\    use_it(f)
        \\}
    ,
        \\t.cell:13:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "NLL slice 2: a holder passed as a direct call argument is dead after that call" {
    // The shape users actually hit. The mention of `e` between the loan and
    // the conflict is a direct call argument, which R8 proves cannot propagate
    // the reference anywhere, so the window scan lets it through.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    grow(exclusive e, shared 1)
        \\    read(&buf)
        \\}
    );

    // MUTATION 1, the forward half.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    grow(exclusive e, shared 1)
        \\    read(&buf)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:13:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );

    // MUTATION 2, the window half: the SAME mention of `e`, moved out of the
    // whitelisted position into a `let` initializer. The whitelist is what
    // separates these two programs, and nothing else about them differs.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    let copy n = use_it(e) + e.len
        \\    read(&buf)
        \\}
    ,
        \\t.cell:13:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "NLL: the acceptance reaches all four conflict sites, including assignment" {
    // `checkAssign` was the one conflict site that never consulted the NLL
    // predicate. Three sites enumerated, a fourth missed. Each of these four
    // programs is rejected by the lexical model and accepted here, and each
    // exercises a different site: createLoan, readPlace, movePlace, and the
    // assignment.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf)
        \\}
    );
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    let copy n = buf.len
        \\}
    );
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    take(buf)
        \\}
    );
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    buf.len = 1
        \\}
    );
}

test "NLL: a use of the holder on the far side of a while back edge keeps the loan live" {
    // The forward scan counts the ENCLOSING statement in full and recurses
    // into a `while`'s condition and body, so a use that only a second
    // iteration reaches still reads as "used". Without that this would be
    // accepted and the second iteration would alias.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    while read(&buf) > 0 {
        \\        let copy n = use_it(e)
        \\    }
        \\}
    ,
        \\t.cell:12:17: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "NLL soundness rests on R8: a borrow still cannot escape by return or struct field" {
    // NAMED FOR THE INVARIANT ON PURPOSE. The call-argument whitelist in
    // `argPropagatesName` is the entire reason slice 2 can accept anything,
    // and it is sound only because a callee has nowhere to put what it is
    // handed: R8 refuses a returned borrow and a borrow in a struct field,
    // and Cell has no lifetime parameters, no references inside aggregates
    // and no closures. If lifetime parameters ever land, this test fails, and
    // when it does the NLL acceptance must be revisited with it rather than
    // this test being updated to match the new behaviour.
    try expectDiagnostics(prelude ++
        \\pub fn peek(shared b: Buffer) -> shared Buffer {
        \\    return b
        \\}
    ,
        \\t.cell:10:12: error: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:10:12: note: return an 'owned' or 'arc' value instead
        \\
    );
    try expectDiagnostics(
        \\pub struct View {
        \\    exclusive buf: Buffer
        \\}
    ,
        // "a exclusive" is the message `checkStructFields` actually prints:
        // it interpolates `LoanKind.word()` with a fixed article. Pinned as
        // it is rather than fixed here, so this change touches no diagnostic
        // text it does not own.
        \\t.cell:1:1: error: cannot store a exclusive borrow in field 'buf': Cell has no lifetime annotations, so the borrow cannot be proven to outlive the value
        \\t.cell:1:1: note: store an 'owned' or 'arc' value instead
        \\
    );
}

test "0.3: a holder that was copied into a second borrow behind the conflict is not dead" {
    // The forward scan alone said "'e' is never used again" here and printed
    // a note claiming NLL would accept this. NLL REJECTS it: `f` aliases `buf`
    // through `e`, and `f` is used afterwards. `nameUsedFrom` starts at the
    // conflicting statement and can never see the `let exclusive f = e`
    // BEHIND it, which is what the window scan is for.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    let exclusive f = e
        \\    read(&buf)
        \\    grow(exclusive f, shared 1)
        \\}
    ,
        \\t.cell:13:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "0.3: a holder used inside a match GUARD is not dead" {
    // A match arm has two expression positions and the forward scan walked
    // one. `exprUsesName` recursed into `arm.body` and not `arm.guard`, so
    // this printed the NLL note, and under the acceptance that predicate now
    // gates it would have ended a loan the guard still holds.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf)
        \\    let copy m = match 1 { _ if use_it(shared e) > 0 => 1, _ => 2 }
        \\}
    ,
        \\t.cell:12:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "0.3 exception 1: a borrow created as a call argument ends with its statement" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    read(&buf)
        \\    grow(&mut buf, 16)
        \\    take(buf)
        \\}
    );
}

test "0.3 exception 2: a borrow created in a condition ends when the if finishes" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    if read(&buf) > 0 {
        \\        let copy z = 1
        \\    }
        \\    grow(&mut buf, 16)
        \\}
    );
}

test "R6: two disjoint field borrows coexist" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive d = &mut buf.data
        \\    let exclusive l = &mut buf.len
        \\    use_it(d)
        \\}
    );
}

test "R6: moving the owner while one of its fields is borrowed is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive d = &mut buf.data
        \\    take(buf)
        \\    use_it(d)
        \\}
    ,
        \\t.cell:12:10: error: cannot move 'buf': its field 'buf.data' is borrowed
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "R6: borrowing a field while the whole place is borrowed exclusively is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf.len)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:11: error: cannot borrow 'buf.len' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "places are keyed by binding identity, so sibling blocks do not share a move" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    {
        \\        let owned a = Buffer { data: [], len: 0 }
        \\        take(a)
        \\    }
        \\    {
        \\        let owned a = Buffer { data: [], len: 0 }
        \\        take(a)
        \\    }
        \\}
    );
}

test "shadowing in one block introduces a new place rather than reviving the old one" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned a = Buffer { data: [], len: 0 }
        \\    take(a)
        \\    let owned a = Buffer { data: [], len: 0 }
        \\    take(a)
        \\}
    );
}

test "a parameter of one function is not visible in the next" {
    // OWNERSHIP.md 0.4: typecheck.zig's flat symbol table leaks parameters
    // across functions. This checker's per-function scope does not.
    try expectAccepted(prelude ++
        \\pub fn first(owned b: Buffer) { take(b) }
        \\pub fn second() -> Int { return 1 }
    );
}

test "a move inside one branch of an if kills the place after the if" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    if 1 > 0 {
        \\        take(buf)
        \\    }
        \\    read(&buf)
        \\}
    ,
        \\t.cell:14:11: error: use of 'buf' after it was moved
        \\t.cell:12:14: note: 'buf' was moved here by the call to 'take'
        \\
    );
}

test "0.3 exception 2: a condition's borrow is still live inside the branches" {
    // The exception narrows a condition borrow to the end of the `if`, not to
    // the end of the condition, so the branch bodies are inside it. This is
    // the checker's conservatism showing: NLL would end the loan at the
    // comparison. There is no named holder to point at, so no NLL note.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    if read(&buf) > 0 {
        \\        take(buf)
        \\    }
        \\}
    ,
        \\t.cell:12:14: error: cannot move 'buf' while it is borrowed
        \\t.cell:11:14: note: the shared borrow starts here and lasts until this statement completes
        \\
    );
}

test "a revival inside one branch only is rejected conservatively" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\    if 1 > 0 {
        \\        buf = Buffer { data: [], len: 0 }
        \\    }
        \\    read(&buf)
        \\}
    ,
        \\t.cell:15:11: error: use of 'buf' after it was moved
        \\t.cell:11:10: note: 'buf' was moved here by the call to 'take'
        \\
    );
}

test "an unknown callee's argument is read rather than moved" {
    // Without a signature there is no parameter mode to infer from, so
    // inventing a move would reject every call to a builtin.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    println(buf)
        \\    take(buf)
        \\}
    );
}

test "examples/ownership.cell is accepted verbatim" {
    // Inlined because @embedFile cannot reach outside the module root and the
    // build's `examples` step only checks hello.cell. The text below is the
    // code of examples/ownership.cell with its comments removed.
    try expectAccepted(
        \\pub struct Buffer {
        \\    owned data: [Byte]
        \\    copy len: Int
        \\}
        \\pub fn grow(exclusive buf: Buffer, shared extra: Int) {
        \\    let copy new_len = buf.len + extra
        \\    buf.len = new_len
        \\}
        \\pub fn share_name(arc name: String) -> arc String {
        \\    return name
        \\}
        \\pub fn take(owned b: Buffer) {
        \\}
        \\pub fn read_only(shared b: Buffer) -> Int {
        \\    return b.len
        \\}
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    grow(exclusive buf, shared 16)
        \\    let copy n = read_only(shared buf)
        \\    take(owned buf)
        \\}
    );
}

test "with a source buffer the caret lands on the offending column" {
    var h: Harness = .init();
    defer h.deinit();
    const src =
        \\pub fn take(owned b: Buffer) { }
        \\pub fn main() {
        \\    let owned buf = 0
        \\    take(buf)
        \\    take(buf)
        \\}
    ;
    var buf: [1024]u8 = undefined;
    const out = try h.run(src, &buf, true);
    try std.testing.expectEqualStrings(
        \\t.cell:5:10: error: use of 'buf' after it was moved
        \\        take(buf)
        \\             ^~~
        \\t.cell:4:10: note: 'buf' was moved here by the call to 'take'
        \\        take(buf)
        \\             ^~~
        \\
    , out);
}

test "pathPrefix compares whole segments, not bytes" {
    try std.testing.expect(pathPrefix("", "len"));
    try std.testing.expect(pathPrefix("len", "len"));
    try std.testing.expect(pathPrefix("a", "a.b"));
    try std.testing.expect(!pathPrefix("a", "ab"));
    try std.testing.expect(!pathPrefix("a.b", "a"));
    try std.testing.expect(!pathPrefix("le", "len"));
}

test "R8: a function may not return a shared borrow" {
    try expectDiagnostics(prelude ++
        \\pub fn peek(shared b: Buffer) -> shared Buffer {
        \\    return b
        \\}
    ,
        \\t.cell:10:12: error: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:10:12: note: return an 'owned' or 'arc' value instead
        \\
    );
}

test "R8: a function may not return an exclusive borrow" {
    try expectDiagnostics(prelude ++
        \\pub fn leak(exclusive b: Buffer) -> exclusive Buffer {
        \\    return b
        \\}
    ,
        \\t.cell:10:12: error: cannot return an exclusive borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:10:12: note: return an 'owned' or 'arc' value instead
        \\
    );
}

test "R8: a bodyless shared-borrow return still errors at the function" {
    try expectDiagnostics(prelude ++
        \\pub fn peek(shared b: Buffer) -> shared Buffer;
    ,
        \\t.cell:9:1: error: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:9:1: note: return an 'owned' or 'arc' value instead
        \\
    );
}

test "R8: a struct field may not store a shared borrow" {
    try expectDiagnostics(
        \\pub struct View {
        \\    shared buf: Buffer
        \\}
    ,
        \\t.cell:1:1: error: cannot store a shared borrow in field 'buf': Cell has no lifetime annotations, so the borrow cannot be proven to outlive the value
        \\t.cell:1:1: note: store an 'owned' or 'arc' value instead
        \\
    );
}

test "R10: an arc place may not be passed to an owned parameter" {
    // Ruled a REFUSAL rather than a retain, and the reason is that a retain
    // cannot fix it. `owned [T]` and `shared [T]` are the same C type
    // (`cell_slice_t` by value), so the C backend's unbox emitted
    // `take((*(const cell_slice_t *)xs.ptr))`, which compiles clean at
    // -Werror. `runtime/cell_rt.h` section 7 makes an `owned` callee
    // responsible for the eventual free, and `cell_slice_drop_glue` then
    // frees the same BUFFER again when the box dies. `cell_arc_clone`
    // increments a refcount and the buffer is not what the refcount governs,
    // so the only correct answer is to reject the conversion.
    try expectDiagnostics(
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    let copy n = take(owned xs)
        \\}
    ,
        \\t.cell:4:29: error: cannot pass 'arc' value 'xs' to 'owned' parameter 'xs': ownership is shared and cannot be made unique
        \\t.cell:4:29: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10: an arc place may not be bound to an owned binding" {
    // The escape the parameter guard did not reach. `let owned ys: [Int] = xs`
    // emitted `cell_slice_t ys = *(const cell_slice_t *)xs.ptr;` and then BOTH
    // `cell_slice_free(&ys)` and the box's own glue freed the same buffer:
    // AddressSanitizer double free, exit 134, while `cell check` exited 0 and
    // `-Wall -Wextra -Werror` was silent.
    try expectDiagnostics(
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    let owned ys: [Int] = xs
        \\}
    ,
        \\t.cell:3:27: error: cannot bind 'arc' value 'xs' to 'owned' binding 'ys': ownership is shared and cannot be made unique
        \\t.cell:3:27: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10: an arc place may not be assigned to an owned place" {
    // The same double free reached by writing into an already-declared
    // `owned` place rather than declaring a new one. Found by enumerating the
    // positions rather than by review, which is the point of enumerating.
    try expectDiagnostics(
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    var owned ys: [Int] = [9]
        \\    ys = xs
        \\}
    ,
        \\t.cell:4:10: error: cannot assign 'arc' value 'xs' to 'owned' place 'ys': ownership is shared and cannot be made unique
        \\t.cell:4:10: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10: an arc place may not be stored in an owned struct field" {
    // Not a double free today, and refused anyway: this backend never drops a
    // `record` shape, so the field's buffer is freed once by the box's glue
    // and the record merely outlives it. It is the same illegal conversion
    // and becomes a double free the moment struct drops land.
    try expectDiagnostics(
        \\pub struct Buf { owned data: [Int]  copy len: Int }
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    let owned b = Buf { data: xs, len: 3 }
        \\}
    ,
        \\t.cell:4:31: error: cannot store 'arc' value 'xs' in 'owned' field 'data': ownership is shared and cannot be made unique
        \\t.cell:4:31: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10 is asked of the EXPRESSION, so a value position escapes none of the four positions" {
    // R10 enumerated four POSITIONS and asserted a property of every
    // consumption. Each position asked `placeOf` first, and a `match` is
    // valued and is not a place, so all four let it through. Measured before
    // the fix, on the same `arc` binding and the same semantic operation:
    //
    //     take(owned xs)                            refused, exit 1
    //     take(owned match c { 0 => xs, _ => xs })  ACCEPTED, exit 0
    //
    // and identically for the `let`, the assignment and the struct field. The
    // emitted C unboxed the arc and handed the box's slice by value to an
    // `owned` parameter, which is the exact shape R10's text names as the
    // double free it exists to prevent. It was masked only by the
    // `cell_arc_clone` in the value temporary holding the refcount off zero.
    //
    // Same axis, place versus value, as `arc` use-after-frees three and four.
    try expectDiagnostics(
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let copy c = 0
        \\    let arc xs = [1, 2, 3]
        \\    let copy n = take(owned match c { 0 => xs, _ => xs })
        \\}
    ,
        \\t.cell:5:44: error: cannot pass 'arc' value 'xs' to 'owned' parameter 'xs': ownership is shared and cannot be made unique
        \\t.cell:5:44: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    try expectDiagnostics(
        \\pub fn main() {
        \\    let copy c = 0
        \\    let arc xs = [1, 2, 3]
        \\    let owned ys: [Int] = match c { 0 => xs, _ => xs }
        \\}
    ,
        \\t.cell:4:42: error: cannot bind 'arc' value 'xs' to 'owned' binding 'ys': ownership is shared and cannot be made unique
        \\t.cell:4:42: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    try expectDiagnostics(
        \\pub fn main() {
        \\    let copy c = 0
        \\    let arc xs = [1, 2, 3]
        \\    var owned ys: [Int] = []
        \\    ys = match c { 0 => xs, _ => xs }
        \\}
    ,
        \\t.cell:5:25: error: cannot assign 'arc' value 'xs' to 'owned' place 'ys': ownership is shared and cannot be made unique
        \\t.cell:5:25: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    try expectDiagnostics(
        \\pub struct Box { owned items: [Int] }
        \\pub fn main() {
        \\    let copy c = 0
        \\    let arc xs = [1, 2, 3]
        \\    let owned b = Box { items: match c { 0 => xs, _ => xs } }
        \\}
    ,
        \\t.cell:5:47: error: cannot store 'arc' value 'xs' in 'owned' field 'items': ownership is shared and cannot be made unique
        \\t.cell:5:47: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10 also looks through an if branch and a block tail, which typecheck alone would hide" {
    // Neither of these can reach a typed `owned` position through `cell
    // check` today, because typecheck gives an `if`-expression and a block
    // the type `()` and refuses the argument first. That is an ACCIDENT of
    // the type checker, not enforcement of an ownership rule, and R10's own
    // text objects elsewhere to a rule whose enforcement depends on a
    // coincidence of two types. Borrowck runs independently of typecheck, so
    // this harness reaches both forms and pins them refused on their own
    // merits: when `if` grows a real type, nothing here has to change.
    try expectDiagnostics(
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let copy c = 0
        \\    let arc xs = [1, 2, 3]
        \\    let copy n = take(owned if c > 0 { xs } else { xs })
        \\}
    ,
        \\t.cell:5:40: error: cannot pass 'arc' value 'xs' to 'owned' parameter 'xs': ownership is shared and cannot be made unique
        \\t.cell:5:40: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    try expectDiagnostics(
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    let copy n = take(owned { xs })
        \\}
    ,
        \\t.cell:4:31: error: cannot pass 'arc' value 'xs' to 'owned' parameter 'xs': ownership is shared and cannot be made unique
        \\t.cell:4:31: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10 refuses only the owned conversion, not the arc binding itself" {
    // The guard must not swallow what builds an `arc [T]` in the first place.
    try expectAccepted(
        \\pub fn read(shared xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    let copy n = read(shared xs)
        \\}
    );
}

test "R10 leaves a non-arc owned argument moving exactly as before" {
    // The refusal sits in front of `movePlace`, so the move path it guards
    // has to still fire for every other ownership mode.
    try expectDiagnostics(prelude ++
        \\pub fn f() {
        \\    let owned b = Buffer { data: [], len: 0 }
        \\    take(b)
        \\    take(b)
        \\}
    ,
        \\t.cell:12:10: error: use of 'b' after it was moved
        \\t.cell:11:10: note: 'b' was moved here by the call to 'take'
        \\
    );
}

test "R10 axis 2, the arc SOURCE: a call result typed 'arc' is refused at every site" {
    // THE LIVE DOUBLE FREE THIS CLOSED, and it was live rather than masked.
    // `fresh() -> arc [Int]` hands back a box; the caller's temporary drops
    // it; `take(owned ...)` frees the same buffer through the unbox. Measured
    // end to end before the fix: `cell check` exit 0, `cc -Wall -Wextra
    // -Werror -fsanitize=address` exit 0, running it exit 134, with frames
    // cell_slice_free <- cell_slice_drop_glue <- cell_arc_drop <- cell_main.
    //
    // It escaped because the `arc`-ness comes from a SIGNATURE's return type
    // and not from a binding annotation, so neither the place machinery nor
    // the expression-shape widening of `23353e9` could see it. That is a
    // different axis from place-versus-value, and `23353e9`'s message claiming
    // to land "before any such change and not after" was false for it: the
    // unmasking landed in `460b9a3`, seven commits earlier, measured by
    // emitting this program at both commits.
    //
    // examples/rejected/arc_call_to_owned.cell is the corpus form.
    try expectDiagnostics(
        \\pub fn fresh() -> arc [Int];
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let copy n = take(owned fresh())
        \\}
    ,
        \\t.cell:4:29: error: cannot pass 'arc' value 'fresh()' to 'owned' parameter 'xs': ownership is shared and cannot be made unique
        \\t.cell:4:29: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    // The `let` position. Before this it emitted no drop at all, so it was a
    // LEAK rather than a double free: an undocumented sixth leak gap, now
    // closed by refusal rather than by a release.
    try expectDiagnostics(
        \\pub fn fresh() -> arc [Int];
        \\pub fn main() {
        \\    let owned ys: [Int] = fresh()
        \\}
    ,
        \\t.cell:3:27: error: cannot bind 'arc' value 'fresh()' to 'owned' binding 'ys': ownership is shared and cannot be made unique
        \\t.cell:3:27: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    // Through a value position, so the two widenings compose rather than one
    // shadowing the other.
    try expectDiagnostics(
        \\pub fn fresh() -> arc [Int];
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let copy c = 0
        \\    let copy n = take(owned match c { 0 => fresh(), _ => fresh() })
        \\}
    ,
        \\t.cell:5:44: error: cannot pass 'arc' value 'fresh()' to 'owned' parameter 'xs': ownership is shared and cannot be made unique
        \\t.cell:5:44: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10 axis 3, the consumption SITE: a list element and a return were never asked" {
    // A list literal copies each element by value into a buffer the list owns,
    // so every element is made unique. `let owned zss: [[Int]] = [xs, xs]`
    // with an `arc [Int]` place passed `cell check` and compiled clean at
    // -Werror. It is not a use-after-free today only because slice elements
    // are never released, which is a separately disclosed gap; closing that
    // gap detonates this.
    try expectDiagnostics(
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    let owned zss: [[Int]] = [xs, xs]
        \\}
    ,
        \\t.cell:3:31: error: cannot store 'arc' value 'xs' in an 'owned' list element: ownership is shared and cannot be made unique
        \\t.cell:3:31: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\t.cell:3:35: error: cannot store 'arc' value 'xs' in an 'owned' list element: ownership is shared and cannot be made unique
        \\t.cell:3:35: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    // A `-> [Int]` return slot is `owned` by R1. This one was already refused
    // downstream, by `cc` rejecting `cell_slice_t x = cell_arc_clone(...)`,
    // which is protection by a coincidence of two C types and exactly what
    // R10's own text objects to. Refused here so the rule holds for every
    // type rather than for the types whose C spellings happen to differ.
    try expectDiagnostics(
        \\pub fn f() -> [Int] {
        \\    let arc xs = [1, 2, 3]
        \\    return xs
        \\}
    ,
        \\t.cell:3:12: error: cannot return 'arc' value 'xs' from 'owned' function 'f': ownership is shared and cannot be made unique
        \\t.cell:3:12: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10 refuses a source it cannot prove is not arc, rather than permitting it" {
    // The structural point of the whole change. The classifier used to return
    // `?Place`, so any form it did not recognise fell out as `null` and was
    // PERMITTED: silence meant safe, and silence is what an unenumerated form
    // produces. Every one of the three widenings was a form that fell into
    // that default. Now an undecidable source is `.unknown` and refused.
    //
    // `cell check` also reports its own `unknown identifier` here, so no
    // program that was otherwise accepted is lost by this; what is gained is
    // that the next unenumerated form fails closed.
    try expectDiagnostics(
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let copy n = take(owned nowhere())
        \\}
    ,
        \\t.cell:3:29: error: cannot pass the result of the unresolved callee 'nowhere' to 'owned' parameter 'xs': its ownership cannot be resolved here
        \\t.cell:3:29: note: R10 refuses what it cannot prove is not 'arc': an 'arc' value made unique is freed twice
        \\
    );
}

test "R10's widening does not over-refuse a call result, an arc return, or an enum variant" {
    // The controls for the three arms most likely to fail closed by accident.
    // An `owned` call result is the whole point of `owned`.
    try expectAccepted(
        \\pub fn fresh() -> [Int];
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let copy n = take(owned fresh())
        \\}
    );
    // `-> arc T` returning its own `arc` local is the legal arc-to-arc case,
    // and it is what the reproducer's `fresh` is made of: refusing it would
    // have made the double free unreproducible instead of refused.
    try expectAccepted(
        \\pub fn fresh() -> arc [Int] {
        \\    let arc xs: [Int] = [1, 2, 3]
        \\    return xs
        \\}
    );
    // A qualified enum variant is a `field` whose base is an `ident` that is
    // not a binding, so `placeOf` fails on it exactly as it fails on
    // `fresh().len`. Told apart by the enum table, and found by the gate:
    // examples/pairing/geometry.body returns one, and the first draft of this
    // change refused it.
    try expectAccepted(
        \\pub enum Quadrant { First, Second }
        \\pub fn q() -> Quadrant {
        \\    return Quadrant.First
        \\}
    );
    // A plain owned place in the parameter position, the case the whole rule
    // has to keep accepting.
    try expectAccepted(
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let owned xs: [Int] = [1, 2, 3]
        \\    let copy n = take(owned xs)
        \\}
    );
}

test "R10's total verdict needs a struct type inferred from a CALL, or it refuses valid code" {
    // The cost of a verdict with no permissive default: every annotation it
    // cannot resolve becomes load-bearing. `Binding.struct_name` was inferred
    // from a declared type and from a struct literal, but not from a call, so
    //
    //     let owned s = make()          // make() -> Session
    //     take(owned s.data)            // Session { owned data: [Int] }
    //
    // left `struct_name` null, `placeOwnership` returned null on the first
    // segment, and the field's plainly `owned` annotation was never read.
    // Measured: accepted at `b6aadb5`, refused after the widening, with NO
    // typecheck error alongside it, i.e. a valid program lost. `checkLet` now
    // reads the callee's return type, the same lookup `arcCallResult` does.
    try expectAccepted(
        \\pub struct Session {
        \\    owned data: [Int]
        \\    copy id: Int
        \\}
        \\pub fn make() -> Session;
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let owned s = make()
        \\    let copy n = take(owned s.data)
        \\}
    );
    // The annotated form was never affected, and is here so a future change
    // that breaks only one of the two is caught rather than half-caught.
    try expectAccepted(
        \\pub struct Session {
        \\    owned data: [Int]
        \\    copy id: Int
        \\}
        \\pub fn make() -> Session;
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let owned s: Session = make()
        \\    let copy n = take(owned s.data)
        \\}
    );
    // Resolving the type is not the same as permitting the field, and this is
    // the direction that matters: an `arc` field reached through an
    // unannotated `let` is now REFUSED where the old permissive default let it
    // through, so the inference strengthens the rule rather than widening a
    // hole in it.
    try expectDiagnostics(
        \\pub struct Session {
        \\    arc name: String
        \\    copy id: Int
        \\}
        \\pub fn make() -> Session;
        \\pub fn take_str(owned s: String) -> Int;
        \\pub fn main() {
        \\    let owned s = make()
        \\    let copy n = take_str(owned s.name)
        \\}
    ,
        \\t.cell:9:33: error: cannot pass 'arc' value 's.name' to 'owned' parameter 's': ownership is shared and cannot be made unique
        \\t.cell:9:33: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R2.b: a value shape reaching an owned position was READ, not moved, and double freed" {
    // THE DEFECT. R2 enumerates the forms that move a PLACE, and every one of
    // its consumption sites asked `placeOf` first: a place moved, and anything
    // else fell through to `checkExpr`, which only reads. A `match` is not a
    // place, so
    //
    //     let owned s2: String = match c { 0 => s1, _ => s1 }
    //
    // read `s1`. `wasMoved(s1)` stayed false, codegen's `pendingDrops` kept
    // BOTH `s1` and `s2`, and `emitValueInto`'s leaf emitted a bitwise
    // `_cell_t0 = s1;`, so two headers held one buffer. Measured end to end
    // against `zig-out/bin/cell` built at `0e82266`:
    //
    //     cell check                  exit 0
    //     cc -fsanitize=address       exit 0
    //     running it                  exit 134
    //     AddressSanitizer: attempting double-free, under cell_string_free
    //
    // This has nothing to do with `arc`: it is ordinary `owned String` code,
    // and it predates every line of the `arc` work. It is R10 axis 1 in the
    // general rule R10 is a special case of.
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned s1 = mk()
        \\    let owned s2: String = match c { 0 => s1, _ => s1 }
        \\}
    ,
        \\t.cell:5:43: error: cannot bind the place 's1' reached through a branch to 'owned' binding 's2': which owned place it gives up cannot be resolved here
        \\t.cell:5:43: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
}

test "R2.b is asked at all six owned consumption sites, four of which were live" {
    // FOUR of these were AddressSanitizer double frees at exit 134, measured
    // at `0e82266` with the same `mk() -> String` and the same `match`: the
    // `let` above, the assignment, the call argument and the return. The
    // opening brief named the `let`, the assignment, the struct field and the
    // list element; the call argument and the return are the two it did not
    // name and both were live. That is this repository's recurring
    // undercount, so the sites are enumerated in a test rather than in prose.
    //
    // The remaining two are latent for reasons that belong to other gaps and
    // are refused with the rest rather than left as traps for closing them:
    // a `record` shape is never dropped, and slice elements are never
    // released (OWNERSHIP.md R11).
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned s1 = mk()
        \\    var owned s2: String = mk()
        \\    s2 = match c { 0 => s1, _ => s1 }
        \\}
    ,
        \\t.cell:6:25: error: cannot assign the place 's1' reached through a branch to 'owned' place 's2': which owned place it gives up cannot be resolved here
        \\t.cell:6:25: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn take(owned s: String);
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned s1 = mk()
        \\    take(owned match c { 0 => s1, _ => s1 })
        \\}
    ,
        \\t.cell:6:31: error: cannot pass the place 's1' reached through a branch to 'owned' parameter 's': which owned place it gives up cannot be resolved here
        \\t.cell:6:31: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn pick(copy c: Int) -> String {
        \\    let owned s1 = mk()
        \\    return match c { 0 => s1, _ => s1 }
        \\}
    ,
        \\t.cell:4:27: error: cannot return the place 's1' reached through a branch from 'owned' function 'pick': which owned place it gives up cannot be resolved here
        \\t.cell:4:27: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
    try expectDiagnostics(
        \\pub struct Box { owned items: [Int] }
        \\pub fn fresh() -> [Int];
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned xs: [Int] = fresh()
        \\    let owned b = Box { items: match c { 0 => xs, _ => xs } }
        \\}
    ,
        \\t.cell:6:47: error: cannot store the place 'xs' reached through a branch in owned field 'items': the source is not a fresh owned value
        \\t.cell:6:47: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\
    );
    try expectDiagnostics(
        \\pub fn fresh() -> [Int];
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned xs: [Int] = fresh()
        \\    let owned zss: [[Int]] = [match c { 0 => xs, _ => xs }]
        \\}
    ,
        \\t.cell:5:46: error: cannot store the place 'xs' reached through a branch in an 'owned' list element: which owned place it gives up cannot be resolved here
        \\t.cell:5:46: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
}

test "R2.b covers an if branch and a block tail, which typecheck alone would hide" {
    // Neither reaches a typed `owned` position through `cell check` today:
    // typecheck gives an `if`-expression and a block the type `()` and
    // refuses the initializer first. Measured, both of them. That is an
    // ACCIDENT of the type checker rather than enforcement of this rule, and
    // R10's own text objects to a rule enforced by a coincidence of two
    // types. Borrowck runs independently of typecheck, so its own tests reach
    // both forms and pin them on their own merits.
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned s1 = mk()
        \\    let owned s2 = if c == 0 { s1 } else { s1 }
        \\}
    ,
        \\t.cell:5:32: error: cannot bind the place 's1' reached through a branch to 'owned' binding 's2': which owned place it gives up cannot be resolved here
        \\t.cell:5:32: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    let owned s1 = mk()
        \\    let owned s2 = { s1 }
        \\}
    ,
        \\t.cell:4:22: error: cannot bind the place 's1' reached through a branch to 'owned' binding 's2': which owned place it gives up cannot be resolved here
        \\t.cell:4:22: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
    // An `owned` keyword in front of the value does not get around it.
    // `placeOf` already peels `.annotated`, so this arm adds no move that
    // `placeOf` was not already making: `let owned s2: String = owned s1`
    // already reported use-after-move at `0e82266`, and it still does (the
    // control below). Only the value shape underneath is new.
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned s1 = mk()
        \\    let owned s2: String = owned match c { 0 => s1, _ => s1 }
        \\}
    ,
        \\t.cell:5:49: error: cannot bind the place 's1' reached through a branch to 'owned' binding 's2': which owned place it gives up cannot be resolved here
        \\t.cell:5:49: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
}

test "R2.b moves bindings but owning resource fields refuse place transfers" {
    // THE OVER-REFUSAL CONTROLS. The fix refuses; the risk of a refusal is
    // that it refuses everything, and the risk of routing a move decision
    // through a new classifier is that the move stops happening. This is what
    // proves the move still happens: `s1` is moved, so reading it afterwards
    // is R2's use-after-move. If `ownedMoveSource` ever returned
    // `.no_owned_place` for a plain place, this test would report nothing and
    // codegen's `pendingDrops` would free the buffer twice, which is the
    // defect this whole rule exists to close, reintroduced by its own fix.
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn use_it(shared s: String) -> Int;
        \\pub fn main() {
        \\    let owned s1 = mk()
        \\    let owned s2: String = s1
        \\    let copy n = use_it(shared s1)
        \\}
    ,
        \\t.cell:6:32: error: use of 's1' after it was moved
        \\t.cell:5:28: note: 's1' was moved here by binding it to 's2'
        \\
    );
    // A `match` whose arms are all fresh values owns nothing an existing
    // binding still holds, so it is accepted. This is the common shape and
    // refusing it would have made `match` unusable as an initializer.
    try expectAccepted(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned s2: String = match c { 0 => mk(), _ => mk() }
        \\}
    );
    // Scalar arms, the same claim one type down.
    try expectAccepted(
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned n: Int = match c { 0 => 1, _ => 2 }
        \\}
    );
    // Aggregate partial-move/drop state is absent, so a resource-bearing
    // owned field refuses a place rather than copying its owning header.
    try expectDiagnostics(
        \\pub struct Box { owned s: String }
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    let owned s1 = mk()
        \\    let owned b: Box = Box { s: s1 }
        \\}
    ,
        \\t.cell:5:33: error: cannot store s1 in owned field 's': moving a place into an aggregate is not implemented
        \\t.cell:5:33: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\
    );
    // List-element transfer remains a separate disclosed boundary.
    try expectAccepted(
        \\pub fn fresh() -> [Int];
        \\pub fn main() {
        \\    let owned xs: [Int] = fresh()
        \\    let owned zss: [[Int]] = [xs]
        \\}
    );
}

test "R2.b over-refuses a match over copy places, and the workaround is a name" {
    // NAMED RATHER THAN LEFT TO BE DISCOVERED. This program was accepted at
    // `0e82266`, runs clean, and is now REFUSED:
    //
    //     pub fn pick(copy c: Int, copy a: Int, copy b: Int) -> Int {
    //         return match c { 0 => a, _ => b }
    //     }
    //
    // A `copy` place is exempt from R2 by R12 and `pendingDrops` never drops
    // one, so an exemption for it looks free. It was considered and REJECTED.
    // The exemption would be an enumeration of the ownership modes this
    // backend drops today, asserted over every `copy` place, which is exactly
    // the reasoning failure this rule is the sixteenth instance of; and the
    // neighbouring claim is already false, because `copy String` is spellable
    // and `let owned s: String = a` over one emits a shallow header copy and
    // frees `a`'s buffer through `s`. Refusing costs a program that can be
    // spelled with a name. Accepting costs a free of something still live.
    try expectDiagnostics(
        \\pub fn pick(copy c: Int, copy a: Int, copy b: Int) -> Int {
        \\    return match c { 0 => a, _ => b }
        \\}
    ,
        \\t.cell:2:27: error: cannot return the place 'a' reached through a branch from 'owned' function 'pick': which owned place it gives up cannot be resolved here
        \\t.cell:2:27: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
    // The workaround, verified rather than asserted: bind the value to a name
    // whose annotation says what it is, then hand the name over.
    try expectAccepted(
        \\pub fn pick(copy c: Int, copy a: Int, copy b: Int) -> Int {
        \\    let copy r = match c { 0 => a, _ => b }
        \\    return copy r
        \\}
    );
}

test "R8 accepts returning an arc, which is not a borrow" {
    try expectAccepted(
        \\pub fn share_name(arc name: String) -> arc String {
        \\    return name
        \\}
    );
}

// The three cases below pin decisions OWNERSHIP.md leaves open for a binding
// that holds a borrow rather than a value. They are separated from the
// parameter cases above because a `let exclusive e = &mut buf` is a local, so
// it takes the `mutable` path in `checkAssign` that a parameter never reaches.

test "a write through a let-bound exclusive borrow is allowed" {
    // The borrow kind grants mutability of the referent, so the `let` being
    // immutable does not block a write through it.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    e.len = 1
        \\    use_it(e)
        \\}
    );
}

test "rebinding a let-bound exclusive borrow still needs var" {
    // Mutability of the referent is not mutability of the binding: pointing
    // `e` at something else is an ordinary R14 immutable assignment.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let owned other = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    e = &mut other
        \\}
    ,
        \\t.cell:13:5: error: cannot assign to immutable binding 'e'
        \\t.cell:12:5: note: 'e' is declared immutable here
        \\
    );
}

test "R3: a let-bound exclusive borrow cannot be moved into an owned parameter" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    take(e)
        \\}
    ,
        \\t.cell:12:10: error: cannot move out of 'e': it is an exclusive borrow, not an owner
        \\
    );
}

test "R2.a: a move inside a loop is rejected, because iteration 2 uses it dead" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    var i = 0
        \\    while i < 3 {
        \\        take(owned buf)
        \\        i = i + 1
        \\    }
        \\}
    ,
        \\t.cell:13:20: error: 'buf' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:12:5: note: 'buf' is declared outside this loop; assign to it before the end of the body to revive it
        \\
    );
}

test "R2.a: reassigning before the body ends revives the place and the loop is legal" {
    // R3a already removes a place from the dead list on assignment, so R2.a
    // gets revival for free rather than needing a second rule.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    var i = 0
        \\    while i < 3 {
        \\        take(owned buf)
        \\        buf = Buffer { data: [], len: 1 }
        \\        i = i + 1
        \\    }
        \\}
    );
}

test "R2.a does not fire for a place declared inside the loop body" {
    // A binding created fresh each iteration is not moved across the back
    // edge, so there is nothing to catch. Getting this wrong would reject
    // every loop that owns anything.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var i = 0
        \\    while i < 3 {
        \\        let owned tmp = Buffer { data: [], len: 0 }
        \\        take(owned tmp)
        \\        i = i + 1
        \\    }
        \\}
    );
}

// ── R9: `arc` grants shared access only ─────────────────────────────────
//
// Every program in this group was ACCEPTED at exit 0 before these checks
// landed, measured against `zig-out/bin/cell` built at `b3698a7`. The
// `docs/SPEC.md` 4.1.4 text calling mutation through `arc` "not permitted in
// this revision" was therefore an overclaimed safety guarantee, which is the
// one direction of documentation error this repository treats as worse than
// silence.

test "R9: an arc place may not be passed to an exclusive parameter" {
    // Measured before this check: accepted, and emitted
    // `cell_grow(((cell_string_t *)s.ptr))` for the String analogue, a mutable
    // pointer into the shared box, clean at `-Wall -Wextra -Werror`.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let arc b = Buffer { data: [], len: 0 }
        \\    grow(exclusive b, shared 1)
        \\}
    ,
        \\t.cell:11:20: error: cannot borrow 'b' as exclusive: 'arc' grants shared access only
        \\t.cell:11:20: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

test "R9: an arc place may not be borrowed as exclusive by a let" {
    // The other spelling, and the reason the check lives in `createLoan`
    // rather than in `checkCall`: one choke point, not a second enumeration.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    var arc b = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut b
        \\}
    ,
        \\t.cell:11:28: error: cannot borrow 'b' as exclusive: 'arc' grants shared access only
        \\t.cell:11:28: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

test "R9 asks every step of the chain, so an arc FIELD is refused too" {
    // The worst of the measured emits: `cell_grow(((cell_string_t *)&b.h.ptr))`
    // for the String analogue, a mutable pointer aimed at the arc handle's own
    // pointer field. Silent, and accepted by `cc`. A check that only asked
    // about the BINDING would miss it, which is this file's recurring failure.
    try expectDiagnostics(prelude ++
        \\pub struct Holder { arc h: Buffer }
        \\pub fn main() {
        \\    let owned k = Holder { h: Buffer { data: [], len: 0 } }
        \\    grow(&mut k.h, shared 1)
        \\}
    ,
        \\t.cell:12:15: error: cannot borrow 'k.h' as exclusive: 'arc' grants shared access only
        \\t.cell:12:15: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

test "R9: a write through an arc binding is refused" {
    // Measured before this check: accepted, and emitted
    // `cell_arc_t b = (cell_B){ .n = 1 }; b.n = 2;`, which `cc` then refused.
    // A loud C error is the mild end of R9; the borrow forms above are silent.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    var arc b = Buffer { data: [], len: 0 }
        \\    b.len = 2
        \\}
    ,
        \\t.cell:11:5: error: cannot assign to 'b.len': it is reached through the 'arc' handle 'b', which grants shared access only
        \\t.cell:11:5: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

test "R9 refuses an exclusive borrow whose ownership it cannot resolve" {
    // The verdict is total, so an unreadable annotation is a REFUSAL and not
    // silence. `s` is an `Int`, so `s.data` has no field annotation to read.
    try expectDiagnostics(prelude ++
        \\pub fn use_bytes(exclusive d: [Byte]) { }
        \\pub fn main() {
        \\    let copy s = 1
        \\    use_bytes(&mut s.data)
        \\}
    ,
        \\t.cell:12:20: error: cannot borrow 's.data' as exclusive: the ownership of the field 'data' of 's' cannot be resolved here
        \\t.cell:12:20: note: R9 refuses what it cannot prove is not 'arc': a unique reference into a shared value mutates every holder
        \\
    );
}

test "R9 leaves a shared borrow of an arc place alone" {
    // R10's table makes `arc` to a `shared` parameter legal: it borrows the
    // pointee without retaining, and R8 keeps the borrow inside the block.
    // Refusing this would break `examples/arc.cell`.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let arc b = Buffer { data: [], len: 0 }
        \\    read(shared b)
        \\}
    );
}

test "R9 leaves rebinding a var arc handle alone" {
    // Assigning to the handle ITSELF replaces the reference and does not
    // mutate the shared value, so it is R11's leak (the previous box is never
    // released) and not R9's rule. That is why the assignment check asks only
    // the STRICT prefixes of the target's path.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var arc b = Buffer { data: [], len: 0 }
        \\    b = Buffer { data: [], len: 1 }
        \\}
    );
}

test "a field borrow through a named loan resolves the referent's struct type" {
    // `let exclusive e = &mut buf` carries no type annotation, is not a struct
    // literal and is not a call, so `e` used to reach `declare` with no
    // `struct_name` at all. Harmless while an unresolved annotation meant
    // "permit"; under R9's total verdict it would mean REFUSE, and this
    // ordinary field borrow would stop compiling. Same shape as the call
    // inference `b3698a7` had to add for R10, in a new position.
    try expectAccepted(prelude ++
        \\pub fn use_bytes(exclusive d: [Byte]) { }
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    use_bytes(&mut e.data)
        \\}
    );
}

// ── R14's second clause: a borrow-holding binding may not be rebound ─────

test "R14: a var-bound exclusive borrow may not be retargeted" {
    // Measured before this check: accepted at exit 0. `placeOf` returns null
    // for a unary, so `checkExpr` made a TEMPORARY loan on the new referent
    // that died with the statement, leaving a loan on the OLD referent and
    // none on the new one; a following `take(owned other)` was accepted.
    //
    // The C backend does not retarget at all: it emits `*e = *&other;`. With
    // heap values that aliases one buffer into two owners and both are freed,
    // measured as an AddressSanitizer double free at exit 134. Refusing is the
    // answer because the statement has two meanings and the compiler
    // implements a different one in each half.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let owned other = Buffer { data: [], len: 0 }
        \\    var exclusive e = &mut buf
        \\    e = &mut other
        \\}
    ,
        \\t.cell:13:5: error: cannot assign a borrow of 'other' to 'e': it already holds a borrow, and rebinding one is not defined in this revision
        \\t.cell:13:5: note: the C backend writes THROUGH the borrow rather than retargeting it, so the two readings of this statement differ; bind a new name instead
        \\
    );
}

test "R14's rebinding clause reads the loan, not only the annotation" {
    // `checkLetInit` creates a named loan whenever the initializer is a `&`
    // form, REGARDLESS of the annotation, so a binding whose declared mode is
    // not a borrow can hold one. Asking only about the declared mode would be
    // exactly the enumeration this file keeps being caught by; `holdsBorrow`
    // asks both.
    //
    // The witness is `var copy` rather than the `var owned` this test used to
    // write, because R18 now refuses `var owned e = &mut buf` at the `let`
    // and no loan is created for it. `copy` still reaches the loan branch, so
    // the clause under test still has a live case; the `owned` spelling is
    // pinned by the R18 test below instead. Both halves stay covered.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let owned other = Buffer { data: [], len: 0 }
        \\    var copy e = &mut buf
        \\    e = &mut other
        \\}
    ,
        \\t.cell:13:5: error: cannot assign a borrow of 'other' to 'e': it already holds a borrow, and rebinding one is not defined in this revision
        \\t.cell:13:5: note: the C backend writes THROUGH the borrow rather than retargeting it, so the two readings of this statement differ; bind a new name instead
        \\
    );
}

test "R14's rebinding clause refuses a value it cannot classify" {
    // `borrowSource` is total for the same reason `arcUniqueSource` is: the
    // permissive default is what every previous widening escaped through.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    var exclusive e = &mut buf
        \\    e = unresolved_callee()
        \\}
    ,
        \\t.cell:12:5: error: cannot assign to 'e', which holds a borrow: the result of the unresolved callee 'unresolved_callee' cannot be classified as a value or a borrow here
        \\t.cell:12:5: note: R14 refuses what it cannot prove is not a borrow: a retarget the checker does not see leaves a loan on the old referent and none on the new one
        \\
    );
}

test "a whole-value write through a var exclusive borrow is still allowed" {
    // The legitimate neighbour the rebinding clause must not eat.
    // `runtime/cell_rt.h` section 7 defines `exclusive` as the callee mutating
    // the caller's value, and a codegen fix already landed for this form.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    var exclusive e = &mut buf
        \\    e = Buffer { data: [], len: 3 }
        \\    use_it(e)
        \\}
    );
}

test "a field write through a let-bound exclusive borrow is still allowed" {
    // The other neighbour: `examples/ownership.cell` writes `buf.len` through
    // an `exclusive buf: Buffer` parameter, and the rebinding clause is scoped
    // to an EMPTY path so it never sees this.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    grow(exclusive e, shared 1)
        \\    e.len = 4
        \\}
    );
}

test "R9 reaches a VALUE position: an arc call result may not be borrowed as exclusive" {
    // Axis 1 of R10's history, repeating in a new rule. `createLoan` is the
    // choke point for every exclusive loan and only a PLACE creates one, so
    // this escaped the rule that refuses `grow(exclusive b, shared 1)` for the
    // same handle. Measured before this: accepted at exit 0, emitting
    // `cell_grow(((cell_string_t *)&cell_fresh().ptr))`.
    try expectDiagnostics(prelude ++
        \\pub fn fresh() -> arc Buffer;
        \\pub fn main() {
        \\    grow(&mut fresh(), shared 1)
        \\}
    ,
        \\t.cell:11:15: error: cannot borrow 'fresh()' as exclusive: 'arc' grants shared access only
        \\t.cell:11:15: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

test "R9's value position is checked at BOTH sites, not only the unary one" {
    // `checkCall` peels the sigil itself and hands `checkExpr` the operand, so
    // the unary arm never sees a call argument. Fixing only the unary arm left
    // the measured program above still accepted; this test is the bare form
    // that the unary arm does see, and the pair is what keeps them together.
    try expectDiagnostics(prelude ++
        \\pub fn fresh() -> arc Buffer;
        \\pub fn main() {
        \\    &mut fresh()
        \\}
    ,
        \\t.cell:11:10: error: cannot borrow 'fresh()' as exclusive: 'arc' grants shared access only
        \\t.cell:11:10: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

test "a match arm binding inherits the scrutinee's struct type" {
    // Not R7, which is still unimplemented: only the struct TYPE, which is
    // what `placeOwnership` needs one level down. An arm binding declared with
    // no struct name made this ordinary field borrow undecidable, and R9's
    // total verdict turns undecidable into refused. Found by probing for the
    // same residual the `checkLet` propagation had already closed once.
    try expectAccepted(prelude ++
        \\pub fn use_bytes(exclusive d: [Byte]) { }
        \\pub fn main() {
        \\    var owned src = Buffer { data: [], len: 0 }
        \\    match src {
        \\        x => use_bytes(&mut x.data)
        \\    }
        \\}
    );
}

test "R9 reaches an arc field through a match arm binding" {
    // The other half of the propagation, and the reason it is not a weakening:
    // resolving the arm binding's type turns a vague "cannot be resolved here"
    // into R9's own verdict, read off a real annotation. Both refuse; only one
    // says why.
    try expectDiagnostics(prelude ++
        \\pub struct Holder { arc h: Buffer }
        \\pub fn main() {
        \\    var owned src = Holder { h: Buffer { data: [], len: 0 } }
        \\    match src {
        \\        x => grow(&mut x.h, shared 1)
        \\    }
        \\}
    ,
        \\t.cell:13:24: error: cannot borrow 'x.h' as exclusive: 'arc' grants shared access only
        \\t.cell:13:24: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

// ── R7's consumption clause ─────────────────────────────────────────────
//
// The scrutinee is READ, never moved, so an arm binding is an alias of it and
// not a second owner. Every `owned` consumption site asked `placeOf`, got a
// place rooted at the arm binding, and moved THAT. Eleven shapes were measured
// live at `4698dbc`; the four below that carry a measured exit code name it in
// their comment, and `examples/rejected/owned_move_through_match_binding.cell`
// carries the whole table.

test "R7: an arm binding may not be passed to an owned parameter" {
    // The reproducer, measured at `4698dbc`: `cell check` exit 0,
    // `cc -fsanitize=address` exit 0, running it exit 134,
    // `AddressSanitizer: attempting double-free`.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => take(owned x)
        \\    }
        \\}
    ,
        \\t.cell:12:25: error: cannot pass the match binding 'x' aliasing 'buf' to 'owned' parameter 'b': the scrutinee still owns the value
        \\t.cell:12:25: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: a call-result scrutinee still lowers, because nothing else owns it" {
    // The distinction the rule draws, and the row that must NOT be refused:
    // measured at `4698dbc` and again after the fix, exit 0. A scrutinee with
    // no place behind it has no other owner, so the arm binding is the only
    // handle and consuming it is a move of a temporary.
    try expectAccepted(prelude ++
        \\pub fn fresh() -> Buffer;
        \\pub fn main() {
        \\    match fresh() {
        \\        x => take(owned x)
        \\    }
        \\}
    );
}

test "R7 over-refuses a nested arm binding over a TEMP, and that is the fix" {
    // This program is safe today, measured exit 0, and it is refused anyway.
    // The first version of R7 accepted it, by propagating `.temp` through a
    // whole arm binding: `x` is a temporary with no other owner, so `y` is one
    // too. Sound about ONE consumer, false about two, and the version below is
    // what falsified it -- so this pair is kept together on purpose, the
    // over-refusal above the reason for it.
    try expectDiagnostics(prelude ++
        \\pub fn fresh() -> Buffer;
        \\pub fn main() {
        \\    match fresh() {
        \\        x => match x {
        \\            y => take(owned y)
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:13:29: error: cannot pass the match binding 'y' aliasing 'x' to 'owned' parameter 'b': the scrutinee still owns the value
        \\t.cell:13:29: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: two live handles on one temp, which R2 cannot see" {
    // The measurement that removed the propagation. `x` and `y` are two
    // different bindings with two different ids, both holding one buffer, so
    // R2's use-after-move never fires: `take(owned y)` frees it and
    // `take(owned x)` frees it again, exit 134 under AddressSanitizer.
    //
    // Nesting a `match` is the ONLY construct in this grammar that makes two
    // live handles: `let owned y = x` moves `x`, which is why the `let`
    // spelling was already safe and why this one was not. Refusing the inner
    // binding closes the class rather than this shape.
    try expectDiagnostics(prelude ++
        \\pub fn fresh() -> Buffer;
        \\pub fn main() {
        \\    match fresh() {
        \\        x => { match x {
        \\                   y => take(owned y)
        \\               }
        \\               take(owned x) }
        \\    }
        \\}
    ,
        \\t.cell:13:36: error: cannot pass the match binding 'y' aliasing 'x' to 'owned' parameter 'b': the scrutinee still owns the value
        \\t.cell:13:36: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: a nested arm binding over a PLACE scrutinee is refused" {
    // The same nesting over a place was measured exit 134 at `4698dbc`. The
    // pair with the test above is the whole point: nesting does not launder
    // the question, it forwards it.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => match x {
        \\            y => take(owned y)
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:13:29: error: cannot pass the match binding 'y' aliasing 'x' to 'owned' parameter 'b': the scrutinee still owns the value
        \\t.cell:13:29: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: an arm binding may not be returned" {
    // Measured at `4698dbc`: returning an arm binding out of a `-> String`
    // body was exit 134, the caller's holder and the callee's scope drop
    // freeing one buffer.
    try expectDiagnostics(prelude ++
        \\pub fn pick(owned seed: Buffer) -> Buffer {
        \\    match seed {
        \\        x => { return x }
        \\    }
        \\    return seed
        \\}
    ,
        \\t.cell:11:23: error: cannot return the match binding 'x' aliasing 'seed' from 'owned' function 'pick': the scrutinee still owns the value
        \\t.cell:11:23: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: an arm binding may not be assigned into an owned place" {
    // Measured at `4698dbc`: `match s1 { x => { d = x } }` into a
    // `var owned d` was exit 134.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    var owned dst = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => { dst = x }
        \\    }
        \\}
    ,
        \\t.cell:13:22: error: cannot assign the match binding 'x' aliasing 'buf' to 'owned' place 'dst': the scrutinee still owns the value
        \\t.cell:13:22: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: an arm binding may not initialise an owned let" {
    // NOT a double free at `4698dbc` (measured exit 0), and refused anyway:
    // an arm binding is never dropped either, so the three headers merely
    // aliased one buffer. Arm-scope drops detonate it, and the file's standing
    // choice is to refuse a latent case with the live ones rather than leave
    // it as a trap for the change that lands them.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => { let owned y: Buffer = x
        \\               read(shared y) }
        \\    }
        \\}
    ,
        \\t.cell:12:38: error: cannot bind the match binding 'x' aliasing 'buf' to 'owned' binding 'y': the scrutinee still owns the value
        \\t.cell:12:38: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: a FIELD of an aliasing arm binding is refused too" {
    // The question is asked of the place, not of the name, so `x.data` is the
    // same alias one segment deeper. Measured exit 0 at `4698dbc` only because
    // this backend never drops a `record`, which is R11's gap and not a reason
    // to accept.
    try expectDiagnostics(prelude ++
        \\pub fn eat(owned d: [Byte]) { }
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => eat(owned x.data)
        \\    }
        \\}
    ,
        \\t.cell:13:24: error: cannot pass the match binding 'x.data' aliasing 'buf' to 'owned' parameter 'd': the scrutinee still owns the value
        \\t.cell:13:24: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: a BORROWED scrutinee is refused, and the C type is why that matters" {
    // Measured at `4698dbc` with a `shared [Int]` parameter as the scrutinee:
    // exit 134. The `String` spelling of the same program ran clean, because
    // `owned String` and `shared String` are DIFFERENT C types and codegen
    // inserted a copy, while `owned [T]` and `shared [T]` are the same type
    // and it inserted nothing. A rule whose enforcement depends on which two C
    // types happen to coincide is the thing `refuseArcUnique`'s comment
    // already refuses to write, so both spellings are refused here.
    try expectDiagnostics(prelude ++
        \\pub fn borrowing(shared b: Buffer) {
        \\    match b {
        \\        x => take(owned x)
        \\    }
        \\}
    ,
        \\t.cell:11:25: error: cannot pass the match binding 'x' aliasing 'b' to 'owned' parameter 'b': the scrutinee still owns the value
        \\t.cell:11:25: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "a FIELD of a temp arm binding is refused, and R10 gets there first" {
    // Written to pin R7's narrow propagation -- temp-ness crosses an EMPTY
    // path only, so `take(owned x)` is accepted above while `x.data` is not --
    // and MEASURED to be refused by something else entirely. `scrutinee_struct`
    // is read off `placeOf(scrutinee)`, which is null for a call, so a `.temp`
    // arm binding never has a struct name, and R10's total verdict calls every
    // field of it unresolved. That is the residual `checkLet` already records
    // for an unannotated `match` or call initializer, reached from the other
    // side.
    //
    // The test is kept with its real output rather than deleted, because the
    // shape it was written for is genuinely unreachable as an R7 diagnostic
    // today: anyone who closes R10's residual will land here, and the arm
    // below is the answer they need. Both refusals are the safe direction.
    try expectDiagnostics(prelude ++
        \\pub fn fresh() -> Buffer;
        \\pub fn eat(owned d: [Byte]) { }
        \\pub fn main() {
        \\    match fresh() {
        \\        x => eat(owned x.data)
        \\    }
        \\}
    ,
        \\t.cell:13:24: error: cannot pass the place 'x.data' to 'owned' parameter 'd': its ownership cannot be resolved here
        \\t.cell:13:24: note: R10 refuses what it cannot prove is not 'arc': an 'arc' value made unique is freed twice
        \\
    );
}

test "R7 aliases cannot enter owning resource fields" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => read(shared Buffer { data: x, len: 0 })
        \\    }
        \\}
    ,
        \\t.cell:12:41: error: cannot store the match binding 'x' aliasing 'buf' in owned field 'data': the source is not a fresh owned value
        \\t.cell:12:41: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\
    );
}

test "R7 leaves a shared read of an arm binding alone" {
    // The rule is scoped to `owned` consumption. Reading through an arm
    // binding is what `match` is for, was measured exit 0, and stays exit 0.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => use_it(shared x)
        \\    }
        \\    take(buf)
        \\}
    );
}

test "R7 does not touch a copy scrutinee" {
    // A `copy` place duplicates rather than moving, so nothing is aliased and
    // there is nothing to refuse. Measured exit 0 before and after.
    try expectAccepted(prelude ++
        \\pub fn show(copy n: Int) { }
        \\pub fn main() {
        \\    let copy n = 3
        \\    match n {
        \\        x => show(copy x)
        \\    }
        \\}
    );
}

test "R7 closes an R10 escape: an arm binding launders an arc scrutinee" {
    // `arcUniqueSource` reads the ARM BINDING's own annotation, which
    // `checkMatch` declares `.owned`, so it could not see the scrutinee's
    // `arc`. Measured at `4698dbc` with an `arc [Int]` place:
    // `take_list(owned a)` was already refused by R10, and
    // `match a { x => take_list(owned x) }` was `cell check` exit 0 and
    // running it exit 134. R7's question is asked of the PLACE and does not
    // need to know the scrutinee is `arc`, which is why one check closes two
    // rules' escapes.
    try expectDiagnostics(prelude ++
        \\pub fn shared_buf() -> arc Buffer;
        \\pub fn main() {
        \\    let arc a: Buffer = shared_buf()
        \\    match a {
        \\        x => take(owned x)
        \\    }
        \\}
    ,
        \\t.cell:13:25: error: cannot pass the match binding 'x' aliasing 'a' to 'owned' parameter 'b': the scrutinee still owns the value
        \\t.cell:13:25: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "resource shape is total across every declared type variant" {
    var checker = Checker.init(std.testing.allocator, "t.cell", null);
    defer checker.deinit();

    var string_ty: ast.TypeExpr = .{ .name = "String" };
    var int_ty: ast.TypeExpr = .{ .name = "Int" };
    var float64_ty: ast.TypeExpr = .{ .name = "Float64" };
    var unknown_ty: ast.TypeExpr = .{ .name = "Missing" };
    var list_ty: ast.TypeExpr = .{ .list = &int_ty };
    var optional_ty: ast.TypeExpr = .{ .optional = &string_ty };
    var result_ty: ast.TypeExpr = .{ .result = .{ .ok = &int_ty, .err = &string_ty } };
    var ref_ty: ast.TypeExpr = .{ .ref = .{ .ownership = .copy, .inner = &string_ty } };
    var unit_ty: ast.TypeExpr = .unit;

    try std.testing.expectEqual(Checker.ResourceShape.resources, try checker.resourceShape(&string_ty));
    try std.testing.expectEqual(Checker.ResourceShape.no_resources, try checker.resourceShape(&int_ty));
    try std.testing.expectEqual(Checker.ResourceShape.no_resources, try checker.resourceShape(&float64_ty));
    try std.testing.expectEqual(Checker.ResourceShape.unknown, try checker.resourceShape(&unknown_ty));
    try std.testing.expectEqual(Checker.ResourceShape.resources, try checker.resourceShape(&list_ty));
    try std.testing.expectEqual(Checker.ResourceShape.resources, try checker.resourceShape(&optional_ty));
    try std.testing.expectEqual(Checker.ResourceShape.resources, try checker.resourceShape(&result_ty));
    try std.testing.expectEqual(Checker.ResourceShape.resources, try checker.resourceShape(&ref_ty));
    try std.testing.expectEqual(Checker.ResourceShape.no_resources, try checker.resourceShape(&unit_ty));

    var color_variants = [_][]const u8{"Red"};
    const color = ast.EnumDef{ .name = "Color", .variants = &color_variants, .is_public = false };
    try checker.enums.put(checker.allocator, color.name, color);
    var color_ty: ast.TypeExpr = .{ .name = "Color" };
    try std.testing.expectEqual(Checker.ResourceShape.no_resources, try checker.resourceShape(&color_ty));

    var scalar_fields = [_]ast.Field{.{
        .name = "n",
        .ty = .{ .name = "Int" },
        .ownership = .copy,
    }};
    var nested_fields = [_]ast.Field{.{
        .name = "s",
        .ty = .{ .name = "String" },
        .ownership = .owned,
    }};
    var cycle_fields = [_]ast.Field{.{
        .name = "next",
        .ty = .{ .name = "Cycle" },
        .ownership = .owned,
    }};
    const scalar = ast.StructDef{ .name = "Scalar", .fields = &scalar_fields, .is_public = false };
    const nested = ast.StructDef{ .name = "Nested", .fields = &nested_fields, .is_public = false };
    const cycle = ast.StructDef{ .name = "Cycle", .fields = &cycle_fields, .is_public = false };
    try checker.structs.put(checker.allocator, scalar.name, scalar);
    try checker.structs.put(checker.allocator, nested.name, nested);
    try checker.structs.put(checker.allocator, cycle.name, cycle);
    var scalar_ty: ast.TypeExpr = .{ .name = "Scalar" };
    var nested_ty: ast.TypeExpr = .{ .name = "Nested" };
    var cycle_ty: ast.TypeExpr = .{ .name = "Cycle" };
    try std.testing.expectEqual(Checker.ResourceShape.no_resources, try checker.resourceShape(&scalar_ty));
    try std.testing.expectEqual(Checker.ResourceShape.resources, try checker.resourceShape(&nested_ty));
    try std.testing.expectEqual(Checker.ResourceShape.unknown, try checker.resourceShape(&cycle_ty));
}

test "copy fields reject resource and unknown shapes but preserve scalar records" {
    try expectDiagnostics(
        \\pub struct BadString { copy value: String }
        \\pub struct BadList { copy value: [Int] }
        \\pub struct Inner { owned value: String }
        \\pub struct BadNested { copy value: Inner }
        \\pub struct BadOptional { copy value: String? }
        \\pub struct BadUnknown { copy value: Missing }
    ,
        \\t.cell:1:1: error: cannot declare copy field 'value': its type may own resources and copying its header would create two owners
        \\t.cell:1:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\t.cell:2:1: error: cannot declare copy field 'value': its type may own resources and copying its header would create two owners
        \\t.cell:2:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\t.cell:4:1: error: cannot declare copy field 'value': its type may own resources and copying its header would create two owners
        \\t.cell:4:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\t.cell:5:1: error: cannot declare copy field 'value': its type may own resources and copying its header would create two owners
        \\t.cell:5:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\t.cell:6:1: error: cannot declare copy field 'value': its type may own resources and copying its header would create two owners
        \\t.cell:6:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\
    );
    try expectAccepted(
        \\pub enum Color { Red, Blue }
        \\pub struct Point { copy x: Int copy color: Color }
        \\pub struct Wrapper { copy point: Point }
    );
}

test "a boxed record hides in a copy field until the classifier reads field ownership" {
    // The gap the owning-field slice left open. `arc Point` is NOT `Point`:
    // it emits `cell_arc_t point;` while `Point` emits two `int64_t`s, both
    // measured. A classifier that recursed on the declared TYPE and skipped
    // the KEYWORD saw a scalar-only record and let a `copy` field shallow-copy
    // a refcount header, which is a second owner that never retained.
    try expectDiagnostics(
        \\pub enum Color { Red, Blue }
        \\pub struct Point { copy x: Int copy y: Int }
        \\pub struct ArcRecord { arc point: Point }
        \\pub struct BadNestedArc { copy holder: ArcRecord }
        \\pub struct BadQualifiedArc { copy point: arc Point }
        \\pub struct ArcString { arc name: String }
        \\pub struct BadNestedArcString { copy s: ArcString }
    ,
        \\t.cell:4:1: error: cannot declare copy field 'holder': its type may own resources and copying its header would create two owners
        \\t.cell:4:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\t.cell:5:1: error: cannot declare copy field 'point': its type may own resources and copying its header would create two owners
        \\t.cell:5:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\t.cell:7:1: error: cannot declare copy field 's': its type may own resources and copying its header would create two owners
        \\t.cell:7:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\
    );
    // The controls that keep this from being "reject every arc". Primitive
    // ARC is by value under the language contract: `arc Int` emits `int64_t`
    // and an enum is a distinct integer type, so neither is a handle and
    // neither may be refused. `copy n: arc Int` is the qualified spelling of
    // the same thing and must agree with the annotated one.
    try expectAccepted(
        \\pub enum Color { Red, Blue }
        \\pub struct Point { copy x: Int copy y: Int }
        \\pub struct PrimitiveArc { arc n: Int }
        \\pub struct OkPrimitiveArc { copy h: PrimitiveArc }
        \\pub struct EnumArc { arc c: Color }
        \\pub struct OkEnumArc { copy e: EnumArc }
        \\pub struct OkScalarRecord { copy p: Point }
        \\pub struct OkQualifiedPrimitiveArc { copy n: arc Int }
    );
}

test "owned resource fields accept fresh values and refuse every unsafe source class" {
    try expectAccepted(
        \\pub struct Tag { owned name: String }
        \\pub fn make() -> String;
        \\pub fn main() {
        \\    let owned a = Tag { name: "literal" }
        \\    let owned b = Tag { name: make() }
        \\}
    );
    try expectDiagnostics(
        \\pub struct Tag { owned name: String }
        \\pub fn make() -> String;
        \\pub fn main() {
        \\    let owned source = make()
        \\    let owned a = Tag { name: source }
        \\    let owned b = Tag { name: owned source }
        \\}
    ,
        \\t.cell:5:31: error: cannot store source in owned field 'name': moving a place into an aggregate is not implemented
        \\t.cell:5:31: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\t.cell:6:31: error: cannot store source in owned field 'name': moving a place into an aggregate is not implemented
        \\t.cell:6:31: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\
    );
    try expectDiagnostics(
        \\pub struct Tag { owned name: String }
        \\pub fn inspect(shared s: String) -> shared String;
        \\pub fn main(shared source: String) {
        \\    let owned a = Tag { name: &source }
        \\    let owned b = Tag { name: shared source }
        \\    let owned c = Tag { name: inspect(shared source) }
        \\}
    ,
        \\t.cell:2:1: error: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:2:1: note: return an 'owned' or 'arc' value instead
        \\t.cell:4:31: error: cannot store a borrow of 'source' in owned field 'name': a borrow does not transfer ownership
        \\t.cell:4:31: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\t.cell:5:31: error: cannot store a borrow of 'source' in owned field 'name': a borrow does not transfer ownership
        \\t.cell:5:31: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\t.cell:6:31: error: cannot store the borrow returned by 'inspect' in owned field 'name': a borrow does not transfer ownership
        \\t.cell:6:31: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\
    );
}

test "owning field guard follows field paths and recursive destination shapes" {
    try expectDiagnostics(
        \\pub struct Inner { owned name: String }
        \\pub struct Outer { owned inner: Inner }
        \\pub struct Maybe { owned name: String? }
        \\pub struct Lists { owned items: [Int] }
        \\pub fn make_string() -> String;
        \\pub fn make_inner() -> Inner;
        \\pub fn make_list() -> [Int];
        \\pub fn main() {
        \\    let owned source = make_string()
        \\    let owned inner = Inner { name: make_string() }
        \\    let owned a = Inner { name: inner.name }
        \\    let owned b = Outer { inner: inner }
        \\    let owned c = Maybe { name: source }
        \\    let owned d = Lists { items: make_list() }
        \\}
    ,
        \\t.cell:11:33: error: cannot store inner.name in owned field 'name': moving a place into an aggregate is not implemented
        \\t.cell:11:33: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\t.cell:12:34: error: cannot store inner in owned field 'inner': moving a place into an aggregate is not implemented
        \\t.cell:12:34: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\t.cell:13:33: error: cannot store source in owned field 'name': moving a place into an aggregate is not implemented
        \\t.cell:13:33: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\
    );
}

test "owning field guard fails closed for unknown and cyclic destination shapes" {
    try expectDiagnostics(
        \\pub struct Mystery { owned value: Missing }
        \\pub struct Node { owned next: Node }
        \\pub fn make_node() -> Node;
        \\pub fn main() {
        \\    let owned a = Mystery { value: 1 }
        \\    let owned b = Node { next: make_node() }
        \\}
    ,
        \\t.cell:5:36: error: cannot store a value of unresolved resource shape in owned field 'value': the destination field's resource shape cannot be resolved
        \\t.cell:5:36: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\t.cell:6:32: error: cannot store a value of unresolved resource shape in owned field 'next': the destination field's resource shape cannot be resolved
        \\t.cell:6:32: note: aggregate ownership transfer and partial-move drop state are not implemented; construct a fresh field value instead
        \\
    );
}
