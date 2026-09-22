//! Borrow and move checker for Cell.
//!
//! Implements `docs/OWNERSHIP.md` rules R1, R2, R2.a, **R2.b**, R3, R3a, R4,
//! R5, R6, **R7's consumption clause**, R8, R9,
//! R14, R15 and **R18**, plus ONE clause of R10: an `arc` value may not be
//! made UNIQUE,
//! refused at six consumption sites (an `owned` parameter, an `owned`
//! binding, an assignment into an `owned` place, an `owned` struct field, a
//! list-literal element, and a `return` whose declared return type is not
//! `arc`). The rest of R10 is still designed only, except that
//! move-into-`arc` is implemented at FIVE positions since 2026-09-16, all for
//! one source shape, a whole `owned` `String` or list binding
//! (`boxableOwnedBinding`): `let arc` moves it into the fresh box, a direct
//! `return` from a `-> arc T` function does (the ordinary R2 return move),
//! so does an assignment into a whole `var arc` binding, so does passing it
//! to an `arc` parameter (the callee releases the box), and so does storing
//! it in a struct literal's `arc` field (the record's drop glue releases
//! it). Every other owned-into-`arc` source and position (a field target,
//! a block tail) is refused as not implemented. That single clause is here rather than in codegen
//! because codegen cannot refuse it: `owned [T]` and `shared [T]` lower to
//! the SAME C type, so the emitted conversion compiles clean and double frees
//! the buffer. Its classifier, `arcUniqueSource`, returns a TOTAL verdict:
//! a source whose ownership it cannot resolve is refused, not permitted.
//! Read that function's comment before widening it a fourth time; the three
//! widenings so far were three different axes and each escaped through the
//! same permissive default.
//!
//! **R2.a is asked on every path out of a loop body** (2026-09-16), not only
//! at the fall-through end: at each `continue`, and after the loop through
//! the union of every `break` state and the failing-condition state (which
//! includes the entry state). Before that, five accepted shapes ran as
//! AddressSanitizer double frees; `checkWhile` and `docs/OWNERSHIP.md` R2.a
//! list them. It is the file's recurring defect again: one back-edge source
//! was enumerated and a property of all of them asserted.
//!
//! **R2.b** is the general rule that one clause of R10 was a special case of:
//! an `owned` consumption position is asked of the EXPRESSION, not of a place.
//! Every site used to call `placeOf` first and fall through to `checkExpr`,
//! which only READS, so `let owned s2: String = match c { 0 => s1, _ => s1 }`
//! read `s1`, `pendingDrops` kept both bindings, and one buffer was freed
//! twice (exit 134, no `arc` anywhere in it). Enforced at the same six sites,
//! by `ownedMoveSource`, whose `.unknown` is REFUSED and whose branch arms can
//! never return a movable place. A BLOCK in any of the six positions is one
//! path, not a branch: each site opens it first (`openBlockTail`) and consumes
//! its tail with the block's `let`s in scope, so the tail moves. A resource-bearing owned struct field now
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

const bk_model = @import("borrowck/model.zig");
const bk_nll = @import("borrowck/nll.zig");
const bk_arc = @import("borrowck/arc.zig");
const bk_resource = @import("borrowck/resource.zig");
const bk_loans = @import("borrowck/loans.zig");
const bk_expr = @import("borrowck/expr.zig");
const bk_bindings = @import("borrowck/bindings.zig");
const bk_stmts = @import("borrowck/stmts.zig");
const bk_scope = @import("borrowck/scope.zig");
const bk_tests_support = @import("borrowck/tests_support.zig");
const bk_tests_core = @import("borrowck/tests_core.zig");
const bk_tests_arc = @import("borrowck/tests_arc.zig");
const bk_tests_loops = @import("borrowck/tests_loops.zig");
const bk_tests_results = @import("borrowck/tests_results.zig");
const bk_tests_borrows = @import("borrowck/tests_borrows.zig");
pub const Error = bk_model.Error;
pub const BorrowError = bk_model.BorrowError;
pub const LoanKind = bk_model.LoanKind;
const Binding = bk_model.Binding;
const MovedPath = bk_model.MovedPath;
const AssignLiveness = bk_model.AssignLiveness;
pub const ExitKind = bk_model.ExitKind;
const SkipBreak = bk_model.SkipBreak;
const ExitLiveness = bk_model.ExitLiveness;
const ExitFieldLiveness = bk_model.ExitFieldLiveness;
const Dead = bk_model.Dead;
const Loan = bk_model.Loan;
const OpenBlock = bk_model.OpenBlock;
const LoopFrame = bk_model.LoopFrame;

// The test files are reached only through this reference.
comptime {
    _ = bk_tests_support;
    _ = bk_tests_core;
    _ = bk_tests_arc;
    _ = bk_tests_loops;
    _ = bk_tests_results;
    _ = bk_tests_borrows;
}

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
    /// The `while` statements being walked, innermost last. See `LoopFrame`.
    loop_frames: std.ArrayListUnmanaged(LoopFrame) = .empty,
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
    /// The same moves as `moved`, WITH the field path each one took, and
    /// append-only for the same reason. `moved` answers "was anything under
    /// this binding moved", which is everything a scalar, a buffer or a
    /// handle needs. A record needs to know WHICH fields went: before this
    /// existed, `let owned m = p.a` made codegen skip `p` entirely, so a
    /// second owning field `p.b` was released by nothing (the partial-move
    /// leak). The paths are safe to keep: `placeOf` allocates them from
    /// `self.arena`, which outlives the per-function `dead` reset. It
    /// inherits `moved`'s conservatism exactly, since both are written at
    /// the same point: a move on one branch of an `if` is recorded as if it
    /// happened on every path, which for a DROP decision fails toward a
    /// leak and never toward a double free. R3a field revival marks a
    /// matching field path `revived` rather than deleting the slot, so
    /// `fieldWasMoved` can release the new value without shrinking the log
    /// `loop_moved` snapshots by length. A whole-binding `path == ""` is
    /// never marked.
    moved_paths: std.ArrayListUnmanaged(MovedPath) = .empty,
    /// One entry per whole-binding reassignment `v = ...` the checker
    /// accepted, recording whether `v` still held a live value at that store
    /// (after the right side was checked, so `v = f(v)` counts as moved).
    /// Codegen reads it through `assignReleasesOldValue` to decide whether
    /// the old value may be freed before the store.
    ///
    /// WHY NOT `wasMoved`. That answer is "moved anywhere in the function",
    /// so a var moved AFTER its reassignment (a later `return v`) looked
    /// moved at the store too, and its old value leaked. `dead` answers the
    /// right question at the right point, lexically.
    ///
    /// WHY THE LOOP INVALIDATION. `dead` is lexical, and a `continue` (or the
    /// back edge after any path) can carry a move made LATER in a `while`
    /// body to a store EARLIER in the next iteration without `dead` ever
    /// showing it: in `while c { v = "x" \n if d { take(v) \n continue } \n
    /// v = "y" }`, at `v = "x"` on the third iteration the value was already
    /// handed to `take`. (That program was accepted until 2026-09-16 and is
    /// now refused by R2.a at the `continue`; the invalidation stays, because
    /// codegen emits C for a rejected module too and the back edge from the
    /// body end reaches the store the same way.) So `checkWhile` clears `live`
    /// on every entry recorded inside its body whose binding was moved
    /// anywhere in that body (`moved_paths` is append-only, so "anywhere in
    /// the body" is a range). `while` is the only back edge Cell has.
    assign_liveness: std.ArrayListUnmanaged(AssignLiveness) = .empty,
    /// The FIELD-store twin of `assign_liveness` (2026-09-21): one entry per
    /// accepted store `r.f = ...` (any depth of `.field`, no deref, index or
    /// call in the chain) whose root binding is `owned` and whose target
    /// field is `owned`, recording whether the target path still held its
    /// whole value after the right side was checked. `findDead` is asked of
    /// the FULL path in both directions, so a moved field (R3a revival), a
    /// moved parent and a moved subfield all record `live = false`. Keyed by
    /// the root identifier's name bytes, unique per statement. Codegen reads
    /// it through `fieldAssignReleasesOldValue` and frees the old field value
    /// before the store only on a `true`. Every other shape records nothing
    /// and keeps the leak: an `exclusive` or `shared` root (the old value
    /// belongs to the referent, not measured), an `arc` root or field (R9 and
    /// R10 refuse those stores), a `copy` field.
    field_assign_liveness: std.ArrayListUnmanaged(AssignLiveness) = .empty,
    /// One entry per (scope exit, visible binding): whether the binding still
    /// held a value at that exit on the path the checker was walking. Codegen
    /// reads it through `liveAtExit` to release a var that was moved and then
    /// revived (R3a), which `wasMoved` alone leaks at scope end because it is
    /// permanent for the whole function.
    ///
    /// `dead` is the right answer at the exit for the same reason it is at a
    /// store: `checkIf` and `checkMatch` start every branch from the entry
    /// state and union the results, so a move on one branch, or a revival on
    /// only one, leaves the place dead after the merge.
    ///
    /// WHY THE LOOP GUARDS. `while` is the only back edge. A `break` or
    /// `continue` taken between a move and its revival leaves the loop, or
    /// reaches the next iteration, with the place moved while every exit the
    /// checker walked saw it revived. R2.a now refuses the `continue` form
    /// and makes the place dead after the loop for the `break` form (since
    /// 2026-09-16), but a skip-revival `break` with no later use is still
    /// accepted, and codegen emits C for rejected modules too, so the guards
    /// stay. So a binding declared outside a loop
    /// and moved anywhere in it (the condition included) is never live at an
    /// exit recorded inside that loop (cleared by `checkWhile` once the body
    /// is walked; a `return` in a loop that reported no error is spared,
    /// 2026-09-17) or at any exit after it (`loop_moved`). Bindings declared inside the loop body are
    /// fresh on every iteration, so the back edge carries none of their moves.
    exit_liveness: std.ArrayListUnmanaged(ExitLiveness) = .empty,
    /// Every `break` codegen must lower as a jump past its loop's
    /// `after_loop_skip` releases. Empty unless `checkWhile` proved the
    /// skip-revival shape; a missing entry keeps the leak.
    skip_breaks: std.ArrayListUnmanaged(SkipBreak) = .empty,
    /// Every `Ok(x)` whose operand place was MOVED into the Result (an owning
    /// payload whose type resolved, 2026-09-17). Codegen passes that operand's
    /// header straight in; any other owning operand it copies, because this
    /// checker only read it.
    wrap_moves: std.ArrayListUnmanaged(usize) = .empty,
    /// Per-field sibling of `exit_liveness`. One entry per (exit, visible
    /// binding, path in `moved_paths`): whether that field still held a
    /// value on the path being walked. Filled from `dead` at `recordExit`
    /// (so a `branch_end` sees the pre-merge snapshot). Codegen frees a
    /// field at a branch end only when it is live here and dead after the
    /// merge; a missing record keeps the leak. Whole-binding `liveAtExit`
    /// is unchanged: any dead field path still makes `live = false`.
    exit_field_liveness: std.ArrayListUnmanaged(ExitFieldLiveness) = .empty,
    /// Every binding declared outside a `while` and moved inside it. Permanent,
    /// like `moved`, and safe to keep across functions for the same reason.
    /// See `exit_liveness`.
    loop_moved: std.AutoHashMapUnmanaged(u32, void) = .empty,
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
    /// The mirror of the flag above: set while checking a function that DOES
    /// declare `-> arc T`, which makes the return slot R10's other direction
    /// (see `refuseUnimplementedArcMove`). `fn g(owned p: String) -> arc
    /// String { return p }` was accepted by the checker and rejected by `cc`,
    /// the fifth position of this rule and the last one found; the first four
    /// were a binding, an assignment, a call argument and a struct-literal
    /// field. That exact program is accepted and boxed since 2026-09-16 (a
    /// direct return of a whole `owned` `String` or list binding). Exactly one of these two flags is non-null once a return type is
    /// declared, and both stay null when none is.
    fn_return_arc: ?[]const u8 = null,
    /// The function whose body is being walked. Read only by the differential
    /// oracle, which needs the whole body and the parameter list at once,
    /// which the region-walking state above deliberately does not keep.
    current_fn: ?*const ast.FnDef = null,

    // Declarations split into `borrowck/*.zig`, re-exported so every
    // `Checker.name` and `self.name(...)` resolves exactly as before.
    pub const noteLoanScope = bk_nll.noteLoanScope;
    pub const loanStatusAt = bk_nll.loanStatusAt;
    pub const findBlockingLoan = bk_nll.findBlockingLoan;
    pub const oracleDead = bk_nll.oracleDead;
    pub const windowPropagates = bk_nll.windowPropagates;
    pub const nameUsedFrom = bk_nll.nameUsedFrom;
    pub const ArcSource = bk_arc.ArcSource;
    pub const arcUniqueSource = bk_arc.arcUniqueSource;
    pub const arcCallResult = bk_arc.arcCallResult;
    pub const OwnedMove = bk_arc.OwnedMove;
    pub const wrapPayloadBody = bk_arc.wrapPayloadBody;
    pub const ownedMoveBranch = bk_arc.ownedMoveBranch;
    pub const armAlias = bk_arc.armAlias;
    pub const ownedMoveSource = bk_arc.ownedMoveSource;
    pub const refuseUnknownMove = bk_arc.refuseUnknownMove;
    pub const refuseScrutineeAlias = bk_arc.refuseScrutineeAlias;
    pub const boxableOwnedBinding = bk_arc.boxableOwnedBinding;
    pub const refuseUnimplementedArcMove = bk_arc.refuseUnimplementedArcMove;
    pub const refuseArcUnique = bk_arc.refuseArcUnique;
    pub const ArcReach = bk_arc.ArcReach;
    pub const ReachDepth = bk_arc.ReachDepth;
    pub const arcReach = bk_arc.arcReach;
    pub const refuseArcShared = bk_arc.refuseArcShared;
    pub const refuseArcValueBorrow = bk_arc.refuseArcValueBorrow;
    pub const BorrowSource = bk_resource.BorrowSource;
    pub const borrowSource = bk_resource.borrowSource;
    pub const holdsBorrow = bk_resource.holdsBorrow;
    pub const isDuplicable = bk_resource.isDuplicable;
    pub const placeOwnership = bk_resource.placeOwnership;
    pub const placeStructName = bk_resource.placeStructName;
    pub const reportEscapingReturn = bk_resource.reportEscapingReturn;
    pub const checkStructFields = bk_resource.checkStructFields;
    pub const ResourceShape = bk_resource.ResourceShape;
    pub const Representation = bk_resource.Representation;
    pub const representationOf = bk_resource.representationOf;
    pub const resourceShape = bk_resource.resourceShape;
    pub const fieldResourceShape = bk_resource.fieldResourceShape;
    pub const PlaceType = bk_resource.PlaceType;
    pub const placeTypeOf = bk_resource.placeTypeOf;
    pub const placeResourceShape = bk_resource.placeResourceShape;
    pub const inferBindingType = bk_resource.inferBindingType;
    pub const refuseResourceCopy = bk_resource.refuseResourceCopy;
    pub const refuseListElementMove = bk_resource.refuseListElementMove;
    pub const resourceShapeOwned = bk_resource.resourceShapeOwned;
    pub const resourceShapeInner = bk_resource.resourceShapeInner;
    pub const combineResourceShapes = bk_resource.combineResourceShapes;
    pub const refuseOwnedFieldTransfer = bk_resource.refuseOwnedFieldTransfer;
    pub const reportUseAfterMove = bk_resource.reportUseAfterMove;
    pub const readPlace = bk_loans.readPlace;
    pub const movePlace = bk_loans.movePlace;
    pub const createLoan = bk_loans.createLoan;
    pub const visibleArmAliasOf = bk_loans.visibleArmAliasOf;
    pub const revive = bk_loans.revive;
    pub const findDead = bk_loans.findDead;
    pub const deadStrictPrefixOf = bk_loans.deadStrictPrefixOf;
    pub const loanConflicts = bk_loans.loanConflicts;
    pub const placeOf = bk_loans.placeOf;
    pub const checkExpr = bk_expr.checkExpr;
    pub const checkIf = bk_expr.checkIf;
    pub const checkMatch = bk_expr.checkMatch;
    pub const unionDead = bk_expr.unionDead;
    pub const checkWrap = bk_expr.checkWrap;
    pub const valueMayOwn = bk_expr.valueMayOwn;
    pub const checkCall = bk_expr.checkCall;
    pub const checkLet = bk_bindings.checkLet;
    pub const checkLetInit = bk_bindings.checkLetInit;
    pub const BlockTail = bk_bindings.BlockTail;
    pub const openBlockTail = bk_bindings.openBlockTail;
    pub const closeBlockTail = bk_bindings.closeBlockTail;
    pub const branchDiverges = bk_bindings.branchDiverges;
    pub const branchKeyOf = bk_bindings.branchKeyOf;
    pub const checkAssign = bk_bindings.checkAssign;
    pub const assignTargetName = bk_bindings.assignTargetName;
    pub const checkBlockStmts = bk_stmts.checkBlockStmts;
    pub const checkWhile = bk_stmts.checkWhile;
    pub const collectSkipRevival = bk_stmts.collectSkipRevival;
    pub const clearSkip = bk_stmts.clearSkip;
    pub const bindingInCurrentBlock = bk_stmts.bindingInCurrentBlock;
    pub const afterLoopHolds = bk_stmts.afterLoopHolds;
    pub const invalidateLoopStoresIn = bk_stmts.invalidateLoopStoresIn;
    pub const invalidateLoopStores = bk_stmts.invalidateLoopStores;
    pub const checkContinue = bk_stmts.checkContinue;
    pub const saveBreakState = bk_stmts.saveBreakState;
    pub const checkStmt = bk_stmts.checkStmt;
    pub const checkStmtKind = bk_stmts.checkStmtKind;
    pub const ScopeMark = bk_scope.ScopeMark;
    pub const init = bk_scope.init;
    pub const deinit = bk_scope.deinit;
    pub const hasErrors = bk_scope.hasErrors;
    pub const msg = bk_scope.msg;
    pub const checkModule = bk_scope.checkModule;
    pub const checkFn = bk_scope.checkFn;
    pub const pushScope = bk_scope.pushScope;
    pub const popScope = bk_scope.popScope;
    pub const declare = bk_scope.declare;
    pub const lookup = bk_scope.lookup;
    pub const bindingById = bk_scope.bindingById;
    pub const wasMoved = bk_scope.wasMoved;
    pub const assignReleasesOldValue = bk_scope.assignReleasesOldValue;
    pub const fieldAssignReleasesOldValue = bk_scope.fieldAssignReleasesOldValue;
    pub const recordLiveAtExit = bk_scope.recordLiveAtExit;
    pub const wrapMoved = bk_scope.wrapMoved;
    pub const skipBreakLoop = bk_scope.skipBreakLoop;
    pub const loopHasSkipBreaks = bk_scope.loopHasSkipBreaks;
    pub const liveAtExit = bk_scope.liveAtExit;
    pub const fieldLiveAtExit = bk_scope.fieldLiveAtExit;
    pub const fieldDeadAtExit = bk_scope.fieldDeadAtExit;
    pub const recordExit = bk_scope.recordExit;
    pub const wasWhollyMoved = bk_scope.wasWhollyMoved;
    pub const fieldWasMovedWhole = bk_scope.fieldWasMovedWhole;
    pub const fieldWasMoved = bk_scope.fieldWasMoved;
    pub const bindingName = bk_scope.bindingName;
};

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
