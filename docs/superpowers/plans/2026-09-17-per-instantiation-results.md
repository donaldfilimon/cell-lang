# Per-instantiation Result Layouts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single 24-byte `cell_result_t` with one exact C struct per scalar `Result<T, E>` pair, carried identically by the C, LLVM and MLIR backends, so `E` is no longer narrowed to `int32_t` and scalar Results travel in registers.

**Architecture:**
- **Runtime:** `runtime/cell_rt.h` predefines every in-scope instance with an X-macro, the way it already predefines the scalar optionals.
- **Layout table:** `abi.zig` owns the table of members and the layout rule.
- **Backends:** the C backend names the instance from the Cell type names. The IR backends spell the struct structurally from `abi.resultShape`.
- **Legacy names:** they stay in the header for one version. An out-of-scope pair such as `Result<Int, String>` keeps its old pass-through spelling in C only.

**Tech Stack:** Zig master (`zig build -Dswift=false`), C11 runtime, LLVM IR text, MLIR llvm dialect, clang for measurement.

**Spec:** `docs/superpowers/specs/2026-09-17-per-instantiation-results-design.md` (approved by Donald 2026-09-17 for plan and build).

## Global Constraints

- Every command passes `-Dswift=false`. The gate is `tools/check.sh`, and its verdict line must read `clean`.
- Read exit codes from the command itself, never through a pipe (`cmd > log 2>&1; echo "EXIT $?"`).
- Instance names are `cell_res_<ok>_<err>`, built from these slugs:
  - `i64`, `i32`, `i16`, `i8`, `u64`, `u32`, `u16`, `u8`, `f64`, `f32`;
  - `bool`, `byte`, and `unit` (the `Ok` side only).
- A payload-free enum takes the slug `i32` and the C type `int32_t`.
- `CELL_RT_ABI_VERSION` is `2`. `cell_rt_version()` returns `cell-rt 0.3.0 (c11, atomic arc)`.
- Constructors zero the whole struct first.
- No em dashes in comments, docs or commit messages.
- `--test-filter` fails toward a false green. Always confirm that the named test appears in the output.

## Deviations from the spec (decided while planning; smart defaults per Donald)

1. **Predefined instances, no codegen pass.** Every in-scope pair is predefined in `cell_rt.h` (12 scalar `Ok` sides plus unit, × 12 `Err` sides = 156 instances, through nested X-macros), instead of an `emitResultInstances` pass in codegen.
   - A pass would only see `let` annotations at the top level of a body, as `collectOptionalsInStmts` does today. A nested `let r: Result<Int8, Int8>` would then miss its instance.
   - Predefinition cannot miss an instance, and it gives C hosts every instance too.
2. **Structural LLVM types.** LLVM uses the structural type `{ i8, { <member> } }` rather than named `%cell_res_*` types.
   - No module-wide type collection is needed, and it matches MLIR's structural spelling.
   - Stage 10 resolves names to structure anyway, and every in-scope instance is register-placed, so no signature text contains it.
3. **Out-of-scope pairs.**
   - They keep lowering to the deprecated `cell_result_t` in C, as a pass-through. Examples are `Result<Int, String>`, which `cell check` accepts in a signature today, pinned by the codegen test "TYPE-06: a Result type lowers ...".
   - A payload binding on such a pair is emitted as the undeclared identifier `cell_res_unsupported_payload`, so cc refuses it.
   - The IR backends keep refusing these pairs.
4. **Unit `Ok`.** Instances, types and tag matching exist for a unit `T`. `Ok` construction for it cannot be written, because Cell has no unit value expression. Binding an `Ok(v)` payload of a unit `T` is refused in the IR backends.
5. **`Err` admission message.** typecheck now refuses a non-scalar, non-enum `Err` payload with the existing "optional/Result payloads other than scalar primitives are not implemented" diagnostic. That changes one pinned message: "Ok and Err are checked against the declared Result", diag 0, same position 5:35.

---

### Task 1: Runtime instances, version 2, and the measured layout table

**Files:**
- Modify: `runtime/cell_rt.h` (the Result section, after `CELL_DEFINE_OPTIONAL(cell_opt_ptr, void *)`, and the ABI comment near line 99)
- Modify: `runtime/cell_rt.c:23` (version string)
- Modify: `runtime/tests/test_cell_rt.c` (`test_result`, about lines 603-651)
- Create: `tools/measure-result-layouts.sh`

**Interfaces:**
- Produces: `cell_res_<ok>_<err>_t` with its constructors.
  - Each type has fields `ok` and `as.ok` / `as.err`.
  - Constructors are `cell_res_<ok>_<err>_ok(T)` and `cell_res_<ok>_<err>_err(E)`.
  - For a unit `T` they are `cell_res_unit_<err>_ok(void)` and `cell_res_unit_<err>_err(E)`.
  - `CELL_RT_ABI_VERSION` is `2`.

- [ ] **Step 1: Write the measurement script and confirm the spec's table**

Create `tools/measure-result-layouts.sh`:

```sh
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
typedef struct { bool ok; union { int64_t ok; int32_t err; } as; } r_i64_i32;
typedef struct { bool ok; union { bool ok; int32_t err; } as; } r_bool_i32;
typedef struct { bool ok; union { double ok; int64_t err; } as; } r_f64_i64;
typedef struct { bool ok; union { int8_t ok; double err; } as; } r_i8_f64;
typedef struct { bool ok; union { int32_t err; } as; } r_unit_i32;
typedef struct { bool ok; union { bool ok; int64_t err; } as; } r_bool_i64;
r_i64_i32 f1(r_i64_i32 a) { return a; }
r_bool_i32 f2(r_bool_i32 a) { return a; }
r_f64_i64 f3(r_f64_i64 a) { return a; }
r_i8_f64 f4(r_i8_f64 a) { return a; }
r_unit_i32 f5(r_unit_i32 a) { return a; }
r_bool_i64 f6(r_bool_i64 a) { return a; }
EOF
cc -S -emit-llvm -O0 -o - "$tmp/m.c" | grep -E '^(%struct|%union|define)'
```

Run: `sh tools/measure-result-layouts.sh > /tmp/claude-501/layouts.txt 2>&1; echo "EXIT $?"; cat /tmp/claude-501/layouts.txt`

Expected output, `EXIT 0`, and lines showing:
- `%struct.r_i64_i32 = type { i8, %union.anon }` with the union `{ i64 }`;
- `define [2 x i64] @f1([2 x i64] %…)`;
- `define i64 @f2(i64 %…)`;
- `@f3` and `@f4` with `[2 x i64]` (unions `{ double }`);
- `define i64 @f5(i64`;
- `define [2 x i64] @f6([2 x i64]`.

**If any row differs, stop and report.** The layout rule in Task 2 depends on these rows.

- [ ] **Step 2: Write the failing runtime test**

In `runtime/tests/test_cell_rt.c`, replace the whole body of `static void test_result(void)`, from the line after its `{` to its closing `}`, with:

```c
    /* Per-instantiation Results (CELL_RT_ABI_VERSION 2). Every payload is
     * stored in its own C type: no widening, no narrowing of E. */
    CHECK(CELL_RT_ABI_VERSION == 2);

    cell_res_i64_i32_t ok = cell_res_i64_i32_ok(INT64_MIN);
    CHECK(ok.ok);
    CHECK(ok.as.ok == INT64_MIN);
    cell_res_i64_i32_t err = cell_res_i64_i32_err(-3);
    CHECK(!err.ok);
    CHECK(err.as.err == -3);

    /* A 64-bit error round-trips; cell_err narrowed it to int32_t. */
    cell_res_bool_i64_t big = cell_res_bool_i64_err(INT64_C(5000000000));
    CHECK(!big.ok);
    CHECK(big.as.err == INT64_C(5000000000));
    cell_res_bool_i64_t yes = cell_res_bool_i64_ok(true);
    CHECK(yes.ok && yes.as.ok);

    cell_res_f64_i64_t f = cell_res_f64_i64_ok(1.25);
    CHECK(f.ok && f.as.ok == 1.25);
    cell_res_u64_byte_t u = cell_res_u64_byte_ok(UINT64_MAX);
    CHECK(u.as.ok == UINT64_MAX);
    cell_res_byte_u8_t b = cell_res_byte_u8_err(200);
    CHECK(!b.ok && b.as.err == 200);
    cell_res_f32_f32_t g = cell_res_f32_f32_err(0.5f);
    CHECK(!g.ok && g.as.err == 0.5f);

    cell_res_unit_i32_t unit = cell_res_unit_i32_ok();
    CHECK(unit.ok);
    cell_res_unit_i32_t unit_err = cell_res_unit_i32_err(9);
    CHECK(!unit_err.ok && unit_err.as.err == 9);

    /* Constructors zero the struct first, so padding compares equal. */
    cell_res_i8_f64_t z1 = cell_res_i8_f64_ok(7);
    cell_res_i8_f64_t z2 = cell_res_i8_f64_ok(7);
    CHECK(memcmp(&z1, &z2, sizeof(z1)) == 0);

    /* The deprecated legacy names still compile for one runtime version. */
    cell_result_t legacy = cell_err(4);
    CHECK(!legacy.ok && legacy.error_code == 4);
```

Directly above `static void test_result(void) {`, add the static layout checks. They are the measured rows from Step 1:

```c
_Static_assert(sizeof(cell_res_i64_i32_t) == 16 && _Alignof(cell_res_i64_i32_t) == 8
    && offsetof(cell_res_i64_i32_t, as) == 8, "cell_res_i64_i32_t layout");
_Static_assert(sizeof(cell_res_bool_i32_t) == 8 && _Alignof(cell_res_bool_i32_t) == 4
    && offsetof(cell_res_bool_i32_t, as) == 4, "cell_res_bool_i32_t layout");
_Static_assert(sizeof(cell_res_f64_i64_t) == 16 && offsetof(cell_res_f64_i64_t, as) == 8,
    "cell_res_f64_i64_t layout");
_Static_assert(sizeof(cell_res_i8_f64_t) == 16 && offsetof(cell_res_i8_f64_t, as) == 8,
    "cell_res_i8_f64_t layout");
_Static_assert(sizeof(cell_res_i32_i32_t) == 8, "cell_res_i32_i32_t layout");
_Static_assert(sizeof(cell_res_unit_i32_t) == 8 && offsetof(cell_res_unit_i32_t, as) == 4,
    "cell_res_unit_i32_t layout");
_Static_assert(sizeof(cell_res_f64_f64_t) == 16, "cell_res_f64_f64_t layout");
_Static_assert(sizeof(cell_res_i8_i8_t) == 2, "cell_res_i8_i8_t layout");
```

If `offsetof` is undeclared there, add `#include <stddef.h>` at the top of the test file.

- [ ] **Step 3: Run it to verify it fails**

Run: `zig build test -Dswift=false > /tmp/claude-501/t1.log 2>&1; echo "EXIT $?"; grep -m3 -E 'error|undeclared' /tmp/claude-501/t1.log`
Expected: EXIT 1, with `cell_res_i64_i32_t` undeclared.

- [ ] **Step 4: Add the instances to the header**

In `runtime/cell_rt.h`, directly after the `/* Result<T, E> */` banner and before `typedef union cell_value`, insert:

```c
/**
 * ABI version of the runtime's type spellings. 2 = per-instantiation
 * Results (2026-09-17). Bumped whenever an emitted type's layout changes.
 */
#define CELL_RT_ABI_VERSION 2

/*
 * One exact struct per Result<T, E> pair. `ok` is the tag; the payload lives
 * in `as`, in its own C type. Constructors zero the whole struct first, so
 * padding is deterministic (the IR backends build from zeroinitializer).
 * Instances are named cell_res_<ok>_<err>; see the slug table below.
 */
#define CELL_DEFINE_RESULT(base, T, E)                                         \
    typedef struct base##_s {                                                  \
        bool ok;                                                               \
        union { T ok; E err; } as;                                             \
    } base##_t;                                                                \
    static inline base##_t base##_ok(T v) {                                    \
        base##_t r;                                                            \
        memset(&r, 0, sizeof(r));                                              \
        r.ok = true;                                                           \
        r.as.ok = v;                                                           \
        return r;                                                              \
    }                                                                          \
    static inline base##_t base##_err(E e) {                                   \
        base##_t r;                                                            \
        memset(&r, 0, sizeof(r));                                              \
        r.ok = false;                                                          \
        r.as.err = e;                                                          \
        return r;                                                              \
    }

/** A unit T: only the error has storage. */
#define CELL_DEFINE_RESULT_UNIT(base, E)                                       \
    typedef struct base##_s {                                                  \
        bool ok;                                                               \
        union { E err; } as;                                                   \
    } base##_t;                                                                \
    static inline base##_t base##_ok(void) {                                   \
        base##_t r;                                                            \
        memset(&r, 0, sizeof(r));                                              \
        r.ok = true;                                                           \
        return r;                                                              \
    }                                                                          \
    static inline base##_t base##_err(E e) {                                   \
        base##_t r;                                                            \
        memset(&r, 0, sizeof(r));                                              \
        r.ok = false;                                                          \
        r.as.err = e;                                                          \
        return r;                                                              \
    }

/*
 * Every in-scope pair, predefined like the scalar optionals. Slugs: i64 i32
 * i16 i8 u64 u32 u16 u8 f64 f32 bool byte, plus unit for T. A payload-free
 * enum is int32_t and uses i32. Byte stays distinct from UInt8.
 */
#define CELL_RES_ERRS(X, pfx, OT)                                              \
    X(pfx, OT, i64, int64_t) X(pfx, OT, i32, int32_t)                          \
    X(pfx, OT, i16, int16_t) X(pfx, OT, i8, int8_t)                            \
    X(pfx, OT, u64, uint64_t) X(pfx, OT, u32, uint32_t)                        \
    X(pfx, OT, u16, uint16_t) X(pfx, OT, u8, uint8_t)                          \
    X(pfx, OT, f64, double) X(pfx, OT, f32, float)                             \
    X(pfx, OT, bool, bool) X(pfx, OT, byte, uint8_t)
/* The Ok side travels as its already-pasted prefix: <stdbool.h> makes
 * `bool` a macro, and a bare `bool` slug passed through two macro levels
 * would expand to `_Bool` before it is pasted. The Err slug is only ever an
 * operand of ##, which is never macro-expanded. */
#define CELL_RES_OKS(Y)                                                        \
    Y(cell_res_i64, int64_t) Y(cell_res_i32, int32_t)                          \
    Y(cell_res_i16, int16_t) Y(cell_res_i8, int8_t)                            \
    Y(cell_res_u64, uint64_t) Y(cell_res_u32, uint32_t)                        \
    Y(cell_res_u16, uint16_t) Y(cell_res_u8, uint8_t)                          \
    Y(cell_res_f64, double) Y(cell_res_f32, float)                             \
    Y(cell_res_bool, bool) Y(cell_res_byte, uint8_t)
#define CELL_RES_DEFINE_ONE(pfx, OT, err, ET) CELL_DEFINE_RESULT(pfx##_##err, OT, ET)
#define CELL_RES_DEFINE_UNIT(pfx, OT, err, ET) CELL_DEFINE_RESULT_UNIT(pfx##_##err, ET)
#define CELL_RES_FOR_OK(pfx, OT) CELL_RES_ERRS(CELL_RES_DEFINE_ONE, pfx, OT)
CELL_RES_OKS(CELL_RES_FOR_OK)
CELL_RES_ERRS(CELL_RES_DEFINE_UNIT, cell_res_unit, void)
#undef CELL_RES_FOR_OK
#undef CELL_RES_DEFINE_UNIT
#undef CELL_RES_DEFINE_ONE
#undef CELL_RES_OKS
#undef CELL_RES_ERRS
```

The count is 12 × 12 = 144 scalar pairs plus 12 unit pairs, which is 156. The spec's "13 sides" counted the enum separately, but the enum shares `i32`.

Change the comment above `typedef union cell_value` to:
`/** DEPRECATED (ABI 1). Kept for one runtime version; codegen emits cell_res_* for scalar pairs and this only as an opaque pass-through for pairs it cannot lay out. */`

Change the comment above `typedef struct cell_result` the same way.

In the file's type table near line 99, replace the Result line with:
` *   Result<T, E> -> cell_res_<ok>_<err>_t { bool ok; union { T ok; E err; } as; } (ABI 2)`

- [ ] **Step 5: Bump the version string**

In `runtime/cell_rt.c:23`, change `"cell-rt 0.2.0 (c11, atomic arc)"` to `"cell-rt 0.3.0 (c11, atomic arc)"`.

Then run `git grep -n 'cell-rt 0.2.0'` and update every hit outside `docs/superpowers/` and dated ledgers.

- [ ] **Step 6: Run the tests and the C++ probe**

Run: `zig build test -Dswift=false > /tmp/claude-501/t1.log 2>&1; echo "EXIT $?"`
Expected: `EXIT 0`.

Run: `zig build -Dswift=false > /tmp/claude-501/b1.log 2>&1; echo "EXIT $?"; zig-out/bin/cell run examples/hello.cell; echo " RUN $?"`
Expected: `EXIT 0`, then `42`, then `RUN 0`. That shows the embedded runtime compiles through `cell run`.

Run: `c++ -std=c++17 -fsyntax-only -I runtime runtime/cell_rt.cpp; echo "CXX $?"`
Expected: `CXX 0`.

- [ ] **Step 7: Commit**

```bash
git add runtime tools/measure-result-layouts.sh
git commit -m "feat(runtime): per-instantiation Result structs, ABI version 2"
```

---

### Task 2: abi.zig layout rule and member table

**Files:**
- Modify: `src/cell/abi.zig`
  - `.result` arm of `layoutOf`, around lines 77-83;
  - add new declarations after `ResultPayload`;
  - replace the test "a Result is cell_result_t …" at about line 550.

**Interfaces:**
- Consumes: nothing new.
- Produces (all `pub`):

```zig
pub const ResultMember = struct {
    slug: []const u8,     // "i64", "bool", "byte", ...
    c: []const u8,        // "int64_t", "bool", "uint8_t", ...
    natural: []const u8,  // LLVM value type: "i64", "i1" for Bool, "double"
    mem: []const u8,      // LLVM in-memory type: "i8" for Bool, else natural
    size: u32,
    alignment: u32,
};
pub fn resultMember(ty: hir.Ty) ?ResultMember;
pub const ResultShape = struct {
    ok: ?ResultMember,          // null for a unit T
    err: ResultMember,
    union_member: ResultMember, // what clang spells the union as
    size: u32,
    alignment: u32,
};
pub fn resultShape(r: types.ResultType) ?ResultShape;
pub fn resultLlvmType(arena: std.mem.Allocator, s: ResultShape) ![]const u8;  // "{ i8, { i64 } }"
pub fn resultMlirType(arena: std.mem.Allocator, s: ResultShape) ![]const u8;  // "!llvm.struct<(i8, !llvm.struct<(i64)>)>"
```

- [ ] **Step 1: Write the failing test**

Replace the test "a Result is cell_result_t: 24 bytes, align 8, passed and returned indirectly" with:

```zig
fn resultOf(ok: *const hir.Ty, err: *const hir.Ty) hir.Ty {
    return .{ .result = .{ .ok = ok, .err = err } };
}

test "a scalar Result lays out as clang lays out its per-pair struct" {
    // Measured by tools/measure-result-layouts.sh (clang, AArch64/Darwin,
    // 2026-09-17). Union spelled as its first member of the largest
    // alignment, Ok before Err.
    const m = emptyModule();
    const Row = struct { ok: hir.Ty, err: hir.Ty, size: u32, alignment: u32, member: []const u8, param: ParamClass };
    const t_int = types.t_int;
    _ = t_int;
    const rows = [_]Row{
        .{ .ok = types.t_int, .err = types.t_int32, .size = 16, .alignment = 8, .member = "i64", .param = .{ .coerce_words = 2 } },
        .{ .ok = types.t_bool, .err = types.t_int32, .size = 8, .alignment = 4, .member = "i32", .param = .{ .coerce_words = 1 } },
        .{ .ok = types.t_float, .err = types.t_int, .size = 16, .alignment = 8, .member = "double", .param = .{ .coerce_words = 2 } },
        .{ .ok = types.t_int8, .err = types.t_float, .size = 16, .alignment = 8, .member = "double", .param = .{ .coerce_words = 2 } },
        .{ .ok = types.t_int32, .err = types.t_int32, .size = 8, .alignment = 4, .member = "i32", .param = .{ .coerce_words = 1 } },
        .{ .ok = types.t_unit, .err = types.t_int32, .size = 8, .alignment = 4, .member = "i32", .param = .{ .coerce_words = 1 } },
        .{ .ok = types.t_float, .err = types.t_float, .size = 16, .alignment = 8, .member = "double", .param = .{ .coerce_words = 2 } },
        .{ .ok = types.t_int8, .err = types.t_int8, .size = 2, .alignment = 1, .member = "i8", .param = .{ .coerce_words = 1 } },
    };
    for (rows) |row| {
        const r = resultOf(&row.ok, &row.err);
        const l = layoutOf(&m, r, .copy).?;
        try std.testing.expectEqual(row.size, l.size);
        try std.testing.expectEqual(row.alignment, l.alignment);
        const s = resultShape(r.result).?;
        try std.testing.expectEqualStrings(row.member, s.union_member.mem);
        try std.testing.expect(std.meta.eql(row.param, classifyParam(&m, r, .copy)));
    }
}

test "the Result member table covers every scalar and the payload-free enum" {
    try std.testing.expectEqualStrings("i1", resultMember(types.t_bool).?.natural);
    try std.testing.expectEqualStrings("i8", resultMember(types.t_bool).?.mem);
    try std.testing.expectEqualStrings("byte", resultMember(types.t_byte).?.slug);
    try std.testing.expectEqualStrings("u8", resultMember(types.t_uint8).?.slug);
    try std.testing.expectEqualStrings("f32", resultMember(types.t_float32).?.slug);
    const e: hir.Ty = .{ .enum_type = "E" };
    try std.testing.expectEqualStrings("i32", resultMember(e).?.slug);
    try std.testing.expect(resultMember(types.t_string) == null);
    const t_s = types.t_string;
    const t_i = types.t_int;
    try std.testing.expect(resultShape(.{ .ok = &t_s, .err = &t_i }) == null);
    try std.testing.expect(resultShape(.{ .ok = &t_i, .err = &types.t_unit }) == null);
}

test "a Result's IR spelling is the tag byte and its union member" {
    const t_b = types.t_bool;
    const t_i = types.t_int;
    const s = resultShape(.{ .ok = &t_b, .err = &t_i }).?;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("{ i8, { i64 } }", try resultLlvmType(a, s));
    try std.testing.expectEqualStrings("!llvm.struct<(i8, !llvm.struct<(i64)>)>", try resultMlirType(a, s));
    const t_f = types.t_float;
    const sf = resultShape(.{ .ok = &t_f, .err = &t_i }).?;
    try std.testing.expectEqualStrings("!llvm.struct<(i8, !llvm.struct<(f64)>)>", try resultMlirType(a, sf));
}

test "an out-of-scope Result keeps the legacy 24-byte indirect layout" {
    const m = emptyModule();
    const t_i = types.t_int;
    const t_s = types.t_string;
    const r = resultOf(&t_i, &t_s);
    try std.testing.expectEqual(@as(u32, 24), layoutOf(&m, r, .copy).?.size);
    try std.testing.expect(classifyParam(&m, r, .copy) == .indirect);
}
```

Before running, check the real names:
- `ParamClass` and its coerce variant: `grep -n 'pub const ParamClass' -A12 src/cell/abi.zig`. If the variant is not `coerce_words`, use the actual variant name and payload in the `.param` fields and keep the word counts above.
- The `types.t_*` constant names: `grep -n 'pub const t_' src/cell/types.zig`. If `t_bool` is really `t_boolean`, use the real name.
- Remove the stray `const t_int = types.t_int; _ = t_int;` lines if the compiler flags them.

- [ ] **Step 2: Run it to verify it fails**

Run: `zig test src/cell/abi.zig > /tmp/claude-501/t2.log 2>&1; echo "EXIT $?"; grep -m3 error /tmp/claude-501/t2.log`
Expected: EXIT 1, with `use of undeclared identifier 'resultShape'` or a similar error.

- [ ] **Step 3: Implement the table and the rule**

Add after the `ResultPayload` declarations:

```zig
/// One side of a per-instantiation Result (`cell_res_<ok>_<err>_t` in
/// cell_rt.h). The table is the single source both IR backends read; the C
/// backend keeps its own name table (it does not import this module) and a
/// parity test in codegen.zig pins the two together.
pub const ResultMember = struct {
    slug: []const u8,
    c: []const u8,
    natural: []const u8,
    mem: []const u8,
    size: u32,
    alignment: u32,
};

fn member(slug: []const u8, c: []const u8, natural: []const u8, mem: []const u8, size: u32) ResultMember {
    return .{ .slug = slug, .c = c, .natural = natural, .mem = mem, .size = size, .alignment = size };
}

pub fn resultMember(ty: hir.Ty) ?ResultMember {
    return switch (ty) {
        .int => member("i64", "int64_t", "i64", "i64", 8),
        .int8 => member("i8", "int8_t", "i8", "i8", 1),
        .int16 => member("i16", "int16_t", "i16", "i16", 2),
        .int32 => member("i32", "int32_t", "i32", "i32", 4),
        .uint => member("u64", "uint64_t", "i64", "i64", 8),
        .uint8 => member("u8", "uint8_t", "i8", "i8", 1),
        .uint16 => member("u16", "uint16_t", "i16", "i16", 2),
        .uint32 => member("u32", "uint32_t", "i32", "i32", 4),
        .float => member("f64", "double", "double", "double", 8),
        .float32 => member("f32", "float", "float", "float", 4),
        .boolean => member("bool", "bool", "i1", "i8", 1),
        .byte => member("byte", "uint8_t", "i8", "i8", 1),
        // A payload-free enum is an int32_t at the C boundary (SPEC 10.3).
        .enum_type => member("i32", "int32_t", "i32", "i32", 4),
        else => null,
    };
}

pub const ResultShape = struct {
    ok: ?ResultMember,
    err: ResultMember,
    union_member: ResultMember,
    size: u32,
    alignment: u32,
};

/// Null for a pair the per-instantiation runtime does not define: an
/// owning or aggregate side, or a unit E.
pub fn resultShape(r: types.ResultType) ?ResultShape {
    const ok: ?ResultMember = if (r.ok.tag() == .unit) null else (resultMember(r.ok.*) orelse return null);
    const err = resultMember(r.err.*) orelse return null;
    // clang spells a union as its FIRST member of the largest alignment,
    // declaration order `T ok; E err;` (measured, see the spec's table).
    var chosen = err;
    if (ok) |o| {
        if (o.alignment >= err.alignment) chosen = o;
    }
    // Every scalar here has size == alignment, so the chosen member is also
    // the largest. Refuse rather than mis-spell a pair where that fails.
    if (ok) |o| if (o.size > chosen.size) return null;
    if (err.size > chosen.size) return null;
    const a = @max(chosen.alignment, 1);
    const u = chosen.size;
    return .{
        .ok = ok,
        .err = err,
        .union_member = chosen,
        .size = alignUp(alignUp(1, a) + u, a),
        .alignment = a,
    };
}

pub fn resultLlvmType(arena: std.mem.Allocator, s: ResultShape) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{ i8, {{ {s} }} }}", .{s.union_member.mem});
}

pub fn resultMlirType(arena: std.mem.Allocator, s: ResultShape) ![]const u8 {
    const m = if (std.mem.eql(u8, s.union_member.mem, "double")) "f64" else if (std.mem.eql(u8, s.union_member.mem, "float")) "f32" else s.union_member.mem;
    return std.fmt.allocPrint(arena, "!llvm.struct<(i8, !llvm.struct<({s})>)>", .{m});
}
```

Replace the `.result` arm of `layoutOf` and its comment with:

```zig
        // A scalar Result is its per-pair struct (cell_rt.h ABI 2): the tag
        // byte, padding to the union's alignment, the union. Any other pair
        // is still the deprecated 24-byte `cell_result_t` pass-through the C
        // backend keeps for it; the IR backends refuse those.
        .result => |r| if (resultShape(r)) |s|
            .{ .size = s.size, .alignment = s.alignment }
        else
            .{ .size = 24, .alignment = 8 },
```

In Zig 0.17-dev, `if (ok) |o| if (...) return null;` inside a function body may need braces. Write it as `if (ok) |o| { if (o.size > chosen.size) return null; }` if the compiler asks.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig test src/cell/abi.zig > /tmp/claude-501/t2.log 2>&1; echo "EXIT $?"; tail -1 /tmp/claude-501/t2.log`
Expected: `EXIT 0`, with all tests passing, including the four named above. Confirm each name with `grep -c 'Result' /tmp/claude-501/t2.log`.

Run: `zig test src/root.zig > /tmp/claude-501/t2all.log 2>&1; echo "EXIT $?"; grep -E 'FAIL' -A6 /tmp/claude-501/t2all.log | head -40`
Expected: failures only in llvmemit and mlirmit Result tests, whose sret/pointer signature pins are now stale because Results became register-placed. Tasks 4 and 5 rewrite those tests. Anything else failing is a real regression: stop and fix it.

- [ ] **Step 5: Commit**

```bash
git add src/cell/abi.zig
git commit -m "feat(abi): per-pair Result layout rule and member table"
```

The whole-suite state between Task 2 and Task 5 can be red in exactly those IR Result tests. Do not push until Task 6's gate is clean.

---

### Task 3: C backend and typecheck

**Files:**
- Modify: `src/cell/codegen.zig`:
  - `lowerType`'s `.result` arm, about line 3372;
  - the `.ok`/`.err` arms of the wrap emitter, about lines 2572-2588;
  - wrap-pattern binding, about lines 2120-2134;
  - delete `resultField`, about lines 3892-3906;
  - `CType.result`, line 311;
  - tests at about 4947, 8840 and 8866.
- Modify: `src/cell/typecheck.zig`:
  - the `.err` wrap arm, about lines 578-582;
  - the test "Ok and Err are checked against the declared Result".

**Interfaces:**
- Consumes: the Task 1 runtime names `cell_res_<ok>_<err>_t`, `_ok`, `_err`, and the fields `ok`, `as.ok`, `as.err`.
- Produces: `fn resultSlug(self: *Generator, ty: *const ast.TypeExpr, side: enum { ok, err }) Alloc!?[]const u8` and C output that later tasks do not depend on.

- [ ] **Step 1: Write the failing tests**

In `src/cell/codegen.zig`, in the test "Some/None/Ok/Err lower onto the runtime constructors", replace the three `cell_result_t` expectations with:

```zig
    try expectContains(f, "cell_res_i64_i32_t d = cell_res_i64_i32_ok(3);");
    try expectContains(f, "cell_res_i64_i32_t g = cell_res_i64_i32_err(cell_E_B);");
    try expectContains(f, "cell_res_byte_i32_t h = cell_res_byte_i32_ok(4);");
```

In "wrap patterns test the tag and bind the payload", replace the two payload lines with:

```zig
    try expectContains(f, "uint8_t v = _cell_t3.as.ok;");
    try expectContains(f, "cell_E code = (cell_E)_cell_t3.as.err;");
```

Add after that test:

```zig
test "a Result keeps its error at full width and its payload in its own type" {
    var e = try emitSource(
        \\pub fn big(copy n: Int) -> Result<Bool, Int> {
        \\  if n > 0 {
        \\    return Ok(true)
        \\  }
        \\  return Err(5000000000)
        \\}
        \\pub fn half(copy x: Float32) -> Result<Float32, UInt16> {
        \\  return Ok(x)
        \\}
        \\pub fn get(copy r: Result<Bool, Int>) -> Int {
        \\  return match r { Ok(v) => 1, Err(e) => e }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_res_bool_i64_t cell_big(int64_t n);");
    try expectContains(try fnDef(e.text, "big"), "return cell_res_bool_i64_err(5000000000);");
    try expectContains(try fnDef(e.text, "half"), "return cell_res_f32_u16_ok(x);");
    try expectContains(try fnDef(e.text, "get"), "int64_t e = _cell_t");
    try expectAbsent(e.text, "cell_result_t");
    try expectAbsent(e.text, "(int32_t)");
    try expectCompiles(e.text);
}

test "the C Result slugs match abi.resultMember for every scalar name" {
    const abi = @import("abi.zig");
    const types = @import("types.zig");
    const Pair = struct { name: []const u8, ty: types.Type };
    const pairs = [_]Pair{
        .{ .name = "Int", .ty = types.t_int },       .{ .name = "Int8", .ty = types.t_int8 },
        .{ .name = "Int16", .ty = types.t_int16 },   .{ .name = "Int32", .ty = types.t_int32 },
        .{ .name = "UInt", .ty = types.t_uint },     .{ .name = "UInt8", .ty = types.t_uint8 },
        .{ .name = "UInt16", .ty = types.t_uint16 }, .{ .name = "UInt32", .ty = types.t_uint32 },
        .{ .name = "Float", .ty = types.t_float },   .{ .name = "Float32", .ty = types.t_float32 },
        .{ .name = "Bool", .ty = types.t_bool },     .{ .name = "Byte", .ty = types.t_byte },
    };
    for (pairs) |p| {
        try std.testing.expectEqualStrings(abi.resultMember(p.ty).?.slug, scalarSlug(p.name).?);
    }
    try std.testing.expect(scalarSlug("String") == null);
}
```

The parity test uses the same `types.t_*` names that Task 2 settled.

In typecheck.zig's test "Ok and Err are checked against the declared Result", change diag 0 to:

```zig
    try t.expectDiag(0, .err, 5, 35, "optional/Result payloads other than scalar primitives are not implemented");
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig test src/root.zig --test-filter "Result" > /tmp/claude-501/t3.log 2>&1; echo "EXIT $?"; grep -E '^[0-9]+/[0-9]+ .*(FAIL|OK)|error:' /tmp/claude-501/t3.log | head`
Expected: EXIT 1, with `scalarSlug` undeclared.

- [ ] **Step 3: Implement the slug table and the Result CType**

Add as a free function next to `listReader` in codegen.zig:

```zig
/// The per-instantiation Result slug for a Cell scalar type name (cell_rt.h
/// ABI 2). Mirrors abi.resultMember; the parity test pins the two.
fn scalarSlug(n: []const u8) ?[]const u8 {
    if (eq(n, "Int") or eq(n, "Int64")) return "i64";
    if (eq(n, "Int8")) return "i8";
    if (eq(n, "Int16")) return "i16";
    if (eq(n, "Int32")) return "i32";
    if (eq(n, "UInt") or eq(n, "UInt64")) return "u64";
    if (eq(n, "UInt8")) return "u8";
    if (eq(n, "UInt16")) return "u16";
    if (eq(n, "UInt32")) return "u32";
    if (eq(n, "Float") or eq(n, "Float64")) return "f64";
    if (eq(n, "Float32")) return "f32";
    if (eq(n, "Bool")) return "bool";
    if (eq(n, "Byte")) return "byte";
    return null;
}
```

Add as a `Generator` method next to `optionalInstance`:

```zig
    /// A Result side's slug: a scalar name, a payload-free enum (`i32`), or
    /// unit on the Ok side. Null for anything cell_rt.h does not define.
    fn resultSlug(self: *Generator, ty: *const ast.TypeExpr, is_ok: bool) Alloc!?[]const u8 {
        switch (ty.*) {
            .unit => return if (is_ok) "unit" else null,
            .name => |n| {
                if (scalarSlug(n)) |s| return s;
                const base = try self.namedType(n);
                if (base.shape == .enumeration) return "i32";
                return null;
            },
            .ref => |r| return try self.resultSlug(r.inner, is_ok),
            else => return null,
        }
    }
```

Replace the `.result` arm of `lowerType` with:

```zig
            .result => |r| blk: {
                const ok = try self.arena.create(CType);
                ok.* = try self.lowerType(r.ok, .copy);
                const err = try self.arena.create(CType);
                err.* = try self.lowerType(r.err, .copy);
                const text = if (try self.resultSlug(r.ok, true)) |os|
                    if (try self.resultSlug(r.err, false)) |es|
                        try std.fmt.allocPrint(self.arena, "cell_res_{s}_{s}_t", .{ os, es })
                    else
                        CType.result.text
                else
                    CType.result.text;
                break :blk .{ .text = text, .shape = .result, .payload = ok, .err_payload = err };
            },
```

Leave `CType.result` as the legacy spelling (`cell_result_t`) and document it: `/// The deprecated ABI-1 spelling, used only for a Result pair cell_rt.h has no instance for (see lowerType).`

- [ ] **Step 4: Construction and binding**

Add a helper next to `optBase`:

```zig
/// `cell_res_i64_i32` for `cell_res_i64_i32_t`; null for the legacy
/// pass-through spelling, which has no per-pair constructors.
fn resultBase(t: CType) ?[]const u8 {
    if (!std.mem.startsWith(u8, t.text, "cell_res_")) return null;
    return t.text[0 .. t.text.len - 2];
}
```

Replace the `.ok` and `.err` arms of the wrap emitter with:

```zig
            .ok, .err => {
                const is_ok = w.ctor == .ok;
                const dest: ?CType = if (want) |d| (if (d.shape == .result) d else null) else null;
                const base = if (dest) |d| resultBase(d) else null;
                if (base == null) {
                    // No declared per-pair destination: cc must refuse it
                    // rather than guess a layout.
                    try out.writeAll(if (is_ok) "cell_res_unknown_ok(" else "cell_res_unknown_err(");
                    try self.emitExpr(w.operand.?, indent);
                    try out.writeAll(")");
                    return;
                }
                const member = if (is_ok) dest.?.payload.?.* else dest.?.err_payload.?.*;
                try out.print("{s}_{s}(", .{ base.?, if (is_ok) "ok" else "err" });
                try self.emitArgLike(w.operand.?, member, indent);
                try out.writeAll(")");
            },
```

Before writing this, confirm how the wrap emitter's surrounding switch is structured: `grep -n '.ok => {' src/cell/codegen.zig`. The replacement must stay inside the same `switch (w.ctor)`.

Also check whether any caller reaches `.ok` with `want == null`: `grep -n 'emitWrap(' src/cell/codegen.zig`. Typecheck already refuses an undeclared `Ok`/`Err` ("'Ok' needs a declared Result type here"), so the `cell_res_unknown_*` path is only a guard.

`emitArgLike` for an enum operand into an `int32_t` member emits the enum constant (`cell_E_B`), which C converts implicitly. Confirm that the new expectation `cell_res_i64_i32_err(cell_E_B)` holds. If `emitArgLike` inserts a cast, update that expectation to the real text rather than changing the emitter.

In the wrap-pattern binding, replace the `.ok` and `.err` arms with:

```zig
                    .ok, .err => {
                        if (!std.mem.startsWith(u8, scrut_ty.text, "cell_res_")) {
                            try self.writer.writeAll(" = cell_res_unsupported_payload;\n");
                        } else if (ty.shape == .enumeration) {
                            try self.writer.print(" = ({s}){s}.as.{s};\n", .{ ty.text, temp, if (wp.ctor == .ok) "ok" else "err" });
                        } else {
                            try self.writer.print(" = {s}.as.{s};\n", .{ temp, if (wp.ctor == .ok) "ok" else "err" });
                        }
                    },
```

The Result tag test (`if (_cell_t3.ok)`) is unchanged, because the field is still named `ok`.

Delete `fn resultField` and its doc comment. `grep -n resultField src/cell/codegen.zig` must print nothing.

- [ ] **Step 5: Admit only scalar or enum Err payloads in typecheck**

Replace the `.err` arm in typecheck.zig's wrap handling with:

```zig
                    .err => {
                        // E is carried at its own width (cell_rt.h ABI 2), so
                        // it must be a scalar or a payload-free enum.
                        if (!isScalarPayload(payload) and payload.tag() != .enum_type) {
                            try self.errf(expr.span, "optional/Result payloads other than scalar primitives are not implemented", .{});
                            return try self.resultOf(types.t_unknown, types.t_unknown);
                        }
                        return try self.resultOf(types.t_unknown, payload);
                    },
```

- [ ] **Step 6: Update the TYPE-06 pass-through test**

In the test "TYPE-06: a Result type lowers to cell_result_t …", keep the program (`Result<Int, String>` is out of scope). Keep `cell_result_t cell_read(void);`, and add this comment above the expectations:

```zig
    // `Result<Int, String>` has no per-pair instance (an owning Err), so it
    // keeps the deprecated ABI-1 pass-through spelling (sub-project 3).
```

- [ ] **Step 7: Run the tests**

Run: `zig test src/root.zig > /tmp/claude-501/t3all.log 2>&1; echo "EXIT $?"; grep -B2 -A12 FAIL /tmp/claude-501/t3all.log | head -60`
Expected: the codegen and typecheck Result tests pass, including "a Result keeps its error at full width …" and the parity test. Confirm both names in the log. The only remaining failures are the llvmemit/mlirmit Result tests.

Run: `zig build -Dswift=false > /tmp/claude-501/b3.log 2>&1; echo B $?; zig-out/bin/cell run examples/results.cell; echo " RUN $?"; zig-out/bin/cell run examples/prelude.cell; echo " RUN $?"`
Expected: `B 0`, then `9` and `RUN 0`, then `123` and `RUN 0`.

- [ ] **Step 8: Commit**

```bash
git add src/cell/codegen.zig src/cell/typecheck.zig
git commit -m "feat(codegen): emit per-pair Result instances; typecheck admits scalar or enum E"
```

---

### Task 4: HIR admission and the LLVM backend

**Files:**
- Modify: `src/cell/hir.zig` (about lines 834-841 and 977-980)
- Modify: `src/cell/llvmemit.zig`:
  - the preamble, lines 183-184;
  - `emitResultCtor` and `readResultPayload`, about lines 1436-1506;
  - the match tag, about lines 1729-1740;
  - `llType`'s `.result`, about lines 1910-1915;
  - tests at about 2516-2555.

**Interfaces:**
- Consumes: `abi.resultShape`, `abi.resultMember`, `abi.resultLlvmType`, `ResultShape.ok`/`.err`/`.union_member`, and `ResultMember.natural`/`.mem`.
- Produces: nothing that later tasks read, except that hir now admits unit `T` and every scalar or enum `E`.

- [ ] **Step 1: Write the failing tests**

Replace the llvmemit tests "a scalar Result lowers to cell_result_t, built zeroed and matched on its ok byte" and "a narrow Result payload is widened in and narrowed out the way cell_ok_* does" with:

```zig
test "a scalar Result lowers to its per-pair struct, built zeroed and matched on its ok byte" {
    var e = try emitSource(
        \\pub enum ParseError { Empty, TooLong }
        \\pub fn parse_len(copy n: Int) -> Result<Int, ParseError> {
        \\    if n == 0 { return Err(ParseError.Empty) }
        \\    return Ok(n * 2)
        \\}
        \\pub fn score(copy r: Result<Int, ParseError>) -> Int {
        \\    return match r { Ok(v) => v, Err(e) => 1 }
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, e.text, "%cell_result") == null);
    try std.testing.expect(std.mem.indexOf(u8, e.text, "%cell_value") == null);
    // 16 bytes, align 8: two words each way, as clang places it.
    try expectContains(e.text, "define [2 x i64] @cell_parse_len(i64 %arg0)");
    try expectContains(e.text, "define i64 @cell_score([2 x i64] %arg0)");
    try expectContains(e.text, "store { i8, { i64 } } zeroinitializer, ptr");
    try expectContains(e.text, "getelementptr inbounds { i8, { i64 } }, ptr %");
    try expectContains(e.text, "extractvalue { i8, { i64 } }");
    try expectContains(e.text, "icmp ne i8");
    try expectContains(e.text, "icmp eq i8");
}

test "a Result payload is stored in its own width, never widened" {
    var e = try emitSource(
        \\pub fn wrap8(copy v: Int8) -> Result<Int8, Int32> { return Ok(v) }
        \\pub fn flag(copy b: Bool) -> Result<Bool, Int32> { return Ok(b) }
        \\pub fn big() -> Result<Bool, Int> { return Err(5000000000) }
        \\pub fn get8(copy r: Result<Int8, Int32>, copy d: Int8) -> Int8 { return match r { Ok(v) => v, Err(_) => d } }
        \\pub fn getb(copy r: Result<Bool, Int32>) -> Bool { return match r { Ok(v) => v, Err(_) => false } }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, e.text, "sext") == null);
    try std.testing.expect(std.mem.indexOf(u8, e.text, "trunc i64") == null);
    // 8 bytes: an exact-width i64 return.
    try expectContains(e.text, "define i64 @cell_flag(");
    try expectContains(e.text, "alloca { i8, { i32 } }");
    // A C bool is a byte in memory.
    try expectContains(e.text, "zext i1 ");
    try expectContains(e.text, "trunc i8 ");
    // The large error keeps all 64 bits.
    try expectContains(e.text, "define [2 x i64] @cell_big()");
    try expectContains(e.text, "store i64 5000000000, ptr");
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig test src/root.zig --test-filter "per-pair struct" > /tmp/claude-501/t4.log 2>&1; echo "EXIT $?"; grep -E 'per-pair|FAIL' /tmp/claude-501/t4.log | head -4`
Expected: EXIT 1, with the named test in the output and FAIL.

- [ ] **Step 3: HIR admission**

In hir.zig, replace the two checks in the wrap arm (`resultPayload(r.ok.*) == null` and `!resultErrorCarried(r.err.*)`) with:

```zig
                if (r.ok.tag() != .unit and abi.resultMember(r.ok.*) == null) {
                    try self.cannotLower(e.span, "a Result whose Ok payload is not a scalar primitive");
                    return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "wrap" });
                }
                if (abi.resultShape(r) == null) {
                    try self.cannotLower(e.span, "a Result whose Err payload is not a scalar primitive or a payload-free enum");
                    return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "wrap" });
                }
```

In the pattern arm, replace `if (abi.resultPayload(r.ok.*) == null or !abi.resultErrorCarried(r.err.*))` with `if (abi.resultShape(r) == null)` and change its message to `"a Result pattern whose payloads are not scalar primitives or a payload-free enum"`.

Then add, directly before `var binding: ?u32 = null;`:

```zig
                if (wp.binding != null and wp.ctor == .ok and r.ok.tag() == .unit) {
                    try self.cannotLower(p.span, "binding the payload of a unit Ok");
                    return .{ .kind = .wildcard, .span = p.span };
                }
```

`r` is `types.ResultType` here, which is what `resultShape` takes. If the compiler reports `r` as a pointer, pass `r.*`.

- [ ] **Step 4: LLVM types and construction**

Delete the two preamble lines `%cell_value = type { %cell_str }` and `%cell_result = type { i8, i32, %cell_value }`.

In `llType`, replace the `.result` arm with:

```zig
            // The per-pair struct, spelled structurally the way clang lays
            // it out (abi.resultShape). Any other pair is refused.
            .result => |r| blk: {
                const s = abi.resultShape(r) orelse break :blk null;
                break :blk abi.resultLlvmType(self.arena, s) catch null;
            },
```

Replace `emitResultCtor` with:

```zig
    /// `Ok(x)`/`Err(e)`, built the way cell_rt.h's per-pair constructors
    /// build it: a zeroed struct, the `ok` byte, then the payload at field 1
    /// in its own member type (a Bool as a byte).
    fn emitResultCtor(self: *Emitter, e: *const hir.Expr, is_ok: bool, operand_e: *const hir.Expr) EmitError!Value {
        const r = e.ty.result;
        const s = abi.resultShape(r).?;
        const ty = try abi.resultLlvmType(self.arena, s);
        const v = try self.emitExpr(operand_e);
        if (v.isVoid()) return Value.void_value;
        const m = if (is_ok) s.ok.? else s.err;
        if (!try self.fits(operand_e.span, v.ty, m.natural, if (is_ok) "an Ok payload" else "an Err payload")) return Value.void_value;
        const buf = try self.nextTemp();
        try self.out.print("  {s} = alloca {s}\n", .{ buf, ty });
        try self.out.print("  store {s} zeroinitializer, ptr {s}\n", .{ ty, buf });
        if (is_ok) try self.out.print("  store i8 1, ptr {s}\n", .{buf});
        var stored = v.text;
        if (!std.mem.eql(u8, m.natural, m.mem)) {
            const w = try self.nextTemp();
            try self.out.print("  {s} = zext {s} {s} to {s}\n", .{ w, m.natural, v.text, m.mem });
            stored = w;
        }
        const at = try self.nextTemp();
        try self.out.print("  {s} = getelementptr inbounds {s}, ptr {s}, i32 0, i32 1\n", .{ at, ty, buf });
        try self.out.print("  store {s} {s}, ptr {s}\n", .{ m.mem, stored, at });
        const out = try self.nextTemp();
        try self.out.print("  {s} = load {s}, ptr {s}\n", .{ out, ty, buf });
        return .{ .text = out, .ty = ty };
    }
```

The expectation `store i64 5000000000, ptr` requires that `emitExpr` on an integer literal returns the literal text itself. Check this first: `grep -n '\.int => ' src/cell/llvmemit.zig | head`. If literals are materialized into a temporary, change that expectation to `store i64 %` plus `5000000000` appearing in the text.

Replace `readResultPayload` with:

```zig
    /// The payload a matched `Ok(v)`/`Err(e)` binds, read from field 1
    /// through memory (the union is not an addressable field of its own).
    fn readResultPayload(self: *Emitter, scrutinee: Value, ty: hir.Ty, is_ok: bool) EmitError!Value {
        const s = abi.resultShape(ty.result).?;
        const lt = try abi.resultLlvmType(self.arena, s);
        const m = if (is_ok) s.ok.? else s.err;
        const buf = try self.nextTemp();
        try self.out.print("  {s} = alloca {s}\n", .{ buf, lt });
        try self.out.print("  store {s} {s}, ptr {s}\n", .{ lt, scrutinee.text, buf });
        const at = try self.nextTemp();
        try self.out.print("  {s} = getelementptr inbounds {s}, ptr {s}, i32 0, i32 1\n", .{ at, lt, buf });
        const raw = try self.nextTemp();
        try self.out.print("  {s} = load {s}, ptr {s}\n", .{ raw, m.mem, at });
        if (std.mem.eql(u8, m.natural, m.mem)) return .{ .text = raw, .ty = m.natural };
        const n = try self.nextTemp();
        try self.out.print("  {s} = trunc {s} {s} to {s}\n", .{ n, m.mem, raw, m.natural });
        return .{ .text = n, .ty = m.natural };
    }
```

In the match-tag branch, replace `extractvalue %cell_result {s}, 0` with `extractvalue {s} {s}, 0`, passing `.{ tag, scrutinee.ty, scrutinee.text }`. Update the comment to read "`ok` is the per-pair struct's first field, a C bool byte." `scrutinee.ty` must hold the struct text. Confirm `emitMatch` sets it from `llType`: `grep -n 'scrutinee' src/cell/llvmemit.zig | head`.

- [ ] **Step 5: Run the tests**

Run: `zig test src/root.zig > /tmp/claude-501/t4all.log 2>&1; echo "EXIT $?"; grep -B2 -A12 FAIL /tmp/claude-501/t4all.log | head -60`
Expected: llvmemit tests pass, and both new names appear. Only mlirmit Result tests may still fail.

Run: `zig build -Dswift=false > /tmp/claude-501/b4.log 2>&1; echo B $?; .claude/skills/run-cell-lang/driver.sh --expect 9 examples/results.cell > /tmp/claude-501/d4.log 2>&1; echo "D $?"; cat /tmp/claude-501/d4.log`
Expected: `B 0`, the `C` and `LLVM` rows `ok -> 9`, and the MLIR row possibly failing until Task 5.

- [ ] **Step 6: Commit**

```bash
git add src/cell/hir.zig src/cell/llvmemit.zig
git commit -m "feat(llvm): per-pair Result structs, stored at their own width"
```

---

### Task 5: The MLIR backend and removing the ABI-1 helpers

**Files:**
- Modify: `src/cell/mlirmit.zig`:
  - `result_type`, line 99;
  - `emitResultCtor` and `readResultPayload`, about lines 1500-1575;
  - the match tag, about lines 1639-1651;
  - `mlirType`'s `.result`, about lines 1901-1907;
  - the test at about 2672.
- Modify: `src/cell/abi.zig` (delete `ResultPayload`, `resultPayload`, `resultErrorCarried`)

**Interfaces:**
- Consumes: `abi.resultShape`, `abi.resultMlirType`, and `ResultMember.natural`/`.mem` (LLVM names; map them through `mlirScalar`).

- [ ] **Step 1: Write the failing test**

Replace "a scalar Result lowers to the cell_result_t struct in the llvm dialect" with:

```zig
test "a scalar Result lowers to its per-pair struct in the llvm dialect" {
    var e = try emitSource(
        \\pub enum ParseError { Empty, TooLong }
        \\pub fn parse_len(copy n: Int) -> Result<Int, ParseError> {
        \\    if n == 0 { return Err(ParseError.Empty) }
        \\    return Ok(n * 2)
        \\}
        \\pub fn score(copy r: Result<Int8, ParseError>, copy d: Int8) -> Int8 {
        \\    return match r { Ok(v) => v, Err(_) => d }
        \\}
        \\pub fn wide() -> Result<Float, Int> { return Err(5000000000) }
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, e.text, "!llvm.struct<(i8, i32, ") == null);
    try expectContains(e.text, "llvm.mlir.zero : !llvm.struct<(i8, !llvm.struct<(i64)>)>");
    try expectContains(e.text, "llvm.alloca");
    try expectContains(e.text, "[0, 1] : (!llvm.ptr) -> !llvm.ptr, !llvm.struct<(i8, !llvm.struct<(i64)>)>");
    try expectContains(e.text, "arith.cmpi ne,");
    try std.testing.expect(std.mem.indexOf(u8, e.text, "arith.trunci") == null);
    // Result<Int8, ParseError> is 8 bytes: one word, as in C.
    try expectContains(e.text, "@cell_score(%arg0: !llvm.array<1 x i64>, %arg1: i8)");
    try expectContains(e.text, "!llvm.struct<(i8, !llvm.struct<(f64)>)>");
    // A Result slot is an llvm.alloca: memref cannot hold an !llvm.struct.
    try std.testing.expect(std.mem.indexOf(u8, e.text, "memref<!llvm.struct<(i8, ") == null);
}
```

The `@cell_score` line follows the MLIR spelling of a one-word coerced parameter. Confirm it against an existing optional test: `grep -n 'array<1 x i64>' src/cell/mlirmit.zig | head -3`. Use exactly that spelling.

- [ ] **Step 2: Run it to verify it fails**

Run: `zig test src/root.zig --test-filter "per-pair struct in the llvm dialect" > /tmp/claude-501/t5.log 2>&1; echo "EXIT $?"; grep -E 'llvm dialect|FAIL' /tmp/claude-501/t5.log | head -3`
Expected: EXIT 1, with the named test failing.

- [ ] **Step 3: Implement**

Delete `const result_type = ...` and its comment.

In `mlirType`, replace the `.result` arm with:

```zig
            // The per-pair struct (abi.resultShape), structural like
            // llvmemit.zig's. Any other pair is refused.
            .result => |r| blk: {
                const s = abi.resultShape(r) orelse break :blk null;
                break :blk abi.resultMlirType(self.arena, s) catch null;
            },
```

Replace `emitResultCtor` with:

```zig
    /// `Ok(x)`/`Err(e)`, built the way llvmemit.zig builds it: a zeroed
    /// per-pair struct, the `ok` byte, then the payload at field 1 in its own
    /// member type.
    fn emitResultCtor(self: *Emitter, e: *const hir.Expr, is_ok: bool, operand_e: *const hir.Expr) EmitError!Value {
        const s = abi.resultShape(e.ty.result).?;
        const ty = try abi.resultMlirType(self.arena, s);
        const v = try self.emitExpr(operand_e);
        if (v.isNone()) return Value.none;
        const m = if (is_ok) s.ok.? else s.err;
        const natural = mlirScalar(m.natural);
        const mem = mlirScalar(m.mem);
        if (!try self.fits(operand_e.span, v.ty, natural, if (is_ok) "an Ok payload" else "an Err payload")) return Value.none;
        const one = try self.nextSsa();
        try self.line("{s} = llvm.mlir.constant(1 : i64) : i64", .{one});
        const buf = try self.nextSsa();
        try self.line("{s} = llvm.alloca {s} x {s} : (i64) -> !llvm.ptr", .{ buf, one, ty });
        const zero = try self.nextSsa();
        try self.line("{s} = llvm.mlir.zero : {s}", .{ zero, ty });
        try self.line("llvm.store {s}, {s} : {s}, !llvm.ptr", .{ zero, buf, ty });
        if (is_ok) {
            const tag = try self.nextSsa();
            try self.line("{s} = llvm.mlir.constant(1 : i8) : i8", .{tag});
            try self.line("llvm.store {s}, {s} : i8, !llvm.ptr", .{ tag, buf });
        }
        var stored = v.text;
        if (!std.mem.eql(u8, natural, mem)) {
            const w = try self.nextSsa();
            try self.line("{s} = arith.extui {s} : {s} to {s}", .{ w, v.text, natural, mem });
            stored = w;
        }
        const at = try self.nextSsa();
        try self.line("{s} = llvm.getelementptr inbounds {s}[0, 1] : (!llvm.ptr) -> !llvm.ptr, {s}", .{ at, buf, ty });
        try self.line("llvm.store {s}, {s} : {s}, !llvm.ptr", .{ stored, at, mem });
        const out = try self.nextSsa();
        try self.line("{s} = llvm.load {s} : !llvm.ptr -> {s}", .{ out, buf, ty });
        return .{ .text = out, .ty = ty };
    }
```

Replace `readResultPayload` with:

```zig
    /// The payload a matched `Ok(v)`/`Err(e)` binds, read from field 1.
    fn readResultPayload(self: *Emitter, scrutinee: Value, ty: hir.Ty, is_ok: bool) EmitError!Value {
        const s = abi.resultShape(ty.result).?;
        const st = try abi.resultMlirType(self.arena, s);
        const m = if (is_ok) s.ok.? else s.err;
        const natural = mlirScalar(m.natural);
        const mem = mlirScalar(m.mem);
        const one = try self.nextSsa();
        try self.line("{s} = llvm.mlir.constant(1 : i64) : i64", .{one});
        const buf = try self.nextSsa();
        try self.line("{s} = llvm.alloca {s} x {s} : (i64) -> !llvm.ptr", .{ buf, one, st });
        try self.line("llvm.store {s}, {s} : {s}, !llvm.ptr", .{ scrutinee.text, buf, st });
        const at = try self.nextSsa();
        try self.line("{s} = llvm.getelementptr inbounds {s}[0, 1] : (!llvm.ptr) -> !llvm.ptr, {s}", .{ at, buf, st });
        const raw = try self.nextSsa();
        try self.line("{s} = llvm.load {s} : !llvm.ptr -> {s}", .{ raw, at, mem });
        if (std.mem.eql(u8, natural, mem)) return .{ .text = raw, .ty = natural };
        const n = try self.nextSsa();
        try self.line("{s} = arith.trunci {s} : {s} to {s}", .{ n, raw, mem, natural });
        return .{ .text = n, .ty = natural };
    }
```

In the match-tag branch, replace `result_type` with `scrutinee.ty`, and update the comment the same way as in llvmemit.

Delete `ResultPayload`, `resultPayload` and `resultErrorCarried` from abi.zig. Then run `git grep -n 'resultPayload\|resultErrorCarried\|result_type\|%cell_result\|%cell_value' -- src`, which must print nothing.

- [ ] **Step 4: Run the tests and all three backends**

Run: `zig build -Dswift=false > /tmp/claude-501/b5.log 2>&1; echo B $?; zig test src/root.zig > /tmp/claude-501/t5all.log 2>&1; echo "T $?"; tail -1 /tmp/claude-501/t5all.log`
Expected: `B 0`, `T 0`, `All N tests passed.`

Run: `.claude/skills/run-cell-lang/driver.sh --expect 9 examples/results.cell > /tmp/claude-501/d5.log 2>&1; echo "D $?"; cat /tmp/claude-501/d5.log`
Expected: `D 0`, with `C`, `LLVM` and `MLIR` each reading `ok -> 9`.

- [ ] **Step 5: Commit**

```bash
git add src/cell/mlirmit.zig src/cell/abi.zig
git commit -m "feat(mlir): per-pair Result structs; drop the ABI-1 payload helpers"
```

---

### Task 6: The wide example, the gate, docs and the push

**Files:**
- Create: `examples/results_wide.cell`
- Modify: `docs/SPEC.md` (3.4 at line 793, the 10.3 table at about 1928, the 10.6 version quote at line 2027)
- Modify: `docs/FEATURES.md` (TYPE-06 at line 30, ABI-02 at line 46)
- Modify: `AGENTS.md` (lines 140 and 147)
- Modify: `examples/results.cell` (the header comment only)
- Modify: `docs/superpowers/specs/2026-09-17-per-instantiation-results-design.md` (the Status line)

- [ ] **Step 1: Write the example**

Create `examples/results_wide.cell`:

```cell
// Per-instantiation Results (cell_rt.h ABI 2): E is carried at its own
// width, so an error above 32 bits round-trips, and a Float or Bool payload
// is stored exactly. Before 2026-09-17 the C backend narrowed E to an
// int32_t code (5000000000 became 705032704) and the IR backends refused an
// Int error outright.
//
// Status: parses, passes `cell check`, and runs on the C, LLVM and MLIR
// backends, printing the same answer on each (see EXPECT-OUTPUT).
// EXPECT-OUTPUT: -8999999983

pub fn print_int(copy value: Int);

pub fn half(copy x: Float) -> Result<Float, Int> {
    if x < 0.0 {
        return Err(5000000000)
    }
    return Ok(x / 2.0)
}

pub fn check(copy n: Int) -> Result<Bool, Int> {
    if n > 3 {
        return Ok(true)
    }
    return Err(n - 9000000000)
}

pub fn f_score(copy r: Result<Float, Int>) -> Int {
    return match r {
        Ok(v) => if v > 1.0 { 1 } else { 2 },
        Err(e) => e / 1000000000,
    }
}

pub fn b_score(copy r: Result<Bool, Int>) -> Int {
    return match r {
        Ok(v) => if v { 10 } else { 20 },
        Err(e) => e,
    }
}

pub fn main() {
    let copy a = f_score(half(3.0))
    let copy b = f_score(half(-1.0))
    let copy c = b_score(check(5))
    let copy d = b_score(check(1))
    print_int(a + b + c + d)
}
```

Expected answer: `a = 1`, `b = 5`, `c = 10`, `d = 1 - 9000000000`, for a total of **-8999999983**.

- [ ] **Step 2: Run it on all three backends**

Run: `zig-out/bin/cell check examples/results_wide.cell; echo "CHECK $?"; .claude/skills/run-cell-lang/driver.sh --expect -8999999983 examples/results_wide.cell > /tmp/claude-501/d6.log 2>&1; echo "D $?"; cat /tmp/claude-501/d6.log`
Expected: `CHECK 0`, `D 0`, and three rows reading `ok -> -8999999983`.

If any backend prints another number, do not change the pin. Find which backend is wrong: compare the C answer, which you can compute by hand, with the other two.

- [ ] **Step 3: Update the docs**

- **SPEC 3.4:**
  - Replace the sentence that says E is narrowed to an `int32_t` code with this paragraph:
    > "A `Result<T, E>` whose `T` is a scalar primitive or unit and whose `E` is a scalar primitive or a payload-free enum lowers to its own C struct, `cell_res_<ok>_<err>_t { bool ok; union { T ok; E err; } as; }` (cell_rt.h ABI 2, 2026-09-17), with both payloads stored at their own width. At most 16 bytes, so it travels in registers. Any other pair keeps the deprecated `cell_result_t` spelling in C as a pass-through, and the IR backends refuse it."
  - State that `Err` accepts any scalar or payload-free enum.
- **SPEC 10.3:** change the Result row to `cell_res_<ok>_<err>_t (ABI 2)`.
- **SPEC 10.6:** change `cell-rt 0.1.0 (c11)` to `cell-rt 0.3.0 (c11, atomic arc)`.
- **FEATURES TYPE-06:** replace "`E` is Int32 or a payload-free enum" with "`E` is any scalar primitive or a payload-free enum, carried at its own width in a per-pair struct (ABI 2, 2026-09-17); `results_wide.cell` pins a 64-bit error on all three backends". Remove any clause saying LLVM/MLIR refuse a `Byte` payload, since `resultMember` covers `Byte`.
- **FEATURES ABI-02:** state is `partial` in the C column and the two IR columns. Evidence: "ABI version 2 (`CELL_RT_ABI_VERSION`) and per-pair Result instance naming for scalar payloads; owning payloads are sub-projects 2-4". Keep the other columns as they are.
- **AGENTS.md line 140:** "`Result<T,E>` is present for scalar payloads only, as per-pair structs (SPEC 3.4)".
- **AGENTS.md line 147:** leave it unless it names `cell_result_t`.
- **examples/results.cell header:** replace "carried as an int32_t code at the C boundary (SPEC 3.4)" with "carried as an int32_t at the C boundary, in the per-pair struct `cell_res_i64_i32_t` (SPEC 3.4)".
- **Spec Status line:** "Status: approved 2026-09-17; implemented by docs/superpowers/plans/2026-09-17-per-instantiation-results.md (see its Deviations section)."

Run: `sh tools/check-rule-lists.sh > /dev/null; echo "RULES $?"; git grep -n 'cell_result_t\|cell-rt 0.2.0\|int32_t code' -- docs/SPEC.md docs/FEATURES.md AGENTS.md README.md examples`
Expected: `RULES 0`. Every remaining hit must describe the deprecated pass-through or be history.

- [ ] **Step 4: Run the full gate**

Run: `tools/check.sh > /tmp/claude-501/cell-gate.log 2>&1; echo "GATE EXIT $?" >> /tmp/claude-501/cell-gate.log; grep -E 'All [0-9]+ tests|results|owned_scalar|disagreement|FAIL|SKIP' /tmp/claude-501/cell-gate.log; sed -n '/== verdict ==/,$p' /tmp/claude-501/cell-gate.log`
Expected:
- the verdict reads `clean` and `GATE EXIT 0`;
- `results` and `results_wide` each read `C/LLVM/MLIR`;
- `owned_scalar_wrappers -> 0`;
- `0 disagreement(s)`.

If stage 10 reports a disagreement, check the IR type spelling against `tools/measure-result-layouts.sh` before touching anything else.

- [ ] **Step 5: Commit and push**

```bash
git add examples/results_wide.cell examples/results.cell docs AGENTS.md
git commit -m "docs: per-instantiation Results (ABI 2); results_wide pins a 64-bit error"
git fetch -q && git status -sb | head -1
S=$(git rev-parse HEAD); git push -q origin "${S}:refs/heads/main"; echo "PUSH $?"; git ls-remote origin refs/heads/main
```

Expected: `PUSH 0`, and the remote hash equals `$S`. Write the SHA inline if zsh mangles `${S}:refs`.
