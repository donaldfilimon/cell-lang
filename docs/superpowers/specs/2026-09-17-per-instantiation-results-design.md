# Per-instantiation Result layouts

Status: design for review, 2026-09-17, from Donald's `/superpowers:brainstorming`
session. Not yet approved for implementation.

## Decisions already taken (Donald, 2026-09-17)

- Resource-bearing `Result` and optional payloads will be carried by **one exact
  struct per instantiation**, the way `CELL_DEFINE_OPTIONAL` already works for
  optionals. The alternatives, rejected, were a single widened `cell_value_t`
  union and two unions.
- The work is **four sub-projects**, each with its own spec, plan and gate:
  1. **this document**: per-instantiation layout for the scalar Results
     Cell already has;
  2. owning `String` in `Ok`;
  3. owning `String` in `Err` (the rich error side);
  4. owning `String?`.
- For sub-projects 2-4, a binding pattern on an owning payload **must say its
  mode**: `Ok(owned s)` moves the payload out and consumes the scrutinee,
  `Ok(shared s)` borrows it, and a bare `Ok(s)` on an owning payload is refused.
- Everything below that is not listed above was chosen by default and is open
  to review.

## Why

Today every `Result<T, E>` is `cell_result_t`
(`runtime/cell_rt.h:301-305`, 24 bytes, measured):

```c
typedef union cell_value { int64_t i64; uint64_t u64; double f64; bool b; void *ptr; cell_str_t str; } cell_value_t;
typedef struct cell_result { bool ok; int32_t error_code; cell_value_t value; } cell_result_t;
```

- **E is narrowed.** `E` is squeezed into an `int32_t` code whatever its Cell
  type is, so `Result<Int, Int>` silently loses the high bits of its error.
- **T is limited.** `T` must fit a 16-byte union whose widest member is a
  *borrowed* `cell_str_t`, so an owning `cell_string_t` (24 bytes) cannot be
  carried at all.
- **Size is fixed.** Every Result is 24 bytes and passed indirectly, even
  `Result<Bool, Int32>`.

An exact struct per `(T, E)` pair removes all three limits for scalar payloads
now. It gives sub-projects 2-4 a place to put owning payloads and their drop
glue later.

## Scope

- **In scope:** every `Result<T, E>` Cell accepts today, with `T` a scalar
  primitive (`Int`/`Int8`/`Int16`/`Int32`, the unsigned widths, `Float`,
  `Float32`, `Bool`, `Byte`) or unit. The error side widens to any of those
  scalars or a payload-free enum.
- **Non-goals:**
  - owning payloads (sub-projects 2-4);
  - payload-carrying enums (FEATURES PAT-02, absent);
  - borrow-checker changes;
  - optional layouts.

## Runtime

`runtime/cell_rt.h` gains:

```c
#define CELL_RT_ABI_VERSION 2

#define CELL_DEFINE_RESULT(base, T, E)                                   \
    typedef struct base##_s { bool ok; union { T ok; E err; } as; } base##_t; \
    static inline base##_t base##_ok(T v) {                              \
        base##_t r; memset(&r, 0, sizeof(r)); r.ok = true; r.as.ok = v; return r; } \
    static inline base##_t base##_err(E e) {                             \
        base##_t r; memset(&r, 0, sizeof(r)); r.ok = false; r.as.err = e; return r; }

#define CELL_DEFINE_RESULT_UNIT(base, E)                                 \
    typedef struct base##_s { bool ok; union { E err; } as; } base##_t;  \
    static inline base##_t base##_ok(void) {                             \
        base##_t r; memset(&r, 0, sizeof(r)); r.ok = true; return r; }   \
    static inline base##_t base##_err(E e) {                             \
        base##_t r; memset(&r, 0, sizeof(r)); r.ok = false; r.as.err = e; return r; }
```

- **Why the zeroing.** Every constructor zeroes the whole struct first, as the
  optional constructors do. That keeps padding deterministic for a byte-wise
  comparison and for the IR backends' `zeroinitializer`.
- **Legacy names.** `cell_result_t`, `cell_value_t` and `cell_ok_*`/`cell_err`
  stay in the header for one runtime version, marked deprecated. Codegen stops
  emitting them. No host, example or prelude file uses them today (grep,
  2026-09-17).
- **Version.** `cell_rt_version()` becomes `cell-rt 0.3.0 (c11, atomic arc)`,
  and SPEC 10.6's stale `0.1.0` quote is corrected.
- **Layout checks.** `runtime/tests/test_cell_rt.c` rewrites `test_result`
  around a handful of instances and adds `_Static_assert` size and offset
  checks for them, the first layout assertions in the runtime.

### Measured layouts (clang, AArch64/Darwin, 2026-09-17)

| Instance (`T`, `E`) | size | align | `as` offset | union spelled | returned as | passed as |
|---|---|---|---|---|---|---|
| `int64_t`, `int32_t` | 16 | 8 | 8 | `{ i64 }` | `[2 x i64]` | `[2 x i64]` |
| `bool`, `int32_t` | 8 | 4 | 4 | `{ i32 }` | `i64` | `i64` |
| `double`, `int64_t` | 16 | 8 | 8 | `{ double }` | `[2 x i64]` | `[2 x i64]` |
| `int8_t`, `double` | 16 | 8 | 8 | `{ double }` | `[2 x i64]` | `[2 x i64]` |
| `int32_t`, `int32_t` | 8 | 4 | 4 | `{ i32 }` | `i64` | `i64` |
| unit, `int32_t` | 8 | 4 | 4 | `{ i32 }` | `i64` | `i64` |
| `double`, `double` | 16 | 8 | 8 | `{ double }` | `[2 x i64]` | `[2 x i64]` |

What the table shows:
- **Union spelling.** Clang spells the union as its **first member of the
  largest alignment**. A `bool`/`int32_t` union is `{ i32 }`, and a
  `double`/`int64_t` union is `{ double }`, because `double` comes first.
- **No HFAs.** None of these is an HFA, because the leading `bool` rules that
  out.
- **Register placement.** Every scalar instance is at most 16 bytes, so all of
  them now travel in registers under the classification landed in `1e295f0e`.
  Scalar Results no longer pass indirectly.

## Naming

Instances are named `cell_res_<ok>_<err>` from structural slugs:
- `i64`, `i32`, `i16`, `i8` for the signed integers;
- `u64`, `u32`, `u16`, `u8` for the unsigned integers;
- `f64`, `f32` for the floats;
- `bool` and `byte` (Byte stays distinct from UInt8, as in `optionalBase`);
- `unit` for a unit `T`.

A payload-free enum lowers to `int32_t` (SPEC 10.3) and takes the slug `i32`.
So `Result<Int, ParseError>` and `Result<Int, Int32>` share
`cell_res_i64_i32_t`, which is correct because their C representations are
identical.

## Compiler changes

### abi.zig

- **`layoutOf(.result)`:**
  - Let `a = max(align(T), align(E), 1)` and `u = max(size(T), size(E))`,
    where unit contributes size 0 and align 1.
  - The layout is `size = alignUp(alignUp(1, a) + u, a)` with alignment `a`.
  - `layoutOf(.result)` currently returns a fixed 24/8.
- **Classification.** `classifyParam`/`classifyReturn` need no change: the
  table above is exactly what they produce for those sizes.
- **Payload helpers.** `resultPayload` and `resultErrorCarried` are replaced by
  `resultMember(ty) ?Member`:
  - it gives the member's LLVM type (`bool` is `i8` in memory);
  - it returns null for anything not in scope;
  - both sides use the same predicate.
- **Tests.** The "a Result is cell_result_t: 24 bytes" test becomes a per-pair
  table checked against the measured rows above.

### C backend (codegen.zig)

- **Instances.** `CType.result` becomes the instance type. An
  `emitResultInstances` pass, beside `emitOptionalInstances`, emits one
  `CELL_DEFINE_RESULT[_UNIT]` per used pair, after typedefs and before
  prototypes.
- **Constructors and matching.** `emitWrap` calls `<base>_ok(x)` /
  `<base>_err(e)`, and match binding reads `temp.as.ok` / `temp.as.err`. Both
  use the exact C type: no casts, no `int32_t` narrowing.
- **Removals.** `resultField` and the `cell_value_t` field table go away.

### typecheck.zig and hir.zig

- **Admission.** `Err` payloads widen to every scalar primitive and
  payload-free enum, the same set `Ok` takes.
- **Patterns.** Pattern bindings stay `copy` (scalars).
- **HIR.** HIR keeps `result_ctor` as it is. Only the admission predicate
  changes, to `abi.resultMember` on both sides.

### llvmemit.zig and mlirmit.zig

- **Types.**
  - Each used pair gets a named type in LLVM,
    `%cell_res_<ok>_<err> = type { i8, <union> }`, where `<union>` is the
    member chosen by clang's rule above, wrapped in `{ }`.
  - MLIR uses the structural
    `!llvm.struct<(i8, !llvm.struct<(<member>)>)>`.
  - Stage 10 compares an indirect type as resolved text, so this spelling must
    resolve to exactly clang's `{ i8, { <member> } }`. With every scalar
    instance now register-placed, stage 10 compares them by size, which is
    also correct.
- **Construction.**
  - Start from `zeroinitializer` (MLIR: `llvm.mlir.zero`) in an alloca of the
    instance type.
  - Store `i8 1` at field 0 for `Ok`.
  - Store the payload through a GEP to field 1, in its own member type (a
    `bool` as `zext` to `i8`).
  - Load the struct.
- **Matching.** Test the `i8` at field 0, then load the member from field 1
  (`trunc` back to `i1` for Bool).
- **Removals.** The `%cell_value` / `%cell_result` preamble lines, MLIR's
  `result_type` constant, and the union-widening code (`sext`/`zext`/`fpext`
  into a 64-bit slot) all go away. Payloads are stored exactly.

## Testing and gate

- **Runtime:** `test_result` is rewritten per instance, with static
  size/offset assertions. The printed check count changes; nothing pins it.
- **abi:** a per-pair layout table test and a classification test (both
  values above).
- **llvmemit/mlirmit:**
  - the instance type text;
  - that a `Result<Int, Int32>` parameter is `[2 x i64]`;
  - a `Result<Bool, Int32>` return as `i64`;
  - an `Err` of a non-int32 `E` stored in its own width.
- **Examples:**
  - `examples/results.cell` must still print 9 on all three backends;
  - a new `examples/results_wide.cell` exercises `Result<Float, Int>` and
    `Result<Bool, Int64>` with a large error value that the old narrowing
    would have truncated, printing the same number on C, LLVM and MLIR.
- **Leaks:** `examples/leaks/owned_scalar_wrappers.cell` stays pinned at 0.
- **Gate:**
  - stage 10 has no disagreement;
  - the prelude signature stage is unchanged, since no prelude function
    returns a Result;
  - `tools/check.sh` verdict is `clean`.

## Docs

- **SPEC:**
  - 3.4: the layout section, the E widening, and removing "narrowed to an
    int32_t code";
  - 10.3: the table row;
  - 10.6: the version string.
- **FEATURES:** TYPE-06 (E widening, per-instance layout) and ABI-02 (version 2
  and instance naming now present for scalar payloads).
- **AGENTS.md:** the Result line.

## Risks and how the plan handles them

- **Signature spelling drift.** Clang's union-member choice is a measured rule.
  The llvmemit/mlirmit tests pin it per pair, and stage 10 would catch any
  drift on every example.
- **A host passing `cell_result_t`.** None exists today. The deprecated names
  stay for one version.
- **Silent behavior change for large `E`.** `Result<Int, Int>` errors that
  exceeded 32 bits were truncated before. They now round-trip.
  `results_wide.cell` pins the new behavior, and FEATURES and SPEC state it.

## Recorded for sub-projects 2-4 (not built here)

- **Moves.** `borrowck.zig` treats `Ok(s)`/`Some(s)` as a *read* of `s`
  (`:2334`, `ownedMoveSource` `.no_owned_place` at `:3442`). With an owning
  payload that is a double free. Sub-project 2 must make construction a move.
- **Pattern keywords.** `Ok(owned s)` / `Ok(shared s)` need parser, typecheck
  and borrowck support (`wrap_pattern` currently has `binding: ?[]const u8`
  only).
- **Drop glue.** Owning instances need generated drop glue that switches on
  `ok`, plugged into `hasDropCall`/`needsDrop`
  (`codegen.zig:1009-1023`). The existing record glue is the model:
  `cell_drop_<Name>`, two passes.
- **`String?` layout mismatch.** `abi.layoutOf(String?)` is 32 bytes (it sizes
  the inner String as owning) while C's `cell_opt_str_t` and LLVM's
  `%cell_opt_str` are 24 (a borrowed `cell_str_t`). Both are indirect, so
  nothing breaks today. Sub-project 4 must reconcile it.
