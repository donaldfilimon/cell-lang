# Owning `String` in `Err` Implementation Plan (sub-project 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, match and release `Result<T, String>` (for every scalar or
unit `T`) and `Result<String, String>` in the C backend. The approach mirrors
sub-project 2 on the error side.

**Architecture:**
- **Runtime:** `CELL_RES_ERRS` gains a `string` error side.
- **Mode rules and move semantics:** the rules sub-project 2 built for `Ok`
  now also apply to `Err` in typecheck and borrowck.
- **Codegen:** it names both owning sides, chooses the glue body per side,
  and binds `.as.err`.
- **abi:** it sizes String sides without admitting them to the IR backends.

**Tech Stack:** as in sub-project 2.

**Spec:** `docs/superpowers/specs/2026-09-17-owning-string-err-and-optional-design.md` (sub-project 3 section; approved 2026-09-17).

## Global Constraints

These are sub-project 2's constraints (`2026-09-17-owning-string-ok.md`),
plus two:
- **Error slug.** It is `string`.
- **Glue name.** It is `cell_drop_res_<ok>_string`, and its body releases
  whichever side is present.

### Task 1: Runtime

- **Tests first.** Add these runtime-test assertions and see them fail:
  - `_Static_assert(sizeof(cell_res_i64_string_t) == 32 ...)`;
  - a `cell_res_string_string_t` built on each side, then released.
- **Implement.** Add `X(pfx, OT, string, cell_string_t)` to `CELL_RES_ERRS`
  and update its comment.
- **Measure.** Add an `r_i64_string` row to
  `tools/measure-result-layouts.sh`.
- **Verify.** Run `zig build test -Dswift=false`, `cell run hello`, and the
  C++ syntax check.
- **Commit.**

### Task 2: typecheck

- **Tests first:**
  - `Err(s)` builds `Result<Int, String>`;
  - `Err(owned e)` and `Err(shared e)` are accepted;
  - a bare `Err(e)` on an owning error is refused with
    "'Err(e)' on an owning payload must say 'owned' or 'shared'";
  - `Result<String, String>` accepts `Ok(owned a)` and `Err(shared b)`;
  - `Some(owned x)` stays refused.
- **Implement:**
  - `Err` admits `String`;
  - an owning payload is `(ok and payload is String) or (err and payload is
    String)`;
  - the mode message names the constructor.
- **Verify, then commit.**

### Task 3: borrowck

- **Tests first:**
  - `Err(s)` moves `s`;
  - `Err(owned e)` consumes on its arm only, and the `Ok` arm keeps the
    Result;
  - `Err(shared e)` borrows;
  - `Err(alias)` is refused.
- **Implement.** `checkWrap` routes `Err` like `Ok` (only `Some` returns
  early). `checkMatch` reads `wp.mode` for `.ok` and `.err`.
- **Verify, then commit.**

### Task 4: abi and codegen

- **Tests first:**
  - `abi.layoutOf(Result<Int, String>)` is 32 and indirect.
  - The out-of-scope legacy test moves to `Result<Int, [Int]>`.
  - Codegen:
    - `Result<Int, String>` lowers to `cell_res_i64_string_t` (the TYPE-06
      test updated);
    - the glue body is `if (!r->ok) cell_string_free(&r->as.err);`;
    - `Result<String, String>` glue frees the side that is present;
    - `Err(owned e)` binds `.as.err` and is released at arm end;
    - `Err(shared e)` binds `cell_string_as_str(&t.as.err)`;
    - a temporary scrutinee is released in arms that do not take its owning
      side;
    - an unresolved `Err(x)` uses the copy fallback.
- **Implement:**
  - abi `layoutOf` sizes String sides as 24/8 (`resultShape` is unchanged,
    so the IR backends still refuse);
  - codegen `resultSlug` answers `string` on either side;
  - `resultSides()` replaces `isOwningResult`, with helpers for each side;
  - glue per side;
  - owning-mode binding for the owning side;
  - the "took" rule per side;
  - the copy fallback for `.err`.
- **Verify** with the full unit suite and the full gate.
- **Commit.**

### Task 5: example, fixture, refusal, docs, push

- **Example.** `examples/results_err_string.cell`, C only, with the answer
  computed by hand, confirmed by `cell run`, and run under ASan.
- **Leak fixture.** `examples/leaks/owned_string_err.cell`, pinned at 0 on
  both witnesses.
- **Falsify:**
  - without the `Err` glue side, the fixture must leak;
  - without the `Err(owned ..)` scrutinee move, the example must show an ASan
    double free.
- **Refusal corpus.** `examples/rejected/owned_err_bare_binding.cell`.
- **Pin and docs.** Add the pin plus the README rows. Update SPEC 3.4 and the
  10.3 row, FEATURES TYPE-06 and PAT-02, OWNERSHIP R7 and R11, AGENTS, and
  the spec status.
- **Finish.** Run the gate and the gate-integrity check, commit, then push by
  the inline SHA.
