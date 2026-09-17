# Owning `String` in `Ok` (Result sub-project 2)

Status: approved by Donald 2026-09-17 for plan and build, with his review answers applied (see the last section): `Ok(_)` is allowed, and the release helper is generated per module.
Parent: `2026-09-17-per-instantiation-results-design.md` (sub-project 1,
landed through `0a29df3`).

## Decisions already taken (Donald)

From the parent design (2026-09-17):
- **Layout.** One exact struct per pair.
- **Pattern modes.**
  - A binding on an owning payload must say its mode: `Ok(owned s)` moves the payload out, and `Ok(shared s)` borrows it.
  - A bare `Ok(s)` on an owning payload is refused.
- **Construction.** `Ok(s)` moves `s`.

Added 2026-09-17 in this session:
- **`Ok(owned s)` consumes the Result only on the arm taken.**
  - The other arms (`Err(..)`, `Ok(_)`, `Ok(shared s)`) leave it alive.
  - It is released after the match on those paths.
  - This reuses the branch-end release machinery that closed the one-branch-move leak (`branch_move.cell`).
- **A temporary scrutinee** (`match read() { .. }`, not a place) is released by codegen in every arm that does not take the payload.

Everything below not listed above is a default chosen while writing and is
open to review. The defaults are marked **(default)**.

## What is broken or missing today (measured at `0a29df3`)

- **Pattern binding.**
  - A declared `Result<String, Int32>` matched with `Ok(s) => ..` passes `cell check` (exit 0).
  - The C backend emits `cell_string_t s = cell_res_unsupported_payload;`, because the pair has no instance.
  - The only refusal is cc.
- **Construction is a read.** borrowck treats `Ok(s)` construction as a read:
  - `checkExpr`'s `.wrap` arm (`borrowck.zig:2510`);
  - `ownedMoveSource`'s `.wrap => .no_owned_place` (`:3634`);
  - `wrapPayloadBody` (`:3473-3484`) is written on the premise that a payload is a scalar copy.
- **Arm bindings.**
  - A wrap binding is declared `.copy` (`:2652-2666`).
  - So `match r { Ok(s) => take(s) }; keep(r)` passes borrowck. That becomes a double free the day codegen can lower it.
- **No drop spelling.**
  - A Result has none (`hasDropCall`/`needsDrop` are false for `.result`).
  - Arm bindings are pushed non-droppable (`codegen.zig:2142`).
  - `emitArmBody` emits no drop at arm end.
- **Already refused.** `copy` on this type is already refused ("may own resources", `borrowck.zig:4668`). That stays.

## Scope

- **In:** `Result<String, E>` where `E` is a scalar primitive or a payload-free enum. This is the 12 `Err` sides sub-project 1 defines.
- **Construction, pattern and move semantics:**
  - `Ok(owned s)`, `Ok(shared s)`, and `Ok(_)`;
  - `Err(e)` and `Err(_)`;
  - `_`;
  - arm values, early `return`/`break` out of an arm;
  - reassignment of a `var` Result;
  - passing and returning by value (`owned`/`shared`/`exclusive` parameter modes as for other owning aggregates).
- **C backend only.** LLVM and MLIR keep refusing any Result with a `String` side. The IR String work is a separate program, decided the same day: conversions, indexing, list literals, then a drop pass ported to HIR.
- **Non-goals:**
  - owning `Err` (sub-project 3);
  - `String?` (sub-project 4);
  - `arc` payloads;
  - `Some(owned x)` / `Err(owned e)` semantics.

## Runtime (`runtime/cell_rt.h`)

- **Instances.**
  - Add `cell_string_t` as an `Ok` side: `Y(cell_res_string, cell_string_t)` in `CELL_RES_OKS`.
  - That adds 12 instances, `cell_res_string_<err>_t`.
  - The slug is `string`, not `str`, because `str` is the borrowed view **(default)**.
- **Drop helper.** Generated per module by codegen (Donald's review answer), beside the record drop glue and in the same two-pass shape (prototypes, then definitions), only for the owning Result pairs the module names:

  ```c
  static inline __attribute__((unused)) void cell_drop_res_string_<err>(cell_res_string_<err>_t *r) {
      if (r->ok) cell_string_free(&r->as.ok);
  }
  ```

  - `cell_string_free` must tolerate a moved-from value the same way it does today.
- **Layout.** Measured by `tools/measure-result-layouts.sh` extended with the instance: size 32, align 8, `as` at 8. AArch64 passes it by pointer to a copy and returns it through `sret`.
- **ABI version.** It stays **2** **(default)**: layouts are only added, never changed.
- **Assertion.** Add a `_Static_assert` row for `cell_res_string_i32_t` to the runtime test.

## Syntax (parser.zig, ast.zig)

- **AST.** `wrap_pattern` gains `mode: ?ast.Ownership` (`ast.zig:122`).
- **Parser.** It calls the existing `parseOwnership()` between `(` and the binding (`parser.zig:589`), for every constructor.
- **Where refusals live.** The checker refuses the combinations that are not allowed. That keeps the grammar uniform and the error messages specific **(default)**.

## Checking (typecheck.zig)

- **Construction.** `Ok(x)` admits `String` as well as the scalars; `Some` and `Err` do not change.
- **Pattern modes.** For a wrap binding:
  - **Owning payload** (`Ok` side of a `Result<String, E>`):
    - `owned` and `shared` are accepted.
    - A bare binding is refused: "`Ok(s)` on an owning payload must say `owned` or `shared`".
    - `exclusive`, `arc` and `copy` are refused **(default)**.
  - **Scalar payload:** any mode is refused ("a scalar payload is copied; remove `<mode>`") **(default)**.
  - **`Some(..)` and `Err(..)`:** any mode is refused until sub-projects 3 and 4.
  - **`Ok(owned _)` / `Ok(shared _)`:** refused ("a wildcard binds nothing") **(default)**. `Ok(_)` is accepted and neither moves nor borrows (Donald's review answer).
- **Binding type.** A `shared` binding is a `String` view; an `owned` binding is an owned `String`.
- **Declared types.** A declared `Result<String, E>` with an `E` outside scope keeps today's behaviour (cc refuses) **(default)**. Refusing it at the type would break the `Result<Int, String>` pass-through pinned by sub-project 1, which is sub-project 3's to change.

## Ownership (borrowck.zig)

1. **Construction moves.** `Ok(x)`'s operand goes through the owned-argument path:
   - `ownedMoveSource` first, where a match alias is refused (R7) and an undecidable source is refused (R2.b);
   - then `movePlace`.
   - The `.wrap` arms of `checkExpr`, `ownedMoveSource` and `wrapPayloadBody` change only for an owning payload. Scalar payloads stay reads.
2. **`Ok(owned s)`, only on the arm taken.**
   - The arm's entry state moves the scrutinee place with `movePlace(scrutinee, "moved by Ok(owned ..)")`.
   - `s` is declared `.owned` with `arm_origin = .temp`, so R2/R6/R14 apply to it and R7's alias refusal does not fire (the scrutinee really is consumed).
   - The existing per-arm `dead` merge makes the scrutinee maybe-dead after the match.
   - The existing `branch_end` records let codegen release it on the arms that did not move it.
   - A use after the match is refused by R2 as for any maybe-moved place.
3. **`Ok(shared s)`** creates a lexical shared loan on the scrutinee for the arm body. `s` is a borrowed view, and R4/R6 then refuse moving or reassigning the scrutinee inside the arm.
4. **Arm values.** `Ok(owned s) => s` is a move of `s` into the destination (`wrapPayloadBody` becomes a move source for an owning `owned` binding). `Ok(shared s) => s` in an owned destination is refused like any borrow escaping (R5).
5. **Temporary scrutinee.** No place exists, so nothing is recorded. Codegen's release rule below covers it.
6. **Reassignment.** A `var` Result's store takes the existing `assign_liveness` pre-drop.
7. **Loops.** A Result moved by an `Ok(owned s)` arm inside a loop is a loop move: R2.a applies unchanged.
8. **Test to change:** `borrowck.zig:10395` ("a wrap-pattern binding is a copy") changes for owning payloads only.

## C backend (codegen.zig)

- **Type.**
  - `scalarSlug` stays scalar-only.
  - `resultSlug` returns `string` for a `String` `Ok` side (a separate branch, so the parity test with `abi.resultMember` still covers scalars only).
- **Drops.**
  - `needsDrop` becomes true for a `cell_res_string_*` Result. `hasDropCall` stays unchanged: its second role, the owning-header guard in `emitValueInto`, must not start treating Results as headers **(default)**.
  - `emitDropFor` gains a `.result` arm that calls `cell_drop_res_string_<err>(&x)`.
  - `reassignedDroppableLocal` admits it.
- **Construction.** `cell_res_string_<err>_ok(<owned string>)`; the move is borrowck's.
- **Binding.**
  - `Ok(owned s)`: `cell_string_t s = t.as.ok;`, pushed droppable. It is released at arm end, at an early exit, or moved on by its uses (existing machinery).
  - `Ok(shared s)`: `cell_str_t s = cell_string_as_str(&t.as.ok);`, not droppable.
- **Scrutinee release.**
  - A place scrutinee is released on the paths where it is still live, through the existing `branch_end`/block-end records.
  - A temporary scrutinee (`_cell_tN`) is released at the end of every arm that did not bind `Ok(owned ..)`, and before an early exit from such an arm.
- **Id agreement.** The droppable arm binding must take borrowck's binding id in the same order (`pushLocal`'s positive id check, `codegen.zig:3805-3842`), or it stays non-droppable. That is the leak-safe side.

## abi.zig and the IR backends

- **No IR lowering.** `hir.zig`'s existing "Ok payload is not a scalar primitive" refusal stays, and both IR backends refuse together.
- **`layoutOf` fix.** `layoutOf` for a `Result<String, E>` currently reports the legacy 24 bytes. Correct it to 32 now, with a test, so `classifyParam` stays honest if the IR program reaches it **(default)**. The `String?` 24/32 mismatch stays with sub-project 4.

## Testing and gate

- **Runtime:**
  - `_Static_assert` for `cell_res_string_i32_t`: size 32, `as` at 8;
  - a drop test on an `Ok` and an `Err` instance under ASan (the harness).
- **Parser:** mode parsed on all four constructors.
- **typecheck:**
  - every refusal above, one test each;
  - acceptance of `Ok(owned s)`, `Ok(shared s)` and `Ok(_)`.
- **borrowck:**
  - construction moves (use after `Ok(s)` refused);
  - `Ok(owned s)` then use of the scrutinee after the match refused;
  - the scrutinee is still usable inside the `Err` arm;
  - `Ok(shared s)` blocks moving the scrutinee inside the arm;
  - alias refusal (R7) for `Ok(armBinding)`;
  - loop move refused by R2.a.
- **codegen:**
  - the instance type;
  - the constructor;
  - both binding forms;
  - drops at arm end and at an early `return`;
  - the temporary scrutinee release per arm;
  - `expectCompiles` on all of the above.
- **Examples.** `examples/results_string.cell`, C only, with an `EXPECT-OUTPUT` pin, builds, passes, returns, reassigns and matches (`owned`, `shared`, `_`, `Err`).
- **Leak fixture.**
  - `examples/leaks/owned_string_result.cell` runs the same shapes 1000 times. It is pinned at 0 on both witnesses.
  - It is also run under ASan by hand, because stage 9 does not see `examples/leaks/`.
- **Refusal corpus.** `examples/rejected/owned_payload_bare_binding.cell` (`// EXPECT: currently-rejected`).
- **Gate:**
  - `tools/check.sh` verdict `clean`;
  - stage 4 still agrees, since both IR backends refuse the new example together;
  - stage 11 unaffected (no new R-rule; the existing rules gain cases).
- **Falsification:**
  - drop the temporary-scrutinee release and show the fixture's leak count rise;
  - make `Ok(owned s)` not move the scrutinee and show ASan report the double free.

## Docs

- **SPEC:**
  - 3.4 (owning `Ok`, pattern modes);
  - 6.x pattern grammar (mode in a wrap pattern);
  - 10.3 row.
- **FEATURES:** TYPE-06 and PAT rows.
- **OWNERSHIP:** R2 (construction moves), R7 (`Ok(owned ..)` consumes, `Ok(shared ..)` borrows), R11 (Result drop spelling).
- **AGENTS.md:** the Result line.

## Risks

- **Id agreement between borrowck and codegen for a droppable arm binding.** The fallback is non-droppable, which leaks, and the fixture would show it.
- **A double free if construction ever reads instead of moving.** The borrowck test and the ASan falsification both pin it.
- **The temporary-scrutinee release** must not run on the arm that moved the payload. Codegen tests pin the per-arm text, and ASan covers the rest.

## Review answers (Donald, 2026-09-17)

1. The mode parses on every constructor and the checker refuses it where it has no meaning (the design as written).
2. `Ok(_)` on an owning payload is allowed: no move, released after the match on that path.
3. The release helper is generated per module, like `cell_drop_<Name>`.
