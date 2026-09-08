#!/bin/bash
# A differential HUNTING tool, not a gate stage. Generates small Cell programs
# across ownership mode x type x position and reports two things the gate's own
# stages cannot see for programs nobody has written down as examples:
#
#   1. a VERDICT SPLIT between the LLVM and MLIR backends;
#   2. a program `cell check` accepts whose emitted C does not compile.
#
# WHY IT EXISTS. Every memory-safety defect found in this project, eleven at the
# time of writing, was found by review and none by the gate. The gate checks a
# corpus, and a corpus can only exercise shapes somebody thought to write: no
# file in it returned a `String` from a body until 2026-09-08, which is exactly
# why an eight-position conversion defect survived. This sweeps the shapes
# nobody wrote.
#
# It is deliberately NOT wired into tools/check.sh. It generates programs rather
# than reading a fixed corpus, so a change in what the language accepts moves
# its output for reasons that are not regressions, and a gate stage that cries
# wolf gets disabled. Run it by hand when changing ownership lowering.
#
# Usage: tools/sweep-backends.sh [tree]   (default: this checkout)
#
# RESULT ON 2026-09-08 at 8eb1a21, 78 programs probed and 5 reported: no new
# defect. Everything it
# reported belonged to ONE disclosed gap, R10's unimplemented move-into-`arc`
# in the front end, where `let arc x = <owned place>` and the assignment form
# of the same are stopped only by a C type error. That negative result is the
# point of recording it: the sweep is evidence about where the remaining holes
# are not.
set -u
cd "${1:-$(dirname "$0")/..}" || exit 2
CELL=./zig-out/bin/cell
[ -x "$CELL" ] || { echo "sweep: no $CELL (build first)"; exit 2; }
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
n=0; issues=0
report() { printf '%-46s %s\n' "$1" "$2"; issues=$((issues + 1)); }

probe() {
    n=$((n + 1))
    printf '%s\n' "$2" > "$T/p.cell"
    # A front-end refusal is a fine answer; this tool is about what gets past it.
    $CELL check "$T/p.cell" >/dev/null 2>&1 || return 0
    for t in c llvm mlir; do
        $CELL emit --target=$t "$T/p.cell" > "$T/o.$t" 2>/dev/null
        eval "v_$t=$?"
    done
    [ "$v_llvm" -ne "$v_mlir" ] && report "$1" "VERDICT SPLIT llvm=$v_llvm mlir=$v_mlir"
    if [ "$v_c" -eq 0 ] && ! cc -std=c11 -Wall -Wextra -I runtime -c "$T/o.c" -o "$T/o.o" 2>"$T/cc.err"; then
        report "$1" "C UNCOMPILABLE: $(grep -m1 'error:' "$T/cc.err" | sed 's/.*error: //' | cut -c1-40)"
    fi
}

for mode in owned shared exclusive copy arc; do
    for ty in String "[Int]" "Int?" Int; do
        probe "param $mode $ty" "pub fn f($mode v: $ty) -> Int { return 1 }"
        probe "let $mode $ty = param" "pub fn f(owned v: $ty) { let $mode x: $ty = v }"
    done
done
for dst in owned copy arc; do
    for src in owned shared exclusive copy; do
        probe "assign $dst <- $src String" "pub fn mk() -> String;
pub fn f($src v: String) { var $dst x: String = mk()
  x = v }"
    done
done
for pm in owned shared exclusive copy arc; do
    for am in owned shared exclusive copy; do
        probe "call $pm <- $am String" "pub fn g($pm s: String);
pub fn f($am v: String) { g($am v) }"
    done
done
for ty in String "[Int]" "Int?"; do
    probe "return owned $ty" "pub fn f(owned v: $ty) -> $ty { return v }"
    probe "field of $ty" "pub struct B { f: $ty }
pub fn f(owned b: B) -> Int { return 1 }"
done

echo "---"
echo "$n programs probed, $issues issue(s)"
[ $issues -eq 0 ] && exit 0 || exit 1
