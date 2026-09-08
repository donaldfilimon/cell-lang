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
printf 'gate integrity helpers: ok\n'
