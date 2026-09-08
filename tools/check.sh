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
LEAK_UNBOUND_SHARED_TEMP=2998
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
        pipeline=$(sed -n 's|^// lower with: mlir-opt ||p' "$TMP/low_$n.mlir" | head -1)
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
    "$LLVM_BIN/mlir-opt" "$TMP/$ex.mlir" \
        --expand-strided-metadata --finalize-memref-to-llvm --convert-cf-to-llvm \
        --convert-func-to-llvm --convert-arith-to-llvm --reconcile-unrealized-casts \
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
    run_c_leaks unbound_shared_temp examples/arc_host.c "$LEAK_UNBOUND_SHARED_TEMP" "R11 row 3 @ ${LEAKS_MEASURED_AT}"
    run_c_leaks block_scoped_local "" "$LEAK_BLOCK_SCOPED_LOCAL" "R11 row 4 @ ${LEAKS_MEASURED_AT}"
    run_c_leaks reassigned_var "" "$LEAK_REASSIGNED_VAR" "R11 row 5 @ ${LEAKS_MEASURED_AT}"
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
