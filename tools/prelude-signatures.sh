#!/bin/sh
# Print every prototype the C backend emits for stdlib/prelude.cell, one per
# line, sorted. runtime/cell_rt.h must contain each of these lines verbatim
# for a program calling the prelude to link; gate stage 13 checks that.
# Usage: tools/prelude-signatures.sh ./zig-out/bin/cell
cell=${1:?cell binary}
cd "$(dirname "$0")/.." || exit 2
"$cell" emit stdlib/prelude.cell > /private/tmp/prelude-emit.c 2>/private/tmp/prelude-emit.err || {
    cat /private/tmp/prelude-emit.err >&2; exit 2; }
# A prototype is a line that ends in `);` and starts with a type, not a brace
# or a comment. `cell_cxx_probe`/`cell_swift_probe` are group 1 probes and
# stay in the list on purpose: they must match too.
grep -E '^[a-z_0-9 *]+ \*?cell_[a-z_0-9]+\(.*\);$' /private/tmp/prelude-emit.c | sort
