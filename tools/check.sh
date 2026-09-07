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
#   5. execution        emitted code is compiled, linked against the real
#                       runtime, RUN, and its answer checked. Every backend
#                       defect found in this repo that mattered was invisible
#                       in the IR and visible only here.
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

set -u

cd "$(dirname "$0")/.." || exit 2

LLVM_BIN=${LLVM_BIN:-/opt/homebrew/opt/llvm/bin}
CELL=./zig-out/bin/cell
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

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

[ $fails -eq 0 ] && pass "all four corpus contracts hold"

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

# ------------------------------------------------------------- 5. execution --
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
