# Goals

## Next language residuals after a26f8b8
status: done
- Parallel slices landed on `main`: hex/bin/oct + separators + exponent floats + unterminated strings (`b0defba`); postfix `a[i]` for String/`[Byte]` (`f5b035e`); R16 field revival (`d3cf2ae`); HIR destination-width integer literals so `widths.cell` runs on C/LLVM/MLIR (`6b717b8`).
- Gate on merged `d3cf2ae`: `verdict: clean`, exit 0, 592 tests (`/private/tmp/cell-gate-next.log`). Origin still unpushed.
- Outcome: `0x1F` is 31; `index.cell` prints 125 through C; `field_revival.cell` LIVE=0; `widths.cell` prints 16 on all three backends.
- Not this goal: skip-revival `break`/`continue`, `return` inside a loop, `Char` (no C mapping in SPEC 3.1), `[Int]` indexing, indexed assignment, NLL slice 3, LLVM/MLIR optional constructors, hexadecimal floats, Unicode names, M1-M10.

## Close residuals after the 2026-09-16 four-plan landing
status: done
- Four 2026-09-16 plans landed on canonical `main` through `90074bf`. Continuation the same day closed TYPE-02, Crash Reporter UX, docs honesty, unit `()`, R16 `after_loop`, string escapes, nested partial-field drop, one-branch field drop, and Int8/Int16/UInt8/UInt16/UInt32, through `a26f8b8`.
- Gate on merged HEAD `a26f8b8`: `verdict: clean`, exit 0, 559 tests (`/private/tmp/cell-gate-merged.log`). Origin still unpushed.
- Outcome: unknown type names are refused; `cell run`/`cell test` abort without a Crash Reporter report and still return 134; `()` is a return type; `\n \t \r \\ \" \0` decode; R16 remaining leaks from the four-plan landing are closed (outer-while-var, nested sibling field, one-branch field). Widths are primitives; `UInt8` is not `Byte`; `Char` stays unknown.
