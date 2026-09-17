#!/bin/sh
# Prints clang's layout and AArch64 placement for representative
# per-instantiation Result structs (docs/superpowers/specs/2026-09-17-
# per-instantiation-results-design.md, "Measured layouts"). Not a gate
# stage: run it by hand when the layout rule in src/cell/abi.zig changes.
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/m.c" <<'EOF'
#include <stdbool.h>
#include <stdint.h>
#include "cell_rt.h"
typedef struct { bool ok; union { int64_t ok; int32_t err; } as; } r_i64_i32;
typedef struct { bool ok; union { bool ok; int32_t err; } as; } r_bool_i32;
typedef struct { bool ok; union { double ok; int64_t err; } as; } r_f64_i64;
typedef struct { bool ok; union { int8_t ok; double err; } as; } r_i8_f64;
typedef struct { bool ok; union { int32_t err; } as; } r_unit_i32;
typedef struct { bool ok; union { bool ok; int64_t err; } as; } r_bool_i64;
typedef struct { bool ok; union { cell_string_t ok; int32_t err; } as; } r_string_i32;
typedef struct { bool ok; union { int64_t ok; cell_string_t err; } as; } r_i64_string;
r_i64_i32 f1(r_i64_i32 a) { return a; }
r_bool_i32 f2(r_bool_i32 a) { return a; }
r_f64_i64 f3(r_f64_i64 a) { return a; }
r_i8_f64 f4(r_i8_f64 a) { return a; }
r_unit_i32 f5(r_unit_i32 a) { return a; }
r_bool_i64 f6(r_bool_i64 a) { return a; }
r_string_i32 f7(r_string_i32 a) { return a; }
r_i64_string f8(r_i64_string a) { return a; }
EOF
cc -S -emit-llvm -O0 -I "$(dirname "$0")/../runtime" -o - "$tmp/m.c" | grep -E '^(%struct|%union|define)'
