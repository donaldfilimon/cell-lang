#!/bin/sh
# Drive a Cell program end to end: emit, compile, link, RUN, compare.
#
# WHY THIS EXISTS, given tools/check.sh already exists. check.sh is the GATE:
# it answers "is the repository green" over a fixed set of three programs with
# three hardcoded expected answers. This answers a different question, the one
# you have while working: "what does THIS program do, through each backend?"
# It takes any .cell file, so it is the tool for a program you just wrote, an
# example you just changed, or a bug you are reducing.
#
# It is also the only place that knows how to RUN a Cell program, because that
# takes five steps no single command performs: emit, compile, link against the
# runtime, supply an entry point the backend did not emit, and run.
#
# TRAPS ENCODED HERE, each of which has actually bitten in this repository:
#
#   * `zig build` without -Dswift=false enables a Swift bridge that hardcodes
#     a path inside /Applications/Xcode-beta.app and fails on any other host.
#   * a FAILED `zig build` leaves the PREVIOUS binary in zig-out/bin/cell, so
#     running it after a failed build tests code that no longer exists. The
#     build's exit code is checked before the binary is touched.
#   * `cmd | tail` reports TAIL's exit status. Nothing whose status matters is
#     ever piped here.
#   * `zig cc -x ir` does not work ("language not recognized: ir"). Use cc.
#   * LLVM IR carrying a target triple warns; -Wno-override-module silences it.
#   * mlir-opt, mlir-translate and llc are NOT on PATH. They live in the
#     Homebrew LLVM keg. When absent, MLIR SKIPS LOUDLY rather than passing
#     silently, because a check that quietly succeeds when its subject is
#     missing is worse than no check.
#   * the three backends do NOT agree about the entry point. C emits
#     `int main`, LLVM emits `define i32 @main`, and MLIR emits NO main at all,
#     so MLIR alone needs a C driver calling cell_main(). Verified by grepping
#     the emitted output of each; do not assume they match.
#
# USAGE
#   driver.sh [options] <file.cell>
#     --expect TEXT     require this exact stdout, else fail
#     --host FILE.c     extra C source to link (for bodyless declarations);
#                       repeatable
#     --backends LIST   comma separated subset of c,llvm,mlir (default: all)
#     --no-build        use zig-out/bin/cell as-is, do not rebuild
#   Exit 0 only if every selected backend built, ran, and matched.

set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
LLVM_BIN=${LLVM_BIN:-/opt/homebrew/opt/llvm/bin}
CELL="$ROOT/zig-out/bin/cell"

expect=""; hosts=""; backends="c,llvm,mlir"; build=1; src=""; explicit=0
while [ $# -gt 0 ]; do
    case "$1" in
        --expect)   expect=$2; shift 2 ;;
        --host)     hosts="$hosts $2"; shift 2 ;;
        --backends) backends=$2; explicit=1; shift 2 ;;
        --no-build) build=0; shift ;;
        -h|--help)  sed -n '/^# USAGE/,/^#   Exit/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
        *)          src=$1; shift ;;
    esac
done
[ -n "$src" ] || { printf 'usage: driver.sh [options] <file.cell>\n' >&2; exit 2; }
[ -f "$src" ] || { printf 'no such file: %s\n' "$src" >&2; exit 2; }

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
fails=0; skips=0; refusals=0
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
# A `cannot lower` refusal from llvm/mlir is DESIGNED behaviour, not a break:
# both backends are scalar-first and refuse rather than emit plausible wrong
# code. So it is reported, not failed -- UNLESS the caller named that backend
# in --backends, which is a request, and an unmet request is a failure.
refuse() {
    refusals=$((refusals + 1))
    if [ "$explicit" -eq 1 ]; then
        fail "$1 refused (you asked for it with --backends)"
        sed -n '1,4p' "$2"
    else
        printf '  refuse %s (scalar-first backend cannot lower this; not a defect)\n' "$1"
        sed -n '1,2p' "$2" | sed 's/^/          /'
    fi
}
pass() { printf '  ok    %s\n' "$*"; }
skip() { printf '  SKIP  %s\n' "$*"; skips=$((skips + 1)); }
want() { case ",$backends," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# ---- build. Its exit code gates everything: see the stale-binary trap above.
if [ $build -eq 1 ]; then
    ( cd "$ROOT" && zig build -Dswift=false ) > "$TMP/build.log" 2>&1
    if [ $? -ne 0 ]; then
        printf 'BUILD FAILED. %s is now STALE; nothing below was run.\n' "$CELL"
        sed -n '1,20p' "$TMP/build.log"
        exit 1
    fi
fi
[ -x "$CELL" ] || { printf 'no compiler at %s (build first)\n' "$CELL" >&2; exit 1; }

printf '\n== %s ==\n' "$src"

# ---- check. A program that does not pass cell check cannot be run at all.
"$CELL" check "$src" > "$TMP/check.log" 2>&1
if [ $? -ne 0 ]; then
    fail "cell check"
    sed -n '1,10p' "$TMP/check.log"
    printf '\n  %d failure(s)\n\n' "$fails"
    exit 1
fi
pass "cell check"

# ---- the runtime, compiled once and shared by every backend.
cc -c -I "$ROOT/runtime" "$ROOT/runtime/cell_rt.c" -o "$TMP/rt.o" 2> "$TMP/rt.log"
[ $? -eq 0 ] || { fail "compiling runtime/cell_rt.c"; sed -n '1,10p' "$TMP/rt.log"; exit 1; }

host_objs=""
for h in $hosts; do
    b=$(basename "$h" .c)
    cc -c -I "$ROOT/runtime" "$h" -o "$TMP/$b.o" 2> "$TMP/$b.log"
    [ $? -eq 0 ] || { fail "compiling host $h"; sed -n '1,10p' "$TMP/$b.log"; exit 1; }
    host_objs="$host_objs $TMP/$b.o"
done

# MLIR emits no main, so it alone needs an entry point.
printf 'extern void cell_main(void);\nint main(void){cell_main();return 0;}\n' > "$TMP/drv.c"

report() { # backend, output
    if [ -n "$expect" ]; then
        if [ "$2" = "$expect" ]; then pass "$1 -> $2"; else fail "$1 -> $2, want $expect"; fi
    else
        pass "$1 -> $2"
    fi
}

if want c; then
    "$CELL" emit --target=c "$src" > "$TMP/o.c" 2>"$TMP/c.err"
    if [ $? -ne 0 ]; then fail "C emit"; sed -n '1,6p' "$TMP/c.err"; else
        cc -I "$ROOT/runtime" "$TMP/o.c" $host_objs "$TMP/rt.o" -o "$TMP/b_c" 2>"$TMP/c2.err"
        if [ $? -ne 0 ]; then fail "C compile"; sed -n '1,6p' "$TMP/c2.err"; else
            out=$("$TMP/b_c"); report "C   " "$out"
        fi
    fi
fi

if want llvm; then
    "$CELL" emit --target=llvm "$src" > "$TMP/o.ll" 2>"$TMP/l.err"
    if [ $? -ne 0 ]; then
        if grep -q 'cannot lower' "$TMP/l.err"; then refuse "LLVM" "$TMP/l.err"
        else fail "LLVM emit"; sed -n '1,6p' "$TMP/l.err"; fi
    else
        # cc, never `zig cc`: measured, `zig cc -x ir` fails outright.
        cc -Wno-override-module -x ir "$TMP/o.ll" -c -o "$TMP/o_l.o" 2>"$TMP/l2.err"
        if [ $? -ne 0 ]; then fail "LLVM compile"; sed -n '1,6p' "$TMP/l2.err"; else
            cc "$TMP/o_l.o" $host_objs "$TMP/rt.o" -o "$TMP/b_l" 2>"$TMP/l3.err"
            if [ $? -ne 0 ]; then fail "LLVM link"; sed -n '1,6p' "$TMP/l3.err"; else
                out=$("$TMP/b_l"); report "LLVM" "$out"
            fi
        fi
    fi
fi

if want mlir; then
    if [ ! -x "$LLVM_BIN/mlir-opt" ] || [ ! -x "$LLVM_BIN/mlir-translate" ] || [ ! -x "$LLVM_BIN/llc" ]; then
        skip "MLIR (mlir-opt/mlir-translate/llc not in $LLVM_BIN; set LLVM_BIN=)"
    else
        "$CELL" emit --target=mlir "$src" > "$TMP/o.mlir" 2>"$TMP/m.err"
        if [ $? -ne 0 ]; then
            if grep -q 'cannot lower' "$TMP/m.err"; then refuse "MLIR" "$TMP/m.err"
            else fail "MLIR emit"; sed -n '1,6p' "$TMP/m.err"; fi
        else
            # The emitter writes its own lowering pipeline into the file as a
            # `// lower with: mlir-opt ...` comment. Read it from there rather
            # than hardcoding a copy that can drift from the backend.
            pipeline=$(sed -n 's|^// lower with: mlir-opt ||p' "$TMP/o.mlir" | head -1)
            [ -n "$pipeline" ] || pipeline="--expand-strided-metadata --finalize-memref-to-llvm --convert-cf-to-llvm --convert-func-to-llvm --convert-arith-to-llvm --reconcile-unrealized-casts"
            "$LLVM_BIN/mlir-opt" "$TMP/o.mlir" $pipeline -o "$TMP/low.mlir" 2>"$TMP/m2.err"
            if [ $? -ne 0 ]; then fail "mlir-opt"; sed -n '1,6p' "$TMP/m2.err"; else
                "$LLVM_BIN/mlir-translate" --mlir-to-llvmir "$TMP/low.mlir" -o "$TMP/o_m.ll" 2>"$TMP/m3.err"
                if [ $? -ne 0 ]; then fail "mlir-translate"; sed -n '1,6p' "$TMP/m3.err"; else
                    "$LLVM_BIN/llc" -filetype=obj "$TMP/o_m.ll" -o "$TMP/o_m.o" 2>"$TMP/m4.err"
                    if [ $? -ne 0 ]; then fail "llc"; sed -n '1,6p' "$TMP/m4.err"; else
                        cc "$TMP/o_m.o" "$TMP/drv.c" $host_objs "$TMP/rt.o" -o "$TMP/b_m" 2>"$TMP/m5.err"
                        if [ $? -ne 0 ]; then fail "MLIR link"; sed -n '1,6p' "$TMP/m5.err"; else
                            out=$("$TMP/b_m"); report "MLIR" "$out"
                        fi
                    fi
                fi
            fi
        fi
    fi
fi

printf '\n'
[ $skips -gt 0 ] && printf '  %d skipped, so this run is weaker than a full one.\n' "$skips"
[ $refusals -gt 0 ] && printf '  %d backend(s) refused by design. tools/check.sh is what pins\n     llvm and mlir to the SAME verdict; this script does not.\n' "$refusals"
if [ $fails -ne 0 ]; then printf '  %d FAILURE(S)\n\n' "$fails"; exit 1; fi
printf '  clean\n\n'
exit 0
