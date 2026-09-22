# Goals

## R2.a on every path out of a loop (skip-revival jumps)
status: done
- Reclassified from a deferred leak residual: skip-revival `break`/`continue` was a borrowck soundness hole. At `05116dc`, `cell check` accepted eight probes and ASan aborted each with a double free (exit 134): `skip_continue`, `skip_break_use`, `cond_move`, `nested_continue`, `break_then_outer`, `cond_twice`, and two found while fixing, `swap_hide` (a revival's `swapRemove` hid a body move from the index-based body-end scan) and `zero_iter` (a zero-iteration body left a pre-loop move invisible after the loop).
- Fix, borrowck only: a `LoopFrame` stack (`src/cell/borrowck/model.zig`); R2.a at `continue`; `break` states and the failing-condition state (a copy of `dead` after the condition, which includes the entry state) unioned into `dead` after the loop, after `after_held` and the body-end R2.a; "moved in the loop" compared against a copy of the entry state rather than an index. No new rule ID, no codegen change, no gate constant change.
- Conservative by Donald's ruling: `loopy`-shaped programs (`v = "x"` at the top, `take(v); continue` later) are now refused. The precise divergence walk, early-`return` divergence and the return-in-loop drop remain open.
- Evidence: 13 new borrowck tests; eight guard mutations, each failing a named test; `examples/rejected/skip_revival_jump.cell` flipped to currently-rejected; all eight probes refused. Full gate: `/private/tmp/cell-gate-skiprev.log`, run after this entry was written, with its verdict in the commit message. Not pushed.

## Project Grok bots follow Cell's gate
status: done
- Also: project `computer-control` skill (Grok Bot Agent Computer, not Claude/Orca); `reviewer` and `test-writer` overlays so those agents stop reviewing as Rust. `grok inspect` lists all three agents and both skills as project.
- Continuation: project overlays for `researcher`, `security-auditor`, `quick-search`, `design-doc-reviewer`, `design-doc-writer`. `abbey-assistant` left user-scoped on purpose (Abbey identity, not a Cell bot). `grok inspect`: eight project agents; only leftover user agent is `abbey-assistant`.
- Project overlays under `.grok/{agents,personas,skills,rules}` shadow the bundled implementer `fmt`/`clippy` bar with `-Dswift=false`, `tools/check.sh`, the `--test-filter`/`refAllDecls` false-green trap, and the canonical-`main`/worktree rule.
- `tools/check-grok-bots.sh` greps those live files and fails closed if a token or the implementer overlay is dropped; `tools/tests/test-grok-bots.sh` drives that script (eight cases). Wired as gate stage 15.
- `grok inspect --json` lists `implementer` (agent) and `cell-lang` (skill) as `source.type=project`, twice identical. Inspect has no personas catalog; `.grok/personas/implementer.toml` is loaded by Grok but not listed there.
- Outcome: an implementer session in this repo is told Cell's gate, not clippy. Not pushed.

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
