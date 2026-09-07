# Aggregate ABI for the LLVM and MLIR backends

**Status: design, approved 2026-09-07. Not implemented.**

## The problem

`cell emit --target=llvm` and `--target=mlir` refuse every aggregate type.
`String`, `[T]`, `T?`, `Result` and `arc` produce a `cannot lower` diagnostic,
and the MLIR backend refuses structs as well, which is why it refuses
`examples/hello.cell`.

The C backend has no such limit, and the asymmetry is not an oversight. It
writes C, so the C compiler places aggregates according to the platform ABI.
The other two write LLVM IR and MLIR, so *they* choose the calling convention,
and an LLVM `{ptr, i64}` parameter is not what AAPCS64 does with a
`cell_str_t`.

Two facts make this worse, and both are measured rather than assumed:

1. The host is **arm64 (AAPCS64)**, not System V x86-64.
2. Every aggregate **constructor** in `runtime/cell_rt.h` is `static inline`:
   `cell_str_from_parts`, `cell_str_empty`, `cell_string_as_str`,
   `cell_slice_empty`, the whole `CELL_DEFINE_OPTIONAL` family, and every
   `cell_ok_*`. A `static inline` function has no symbol, so neither backend
   can call one. They must materialize those structs themselves.

## The measurement

Run on this machine on 2026-09-07 with Apple clang 21.0.0, target
`arm64-apple-darwin27.0.0`, by compiling a probe that includes
`runtime/cell_rt.h` and reading `cc -S -emit-llvm -O0` output.

Sizes, from `sizeof`/`_Alignof`:

| Type | Size | Align |
|---|---:|---:|
| `cell_str_t` | 16 | 8 |
| `cell_string_t` | 24 | 8 |
| `cell_slice_t` | 24 | 8 |
| `cell_arc_t` | 24 | 8 |
| `cell_opt_i64_t` | 16 | 8 |
| `cell_result_t` | 24 | 8 |
| `cell_value_t` | 16 | 8 |

Struct bodies clang assigns:

```llvm
%struct.cell_str       = type { ptr, i64 }
%struct.cell_string    = type { ptr, i64, i64 }
%struct.cell_slice     = type { ptr, i64, i64 }
%struct.cell_arc       = type { ptr, ptr, ptr }
%struct.cell_opt_i64_s = type { i8, i64 }
%struct.cell_result    = type { i8, i32, %union.cell_value }
```

**Parameters and returns classify differently, and that asymmetry is the whole
reason this needs a classifier rather than a lookup table:**

| Shape | Size | Parameter | Return |
|---|---:|---|---|
| `{double, double}` (HFA) | 16 | `[2 x double]` | `%struct` direct |
| `{double, double, double, double}` (HFA) | 32 | `[4 x double]` | `%struct` direct |
| `{i64, i64}` | 16 | `[2 x i64]` | `[2 x i64]` |
| `{i64, i64, i64}` | 24 | `ptr` | `void` + `sret` param |
| `{i32}` | 4 | `i64` | `i32` |
| `{i64, double}` (mixed, not HFA) | 16 | `[2 x i64]` | not probed |
| `{char, i64}` (padded) | 16 | `[2 x i64]` | not probed |
| `cell_str_t` | 16 | `[2 x i64]` | `[2 x i64]` |
| `cell_opt_i64_t` | 16 | `[2 x i64]` | `[2 x i64]` |
| `cell_string_t` | 24 | `ptr` | `void` + `sret` |
| `cell_slice_t` | 24 | `ptr` | `void` + `sret` |
| `cell_arc_t` | 24 | `ptr` | `void` + `sret` |
| `cell_result_t` | 24 | `ptr` | `void` + `sret` |
| `bool` | 1 | `i1 zeroext` | `i1` |

The two rows marked "not probed" were measured as parameters only. The
implementation must probe them as returns before relying on either; see
Testing.

The rules this implies:

- A **homogeneous float aggregate** (every member the same float type, at most
  four members, recursively) is coerced to `[N x double]` or `[N x float]` as a
  parameter and returned **directly as the struct**. The HFA rule **ignores the
  16-byte cutoff**: a 32-byte four-double aggregate still goes in registers.
- A non-HFA aggregate of **16 bytes or less** is coerced to `[N x i64]`, in
  both positions, where N is the size rounded up to a multiple of 8 and divided
  by 8. A 4-byte aggregate becomes a bare `i64` as a parameter and the
  underlying scalar type as a return.
- A non-HFA aggregate **larger than 16 bytes** is passed as `ptr` and returned
  through an `sret` pointer parameter with the function returning `void`.
- `bool` is `i1` and carries `zeroext` at a C boundary.

## A defect this measurement exposed

`src/cell/llvmemit.zig` already emits `%cell_Point = type { double, double }`
and passes it **directly**. AAPCS64 says `[2 x double]`.

This is currently harmless because struct passing is Cell-to-Cell inside one
emitted module, so both sides use the same wrong convention consistently and
agree. It breaks the moment a struct crosses to C, and `examples/hello.cell`
declares exactly such a struct. It is a latent bug, not a theoretical one, and
it is fixed first (see Sequencing).

## Design

### `src/cell/abi.zig`

A **leaf module**. It imports `types.zig` and `hir.zig` for type shapes and
nothing else, so it is testable standalone and neither backend can smuggle
target knowledge past it.

```zig
pub const Class = union(enum) {
    /// Passed and returned as this LLVM scalar: "i64", "double", "i1".
    direct: []const u8,
    /// Coerced to [n x i64].
    coerce_int: u32,
    /// Coerced to [n x elem], where elem is "double" or "float". HFA only.
    coerce_float: struct { n: u32, elem: []const u8 },
    /// Parameter: a plain `ptr`. Return: `void` plus an `sret` pointer
    /// parameter prepended to the signature.
    indirect,
    /// This backend does not know how to place this type. The caller emits a
    /// `cannot lower` diagnostic and the module is not emitted.
    unclassified,
};

pub fn classifyParam(m: *const hir.Module, ty: hir.Ty) Class;
pub fn classifyReturn(m: *const hir.Module, ty: hir.Ty) Class;
```

**Two entry points, not one with a flag.** The measurement above shows the two
positions genuinely disagree for HFAs and for the indirect case. A single
`classify` would force every caller to remember the asymmetry, which is how it
gets forgotten at one call site and not the others.

### Layout knowledge

`abi.zig` needs `size(ty)` and `isHfa(ty)`, neither of which exists today.

They are computed **in `abi.zig`**, from the struct declarations already
carried in `hir.Module`. `types.zig` is not extended. That file's header
states that ownership is deliberately not part of a type; layout is the same
kind of separation, and a `Ty` that knows its own size on one target stops
being a source-language type.

`size` follows the C rules the header already relies on: each field aligned to
its own alignment, the struct aligned to its widest member, trailing padding to
a multiple of that alignment. `isHfa` is recursive: a struct is an HFA when every member is the same float
type or is itself an HFA of that same type, and the count of **leaf** members
across the whole nesting is at most four. Counting top-level members instead
would classify a two-member struct of two-double structs as an HFA of two when
it is an HFA of four, and a five-leaf aggregate would be misclassified as
register-passed. The unit tests pin the nested case for this reason.

### Constructors

Neither backend may call a `static inline` constructor, because there is no
symbol. They materialize the structs directly:

- **16 bytes or less:** an `insertvalue` chain, producing a first-class value
  that can be returned or passed.
- **Larger than 16 bytes:** `alloca` plus field stores through
  `getelementptr`, then pass the pointer.

`runtime/cell_rt.h` is **not modified**. `AGENTS.md` states the header and
codegen change together, and adding out-of-line copies of the constructors to
dodge an ABI problem is the rejected approach 2: it widens the runtime's
exported surface permanently to avoid writing a classifier once.

### Error handling

`unclassified` preserves the behavior both backends already have: a
`cannot lower` diagnostic at the offending span, and **no output at all**.
`root.emitFor` buffers emission and writes to the caller only on success, so a
partly-classified module cannot leave a truncated file on disk.

Everything not confirmed by the probe test lands in `unclassified`: unions,
aggregates with more than four float members, nested aggregates the HFA rule
does not cover, and any type added later. A backend that refuses is a fact
about the compiler; a backend that guesses is a crash in someone's program.

## Testing

### The clang-comparison test, which is the load-bearing one

For each shape in the measurement table, the test:

1. writes a C probe declaring a function that takes and one that returns that
   type,
2. runs `cc -S -emit-llvm -O0` on it,
3. extracts the `define` line,
4. asserts that `classifyParam` and `classifyReturn` predicted **that exact
   signature**.

This is a live comparison against the compiler that owns the ABI, not a golden
file. A golden file records what clang did once; this records what clang does
now. A hand-written ABI that nothing checks is one that rots silently, and the
rot surfaces as a wrong answer in a linked program rather than as a build
failure.

It **skips** when `cc` is unavailable, following the precedent already set by
the MLIR execution test in `src/cell/mlirmit.zig`, which skips rather than
passing vacuously when `mlir-opt` is absent.

The two "not probed" rows in the measurement table are covered by this test on
its first run; the table is the starting hypothesis, the test is the authority.

### Execution tests

Structural agreement is not enough, because a signature can match while the
value in it is wrong. At least:

- a Cell program passing a `String` to `cell_print` through the LLVM backend,
  linked against `runtime/cell_rt.c` and run, asserting what it printed;
- a Cell program returning a struct across the C boundary, linked and run;
- one `>16B` case exercising the `sret` path end to end.

These use `cc`, not `zig cc`: `zig cc -x ir` fails with
`language not recognized: ir`, measured.

### Unit tests

`abi.zig` gets direct tests for `size` and `isHfa`, including the cases the
classifier keys off: a four-double HFA at 32 bytes classifying as float
coercion despite exceeding 16 bytes, a mixed `{i64, double}` at 16 bytes
classifying as integer coercion because it is not an HFA, and a
single-`i32` struct classifying as a bare scalar.

## Sequencing

Each step ends at a green gate: `zig build -Dswift=false`, `zig build test
-Dswift=false`, the four `examples/README.md` corpus contracts, and
`examples/backends.cell` printing 24 through all three backends.

0. **Fix `%cell_Point`.** Pass HFA structs as `[2 x double]`. Add a test that a
   struct crosses to C correctly, which is the test whose absence let this
   defect ship. No new types yet.

   **This step changes a shipped test.** `src/cell/llvmemit.zig:956` asserts
   `%cell_Point = type { double, double }`. The type DEFINITION is correct and
   stays; what changes is how a value of it is passed and returned, so that
   assertion should survive while the surrounding signature assertions change.
   Verify that rather than assuming it: if the test does need editing, edit it
   in the same commit as the fix and say why in the message, because a test
   changed to match new output is the exact shape of a test changed to hide a
   regression.
1. **`abi.zig` plus the clang-comparison test.** No backend changes. The
   classifier is proven against clang before anything depends on it.
2. **LLVM adopts it**, in order: `String` (`cell_str_t`, the 16-byte coercion
   case), then `T?`, then the `>16B` indirect and `sret` cases.
3. **MLIR structs**, then the same aggregate set.

Step 0 comes first because adding aggregates on top of a broken struct
convention means every new type inherits the bug, and the test that would catch
it is the same test.

## Out of scope

- `arc` retain and release insertion (OWNERSHIP R11), drop insertion (R16,
  R17), and non-lexical lifetimes. These share a control-flow graph and are a
  separate design.
- `arc` boxing, which makes an `arc` value constructible at all. Today
  `examples/arc.cell` emits C that does not compile because nothing calls
  `cell_arc_new`. That is a separate, smaller design, and this one only has to
  place a `cell_arc_t` correctly once one exists.
- Any target other than arm64. The classifier is written against AAPCS64 as
  clang implements it here. A second target needs its own measurement, and the
  probe test is what would tell you the classifier is wrong on it.
- Re-seating the C emitter on the HIR. Unrelated, and separately risky.
