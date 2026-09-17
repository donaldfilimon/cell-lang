# Owning `String` in `Err` and in `String?` (Result sub-projects 3 and 4)

Status: approved by Donald 2026-09-17 for plan and build (sub-project 3
first). Review answers: `String?` is owning; `Result<String, String>` is in
sub-project 3; both sub-projects proceed.
Parents:
- `2026-09-17-per-instantiation-results-design.md` (sub-project 1, landed).
- `2026-09-17-owning-string-ok-design.md` (sub-project 2, landed through
  `8a0abba`).

These two sub-projects reuse sub-project 2's machinery almost unchanged, so
one document specifies both. Each still gets its own plan and gate.

## Decisions already taken (Donald, 2026-09-17)

- **One exact struct per instantiation.**
- **Payload bindings must name their mode.** A binding on an owning payload
  must say `owned` or `shared`. A bare binding is refused. `_` binds nothing.
- **`owned` consumes on its own arm only.** An `owned` payload binding
  consumes the scrutinee on that arm only. A temporary scrutinee is released
  in every arm that does not take the payload.
- **Release glue is generated per module.**

Defaults chosen here are marked **(default)**.

## What sub-project 2 left behind (measured at `8a0abba`)

- **Pass-through pairs.** `Result<Int, String>` and every other pair with a
  `String` error still lower to the deprecated `cell_result_t` pass-through.
  A payload binding on one fails at cc. The codegen test "TYPE-06: a Result
  type lowers to cell_result_t" pins that pass-through.
- **`String?` is a borrowed view.** It lowers to `cell_opt_str`
  (`{ bool has_value; cell_str_t value; }`, 24 bytes), while
  `abi.layoutOf(String?)` answers 32, the owning size.
  - `Some(s)` with a `String` operand is refused ("scalar payloads only").
  - A `String?` value can therefore only arrive from a declared signature.
  - No corpus file uses it.
- **Modes are parsed on every wrap pattern.** The checker refuses them on
  `Some`/`Err`.

## Sub-project 3: owning `String` in `Err`

### Scope

- **Admitted pairs:** `Result<T, String>` for every scalar or unit `T`, plus
  `Result<String, String>`.
- **Not admitted:** payload-carrying enums in `Err` (FEATURES PAT-02).

### Runtime and naming

- **The `Err` slug is `string`** **(default)**. The instances are
  `cell_res_<ok>_string_t`, 14 in all:
  - 12 scalar `Ok` sides;
  - `unit`;
  - `string` (the `Result<String, String>` instance).
- **Layout.** `Result<Int, String>` is 32 bytes, align 8, with `as` at 8. It
  is passed indirectly and returned through `sret`. Extend
  `tools/measure-result-layouts.sh` to confirm this.
- **Generated glue** releases whichever side owns:

  ```c
  static inline __attribute__((unused)) void cell_drop_res_<ok>_string(cell_res_<ok>_string_t *r) {
      if (!r->ok) cell_string_free(&r->as.err);
  }
  /* For Result<String, String>: */
  /*   if (r->ok) cell_string_free(&r->as.ok); else cell_string_free(&r->as.err); */
  ```

- **ABI version** stays 2.

### Checking, ownership, codegen

- **Construction.** `Err(x)` admits `String` as well as scalars and enums.
- **Patterns.**
  - `Err(owned e)` and `Err(shared e)` are accepted on an owning error.
  - A bare `Err(e)` on an owning error is refused with "'Err(e)' on an owning
    payload must say 'owned' or 'shared'".
  - A mode on a scalar error stays refused, and so does a mode on `Some`
    until sub-project 4.
- **borrowck.**
  - `checkWrap` treats `Err` exactly like `Ok`: the move when the type
    resolves, `wrap_moves`, and the R7/R2.b refusals.
  - `checkMatch` treats `Err(owned e)` / `Err(shared e)` exactly like the
    `Ok` forms.
- **codegen.**
  - `resultSlug` answers `string` on the `Err` side too.
  - `isOwningResult` becomes "either side is `string`".
  - The glue body is chosen per side.
  - Binding, release and temporary-scrutinee logic apply with `.as.err`.
    "Took the payload" means the arm binds the owning side with `owned`.
  - The copy fallback (`cell_string_clone`) applies to `Err(x)`.
- **IR backends.** LLVM and MLIR keep refusing.
- **abi.** The legacy 24-byte branch shrinks to pairs that are still out of
  scope, which after this sub-project is only a non-String aggregate side.
  `layoutOf` answers 32 for these pairs.

### Tests and gate

- **Tests.** Mirror sub-project 2 test for test:
  - runtime asserts and the release;
  - parser (already done);
  - typecheck refusals and acceptance;
  - borrowck move, arm-only consumption, loan and alias;
  - codegen instance, glue per side, bindings, releases and the copy
    fallback.
- **Pass-through pin.** Update the TYPE-06 test: `Result<Int, String>` now
  lowers to `cell_res_i64_string_t` and is released.
- **Example.** `examples/results_err_string.cell`, C only, pinned, covering
  `Result<Int, String>` and `Result<String, String>`.
- **Leak fixture.** `examples/leaks/owned_string_err.cell`, pinned at 0.
  Falsify the release the same way as in sub-project 2.
- **Refusal corpus.** `examples/rejected/owned_err_bare_binding.cell`.

## Sub-project 4: owning `String?`

### The decision this needs

What `String?` means **(default: owning, like `String`)**.

- **Owning (the default).**
  - A new instance, `cell_opt_string` (`{ bool has_value; cell_string_t value; }`,
    32 bytes), makes `String?` in an owned position an owner, like
    `String`.
  - `shared String?` is a borrow of that optional, passed by pointer as other
    aggregates are, per the ownership table.
  - `cell_opt_str` stays in the header for hosts that want a view optional.
    Codegen stops emitting it for `String?`.
  - The `abi.layoutOf` mismatch (32 against 24) disappears, because 32 is
    now right.
- **Alternative (not chosen): keep `String?` as a view** and add no owning
  optional. That is simpler, but `Some(owned_string)` could then never be
  expressed, and every `String?` would be a borrow with no stated lifetime.

### Scope

- **Construction.** `Some(x)` with a `String` operand moves it when its type
  resolves, and is copied otherwise, as in sub-project 2.
- **Patterns.**
  - `Some(owned s)`, `Some(shared s)` and `Some(_)`.
  - `None`.
  - A bare `Some(s)` on `String?` is refused.
- **Also in scope:** releasing on every path; reassigning a
  `var owned o: String? = ...`.
- **IR backends.** LLVM and MLIR keep refusing (`optionPayloadCarried` stays
  false for String).

### Runtime, checking, ownership, codegen

- **Runtime.** Add `CELL_DEFINE_OPTIONAL(cell_opt_string, cell_string_t)` to
  the predefined optionals.
- **Generated glue.** `cell_drop_opt_string(cell_opt_string_t *o)` does
  `if (o->has_value) cell_string_free(&o->value)`.
- **Codegen.**
  - `optionalInstance("String")` becomes `cell_opt_string` with element
    `cell_string_t`.
  - `needsDrop` admits it.
  - Binding, release and temporary-scrutinee logic reuse sub-project 2's
    code with `.value` / `.has_value`.
- **typecheck.** `Some(x)` admits `String`. `Some(owned s)` / `Some(shared s)`
  are accepted on an owning payload; a bare binding is refused.
- **borrowck.** `checkWrap` and `checkMatch` treat `Some` exactly like `Ok`.
- **abi.** `layoutOf(String?)` stays 32, and a test now pins it against
  clang.

### Tests and gate

- **Tests.** Mirror sub-project 2. The typecheck test "scalar payloads only",
  `Some(s)` on `String`, changes into an acceptance of `Some(s)` plus a
  refusal of a bare `Some(s)` pattern.
- **Example.** `examples/optional_string.cell`, C only, pinned.
- **Leak fixture.** `examples/leaks/owned_string_optional.cell`, pinned at 0,
  with falsifications.
- **Refusal corpus.** `examples/rejected/owned_some_bare_binding.cell`.

## Order and risks

- **Order.** Sub-project 3 first: it retires the last legacy pass-through
  that the corpus pins. Sub-project 4 second.
- **Risks.**
  - **`Result<String, String>` glue.** It must release exactly one side.
    Test both arms under ASan.
  - **`String?` changing from a view to an owner** changes the C type of
    every declared `String?` signature. No corpus file or host uses one
    today (grep, 2026-09-17), and stage 10 would catch a mismatch in the
    corpus.
  - **Carried-over residual.** The residuals found in sub-project 2 carry
    over unchanged: yielding an `owned` binding straight from its arm, and a
    temporary scrutinee not released on an arm's early exit.

## Open questions for review

1. `String?` owning (default) or kept as a borrowed view?
2. Include `Result<String, String>` in sub-project 3 (default yes), or only
   `Result<scalar, String>`?
3. Keep the two sub-projects in one approval, with two plans and two gates,
   or review them separately?
