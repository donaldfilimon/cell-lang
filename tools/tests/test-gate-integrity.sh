#!/bin/sh
set -u

cd "$(dirname "$0")/../.." || exit 2
repo_dir=$(pwd)
test_tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$test_tmp"' EXIT

CELL_GATE_LIBRARY_ONLY=1 . tools/check.sh
set -e
cd "$repo_dir" || exit 2
TMP=$test_tmp

# Explicit multiline expectations compare exact internal newlines. Ordinary
# EXPECT-OUTPUT retains literal backslashes rather than decoding them.
printf '%s\n' '// EXPECT-OUTPUT-ESCAPED: 7\n8\n16' > "$test_tmp/escaped.cell"
read_output_expectation "$test_tmp/escaped.cell"
[ "$EXPECT_OUTPUT_KIND" = escaped ]
multiline=$(printf '7\n8\n16')
[ "$EXPECT_OUTPUT_VALUE" = "$multiline" ]
fails=0
check_expected_output fixture C "$multiline"
[ "$fails" -eq 0 ]
check_expected_output fixture C '7816' > "$test_tmp/output-mismatch.log"
[ "$fails" -eq 1 ]
grep -q 'declares escaped output' "$test_tmp/output-mismatch.log"
wrong_line=$(printf '7\n9\n16')
check_expected_output fixture LLVM "$wrong_line" > "$test_tmp/output-line-mismatch.log"
[ "$fails" -eq 2 ]
printf '%s\n' '// EXPECT-OUTPUT: 7\n8' > "$test_tmp/verbatim.cell"
read_output_expectation "$test_tmp/verbatim.cell"
[ "$EXPECT_OUTPUT_KIND:$EXPECT_OUTPUT_VALUE" = 'verbatim:7\n8' ]
printf '%s\n' '// EXPECT-OUTPUT-ESCAPED: 7\t8' > "$test_tmp/malformed.cell"
if read_output_expectation "$test_tmp/malformed.cell" 2> "$test_tmp/malformed.log"; then exit 1; fi
grep -q 'only' "$test_tmp/malformed.log"
printf '%s\n' '// EXPECT-OUTPUT-ESCAPED: 7\' > "$test_tmp/dangling.cell"
if read_output_expectation "$test_tmp/dangling.cell" 2> "$test_tmp/dangling.log"; then exit 1; fi
printf '%s\n' '// EXPECT-OUTPUT-ESCAPED:7' > "$test_tmp/spacing.cell"
if read_output_expectation "$test_tmp/spacing.cell" 2> "$test_tmp/spacing.log"; then exit 1; fi
for header in '// EXPECT-OUTPUT 7' '// EXPECT-OUTPUT-ESCAPED 7\n8' \
    '// EXPECT-OUTPUT' '// EXPECT-OUTPUT-ESCAPED' \
    '//EXPECT-OUTPUT: 7' '//  EXPECT-OUTPUT-ESCAPED: 7' \
    ' // EXPECT-OUTPUT: 7' '// EXPECT-OUTPUT-ESCAPED : 7'; do
    printf '%s\n' "$header" > "$test_tmp/malformed-header.cell"
    if read_output_expectation "$test_tmp/malformed-header.cell" 2> "$test_tmp/malformed-header.log"; then exit 1; fi
    grep -q 'expected // EXPECT-OUTPUT' "$test_tmp/malformed-header.log"
done
# A different comment key and a prose mention are not expectation declarations.
printf '%s\n' '// EXPECT-OUTPUT-NOTE: prose' '// This documents EXPECT-OUTPUT: 7' > "$test_tmp/unrelated.cell"
read_output_expectation "$test_tmp/unrelated.cell"
[ "$EXPECT_OUTPUT_KIND" = none ]
printf '%s\n' '// EXPECT-OUTPUT: 7' '// EXPECT-OUTPUT-ESCAPED: 7' > "$test_tmp/conflicting.cell"
if read_output_expectation "$test_tmp/conflicting.cell" 2> "$test_tmp/conflicting.log"; then exit 1; fi
grep -q 'duplicate or conflicting' "$test_tmp/conflicting.log"
printf '%s\n' '// EXPECT-OUTPUT-ESCAPED: 7' '// EXPECT-OUTPUT-ESCAPED: 7' > "$test_tmp/duplicate.cell"
if read_output_expectation "$test_tmp/duplicate.cell" 2> "$test_tmp/duplicate.log"; then exit 1; fi
awk 'BEGIN { printf "// EXPECT-OUTPUT-ESCAPED: "; for (i = 0; i < 4097; i++) printf "x"; print "" }' > "$test_tmp/oversize.cell"
if read_output_expectation "$test_tmp/oversize.cell" 2> "$test_tmp/oversize.log"; then exit 1; fi
grep -q 'exceeds 4096' "$test_tmp/oversize.log"
printf '%s\n' '// EXPECT-OUTPUT-ESCAPED: ' > "$test_tmp/empty.cell"
read_output_expectation "$test_tmp/empty.cell"
[ "$EXPECT_OUTPUT_KIND:$EXPECT_OUTPUT_VALUE" = escaped: ]
fails=0
check_expected_output fixture C ''
[ "$fails" -eq 0 ]
printf '%s\n' 'pub fn main() {}' > "$test_tmp/absent.cell"
read_output_expectation "$test_tmp/absent.cell"
[ "$EXPECT_OUTPUT_KIND" = none ]

# Prove this harness itself fails closed before trusting its assertions.
if sh -ec 'false; printf "unreachable\n"'; then
    printf 'assertion harness did not stop on failure\n' >&2
    exit 1
fi

mkdir -p "$test_tmp/bin"
cat > "$test_tmp/bin/cell" <<'FAKE_CELL'
#!/bin/sh
case "$FAKE_RESULT" in
    accept) printf '// lower with: mlir-opt --fake\n'; exit 0 ;;
    refuse) printf 'error: cannot lower to MLIR\n' >&2; exit 1 ;;
    misleading) printf 'error: cannot lower after internal crash\n' >&2; exit 134 ;;
    other) printf 'error: parser exploded\n' >&2; exit 1 ;;
esac
FAKE_CELL
chmod +x "$test_tmp/bin/cell"
CELL=$test_tmp/bin/cell

for pair in 'accept accept:0' 'refuse refuse:1' 'misleading error:134' 'other error:1'; do
    set -- $pair
    FAKE_RESULT=$1; export FAKE_RESULT
    backend_emit_verdict mlir fixture "$test_tmp/out" "$test_tmp/err"
    [ "$BACKEND_VERDICT:$BACKEND_STATUS" = "$2" ]
done

tag_a=$(artifact_tag examples/a/b.cell)
tag_b=$(artifact_tag examples/a_b.cell)
[ "$tag_a" != "$tag_b" ]

accepted_examples | grep -qx 'examples/signatures/arc_string_return.cell'
accepted_examples | grep -qx 'examples/modules/main.cell'
accepted_examples | grep -qx 'examples/modules/geo.cell'
accepted_examples | grep -qx 'examples/modules/grid.cell'

cat > "$test_tmp/bin/mlir-opt" <<'FAKE_OPT'
#!/bin/sh
[ "${FAKE_OPT_FAIL:-0}" = 0 ] || exit 9
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then cp /dev/null "$2"; exit 0; fi
    shift
done
exit 2
FAKE_OPT
cat > "$test_tmp/bin/mlir-translate" <<'FAKE_TRANSLATE'
#!/bin/sh
[ "${FAKE_TRANSLATE_FAIL:-0}" = 0 ] || exit 7
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then printf '; fake llvm\n' > "$2"; exit 0; fi
    shift
done
exit 2
FAKE_TRANSLATE
chmod +x "$test_tmp/bin/mlir-opt" "$test_tmp/bin/mlir-translate"
LLVM_BIN=$test_tmp/bin
: > "$test_tmp/in.mlir"
FAKE_OPT_FAIL=0 FAKE_TRANSLATE_FAIL=0; export FAKE_OPT_FAIL FAKE_TRANSLATE_FAIL
mlir_to_llvm "$test_tmp/in.mlir" '--fake' "$test_tmp/low" "$test_tmp/out.ll" "$test_tmp/lower"
[ "$MLIR_LOWER_FAILURE" = none ]
FAKE_OPT_FAIL=1; export FAKE_OPT_FAIL
if mlir_to_llvm "$test_tmp/in.mlir" '--fake' "$test_tmp/low" "$test_tmp/out.ll" "$test_tmp/lower"; then exit 1; fi
[ "$MLIR_LOWER_FAILURE" = opt ]
FAKE_OPT_FAIL=0 FAKE_TRANSLATE_FAIL=1; export FAKE_OPT_FAIL FAKE_TRANSLATE_FAIL
if mlir_to_llvm "$test_tmp/in.mlir" '--fake' "$test_tmp/low" "$test_tmp/out.ll" "$test_tmp/lower"; then exit 1; fi
[ "$MLIR_LOWER_FAILURE" = translate ]

# Stage 10 coverage classification: crashes and post-emit failures must fail
# and can never be described as C-only. Only two explicit refusals qualify.
signature_coverage_verdict error refuse unavailable
[ "$SIG_COVERAGE_FAILURE:$SIG_C_ONLY" = yes:no ]
signature_coverage_verdict refuse accept opt-failed
[ "$SIG_COVERAGE_FAILURE:$SIG_C_ONLY" = yes:no ]
signature_coverage_verdict refuse accept translate-failed
[ "$SIG_COVERAGE_FAILURE:$SIG_C_ONLY" = yes:no ]
signature_coverage_verdict refuse refuse unavailable
[ "$SIG_COVERAGE_FAILURE:$SIG_C_ONLY" = no:yes ]

cat > "$test_tmp/bin/zig" <<'FAKE_ZIG'
#!/bin/sh
printf 'injected count failure\n' >&2
exit 23
FAKE_ZIG
chmod +x "$test_tmp/bin/zig"
ZIG=$test_tmp/bin/zig
fails=0
collect_root_test_count "$test_tmp/count.log" > "$test_tmp/count.out"
[ "$fails" -eq 1 ]
grep -q 'exit 23' "$test_tmp/count.out"
# New clang emits dead_on_return on ABI-indirect by-value aggregate
# parameters. Measure a real C declaration, then prove only that known hint
# is neutral: pointer versus scalar must still disagree and unknown words
# must still reach the unparseable-type failure path.
write_signature_canonicalizer "$test_tmp/sig.awk"
cat > "$test_tmp/signature.c" <<'C_SIGNATURE'
typedef struct { const void *ptr; unsigned long len; unsigned long cap; } Buffer;
long cell_probe(Buffer value) { return value.len; }
C_SIGNATURE
cc -std=c11 -S -emit-llvm "$test_tmp/signature.c" -o "$test_tmp/signature.ll"
awk -f "$test_tmp/sig.awk" "$test_tmp/signature.ll" > "$test_tmp/clang.sig"
printf 'cell_probe\ti64|ptr\n' > "$test_tmp/expected.sig"
cmp "$test_tmp/clang.sig" "$test_tmp/expected.sig"

# Synthetic input ensures coverage even on hosts whose clang predates the
# attribute; the installed clang's real output is checked immediately above.
printf 'declare i64 @cell_probe(ptr dead_on_return %%value)\n' > "$test_tmp/known.ll"
awk -f "$test_tmp/sig.awk" "$test_tmp/known.ll" > "$test_tmp/known.sig"
cmp "$test_tmp/known.sig" "$test_tmp/expected.sig"
printf 'declare i64 @cell_probe(ptr future_unknown_hint %%value)\n' > "$test_tmp/unknown.ll"
awk -f "$test_tmp/sig.awk" "$test_tmp/unknown.ll" > "$test_tmp/unknown.sig"
grep -q 'UNPARSEABLE<ptr future_unknown_hint>' "$test_tmp/unknown.sig"
printf 'declare i64 @cell_probe(i64 %%value)\n' > "$test_tmp/mismatch.ll"
awk -f "$test_tmp/sig.awk" "$test_tmp/mismatch.ll" > "$test_tmp/mismatch.sig"

SIGTAB=$(printf '\t')
SIG_DISCLOSED=''
sig_compared=0; sig_disagree=0; sig_undisclosed=0; fails=0
sig_join fixture LLVM "$test_tmp/expected.sig" "$test_tmp/known.sig"
[ "$fails:$sig_compared:$sig_disagree" = 0:1:0 ]
sig_join fixture LLVM "$test_tmp/expected.sig" "$test_tmp/mismatch.sig" > "$test_tmp/mismatch.out"
[ "$fails:$sig_compared:$sig_disagree:$sig_undisclosed" = 1:2:1:1 ]
grep -q 'DIFFERENT calling convention' "$test_tmp/mismatch.out"
sig_join fixture LLVM "$test_tmp/unknown.sig" "$test_tmp/unknown.sig" > "$test_tmp/unknown.out"
[ "$fails:$sig_compared" = 2:3 ]
grep -q 'could not parse a type' "$test_tmp/unknown.out"
# Exercise the linkage verdict with real independently compiled hosts. The
# private definition is static; its public wrapper calls it successfully.
cat > "$test_tmp/linkage.c" <<'LINKAGE_C'
#include <stdint.h>
typedef struct { int64_t x; } cell_geo_Point;
static int64_t cell_geo_twice(int64_t value) { return value * 2; }
int64_t cell_geo_area(cell_geo_Point point) { return cell_geo_twice(point.x); }
LINKAGE_C
cc -std=c11 -Wall -Wextra -Werror -c "$test_tmp/linkage.c" -o "$test_tmp/linkage.o"
# Stage 10 must retain static prototypes in its address-taking probe and
# compare their signatures exactly despite the new internal linkage.
printf 'static __attribute__((unused)) int64_t cell_geo_twice(int64_t value);\n' > "$test_tmp/private_prototype.c"
sed -n 's/^[A-Za-z_].* \**\(cell_[A-Za-z0-9_]*\)(.*);$/  (void *)\&\1,/p' "$test_tmp/private_prototype.c" > "$test_tmp/private_probe.txt"
grep -q '&cell_geo_twice,' "$test_tmp/private_probe.txt"
cc -std=c11 -S -emit-llvm "$test_tmp/linkage.c" -o "$test_tmp/linkage.ll"
awk -f "$test_tmp/sig.awk" "$test_tmp/linkage.ll" > "$test_tmp/linkage.sig"
printf 'cell_geo_twice\ti64|i64\n' > "$test_tmp/private_expected.sig"
grep '^cell_geo_twice' "$test_tmp/linkage.sig" > "$test_tmp/private_actual.sig"
cmp "$test_tmp/private_expected.sig" "$test_tmp/private_actual.sig"
cc -std=c11 -Wall -Wextra -Werror -c examples/modules/public_link_host.c -o "$test_tmp/public_host.o"
cc -std=c11 -Wall -Wextra -Werror -c examples/modules/private_link_host.c -o "$test_tmp/private_host.o"
cc -I runtime -c runtime/cell_rt.c -o "$TMP/rt.o"
fails=0
module_private_link_verdict "$test_tmp/linkage.o" "$test_tmp/public_host.o" "$test_tmp/private_host.o" test > "$test_tmp/linkage.out"
[ "$fails" -eq 0 ]
grep -q 'public cell_geo_area links and returns 42' "$test_tmp/linkage.out"
grep -q 'private cell_geo_twice refuses external linkage' "$test_tmp/linkage.out"

# An unrelated undefined reference must fail, never count as private linkage.
cat > "$test_tmp/unrelated.c" <<'UNRELATED_C'
extern int unrelated_missing_function(void);
int main(void) { return unrelated_missing_function(); }
UNRELATED_C
cc -c "$test_tmp/unrelated.c" -o "$test_tmp/unrelated.o"
module_private_link_verdict "$test_tmp/linkage.o" "$test_tmp/public_host.o" "$test_tmp/unrelated.o" unrelated > "$test_tmp/unrelated.out"
[ "$fails" -eq 1 ]
grep -q 'reason other than undefined cell_geo_twice' "$test_tmp/unrelated.out"

# If privacy regresses and both symbols become external, the negative probe
# must fail the gate even though its executable computes the right answer.
sed 's/static int64_t/int64_t/' "$test_tmp/linkage.c" > "$test_tmp/exposed.c"
cc -c "$test_tmp/exposed.c" -o "$test_tmp/exposed.o"
module_private_link_verdict "$test_tmp/exposed.o" "$test_tmp/public_host.o" "$test_tmp/private_host.o" exposed > "$test_tmp/exposed.out"
[ "$fails" -eq 2 ]
grep -q 'private cell_geo_twice is externally linkable' "$test_tmp/exposed.out"
printf 'gate integrity helpers: ok\n'
