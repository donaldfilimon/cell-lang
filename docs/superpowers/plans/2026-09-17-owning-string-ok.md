# Owning `String` in `Ok` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the C backend build, pass, match and release `Result<String, E>` for every scalar or enum `E`. `Ok(x)` moves `x`, `Ok(owned s)` consumes the Result only on the arm taken, and `Ok(shared s)` borrows it. A bare `Ok(s)` is refused.

**Architecture:**
- **Runtime:** it predefines 12 `cell_res_string_<err>_t` instances.
- **Parser:** it records an optional ownership mode on every wrap pattern, and typecheck refuses the modes that mean nothing.
- **borrowck:** construction and `Ok(owned ..)` arms become real moves, handled by the existing move, merge and exit-liveness machinery.
- **codegen:**
  - it emits per-module release glue `cell_drop_res_string_<err>` and treats such a Result as droppable;
  - it binds payloads by mode;
  - it releases a temporary scrutinee in every arm that does not take the payload.
- **IR backends:** they keep refusing.

**Tech Stack:** Zig master (`zig build -Dswift=false`), C11 runtime, clang, AddressSanitizer, `leaks`.

**Spec:** `docs/superpowers/specs/2026-09-17-owning-string-ok-design.md` (approved 2026-09-17, review answers applied).

## Global Constraints

- **Gate:**
  - `tools/check.sh` with verdict `clean`;
  - exit codes are read from the command, never through a pipe;
  - every build passes `-Dswift=false`.
- **Names:**
  - The owning `Ok` slug is `string`.
  - The release glue is `cell_drop_res_string_<err>`, generated per module with `static inline __attribute__((unused))`.
- **ABI version stays 2.**
- **`Ok(_)` is allowed:** no move, no borrow.
- **Mode refusals:**
  - `Ok(owned _)` and `Ok(shared _)` are refused.
  - On an owning payload, only `owned` and `shared` are accepted.
  - Any mode on a scalar payload, on `Some(..)` or on `Err(..)` is refused.
- **`--test-filter` passes falsely.** Always confirm the named test appears in the output.
- **Id agreement.** A droppable arm binding must take borrowck's binding id in declaration order. If ids can't be matched, fall back to non-droppable, which only leaks.
- **Style:** no em dashes.
- **Workflow:** commit per task, and push only after Task 7's gate is clean.

## How the steps are written

Sub-project 1's plan quoted final code. This plan names:
- the exact site;
- the test that must fail first;
- the shape of the change.

Several sites are long functions whose current text must be read at execution time (borrowck's owned-argument path, codegen's match and drop passes). Each step still ends in a named, runnable check.

---

### Task 1: Runtime instances for an owning `Ok`

**Files:**
- Modify: `runtime/cell_rt.h`, the `CELL_RES_OKS` list.
- Modify: `runtime/tests/test_cell_rt.c`, the static asserts and `test_result`.
- Modify: `tools/measure-result-layouts.sh`.

- [ ] **Step 1: Write the failing test.**
  - Add `_Static_assert(sizeof(cell_res_string_i32_t) == 32 && _Alignof(cell_res_string_i32_t) == 8 && offsetof(cell_res_string_i32_t, as) == 8, "cell_res_string_i32_t layout");`.
  - In `test_result`, add:

    ```c
    cell_res_string_i64_t so = cell_res_string_i64_ok(cell_string_from_cstr("payload"));
    CHECK(so.ok && so.as.ok.len == 7);
    cell_string_free(&so.as.ok);
    cell_res_string_i64_t se = cell_res_string_i64_err(INT64_C(5000000000));
    CHECK(!se.ok && se.as.err == INT64_C(5000000000));
    ```

  - Run `zig build test -Dswift=false`. Expected: it fails with `cell_res_string_i32_t` undeclared.
- [ ] **Step 2: Add the instances.** Add `Y(cell_res_string, cell_string_t)` to `CELL_RES_OKS`. Move the Result block below the `cell_string_t` typedef if needed; the header defines strings at about line 163, before the Result section.
- [ ] **Step 3: Extend the measurement script.** Add a `cell_string_t` row to `tools/measure-result-layouts.sh`:
  - add `#include "cell_rt.h"`;
  - compile with `-I runtime`;
  - add `r_string_i32` with `f7(r_string_i32 a)`.
  - Run it. Expected: `define void @f7(ptr ... sret(...), ptr ...)`.
- [ ] **Step 4: Verify.**
  - `zig build test -Dswift=false` returns EXIT 0.
  - `zig build -Dswift=false && zig-out/bin/cell run examples/hello.cell` prints 42.
  - `c++ -std=c++17 -fsyntax-only -I runtime runtime/cell_rt.cpp` returns 0.
- [ ] **Step 5: Commit** with the message `feat(runtime): owning String Ok instances (cell_res_string_*)`.

### Task 2: A mode on wrap patterns (ast, parser)

**Files:**
- Modify: `src/cell/ast.zig:122` (`wrap_pattern`).
- Modify: `src/cell/parser.zig` (wrap pattern parse, about 588-595; tests about 1187-1204).

- [ ] **Step 1: Write the failing parser test.** It parses `match r { Ok(owned s) => 1, Ok(shared t) => 2, Err(e) => 3, Some(copy x) => 4, Ok(_) => 5 }` and asserts:
  - `mode == .owned` on arm 0;
  - `mode == .shared` on arm 1;
  - `mode == null` on arm 2;
  - `mode == .copy` on arm 3;
  - `binding == null` and `mode == null` on arm 4.

  Run `zig test src/cell/parser.zig --test-filter "wrap patterns carry an ownership mode"`. Expected: it fails to compile, because there is no `mode` field.
- [ ] **Step 2: Change the AST and parser.**
  - Change the AST to `wrap_pattern: struct { ctor: Ctor, binding: ?[]const u8, mode: ?Ownership = null }`.
  - In the parser, after `expect(.l_paren)`, call `const mode = self.parseOwnership();` and store it.
  - `Some(owned _)` parses as `mode = .owned` with `binding = null`.
  - Update every constructor of `wrap_pattern` found by `grep -n "wrap_pattern = " src/cell/*.zig` to pass `.mode`, or rely on the default.
- [ ] **Step 3: Verify.** `zig test src/root.zig` passes in full; confirm the new test name appears in the output.
- [ ] **Step 4: Commit** with the message `feat(parser): an optional ownership mode on wrap patterns`.

### Task 3: typecheck admission and mode rules

**Files:**
- Modify: `src/cell/typecheck.zig`:
  - the `.ok` wrap arm (about 572);
  - wrap-pattern binding (about 483-515);
  - `isScalarPayload` (about 824);
  - tests.

- [ ] **Step 1: Write the failing tests.** Use one `TestModule` per case, with the message text pinned.
  - **Accepted:**
    - `let r: Result<String, Int32> = Ok(s)` where `s` is an `owned String` parameter;
    - `match r { Ok(owned s) => .., Err(e) => .. }`;
    - `match r { Ok(shared s) => .., Err(_) => .. }`;
    - `match r { Ok(_) => .., Err(_) => .. }`.
  - **Refused**, each with its message:
    - bare `Ok(s)` on `Result<String, Int32>`: "'Ok(s)' on an owning payload must say 'owned' or 'shared'";
    - `Ok(exclusive s)`, `Ok(arc s)` and `Ok(copy s)` on an owning payload: "only 'owned' or 'shared' can bind an owning payload";
    - `Ok(owned v)` on `Result<Int, Int32>`: "a scalar payload is copied; remove 'owned'";
    - `Some(owned x)` and `Err(owned e)`: "a mode on 'Some'/'Err' payloads is not implemented";
    - `Ok(owned _)`: "a wildcard binds nothing; remove 'owned'".
  - **Still refused:** `Some(s)` with a `String` operand ("scalar payloads only").
  - Run `zig test src/root.zig --test-filter "owning payload"`. Expected: FAIL.
- [ ] **Step 2: Implement.**
  - `.ok` construction admits `payload.tag() == .string` as well as scalars.
  - The pattern arm computes `owning = wp.ctor == .ok and payload.tag() == .string`.
  - It applies the mode table from the spec.
  - It declares the binding:
    - owning `owned` binds type `String` with `.owned`;
    - owning `shared` binds type `String` with `.shared`;
    - otherwise it binds `.copy` as today.
- [ ] **Step 3: Verify.**
  - The full `zig test src/root.zig` passes.
  - The typecheck test "scalar payloads only" is unchanged and passing.
- [ ] **Step 4: Commit** with the message `feat(typecheck): owning String Ok and wrap-pattern mode rules`.

### Task 4: borrowck moves

**Files:**
- Modify: `src/cell/borrowck.zig`:
  - `checkExpr` `.wrap` (about 2510);
  - `ownedMoveSource` `.wrap` (about 3634);
  - `wrapPayloadBody` (about 3473);
  - `checkMatch` wrap-binding declare (about 2652);
  - the test at about 10395.

- [ ] **Step 1: Write the failing tests.** They use the `expectAccepted` / `expectRejectedWith` / `LiveHarness` helpers, with a prelude that declares `take(owned s: String)`, `keep(owned r: Result<String, Int32>)` and `view(shared s: String) -> Int`.
  1. `let r: Result<String, Int32> = Ok(s)` followed by `take(s)` is refused: "use of 's' after it was moved".
  2. `match r { Ok(owned x) => take(x), Err(_) => {} }` followed by `keep(r)` is refused: "use of 'r' after it was moved".
  3. `match r { Ok(owned x) => take(x), Err(_) => keep(r) }` is accepted, because the `Err` arm still owns `r`.
  4. `match r { Ok(shared x) => { keep(r) } , Err(_) => {} }` is refused with the existing R6 live-loan message; confirm its exact text first with `grep -n "while it is borrowed" src/cell/borrowck.zig`.
  5. `match r { Ok(shared x) => view(x), Err(_) => 0 }` followed by `keep(r)` is accepted.
  6. `Ok(y)` where `y` is a match-arm alias is refused with the R7 alias message.
  7. `while .. { match r { Ok(owned x) => take(x), Err(_) => {} } }` is refused with the R2.a loop message.
  8. **Liveness:** after (3), `liveAtExit(.branch_end, <Err arm key>, r)` is true and `wasMoved(r)` is true.
  9. The old test "Some reads its operand and a wrap-pattern binding is a copy" still passes for `Some` and scalar `Ok`. Add an owning twin asserting that `Ok(s)` moves.

  Expected: tests 1, 2, 6, 7 and 9 fail.
- [ ] **Step 2: Construction.**
  - In `checkExpr`'s `.wrap`, when the operand's resource shape is owning, run the owned-argument sequence the call path uses:
    - read `checkCall`'s owned branch (about 2791-2878) and factor its "ownedMoveSource then movePlace" body into `fn consumeOwned(self, expr, note) !void` if it is not already one;
    - call it with the note "moved by Ok".
  - `ownedMoveSource`'s `.wrap` returns the operand's own source when owning.
  - Scalar operands keep today's read.
- [ ] **Step 3: Arm bindings.**
  - In `checkMatch`, for a wrap pattern with `mode == .owned` on an owning payload:
    - declare the binding `.owned` with `.arm_origin = .temp`;
    - if `scrutinee_place != null`, call `movePlace(scrutinee_place, "moved by Ok(owned ..)")` after `pushScope` and before `checkExpr(arm.body)`.
  - For `mode == .shared`:
    - declare the binding `.shared`;
    - create a lexical shared loan on `scrutinee_place` for the arm scope. Use the same call `checkLet` uses for a `shared` borrow binding (`grep -n "createLoan" src/cell/borrowck.zig`), scoped so `popScope` truncates it.
  - `wrapPayloadBody` returns a move source for an owning `owned` binding.
- [ ] **Step 4: Verify.** The full `zig test src/root.zig` passes, and all 9 test names appear.
- [ ] **Step 5: Commit** with the message `feat(borrowck): Ok(x) moves an owning payload; Ok(owned ..) consumes on its arm`.

### Task 5: codegen types, glue, bindings, releases

**Files:**
- Modify: `src/cell/codegen.zig`:
  - `resultSlug` (about 3465);
  - `recordNeedsDrop` / `emitDropGlue` (about 1067-1133);
  - `needsDrop` (about 1050);
  - `emitDropFor` (about 1142);
  - `reassignedDroppableLocal` (about 999);
  - wrap-pattern binding (about 2117-2148);
  - `emitMatch` / `emitArmBody` (about 2012-2088);
  - tests.

- [ ] **Step 1: Write the failing codegen tests** (`emitSource`, `fnDef`, `expectContains`, `expectCompiles`).
  1. **Type:** `pub fn read() -> Result<String, Int32>;` emits `cell_res_string_i32_t cell_read(void);`.
  2. **Glue:** the module emits `static inline __attribute__((unused)) void cell_drop_res_string_i32(cell_res_string_i32_t *r)` once, with body `if (r->ok) cell_string_free(&r->as.ok);`. A module without such a Result emits no glue.
  3. **Construction:** `return Ok(s)` for an `owned s: String` parameter gives `return cell_res_string_i32_ok(s);` and no `cell_string_free(&s)` in that function.
  4. **Owned binding:** `match r { Ok(owned x) => take(x), Err(_) => {} }` with `owned r` gives:
     - `cell_string_t x = _cell_tN.as.ok;`;
     - no free of `x` (it was moved to `take`);
     - exactly one `cell_drop_res_string_i32(&r);`, on the `Err` path or after the match on that path, never on the `Ok(owned)` path.
  5. **Arm end:** `Ok(owned x) => view(x)` gives `cell_string_free(&x);` at arm end.
  6. **Shared binding:** `Ok(shared x) => view(x)` gives `cell_str_t x = cell_string_as_str(&_cell_tN.as.ok);`, no free of `x`, and one release of `r` after the match.
  7. **Temporary scrutinee:** `match read() { Ok(owned x) => take(x), Err(_) => 0 }` gives `cell_drop_res_string_i32(&_cell_tN);` in the `Err` arm only.
  8. **Reassignment:** `var owned r: Result<String, Int32> = read(); r = read()` gives `cell_drop_res_string_i32(&r);` before the store.
  9. `expectCompiles` on each.

  Expected: all fail.
- [ ] **Step 2: Type and glue.**
  - `resultSlug` returns `"string"` for an `Ok` side named `String`, in a separate branch; `scalarSlug` is unchanged.
  - Collect owning Result pairs the way `recordNeedsDrop` collects records.
  - Emit prototypes, then definitions, in the same pass that writes record glue.
- [ ] **Step 3: Drop plumbing.**
  - `needsDrop` returns true for a `.result` CType whose text starts with `cell_res_string_`.
  - `hasDropCall` stays unchanged.
  - `emitDropFor` gets a `.result` arm: `cell_drop_<base without cell_ and _t>(&name);` (so `cell_drop_res_string_i32`).
  - `reassignedDroppableLocal` admits it.
- [ ] **Step 4: Bindings.**
  - `owned` binds `ty` (`cell_string_t`) from `temp.as.ok`, pushed droppable with borrowck's id. Match borrowck's declare order: the wrap binding is declared after `pushScope` for the arm.
  - `shared` binds `cell_str_t` through `cell_string_as_str(&temp.as.ok)`, not droppable.
- [ ] **Step 5: Releases.**
  - **Place scrutinee:** the existing `branch_end` / block-end releases apply once `needsDrop` is true and borrowck records exist; verify test 4.
  - **Temporary scrutinee:** in `emitMatch`, when the scrutinee is not a place and its type needs a drop, emit `cell_drop_…(&_cell_tN);` at the end of every arm that is not `Ok(owned ..)`, and before any early exit inside such an arm.
- [ ] **Step 6: Verify.** The full `zig test src/root.zig` passes, and all 8 test names appear.
- [ ] **Step 7: Commit** with the message `feat(codegen): release and bind owning String Results`.

### Task 6: Examples, leak fixture, refusal corpus

**Files:**
- Create: `examples/results_string.cell`.
- Create: `examples/leaks/owned_string_result.cell`.
- Create: `examples/rejected/owned_payload_bare_binding.cell`.
- Modify: `tools/check.sh` (a `LEAK_OWNED_STRING_RESULT` pin and a row), `examples/README.md`, `examples/leaks/README.md`.

- [ ] **Step 1: The example.** `examples/results_string.cell` (C only; the IR backends refuse it together).
  - A `parse(copy n: Int) -> Result<String, Int32>` that returns `Ok(str_from_int(n))` or `Err(code)`.
  - Matched with `Ok(owned s)`, `Ok(shared s)`, `Ok(_)` and `Err(e)` in different functions.
  - One reassigned `var`.
  - The result is printed as a sum of lengths and codes, with an `EXPECT-OUTPUT` pin computed by hand and confirmed by `zig-out/bin/cell run`.
- [ ] **Step 2: The leak fixture.** `examples/leaks/owned_string_result.cell` runs the same shapes 1000 times. Measure it with the counter and `leaks` (the pattern of `run_c_leaks`). Expected: 0 and 0. Also build it with `-fsanitize=address` and run it: exit 0.
- [ ] **Step 3: Falsify.**
  - Temporarily remove the temporary-scrutinee release in codegen and confirm the fixture's count rises.
  - Temporarily make `Ok(owned ..)` skip the scrutinee move in borrowck and confirm that test 3's program under ASan reports a double free.
  - Restore both. Confirm with `git diff --stat` that only the intended files differ.
- [ ] **Step 4: The refusal corpus file.** It has a `// EXPECT: currently-rejected` line and a bare `Ok(s)` on an owning payload.
- [ ] **Step 5: Pin and document.** Add the pin plus `run_c_leaks owned_string_result "" "$LEAK_OWNED_STRING_RESULT" "owning String Ok, 2026-09-17"`, and update both README tables.
- [ ] **Step 6: Commit** with the message `test: owning String Result example, leak fixture and refusal`.

### Task 7: Docs, gate, push

- [ ] **Step 1: Docs.**
  - SPEC 3.4 (owning `Ok`, pattern modes), the pattern grammar section, and the 10.3 row.
  - FEATURES TYPE-06 and the PAT row.
  - OWNERSHIP R2 (construction moves), R7 (`Ok(owned ..)` consumes on its arm, `Ok(shared ..)` borrows) and R11 (Result release glue).
  - AGENTS.md's Result line.
  - The spec's status line (implemented).
- [ ] **Step 2: Gate.**
  - `sh tools/check-rule-lists.sh` returns 0.
  - `tools/check.sh > log 2>&1; echo EXIT $?` shows the verdict `clean`, `results_string` in the answers stage as `C` with its value, and `owned_string_result -> 0`.
  - `sh tools/tests/test-gate-integrity.sh` returns 0.
- [ ] **Step 3: Commit and push.** Fetch, then push by the inline SHA, then check that `ls-remote` equals HEAD.
