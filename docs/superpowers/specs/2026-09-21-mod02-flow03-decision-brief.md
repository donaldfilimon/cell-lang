# Decision brief: MOD-02 (modules, visibility) and FLOW-03 (loop, labels, defer, for)

Status: **decisions needed, nothing implemented.** Written 2026-09-21 after the
field-store leak closed (see `examples/leaks/field_store_old.cell`). Both rows in
`docs/FEATURES.md` need semantics before code, and this repository's history
(AGENTS.md, "Instances of ONE reasoning failure") shows every brief that
enumerated forms undercounted them. So each question below names the decision,
the recommended default, and what the choice constrains, and leaves the
enumeration of affected sites to the implementation plan that follows a ruling.

## MOD-02: module resolution and visibility

Today (SPEC 1, 8.5): `use` parses and is dropped; `pub` only emits a
`// export` comment; every function has external C linkage; stem pairing
(`.cell` + `.body`) is the only multi-file mechanism, and it is a loader
concern, not import.

| # | Decision | Recommended default | Why |
|---|---|---|---|
| M1 | What a `use` path names | A module file, resolved relative to the importing file's directory first, then a configured search root; no network or package resolution | Matches stem pairing's same-directory rule; keeps the loader deterministic |
| M2 | What a `use` brings into scope | Only `pub` items, under the module's name (`geo.area(...)`); no glob import in the first slice | Qualified names avoid collision rules until visibility exists |
| M3 | Non-`pub` linkage | `static` in the C backend (and `internal`/private in LLVM and MLIR) | SPEC 8.5 already designs this; it is the smallest visible effect of `pub` |
| M4 | C symbol names across modules | Prefix with the module stem (`cell_<module>_<fn>`) for non-main modules | Current `cell_<fn>` mangling collides the moment two modules define `area` |
| M5 | Cycles | Refused at load time with the cycle printed | Declarations-before-bodies makes cycles expressible later; refusing first is the safe direction |
| M6 | Ownership across modules | Unchanged: signatures carry ownership, and borrowck checks each module against imported signatures only | borrowck is already signature-driven for bodyless declarations |

First slice if ruled as above: M1 + M2 + M5 in `load.zig` and the parser, M3
and M4 in the C backend only, with the IR backends refusing a multi-module
program until they get M3/M4. Gate: a two-module corpus pair under
`examples/modules/`, one rejected cycle, and a symbol-collision case.

## FLOW-03: `loop`, labels, `defer`, `for`

Today (SPEC 7.6): only `while`, `break`, `continue`. R2.a checks loop moves on
every path. The drop pass releases at scope exits and at `break`/`continue`
skip points; there is no general control-flow graph.

| # | Decision | Recommended default | Why |
|---|---|---|---|
| F1 | `loop { }` | Exactly `while true { }` for checking and lowering; a statement, not an expression (no `break value`) | Reuses R2.a and every drop point `while` already has; zero new ownership surface |
| F2 | Labels | `'name: while` / `'name: loop` with `break 'name` / `continue 'name`; R2.a and the drop pass must treat a labelled jump as leaving every loop in between | Labels are where the drop pass needs multi-level exits; worth doing before `defer` |
| F3 | `defer` | Deferred to after F1/F2. When done: runs at every exit of its block in reverse order, BEFORE the scope's drops, and may not move a binding declared outside the deferring block | Ordering against drops is the one question that decides whether `defer` can double free; pick it before any code |
| F4 | `for` | Out of scope until an iteration protocol exists (SPEC 7.6 already says so); the first form, if wanted, is `for i in a..b` over `Int` only, lowered to a `while` | Needs a range value; the indexing operator now exists for `String`/`[Byte]`/`[Int]` |

First slice if ruled as above: F1 alone (lexer already reserves `loop`), with
R2.a and drop-pass tests copied from the `while` suite, then F2. F3 needs its
ordering ruling first; F4 needs a range type first.

## What a ruling looks like

Reply per row: accept the default, change it, or defer it. Anything not ruled
stays designed-only, and `docs/FEATURES.md` keeps its current status.
