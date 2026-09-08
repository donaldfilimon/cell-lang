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
#   7. leaks            docs/OWNERSHIP.md R11's "Still broken" table discloses
#                       six `arc` retain/release gaps and MEASURES five of
#                       them with `leaks`, in prose that lived nowhere as a
#                       file: nobody could re-run a single one of those
#                       numbers, or tell whether a change moved them.
#                       examples/leaks/*.cell isolates each measurable gap in
#                       its own program. THESE FIXTURES ASSERT LEAKS THAT
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
#   * `leaks -atExit` can UNDER-count by exactly one instance for a program
#     whose leaked allocation is still referenced by a stale CPU register or
#     stack slot at exit, a real false negative and not this script's bug (one
#     agent measured `leaks` reporting 0 for a case that genuinely leaked one
#     reference). The counts pinned below were re-measured 8 times each and
#     were IDENTICAL every time, so they are stable-but-possibly-undercounting
#     numbers, not flaky ones; if a future re-measurement is not reproducible
#     run to run, say so in the report rather than pinning whichever number
#     came up first.

set -u

cd "$(dirname "$0")/.." || exit 2

LLVM_BIN=${LLVM_BIN:-/opt/homebrew/opt/llvm/bin}
CELL=./zig-out/bin/cell
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

# ---- docs/OWNERSHIP.md R11 disclosed-leak constants, pinned by commit -----
# Each number is the exact `leaks -atExit` count this fixture produced when
# it was measured, over 1000 loop iterations, on THIS commit. Not the number
# quoted in docs/OWNERSHIP.md's prose (that prose predates these fixtures and
# used a different string literal in one case, which changes byte totals but
# not leak counts): re-measured fresh so the constant and the fixture that
# produces it live in the same place. Re-measured 8 times each and identical
# every time; see tools/check.sh's header trap note on `leaks -atExit`
# under-counting by one via a stale stack/register reference, which is why
# three of these read 999-worth of leaked units rather than the 1000 the
# source loop actually runs.
#
# When one of these changes because a gap in docs/OWNERSHIP.md R11 closed:
# update the constant AND that document's row, and cite the new commit here.
LEAKS_MEASURED_AT=78eadb22dd0e943f6f3ed15d8914d58a54e1ed11

# R11 row 1: a Cell body never releases its own `arc` parameter.
LEAK_PARAM_NEVER_RELEASED=2997
# R11 row 2: a struct holding an `arc` field is never dropped.
LEAK_STRUCT_ARC_FIELD=2997
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
# R11 row 4: an `arc` local declared inside a block is never released
# (function-scoped release, block-scoped binding); the "block form" row.
LEAK_BLOCK_SCOPED_LOCAL=2997
# R11 row 5: reassigning an `arc` `var` leaks the previous box.
LEAK_REASSIGNED_VAR=3000

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

# ---------------------------------------------------------------- 1. build --
printf '\n== build ==\n'
zig build -Dswift=false > "$TMP/build.log" 2>&1
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
zig build test -Dswift=false > "$TMP/test.log" 2>&1
test_status=$?
if [ $test_status -ne 0 ]; then
    fail "zig build test -Dswift=false (exit $test_status)"
    grep "^error: '" "$TMP/test.log" | head -10
else
    pass "zig build test -Dswift=false"
fi

# The count, not just the colour. AGENTS.md: check the count before citing a
# green run. `zig build test` prints nothing on success, so ask root.zig.
zig test src/root.zig > "$TMP/count.log" 2>&1
if [ $? -eq 0 ]; then
    printf '  ....  %s\n' "$(tail -1 "$TMP/count.log")"
fi

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
printf '\n== backend agreement ==\n'
disagreements=0
for f in examples/*.cell examples/pairing/*.cell; do
    if $CELL emit --target=llvm "$f" > /dev/null 2>&1; then l=accept; else l=refuse; fi
    if $CELL emit --target=mlir "$f" > /dev/null 2>&1; then m=accept; else m=refuse; fi
    if [ "$l" != "$m" ]; then
        fail "$f: llvm=$l mlir=$m"
        disagreements=$((disagreements + 1))
    fi
done
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
    for f in examples/*.cell examples/pairing/*.cell; do
        n=$(basename "$f" .cell)
        # An emit REFUSAL is designed scalar-first behaviour and stage 4 already
        # pins it. A CRASH is not, so the two are told apart the way
        # .claude/skills/run-cell-lang/driver.sh tells them apart, and only what
        # emitted is lowered.
        if ! $CELL emit --target=mlir "$f" > "$TMP/low_$n.mlir" 2> "$TMP/low_$n.emit"; then
            grep -q 'cannot lower' "$TMP/low_$n.emit" || {
                fail "mlir emit $f (not a 'cannot lower' refusal)"
                sed -n '1,4p' "$TMP/low_$n.emit"
            }
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
    done
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
    run_c_leaks() {
        ex=$1; host=$2; want=$3; note=$4
        $CELL emit "examples/leaks/$ex.cell" > "$TMP/leak_$ex.c" 2>/dev/null \
            || { fail "leaks: C emit $ex"; return; }
        if [ -n "$host" ]; then
            cc -I runtime "$TMP/leak_$ex.c" "$host" runtime/cell_rt.c -o "$TMP/leak_$ex" 2>/dev/null \
                || { fail "leaks: C compile $ex"; return; }
        else
            cc -I runtime "$TMP/leak_$ex.c" runtime/cell_rt.c -o "$TMP/leak_$ex" 2>/dev/null \
                || { fail "leaks: C compile $ex"; return; }
        fi
        got=$(leaks -atExit -- "$TMP/leak_$ex" 2>/dev/null \
            | sed -n 's/^Process [0-9][0-9]*: \([0-9][0-9]*\) leaks for .*/\1/p' | tail -1)
        if [ -z "$got" ]; then
            fail "leaks $ex: could not parse a leak count from 'leaks -atExit' output"
            return
        fi
        if [ "$got" -eq "$want" ]; then
            pass "leaks $ex -> $got leaks (pinned, $note)"
        else
            fail "leaks $ex -> $got leaks, want $want (pinned $note; a DROP means the R11 gap closed and the constant plus docs/OWNERSHIP.md need updating; a RISE, or any leak in a previously clean fixture, means codegen regressed)"
        fi
    }

    run_c_leaks param_never_released "" "$LEAK_PARAM_NEVER_RELEASED" "R11 row 1 @ ${LEAKS_MEASURED_AT}"
    run_c_leaks struct_arc_field "" "$LEAK_STRUCT_ARC_FIELD" "R11 row 2 @ ${LEAKS_MEASURED_AT}"
    run_c_leaks unbound_shared_temp examples/arc_host.c "$LEAK_UNBOUND_SHARED_TEMP" "R11 row 3, CLOSED @ 460b9a3"
    run_c_leaks block_scoped_local "" "$LEAK_BLOCK_SCOPED_LOCAL" "R11 row 4 @ ${LEAKS_MEASURED_AT}"
    run_c_leaks reassigned_var "" "$LEAK_REASSIGNED_VAR" "R11 row 5 @ ${LEAKS_MEASURED_AT}"
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
