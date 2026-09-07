# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`AGENTS.md` is canonical for this repository and wins on any conflict with this
file. Read it before editing anything here. This file only routes.

## Read first, in this order

1. `AGENTS.md` **Toolchain and gates**: the Zig-master pin, why every command
   needs `-Dswift=false`, and the two traps that have already produced false
   green claims here (`cmd | tail` reporting tail's exit code, and a failed
   build leaving the previous binary in `zig-out/bin/cell`).
2. `AGENTS.md` **Status honesty**: what is enforced versus parsed versus only
   designed. Syntax parsing is not implementation; verify a claim by running
   the compiler.
3. `docs/SPEC.md` section 12 for the construct-by-construct status index, and
   `docs/OWNERSHIP.md` for the numbered ownership rules the borrow checker
   implements.

## The gate

```bash
zig build -Dswift=false > /private/tmp/cell-build.log 2>&1; echo "EXIT: $?"
zig build test -Dswift=false > /private/tmp/cell-test.log 2>&1; echo "EXIT: $?"
```

Then run the three example-corpus loops in `examples/README.md`. `zig build
test` does not run them and `zig build examples` checks only `hello.cell`, so a
green package gate alone does not cover the language.

Single test: `zig test src/root.zig --test-filter "<name>"`. `zig build test`
does not accept `--test-filter`.

## Architecture in one paragraph

`src/cell/load.zig` resolves a path to a compilation unit, pairing a
`.body`/`.bod` file with its same-directory `.cell`/`.cel` stem-mate. `lexer`
and `parser` build an `ast.Module`. `typecheck.Checker` and `borrowck.Checker`
run independently, each into its own `diag.Bag`; `root.check` prints both and
returns `error.TypeError`. `codegen.Generator` emits C against the ABI in
`runtime/cell_rt.h`, which is the contract that keeps emitted code linking:
change that header and `codegen.zig` together.

## Conventions

Match the surrounding Zig, which already uses current master idioms. No em
dashes in source comments, docs, or commit messages. This repository has no
remote, so work here exists nowhere else until it is bundled to
`~/at-risk-bundles/`.
