# Optional and Result values, then the prelude's group 3

Design, approved 2026-09-16 (Donald, via `/superpowers:brainstorming do all`
in the compiler goal). Two sub-projects, built in this order because the
second depends on the first:

- **B.** Construction and match-inspection of `T?` and `Result<T, E>` values,
  scalar payloads, C backend only.
- **A.** Implementations for every declaration in `stdlib/prelude.cell`'s
  group 3, with the partial ones returning optionals.

Decisions recorded here were taken by Donald and are not open: partial
prelude operations return optionals rather than panicking or truncating;
the spellings are the uppercase `Some`, `None`, `Ok`, `Err`.

## Why

`docs/SPEC.md` 3.2 says an optional "cannot be produced or consumed in Cell
today, only named in a signature"; 3.4 says the same of `Result` since it
began to parse on 2026-09-16. The prelude's group 3 (`stdlib/prelude.cell`)
is "declared here, backed by nothing", and `cell build` shows that as an
undefined `cell_<name>` symbol at link time. Closing group 3 with optional
returns needs B first, so B is the dependency and goes first.

## B. Optional and Result values

### B.1 Grammar

Four new reserved words, added to the lexer's keyword table and to SPEC 2.5's
list: `Some`, `None`, `Ok`, `Err`. Making them keywords is what removes the
collision the uppercase spelling would otherwise have with the parser's rule
that an uppercase bare identifier in a pattern is an enum variant: a user
enum can no longer declare a variant named `Some` or `Ok` at all (it is a
parse error, the same as naming one `while`), so nothing downstream needs a
special case.

Expressions:

```cell
Some(e)      // T? holding e
None         // T? absent
Ok(e)        // Result<T, E> success carrying e
Err(e)       // Result<T, E> failure carrying e
```

Patterns, in `match` arms only:

```cell
Some(x)   Some(_)   None
Ok(x)     Ok(_)     Err(x)     Err(_)
```

The inner pattern is a binding or `_`, nothing else in this slice (no
literal, no nested constructor). `x` binds the payload as a `copy` binding
for the arm.

AST: `Expr.Kind` gains one variant carrying which constructor and an optional
operand (`None` has none); `Pattern.Kind` gains one variant carrying which
constructor and the inner binding name or wildcard.

### B.2 Types and checking

- `Some(e)` has type `T?` where `T` is the type of `e`.
- `None` has no type of its own. It is accepted only where the destination
  declares `T?`: a `let`/`var` with a written type, an assignment into such a
  binding, a `return` from a `-> T?` function, a call argument whose parameter
  is `T?`, a struct-literal field declared `T?`. Elsewhere it is refused with
  "`None` needs a declared optional type here".
- `Ok(e)` and `Err(e)` likewise take `Result<T, E>` from the declared
  destination and are refused without one. `Ok(e)` checks `e` against `T`;
  `Err(e)` checks `e` against `E`.
- **Payload restriction, this slice:** `T` (for both `T?` and `Result`) is one
  of `Int`, `Int32`, `UInt`, `Float`, `Float32`, `Bool`, `Byte`. `E` is
  `Int32` or a payload-free enum. A `String`, list, `arc`, struct, optional
  or `Result` payload is refused with "optional/Result payloads other than
  scalar primitives are not implemented", at construction and at pattern
  binding. This is the ownership boundary: every admitted payload is `copy`,
  so constructing is a read of `e`, a bound `x` is a `copy` binding, nothing
  new is dropped, and R8 has no view to keep inside a block.
- Matching on a `T?` or `Result` scrutinee accepts the four patterns above
  plus `_` and a binding; an enum-variant pattern or a literal against such a
  scrutinee is a type error. Exhaustiveness is not checked, exactly as for
  enums today (a missing arm reaches the existing `cell_panic`).
- borrowck: no new rule. The scrutinee is read; the arm binding is a fresh
  `copy` place. `ownedMoveSource` and `arcUniqueSource` classify the new
  expression kind as `.no_owned_place` / not `arc`, which is true because the
  payload is scalar.
- `hir.lower`, and therefore the LLVM and MLIR backends, refuse the new
  expression and pattern kinds with `cannot lower` at the span. Both refuse
  together, so the gate's agreement stage holds.

### B.3 Lowering (C backend)

The runtime already defines the representations (`runtime/cell_rt.h`):
`CELL_DEFINE_OPTIONAL(cell_opt_<t>, T)` gives `cell_opt_<t>_t` with
`has_value`/`value` and the constructors `cell_opt_<t>_some(v)` /
`cell_opt_<t>_none()`; `cell_result_t { bool ok; int32_t error_code;
cell_value_t value; }` with `cell_ok_i64` / `cell_ok_u64` / `cell_ok_f64` /
`cell_ok_bool` / `cell_ok_unit`. `codegen.zig`'s `optionalInstance` already
maps `T?` to the right `cell_opt_*` instance, generating one for `Float32`
and named types.

Additions:

- `runtime/cell_rt.h`: `static inline cell_result_t cell_err(int32_t code)`
  (`ok = false`, `error_code = code`, value zeroed), plus `cell_ok_i32` if the
  `Int32` payload is admitted (it is; `cell_ok_i64` cannot carry it without a
  silent widening in the union, so it gets its own field write).
- Expressions: `Some(e)` -> `cell_opt_<t>_some(<e>)`; `None` ->
  `cell_opt_<t>_none()` with `<t>` from the destination type, which the
  declared-type funnel (`emitArgLike` / `emitConversion`) already hands to
  every position that has one; `Ok(e)` -> `cell_ok_<t>(<e>)`; `Err(e)` ->
  `cell_err(<e>)`, with an enum `E` cast `(int32_t)`.
- Patterns (`emitPatternTest` and the arm-binding emission beside it):
  `Some(x)` tests `<temp>.has_value` and binds `T x = <temp>.value;`; `None`
  tests `!<temp>.has_value`; `Ok(x)` tests `<temp>.ok` and binds
  `T x = <temp>.value.<field>;` with the union field chosen by `T`
  (`i64`, `u64`, `f64`, `b`; `Int32`, `Float32` and `Byte` read the wider
  field and cast); `Err(x)` tests `!<temp>.ok` and binds
  `int32_t x = <temp>.error_code;` or `cell_E x = (cell_E)<temp>.error_code;`.
- Drops: none. Scalar payloads have no `needsDrop`, and an `owned` `Result`
  stays undropped exactly as SPEC 3.4 already records (its payload cannot be
  resource-bearing in this slice, so that is a leak of nothing).

### B.4 Evidence

- Lexer test: the four words lex as keywords (extend the SPEC 2.5 test).
- Parser tests: each expression and pattern form; `Some` without parentheses,
  `Some(1, 2)`, `Ok()` and a nested `Some(Some(x))` are parse errors with
  the messages the tests pin.
- Typecheck tests: `None` and `Ok`/`Err` without a declared destination are
  refused; a `String` payload is refused at construction and at binding;
  `Err("x")` against `Result<Int, Int32>` is a type error; an enum `E` is
  accepted.
- borrowck test: `Some(n)` reads `n` (a later use is fine); `Some(x)` in an
  arm binds a `copy` place (assignment to it is R14's immutability error).
- codegen tests: exact emitted text for each constructor and each pattern,
  and `expectCompiles`.
- Corpus: `examples/optionals.cell` and `examples/results.cell`, each with
  `// EXPECT-OUTPUT:`, C-only (LLVM/MLIR refuse, together). They join stages
  3, 4, 5, 8 and 9 automatically.
- Docs: SPEC 2.5 (keywords), 3.2 and 3.4 (status to "implemented, scalar
  payloads, C backend"), section 9 (patterns), 0.8 unchanged (the `?`
  propagation refusal stands); `docs/FEATURES.md` rows TYPE-04, TYPE-06,
  PAT-02; `README.md` Status paragraph; `stdlib/prelude.cell`'s note that
  `bytes_pop`'s `Byte?` is unusable becomes history.
- Gate clean, count cited from the log; `tools/sweep-backends.sh` re-run and
  its count explained if it moves.

## A. Prelude group 3

### A.1 Signatures

Every group 3 declaration gets an implementation whose C prototype matches
the emitted one exactly; the check is the one the prelude already documents,
`cell emit stdlib/prelude.cell` diffed against `runtime/cell_rt.h`, and it
becomes a test in `tools/tests/` so it cannot drift silently. Partial
operations change their declared return type in `stdlib/prelude.cell`:

| function | was | becomes | absent when |
|---|---|---|---|
| `str_byte_at(shared s, copy index)` | `Byte` | `Byte?` | index out of range |
| `bytes_at(shared xs, copy index)` | `Byte` | `Byte?` | index out of range |
| `bytes_pop(exclusive xs)` | `Byte?` | `Byte?` (unchanged) | empty |
| `rem_int(copy a, copy b)` | `Int` | `Int?` | `b == 0`, or `a == INT64_MIN && b == -1` |
| `int_from_float(copy v)` | `Int` | `Int?` | NaN, infinite, or outside `int64_t` |
| `int_from_uint(copy v)` | `Int` | `Int?` | `v > INT64_MAX` |
| `uint_from_int(copy v)` | `UInt` | `UInt?` | `v < 0` |
| `int32_from_int(copy v)` | `Int32` | `Int32?` | outside `int32_t` |
| `byte_from_int(copy v)` | `Byte` | `Byte?` | outside `0..255` |
| `abs_int(copy v)` | `Int` | `Int?` | `v == INT64_MIN` (its negation does not fit) |

Total functions stay total: `str_len`, `str_eq`, `str_concat`,
`str_from_int`, `str_from_float`, `str_from_bool`, `eprintln`,
`int_from_int32`, `float_from_int`, `float32_from_float`,
`float_from_float32`, `int_from_byte`, `min_int`, `max_int`, `abs_float`,
`min_float`, `max_float`, `bytes_len`, `bytes_push`,
`bytes_clear`, `bytes_empty`, `bytes_with_capacity`, `arc_retain_string`,
`arc_release_string`, `arc_count_string`.

Group 2 closes on the runtime side, as its own comment says it must:
`cell_rt_version` returns `cell_string_t` (a fresh owned copy of the version
text, so the caller's drop pass releases it like any owned String), and
`cell_panic` takes `cell_str_t`. Both keep their behaviour; the two callers
inside the runtime and the harness are updated with them.

### A.2 Implementation

All in `runtime/cell_rt.c` with prototypes in `runtime/cell_rt.h` under a new
"Prelude" section, C11, `-Wall -Wextra -Werror` clean. `str_concat`,
`str_from_*` and `bytes_empty`/`bytes_with_capacity` return fresh owned
values through the existing `cell_string_from_str`/`cell_slice_alloc`
allocation paths, so the drop pass releases them with no new glue. The
`arc_*` trio wraps `cell_arc_clone`, `cell_arc_drop` and
`cell_arc_strong_count`; `arc_retain_string` returns the clone already
retained, which is R11's release rule 3 for a returned `arc`, and the
callee-releases rule for its `arc` parameter (R11 row 1) is what makes the
count observable.

### A.3 Evidence

- One C harness test per function in `runtime/tests/test_cell_rt.c`
  (`zig build test-runtime`), including every absent case in the table.
- Gate stage 13, "prelude signatures": emits the prelude and asserts every
  group 1 and group 3 prototype appears verbatim in `runtime/cell_rt.h`.
  Its own stage, appended after stage 12, so stages 1 to 12 keep the numbers
  their cross-references use (the same reason stage 11 was appended rather
  than inserted).
- `examples/prelude.cell`: calls every group 3 function, matches the
  optional results, prints one number pinned by `// EXPECT-OUTPUT:`; runs
  through gate stage 12 (`cell run`) as well, which is the "no longer backed
  by nothing" measurement.
- `stdlib/prelude.cell` header: group 3's "backed by nothing" paragraph
  becomes history with the commit hash; the group 2 paragraph likewise.
- `docs/FEATURES.md` CLI-02: prelude half moves from `absent` to
  `checked`/`lowered` for C; `README.md` Status drops "the prelude's group 3
  declarations still resolve to no symbol".

## Out of scope, stated

- Resource-bearing payloads for `T?` and `Result` (a `String?` that owns, a
  `Result<[Int], E>`): needs a drop spelling for the optional and a payload
  union on the error side, both designed later.
- Optional chaining, force unwrap, `?` propagation: SPEC 0.8 refused
  expression-position `?`; nothing here reopens it.
- `cell test` and the R16 drop flags: separate designs, after A lands.
