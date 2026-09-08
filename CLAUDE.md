# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is canonical for this repository and wins on any conflict with this
file. Read it before editing anything here. This file routes, and adds the
cross-file picture that no single source file states.

## Read first, in this order

1. `AGENTS.md` **Toolchain and gates** and **Status honesty**: the Zig-master
   pin, why every command needs `-Dswift=false`, and what is enforced versus
   parsed versus only designed.
2. `docs/SPEC.md` section 12, the construct-by-construct status index, and
   `docs/OWNERSHIP.md` for the numbered rules `borrowck.zig` implements
   (R1, R2, R3, R3a, R4, R5, R6, R8, R14, R15 today; its header comment is
   the live list).
3. The module doc comment of whatever you are about to change. They are long
   on purpose and carry the decision, not just the description:
   `hir.zig` on why lowering is total and tolerant, `cfg.zig` on why a block
   is a shape and carries no statements, `codegen.zig` on which places are
   deliberately never dropped, `abi.zig` on why every AAPCS64 fact there was
   measured from clang rather than read.

## The gate

```sh
tools/check.sh          # exit code is the verdict
```

One command, five stages, and its header comment explains why each stage
earns its place. `zig build test` alone is not the gate: it does not run a
single `.cell` program, and `zig build examples` checks only `hello.cell`.
The stages are build, tests (with the count printed), the four corpus
contracts from `examples/README.md`, LLVM-vs-MLIR verdict agreement on every
example, and real execution (emit, compile, link against `runtime/cell_rt.c`,
run, compare output) of `hello`/`backends`/`loops` through all three backends.

`examples/README.md` still says "there is no gate script" and prints the loops
by hand. That line predates `tools/check.sh`; the script is the same loops.

MLIR stages **SKIP loudly** when `mlir-opt`/`mlir-translate`/`llc` are missing,
and the verdict says the run was weaker. They are in the Homebrew keg, not on
PATH; override with `LLVM_BIN=`.

**Do not trust a test count written here.** It moved 254 -> 289 in a single
evening, and an execution-check count with it. Run the gate and read its own
output; the count is the one thing this file cannot keep current.

## Tests

`zig build test -Dswift=false` prints nothing on success and covers three
things: the library (`src/root.zig`, which pulls everything in via
`refAllDecls`, including codegen tests that shell out to `cc -c`), the CLI
(`src/main.zig`), and the C runtime harness.

```sh
zig test src/root.zig 2>&1 | tail -1              # the count
zig test src/root.zig --test-filter "escaping borrow"
zig test src/cell/borrowck.zig --test-filter "R5"
```

**`--test-filter` fails toward a false green, and here it is worse than the
usual warning.** A filter matching nothing exits 0. It does not print
"All 0 tests passed" either: `src/root.zig:143` is an ANONYMOUS
`test { refAllDecls(@This()); }`, so it has no name for a filter to exclude and
always runs. A typo'd filter therefore prints a plausible

    1/1 root.test_0...OK
    All 1 tests passed.

Measured 2026-09-07. Always check the named test you asked for actually appears
in the output; the count alone cannot tell a real pass from a typo, and it is
always one higher than the number of named tests that matched.

`zig build test` does **not** accept `--test-filter`; filter by invoking
`zig test` on the file directly. That works for `src/root.zig` and the
`src/cell/*` modules, but **not** for `src/main.zig`, which fails outright with
`no module named 'cell'`: the CLI's `@import("cell")` and the C sources behind
its three `extern fn`s are supplied by `build.zig`, so its tests run only under
`zig build test`.

## Architecture

One compilation unit, two lowering paths.

`load.zig` resolves a path to a unit: it classifies the extension and pairs a
`.body`/`.bod` file with its same-directory `.cell`/`.cel` stem-mate, merging
the module's decls into the body unit so names declared only in the module
resolve. Its diagnostics are its own and are **not** OWNERSHIP.md rules:
missing module file, ambiguous module, a declaration that already has a body,
and body-versus-declaration signature mismatch. `lexer` and `parser` build an
`ast.Module`.

`typecheck.Checker` and `borrowck.Checker` then run **independently**, each
into its own `diag.Bag`. That independence is deliberate: borrowck imports
only `ast` and `diag`, carries its own scope stack and signature table, and
reasons about *places* (binding identity plus a dotted field path) rather than
names. `root.check` prints both bags and returns `error.TypeError` if either
errored, so a type error never suppresses a borrow error.

From the checked AST the two emit paths diverge, and knowing which one you are
in explains most surprises:

- **`--target=c` (default) walks the AST directly** in `codegen.zig`. It is
  the only backend that lowers the whole language today, and it owns both
  halves of ownership lowering: drop insertion (release) and `arc`
  retain insertion (OWNERSHIP.md R11). Its drop pass depends on an
  id-numbering agreement with the binding walk and is written to **fail toward
  a leak**: skipping a live place's drop only leaks, while dropping a place
  that is still live is a double free, so a numbering drift trips a loud test
  rather than mis-dropping. The retain side runs the same asymmetry in reverse,
  retaining when unsure, because retaining too much leaks and retaining too
  little dangles.

  Retains reach two kinds of position by two deliberately different routes,
  and the split is not accidental: `emitArcConversion` is **type-directed** and
  serves argument and value slots, while `returnedArcNeedsRetain` is a
  **position policy** for `return`, which alone carries R11's exception that a
  returned parameter must not be retained. Do not "simplify" these into one
  function; that exception is a fact about the position, not the type, and
  merging them means passing a mode flag into a clean type-directed
  conversion.
- **`--target=llvm` and `--target=mlir` go through `hir.lower`** and are
  deliberately **scalar-first**. They refuse `String`, `[T]`, `T?`, `Result`,
  `arc`, and most aggregates crossing the C boundary with a `cannot lower`
  diagnostic at the span. They never emit plausible wrong code. Because they
  share `hir`, a disagreement between them means one is wrong, which is what
  the gate's agreement stage exists to catch.

`cfg.zig` (CFG over one `hir.Fn`), `liveness.zig` (backward liveness and
last-use over that graph) and `abi.zig` (AAPCS64 classification) are leaf
modules importing only `hir`/`cfg`/`types`, kept that way so neither backend
can smuggle target knowledge past them. `liveness.zig` is `cfg.zig`'s only
consumer and has none of its own yet: it is scaffolding for a precise drop pass
and for NLL, and "nothing uses this" is expected rather than a defect. It
correlates its op lists to `cfg.Block`s by mirroring `cfg.Builder`'s traversal
function for function, so **the two walks must change together**; a drift
misaligns every list against the wrong block.

`runtime/cell_rt.h` is the ABI contract that keeps emitted code linking: change
it and the emitters together. `src/main.zig` holds the three `extern fn`
declarations (`cell_rt_version`, `cell_cxx_probe`, `cell_swift_probe`) that pin
runtime signatures, so changing the C side without updating them breaks the
build in a way the C compiler cannot see. `stdlib/prelude.cell` is bodyless
declarations only; nothing is auto-imported and no module resolution exists.

## Traps that have already produced false claims here

- **`cmd | tail` reports tail's exit code.** Redirect and echo `$?` from the
  command itself.
- **A failed `zig build` leaves the previous `zig-out/bin/cell` in place.**
  Check the build's exit code before running the binary; `tools/check.sh`
  stops outright on a build failure for exactly this reason.
- **Zig master reflection moves.** `std.meta.fields` is now
  `@compileError("deprecated in favor of @typeInfo")`, and `@typeInfo(E).@"enum"`
  carries `field_names`/`field_values`, not `fields`. Read
  `$(zig env | grep std_dir)` before assuming any std shape; a hit fixed in
  `src/main.zig` on 2026-09-07 came from exactly this.
- **`zig cc -x ir` fails** ("language not recognized: ir"). Use plain `cc` for
  `.ll`. Never emit a `target triple` in IR.
- **The MLIR backend must use the `cf` dialect, not `scf`.** An early `return`
  inside `scf.if` is invalid and `mlir-opt` rejects it obscurely.
- **A green `zig build test` says nothing about the language.** Run the gate.

## Conventions

Match the surrounding Zig, which already uses current master idioms
(`std.ArrayList(T) = .empty`, allocator-passing methods, `std.Io`,
`pub fn main(init: std.process.Init)`). Do not rewrite toward older forms.

No em dashes in source comments, docs, or commit messages.

Design work in flight lives in `docs/superpowers/specs/` and
`docs/superpowers/plans/`; `.superpowers/sdd/` holds task briefs and reports
from multi-agent passes. Add tests with the code you change, and cite the test
count rather than a bare green.

This repository has **no git remote**, so work here exists nowhere else until
it is bundled to `~/at-risk-bundles/`. Re-bundle after meaningful changes.
