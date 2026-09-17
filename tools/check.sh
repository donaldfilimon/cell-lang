#!/bin/sh
# The gate for cell-lang. Its exit code is the verdict.
#
# WHY THIS EXISTS. `examples/README.md` used to say, in as many words, "There
# is no gate script, because tools/ is not part of this change", and then
# printed four shell loops for a human to paste. Those loops were retyped by
# hand more than a dozen times in a single session, and every retype is a
# chance to run a subtly different check and believe a different answer. The
# loops are the same; the difference is that they now live somewhere.
#
# WHAT IT CHECKS, and why each one earns its place:
#
#   1. build            nothing else means anything if this fails
#   2. tests            with the count printed, because AGENTS.md asks for the
#                       count rather than a bare green
#   3. corpus           the four contracts in examples/README.md. A green
#                       `zig build test` proves nothing about the LANGUAGE:
#                       it does not run a single example.
#   4. agreement        every example must get the SAME verdict from the LLVM
#                       and MLIR backends. This is the check that caught MLIR
#                       vacuously ACCEPTING a program LLVM refused, because it
#                       renders struct types at each use and so never examined
#                       a declared-but-unused one. Neither backend alone could
#                       have found that.
#   5. mlir lowering    every example whose MLIR emit SUCCEEDS must actually
#                       lower. Stage 4 compares VERDICTS, accept or refuse, and
#                       a verdict says nothing about whether the accepted text
#                       is well formed. examples/borrows.cell emitted a module
#                       that declared `@cell_look(%llvm.ptr)` and then called it
#                       with an `!llvm.struct<(i64)>`, so mlir-opt refused it
#                       outright, and this gate was green the whole time
#                       because stage 6 runs only three programs.
#   6. execution        emitted code is compiled, linked against the real
#                       runtime, RUN, and its answer checked. Every backend
#                       defect found in this repo that mattered was invisible
#                       in the IR and visible only here.
#   7. leaks            docs/OWNERSHIP.md R11's "Still broken" table disclosed
#                       six `arc` retain/release gaps and MEASURED five of
#                       them with `leaks`, in prose that lived nowhere as a
#                       file: nobody could re-run a single one of those
#                       numbers, or tell whether a change moved them.
#                       examples/leaks/*.cell isolates each measurable gap in
#                       its own program (six fixtures since 2026-09-15: the
#                       value-position block residual joined the five, and
#                       FIVE of the six are closed and pinned at 0). THESE FIXTURES ASSERT LEAKS THAT
#                       CURRENTLY EXIST, ON PURPOSE: that is the entire value.
#                       A later change that closes one of R11's gaps makes a
#                       pinned number here go DOWN, which is visible instead
#                       of silent; a change that makes one WORSE, or opens a
#                       new one, makes a number go UP or a clean fixture start
#                       leaking, which fails the gate instead of shipping
#                       quietly. DO NOT "fix" a failing fixture by loosening
#                       its expected count. A dropped count means a gap
#                       closed: update the constant, cite the new commit, and
#                       update docs/OWNERSHIP.md's row. A risen count, or a
#                       new leak in a program that used to be clean, means
#                       codegen regressed. Either way the fix belongs in
#                       src/, never in the pinned number.
#   8. backend answers  every example with a runnable `main`, through every
#                       backend that emits it, compared on its OUTPUT. Stage 4
#                       compares VERDICTS, and verdict agreement is not answer
#                       agreement: three backends can accept one program and
#                       compute three different things, and the gate said
#                       "llvm and mlir agree on every example" while the LLVM
#                       backend discarded every write through an `exclusive`
#                       borrow and printed 737 where the other two printed 142.
#                       Stage 6 could not have caught it either, because it
#                       runs a fixed list of four programs. This stage needs no
#                       list, so an example is covered the day it lands, and an
#                       example may declare `// EXPECT-OUTPUT:` to pin the
#                       answer itself, since three backends agreeing is not the
#                       same as three backends being right.
#                       AND IT STILL ONLY SEES THE SHAPES THE CORPUS CONTAINS.
#                       This stage was green over three further LLVM defects at
#                       once, because no example BOUND a borrow to a name
#                       before calling through it: a let-bound borrow took a
#                       copy, a borrow consumed by value handed over pointer
#                       bits, and `exclusive String` was classified by value
#                       while codegen passed a pointer. So the compiler fix for
#                       a silent class of defect is never the whole fix: the
#                       corpus has to carry the shape, or the next regression
#                       is silent again. examples/write_through_named.cell is
#                       that half for these three, and
#                       examples/let_binding_modes.cell is that half for the
#                       five in codegen.zig's `letType`.
#                       A SHAPE THIS STAGE STILL CANNOT CARRY, recorded so it
#                       is a known hole rather than a silence. The `let`
#                       family's fix covers OWNING types too: `let exclusive e
#                       = <a String or [T] place>` used to emit a shallow copy
#                       of the owning header, which is a double free rather
#                       than a wrong number. There is no corpus entry for it,
#                       because this stage runs every backend that EMITS a
#                       program and the MLIR backend emits this one wrongly:
#                       measured, it declares both `exclusive String` and
#                       `shared String` as `!llvm.struct<(ptr, i64)>`, passing
#                       a 16-byte view by value where the C ABI and
#                       runtime/cell_rt.h section 7 say `cell_string_t *`, and
#                       the linked program dies at exit 134. That is the
#                       unfixed twin of the `abi.classifyParam` defect 1fffcf8
#                       fixed for the LLVM backend, it predates the `letType`
#                       change (identical emission at ea36e3d), and it lives in
#                       src/cell/mlirmit.zig. Adding the example before that is
#                       fixed would mean either a red gate or teaching this
#                       stage to look away from a real defect, and stage 7's
#                       header already says which of those is allowed. The
#                       coverage lives meanwhile in codegen.zig's test "an
#                       exclusive String let is not a double free, run under
#                       AddressSanitizer", which compiles and RUNS the shape.
#   9. sanitizers       the same programs, rebuilt with -fsanitize=address and
#                       run, with an ASan REPORT failing the gate. Eight
#                       use-after-frees were found in this repository in one
#                       evening and this gate caught none of them: every one
#                       passed `cell check`, compiled at -Wall -Wextra -Werror,
#                       ran to completion and printed a plausible answer, so
#                       stages 6 and 8 saw nothing wrong. Read this stage as a
#                       claim about the CORPUS rather than the compiler: at
#                       `99d2971^` every runnable example was measured
#                       ASan-clean while a real heap-use-after-free was live,
#                       because no example returned an `arc` field. That is
#                       what examples/arc_return_field.cell is for.
#  10. signatures     the C backend's DECLARED SIGNATURES against the other
#                       two, compared at the ABI level rather than the textual
#                       one, because runtime/cell_rt.h section 7 is the
#                       contract and the C backend is its reference
#                       implementation. Stage 4 compares LLVM against MLIR and
#                       NOTHING ELSE, so it is blind to both being wrong
#                       together and to either disagreeing with C, and it was:
#                       `pub fn f() -> arc String` declares
#                       `cell_arc_t cell_f(void)` in C, which clang lowers to
#                       `sret(%struct.cell_arc)`, a 24-byte {ptr,ptr,ptr}, and
#                       both other backends declare `sret(%cell_string)`, a
#                       24-byte {ptr,i64,i64}. Same arity, same sret-ness, same
#                       SIZE, different TYPE: a C host linked against either IR
#                       backend hands the callee a buffer it fills with the
#                       wrong struct. Every stage above was green on it, and
#                       stage 8 could not have caught it either, because the
#                       program has no `main` and prints nothing.
#  11. rule lists       tools/check-rule-lists.sh: every document that lists
#                       the rules borrowck.zig enforces must mention every
#                       rule its header names. The list was found stale in
#                       SIX places in one session on 2026-09-08 and two of
#                       them re-drifted within the hour; the script existed
#                       from that day but was never run by this gate, and on
#                       2026-09-15 it was red again (AGENTS.md and CLAUDE.md
#                       had missed R7's consumption clause) with nothing
#                       saying so. Understating what the checker enforces
#                       invites re-implementing a rule that already exists.
#                       Appended as the last stage so the ten cross-references
#                       above keep their numbers.
#  12. cli build/run    `cell run` and `cell build` (added 2026-09-16, closing
#                       the goal's opening gap 5: "no .cell to executable
#                       path"). Stage 6 is the oracle; this proves the CLI
#                       reproduces its recipe from the runtime the binary
#                       embeds, forwards the program's exit status, refuses
#                       the textual targets and a second source file, writes
#                       nothing for a rejected program, and leaves no staging
#                       directory behind. Since the same night, .c positionals
#                       are hand-written hosts handed to cc in run_c_host's
#                       order, so arc (13) and owned_string (44) run here too.
#  13. prelude sigs     every prototype the C backend emits for
#                       stdlib/prelude.cell appears verbatim in
#                       runtime/cell_rt.h. The prelude's own comments checked
#                       this by hand ("Emits ... / Runtime ...") and were
#                       found inverted once (2026-09-07); a program that
#                       calls a prelude function links only while this holds.
#  14. cli test         `cell test tests/` passes; a copy with a program
#                       that assert(false)s fails with exit 1 and names it;
#                       an empty directory is exit 2, never green.
#  15. grok bots        tools/check-grok-bots.sh: every project-scoped Grok
#                       bot file under .grok/{agents,personas,skills,rules}
#                       must name -Dswift=false, tools/check.sh,
#                       --test-filter, refAllDecls, and worktree, and the
#                       implementer overlays must exist. Bundled
#                       implementer still says fmt/clippy;
#                       this is the check that the overlay did not drift
#                       back to that bar. Needs no cell binary.
#
# TRAPS THIS SCRIPT IS WRITTEN AGAINST, each one having actually bitten:
#
#   * `cmd | tail` reports TAIL's exit code, not cmd's. Never pipe a command
#     whose status you are about to test.
#   * a failed `zig build` leaves the PREVIOUS binary in zig-out/bin/cell, so
#     running it after a failed build tests code that no longer exists.
#   * `zig cc -x ir` does not work ("language not recognized: ir"). Use cc.
#   * mlir-opt, mlir-translate and llc are NOT on PATH; they live in the
#     Homebrew LLVM keg. When they are absent the MLIR checks SKIP loudly
#     rather than passing silently, because a check that quietly succeeds when
#     its subject is missing is worse than no check.
#   * `zig cc -fsanitize=address` does NOT link here, the same way `zig cc -x ir`
#     does not work. Stage 9 uses `cc`, and skips loudly when even that cannot
#     link a sanitized binary.
#   * macOS's `leaks` tool is not always installed (CI, a minimal machine), and
#     the leaks stage below SKIPS loudly rather than passing silently when it
#     is absent, for the same reason as the MLIR tools above.
#   * `leaks -atExit` UNDER-counts by exactly ONE ITERATION'S ALLOCATIONS for
#     a program whose most recent allocation is still referenced by a stale CPU
#     register or stack slot at exit. A real false negative, not this script's
#     bug. Note the unit: it is one iteration, which is THREE allocations in
#     these fixtures, not the number three and not "one instance". A fixture
#     that allocates a different amount per iteration will be off by that
#     amount instead.
#
#     SINCE 2026-09-15 THE STAGE NO LONGER SEES THIS ARTIFACT, and it no longer
#     trusts `leaks` alone. Every fixture is linked behind
#     examples/leaks/leak_host.c (the real `main`, which runs the program and
#     then overwrites the stack before exit; the emitted C is compiled with
#     `-Dmain=cell_program_main` as its own object so the rename cannot touch
#     the host) and built with examples/leaks/malloc_counter.{h,c} injected
#     (`-include`, one shared definition across every translation unit). Each
#     fixture therefore yields TWO numbers, the `leaks` count and the counter's
#     LIVE, and the stage requires BOTH to equal the pin. The history below is
#     kept because it is the reason those two files exist and the reason a
#     one-witness stage must never come back.
#
#     PROVEN 2026-09-08, by two measurements rather than by argument, and the
#     first one falsified the competing explanation that used to live in
#     examples/leaks/block_scoped_local.cell (that the last iteration's box was
#     released by a function-scoped drop):
#
#       1. An interposed malloc counter, via a `-include` header redefining
#          malloc/free around the emitted C and runtime, reports
#          ALLOC=3000 FREE=0 LIVE=3000 for param_never_released,
#          struct_arc_field and block_scoped_local, and ALLOC=3003 FREE=3
#          LIVE=3000 for reassigned_var. Two of those three emit ZERO release
#          calls of any kind, so nothing is released and no drop can explain a
#          count that is short.
#       2. Re-linking the same emitted C behind a stack-clobbering epilogue (a
#          recursive function memset-ing a 4 KB volatile buffer, called after
#          the program) makes `leaks` report the true 3000.
#
#     SO ALL FOUR FIXTURES LEAK EXACTLY 3000 UNITS. The constants below differ
#     only in what `leaks` can SEE, and a reader must not conclude that
#     struct_arc_field leaks less than reassigned_var. reassigned_var reads the
#     full 3000 only because it allocates 3003 and frees the most recent 3,
#     which is precisely the group the other three still hold a stale reference
#     to.
#
#     THE HAZARD THIS CREATED, and it is the reason all of the above is written
#     down: the artifact is STACK-LAYOUT-SENSITIVE. Before the host existed, a
#     codegen change that added or removed a local in the emitted C could flip
#     a constant 2997 -> 3000 or 3000 -> 2997 without changing what the program
#     leaks, and the stage would have reported a RISE ("regression") or a DROP
#     ("good, re-pin"); the second is the honesty hazard, because someone
#     re-pins believing a leak closed. The stack clobber removes the artifact
#     and the counter is the witness that it is gone: if the two numbers ever
#     disagree, the stage fails and names which one moved. RULE, unchanged in
#     spirit: never re-pin on one witness. A `leaks` reading that the counter
#     does not reproduce is a measurement problem, not a closed leak.
#
#     The 2997s were re-measured 8 times each and were IDENTICAL every time,
#     so they were stable-but-undercounting numbers, not flaky ones. The 3000s
#     pinned below were measured 3 times each through the host and counter
#     (leaks and LIVE agreed on every run; the two controls, row 3 at 0 and
#     row 5 at 3000 with ALLOC=3003 FREE=3, held). If a future re-measurement
#     is not reproducible run to run, say so in the report rather than pinning
#     whichever number came up first.

set -u

cd "$(dirname "$0")/.." || exit 2

LLVM_BIN=${LLVM_BIN:-/opt/homebrew/opt/llvm/bin}
ZIG=${ZIG:-zig}
CELL=${CELL:-./zig-out/bin/cell}
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

# ---- docs/OWNERSHIP.md R11 disclosed-leak constants, pinned by commit -----
# Each number is the count this fixture produced when it was measured, over
# 1000 loop iterations, on THIS commit, read from BOTH witnesses the stage
# uses: the `leaks -atExit` count of the binary linked behind
# examples/leaks/leak_host.c, and the LIVE figure from
# examples/leaks/malloc_counter.c injected into the same binary. The stage
# fails unless both equal the pin. Not the number quoted in
# docs/OWNERSHIP.md's prose (that prose predates these fixtures and used a
# different string literal in one case, which changes byte totals but not
# leak counts): re-measured fresh so the constant and the fixture that
# produces it live in the same place.
#
# HISTORY, because the numbers moved once without any leak closing: from
# 2026-09-08 (35003ca) to 2026-09-15 three of these were pinned at 2997,
# measured at 78eadb22 with `leaks` alone, because the tool's conservative
# scan could still see the last iteration's three boxes through a stale stack
# slot. The header trap note on this stage carries the proof. Adding the host
# and the counter made the true 3000 visible and confirmable, and the pins
# moved 2997 -> 3000 on 2026-09-15 with NO change under src/: the codegen
# measured is still 178599028cf2aabf3e815947cae0f9926b601c81's, which is why
# that is the commit cited rather than the one that changed the method.
#
# When one of these changes because a gap in docs/OWNERSHIP.md R11 closed:
# update the constant AND that document's row, and cite the new commit here.
#
# 2026-09-15, second move: the block-scoped release that closed row 4 is a
# codegen change, so the tree the surviving 3000s describe is no longer
# 1785990's. They were re-measured (3 runs, both witnesses) on the tree that
# the closing commit changed, whose parent is 82f222e; a commit cannot cite
# its own hash, so the hash below is that parent and the codegen it names is
# "82f222e plus the codegen commits that follow it the same day" (4cf7852,
# block-scoped release; 973c23c, block-tail typing and inference, which added
# the sixth fixture). The gate re-verified every pin on each of those trees.
LEAKS_MEASURED_AT=82f222e903afdd01cdc9a384a000ffc2a8df70cc

# R11 row 1: a Cell body never released its own `arc` parameter.
# CLOSED 2026-09-16: `emitFn` admits every parameter to the drop pass, which
# still filters on an `owned` or `arc` annotation and on `wasMoved`, so the
# callee releases what runtime/cell_rt.h section 7 already said it owns, and
# `returnedArcNeedsRetain` lost its parameter exemption (a returned parameter
# is now retained, then released at scope end, 1 -> 2 -> 1). Measured 3000 ->
# 0 on both witnesses through this stage's host and counter. The `owned`
# half closed with it, and R10's refusal of an owned place moved into an
# `arc` box stays: releasing a box and boxing a place are separate jobs.
# Pinned at 0 because it is closed: any nonzero reading re-opens row 1.
LEAK_PARAM_NEVER_RELEASED=0
# R11 row 2: a struct holding an `arc` field was never dropped.
# CLOSED 2026-09-15 (late night): every struct with an `owned` or `arc` field
# whose lowered type needs a drop gets a generated
# `static inline __attribute__((unused)) void cell_drop_<Name>(cell_<Name> *r)`
# after the typedefs (prototypes first, then definitions, so nesting order does
# not matter), and a droppable local of that type is released through it by
# `pendingDrops`. The predicate is `needsDrop`, kept separate from
# `hasDropCall` because that one also keys the owning-header guard that makes
# records COPY into a slot. Two borrowck refusals landed first in c314a0e as
# preconditions: a `copy` binding or parameter of a resource-bearing type
# (three accepted routes would each have become a double free the day this
# glue landed), and an `owned` resource-bearing place in a list element (a
# MEASURED live heap-use-after-free for `String`, independent of this row).
# The gate went red on the old pin first ("both witnesses agree ... 0"), then
# the constant moved. A struct with one field moved out was still never
# dropped then (borrowck marked the whole binding moved), which leaked rather
# than double-freed; that residual closed 2026-09-16 (LEAK_PARTIAL_MOVE_FIELD
# below), and the field-store pre-drop is the one still stated.
# Stays pinned at 0: any nonzero reading here re-opens row 2.
LEAK_STRUCT_ARC_FIELD=0
# R11 row 3: an `arc` value unboxed for a `shared` parameter without ever
# being bound (`inspect(shared fresh())`) drops its handle on the floor.
# This is the one row whose count matches docs/OWNERSHIP.md's own prose
# exactly (2998 leaks / 63968 bytes), because that measurement used the same
# string length this fixture does.
# CLOSED 2026-09-07 by 460b9a3: the temporary is now hoisted into the statement
# expression and released, so this row measures 0 rather than 2998. It stays
# in the gate BECAUSE it is closed: pinned at 0, any nonzero reading here is a
# regression that re-opens R11 row 3.
LEAK_UNBOUND_SHARED_TEMP=0
# R11 row 4: an `arc` local declared inside a block used to be never released
# (function-scoped release, block-scoped binding); the "block form" row.
# CLOSED 2026-09-15: `emitStmts` is now a block-scope drop point and `break`/
# `continue` drop the loop's scopes, so this fixture releases every
# iteration's box and measures 0 on both witnesses (it was 3000 on both the
# same evening, through the same host and counter). It stays in the gate
# BECAUSE it is closed: pinned at 0, any nonzero reading here re-opens row 4.
# The codegen tests that pin the drop start at "an arc local declared in a
# while body is released at the end of every iteration" in src/cell/codegen.zig.
LEAK_BLOCK_SCOPED_LOCAL=0
# R11 row 5: reassigning an `arc` `var` leaked the previous box.
# CLOSED 2026-09-15 (night): `emitAssign` evaluates the new value into a
# temporary, drops the old box, then stores, for a whole-binding target
# naming a droppable `arc` local. (`owned` was excluded then because `[s]`
# copied the header without marking `s` moved; see LEAK_REASSIGNED_OWNED_VAR
# below for how that closed.) A droppable var declared without an initializer is now
# zero-initialized so the first pre-drop is a no-op. The gate went red on
# the old pin first ("both witnesses agree ... 0"), then the constant moved.
# Stays pinned at 0: any nonzero reading here re-opens row 5.
LEAK_REASSIGNED_VAR=0
# Row 5's `owned` twin, not an R11 row (R11 is about `arc`): reassigning a
# never-moved `owned` String or list var leaked the old value on every store.
# Measured 2000 on both witnesses before the change (`leaks` 2000, counter
# ALLOC=4000 FREE=2000 LIVE=2000), through this same host and counter.
# CLOSED 2026-09-16 in two steps: `emitAssign`'s pre-drop covers a droppable
# `owned` String or list local (the `[s]` header copy that excluded it is
# refused since c314a0e), first when borrowck's `wasMoved` said the binding
# was never moved (2d95a51), then per STORE from borrowck's `assign_liveness`,
# so a var moved only after its reassignment is released too. The fixture's
# two later-move helpers make the readings 4000 before either step, 2000 at
# 2d95a51, and 0 after (ALLOC=8000 FREE=8000 LIVE=0), ASan clean. A store
# whose target was already moved, or sits in a `while` body that moves it,
# gets no pre-drop (each guard measured as an ASan failure when removed), so
# R16's revival leak is unchanged and not measured here. Stays pinned at 0.
LEAK_REASSIGNED_OWNED_VAR=0
# The revival leak (OWNERSHIP.md R16): a var moved and then revived by a
# fresh assignment (R3a) was never released at scope end, because the drop
# admission read borrowck's permanent `wasMoved`. Measured 5000 on both
# witnesses before the change (`leaks` 5000, counter ALLOC=10000 FREE=5000
# LIVE=5000) at bb38f95, through this same host and counter.
# CLOSED 2026-09-16: borrowck records each visible binding's liveness at
# every block end and every `return` (`exit_liveness`, with a binding moved
# inside a `while` never live at an exit in or after it) and codegen
# releases a moved var only where that says live; after, `leaks` 0 and
# ALLOC=10000 FREE=10000 LIVE=0, ASan clean. Removing either loop guard was
# measured as an ASan double free (exit 134). Stays pinned at 0.
LEAK_REVIVED_VAR=0
# The residual the 2026-09-15 block-scoped release left behind, measurable
# only since the same day (typing a block by its tail made the program
# expressible): an `arc` local declared inside a VALUE-position block was not
# released at that block's exit. Measured 3000 on both witnesses on the tree
# that added it. Not an OWNERSHIP.md "Still broken" row number; the CLOSED
# paragraph under that table carries it.
# CLOSED 2026-09-15 (evening): `emitValueBlockDrops` releases a value block's
# own locals after its tail is lowered into the destination, skipping any
# local the tail can still reach, transitively through the block's own lets
# and assignments (a borrowed view is copied OUTSIDE the braces, and an
# alias of it names the local nowhere in the tail: 85570d6 missed that)
# and dropping the tail itself only in the one case the lowering cloned it
# (an `arc` local into an `arc` destination, which this fixture is). The
# gate went red on the old pin first ("both witnesses agree ... 0"), then
# the constant moved. Stays pinned at 0: any nonzero reading re-opens it.
LEAK_VALUE_BLOCK_LOCAL=0
# Partial-move residual: a record with one owning field moved out
# (`let owned moved = p.a`) was skipped whole at scope end, because the drop
# admission read borrowck's binding-level `wasMoved`, so the record's other
# owning field was released by nothing. Not an OWNERSHIP.md "Still broken"
# row number; the CLOSED paragraph under that table carries it. Measured 1000
# on both witnesses (`leaks` 1000, counter ALLOC=2000 FREE=1000 LIVE=1000)
# through this same host and counter on the tree before the change.
# CLOSED 2026-09-16: borrowck records each move with its field path and
# codegen releases exactly the unmoved owning fields
# (`emitPartialRecordDrop`); after, `leaks` 0 and ALLOC=2000 FREE=2000 LIVE=0.
# ASan clean on the straight-line, single-owning-field, conditional and
# read-after-partial-move shapes. Stays pinned at 0: any nonzero reading
# re-opens it. A CONDITIONAL partial move is `branch_field.cell`.
LEAK_PARTIAL_MOVE_FIELD=0
# R10 move-into-`arc` at its five IMPLEMENTED positions (`let arc` since
# f9441cb; a direct `return` from `-> arc T`, an assignment into a whole
# `var arc`, an argument to an `arc` parameter and a struct literal's `arc`
# field since 2026-09-16; the assignment case raised the counter figures
# below to ALLOC=24000 FREE=24000, the call case to ALLOC=30000 FREE=30000
# and the field case to ALLOC=36000 FREE=36000, each measured with the leaks
# host under ASan before it was pinned). Not an R11
# row and never a measured leak: both positions were refused until they were
# built. Pinned because the move is correct only while borrowck records the
# source as moved AND codegen boxes it and skips its drop; a drift on either
# side is a double free or a leak here. Measured 0 on both witnesses (`leaks`
# 0, ALLOC=12000 FREE=12000 LIVE=0) and ASan clean outside the gate before it
# was added. Stays pinned at 0.
LEAK_ARC_BOX_MOVE=0
# R16 residual 1: a var moved on one branch. Measured 501 before
# (2026-09-16); CLOSED the same day by branch-end releases, 501 -> 0.
LEAK_BRANCH_MOVE=0
# R16 residual 2: a loop-local revived before continue. Measured 1000
# before; CLOSED 2026-09-16 by jump releases, 1000 -> 0.
LEAK_LOOP_JUMP_REVIVAL=0
# R16 residual 3: a var revived inside a value-position block. Measured
# 1000 before; CLOSED 2026-09-16 by value-block-end releases, 1000 -> 0.
LEAK_VALUE_BLOCK_REVIVAL=0
# R16 residual 4: a record moved whole then reassigned whole. Measured
# 1000 before; CLOSED 2026-09-16 by record-revival admission, 1000 -> 0.
LEAK_REVIVED_RECORD=0
# R16 residual: a var moved inside a `while` it was declared outside of.
# Measured 1000 before (2026-09-16, ALLOC=2000 FREE=1000 LIVE=1000);
# CLOSED the same day by after_loop releases, 1000 -> 0.
LEAK_LOOP_CROSS=0
# R16 residual: a nested field whose sibling was moved. `p.inner.a` is
# moved, and `fieldWasMoved` used to skip the whole `inner` field, so
# `p.inner.b` leaked. Measured 1000 before (2026-09-16, ALLOC=3000
# FREE=2000 LIVE=1000); CLOSED the same day by recursing
# `emitPartialRecordDrop`, 1000 -> 0.
LEAK_PARTIAL_NESTED_FIELD=0
# R16 residual 1 at field granularity: a field moved on only one branch of
# an `if` leaked on the other (`p.a` skipped at scope end because the merge
# records it dead). Measured 1000 before (2026-09-16, ALLOC=4000 FREE=3000
# LIVE=1000); CLOSED the same day by branch-end field releases, 1000 -> 0.
LEAK_BRANCH_FIELD=0
# R16 residual: a field revived after it was moved (`take(p.a)` then
# `p.a = "c"`) leaked the new value because `moved_paths` was never
# retracted. Measured 1000 before (2026-09-16, ALLOC=3000 FREE=2000
# LIVE=1000); CLOSED the same day by R3a retracting the revived field
# path from `fieldWasMoved`, 1000 -> 0.
LEAK_FIELD_REVIVAL=0

# ---- stage 10 disclosed signature disagreements, pinned by defect ---------
# Each line is `<example key>:<function>:<leg>` naming a place where the C
# backend's declared ABI and another backend's DISAGREE TODAY, on purpose,
# because the defect is real, unfixed, and lives in a file this gate does not
# own. Same contract as the leak constants above and read the same way:
#
#   * a disagreement that is pinned here is reported as `(disclosed)` and does
#     not fail the gate;
#   * a disagreement that is NOT pinned here FAILS, which is the whole point;
#   * a pin whose function AGREES again, or which is no longer compared at
#     all, ALSO FAILS, so a closed gap cannot go unnoticed and a pin cannot
#     rot into a line nobody reads. When that happens the fix is to delete the
#     pin and cite the commit that closed it, never to keep it "just in case".
#
# DO NOT "fix" a failure here by adding a pin. A new disagreement is a new ABI
# defect; it belongs in src/ or, if it is genuinely disclosed elsewhere, in a
# pin that says WHERE it is disclosed. The former LLVM and MLIR
# `arc_string_return` pins were deleted when HIR began preserving return
# ownership and both backends explicitly refused that unsupported contract.
#
# The list is EMPTY. The last two pins, `primitives:cell_take_list:MLIR` and
# `primitives:cell_take_nested:MLIR`, were deleted when mlirmit.zig began
# placing every parameter and return by `abi.classifyParam`/`classifyReturn`
# (2026-09-17). Their comment gave the wrong reason: a `shared` list is a
# by-value view in cell_rt.h section 7, and clang's `ptr` is the INDIRECT
# copy of that 24-byte struct, not a borrow. MLIR now passes the copy's
# address, coerces 16-byte-or-smaller aggregates to `[n x i64]`/`iN`, and
# agrees with C.
SIG_DISCLOSED=''

fails=0
skips=0

fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
pass() { printf '  ok    %s\n' "$*"; }
skip() { printf '  SKIP  %s\n' "$*"; skips=$((skips + 1)); }

# The mlir-opt pipeline, read back out of the emitted file's own
# `// lower with:` comment. Stage 5 says in as many words that the pipeline is
# NOT written into this script because a second copy could drift from the
# backend, and then run_mlir hardcoded the same six flags sixty lines below it,
# so the script contradicted itself in one file about one pipeline. Both call
# sites now ask here. An absent line is an error rather than a fallback to a
# remembered default, for exactly the reason stage 5 gives.
mlir_pipeline() {
    sed -n 's|^// lower with: mlir-opt ||p' "$1" | head -1
}

accepted_examples() {
    for _example in examples/*.cell examples/pairing/*.cell examples/signatures/*.cell; do
        [ -f "$_example" ] && printf '%s\n' "$_example"
    done
}

artifact_tag() {
    printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

backend_emit_verdict() {
    _backend=$1; _source=$2; _output=$3; _diagnostic=$4
    if "$CELL" emit --target="$_backend" "$_source" > "$_output" 2> "$_diagnostic"; then
        BACKEND_STATUS=0
    else
        BACKEND_STATUS=$?
    fi
    if [ "$BACKEND_STATUS" -eq 0 ]; then
        BACKEND_VERDICT=accept
    elif [ "$BACKEND_STATUS" -eq 1 ] && grep -q 'cannot lower' "$_diagnostic"; then
        BACKEND_VERDICT=refuse
    else
        BACKEND_VERDICT=error
    fi
}

collect_root_test_count() {
    _count_log=$1
    if "$ZIG" test src/root.zig > "$_count_log" 2>&1; then
        _count_status=0
    else
        _count_status=$?
    fi
    if [ "$_count_status" -eq 0 ]; then
        printf '  ....  %s\n' "$(tail -1 "$_count_log")"
    else
        fail "zig test src/root.zig for test count (exit $_count_status)"
        sed -n '1,10p' "$_count_log"
    fi
}

mlir_to_llvm() {
    _mlir=$1; _pipeline=$2; _low=$3; _llvm=$4; _log_prefix=$5
    # Unquoted on purpose: the pipeline is a list of flags and must split.
    if ! "$LLVM_BIN/mlir-opt" "$_mlir" $_pipeline -o "$_low" 2>"${_log_prefix}.opt"; then
        MLIR_LOWER_FAILURE=opt
        return 1
    fi
    if ! "$LLVM_BIN/mlir-translate" --mlir-to-llvmir "$_low" -o "$_llvm" 2>"${_log_prefix}.translate"; then
        MLIR_LOWER_FAILURE=translate
        return 1
    fi
    MLIR_LOWER_FAILURE=none
    return 0
}

# Stage 10 may print "C only" only when both IR backends explicitly refused.
# A crash, unavailable MLIR tools, or accepted MLIR that failed later is a
# failure/incomplete comparison, never a refusal.
signature_coverage_verdict() {
    _llvm_verdict=$1; _mlir_verdict=$2; _mlir_post=$3
    SIG_C_ONLY=no
    SIG_COVERAGE_FAILURE=no
    if [ "$_llvm_verdict" = refuse ] && [ "$_mlir_verdict" = refuse ]; then
        SIG_C_ONLY=yes
    fi
    if [ "$_llvm_verdict" = error ] || [ "$_mlir_verdict" = error ]; then
        SIG_COVERAGE_FAILURE=yes
    elif [ "$_mlir_verdict" = accept ] && [ "$_mlir_post" != compared ]; then
        SIG_COVERAGE_FAILURE=yes
    fi
}

if [ "${CELL_GATE_LIBRARY_ONLY:-0}" = 1 ]; then
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------- 1. build --
printf '\n== build ==\n'
"$ZIG" build -Dswift=false > "$TMP/build.log" 2>&1
build_status=$?
if [ $build_status -ne 0 ]; then
    fail "zig build -Dswift=false (exit $build_status)"
    sed -n '1,20p' "$TMP/build.log"
    # Everything downstream would run against a stale binary, so stop here.
    printf '\nBUILD FAILED. zig-out/bin/cell is now STALE; nothing below was run.\n'
    exit 1
fi
pass "zig build -Dswift=false"

# ---------------------------------------------------------------- 2. tests --
printf '\n== tests ==\n'
"$ZIG" build test -Dswift=false > "$TMP/test.log" 2>&1
test_status=$?
if [ $test_status -ne 0 ]; then
    fail "zig build test -Dswift=false (exit $test_status)"
    grep "^error: '" "$TMP/test.log" | head -10
else
    pass "zig build test -Dswift=false"
fi

# The count, not just the colour. AGENTS.md: check the count before citing a
# green run. `zig build test` prints nothing on success, so ask root.zig.
collect_root_test_count "$TMP/count.log"

# --------------------------------------------------------------- 3. corpus --
# The four contracts declared in examples/README.md.
printf '\n== corpus ==\n'
corpus_before=$fails

for f in examples/*.cell; do
    if ! $CELL check "$f" > /dev/null 2>&1; then
        fail "$f must pass check"
    fi
done

for f in examples/future/*.cell; do
    if $CELL check "$f" > /dev/null 2>&1; then
        fail "$f must FAIL check (the parser grew: move it up and rewrite its header)"
    fi
done

for f in examples/rejected/*.cell; do
    want=$(grep -m1 '^// EXPECT:' "$f" | sed 's|^// EXPECT: ||')
    if $CELL check "$f" > /dev/null 2>&1; then got=currently-accepted; else got=currently-rejected; fi
    if [ "$want" != "$got" ]; then
        fail "$f declares $want but is $got"
    fi
done

for f in examples/pairing/*; do
    if ! $CELL check "$f" > /dev/null 2>&1; then
        fail "$f must pass check (stem pairing)"
    fi
done

# Against the corpus's OWN failures, not the global counter. Gating this on
# $fails meant an earlier stage failing printed NOTHING here: the loops above
# still ran and still passed, but the section went silent and read as skipped.
[ $fails -eq $corpus_before ] && pass "all four corpus contracts hold"

# ------------------------------------------------------------ 4. agreement --
# The two newer backends share an IR, so a disagreement means one of them is
# wrong. This is the check that caught MLIR accepting a program LLVM refused.
# THIS STAGE COMPARES LLVM AGAINST MLIR AND NOTHING ELSE, so it is blind to
# the two backends being wrong TOGETHER, and to either disagreeing with C.
# Measured 2026-09-08, a live instance rather than a hypothetical:
#
#     pub fn make() -> String;
#     pub fn f() -> arc String { return make() }
#
# C declares `cell_arc_t cell_f(void)`, returning by value. LLVM declares
# `cell_f(ptr sret(%cell_string) %sret)` and MLIR the same with an
# `llvm.sret` attribute: a different CALLING CONVENTION, not a different
# spelling. A C host linked against either would pass an argument the callee
# does not expect. All three accept, so no verdict splits; the two backends
# agree with each other, so this stage passes.
#
# The cause is upstream of the backends and neither can see it: `hir.Fn`
# carries `ret: Ty` with no ownership mode, so the `arc` is simply absent by
# the time either emitter reads it.
#
# THAT STAGE NOW EXISTS AND IT IS STAGE 10: it compares the C backend's
# DECLARED SIGNATURES against the other two, the way stage 8 compares printed
# answers, and it pins this exact case as a disclosed disagreement against
# examples/signatures/arc_string_return.cell. Still read a green line HERE as
# "llvm and mlir agree", never as "the backends agree"; stage 10 is the only
# line in this script that speaks for all three. This is the same lesson as
# stage 5's header (a verdict
# is not a lowering) and stage 8's (verdict agreement is not answer
# agreement), one level further out: AGREEMENT BETWEEN TWO PARTIES IS NOT
# CORRECTNESS WHEN A THIRD DEFINES THE CONTRACT, and here the third,
# runtime/cell_rt.h, is the one that does.
printf '\n== backend agreement ==\n'
disagreements=0
accepted_examples > "$TMP/accepted_examples"
while IFS= read -r f; do
    tag=$(artifact_tag "$f")
    backend_emit_verdict llvm "$f" "$TMP/agree_$tag.ll" "$TMP/agree_$tag.llvm.err"
    l=$BACKEND_VERDICT
    if [ "$l" = error ]; then
        fail "$f: llvm emit failed unexpectedly (exit $BACKEND_STATUS)"
        sed -n '1,4p' "$TMP/agree_$tag.llvm.err"
    fi
    backend_emit_verdict mlir "$f" "$TMP/agree_$tag.mlir" "$TMP/agree_$tag.mlir.err"
    m=$BACKEND_VERDICT
    if [ "$m" = error ]; then
        fail "$f: mlir emit failed unexpectedly (exit $BACKEND_STATUS)"
        sed -n '1,4p' "$TMP/agree_$tag.mlir.err"
    fi
    if [ "$l" != "$m" ]; then
        fail "$f: llvm=$l mlir=$m"
        disagreements=$((disagreements + 1))
    fi
done < "$TMP/accepted_examples"
[ $disagreements -eq 0 ] && pass "llvm and mlir agree on every example"

# --------------------------------------------------------- 5. mlir lowering --
# A VERDICT is not a lowering. Stage 4 asks each backend only whether it
# accepts a program; it never asks mlir-opt whether the accepted text means
# anything. examples/borrows.cell spent its whole life on the accepted side of
# that line while emitting a module mlir-opt refused, because stage 6 lowers
# three programs and borrows.cell is not one of them.
#
# The pipeline is NOT written out here. The emitter writes its own into every
# file it produces, as a `// lower with: mlir-opt ...` comment, so this stage
# reads it back from the file. A second copy in this script could drift from
# the backend, and then this stage would be pinning a pipeline nobody ships.
# When the line is absent the stage FAILS rather than falling back to a
# remembered default, for the same reason.
printf '\n== mlir lowering ==\n'
if [ ! -x "$LLVM_BIN/mlir-opt" ]; then
    skip "mlir lowering of every example (mlir-opt not found in $LLVM_BIN)"
else
    lower_before=$fails
    while IFS= read -r f; do
        n=$(artifact_tag "$f")
        # An emit REFUSAL is designed scalar-first behaviour and stage 4 already
        # pins it. A CRASH is not, so the two are told apart the way
        # .claude/skills/run-cell-lang/driver.sh tells them apart, and only what
        # emitted is lowered.
        backend_emit_verdict mlir "$f" "$TMP/low_$n.mlir" "$TMP/low_$n.emit"
        if [ "$BACKEND_VERDICT" = refuse ]; then
            continue
        elif [ "$BACKEND_VERDICT" = error ]; then
            fail "mlir emit $f failed unexpectedly (exit $BACKEND_STATUS)"
            sed -n '1,4p' "$TMP/low_$n.emit"
            continue
        fi
        pipeline=$(mlir_pipeline "$TMP/low_$n.mlir")
        if [ -z "$pipeline" ]; then
            fail "$f: emitted MLIR carries no '// lower with:' line to read the pipeline from"
            continue
        fi
        # Unquoted on purpose: $pipeline is a list of flags and must split.
        "$LLVM_BIN/mlir-opt" "$TMP/low_$n.mlir" $pipeline -o "$TMP/low_$n.out" \
            > /dev/null 2> "$TMP/low_$n.err" || {
            fail "mlir-opt $f"
            sed -n '1,4p' "$TMP/low_$n.err"
        }
    done < "$TMP/accepted_examples"
    [ $fails -eq $lower_before ] && pass "every emitted MLIR module lowers"
fi

# ------------------------------------------------------------- 6. execution --
# Emit, compile, link against the real runtime, RUN, check the answer.
printf '\n== execution ==\n'

cc -c -I runtime runtime/cell_rt.c -o "$TMP/rt.o" 2> "$TMP/rt.log"
if [ $? -ne 0 ]; then
    fail "compiling runtime/cell_rt.c"
    sed -n '1,10p' "$TMP/rt.log"
fi
printf 'extern void cell_main(void);\nint main(void){cell_main();return 0;}\n' > "$TMP/drv.c"

run_c() {
    ex=$1; want=$2
    $CELL emit "examples/$ex.cell" > "$TMP/$ex.c" 2>/dev/null || { fail "C emit $ex"; return; }
    cc -I runtime "$TMP/$ex.c" runtime/cell_rt.c -o "$TMP/${ex}_c" 2>/dev/null || { fail "C compile $ex"; return; }
    got=$("$TMP/${ex}_c")
    [ "$got" = "$want" ] && pass "C    $ex -> $got" || fail "C    $ex -> $got, want $want"
}

# Same as run_c, plus a hand-written C host for the example's bodyless
# declarations. examples/arc.cell needs one because its `observe` reads
# cell_arc_strong_count, which no Cell body can reach: without that the run
# would prove only that the program does not crash, not that the retains
# balance. The host file is a `.c`, so none of the `*.cell` loops above see it.
run_c_host() {
    ex=$1; want=$2; host=$3
    $CELL emit "examples/$ex.cell" > "$TMP/$ex.c" 2>/dev/null || { fail "C emit $ex"; return; }
    cc -I runtime "$TMP/$ex.c" "$host" runtime/cell_rt.c -o "$TMP/${ex}_c" 2>/dev/null \
        || { fail "C compile $ex"; return; }
    got=$("$TMP/${ex}_c")
    [ "$got" = "$want" ] && pass "C    $ex -> $got" || fail "C    $ex -> $got, want $want"
}

run_llvm() {
    ex=$1; want=$2
    $CELL emit --target=llvm "examples/$ex.cell" > "$TMP/$ex.ll" 2>/dev/null || { fail "llvm emit $ex"; return; }
    # cc, never `zig cc`: measured, `zig cc -x ir` fails outright.
    cc -Wno-override-module -x ir "$TMP/$ex.ll" -c -o "$TMP/$ex.o" 2>/dev/null || { fail "llvm compile $ex"; return; }
    cc "$TMP/$ex.o" "$TMP/rt.o" -o "$TMP/${ex}_l" 2>/dev/null || { fail "llvm link $ex"; return; }
    got=$("$TMP/${ex}_l")
    [ "$got" = "$want" ] && pass "LLVM $ex -> $got" || fail "LLVM $ex -> $got, want $want"
}

run_mlir() {
    ex=$1; want=$2
    if [ ! -x "$LLVM_BIN/mlir-opt" ] || [ ! -x "$LLVM_BIN/mlir-translate" ] || [ ! -x "$LLVM_BIN/llc" ]; then
        skip "MLIR $ex (mlir-opt/mlir-translate/llc not found in $LLVM_BIN)"
        return
    fi
    $CELL emit --target=mlir "examples/$ex.cell" > "$TMP/$ex.mlir" 2>/dev/null || { fail "mlir emit $ex"; return; }
    pipeline=$(mlir_pipeline "$TMP/$ex.mlir")
    [ -n "$pipeline" ] || { fail "mlir $ex: emitted MLIR carries no '// lower with:' line"; return; }
    # Unquoted on purpose: $pipeline is a list of flags and must split.
    "$LLVM_BIN/mlir-opt" "$TMP/$ex.mlir" $pipeline \
        -o "$TMP/${ex}_low.mlir" 2>/dev/null || { fail "mlir-opt $ex"; return; }
    "$LLVM_BIN/mlir-translate" --mlir-to-llvmir "$TMP/${ex}_low.mlir" -o "$TMP/${ex}_m.ll" 2>/dev/null \
        || { fail "mlir-translate $ex"; return; }
    "$LLVM_BIN/llc" -filetype=obj "$TMP/${ex}_m.ll" -o "$TMP/${ex}_m.o" 2>/dev/null || { fail "llc $ex"; return; }
    cc "$TMP/${ex}_m.o" "$TMP/drv.c" "$TMP/rt.o" -o "$TMP/${ex}_m" 2>/dev/null || { fail "mlir link $ex"; return; }
    got=$("$TMP/${ex}_m")
    [ "$got" = "$want" ] && pass "MLIR $ex -> $got" || fail "MLIR $ex -> $got, want $want"
}

# hello uses a struct; backends is scalar-only and is the cross-backend
# agreement case; loops covers while/break/continue.
for pair in "hello 42" "backends 24" "loops 55"; do
    set -- $pair
    run_c "$1" "$2"
    run_llvm "$1" "$2"
    run_mlir "$1" "$2"
done

# arc is C only: the LLVM and MLIR backends refuse `arc` outright, which the
# agreement section above already checks. 13 is a refcount measurement, not
# arithmetic: `observe` returns the strong count it was handed (3 both times,
# the original plus the `alias` handle plus that call's own retain), and
# `inspect` returns the borrowed view's length, 7. A missing call-site retain
# reads 2 and prints 11; a retain wrongly inserted for the `shared` call
# would not change the number but would leak, so run this under `leaks` when
# changing the retain rules, not only under this equality.
run_c_host arc 13 examples/arc_host.c

# owned_string is C only for the same KIND of reason and a different one: the
# `str` -> owning-`String` conversion is a call to cell_string_from_str, which
# is `static inline` in the header and so has no symbol the LLVM or MLIR
# backend can call. Both refuse it, together, which stage 4 pins.
#
# 44 is 2+3+4+5+6+7+8+9, the byte length of each of the EIGHT positions where
# a borrowed view meets a declared owning `String`. Six of those were the
# recorded defect; the seventh and eighth are a value-slot `match` arm at a
# `let` and at a `return`, which no list of positions predicted. A conversion
# that produced an empty or a mis-sized value moves this number rather than
# passing quietly, and the emitted C would still compile.
#
# Stage 9 is the other half and the half that matters: its host FREES the
# `owned` argument, so a caller that passed a borrowed view of a string
# literal frees a non-heap pointer and AddressSanitizer says so. Compiling was
# never the hard part for this defect.
run_c_host owned_string 44 examples/owned_string_host.c

# -------------------------------------------------------------- 7. leaks --
# THESE FIXTURES ASSERT LEAKS THAT CURRENTLY EXIST. Read this script's header
# comment (stage 7) before touching anything below: a fixture failing because
# its count moved is reporting a real change in codegen, in either direction,
# and the fix belongs in src/ or in the pinned constant plus
# docs/OWNERSHIP.md, never in loosening this stage.
printf '\n== leaks (docs/OWNERSHIP.md R11 disclosed gaps) ==\n'
if ! command -v leaks > /dev/null 2>&1; then
    skip "leaks stage entirely (macOS 'leaks' tool not found; R11's disclosed gaps were NOT checked this run)"
else
    # Same shape as run_c_host: emit, compile, link against the real runtime
    # (plus an optional host for a bodyless declaration), except the fixture
    # is RUN under `leaks -atExit` and the verdict is a leak COUNT rather than
    # stdout. `host` may be empty; when it is not, the same "isolate the ABI
    # boundary in a hand-written C file" reasoning documented on run_c_host
    # applies (examples/leaks/unbound_shared_temp.cell reuses
    # examples/arc_host.c's existing `cell_inspect` rather than duplicating it).
    #
    # Two things differ from run_c_host, both forced by the header trap note
    # on `leaks -atExit` under-counting:
    #   * The emitted C is compiled as its OWN object with
    #     `-Dmain=cell_program_main`, and examples/leaks/leak_host.c supplies
    #     the real `main`, which runs the program and then clobbers the stack
    #     so the conservative scan cannot find a stale pointer to the last
    #     iteration's boxes. One `cc` line over every source would rename the
    #     host's `main` too and leave no entry point, hence the separate steps.
    #   * examples/leaks/malloc_counter.h is `-include`d into the emitted C,
    #     the runtime, and any host, and malloc_counter.c (compiled WITHOUT
    #     the header, see its comment) prints ALLOC/FREE/LIVE to stderr at
    #     exit. LIVE is a count of blocks never freed that owes nothing to a
    #     stack scan, and the fixture passes only when `leaks` AND LIVE both
    #     equal the pin, so a re-pin can never again rest on one witness.
    # The shared objects are built once, before the first fixture.
    LEAKCC="cc -I runtime -I examples/leaks"
    leak_shared_ok=1
    $LEAKCC -c examples/leaks/malloc_counter.c -o "$TMP/leak_counter.o" 2>/dev/null \
        || { fail "leaks: C compile examples/leaks/malloc_counter.c"; leak_shared_ok=0; }
    $LEAKCC -c examples/leaks/leak_host.c -o "$TMP/leak_host.o" 2>/dev/null \
        || { fail "leaks: C compile examples/leaks/leak_host.c"; leak_shared_ok=0; }
    $LEAKCC -include examples/leaks/malloc_counter.h -c runtime/cell_rt.c -o "$TMP/leak_rt.o" 2>/dev/null \
        || { fail "leaks: C compile runtime/cell_rt.c with the malloc counter"; leak_shared_ok=0; }
    run_c_leaks() {
        ex=$1; host=$2; want=$3; note=$4
        [ "$leak_shared_ok" -eq 1 ] || { fail "leaks $ex: shared objects did not build"; return; }
        $CELL emit "examples/leaks/$ex.cell" > "$TMP/leak_$ex.c" 2>/dev/null \
            || { fail "leaks: C emit $ex"; return; }
        $LEAKCC -include examples/leaks/malloc_counter.h -Dmain=cell_program_main \
            -c "$TMP/leak_$ex.c" -o "$TMP/leak_$ex.o" 2>/dev/null \
            || { fail "leaks: C compile $ex"; return; }
        host_obj=""
        if [ -n "$host" ]; then
            host_obj="$TMP/leak_${ex}_host.o"
            $LEAKCC -include examples/leaks/malloc_counter.h -c "$host" -o "$host_obj" 2>/dev/null \
                || { fail "leaks: C compile $host for $ex"; return; }
        fi
        # $host_obj is deliberately unquoted: empty means no extra object.
        cc "$TMP/leak_$ex.o" "$TMP/leak_host.o" "$TMP/leak_rt.o" "$TMP/leak_counter.o" $host_obj \
            -o "$TMP/leak_$ex" 2>/dev/null \
            || { fail "leaks: C link $ex"; return; }
        got=$(leaks -atExit -- "$TMP/leak_$ex" 2>"$TMP/leak_$ex.stderr" \
            | sed -n 's/^Process [0-9][0-9]*: \([0-9][0-9]*\) leaks for .*/\1/p' | tail -1)
        live=$(sed -n 's/^MALLOC_COUNTER ALLOC=[0-9]* FREE=[0-9]* LIVE=\([0-9][0-9]*\)$/\1/p' "$TMP/leak_$ex.stderr" | tail -1)
        if [ -z "$got" ]; then
            fail "leaks $ex: could not parse a leak count from 'leaks -atExit' output"
            return
        fi
        if [ -z "$live" ]; then
            fail "leaks $ex: the malloc counter printed no MALLOC_COUNTER line (was examples/leaks/malloc_counter.c linked and its atexit handler reached?)"
            return
        fi
        if [ "$got" -eq "$want" ] && [ "$live" -eq "$want" ]; then
            pass "leaks $ex -> $got leaks, counter LIVE=$live (pinned, $note)"
        elif [ "$got" -ne "$live" ]; then
            fail "leaks $ex -> leaks=$got but counter LIVE=$live, want $want for both (the two witnesses DISAGREE: that is a measurement problem in examples/leaks/leak_host.c or malloc_counter.c, not a codegen change; do not re-pin)"
        else
            fail "leaks $ex -> $got leaks, counter LIVE=$live, want $want (pinned $note; both witnesses agree, so this is real: a DROP means the R11 gap closed and the constant plus docs/OWNERSHIP.md need updating; a RISE, or any leak in a previously clean fixture, means codegen regressed)"
        fi
    }

    run_c_leaks param_never_released "" "$LEAK_PARAM_NEVER_RELEASED" "R11 row 1, CLOSED 2026-09-16"
    run_c_leaks struct_arc_field "" "$LEAK_STRUCT_ARC_FIELD" "R11 row 2, CLOSED 2026-09-15"
    run_c_leaks unbound_shared_temp examples/arc_host.c "$LEAK_UNBOUND_SHARED_TEMP" "R11 row 3, CLOSED @ 460b9a3"
    run_c_leaks block_scoped_local "" "$LEAK_BLOCK_SCOPED_LOCAL" "R11 row 4, CLOSED 2026-09-15"
    run_c_leaks reassigned_var "" "$LEAK_REASSIGNED_VAR" "R11 row 5, CLOSED 2026-09-15"
    run_c_leaks reassigned_owned_var "" "$LEAK_REASSIGNED_OWNED_VAR" "owned twin of row 5, CLOSED 2026-09-16"
    run_c_leaks revived_var "" "$LEAK_REVIVED_VAR" "R16 revival leak, CLOSED 2026-09-16"
    run_c_leaks value_block_local "" "$LEAK_VALUE_BLOCK_LOCAL" "R11 value-position block residual, CLOSED 2026-09-15"
    run_c_leaks partial_move_field "" "$LEAK_PARTIAL_MOVE_FIELD" "partial-move residual, CLOSED 2026-09-16"
    run_c_leaks arc_box_move "" "$LEAK_ARC_BOX_MOVE" "R10 move-into-arc at let, return, assignment, call argument and struct-literal field, implemented 2026-09-16"
    run_c_leaks branch_move "" "$LEAK_BRANCH_MOVE" "R16 residual 1, CLOSED 2026-09-16 by branch-end releases; 501 -> 0"
    run_c_leaks loop_jump_revival "" "$LEAK_LOOP_JUMP_REVIVAL" "R16 residual 2, CLOSED 2026-09-16 by jump releases; 1000 -> 0"
    run_c_leaks value_block_revival "" "$LEAK_VALUE_BLOCK_REVIVAL" "R16 residual 3, CLOSED 2026-09-16 by value-block-end releases; 1000 -> 0"
    run_c_leaks revived_record "" "$LEAK_REVIVED_RECORD" "R16 residual 4, CLOSED 2026-09-16 by record-revival admission; 1000 -> 0"
    run_c_leaks loop_cross "" "$LEAK_LOOP_CROSS" "R16 residual outer-while-var, CLOSED 2026-09-16 by after_loop releases; 1000 -> 0"
    run_c_leaks partial_nested_field "" "$LEAK_PARTIAL_NESTED_FIELD" "R16 residual nested partial field, CLOSED 2026-09-16 by recursive emitPartialRecordDrop; 1000 -> 0"
    run_c_leaks branch_field "" "$LEAK_BRANCH_FIELD" "R16 residual 1 at field granularity, CLOSED 2026-09-16 by branch-end field releases; 1000 -> 0"
    run_c_leaks field_revival "" "$LEAK_FIELD_REVIVAL" "R16 residual field revival, CLOSED 2026-09-16 by retracting the revived path from fieldWasMoved; 1000 -> 0"
fi

# ------------------------------------------- 8. cross-backend answer agreement --
# A VERDICT IS NOT AN ANSWER, and stage 4 only ever compared verdicts. It asks
# each backend whether it ACCEPTS a program; it never asks whether the accepted
# programs compute the same thing. So this gate could report "llvm and mlir
# agree on every example" while two of them printed different numbers, and it
# did: examples/write_through.cell prints 142 from the C and MLIR backends and
# printed 737 from the LLVM one, because the LLVM call site passed the address
# of a spilled COPY for every borrow and each write through an `exclusive`
# parameter was silently discarded. Both backends accepted it, so stage 4 was
# green; stage 6 runs a fixed list of four programs and none of them writes
# through a borrow; and the two examples that come closest, ownership.cell and
# borrows.cell, are SILENT by design and would have compared nothing even if
# they had been run. A silent program cannot catch a wrong answer.
#
# So this stage runs EVERY example that has a `main` with a body, through every
# backend that emits it, and compares stdout AND exit status across backends.
# Unlike stage 6 it keeps no hand-maintained list of expected numbers, so a new
# example is covered the day it lands rather than the day someone remembers to
# add a row to a loop up there.
#
# Agreement alone would still pass three identically-wrong backends, so an
# example may declare its own answer in a `// EXPECT-OUTPUT:` line and every
# backend is checked against that too. The declaration lives in the example,
# beside the program that produces it, for the same reason stage 5 reads the
# mlir pipeline out of the emitted file rather than keeping a copy here: a
# second copy drifts, and then the gate pins something nobody ships. The count
# of PINNED programs is reported below and zero is a FAILURE, for the same
# reason zero printing programs is: a stage that compared only unpinned
# programs has proved agreement and not correctness.
#
# THIS STAGE STILL ONLY SEES THE SHAPES THE CORPUS CONTAINS, and that is not a
# limitation to be engineered away, it is a standing obligation on whoever
# lands a compiler change. Measured a second time, on the other backend and
# the other side of the same rule: the MLIR backend silently miscompiled a
# WHOLE-VALUE write through an `exclusive` borrow,
#
#     pub fn reset(exclusive b: Buffer) { b = Buffer { len: 42 } }
#
# printing 37 where C and LLVM printed 42, and every stage here was green.
# write_through.cell was already in this stage and could not catch it, because
# its mutator writes a FIELD and lives in C. So the shape, not the rule, is
# what a corpus entry covers: `examples/write_through_whole.cell` is the
# whole-value half and prints 42. When a fix closes a silent class, the corpus
# has to gain a PRINTING program of that exact shape, or the next regression
# is silent again.
#
# An example whose bodyless declarations need C definitions gets them from
# `examples/<stem>_host.c`, the convention arc_host.c and write_through_host.c
# already share, linked into all three legs.
#
# Two failure modes are told apart deliberately. An emit REFUSAL is designed
# behaviour that stage 4 already pins, so this stage simply skips that
# backend's leg. An emit that SUCCEEDS and then fails to compile or link is a
# FAILURE: that is stage 5's lesson carried to the other two backends, since
# accepted text that cannot be built is not an accepted program.
printf '\n== backend answers ==\n'
answers_before=$fails
answers_compared=0
answers_printing=0
answers_pinned=0

if [ ! -x "$LLVM_BIN/mlir-opt" ] || [ ! -x "$LLVM_BIN/mlir-translate" ] || [ ! -x "$LLVM_BIN/llc" ]; then
    skip "the MLIR leg of the answer comparison (mlir-opt/mlir-translate/llc not found in $LLVM_BIN)"
    answers_mlir=no
else
    answers_mlir=yes
fi

for f in examples/*.cell; do
    n=$(basename "$f" .cell)

    # Only a `main` WITH A BODY produces a program. The rest of the corpus
    # emits no C `main`, so its link stops at `_main`, and that is by design
    # rather than a codegen defect. Reading the source is deterministic;
    # grepping a linker error for `_main` instead would let a REAL link failure
    # hide behind the expected one.
    grep -q '^pub fn main() *{' "$f" || continue

    # A host is compiled ONCE, here, and the object linked into all three
    # legs. Handing the .c to each leg instead means three compiles, and two of
    # those link lines carry no `-I runtime`, so the host's own
    # `#include "cell_rt.h"` fails there and the example reads as an
    # LLVM/MLIR build failure that is really a missing include path. Measured,
    # not imagined: that is exactly what the first run of this stage reported.
    host=""
    if [ -f "examples/${n}_host.c" ]; then
        if cc -c -I runtime "examples/${n}_host.c" -o "$TMP/ans_${n}_host.o" 2>"$TMP/ans_${n}_host.log"; then
            host="$TMP/ans_${n}_host.o"
        else
            fail "answers $n: examples/${n}_host.c does not compile"
            sed -n '1,4p' "$TMP/ans_${n}_host.log"
            continue
        fi
    fi

    # The example's own declared answer, when it states one. Absent is allowed:
    # cross-backend agreement is still checked, and most of this corpus
    # predates the convention.
    want=$(sed -n 's|^// EXPECT-OUTPUT: ||p' "$f" | head -1)

    ran=""
    out_c=""; st_c=""
    out_l=""; st_l=""
    out_m=""; st_m=""

    # -- C. Emits its own `main`, so it links without the driver.
    if $CELL emit "$f" > "$TMP/ans_$n.c" 2>/dev/null; then
        if cc -I runtime "$TMP/ans_$n.c" $host "$TMP/rt.o" -o "$TMP/ans_${n}_c" 2>"$TMP/ans_${n}_c.log"; then
            out_c=$("$TMP/ans_${n}_c"); st_c=$?
            ran="$ran C"
        else
            fail "answers $n: C emitted but did not build"
            sed -n '1,4p' "$TMP/ans_${n}_c.log"
        fi
    fi

    # -- LLVM. Also emits its own `main`.
    if $CELL emit --target=llvm "$f" > "$TMP/ans_$n.ll" 2>/dev/null; then
        if cc -Wno-override-module -x ir "$TMP/ans_$n.ll" -c -o "$TMP/ans_${n}_l.o" 2>"$TMP/ans_${n}_l.log" \
            && cc "$TMP/ans_${n}_l.o" $host "$TMP/rt.o" -o "$TMP/ans_${n}_l" 2>>"$TMP/ans_${n}_l.log"; then
            out_l=$("$TMP/ans_${n}_l"); st_l=$?
            ran="$ran LLVM"
        else
            fail "answers $n: LLVM emitted but did not build"
            sed -n '1,4p' "$TMP/ans_${n}_l.log"
        fi
    fi

    # -- MLIR. Emits cell_main only, so it needs the driver stage 6 wrote.
    if [ "$answers_mlir" = yes ] && $CELL emit --target=mlir "$f" > "$TMP/ans_$n.mlir" 2>/dev/null; then
        pipeline=$(mlir_pipeline "$TMP/ans_$n.mlir")
        if [ -z "$pipeline" ]; then
            fail "answers $n: emitted MLIR carries no '// lower with:' line"
            pipeline=""
        fi
        # Unquoted on purpose: $pipeline is a list of flags and must split.
        if "$LLVM_BIN/mlir-opt" "$TMP/ans_$n.mlir" $pipeline \
                -o "$TMP/ans_${n}_low.mlir" 2>"$TMP/ans_${n}_m.log" \
            && "$LLVM_BIN/mlir-translate" --mlir-to-llvmir "$TMP/ans_${n}_low.mlir" -o "$TMP/ans_${n}_m.ll" 2>>"$TMP/ans_${n}_m.log" \
            && "$LLVM_BIN/llc" -filetype=obj "$TMP/ans_${n}_m.ll" -o "$TMP/ans_${n}_m.o" 2>>"$TMP/ans_${n}_m.log" \
            && cc "$TMP/ans_${n}_m.o" "$TMP/drv.c" $host "$TMP/rt.o" -o "$TMP/ans_${n}_m" 2>>"$TMP/ans_${n}_m.log"; then
            out_m=$("$TMP/ans_${n}_m"); st_m=$?
            ran="$ran MLIR"
        else
            fail "answers $n: MLIR emitted but did not lower, translate or link"
            sed -n '1,4p' "$TMP/ans_${n}_m.log"
        fi
    fi

    [ -z "$ran" ] && continue
    answers_compared=$((answers_compared + 1))

    # The reference is whichever backend ran first, C when it ran at all. The
    # C backend is the oldest and the one examples/README.md quotes numbers
    # from, so naming it in a disagreement reads the right way round.
    case "$ran" in
        *C*) ref_out=$out_c; ref_st=$st_c; ref=C ;;
        *LLVM*) ref_out=$out_l; ref_st=$st_l; ref=LLVM ;;
        *) ref_out=$out_m; ref_st=$st_m; ref=MLIR ;;
    esac

    # stdout AND exit status. A program that prints the right answer and then
    # dies is not a passing program: 9f19b39 exists because that once read as
    # green.
    for b in $ran; do
        case $b in
            C) this_out=$out_c; this_st=$st_c ;;
            LLVM) this_out=$out_l; this_st=$st_l ;;
            MLIR) this_out=$out_m; this_st=$st_m ;;
        esac
        if [ "$this_out" != "$ref_out" ] || [ "$this_st" != "$ref_st" ]; then
            fail "answers $n: $b printed '$this_out' (exit $this_st), $ref printed '$ref_out' (exit $ref_st)"
        fi
    done

    # The declared answer, when the example states one. Backends that are all
    # wrong in the same way still agree with each other, and this is the only
    # check in the stage that can tell that case apart.
    if [ -n "$want" ]; then
        answers_pinned=$((answers_pinned + 1))
        for b in $ran; do
            case $b in
                C) this_out=$out_c ;;
                LLVM) this_out=$out_l ;;
                MLIR) this_out=$out_m ;;
            esac
            [ "$this_out" = "$want" ] || \
                fail "answers $n: $b printed '$this_out', the file declares EXPECT-OUTPUT '$want'"
        done
    fi

    [ -n "$ref_out" ] && answers_printing=$((answers_printing + 1))
    printf '  ....  %-22s %-14s -> %s\n' "$n" "$(echo $ran | tr ' ' '/')" "$ref_out"
done

# A stage that compared nothing must SAY so rather than reporting a green it
# did not earn, and one that compared only silent programs has proved exactly
# as much. That is the same silence this stage exists to end, one level up.
printf '  ....  %d program(s) compared, %d of them printing, %d pinned by EXPECT-OUTPUT\n' \
    "$answers_compared" "$answers_printing" "$answers_pinned"
if [ "$answers_compared" -eq 0 ]; then
    fail "the answer comparison ran against nothing at all"
elif [ "$answers_printing" -eq 0 ]; then
    fail "every program compared was silent, so nothing was actually compared"
elif [ "$answers_pinned" -eq 0 ]; then
    # Three backends wrong the same way agree with each other. Without at
    # least one declared answer this stage has compared them to nothing.
    fail "no program compared declares an EXPECT-OUTPUT, so agreement is all that was checked"
elif [ $fails -eq $answers_before ]; then
    pass "every backend that runs an example computes the same answer"
fi

# -------------------------------------------------- 9. sanitized execution --
# THE GATE HAD NO SANITIZER, AND THAT IS WHY IT CAUGHT NONE OF THE EIGHT
# USE-AFTER-FREES FOUND IN THIS REPOSITORY IN ONE EVENING. Every one of them
# passed `cell check`, compiled clean at `-Wall -Wextra -Werror`, ran to
# completion, printed a plausible answer, and surfaced only when a reviewer
# ran the program under AddressSanitizer BY HAND. Stages 6 and 8 run these
# programs and read what they print; a use-after-free that does not happen to
# corrupt the printed value is invisible to both.
#
# So the same programs are built again with -fsanitize=address and run, and an
# ASan report FAILS the gate. That last clause is the whole stage: a sanitizer
# whose output nobody checks is worse than no sanitizer, because it looks like
# coverage. Both signals are read, the report text and the exit status, since
# ASan exits non-zero on a report and a program can also die without printing
# one.
#
# A SANITIZER IS ONLY AS GOOD AS THE PROGRAMS IT RUNS, and this is the part
# that is easy to get wrong. Measured at `99d2971^`, the commit before a real
# heap-use-after-free in returned `arc` fields was fixed: EVERY runnable
# example in the corpus was ASan-clean. This stage, run against that compiler
# and that corpus, would have reported nothing at all. What was missing was not
# the sanitizer but a program that returned an `arc` field, so
# examples/arc_return_field.cell was written to be that program, and against
# `99d2971^` it exits 134 with "AddressSanitizer: heap-use-after-free". A
# sanitizer stage should be read as a claim about the corpus, not about the
# compiler: when a defect class has no example, this stage is silent about it.
#
# The build is `-std=c11 -Wall -Wextra -Werror`, which is stricter than stages
# 6 and 8 and deliberately so. Those two send compiler diagnostics to
# /dev/null, so a warning in emitted C is information this gate used to throw
# away; here a warning fails, and examples/README.md's claim that every
# emitted file compiles under those flags becomes a thing the gate checks
# rather than a thing a document asserts. Measured today: zero warnings across
# the corpus, so this starts green rather than pinning a backlog.
#
# `cc`, never `zig cc`: measured, `zig cc -fsanitize=address` does not link
# here, the same way `zig cc -x ir` does not work for stage 6.
#
# LeakSanitizer is OFF. Leaks are stage 7's subject, it measures them with
# macOS `leaks` against pinned counts, and several fixtures there leak ON
# PURPOSE because docs/OWNERSHIP.md R11 discloses those gaps. Turning leak
# detection on here would report those same disclosed gaps a second time, in a
# stage that cannot tell a disclosed one from a new one.
#
# Only the C backend is sanitized, and the limit is real rather than an
# oversight. ASan instruments at COMPILE time from source; the LLVM and MLIR
# legs hand `cc` an already-emitted .ll or object, so their emitted code would
# carry no instrumentation and a pass over them would report far less than it
# appears to. The C backend is also where all eight of those defects were, it
# being the only backend that implements `arc` at all.
#
# examples/leaks/ is not covered here. Its fixtures take examples/arc_host.c
# under a different convention that stage 7 owns and passes explicitly, and
# they exist to leak; four of the five were measured ASan-clean, and the fifth
# does not link under the `<stem>_host.c` rule this stage shares with stage 8.
printf '\n== sanitized execution (AddressSanitizer) ==\n'
asan_before=$fails
asan_ran=0

printf 'int main(void){return 0;}\n' > "$TMP/asan_probe.c"
if ! cc -fsanitize=address "$TMP/asan_probe.c" -o "$TMP/asan_probe" 2>/dev/null; then
    skip "sanitized execution of every runnable example (cc -fsanitize=address does not link here)"
else
    for f in examples/*.cell; do
        n=$(basename "$f" .cell)
        grep -q '^pub fn main() *{' "$f" || continue

        # An emit refusal is stage 4's subject, not this one.
        $CELL emit "$f" > "$TMP/san_$n.c" 2>/dev/null || continue

        host=""
        if [ -f "examples/${n}_host.c" ]; then
            host="examples/${n}_host.c"
        fi

        # -Werror on purpose, and the log is printed rather than discarded.
        if ! cc -std=c11 -Wall -Wextra -Werror -fsanitize=address -g -I runtime \
                "$TMP/san_$n.c" $host runtime/cell_rt.c -o "$TMP/san_$n" 2>"$TMP/san_$n.log"; then
            fail "asan $n: emitted C did not build at -Wall -Wextra -Werror -fsanitize=address"
            sed -n '1,6p' "$TMP/san_$n.log"
            continue
        fi

        # detect_leaks=0: see the header. The status is captured from the
        # program itself and never through a pipe.
        ASAN_OPTIONS=detect_leaks=0 "$TMP/san_$n" > "$TMP/san_$n.out" 2>"$TMP/san_$n.err"
        st=$?
        asan_ran=$((asan_ran + 1))

        if grep -q 'ERROR: AddressSanitizer' "$TMP/san_$n.err"; then
            fail "asan $n: $(grep -m1 -o 'AddressSanitizer: [a-z0-9-]*' "$TMP/san_$n.err") (exit $st)"
            sed -n '1,8p' "$TMP/san_$n.err"
        elif [ $st -ne 0 ]; then
            # No report, but it still died. Worth failing on its own: stages 6
            # and 8 compare what a program printed, and a program can print the
            # right thing and then abort.
            fail "asan $n: exited $st under AddressSanitizer with no report"
            sed -n '1,6p' "$TMP/san_$n.err"
        fi
    done

    # A stage that sanitized nothing has proved nothing, and must say so.
    printf '  ....  %d program(s) run under AddressSanitizer\n' "$asan_ran"
    if [ "$asan_ran" -eq 0 ]; then
        fail "the sanitizer stage ran against nothing at all"
    elif [ $fails -eq $asan_before ]; then
        pass "every runnable example is clean under AddressSanitizer"
    fi
fi

# ------------------------------------------------- 10. declared signatures --
# TWO PARTIES AGREEING IS NOT CORRECTNESS WHEN A THIRD DEFINES THE CONTRACT.
# Stage 4 compares the LLVM backend against the MLIR backend and nothing else,
# so it cannot see them being wrong together, and it cannot see either of them
# disagreeing with C. runtime/cell_rt.h section 7 is the contract every backend
# is supposed to honour and the C backend is its reference implementation, so
# the missing comparison is C against the other two. This stage is it.
#
# THE LIVE INSTANCE it was written for, measured rather than imagined:
#
#     pub fn make() -> String;
#     pub fn f() -> arc String { return make() }
#
# C declares `cell_arc_t cell_f(void)`, which clang lowers to
# `void @cell_f(ptr sret(%struct.cell_arc))`, a 24-byte {ptr, ptr, ptr}. Both
# other backends declare `void @cell_f(ptr sret(%cell_string))`, a 24-byte
# {ptr, i64, i64}. Same arity, same sret-ness, SAME SIZE, different type: a C
# host linked against either IR backend's object hands the callee a buffer the
# callee fills with the wrong struct. Every other stage was green on it. Stage
# 8 could not have caught it either, because the program has no `main`.
#
# HOW THE COMPARISON IS MADE, and why not textually. All three legs are
# reduced to LLVM IR first: the emitted C through `cc -S -emit-llvm`, the LLVM
# backend's output as it stands, the MLIR backend's through its own pipeline
# and mlir-translate. That matters, because clang is the thing that turns a C
# declaration into a calling convention. Comparing `cell_arc_t cell_f(void)`
# against `void @cell_f(ptr sret(...))` as TEXT reports a difference that is
# not one: for a 24-byte return the C ABI uses an sret pointer too, and clang
# says so where the header does not.
#
# WHAT IS COMPARED, per function, per backend, against C:
#
#   * the number of parameters after ABI lowering, so an sret pointer counts
#     as the parameter it is;
#   * for each parameter position, whether it is passed INDIRECTLY (`sret`,
#     `byval`) and, when it is, the FULL RESOLVED FIELD LAYOUT of the pointee.
#     clang does not coerce an indirect type, so field-exact is valid here,
#     and this is the half that catches the `arc` case above, which size alone
#     would miss;
#   * for each DIRECT parameter and for the return, a canonical form: scalars
#     by name (ptr, i64, i32, i8, i1, float, double), aggregates collapsed
#     single-element-wise and then reduced to `agg<bytes>`, with an `f` suffix
#     when every leaf is floating point so an HFA cannot canonicalize onto an
#     integer aggregate of the same size. Direct aggregates are reduced rather
#     than compared field by field because CLANG HAS ALREADY COERCED THEM: it
#     renders every 16-byte aggregate as `[2 x i64]`, so the field structure
#     is not recoverable from the C leg and comparing it would fail on
#     spelling. Measured on this corpus, that reduction is what makes
#     `[2 x i64]` vs `{ptr,i64}` vs `{i8,i64}` agree, correctly, while
#     `ptr` vs `{ptr,i64,i64}` still disagrees, correctly.
#
# WHAT IS DELIBERATELY NOT COMPARED, because a stage that looked stronger than
# it is would be worse than the hole it replaces:
#
#   * `zeroext` / `signext`. These ARE calling convention, not hints, and they
#     DO differ here: measured on this commit, clang marks nine parameters
#     that the other backends do not, and the LLVM backend is inconsistent
#     with ITSELF about it, emitting `zeroext` on a `declare`d `i1` but not on
#     a `define`d one, and not at all for `i8`. That is a real finding and it
#     is recorded here rather than gated, because gating it would put nine
#     pins in a file that already has four and would drown the ABI-shape
#     signal this stage exists for. It is a named blind spot, not an oversight.
#   * the field structure of DIRECT aggregates, for the clang-coercion reason
#     above. Two 16-byte aggregates with different fields compare equal.
#   * the difference between "a pointer" and "a caller-allocated COPY behind a
#     pointer", which src/cell/abi.zig:194 already warns about in capitals:
#     `.direct = "ptr"` AND `.indirect` RENDER AS THE SAME FOUR CHARACTERS.
#     clang emits a bare `ptr` for an over-16-byte aggregate passed by value
#     too, so on the C leg `owned String`, `shared [T]` and `exclusive String`
#     all canonicalize to `ptr`, and an emitter that handed the callee a
#     pointer to the CALLER'S ORIGINAL where the ABI says a copy would agree
#     with C here perfectly. That is a real hole in this stage and it is named
#     rather than papered over; ownership of the pointee is abi.zig's subject
#     and its own tests', not this comparison's.
#   * hint attributes (noalias, noundef, dead_on_unwind, writable, align, ...),
#     parameter names, and linkage. None of those are calling convention.
#   * functions that are not present in BOTH IRs. clang drops a declaration
#     nothing references, and the IR backends declare only what they use, so
#     the comparison is over the intersection and the size of it is reported.
#     The probe array below exists to shrink that gap: it takes the address of
#     every function the emitted C declares, which keeps clang from dropping
#     them and, measured, adds 15 comparisons on examples/primitives.cell
#     alone, the example where classification matters most.
#   * anything about what the functions DO. This stage reads declarations. A
#     backend can agree perfectly here and compute the wrong answer, which is
#     stage 8's subject, and it can agree here and mis-lower, which is stage
#     5's.
#   * any ABI but this machine's. The C leg is whatever `cc` targets, so these
#     are AArch64/Darwin facts. On another target the same source could
#     legitimately produce a different, still-consistent set.
#
# An unparseable or unresolved type FAILS rather than being skipped: a size
# this stage guessed wrong would make two different ABIs compare equal, which
# is the one outcome it exists to prevent.
#
# SKIPS. `cc -S -emit-llvm` is the reference leg, so if it does not work the
# whole stage skips loudly. mlir-opt/mlir-translate missing skips the MLIR leg
# only, the way stage 8 does. llc is not needed: nothing is run here. A skipped
# leg also suppresses the pin-rot check for ITS pins, and that clause was
# written after measuring the alternative: with LLVM_BIN=/nonexistent the three
# `:MLIR` pins below all reported themselves as never compared, and the gate
# blamed its own pin list for a missing tool.
printf '\n== declared signatures (C is the reference) ==\n'
sig_before=$fails
sig_compared=0
sig_disagree=0
sig_undisclosed=0
sig_examples=0
sig_conly=0
SIGTAB=$(printf '\t')

cat > "$TMP/sig.awk" <<'SIG_AWK_END'
# Reduce every `@cell_*` declaration in an LLVM IR file to an ABI-shaped
# signature: "name<TAB>ret|p0|p1|...". Stage 10's header says what the shape
# deliberately keeps and deliberately throws away, and why each.
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# Split s on TOP-LEVEL commas into arr[1..n]. Depth-aware, so a comma inside
# `{ ptr, i64 }` or `sret({ ... })` never splits a parameter in half.
function tsplit(s, arr,   i, d, cur, n, c) {
    n = 0; d = 0; cur = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "{" || c == "[" || c == "(" || c == "<") d++
        else if (c == "}" || c == "]" || c == ")" || c == ">") d--
        if (c == "," && d == 0) { n++; arr[n] = trim(cur); cur = "" }
        else cur = cur c
    }
    if (trim(cur) != "") { n++; arr[n] = trim(cur) }
    return n
}

# Size and alignment, AArch64/Darwin. Anything not listed returns -1 and the
# caller reports UNPARSEABLE rather than guessing a layout: a wrong size here
# would make two different ABIs compare equal, which is the one outcome this
# stage exists to prevent.
function talign(t,   inner, n, i, a, mx, parts) {
    t = trim(t)
    if (t == "ptr" || t == "i64" || t == "double") return 8
    if (t == "i32" || t == "float") return 4
    if (t == "i16") return 2
    if (t == "i8" || t == "i1") return 1
    if (substr(t, 1, 1) == "[") {
        inner = substr(t, 2, length(t) - 2)
        if (inner !~ /^[0-9]+ x /) return -1
        sub(/^[0-9]+ x /, "", inner)
        return talign(inner)
    }
    if (substr(t, 1, 1) == "{") {
        inner = trim(substr(t, 2, length(t) - 2))
        if (inner == "") return 1
        n = tsplit(inner, parts); mx = 1
        for (i = 1; i <= n; i++) { a = talign(parts[i]); if (a < 0) return -1; if (a > mx) mx = a }
        return mx
    }
    return -1
}

function tsize(t,   inner, cnt, n, i, off, a, s, mx, parts) {
    t = trim(t)
    if (t == "ptr" || t == "i64" || t == "double") return 8
    if (t == "i32" || t == "float") return 4
    if (t == "i16") return 2
    if (t == "i8" || t == "i1") return 1
    if (substr(t, 1, 1) == "[") {
        inner = substr(t, 2, length(t) - 2)
        if (inner !~ /^[0-9]+ x /) return -1
        cnt = inner; sub(/ x .*$/, "", cnt)
        sub(/^[0-9]+ x /, "", inner)
        s = tsize(inner); if (s < 0) return -1
        return (cnt + 0) * s
    }
    if (substr(t, 1, 1) == "{") {
        inner = trim(substr(t, 2, length(t) - 2))
        if (inner == "") return 0
        n = tsplit(inner, parts); off = 0; mx = 1
        for (i = 1; i <= n; i++) {
            a = talign(parts[i]); s = tsize(parts[i])
            if (a < 0 || s < 0) return -1
            if (a > mx) mx = a
            if (off % a != 0) off += a - (off % a)
            off += s
        }
        if (off % mx != 0) off += mx - (off % mx)
        return off
    }
    return -1
}

# An HFA and an integer aggregate of the SAME SIZE go to different register
# files, so `agg8` must not be able to mean both.
function allfp(t,   inner, n, i, parts) {
    t = trim(t)
    if (t == "float" || t == "double") return 1
    if (t ~ /^(ptr|i1|i8|i16|i32|i64)$/) return 0
    if (substr(t, 1, 1) == "[") { inner = substr(t, 2, length(t) - 2); sub(/^[0-9]+ x /, "", inner); return allfp(inner) }
    if (substr(t, 1, 1) == "{") {
        inner = trim(substr(t, 2, length(t) - 2))
        if (inner == "") return 0
        n = tsplit(inner, parts)
        for (i = 1; i <= n; i++) if (!allfp(parts[i])) return 0
        return 1
    }
    return 0
}

# A one-element aggregate occupies exactly what its element does, and the three
# emitters spell that three ways: i64, [1 x i64], { i64 }. Collapse, repeatedly.
function collapse(t,   inner, n, parts) {
    t = trim(t)
    while (1) {
        if (substr(t, 1, 1) == "{") {
            inner = trim(substr(t, 2, length(t) - 2))
            if (inner == "") return t
            delete parts
            n = tsplit(inner, parts)
            if (n != 1) return t
            t = trim(parts[1])
        } else if (substr(t, 1, 1) == "[") {
            inner = substr(t, 2, length(t) - 2)
            if (inner !~ /^1 x /) return t
            sub(/^1 x /, "", inner)
            t = trim(inner)
        } else return t
    }
}

# A DIRECTLY passed or returned type. clang has already coerced these into
# register-shaped types (any 16-byte aggregate becomes [2 x i64]), so the field
# structure is NOT recoverable from the C leg and comparing it would fail on
# spelling. Scalars keep their name; aggregates reduce to size plus float-ness.
function canon(t,   c, s) {
    c = collapse(t)
    if (c ~ /^(ptr|i1|i8|i16|i32|i64|float|double|void)$/) return c
    if (substr(c, 1, 1) == "{" || substr(c, 1, 1) == "[") {
        s = tsize(c)
        if (s < 0) return "UNPARSEABLE<" c ">"
        return "agg" s (allfp(c) ? "f" : "")
    }
    return "UNPARSEABLE<" c ">"
}

# Named struct types, substituted into every use. An INDIRECT type is compared
# field by field, so the substitution must be complete; a name that never
# resolves is reported rather than silently dropped with the value names.
function resolve(t,   pass, i, c, out, tok, changed) {
    for (pass = 0; pass < 12; pass++) {
        changed = 0; out = ""; i = 1
        while (i <= length(t)) {
            c = substr(t, i, 1)
            if (c == "%") {
                tok = "%"; i++
                while (i <= length(t) && substr(t, i, 1) ~ /[A-Za-z0-9_.$]/) { tok = tok substr(t, i, 1); i++ }
                if (tok in ty) { out = out ty[tok]; changed = 1 } else { out = out tok }
            } else { out = out c; i++ }
        }
        t = out
        if (!changed) break
    }
    return t
}

# Drop the words that are HINTS rather than calling convention, and the value
# names. What survives is the type. zeroext/signext are dropped here too and
# they are NOT hints; stage 10's header records that as a named blind spot.
function bareType(s,   i, n, out, w, parts) {
    gsub(/align +[0-9]+/, " ", s)
    gsub(/dereferenceable(_or_null)?\([0-9]+\)/, " ", s)
    gsub(/(captures|initializes|range|memory|alignstack)\([^)]*\)/, " ", s)
    gsub(/#[0-9]+/, " ", s)
    gsub(/%[A-Za-z0-9_.$]+/, " ", s)
    gsub(/,/, " , ", s)
    n = split(s, parts, /[ \t]+/)
    out = ""
    for (i = 1; i <= n; i++) {
        w = parts[i]
        if (w == "") continue
        if (w ~ /^(dead_on_unwind|writable|noalias|noundef|nonnull|nocapture|readonly|readnone|writeonly|inreg|returned|immarg|willreturn|nofree|nosync|nounwind|zeroext|signext|inalloca|swiftself|swifterror|disjoint|dso_local|local_unnamed_addr|internal|private|external|weak|weak_odr|linkonce|linkonce_odr|hidden|protected|available_externally|fastcc|ccc|coldcc|tailcc|swiftcc)$/) continue
        out = out (out == "" ? "" : " ") w
    }
    return out
}

# An unresolved NAMED type would be deleted by bareType along with the value
# names, and two different opaque structs would then compare equal. Refuse.
function unresolved(s) { return (s ~ /%(struct|union|class)\.|%cell_/) }

/^%[A-Za-z0-9_.$]+ = type / {
    body = $0; sub(/^[^=]*= type /, "", body)
    ty[$1] = trim(body)
    next
}

/^(declare|define)[^@]*@cell_[A-Za-z0-9_]*[ ]*\(/ {
    line = $0
    at = index(line, "@cell_")
    head = substr(line, 1, at - 1)
    rest = substr(line, at + 1)
    fname = rest; sub(/[ (].*$/, "", fname)

    # The balanced argument list, so `sret({ ptr, i64, i64 })` survives whole.
    depth = 0; args = ""; started = 0
    for (i = index(rest, "("); i <= length(rest); i++) {
        ch = substr(rest, i, 1)
        if (ch == "(") { depth++; if (depth == 1) { started = 1; continue } }
        else if (ch == ")") { depth--; if (depth == 0) break }
        if (started) args = args ch
    }

    sub(/^(declare|define) */, "", head)
    rt = resolve(head)
    if (unresolved(rt)) { print fname "\tUNRESOLVED-RETURN-TYPE"; next }
    sig = bareType(rt)
    sig = (sig == "" ? "void" : canon(sig))

    ra = resolve(args)
    delete ps
    np = tsplit(ra, ps)
    for (i = 1; i <= np; i++) {
        p = ps[i]
        if (match(p, /sret\(/) || match(p, /byval\(/)) {
            kind = (match(p, /sret\(/) ? "sret" : "byval")
            match(p, /(sret|byval)\(/)
            st = substr(p, RSTART + RLENGTH); d = 1; inner = ""
            for (j = 1; j <= length(st); j++) {
                ch = substr(st, j, 1)
                if (ch == "(") d++
                else if (ch == ")") { d--; if (d == 0) break }
                inner = inner ch
            }
            if (unresolved(inner)) { sig = sig "|" kind ":UNRESOLVED"; continue }
            gsub(/[ \t]/, "", inner)
            sig = sig "|" kind ":" inner
        } else if (unresolved(p)) {
            sig = sig "|UNRESOLVED-PARAM-TYPE"
        } else {
            sig = sig "|" canon(bareType(p))
        }
    }
    print fname "\t" sig
}
SIG_AWK_END

sig_pinned() { printf '%s\n' "$SIG_DISCLOSED" | grep -qx "$1"; }

# One (function, leg) verdict. Three outcomes, and the third is the one that
# keeps the pin list honest: a pin that stops disagreeing FAILS.
sig_verdict() {
    _key=$1; _fn=$2; _leg=$3; _c=$4; _b=$5
    _pin="$_key:$_fn:$_leg"
    if [ "$_c" = "$_b" ]; then
        if sig_pinned "$_pin"; then
            fail "signatures $_pin AGREES now: the disclosed gap is CLOSED. Delete the pin from SIG_DISCLOSED and cite the commit that closed it."
        fi
        : > "$TMP/sighit_$(printf '%s' "$_pin" | tr '/:' '__')"
        return
    fi
    sig_disagree=$((sig_disagree + 1))
    : > "$TMP/sighit_$(printf '%s' "$_pin" | tr '/:' '__')"
    if sig_pinned "$_pin"; then
        pass "signatures $_key $_fn: $_leg disagrees with C (DISCLOSED, pinned in SIG_DISCLOSED)"
        printf '        C    %s\n        %-4s %s\n' "$_c" "$_leg" "$_b"
    else
        sig_undisclosed=$((sig_undisclosed + 1))
        fail "signatures $_key $_fn: $_leg declares a DIFFERENT calling convention from C"
        printf '        C    %s\n        %-4s %s\n' "$_c" "$_leg" "$_b"
    fi
}

# join(1) needs both sides sorted in the SAME collation as its own comparison.
# LC_ALL=C on both sides rather than trusting the ambient locale.
sig_join() {
    _key=$1; _leg=$2; _cs=$3; _bs=$4
    LC_ALL=C join -t"$SIGTAB" "$_cs" "$_bs" > "$TMP/sig_join.txt"
    # Redirected from a FILE, not a pipe: a `while read` in a pipeline runs in
    # a subshell and every fails++ inside it would be discarded on exit.
    while IFS="$SIGTAB" read -r _fn _a _b; do
        [ -n "$_fn" ] || continue
        sig_compared=$((sig_compared + 1))
        case "$_a$_b" in
            *UNPARSEABLE*|*UNRESOLVED*)
                fail "signatures $_key $_fn: this stage could not parse a type it must compare exactly (C='$_a' $_leg='$_b'); teach tsize/talign the type rather than letting it compare equal"
                continue ;;
        esac
        sig_verdict "$_key" "$_fn" "$_leg" "$_a" "$_b"
    done < "$TMP/sig_join.txt"
}

printf 'int cell__sig_probe_fn(void){return 0;}\n' > "$TMP/sig_probe.c"
if ! cc -std=c11 -S -emit-llvm -o "$TMP/sig_probe.ll" "$TMP/sig_probe.c" 2>/dev/null; then
    skip "the declared-signature comparison entirely (cc -S -emit-llvm does not work here, and the C leg is the reference every other leg is compared against)"
else
    if [ ! -x "$LLVM_BIN/mlir-opt" ] || [ ! -x "$LLVM_BIN/mlir-translate" ]; then
        skip "the MLIR leg of the declared-signature comparison (mlir-opt/mlir-translate not found in $LLVM_BIN)"
        sig_mlir=no
    else
        sig_mlir=yes
    fi

    for f in examples/*.cell examples/pairing/*.cell examples/signatures/*.cell; do
        # An unmatched glob stays literal in sh rather than vanishing, and a
        # literal path is not a file.
        [ -f "$f" ] || continue
        key=$(printf '%s' "$f" | sed 's|^examples/||; s|\.cell$||')
        tag=$(artifact_tag "$key")

        # The C leg is the reference. A refusal here is not designed behaviour
        # the way an LLVM/MLIR refusal is, so it fails rather than skipping.
        if ! $CELL emit "$f" > "$TMP/sig_$tag.c" 2>/dev/null; then
            fail "signatures $key: the C backend refused an example the corpus says it accepts"
            continue
        fi

        # clang drops a declaration nothing references, and most of this corpus
        # is bodyless declarations. Taking their addresses keeps them in the
        # IR. Anchored to the emitted file's own top-level `...cell_x(...);`
        # lines, so nothing from cell_rt.h and nothing from a function body
        # can match.
        {
            cat "$TMP/sig_$tag.c"
            printf '\nvoid *cell__sig_probe[] = {\n'
            sed -n 's/^[A-Za-z_].* \**\(cell_[A-Za-z0-9_]*\)(.*);$/  (void *)\&\1,/p' "$TMP/sig_$tag.c" \
                | LC_ALL=C sort -u
            printf '};\n'
        } > "$TMP/sig_${tag}_probe.c"

        if ! cc -std=c11 -S -emit-llvm -I runtime -o "$TMP/sig_$tag.cll" \
                "$TMP/sig_${tag}_probe.c" 2>"$TMP/sig_$tag.clog"; then
            fail "signatures $key: the emitted C did not lower to LLVM IR"
            sed -n '1,4p' "$TMP/sig_$tag.clog"
            continue
        fi
        awk -f "$TMP/sig.awk" "$TMP/sig_$tag.cll" | LC_ALL=C sort > "$TMP/sig_$tag.csig"

        legs=""

        # -- LLVM. Only exit 1 with a cannot-lower diagnostic is a refusal.
        backend_emit_verdict llvm "$f" "$TMP/sig_$tag.ll" "$TMP/sig_$tag.lemit"
        sig_llvm_verdict=$BACKEND_VERDICT
        if [ "$sig_llvm_verdict" = accept ]; then
            awk -f "$TMP/sig.awk" "$TMP/sig_$tag.ll" | LC_ALL=C sort > "$TMP/sig_$tag.lsig"
            sig_join "$key" LLVM "$TMP/sig_$tag.csig" "$TMP/sig_$tag.lsig"
            legs="$legs LLVM"
        elif [ "$sig_llvm_verdict" = error ]; then
            fail "signatures $key: LLVM emit failed unexpectedly (exit $BACKEND_STATUS)"
            sed -n '1,4p' "$TMP/sig_$tag.lemit"
        fi

        # -- MLIR. Lowered and translated, so the comparison is against the
        # same LLVM-level shape as the other two rather than against MLIR
        # types. A lowering failure is stage 5's subject, so it is skipped
        # here rather than failed twice.
        sig_mlir_verdict=unavailable
        sig_mlir_post=unavailable
        if [ "$sig_mlir" = yes ]; then
            backend_emit_verdict mlir "$f" "$TMP/sig_$tag.mlir" "$TMP/sig_$tag.memit"
            sig_mlir_verdict=$BACKEND_VERDICT
        fi
        if [ "$sig_mlir_verdict" = accept ]; then
            pipeline=$(mlir_pipeline "$TMP/sig_$tag.mlir")
            if [ -z "$pipeline" ]; then
                sig_mlir_post=missing-pipeline
                fail "signatures $key: emitted MLIR carries no '// lower with:' line"
            # Unquoted on purpose: $pipeline is a list of flags and must split.
            elif ! mlir_to_llvm "$TMP/sig_$tag.mlir" "$pipeline" \
                    "$TMP/sig_${tag}_low.mlir" "$TMP/sig_${tag}_m.ll" "$TMP/sig_$tag"; then
                if [ "$MLIR_LOWER_FAILURE" = opt ]; then
                    sig_mlir_post=opt-failed
                fail "signatures $key: emitted MLIR failed to lower"
                    sed -n '1,4p' "$TMP/sig_$tag.opt"
                else
                    sig_mlir_post=translate-failed
                    fail "signatures $key: lowered MLIR failed to translate to LLVM IR"
                    sed -n '1,4p' "$TMP/sig_$tag.translate"
                fi
            else
                sig_mlir_post=compared
                awk -f "$TMP/sig.awk" "$TMP/sig_${tag}_m.ll" | LC_ALL=C sort > "$TMP/sig_$tag.msig"
                sig_join "$key" MLIR "$TMP/sig_$tag.csig" "$TMP/sig_$tag.msig"
                legs="$legs MLIR"
            fi
        elif [ "$sig_mlir_verdict" = error ]; then
            fail "signatures $key: MLIR emit failed unexpectedly (exit $BACKEND_STATUS)"
            sed -n '1,4p' "$TMP/sig_$tag.memit"
        fi

        sig_examples=$((sig_examples + 1))
        signature_coverage_verdict "$sig_llvm_verdict" "$sig_mlir_verdict" "$sig_mlir_post"
        if [ -z "$legs" ] && [ "$SIG_C_ONLY" = yes ]; then
            # Both IR backends refused the whole program. Designed behaviour,
            # counted rather than passed over in silence, because an example
            # that leaves this list is coverage this stage gained.
            sig_conly=$((sig_conly + 1))
            printf '  ....  %-30s C only (both IR backends refuse it)\n' "$key"
        elif [ -n "$legs" ]; then
            printf '  ....  %-30s C vs%s\n' "$key" "$legs"
        fi
    done

    # A pin nobody reached is a pin that has rotted: the function was renamed,
    # the example moved, or the backend stopped emitting it. Failing here is
    # what keeps SIG_DISCLOSED from silently describing a world that is gone.
    for pin in $SIG_DISCLOSED; do
        # A LEG THAT DID NOT RUN IS NOT A ROTTED PIN. Measured with
        # LLVM_BIN=/nonexistent before this guard existed: a legitimately
        # skipped MLIR leg turned all three of its pins into FAILURES, so the
        # gate reported a defect in its own pin list when the only real fact
        # was a missing tool. That is the exact shape of dishonesty the SKIP
        # convention exists to prevent, arriving through the back door.
        case "$pin" in
            *:MLIR) [ "$sig_mlir" = yes ] || continue ;;
        esac
        [ -f "$TMP/sighit_$(printf '%s' "$pin" | tr '/:' '__')" ] || \
            fail "signatures: the pin '$pin' was never compared this run (renamed, moved, or no longer emitted). Delete it or fix the key."
    done

    printf '  ....  %d function signature(s) compared across %d example(s), %d C-only; %d disagreement(s), %d of them disclosed and %d NOT\n' \
        "$sig_compared" "$sig_examples" "$sig_conly" "$sig_disagree" \
        "$((sig_disagree - sig_undisclosed))" "$sig_undisclosed"

    # A stage that compared nothing has proved nothing and must say so, the
    # same way stages 8 and 9 do.
    if [ "$sig_compared" -eq 0 ]; then
        fail "the declared-signature comparison ran against nothing at all"
    elif [ $fails -eq $sig_before ]; then
        pass "every backend that declares a function declares C's calling convention for it"
    fi
fi

# ---------------------------------------------------- 11. rule lists --
# Exit 0 is agreement, 1 is drift, 2 is a setup problem (no borrowck.zig, or
# no rules parsed from its header). 2 is a FAIL and not a SKIP: the authority
# missing is a repository defect, not an absent tool.
printf '\n== rule lists (docs agree with borrowck.zig) ==\n'
sh tools/check-rule-lists.sh > "$TMP/rule_lists.log" 2>&1
rule_lists_status=$?
case "$rule_lists_status" in
    0) pass "every document mentions every rule borrowck.zig enforces" ;;
    1) fail "rule lists drifted from src/cell/borrowck.zig's header (fix the document, not the header, unless the header is wrong)"
       grep '^DRIFT' "$TMP/rule_lists.log" | sed 's/^/        /' ;;
    *) fail "tools/check-rule-lists.sh could not run (exit $rule_lists_status): $(tail -1 "$TMP/rule_lists.log")" ;;
esac

# ------------------------------------------------------------ 12. cli build/run --
# Stage 6 is the oracle: it emits, compiles against runtime/cell_rt.c and runs
# three programs by hand. This stage proves `cell run` and `cell build`
# reproduce that recipe on their own, from the runtime the binary EMBEDS
# rather than the checkout's copy, with the same three pinned answers. The
# negatives matter as much: a rejected program must exit 1 and leave no file
# at the output path, `build` must refuse the textual targets, and a second
# positional must be refused rather than dropped (the old arg loop dropped
# it silently, which is how `cell build a.cell b.cell` would have compiled
# a.cell and said nothing). A program's exit code must come back through
# `run` unchanged: that is what makes `cell run` usable from a script.
printf '\n== cli build/run (stage 6 through the CLI, embedded runtime) ==\n'
# Counted before and after rather than asserted zero: another session's
# concurrent `cell run`, or a directory a crashed one left behind, is not
# this commit's leak. Only a count that GREW across this stage is.
staging_before=$(/bin/ls -d "${TMPDIR:-/tmp}"/cell-build-* 2>/dev/null | wc -l | tr -d ' ')
for pair in hello:42 backends:24 loops:55 prelude:123; do
    ex=${pair%%:*}; want=${pair##*:}
    got=$("$CELL" run "examples/$ex.cell" 2> "$TMP/run_$ex.err"); rc=$?
    if [ $rc -eq 0 ] && [ "$got" = "$want" ]; then
        pass "cell run $ex -> $got"
    else
        fail "cell run $ex -> '$got' (exit $rc), want $want; stderr: $(head -3 "$TMP/run_$ex.err" | tr '\n' ' ')"
    fi
done
# The two host-linked answers stage 6 pins through run_c_host: 13 is a
# refcount measurement only a C host can take, 44 exercises owned String at
# the boundary. A .c positional is handed to cc as given.
got=$("$CELL" run examples/arc.cell examples/arc_host.c 2> "$TMP/run_arc.err"); rc=$?
[ $rc -eq 0 ] && [ "$got" = "13" ] \
    && pass "cell run arc + arc_host.c -> 13" \
    || fail "cell run arc with its host -> '$got' (exit $rc), want 13; stderr: $(head -2 "$TMP/run_arc.err" | tr '\n' ' ')"
got=$("$CELL" run examples/owned_string_host.c examples/owned_string.cell 2> "$TMP/run_os.err"); rc=$?
[ $rc -eq 0 ] && [ "$got" = "44" ] \
    && pass "cell run owned_string + its host (host first) -> 44" \
    || fail "cell run owned_string with its host -> '$got' (exit $rc), want 44; stderr: $(head -2 "$TMP/run_os.err" | tr '\n' ' ')"
"$CELL" check examples/arc.cell examples/arc_host.c > /dev/null 2> "$TMP/check_host.err"; rc=$?
[ $rc -eq 1 ] && grep -q 'apply to build and run only' "$TMP/check_host.err" \
    && pass "a host .c is refused by check, never loaded as Cell source" \
    || fail "cell check with a .c positional: exit $rc, stderr: $(head -1 "$TMP/check_host.err")"
"$CELL" build examples/hello.cell -o "$TMP/hello_built" 2> "$TMP/build_hello.err"
if [ $? -eq 0 ] && [ -x "$TMP/hello_built" ] && [ "$("$TMP/hello_built")" = "42" ]; then
    pass "cell build -o writes a runnable executable (hello -> 42)"
else
    fail "cell build -o: $(head -3 "$TMP/build_hello.err" | tr '\n' ' ')"
fi
# Default output name: the stem. Built from a copy so the corpus stays clean.
cp examples/hello.cell "$TMP/stemtest.cell"
case "$CELL" in /*) cell_abs=$CELL ;; *) cell_abs=$PWD/$CELL ;; esac
( cd "$TMP" && "$cell_abs" build stemtest.cell > /dev/null 2>&1 ) && [ -x "$TMP/stemtest" ] && [ "$("$TMP/stemtest")" = "42" ] \
    && pass "cell build without -o writes the source stem (stemtest -> 42)" \
    || fail "cell build without -o did not produce a runnable $TMP/stemtest"
# Exit-status forwarding, measured on a program that asserts false: the
# runtime aborts (SIGABRT, 6), and the shell convention for a signal death
# is 128 + the number, so 134. Before this was pinned, `run` mapped every
# signal to 1, which is the compiler's own refusal code, so a script could
# not tell "the program died" from "the program did not compile".
if grep -q 'cell_assert' runtime/cell_rt.h; then
    printf 'pub fn assert(copy c: Bool);\npub fn main() {\n    assert(false)\n}\n' > "$TMP/dies.cell"
    "$CELL" run "$TMP/dies.cell" > /dev/null 2>&1; rc=$?
    [ $rc -eq 134 ] \
        && pass "cell run forwards a signal death as 128+signo (assert(false) -> 134)" \
        || fail "cell run of an aborting program returned $rc, want 134 (128 + SIGABRT)"
fi
# Negatives.
rm -f "$TMP/must_not_exist"
"$CELL" build examples/rejected/move_in_loop.cell -o "$TMP/must_not_exist" > /dev/null 2> "$TMP/build_rej.err"; rc=$?
if [ $rc -eq 1 ] && [ ! -e "$TMP/must_not_exist" ] && grep -q 'error:' "$TMP/build_rej.err"; then
    pass "cell build of a rejected program exits 1 with the diagnostic and writes nothing"
else
    fail "cell build of examples/rejected/move_in_loop.cell: exit $rc, output present: $([ -e "$TMP/must_not_exist" ] && echo yes || echo no)"
fi
"$CELL" build examples/hello.cell --target=llvm > /dev/null 2> "$TMP/build_llvm.err"; rc=$?
[ $rc -eq 1 ] && grep -q 'cell emit --target=llvm' "$TMP/build_llvm.err" \
    && pass "cell build --target=llvm is refused and points at emit" \
    || fail "cell build --target=llvm: exit $rc, stderr: $(head -1 "$TMP/build_llvm.err")"
"$CELL" build examples/hello.cell examples/loops.cell > /dev/null 2> "$TMP/build_two.err"; rc=$?
[ $rc -eq 1 ] && grep -q 'unexpected argument' "$TMP/build_two.err" \
    && pass "a second source file is refused, not silently dropped" \
    || fail "cell build with two sources: exit $rc, stderr: $(head -1 "$TMP/build_two.err")"
# Nothing staged is left behind: every run above removes its own directory.
staging_after=$(/bin/ls -d "${TMPDIR:-/tmp}"/cell-build-* 2>/dev/null | wc -l | tr -d ' ')
[ "$staging_after" -le "$staging_before" ] \
    && pass "no cell-build-* staging directory added under \${TMPDIR:-/tmp} ($staging_before before, $staging_after after)" \
    || fail "cell-build-* staging directories under ${TMPDIR:-/tmp} grew from $staging_before to $staging_after during this stage"

# ------------------------------------------------------------ 13. prelude sigs --
printf '\n== prelude signatures (emitted prototypes are in cell_rt.h) ==\n'
if tools/prelude-signatures.sh "$CELL" > "$TMP/prelude_sigs.txt" 2> "$TMP/prelude_sigs.err"; then
    missing=0
    while IFS= read -r proto; do
        if grep -qF -- "$proto" runtime/cell_rt.h; then
            pass "$proto"
        else
            fail "not in runtime/cell_rt.h: $proto"
            missing=$((missing + 1))
        fi
    done < "$TMP/prelude_sigs.txt"
    [ "$(wc -l < "$TMP/prelude_sigs.txt" | tr -d ' ')" -gt 0 ] || fail "prelude-signatures.sh printed no prototypes (the grep in it matched nothing)"
else
    fail "tools/prelude-signatures.sh could not emit the prelude: $(head -1 "$TMP/prelude_sigs.err")"
fi

# ------------------------------------------------------------------ 14. cli test --
printf '\n== cli test (a directory of programs through the run recipe) ==\n'
"$CELL" test tests > "$TMP/cli_test.out" 2> "$TMP/cli_test.err"; rc=$?
if [ $rc -eq 0 ] && grep -qx '3 passed, 0 failed' "$TMP/cli_test.out"; then
    pass "cell test tests/ -> 3 passed, 0 failed"
else
    fail "cell test tests/: exit $rc, $(tail -1 "$TMP/cli_test.out"); stderr: $(head -2 "$TMP/cli_test.err" | tr '\n' ' ')"
fi
mkdir -p "$TMP/tests-red" && cp tests/*.cell tests/*_host.c "$TMP/tests-red/"
printf '// EXPECT-OUTPUT: 1\npub fn assert(copy c: Bool);\npub fn main() {\n    assert(false)\n}\n' > "$TMP/tests-red/dies.cell"
"$CELL" test "$TMP/tests-red" > "$TMP/cli_test_red.out" 2> /dev/null; rc=$?
if [ $rc -eq 1 ] && grep -qx '3 passed, 1 failed' "$TMP/cli_test_red.out" && grep -q '^FAIL  dies.cell' "$TMP/cli_test_red.out"; then
    pass "a failing program is reported and exits 1 (dies.cell)"
else
    fail "cell test on a red directory: exit $rc, $(tail -1 "$TMP/cli_test_red.out")"
fi
mkdir -p "$TMP/tests-empty"
"$CELL" test "$TMP/tests-empty" > /dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && pass "an empty directory is exit 2, not green" || fail "cell test on an empty directory exited $rc, want 2"

# ---------------------------------------------------- 15. grok bots --
# Exit 0 is agreement, 1 is drift, 2 is a setup problem. 2 is a FAIL
# and not a SKIP: the overlay missing is a repository defect.
printf '\n== grok bots (project overlays name Cell'\''s gate) ==\n'
sh tools/check-grok-bots.sh > "$TMP/grok_bots.log" 2>&1
grok_bots_status=$?
case "$grok_bots_status" in
    0) pass "every project Grok bot names -Dswift=false, tools/check.sh, --test-filter, refAllDecls, and worktree" ;;
    1) fail "Grok bot definitions drifted from Cell's gate (fix .grok/, not this stage)"
       grep '^DRIFT' "$TMP/grok_bots.log" | sed 's/^/        /' ;;
    *) fail "tools/check-grok-bots.sh could not run (exit $grok_bots_status): $(tail -1 "$TMP/grok_bots.log")" ;;
esac

# ---------------------------------------------------------------- verdict --
printf '\n== verdict ==\n'
if [ $skips -gt 0 ]; then
    printf '  %d check(s) SKIPPED, so this run is weaker than a full one.\n' "$skips"
fi
if [ $fails -ne 0 ]; then
    printf '  %d FAILURE(S)\n\n' "$fails"
    exit 1
fi
printf '  clean\n\n'
exit 0
