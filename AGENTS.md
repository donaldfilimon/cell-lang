# AGENTS.md

Canonical agent guidance for cell-lang. `CLAUDE.md` points here.

## What this is

The compiler for **Cell**, a systems language blending Rust ownership, Swift
value/reference ergonomics, and Zig explicit control, emitting a C ABI. The
compiler is written in Zig; `runtime/` is C and C++; `swift/` is an optional
Apple bridge. `README.md` and `docs/` carry the language design; this file
carries how to build and what not to trust.

This checkout is canonical. It was imported on 2026-09-06 from
`~/Documents/public/cell-lang`, which had **no git metadata at all** and lived
in iCloud. That original is retained untouched as a fallback and
`~/at-risk-bundles/cell-lang-icloud-nogit-20260906.tar.gz` records the imported
state. Do not develop in the iCloud copy, and do not treat it as a second
branch of this work.

## Toolchain and gates

This project targets Zig **master**, not a release. It was developed against
`0.17.0-dev.2018+ab30a0b9a`; `build.zig.zon` sets `minimum_zig_version` to
`0.17.0-dev.1252+e4b325c19`.

Master moves weekly and removes things. When a std API disagrees with what you
recall, read the source that ships with your own toolchain rather than guessing:

```sh
zig version
zig env            # .std_dir is the stdlib source, .lib_dir/../doc/langref.html the reference
```

Compiling proves removal; the langref proves deprecation. Check both.

```bash
zig build -Dswift=false          # compile
zig build test -Dswift=false     # unit tests
zig build examples -Dswift=false # typecheck examples/hello.cell
./zig-out/bin/cell check examples/hello.cell
```

**Always pass `-Dswift=false` unless you are deliberately testing the Swift
bridge.** The Swift step in `build.zig` shells out to `swiftc` and hardcodes
library paths under `/Applications/Xcode-beta.app`, so it fails on a machine
without that exact beta. `-Dcxx=false` similarly drops the C++ half; the runtime
keeps weak-symbol fallbacks so both still link.

Capture exit codes directly. `cmd | tail` reports tail's status, not the
command's, which has manufactured false green claims here before:

```bash
zig build test -Dswift=false > /private/tmp/cell-test.log 2>&1; echo "EXIT: $?"
```

**A failed `zig build` leaves the previous binary in `zig-out/bin/cell`.** Run
that stale binary after a failed build and you are testing code that no longer
exists, which reads as a pass. Check the build's exit code before trusting any
run of the binary. This has already produced one false green here.

Build scratch belongs under `/private/tmp`, never in an iCloud path.

## A green gate is weak evidence here

As of the import there were **four test blocks in the whole tree**:
`root.zig` (`refAllDecls`), `main.zig` (`"cli smoke"`, which asserts `true`),
`parser.zig` (`"parse fn"`), and `lexer.zig` (`"lex hello"`). `typecheck.zig`,
`codegen.zig`, `ast.zig`, and `diag.zig` had none. `zig build test` passing
therefore says almost nothing about correctness. Check the test count before
citing a green run as evidence, and add tests with the code you write.

## Status honesty

State what is implemented, what is parsed but not enforced, and what is only
designed. Measured at import:

- **Ownership is the headline feature and is parsed, never enforced.** The five
  annotations reach the AST and no rule acts on them: no move checking, no
  use-after-move, no shared-XOR-exclusive aliasing, no ARC insertion.
- The typechecker walks the AST without a type representation. `Symbol.ty_name`
  is a string, and `symbols` is one flat map with no scopes, so parameters leak
  between functions.
- Codegen emits `/*block*/`, `/*if*/`, and `/*match*/` placeholders, so `if` and
  `match` parse and typecheck completely and then generate no control flow.
- Emitted C compiles for declaration-only files and for nothing else.
- There is no path from `.cell` to an executable. `emit` prints C text and
  nothing compiles it.
- The module and body file system (`.cell`/`.cel` declare, `.body`/`.bod`
  implement) is specified and absent. The compiler inspects no extension at all:
  `cell check` accepts `.txt` and a file with no extension identically.

`docs/SPEC.md` section 12 is a construct-by-construct status index, counted
rather than estimated. Cite it instead of guessing, and update it when you
change what is true.

Syntax parsing is not implementation. Verify a claim by running the compiler.

## Layout

`src/root.zig` is the library entry and exports `compile`, `check`, `emit`.
`src/main.zig` is the CLI (`check`, `dump`, `emit`, `version`, `help`) and
declares the C runtime symbols as `extern`, since this tree deliberately avoids
`@cImport`. The compiler stages live in `src/cell/`: `lexer`, `parser`, `ast`,
`typecheck`, `codegen`, `diag`.

`runtime/cell_rt.h` is the ABI contract that generated C targets. Change it and
`codegen.zig` together, or emitted code stops linking.

The three `extern fn` declarations at the top of `src/main.zig`
(`cell_rt_version`, `cell_cxx_probe`, `cell_swift_probe`) pin those runtime
signatures. Changing them in C without changing `main.zig` breaks the build in a
way the C compiler cannot see.

## Conventions

Match the surrounding Zig, which already uses current master idioms:
`pub fn main(init: std.process.Init)`, `std.Io.File.Writer`,
`Io.Dir.cwd().readFileAlloc`, and `std.ArrayList(T) = .empty` with
allocator-passing methods. Do not rewrite these toward older forms.

No em dashes in source comments, docs, or commit messages.

This repository has **no remote**, so work here is committed locally and exists
nowhere else. Re-bundle to `~/at-risk-bundles/` after meaningful work until a
remote exists.
