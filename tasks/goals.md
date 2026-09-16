# Goals

## Close residuals after the 2026-09-16 four-plan landing
status: done
- Four 2026-09-16 plans landed on canonical `main` through `90074bf`. Continuation the same day closed TYPE-02, Crash Reporter UX, docs honesty, unit `()`, R16 `after_loop`, string escapes, nested partial-field drop, one-branch field drop, and Int8/Int16/UInt8/UInt16/UInt32, through `a26f8b8`.
- Gate on merged HEAD `a26f8b8`: `verdict: clean`, exit 0, 559 tests (`/private/tmp/cell-gate-merged.log`). Origin still unpushed.
- Outcome: unknown type names are refused; `cell run`/`cell test` abort without a Crash Reporter report and still return 134; `()` is a return type; `\n \t \r \\ \" \0` decode; R16 remaining leaks from the four-plan landing are closed (outer-while-var, nested sibling field, one-branch field). Widths are primitives; `UInt8` is not `Byte`; `Char` stays unknown.
- Not this goal: skip-revival `break`/`continue`, `return` inside a loop, field revival after a later store, `Char`, indexing, NLL slice 3, LLVM/MLIR optional constructors, M1-M10.
