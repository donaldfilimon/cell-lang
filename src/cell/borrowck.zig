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
const pathPrefix = bk_model.pathPrefix;

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

/// Parse and borrow-check `src`, keeping the checker so a test can ask
/// `liveAtExit`. The module lives in the same arena as the checker.
///
/// The arena is heap-allocated on purpose. `arena.allocator()` captures the
/// arena's ADDRESS, and the checker keeps that allocator, so an arena held
/// by value would leave the checker pointing into `init`'s dead stack frame
/// once the harness is returned. With one harness per test that stale slot
/// happened to survive until `deinit`; a second harness in the same test
/// overwrote it and `deinit` segfaulted inside `ArenaAllocator.free`.
const LiveHarness = struct {
    arena: *std.heap.ArenaAllocator,
    checker: Checker,
    module: ast.Module,

    fn init(src: []const u8) !LiveHarness {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        errdefer std.testing.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const gpa = arena.allocator();
        var lex = lexer.Lexer.init(src, "t.cell");
        const tokens = try lex.tokenizeAll(gpa);
        var p = parser.Parser.init(gpa, tokens.items, "t.cell");
        const module = try p.parseModule();
        var checker: Checker = .init(gpa, "t.cell", src);
        errdefer checker.deinit();
        try checker.checkModule(&module);
        if (checker.diagnostics.hasErrors()) {
            var buf: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try checker.diagnostics.printAll(&w);
            std.debug.print("\nLiveHarness source was rejected:\n{s}\n", .{w.buffered()});
            return error.TestUnexpectedRejection;
        }
        return .{ .arena = arena, .checker = checker, .module = module };
    }

    fn deinit(self: *LiveHarness) void {
        self.checker.deinit();
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }

    fn binding(self: *const LiveHarness, name: []const u8) u32 {
        var id: u32 = 0;
        while (id < self.checker.next_binding_id) : (id += 1) {
            if (self.checker.bindingName(id)) |n| {
                if (std.mem.eql(u8, n, name)) return id;
            }
        }
        std.debug.print("\nno binding named {s}\n", .{name});
        unreachable;
    }

    fn fnBody(self: *const LiveHarness, name: []const u8) []const ast.Stmt {
        for (self.module.items) |*item| {
            switch (item.kind) {
                .fn_def => |f| {
                    if (std.mem.eql(u8, f.name, name)) return f.body.?;
                },
                else => {},
            }
        }
        std.debug.print("\nno function named {s}\n", .{name});
        unreachable;
    }

    fn fnBodyKey(self: *const LiveHarness, name: []const u8) usize {
        const body = self.fnBody(name);
        return @intFromPtr(body.ptr);
    }

    fn firstWhile(self: *const LiveHarness, name: []const u8) usize {
        return firstWhileIn(self.fnBody(name)) orelse {
            std.debug.print("\nno while in {s}\n", .{name});
            unreachable;
        };
    }

    fn firstJump(self: *const LiveHarness, name: []const u8) usize {
        return firstJumpIn(self.fnBody(name)) orelse {
            std.debug.print("\nno jump in {s}\n", .{name});
            unreachable;
        };
    }

    fn firstIf(self: *const LiveHarness, name: []const u8) *const ast.Expr {
        return firstIfIn(self.fnBody(name)) orelse {
            std.debug.print("\nno if in {s}\n", .{name});
            unreachable;
        };
    }
};

fn firstWhileIn(stmts: []const ast.Stmt) ?usize {
    for (stmts) |*s| {
        switch (s.kind) {
            .while_stmt => |w| {
                if (firstWhileIn(w.body)) |inner| return inner;
                return @intFromPtr(s);
            },
            .expr => |e| if (firstWhileInExpr(&e)) |k| return k,
            else => {},
        }
    }
    return null;
}

fn firstWhileInExpr(e: *const ast.Expr) ?usize {
    return switch (e.kind) {
        .block => |stmts| firstWhileIn(stmts),
        .if_expr => |i| firstWhileInExpr(i.then_body) orelse if (i.else_body) |eb| firstWhileInExpr(eb) else null,
        else => null,
    };
}

fn firstIfIn(stmts: []const ast.Stmt) ?*const ast.Expr {
    for (stmts) |*s| {
        switch (s.kind) {
            .expr => if (s.kind.expr.kind == .if_expr) return &s.kind.expr,
            .while_stmt => if (firstIfIn(s.kind.while_stmt.body)) |inner| return inner,
            else => {},
        }
    }
    return null;
}

fn firstJumpIn(stmts: []const ast.Stmt) ?usize {
    for (stmts) |*s| {
        switch (s.kind) {
            .break_stmt, .continue_stmt => return @intFromPtr(s),
            .while_stmt => |w| if (firstJumpIn(w.body)) |k| return k,
            .expr => |e| if (firstJumpInExpr(&e)) |k| return k,
            else => {},
        }
    }
    return null;
}

fn firstReturnIn(stmts: []const ast.Stmt) ?usize {
    for (stmts) |*s| {
        switch (s.kind) {
            .return_stmt => return @intFromPtr(s),
            .while_stmt => |w| if (firstReturnIn(w.body)) |k| return k,
            .expr => |e| if (firstReturnInExpr(&e)) |k| return k,
            else => {},
        }
    }
    return null;
}

fn firstReturnInExpr(e: *const ast.Expr) ?usize {
    return switch (e.kind) {
        .block => |stmts| firstReturnIn(stmts),
        .if_expr => |i| firstReturnInExpr(i.then_body) orelse if (i.else_body) |eb| firstReturnInExpr(eb) else null,
        else => null,
    };
}

fn firstJumpInExpr(e: *const ast.Expr) ?usize {
    return switch (e.kind) {
        .block => |stmts| firstJumpIn(stmts),
        .if_expr => |i| firstJumpInExpr(i.then_body) orelse if (i.else_body) |eb| firstJumpInExpr(eb) else null,
        else => null,
    };
}

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

/// `src` draws an error whose text contains `needle`.
fn expectRejectedWith(src: []const u8, needle: []const u8) !void {
    var h: Harness = .init();
    defer h.deinit();
    var buf: [4096]u8 = undefined;
    const out = try h.run(src, &buf, false);
    if (std.mem.indexOf(u8, out, needle) == null) {
        std.debug.print("\nexpected an error containing:\n{s}\ngot:\n{s}\n", .{ needle, out });
        return error.TestExpectedRejection;
    }
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

test "indexing reads the base so a move then a[i] is use after move" {
    try expectDiagnostics(
        \\pub fn take(owned s: String) { }
        \\pub fn main() {
        \\    let owned s = "ab"
        \\    take(s)
        \\    let copy b = s[0]
        \\}
    ,
        \\t.cell:5:18: error: use of 's' after it was moved
        \\t.cell:4:10: note: 's' was moved here by the call to 'take'
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

test "R10's other direction: an owned place may not be moved into an arc box, at five positions" {
    // NOT symmetry for its own sake. `tools/sweep-backends.sh` reported four
    // rows, all `C UNCOMPILABLE: initializing 'cell_arc_t'`, which made this
    // look like a backend typing bug. It is not: the checker does not consume
    // the source, so boxing the place hands the box a buffer the source still
    // frees. Measured before the refusal existed, with an owned LOCAL rather
    // than a parameter, because parameters were not released then and hid it:
    // `let owned s = make()` then `let arc a = match 1 { _ => s }` emitted
    // `cell_arc_from_string(...)` and `cell_string_free(&s)` and died
    // `exit 134`, `attempting double-free ... in cell_string_free`.
    // Implementing the move means deciding who releases the box, which is
    // R11 row 1's ABI question, so this refuses and says "not implemented".
    // The direct `let arc a = p` with `p: owned String` WAS this case; it is
    // implemented since 2026-09-16 (see the test after this one), so the
    // direct form is pinned with a source the box cannot take: an `Int?`.
    try expectDiagnostics(
        \\pub fn f(owned p: Int?) -> Int {
        \\    let arc a = p
        \\    return 0
        \\}
    ,
        \\t.cell:2:17: error: cannot bind 'owned' place 'p' to 'arc' binding 'a': moving an owned place into an 'arc' box is not implemented
        \\t.cell:2:17: note: R10 designs this as a move into a fresh 'arc' box, but the checker does not consume the source, so the box and the source's own drop free the same buffer; bind a fresh value to the 'arc' place, or start from an 'arc' source
        \\
    );
    // THE VALUE POSITION, and the reason this asks `ownedMoveSource` rather
    // than `placeOf`. A first version used `placeOf`, which returns null for a
    // match, and so refused the direct form while accepting this one: the same
    // program wearing a branch. This is the shape that measured exit 134.
    try expectDiagnostics(
        \\pub fn make() -> String {
        \\    return "hello"
        \\}
        \\pub fn main() -> Int {
        \\    let owned s = make()
        \\    let arc a = match 1 { _ => s }
        \\    return 0
        \\}
    ,
        \\t.cell:6:32: error: cannot bind the place 's' reached through a branch to 'arc' binding 'a': moving an owned place into an 'arc' box is not implemented
        \\t.cell:6:32: note: R10 designs this as a move into a fresh 'arc' box, but the checker does not consume the source, so the box and the source's own drop free the same buffer; bind a fresh value to the 'arc' place, or start from an 'arc' source
        \\
    );
}

test "R10's move into arc: a whole owned String or list binding is moved at let" {
    // Implemented 2026-09-16 for this one source shape. The move is real:
    // the source is dead afterwards, exactly as after `let owned q = p`.
    try expectAccepted(
        \\pub fn f(owned p: String, owned xs: [Int]) -> Int {
        \\    let arc a = p
        \\    let arc b = xs
        \\    return 0
        \\}
    );
    try expectDiagnostics(
        \\pub fn view(shared s: String) -> Int;
        \\pub fn f(owned p: String) -> Int {
        \\    let arc a = p
        \\    return view(p)
        \\}
    ,
        \\t.cell:4:17: error: use of 'p' after it was moved
        \\t.cell:3:17: note: 'p' was moved here into the 'arc' box 'a'
        \\
    );
    // A field is still refused: a partial move into a box is not built.
    try expectRejectedWith(
        \\pub struct R { owned s: String }
        \\pub fn f(owned r: R) -> Int {
        \\    let arc a = r.s
        \\    return 0
        \\}
    , "moving an owned place into an 'arc' box is not implemented");
}

test "R10's move into arc: a whole owned String or list binding is moved at return" {
    // Implemented 2026-09-16, the second position after `let`. A local and
    // a parameter, of both boxable types, returned directly.
    try expectAccepted(
        \\pub fn from_param(owned p: String) -> arc String {
        \\    return p
        \\}
        \\pub fn from_list(owned xs: [Int]) -> arc [Int] {
        \\    return xs
        \\}
        \\pub fn from_local() -> arc String {
        \\    let owned t: String = "t"
        \\    return t
        \\}
    );
    // A conditional return followed by a use is ACCEPTED since 2026-09-17:
    // the use is only reached on the path that did not return, where `p`
    // still holds its value. This assertion used to require a refusal, which
    // was the false refusal docs/superpowers/plans/2026-09-17-early-return-divergence.md
    // fixed. That the return moves is pinned where it is observable: the
    // return's liveness record (no drop of `p` there) and
    // examples/leaks/arc_box_move.cell.
    try expectAccepted(
        \\pub fn view(shared s: String) -> Int;
        \\pub fn f(copy c: Int, owned p: String) -> arc String {
        \\    if c > 0 {
        \\        return p
        \\    }
        \\    let n = view(p)
        \\    return "x"
        \\}
    );
    // Every other source keeps the refusal: a field, an `Int?`, a block tail
    // (its binding is block-scoped and that box path was not built), and a
    // branch value.
    const refused = "moving an owned place into an 'arc' box is not implemented";
    try expectRejectedWith(
        \\pub struct R { owned s: String }
        \\pub fn f(owned r: R) -> arc String {
        \\    return r.s
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn f(owned p: Int?) -> arc Int? {
        \\    return p
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn f(owned p: String) -> arc String {
        \\    return { p }
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn f(owned p: String) -> arc String {
        \\    return match 1 { _ => p }
        \\}
    , refused);
}

test "R10's move into arc: a whole owned String or list binding is moved into a struct-literal arc field" {
    // Implemented 2026-09-16, the fifth position. The record's drop glue
    // releases the box (R11 row 2), so the source must be dead.
    try expectAccepted(
        \\pub struct Box {
        \\    arc s: String
        \\    arc xs: [Int]
        \\}
        \\pub fn f(owned p: String, owned ys: [Int]) {
        \\    let owned b = Box { s: p, xs: ys }
        \\}
    );
    try expectDiagnostics(
        \\pub struct Box {
        \\    arc s: String
        \\}
        \\pub fn view(shared s: String) -> Int;
        \\pub fn f(owned p: String) -> Int {
        \\    let owned b = Box { s: p }
        \\    return view(p)
        \\}
    ,
        \\t.cell:7:17: error: use of 'p' after it was moved
        \\t.cell:6:28: note: 'p' was moved here into the 'arc' field 's'
        \\
    );
    // Every other source keeps the refusal: a field, an `Int?`, a block
    // value (not opened for an `arc` field) and a branch value.
    const refused = "moving an owned place into an 'arc' box is not implemented";
    try expectRejectedWith(
        \\pub struct R { owned s: String }
        \\pub struct Box { arc s: String }
        \\pub fn f(owned r: R) {
        \\    let owned b = Box { s: r.s }
        \\}
    , refused);
    try expectRejectedWith(
        \\pub struct Opt { arc v: Int? }
        \\pub fn f(owned p: Int?) {
        \\    let owned b = Opt { v: p }
        \\}
    , refused);
    try expectRejectedWith(
        \\pub struct Box { arc s: String }
        \\pub fn f(owned p: String) {
        \\    let owned b = Box { s: { p } }
        \\}
    , refused);
    try expectRejectedWith(
        \\pub struct Box { arc s: String }
        \\pub fn f(owned p: String) {
        \\    let owned b = Box { s: match 1 { _ => p } }
        \\}
    , refused);
}

test "R10's move into arc: a whole owned String or list binding is moved at a call argument" {
    // Implemented 2026-09-16, the fourth position. The callee releases the
    // box (cell_rt.h section 7), so the caller's source must be dead, and
    // an explicit `arc` prefix on the argument is the same move.
    try expectAccepted(
        \\pub fn keep(arc s: String);
        \\pub fn keep_list(arc xs: [Int]);
        \\pub fn f(owned p: String, owned xs: [Int]) {
        \\    keep(p)
        \\    keep_list(xs)
        \\}
        \\pub fn g() {
        \\    let owned t: String = "t"
        \\    keep(arc t)
        \\}
    );
    try expectDiagnostics(
        \\pub fn keep(arc s: String);
        \\pub fn view(shared s: String) -> Int;
        \\pub fn f(owned p: String) -> Int {
        \\    keep(p)
        \\    return view(p)
        \\}
    ,
        \\t.cell:5:17: error: use of 'p' after it was moved
        \\t.cell:4:10: note: 'p' was moved here into the 'arc' box passed to 'keep'
        \\
    );
    // Every other source keeps the refusal: a field, an `Int?`, a block
    // argument (not opened for an `arc` parameter) and a branch value.
    const refused = "moving an owned place into an 'arc' box is not implemented";
    try expectRejectedWith(
        \\pub struct R { owned s: String }
        \\pub fn keep(arc s: String);
        \\pub fn f(owned r: R) {
        \\    keep(r.s)
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn keep_opt(arc v: Int?);
        \\pub fn f(owned p: Int?) {
        \\    keep_opt(p)
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn keep(arc s: String);
        \\pub fn f(owned p: String) {
        \\    keep({ p })
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn keep(arc s: String);
        \\pub fn f(owned p: String) {
        \\    keep(match 1 { _ => p })
        \\}
    , refused);
}

test "R10's move into arc: a whole owned String or list binding is moved by assignment" {
    // Implemented 2026-09-16, the third position, into a WHOLE `arc` binding.
    try expectAccepted(
        \\pub fn f(owned p: String, owned xs: [Int]) {
        \\    var arc a: String = "x"
        \\    a = p
        \\    var arc b: [Int] = [1]
        \\    b = xs
        \\}
    );
    try expectRejectedWith(
        \\pub fn view(shared s: String) -> Int;
        \\pub fn f(owned p: String) -> Int {
        \\    var arc a: String = "x"
        \\    a = p
        \\    return view(p)
        \\}
    , "use of 'p' after it was moved");
    const refused = "moving an owned place into an 'arc' box is not implemented";
    // A field target is the struct-field store, a separate position.
    try expectRejectedWith(
        \\pub struct R { arc s: String }
        \\pub fn f(owned p: String) {
        \\    var owned r = R { s: "x" }
        \\    r.s = p
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn f(owned p: String) {
        \\    var arc a: String = "x"
        \\    a = { p }
        \\}
    , "not implemented");
    try expectRejectedWith(
        \\pub fn f(owned p: String) {
        \\    var arc a: String = "x"
        \\    a = match 1 { _ => p }
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn mk() -> Int?;
        \\pub fn f(owned p: Int?) {
        \\    var arc a = mk()
        \\    a = p
        \\}
    , refused);
}

test "R10's other direction leaves every legal arc source alone" {
    // The refusal is narrow by construction, and each of these was verified to
    // COMPILE and run, not merely to pass the checker. Over-refusing here
    // would reject the shape every existing arc test is written in.
    //
    // A fresh value: what `emitArcConversion` already boxes correctly.
    try expectAccepted(
        \\pub fn make() -> String {
        \\    return "hello"
        \\}
        \\pub fn f() -> Int {
        \\    let arc a = make()
        \\    return 0
        \\}
    );
    // An `arc` source: the legal arc-to-arc retain, R10's first table row.
    try expectAccepted(
        \\pub fn f(arc p: String) -> Int {
        \\    let arc a = p
        \\    return 0
        \\}
    );
    // A `shared` source: a view, which `cell_arc_from_string(
    // cell_string_from_str(p))` COPIES rather than aliases, so there is no
    // second owner and nothing for this rule to refuse.
    try expectAccepted(
        \\pub fn f(shared p: String) -> Int {
        \\    let arc a = p
        \\    return 0
        \\}
    );
    // A branch whose arms are fresh values stays accepted: the value position
    // is peeled to ask about the SOURCE, not refused for being a branch.
    try expectAccepted(
        \\pub fn make() -> String {
        \\    return "hello"
        \\}
        \\pub fn f(copy c: Int) -> Int {
        \\    let arc a = match c { _ => make() }
        \\    return 0
        \\}
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
        \\t.cell:6:47: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
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
    // CHANGED 2026-09-15: the block half is no longer refused. A block is
    // ONE path, so its tail always evaluates and `s1` is moved through it
    // (`openBlockTail`); the branch reasoning above is for `if`
    // and `match`, whose taken arm is unknown. The test "a block tail naming
    // an OUTER owned place moves it" proves the move is recorded, by using
    // `x` afterwards and getting a use-after-move.
    try expectAccepted(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    let owned s1 = mk()
        \\    let owned s2 = { s1 }
        \\}
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
    // Aggregate ownership transfer is absent, so a resource-bearing owned
    // field refuses a place rather than copying its owning header: the copy
    // would leave two owners of one buffer. Scope-end release of a record's
    // UNMOVED fields exists (`moved_paths`), but it cannot make that safe.
    try expectDiagnostics(
        \\pub struct Box { owned s: String }
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    let owned s1 = mk()
        \\    let owned b: Box = Box { s: s1 }
        \\}
    ,
        \\t.cell:5:33: error: cannot store s1 in owned field 's': moving a place into an aggregate is not implemented
        \\t.cell:5:33: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\
    );
    // List-element transfer WAS a disclosed boundary and is now refused.
    // This program was accepted until R2's list-element clause landed, on the
    // argument that slice elements are never released. That argument covered
    // the wrong half: the defect is the SOURCE's release, not the element's.
    // `xs` keeps its own header, `cell_slice_free(&xs)` runs at its scope end,
    // and `zss`'s element is left pointing at the freed buffer. The same shape
    // one type down was measured under AddressSanitizer at `76128ba` and
    // reported `heap-use-after-free`; see `refuseListElementMove`.
    try expectDiagnostics(
        \\pub fn fresh() -> [Int];
        \\pub fn main() {
        \\    let owned xs: [Int] = fresh()
        \\    let owned zss: [[Int]] = [xs]
        \\}
    ,
        \\t.cell:4:31: error: cannot store 'xs' in an 'owned' list element: a list literal copies the element's header by value and the source keeps its own
        \\t.cell:4:31: note: the source is released at its scope end while the list still holds the same buffer; build the element from a fresh value instead
        \\
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

test "R12 refuses a copy place whose type owns resources, by all three routes" {
    // THE PRECONDITION FOR R11 ROW 2. Each of these three was ACCEPTED and
    // emitted a plain `cell_Box snap = buf;` (measured at `76128ba`, three
    // separate `cell emit` runs). That was harmless only while a `record` was
    // never dropped. Row 2's drop glue drops both names, which is a double
    // free of one `cell_string_t`, so the refusal has to land first.
    //
    // Route 1: a direct `copy` of an owned record.
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub struct Box { owned s: String, copy n: Int }
        \\pub fn mk() -> Box {
        \\    let owned buf = Box { s: make(), n: 1 }
        \\    let copy snap = buf
        \\    return snap
        \\}
    ,
        \\t.cell:5:5: error: cannot declare copy binding 'snap': its type may own resources and copying its header would create two owners
        \\t.cell:5:5: note: use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported
        \\
    );
    // Route 2: THROUGH an exclusive borrow, which is the route a type read off
    // the initializer alone would miss -- `v` is a borrow, and what the copy
    // duplicates is its referent's header. `inferBindingType` answers with the
    // referent for exactly this case.
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub struct Box { owned s: String, copy n: Int }
        \\pub fn mk() -> Box {
        \\    var owned buf = Box { s: make(), n: 1 }
        \\    let exclusive v = &mut buf
        \\    let copy snap = v
        \\    return snap
        \\}
    ,
        \\t.cell:6:5: error: cannot declare copy binding 'snap': its type may own resources and copying its header would create two owners
        \\t.cell:6:5: note: use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported
        \\
    );
    // Route 3: the parameter position. The caller is what duplicates the
    // header, so this is refused at the declaration whether or not a body
    // follows; the bodyless spelling is the second case below.
    try expectDiagnostics(
        \\pub struct Box { owned s: String, copy n: Int }
        \\pub fn f(copy b: Box) -> Box { return b }
    ,
        \\t.cell:2:1: error: cannot declare copy parameter 'b': its type may own resources and copying its header would create two owners
        \\t.cell:2:1: note: use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported
        \\
    );
    try expectDiagnostics(
        \\pub struct Box { owned s: String, copy n: Int }
        \\pub fn f(copy b: Box) -> Int;
    ,
        \\t.cell:2:1: error: cannot declare copy parameter 'b': its type may own resources and copying its header would create two owners
        \\t.cell:2:1: note: use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported
        \\
    );
    // A bare `String` reaches it too, through the call-return and the
    // source-place routes rather than through a struct name.
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub fn main() {
        \\    let copy s = make()
        \\}
    ,
        \\t.cell:3:5: error: cannot declare copy binding 's': its type may own resources and copying its header would create two owners
        \\t.cell:3:5: note: use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported
        \\
    );
}

test "R12 refuses a copy binding whose type comes back through a match arm" {
    // The fourth route, and the one that was open after the other three were
    // closed: `inferBindingType` had no `.match_expr` arm, so the binding's
    // type resolved to null and `refuseResourceCopy` returned without a
    // verdict. Nothing caught it downstream either -- codegen's own inference
    // had the same hole, the temporary fell back to `int64_t`, and `cc`
    // rejected the module. That C type error was the ONLY thing standing
    // between this program and two `cell_string_t` headers over one buffer.
    try expectDiagnostics(
        \\pub fn make() -> String {
        \\    return "hello"
        \\}
        \\pub fn main() -> Int {
        \\    let owned s = make()
        \\    let copy c = match s { x => x }
        \\    return 0
        \\}
    ,
        \\t.cell:6:5: error: cannot declare copy binding 'c': its type may own resources and copying its header would create two owners
        \\t.cell:6:5: note: use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported
        \\
    );
    // The inference is by SHAPE and stays narrow: an arm body that is not the
    // arm's own binding still resolves through the body, so a scalar match
    // keeps being accepted rather than being swept up by the new arm.
    try expectAccepted(
        \\pub fn main() -> Int {
        \\    let copy n = 7
        \\    let copy c = match n { x => x }
        \\    return c
        \\}
    );
}

test "R12's copy clause leaves scalar places alone, which is most of the corpus" {
    // THE OVER-REFUSAL CONTROLS. A refusal keyed on a resource shape is only
    // as good as its negative answer, and every `copy` in `examples/` is one
    // of these shapes. A scalar-only record is the interesting one: it has a
    // struct name, so a rule keyed on "is it a record" rather than on the
    // shape would refuse it.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let copy n = buf.len
        \\    let copy m = 1
        \\}
    );
    try expectAccepted(
        \\pub struct Point { copy x: Int, copy y: Int }
        \\pub fn dist(copy a: Point, copy b: Point) -> Int { return a.x - b.x }
        \\pub fn main() {
        \\    let owned p = Point { x: 1, y: 2 }
        \\    let copy q = p
        \\    let copy d = dist(copy p, copy q)
        \\}
    );
    // An `arc` binding of the same resource-bearing type is NOT refused: an
    // `arc` place retains rather than duplicating, which is R12's other half.
    try expectAccepted(
        \\pub fn make() -> String;
        \\pub fn main() {
        \\    let arc s = make()
        \\    let arc alias = s
        \\}
    );
}

test "R2 refuses an owned place in a list element, and still accepts a fresh one" {
    // The measurement behind the refusal, so the next reader does not have to
    // re-derive it: emitted at `76128ba`, `mks` freed `s` BEFORE returning the
    // list that held its header, and the caller's read reported
    // `heap-use-after-free` under AddressSanitizer with `cell_string_free` as
    // the freeing frame. A live defect for `String`, independent of R11.
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub fn mks() -> [String] {
        \\    let owned s = make()
        \\    return [s]
        \\}
    ,
        \\t.cell:4:13: error: cannot store 's' in an 'owned' list element: a list literal copies the element's header by value and the source keeps its own
        \\t.cell:4:13: note: the source is released at its scope end while the list still holds the same buffer; build the element from a fresh value instead
        \\
    );
    // A record element is the same defect, and is what R11 row 2's drop glue
    // would otherwise have created for every record on the day it landed.
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub struct Box { owned s: String, copy n: Int }
        \\pub fn mk() -> [Box] {
        \\    let owned buf = Box { s: make(), n: 1 }
        \\    return [buf]
        \\}
    ,
        \\t.cell:5:13: error: cannot store 'buf' in an 'owned' list element: a list literal copies the element's header by value and the source keeps its own
        \\t.cell:5:13: note: the source is released at its scope end while the list still holds the same buffer; build the element from a fresh value instead
        \\
    );
    // THE OVER-REFUSAL CONTROLS. A fresh value has no source to outlive it, a
    // scalar place owns nothing, and a `copy` place is duplicable by R12.
    try expectAccepted(
        \\pub fn make() -> String;
        \\pub fn main() {
        \\    let owned n = 3
        \\    let owned xs: [Int] = [n]
        \\    let owned ys: [String] = [make()]
        \\}
    );
    // And the block-tail local, which the watermark in the list arm exists to
    // keep: `t` is the block's VALUE, excluded from `emitValueBlockDrops`, so
    // the element is its only owner. An OUTER place reached through the same
    // block tail keeps its own header and is refused.
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    let owned xs: [String] = [{
        \\        let owned t = make()
        \\        t
        \\    }]
        \\}
    );
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s = make()
        \\    let owned xs: [String] = [{ s }]
        \\}
    ,
        \\t.cell:5:33: error: cannot store 's' in an 'owned' list element: a list literal copies the element's header by value and the source keeps its own
        \\t.cell:5:33: note: the source is released at its scope end while the list still holds the same buffer; build the element from a fresh value instead
        \\
    );
}

test "R7 refuses a match-arm alias in a list element, the other half of R2's list clause" {
    // The advisor caught this after the `.place` half landed: the same site
    // still read an ALIAS, on the same justification the `.place` half had
    // just retracted. Measured before the fix, `cell check` accepted this and
    // the caller's read reported heap-use-after-free under AddressSanitizer,
    // with `cell_string_free` on the scrutinee as the freeing frame.
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub fn f() -> [String] {
        \\    let owned s = make()
        \\    return match s { x => [x] }
        \\}
    ,
        \\t.cell:4:28: error: cannot store the match binding 'x' aliasing 's' in an 'owned' list element: the scrutinee still owns the value
        \\t.cell:4:28: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
    // THE OVER-REFUSAL CONTROL: a fresh value in every arm is not an alias.
    try expectAccepted(
        \\pub fn make() -> String;
        \\pub fn f(copy c: Int) -> [String] {
        \\    return match c { 0 => [make()], _ => [] }
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

// ── R2.a at a `continue` (2026-09-16) ───────────────────────────────────────
//
// Each refused program below was accepted before this change and ran as an
// AddressSanitizer double free (exit 134), measured with `cell run` and a
// `cc -fsanitize=address` wrapper.

const jump_prelude =
    \\pub fn take(owned s: String) { }
    \\pub fn consume(owned s: String) -> Bool { return false }
    \\
;
// jump_prelude occupies lines 1 and 2, so a test body's first line is 3.

test "R2.a: a continue between a move and its revival is refused" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i < n {
        \\            continue
        \\        }
        \\        v = "b"
        \\    }
        \\}
    ,
        \\t.cell:8:14: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:10:13: note: this 'continue' is reached before 'v' is assigned again
        \\
    );
}

test "R2.a: a continue after the revival is accepted" {
    try expectAccepted(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        v = "b"
        \\        if i < n {
        \\            continue
        \\        }
        \\    }
        \\}
    );
}

test "R2.a: a continue in an inner loop is checked against the inner loop" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 2 {
        \\        i = i + 1
        \\        var j = 0
        \\        while j < 2 {
        \\            j = j + 1
        \\            take(v)
        \\            if j < 2 {
        \\                continue
        \\            }
        \\            v = "b"
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:11:18: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:13:17: note: this 'continue' is reached before 'v' is assigned again
        \\
    );
}

test "R2.a: a place already moved before the loop does not fire at a continue" {
    // The body is walked from the entry state, so an iteration that restarts
    // with `v` still moved is exactly the state that was checked. The body
    // never reads `v`, so nothing here is a use.
    try expectAccepted(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    take(v)
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        if i < n {
        \\            continue
        \\        }
        \\    }
        \\}
    );
}

test "R2.a: a move reached by both a continue and the body end is reported once" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i < n {
        \\            continue
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:8:14: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:10:13: note: this 'continue' is reached before 'v' is assigned again
        \\
    );
}

test "R2.a: reviving a place moved before the loop does not hide a body move" {
    // `a = ...` removes `a`'s entry from `dead` with `swapRemove`, which
    // moved `b`'s in-body entry below the index the body-end check used to
    // start from, so `b` was never reported.
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned a: String = "a"
        \\    var owned b: String = "b"
        \\    take(a)
        \\    var i = 0
        \\    while i < n {
        \\        i = i + 1
        \\        take(b)
        \\        a = "c"
        \\    }
        \\}
    ,
        \\t.cell:10:14: error: 'b' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:8:5: note: 'b' is declared outside this loop; assign to it before the end of the body to revive it
        \\
    );
}

// ── a `break` or a condition move leaves the place dead after the loop ──────

test "R2: a use after a loop that may have broken while moved is refused" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i > n {
        \\            break
        \\        }
        \\        v = "b"
        \\    }
        \\    take(v)
        \\}
    ,
        \\t.cell:14:10: error: use of 'v' after it was moved
        \\t.cell:8:14: note: 'v' was moved here by the call to 'take'
        \\
    );
}

test "R2: a revival after the loop clears the break state" {
    try expectAccepted(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i > n {
        \\            break
        \\        }
        \\        v = "b"
        \\    }
        \\    v = "c"
        \\    take(v)
        \\}
    );
}

test "R2: a use after a loop whose condition moves the place is refused" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    while consume(v) {
        \\        v = "b"
        \\    }
        \\    take(v)
        \\}
    ,
        \\t.cell:8:10: error: use of 'v' after it was moved
        \\t.cell:5:19: note: 'v' was moved here by the call to 'consume'
        \\
    );
}

test "R2.a: a condition move the body revives is accepted" {
    try expectAccepted(jump_prelude ++
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    while consume(v) {
        \\        v = "b"
        \\    }
        \\}
    );
}

test "R2.a: a condition move the body does not revive is refused" {
    // The second evaluation of the condition reads the moved `v`.
    try expectDiagnostics(jump_prelude ++
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while consume(v) {
        \\        i = i + 1
        \\        if i > 1 {
        \\            break
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:6:19: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:6:5: note: 'v' is declared outside this loop; assign to it before the end of the body to revive it
        \\
    );
}

test "R2.a: an inner break while moved reaches the outer body end" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 2 {
        \\        i = i + 1
        \\        var j = 0
        \\        while j < 2 {
        \\            j = j + 1
        \\            take(v)
        \\            if j < 5 {
        \\                break
        \\            }
        \\            v = "b"
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:11:18: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:6:5: note: 'v' is declared outside this loop; assign to it before the end of the body to revive it
        \\
    );
}

test "R2: a use after a loop that may run zero times sees the move before it" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    take(v)
        \\    var i = 0
        \\    while i < n {
        \\        i = i + 1
        \\        v = "b"
        \\    }
        \\    take(v)
        \\}
    ,
        \\t.cell:11:10: error: use of 'v' after it was moved
        \\t.cell:5:10: note: 'v' was moved here by the call to 'take'
        \\
    );
}

// ── a block in an `owned` let position (2026-09-15) ────────────────────────

const block_prelude =
    \\pub fn make() -> String;
    \\pub fn eat(owned s: String) { }
    \\
;
// block_prelude occupies lines 1 through 3 (its trailing empty line counts), so a
// test body's first line is 4.

test "an owned let takes a block whose tail is the block's own owned local" {
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    let owned s = {
        \\        let owned t = make()
        \\        t
        \\    }
        \\}
    );
}

test "the block's statements are checked in a live scope: a tail moved earlier is a use after move" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s = {
        \\        let owned t = make()
        \\        eat(owned t)
        \\        t
        \\    }
        \\}
    ,
        \\t.cell:7:9: error: use of 't' after it was moved
        \\t.cell:6:19: note: 't' was moved here by the call to 'eat'
        \\
    );
}

test "a block tail naming an OUTER owned place moves it, because a block is one path" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned x = make()
        \\    let owned s = { x }
        \\    eat(owned x)
        \\}
    ,
        \\t.cell:6:15: error: use of 'x' after it was moved
        \\t.cell:5:21: note: 'x' was moved here by binding it to 's'
        \\
    );
}

test "a nested block tail resolves through both scopes" {
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    let owned s = {
        \\        let owned t = make()
        \\        {
        \\            let owned u = t
        \\            u
        \\        }
        \\    }
        \\}
    );
}

test "a block tail that is the block's own arc local is R10, naming the local" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s = {
        \\        let arc t = "a"
        \\        t
        \\    }
        \\}
    ,
        \\t.cell:6:9: error: cannot bind 'arc' value 't' to 'owned' binding 's': ownership is shared and cannot be made unique
        \\t.cell:6:9: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "a block tail that borrows the block's own local is R18" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s = {
        \\        let owned t = make()
        \\        &t
        \\    }
        \\}
    ,
        \\t.cell:6:9: error: cannot bind a borrow of 't' to the 'owned' binding 's': a borrow does not confer ownership
        \\t.cell:6:9: note: R18: an 'owned' binding is destroyed at the end of its scope (R16), so binding one to a borrow frees the lender's value twice; write 'let shared s' or 'let exclusive s' to hold the borrow
        \\
    );
}

test "a block-local tail at a call argument resolves like the let position" {
    // CHANGED 2026-09-15 (later the same day): refused until the six
    // consumption sites shared `openBlockTail`. The move is proven by the
    // use-after-move test that follows, not by acceptance alone.
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    eat(owned {
        \\        let owned t = make()
        \\        t
        \\    })
        \\}
    );
}

test "a call argument block whose tail is an OUTER place moves it" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s1 = make()
        \\    eat(owned { s1 })
        \\    eat(owned s1)
        \\}
    ,
        \\t.cell:6:15: error: use of 's1' after it was moved
        \\t.cell:5:17: note: 's1' was moved here by the call to 'eat'
        \\
    );
}

test "a return block resolves its own owned local" {
    try expectAccepted(block_prelude ++
        \\pub fn mk() -> String {
        \\    return {
        \\        let owned t = make()
        \\        t
        \\    }
        \\}
    );
}

test "a return block whose tail is an OUTER place is accepted after a conditional return" {
    // A use after a conditional return is reached only on the path that did
    // not return, so it is ACCEPTED since 2026-09-17 (this test used to pin
    // the false refusal). The move itself is pinned by the codegen test "a
    // return block whose tail is an outer owned place moves it: no drop of
    // the source".
    try expectAccepted(block_prelude ++
        \\pub fn mk(copy c: Bool) -> String {
        \\    let owned s1 = make()
        \\    if c {
        \\        return { s1 }
        \\    }
        \\    eat(owned s1)
        \\    return make()
        \\}
    );
}

test "an assignment block resolves its own owned local" {
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    var owned s2 = make()
        \\    s2 = {
        \\        let owned t = make()
        \\        t
        \\    }
        \\}
    );
}

test "an assignment block whose tail is an OUTER place moves it" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s1 = make()
        \\    var owned s2 = make()
        \\    s2 = { s1 }
        \\    eat(owned s1)
        \\}
    ,
        \\t.cell:7:15: error: use of 's1' after it was moved
        \\t.cell:6:12: note: 's1' was moved here by assigning it to 's2'
        \\
    );
}

test "a resource-bearing struct field resolves a block-local tail and still refuses the place" {
    // The field site resolves the tail like the other five, and then its
    // own rule applies: a PLACE cannot be moved into an aggregate yet (R11,
    // aggregate transfer). The refusal now names `t` instead of blaming
    // the block.
    try expectDiagnostics(block_prelude ++
        \\struct Box { owned s: String }
        \\pub fn main() {
        \\    let owned b = Box { s: {
        \\        let owned t = make()
        \\        t
        \\    } }
        \\}
    ,
        \\t.cell:7:9: error: cannot store t in owned field 's': moving a place into an aggregate is not implemented
        \\t.cell:7:9: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\
    );
}

test "a resource-free struct field reads a block-local tail" {
    try expectAccepted(block_prelude ++
        \\struct Pair { owned n: Int }
        \\pub fn main() {
        \\    let owned p = Pair { n: {
        \\        let copy t = 1
        \\        t
        \\    } }
        \\}
    );
}

test "a list element block resolves its own owned local, and reads it like any element" {
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    let owned xs: [String] = [{
        \\        let owned t = make()
        \\        t
        \\    }]
        \\}
    );
}

test "an owned keyword in front of a block is peeled, so the block still opens" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s1 = make()
        \\    let owned s2 = owned { s1 }
        \\    eat(owned s1)
        \\}
    ,
        \\t.cell:6:15: error: use of 's1' after it was moved
        \\t.cell:5:28: note: 's1' was moved here by binding it to 's2'
        \\
    );
}

test "a block-local tail reached through a BRANCH is still refused, and says so" {
    // A block inside an `if` arm is not the consumed expression; the `if`
    // is, and which arm ran is unknown. The classifier's block arm is now
    // reached only this way.
    try expectDiagnostics(block_prelude ++
        \\pub fn main(copy c: Bool) {
        \\    let owned s = if c {
        \\        let owned t = make()
        \\        t
        \\    } else {
        \\        make()
        \\    }
        \\}
    ,
        \\t.cell:6:9: error: cannot bind the block-local binding 't' reached through a branch to 'owned' binding 's': its ownership cannot be resolved here
        \\t.cell:6:9: note: R10 refuses what it cannot prove is not 'arc': an 'arc' value made unique is freed twice
        \\
    );
}

test "a valueless block at an assignment is walked exactly once" {
    // The `.unit` arm must RETURN, not fall through to `checkExpr`. The
    // discriminator is a move of an OUTER place inside the block: a second
    // walk would see `s1` already moved and report a use-after-move. A
    // canary on a later binding's line would not catch this, because
    // borrowck's own ids stay self-consistent across a double walk; only
    // codegen's `wasMoved` lookups would drift. The typecheck unit mismatch
    // is not in the way: this harness runs borrowck alone.
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    let owned s1 = make()
        \\    var owned s2 = make()
        \\    s2 = {
        \\        eat(owned s1)
        \\    }
        \\}
    );
}

test "a valueless block at a call argument is walked exactly once" {
    // The `.unit` arm `continue`s the argument loop; same discriminator.
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    let owned s1 = make()
        \\    eat(owned {
        \\        eat(owned s1)
        \\    })
        \\}
    );
}

test "a block tail that is a borrow alias of the block's own local cannot leave through an owned position" {
    // The value-position release in codegen keeps a local the tail can
    // reach alive; this is the other half, at the owned sites, where a
    // borrow alias is refused outright rather than copied.
    try expectDiagnostics(block_prelude ++
        \\pub fn mk() -> String {
        \\    return {
        \\        let owned t = make()
        \\        let shared v = &t
        \\        v
        \\    }
        \\}
    ,
        \\t.cell:7:9: error: cannot move out of 'v': it is a shared borrow, not an owner
        \\
    );
}

test "R4 refuses reassigning an arc var while a shared borrow of it is live, which the row 5 pre-drop relies on" {
    // codegen's reassignment pre-drop (R11 row 5) frees the old box before
    // the store; a view of that box surviving the statement would dangle.
    // It cannot: this is the refusal. A borrow that is DEAD by then (NLL)
    // is accepted and never read again.
    try expectDiagnostics(
        \\pub fn inspect(shared s: String) -> Int { return 1 }
        \\pub fn main() {
        \\    var arc v = "one"
        \\    let shared w = &v
        \\    v = "two"
        \\    inspect(w)
        \\}
    ,
        \\t.cell:5:5: error: cannot assign to 'v' while it is borrowed as shared
        \\t.cell:4:21: note: the shared borrow starts here and lasts to the end of this block
        \\
    );
}

test "R7 write clause: assigning to the scrutinee while an arm binding aliases it is refused" {
    // Measured at 4c93571 before this clause existed: `cell check` exit 0,
    // ASan heap-use-after-free at `print(x)`, because the row 5 pre-drop
    // released the box `x` still pointed at. Flat and inside a `while`.
    try expectDiagnostics(
        \\pub fn print(shared s: String);
        \\pub fn main() {
        \\    var arc v = "one"
        \\    match v {
        \\        x => {
        \\            v = "two"
        \\            print(x)
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:6:13: error: cannot assign to 'v' while the match binding 'x' aliases it
        \\t.cell:5:9: note: R7: a match binding aliases the scrutinee rather than copying or borrowing it, and lasts to the end of its arm; assign after the match, or bind a copy of the value before it
        \\
    );
    try expectDiagnostics(
        \\pub fn print(shared s: String);
        \\pub fn main() {
        \\    var arc v = "one"
        \\    var i = 0
        \\    while i < 3 {
        \\        match v {
        \\            x => {
        \\                v = "two"
        \\                print(x)
        \\            }
        \\        }
        \\        i = i + 1
        \\    }
        \\}
    ,
        \\t.cell:8:17: error: cannot assign to 'v' while the match binding 'x' aliases it
        \\t.cell:7:13: note: R7: a match binding aliases the scrutinee rather than copying or borrowing it, and lasts to the end of its arm; assign after the match, or bind a copy of the value before it
        \\
    );
}

test "R7 write clause covers owned scrutinees too, and an assignment after the match is fine" {
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub fn print(shared s: String);
        \\pub fn main() {
        \\    var owned s = make()
        \\    match s {
        \\        x => {
        \\            s = make()
        \\            print(x)
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:7:13: error: cannot assign to 's' while the match binding 'x' aliases it
        \\t.cell:6:9: note: R7: a match binding aliases the scrutinee rather than copying or borrowing it, and lasts to the end of its arm; assign after the match, or bind a copy of the value before it
        \\
    );
    try expectAccepted(
        \\pub fn print(shared s: String);
        \\pub fn main() {
        \\    var arc v = "one"
        \\    match v {
        \\        x => {
        \\            print(x)
        \\        }
        \\    }
        \\    v = "two"
        \\    print(v)
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

test "after_loop is live for an outer var revived on every path out of the while" {
    // R16 residual: a var declared outside a while, moved inside it, and
    // revived before the body ends. `loop_moved` still poisons in-loop
    // exits and the function-end `block_end`; `after_loop` is the one
    // record that stays live. P_exit: no condition move, not dead at body
    // end, every jump this walk saw still held a value (none here).
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        take(v)
        \\        v = "b"
        \\        i = i + 1
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const key = h.firstWhile("f");
    try std.testing.expect(h.checker.liveAtExit(.after_loop, key, v));
    try std.testing.expect(!h.checker.liveAtExit(.block_end, h.fnBodyKey("f"), v));
}

test "after_loop is absent when a break is taken while the outer var is dead" {
    // `take(v); if i > n { break }; v = "b"`. The jump is recorded live=false
    // before invalidation, so P_exit fails and there is no after_loop record.
    // Ignoring that dead jump and emitting the drop was an AddressSanitizer
    // double free (exit 134), measured: the `break` path already handed the
    // buffer to `take`, and C `break` runs the code after the while.
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i > n {
        \\            break
        \\        }
        \\        v = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const key = h.firstWhile("f");
    try std.testing.expect(!h.checker.liveAtExit(.after_loop, key, v));
}

test "after_loop_skip is live for a skip-revival break, and names that break" {
    // Same program as the test above. `after_loop` stays absent; the new
    // kind vouches for the release only together with the skip record.
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i > n {
        \\            break
        \\        }
        \\        v = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const key = h.firstWhile("f");
    try std.testing.expect(!h.checker.liveAtExit(.after_loop, key, v));
    try std.testing.expect(h.checker.liveAtExit(.after_loop_skip, key, v));
    try std.testing.expectEqual(@as(?usize, key), h.checker.skipBreakLoop(h.firstJump("f")));
    try std.testing.expect(h.checker.loopHasSkipBreaks(key));
}

test "after_loop_skip is absent for a field move" {
    // A field move is released per field elsewhere (`exit_field_liveness`),
    // never by a whole-binding release after the loop. (A dead `continue`
    // never reaches this rule: R2.a refuses it.)
    var h: LiveHarness = try .init(
        \\pub struct P { a: String, b: String }
        \\pub fn take(owned s: String) { }
        \\pub fn field(copy n: Int, owned p: P) {
        \\    var owned q: P = p
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(q.a)
        \\        if i > n {
        \\            break
        \\        }
        \\        q.a = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    const key = h.firstWhile("field");
    try std.testing.expect(!h.checker.liveAtExit(.after_loop_skip, key, h.binding("q")));
    try std.testing.expect(!h.checker.loopHasSkipBreaks(key));
}

test "a return inside an accepted loop keeps the walk's liveness" {
    // 2026-09-17. An accepted loop no longer poisons its `return` records:
    // after the revival the value is live at the `return`.
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        v = "b"
        \\        if i > n {
        \\            return
        \\        }
        \\    }
        \\}
    );
    defer h.deinit();
    try std.testing.expect(h.checker.liveAtExit(.return_stmt, firstReturnIn(h.fnBody("f")).?, h.binding("v")));
}

test "a return between the move and the revival stays dead" {
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i > n {
        \\            return
        \\        }
        \\        v = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    try std.testing.expect(!h.checker.liveAtExit(.return_stmt, firstReturnIn(h.fnBody("f")).?, h.binding("v")));
}

test "an if branch that always returns does not reach the code after the if" {
    // 2026-09-17, docs/superpowers/plans/2026-09-17-early-return-divergence.md.
    try expectAccepted(
        \\pub fn take(owned s: String) { }
        \\pub fn early(copy c: Bool, owned s: String) {
        \\    if c {
        \\        take(s)
        \\        return
        \\    }
        \\    take(s)
        \\}
        \\pub fn early_value(copy c: Bool, owned s: String) -> String {
        \\    if c {
        \\        return s
        \\    }
        \\    return s
        \\}
        \\pub fn else_side(copy c: Bool, owned s: String) {
        \\    if c {
        \\        let n = 1
        \\    } else {
        \\        take(s)
        \\        return
        \\    }
        \\    take(s)
        \\}
        \\pub fn nested(copy c: Bool, copy d: Bool, owned s: String) {
        \\    if c {
        \\        take(s)
        \\        if d {
        \\            return
        \\        } else {
        \\            return
        \\        }
        \\    }
        \\    take(s)
        \\}
        \\
    );
}

test "a match arm that always leaves does not reach the code after the match" {
    // 2026-09-17, design C: the divergence rule applied to `match` arms.
    try expectAccepted(
        \\pub fn take(owned s: String) { }
        \\pub fn arm(copy o: Int?, owned s: String) {
        \\    match o {
        \\        Some(x) => {
        \\            take(s)
        \\            return
        \\        },
        \\        None => {
        \\            let n = 0
        \\        },
        \\    }
        \\    take(s)
        \\}
        \\pub fn tail_match(copy c: Bool, copy o: Int?, owned s: String) {
        \\    if c {
        \\        take(s)
        \\        match o {
        \\            Some(x) => {
        \\                return
        \\            },
        \\            None => {
        \\                return
        \\            },
        \\        }
        \\    }
        \\    take(s)
        \\}
        \\
    );
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy o: Int?, copy d: Bool, owned s: String) {
        \\    match o {
        \\        Some(x) => {
        \\            take(s)
        \\            if d {
        \\                return
        \\            }
        \\        },
        \\        None => {
        \\            let n = 0
        \\        },
        \\    }
        \\    take(s)
        \\}
        \\
    , "use of 's' after it was moved");
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn g(copy o: Int?, owned s: String) {
        \\    take(s)
        \\    match o {
        \\        Some(x) => {
        \\            return
        \\        },
        \\        None => {
        \\            return
        \\        },
        \\    }
        \\    take(s)
        \\}
        \\
    , "use of 's' after it was moved");
}

test "a branch that only sometimes returns still reaches the code after the if" {
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Bool, copy d: Bool, owned s: String) {
        \\    if c {
        \\        take(s)
        \\        if d {
        \\            return
        \\        }
        \\    }
        \\    take(s)
        \\}
        \\
    , "use of 's' after it was moved");
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn g(copy c: Bool, owned s: String) {
        \\    if c {
        \\        return
        \\    } else {
        \\        take(s)
        \\    }
        \\    take(s)
        \\}
        \\
    , "use of 's' after it was moved");
}

const owning_ok_prelude =
    \\pub fn take(owned s: String) { }
    \\pub fn keep(owned r: Result<String, Int32>) { }
    \\pub fn view(shared s: String) -> Int { return 0 }
    \\pub fn read() -> Result<String, Int32>;
    \\
;

test "Ok moves an owning String operand" {
    // Owning String in Ok (2026-09-17).
    try expectRejectedWith(owning_ok_prelude ++
        \\pub fn f(owned s: String) -> Result<String, Int32> {
        \\    let r: Result<String, Int32> = Ok(s)
        \\    take(s)
        \\    return r
        \\}
        \\
    , "use of 's' after it was moved");
    // A scalar operand is still only read.
    try expectAccepted(
        \\pub fn f(copy n: Int) -> Int {
        \\    let r: Result<Int, Int32> = Ok(n)
        \\    return n
        \\}
        \\
    );
}

test "Ok(owned ..) consumes the Result on its own arm only" {
    try expectRejectedWith(owning_ok_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) {
        \\    match r {
        \\        Ok(owned x) => take(x),
        \\        Err(_) => {},
        \\    }
        \\    keep(r)
        \\}
        \\
    , "use of 'r' after it was moved");
    try expectAccepted(owning_ok_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) {
        \\    match r {
        \\        Ok(owned x) => take(x),
        \\        Err(_) => keep(r),
        \\    }
        \\}
        \\
    );
    try expectRejectedWith(owning_ok_prelude ++
        \\pub fn f(owned r: Result<String, Int32>, copy n: Int) {
        \\    var i = 0
        \\    while i < n {
        \\        i = i + 1
        \\        match r {
        \\            Ok(owned x) => take(x),
        \\            Err(_) => {},
        \\        }
        \\    }
        \\}
        \\
    , "is moved inside a loop");
}

test "Ok(shared ..) borrows the Result for its arm" {
    try expectRejectedWith(owning_ok_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) -> Int {
        \\    return match r {
        \\        Ok(shared x) => {
        \\            keep(r)
        \\            view(x)
        \\        },
        \\        Err(_) => 0,
        \\    }
        \\}
        \\
    , "cannot move 'r' while it is borrowed");
    try expectAccepted(owning_ok_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) -> Int {
        \\    let n = match r {
        \\        Ok(shared x) => view(x),
        \\        Err(_) => 0,
        \\    }
        \\    keep(r)
        \\    return n
        \\}
        \\
    );
}

test "Ok of a match alias is refused like any consumption of an alias" {
    try expectRejectedWith(owning_ok_prelude ++
        \\pub fn f(owned s: String) -> Result<String, Int32> {
        \\    return match s { y => Ok(y) }
        \\}
        \\
    , "the scrutinee still owns the value");
}

const owning_err_prelude =
    \\pub fn take(owned s: String) { }
    \\pub fn keepe(owned r: Result<Int, String>) { }
    \\pub fn viewe(shared s: String) -> Int { return 0 }
    \\
;

test "Err moves an owning String and Err(owned ..) consumes on its arm only" {
    // Owning String in Err (sub-project 3, 2026-09-17).
    try expectRejectedWith(owning_err_prelude ++
        \\pub fn f(owned s: String) -> Result<Int, String> {
        \\    let r: Result<Int, String> = Err(s)
        \\    take(s)
        \\    return r
        \\}
        \\
    , "use of 's' after it was moved");
    try expectRejectedWith(owning_err_prelude ++
        \\pub fn f(owned r: Result<Int, String>) {
        \\    match r {
        \\        Ok(_) => {},
        \\        Err(owned e) => take(e),
        \\    }
        \\    keepe(r)
        \\}
        \\
    , "use of 'r' after it was moved");
    try expectAccepted(owning_err_prelude ++
        \\pub fn f(owned r: Result<Int, String>) {
        \\    match r {
        \\        Ok(_) => keepe(r),
        \\        Err(owned e) => take(e),
        \\    }
        \\}
        \\
    );
    try expectRejectedWith(owning_err_prelude ++
        \\pub fn f(owned r: Result<Int, String>) -> Int {
        \\    return match r {
        \\        Ok(_) => 0,
        \\        Err(shared e) => {
        \\            keepe(r)
        \\            viewe(e)
        \\        },
        \\    }
        \\}
        \\
    , "cannot move 'r' while it is borrowed");
    try expectRejectedWith(owning_err_prelude ++
        \\pub fn f(owned s: String) -> Result<Int, String> {
        \\    return match s { y => Err(y) }
        \\}
        \\
    , "the scrutinee still owns the value");
}

test "Some moves an owning String and Some(owned ..) consumes on its arm only" {
    // Sub-project 4 (2026-09-17).
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn f(owned s: String) -> String? {
        \\    let o: String? = Some(s)
        \\    take(s)
        \\    return o
        \\}
        \\
    , "use of 's' after it was moved");
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn keepo(owned o: String?) { }
        \\pub fn f(owned o: String?) {
        \\    match o {
        \\        Some(owned x) => take(x),
        \\        None => {},
        \\    }
        \\    keepo(o)
        \\}
        \\
    , "use of 'o' after it was moved");
    try expectAccepted(
        \\pub fn take(owned s: String) { }
        \\pub fn keepo(owned o: String?) { }
        \\pub fn f(owned o: String?) {
        \\    match o {
        \\        Some(owned x) => take(x),
        \\        None => keepo(o),
        \\    }
        \\}
        \\
    );
}

test "Ok of a scalar match alias is still only a read" {
    try expectAccepted(
        \\pub fn f(owned n: Int) -> Result<Int, Int32> {
        \\    return match n { y => Ok(y) }
        \\}
        \\
    );
}

test "yielding an Ok(owned ..) binding straight out of its arm is refused" {
    try expectRejectedWith(owning_ok_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) -> Int {
        \\    let owned s: String = match r {
        \\        Ok(owned x) => x,
        \\        Err(_) => "e",
        \\    }
        \\    take(s)
        \\    return 0
        \\}
        \\
    , "yielding the 'Ok(owned x)' binding directly from its arm is not implemented");
}

test "Ok(owned ..) leaves the Result live on the other arm and dead after the match" {
    var h: LiveHarness = try .init(owning_ok_prelude ++
        \\pub fn f(owned res: Result<String, Int32>) {
        \\    match res {
        \\        Ok(owned x) => take(x),
        \\        Err(_) => {},
        \\    }
        \\}
    );
    defer h.deinit();
    // `h.binding` finds the FIRST binding of a name, and the prelude's
    // `keep` has an `r`, hence `res`.
    const r = h.binding("res");
    try std.testing.expect(h.checker.wasMoved(r));
    try std.testing.expect(!h.checker.liveAtExit(.block_end, h.fnBodyKey("f"), r));
}

test "a moved-then-break branch is accepted inside the loop and refused after it" {
    try expectAccepted(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Bool, owned s: String) {
        \\    var owned v: String = s
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        if c {
        \\            take(v)
        \\            break
        \\        }
        \\        take(v)
        \\        v = "c"
        \\    }
        \\}
        \\
    );
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Bool, owned s: String) {
        \\    var owned v: String = s
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        if c {
        \\            take(v)
        \\            break
        \\        }
        \\    }
        \\    take(v)
        \\}
        \\
    , "use of 'v' after it was moved");
}

test "after_loop is absent when the condition moves the outer var" {
    // `while consume(v) { v = make() }`: the last failing condition already
    // took `v`. Treating that as live and dropping after the loop was an
    // AddressSanitizer double free (exit 134), measured.
    var h: LiveHarness = try .init(
        \\pub fn consume(owned s: String) -> Bool { return true }
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    while consume(v) {
        \\        v = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const key = h.firstWhile("f");
    try std.testing.expect(!h.checker.liveAtExit(.after_loop, key, v));
}

test "after_loop is live for a revival then break, and the jump itself stays dead" {
    // `take(v); v = "b"; if i > n { break }`. Every jump this walk saw still
    // held a value, so after_loop is live. The jump record is poisoned by
    // `loop_moved`, so codegen must not drop at `break` (C break already
    // runs the code after the while).
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        v = "b"
        \\        if i > n {
        \\            break
        \\        }
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const key = h.firstWhile("f");
    try std.testing.expect(h.checker.liveAtExit(.after_loop, key, v));
    try std.testing.expect(!h.checker.liveAtExit(.jump, h.firstJump("f"), v));
}

test "R16 field live at the non-moving branch_end and dead after the merge" {
    // Residual 1 at field granularity: `take(owned p.a)` inside `if c`
    // marks `p.a` moved for the whole function, so whole-binding
    // `liveAtExit` is false on every path (any dead field path). The
    // sibling field records keep the else path live and the merge dead.
    var h: LiveHarness = try .init(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f(shared c: Bool) {
        \\    let owned p: Pair = Pair { a: "x", b: "y" }
        \\    if (c) {
        \\        take(owned p.a)
        \\    }
        \\}
    );
    defer h.deinit();
    const p = h.binding("p");
    const if_expr = h.firstIf("f");
    const then_key = Checker.branchKeyOf(if_expr.kind.if_expr.then_body);
    const else_key = @intFromPtr(if_expr);
    const end_key = h.fnBodyKey("f");
    try std.testing.expect(!h.checker.fieldLiveAtExit(.branch_end, then_key, p, "a"));
    try std.testing.expect(h.checker.fieldLiveAtExit(.branch_end, else_key, p, "a"));
    try std.testing.expect(h.checker.fieldDeadAtExit(.block_end, end_key, p, "a"));
    try std.testing.expect(!h.checker.fieldDeadAtExit(.branch_end, else_key, p, "a"));
    // `b` was never moved, so there is no field record: missing => leak.
    try std.testing.expect(!h.checker.fieldLiveAtExit(.branch_end, else_key, p, "b"));
    try std.testing.expect(!h.checker.fieldDeadAtExit(.block_end, end_key, p, "b"));
    // Whole-binding `liveAtExit` is true on the keeping path (no field is
    // dead there) and false after the merge (any dead field path folds in).
    try std.testing.expect(h.checker.liveAtExit(.branch_end, else_key, p));
    try std.testing.expect(!h.checker.liveAtExit(.block_end, end_key, p));
}

test "branch ends record liveness before the merge" {
    // Plan D Task 2 at whole-binding granularity (the test above is the
    // field form). A var moved on the then-branch only: that branch end is
    // dead, the else-branch end is live, and the function end after the
    // merge is dead. Both branches are blocks, so both keys are the block's
    // statement slice, which is what codegen asks with.
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    if c > 0 {
        \\        take(v)
        \\    } else {
        \\        i = i + 1
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const if_expr = h.firstIf("f");
    const then_body = if_expr.kind.if_expr.then_body;
    const else_body = if_expr.kind.if_expr.else_body.?;
    try std.testing.expect(then_body.kind == .block and else_body.kind == .block);
    const then_key = Checker.branchKeyOf(then_body);
    const else_key = Checker.branchKeyOf(else_body);
    try std.testing.expect(then_key != else_key);
    try std.testing.expect(!h.checker.liveAtExit(.branch_end, then_key, v));
    try std.testing.expect(h.checker.liveAtExit(.branch_end, else_key, v));
    try std.testing.expect(!h.checker.liveAtExit(.block_end, h.fnBodyKey("f"), v));
}

test "a jump records liveness at the jump" {
    // Plan D Task 2: a LOOP-LOCAL var moved and revived before a `continue`
    // holds a value at the jump. `loop_moved` poisons only vars declared
    // outside the while (the after_loop tests above), so this record stays
    // live and codegen releases `v` at the `continue`.
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var i = 0
        \\    while i < n {
        \\        i = i + 1
        \\        var owned v: String = "a"
        \\        take(v)
        \\        v = "b"
        \\        if i > 0 {
        \\            continue
        \\        }
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    try std.testing.expect(h.checker.liveAtExit(.jump, h.firstJump("f"), v));
}

test "a jump taken while a loop-local is moved records it dead" {
    // The converse of the test above: the `continue` sits between the move
    // and the revival, so releasing `v` there would free a buffer `take`
    // already owns.
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var i = 0
        \\    while i < n {
        \\        i = i + 1
        \\        var owned v: String = "a"
        \\        take(v)
        \\        if i > 0 {
        \\            continue
        \\        }
        \\        v = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    try std.testing.expect(!h.checker.liveAtExit(.jump, h.firstJump("f"), v));
}

test "a record reassigned whole after a move is live at scope end" {
    // Plan D Task 5. One harness per function, so `binding("b")` cannot
    // pick the other function's `b`.
    var hf: LiveHarness = try .init(
        \\pub struct Box { owned s: String }
        \\pub fn take(owned b: Box);
        \\pub fn f() {
        \\    var owned b = Box { s: "one" }
        \\    take(b)
        \\    b = Box { s: "two" }
        \\}
    );
    defer hf.deinit();
    try std.testing.expect(hf.checker.recordLiveAtExit(.block_end, hf.fnBodyKey("f"), hf.binding("b")));

    // A field moved out AFTER the revival leaves a dead field path, so the
    // record is not released whole; the partial path handles it instead.
    var hg: LiveHarness = try .init(
        \\pub struct Box { owned s: String }
        \\pub fn take(owned b: Box);
        \\pub fn g() {
        \\    var owned b = Box { s: "one" }
        \\    take(b)
        \\    b = Box { s: "two" }
        \\    let owned moved: String = b.s
        \\}
    );
    defer hg.deinit();
    try std.testing.expect(!hg.checker.recordLiveAtExit(.block_end, hg.fnBodyKey("g"), hg.binding("b")));
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
    // The witness has now moved TWICE, and the reason is recorded because the
    // clause under test is not what keeps changing. It was `var owned`, which
    // R18 refuses at the `let` so no loan is created; then `var copy`, which
    // R12's binding clause now refuses because `Buffer` owns a `[Byte]` and
    // copying its header would make two owners of one buffer. `var arc` is the
    // third duplicable spelling and still reaches the loan branch, so the
    // clause keeps a live case. The other two spellings are pinned by the R18
    // and R12 tests respectively, so all three halves stay covered.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let owned other = Buffer { data: [], len: 0 }
        \\    var arc e = &mut buf
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
        \\t.cell:12:41: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
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
        \\t.cell:5:31: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\t.cell:6:31: error: cannot store source in owned field 'name': moving a place into an aggregate is not implemented
        \\t.cell:6:31: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
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
        \\t.cell:4:31: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\t.cell:5:31: error: cannot store a borrow of 'source' in owned field 'name': a borrow does not transfer ownership
        \\t.cell:5:31: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\t.cell:6:31: error: cannot store the borrow returned by 'inspect' in owned field 'name': a borrow does not transfer ownership
        \\t.cell:6:31: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
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
        \\t.cell:11:33: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\t.cell:12:34: error: cannot store inner in owned field 'inner': moving a place into an aggregate is not implemented
        \\t.cell:12:34: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\t.cell:13:33: error: cannot store source in owned field 'name': moving a place into an aggregate is not implemented
        \\t.cell:13:33: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
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
        \\t.cell:5:36: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\t.cell:6:32: error: cannot store a value of unresolved resource shape in owned field 'next': the destination field's resource shape cannot be resolved
        \\t.cell:6:32: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\
    );
}

// ── moved_paths: the field-level record codegen's partial drop reads ─────

/// Borrow-check `src` and hand back the checker, so a test can query the
/// permanent move records the way codegen does after `checkModule`.
fn checkedFor(gpa: std.mem.Allocator, src: []const u8) !Checker {
    var lex = lexer.Lexer.init(src, "t.cell");
    const tokens = try lex.tokenizeAll(gpa);
    var p = parser.Parser.init(gpa, tokens.items, "t.cell");
    const module = try gpa.create(ast.Module);
    module.* = try p.parseModule();
    var checker: Checker = .init(gpa, "t.cell", null);
    errdefer checker.deinit();
    try checker.checkModule(module);
    return checker;
}

/// The id borrowck gave the (single) binding named `name`, found through the
/// same permanent name table codegen uses to cross-check its numbering.
fn idNamed(checker: *const Checker, name: []const u8) !u32 {
    var found: ?u32 = null;
    var it = checker.names.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.value_ptr.*, name)) {
            if (found != null) return error.AmbiguousName;
            found = kv.key_ptr.*;
        }
    }
    return found orelse error.NoSuchBinding;
}

const partial_move_src =
    \\pub struct Pair {
    \\    owned a: String
    \\    owned b: String
    \\}
    \\pub fn f() {
    \\  let owned p: Pair = Pair { a: "x", b: "y" }
    \\  let owned m: String = p.a
    \\}
;

test "moved_paths: a field move is recorded as that field, not as the whole binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var checker = try checkedFor(arena.allocator(), partial_move_src);
    defer checker.deinit();
    try std.testing.expect(!checker.hasErrors());
    const p = try idNamed(&checker, "p");
    // The binding-level answer is unchanged, which is what every existing
    // caller of `wasMoved` still relies on.
    try std.testing.expect(checker.wasMoved(p));
    try std.testing.expect(!checker.wasWhollyMoved(p));
    try std.testing.expect(checker.fieldWasMoved(p, "a"));
    try std.testing.expect(!checker.fieldWasMoved(p, "b"));
}

test "moved_paths: a whole-binding move is wholly moved and reports no field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var checker = try checkedFor(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f() {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\  let owned q: Pair = p
        \\}
    );
    defer checker.deinit();
    const p = try idNamed(&checker, "p");
    try std.testing.expect(checker.wasWhollyMoved(p));
    // `fieldWasMoved` deliberately does not report a whole move; callers
    // check `wasWhollyMoved` first.
    try std.testing.expect(!checker.fieldWasMoved(p, "a"));
    try std.testing.expect(!checker.fieldWasMoved(p, "b"));
    const q = try idNamed(&checker, "q");
    try std.testing.expect(!checker.wasMoved(q));
}

test "moved_paths: a nested field path counts against its top-level field only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var checker = try checkedFor(arena.allocator(),
        \\pub struct Inner {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub struct Outer {
        \\    owned inner: Inner
        \\    owned tag: String
        \\}
        \\pub fn f() {
        \\  let owned p: Outer = Outer { inner: Inner { a: "x", b: "y" }, tag: "t" }
        \\  let owned m: String = p.inner.a
        \\}
    );
    defer checker.deinit();
    const p = try idNamed(&checker, "p");
    try std.testing.expect(!checker.wasWhollyMoved(p));
    try std.testing.expect(checker.fieldWasMoved(p, "inner"));
    try std.testing.expect(!checker.fieldWasMovedWhole(p, "inner"));
    try std.testing.expect(checker.fieldWasMovedWhole(p, "inner.a"));
    try std.testing.expect(!checker.fieldWasMovedWhole(p, "inner.b"));
    try std.testing.expect(checker.fieldWasMoved(p, "inner.a"));
    try std.testing.expect(!checker.fieldWasMoved(p, "inner.b"));
    try std.testing.expect(!checker.fieldWasMoved(p, "tag"));
    try std.testing.expect(!checker.fieldWasMovedWhole(p, "tag"));
    // A prefix that is not a whole path segment must not match: `in` is not
    // `inner`.
    try std.testing.expect(!checker.fieldWasMoved(p, "in"));
}

test "moved_paths: a partial move is still ACCEPTED, with no diagnostic" {
    // The fix lives entirely in what borrowck records, never in what it
    // refuses: reading the rest of a partly moved record stays legal.
    try expectAccepted(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn view(shared s: String) -> Int;
        \\pub fn f() -> Int {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\  let owned m: String = p.a
        \\  return view(shared p.b)
        \\}
    );
}

test "moved_paths: a field revived after it was moved is no longer fieldWasMoved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var checker = try checkedFor(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\  var owned p: Pair = Pair { a: "x", b: "y" }
        \\  take(owned p.a)
        \\  p.a = "c"
        \\}
    );
    defer checker.deinit();
    try std.testing.expect(!checker.hasErrors());
    const p = try idNamed(&checker, "p");
    try std.testing.expect(checker.wasMoved(p));
    try std.testing.expect(!checker.wasWhollyMoved(p));
    try std.testing.expect(!checker.fieldWasMoved(p, "a"));
    try std.testing.expect(!checker.fieldWasMovedWhole(p, "a"));
    try std.testing.expect(!checker.fieldWasMoved(p, "b"));
}

test "moved_paths: a field moved and never revived stays fieldWasMoved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var checker = try checkedFor(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\  take(owned p.a)
        \\}
    );
    defer checker.deinit();
    try std.testing.expect(!checker.hasErrors());
    const p = try idNamed(&checker, "p");
    try std.testing.expect(checker.fieldWasMoved(p, "a"));
    try std.testing.expect(checker.fieldWasMovedWhole(p, "a"));
    try std.testing.expect(!checker.fieldWasMoved(p, "b"));
}

test "moved_paths: reviving one field does not clear a moved sibling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var checker = try checkedFor(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\  var owned p: Pair = Pair { a: "x", b: "y" }
        \\  take(owned p.a)
        \\  take(owned p.b)
        \\  p.a = "c"
        \\}
    );
    defer checker.deinit();
    try std.testing.expect(!checker.hasErrors());
    const p = try idNamed(&checker, "p");
    try std.testing.expect(!checker.fieldWasMoved(p, "a"));
    try std.testing.expect(checker.fieldWasMoved(p, "b"));
    try std.testing.expect(!checker.wasWhollyMoved(p));
}

test "Some reads its operand and a wrap-pattern binding is a copy" {
    try expectAccepted(
        \\pub fn view(copy n: Int) -> Int;
        \\pub fn f(copy n: Int) -> Int {
        \\    let o: Int? = Some(n)
        \\    let m = view(n)
        \\    let copy a = match o { Some(x) => x + m, None => m }
        \\    return a
        \\}
    );
    try expectRejectedWith(
        \\pub fn f(copy o: Int?) -> Int {
        \\    let copy a = match o {
        \\        Some(x) => { x = 1 x },
        \\        None => 0,
        \\    }
        \\    return a
        \\}
    , "cannot assign to immutable binding 'x'");
    try expectAccepted(
        \\pub fn f(copy o: Int?) -> Int {
        \\    return match o { Some(x) => x, None => 0 }
        \\}
    );
}
