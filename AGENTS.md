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
`0.17.0-dev.2018+ab30a0b9a`. `build.zig.zon` carries `minimum_zig_version`;
read the number there rather than quoting one here, because it is bumped as
the toolchain moves.

Master moves weekly and removes things. When a std API disagrees with what you
recall, read the source that ships with your own toolchain rather than guessing:

```sh
zig version
zig env            # .std_dir is the stdlib source, .lib_dir/../doc/langref.html the reference
```

Compiling proves removal; the langref proves deprecation. Check both.

```bash
zig build -Dswift=false              # compile
zig build test -Dswift=false         # Zig unit tests + the C runtime harness
zig build test-runtime -Dswift=false # the C ABI harness alone
zig build examples -Dswift=false     # typechecks examples/hello.cell, and only that
./zig-out/bin/cell check examples/hello.cell
```

`test-runtime` builds `runtime/tests/test_cell_rt.c` with `-Werror` and
deliberately does **not** link `cell_rt.cpp`, so it exercises the weak-symbol
fallbacks for `cell_cxx_probe` and `cell_swift_probe`. `zig build test` depends
on it, so a green package gate covers it.

`zig build examples` checks one file. It is not the example gate; see below.

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

## The example corpus is the other half of the gate

`zig build test` does not run the examples, and `zig build examples` checks
only `hello.cell`. The real contract lives in `examples/README.md`: top-level
`examples/*.cell` must pass `cell check`, `examples/future/*` must fail, and
every file in `examples/rejected/` must match its own `// EXPECT:` header. Run
those three loops after any change to the front end, the typechecker, or
borrowck. A rule landing turns a `currently-accepted` header into a mismatch,
and the protocol is to update the header in the same commit as the rule.

`examples/pairing/geometry.cell` and `geometry.body` must both pass now that
stem pairing is implemented.

## A green gate is only as strong as the tests

`zig build test -Dswift=false` is the package gate and prints nothing on
success, so it cannot tell you the count. To see one:

```bash
zig test src/root.zig 2>&1 | tail -1   # e.g. "All 158 tests passed." on 67529a9
```

Run a single test by filtering a file directly. `zig build test` does **not**
accept `--test-filter`; it is not wired into `build.zig`.

```bash
zig test src/root.zig --test-filter "escaping borrow"
zig test src/cell/borrowck.zig --test-filter "R5"
```

`src/root.zig` pulls in every stage through `refAllDecls`, so filtering it
reaches the whole library including the codegen tests that shell out to `cc -c`.

`zig test src/main.zig` appears to work and is a trap. It succeeds only because
`"cli smoke"` references nothing, and Zig analyzes top-level declarations
lazily, so neither `@import("cell")` nor the three `extern fn`s are ever
resolved. The first real test of `main.zig` will need the module mapping and
the linked C runtime, which means `zig build test`.

Check the count before citing a green run, and add tests with the code you
write. `main.zig`'s `"cli smoke"` still asserts `true` and is not evidence.

## Status honesty

State what is implemented, what is parsed but not enforced, and what is only
designed.

- **Ownership.** R2, R3, R5, R8, R14, and R15 are enforced by
  `src/cell/borrowck.zig` through `cell check`. The rule set moves, so cite
  that file's header comment, which names the rules it implements, rather than
  this line. `arc` retain/release is not inserted, and there is no drop
  insertion and no NLL.
- **Types.** `src/cell/types.zig` is a real type representation. Scopes do not
  leak parameters between functions.
- **Codegen.** THREE backends, selected with `cell emit --target=c|llvm|mlir`.
  - **C** (default) is the only one that lowers the whole language: `if`/`else`,
    `match`, blocks, struct literals, list literals, mangled calls.
    `cell emit examples/hello.cell` compiles with `cc -c`; linked against
    `runtime/cell_rt.c` it prints `42`.
  - **LLVM IR** and **MLIR** go through `src/cell/hir.zig` and are
    **scalar-first**: scalars, payload-free enums, `if`, `match`, calls, and
    (LLVM only) struct locals. `String`, `[T]`, `T?`, `Result` and `arc` are
    refused with a `cannot lower` diagnostic at the offending span. They do not
    emit plausible-looking wrong output, and that is the design, not a gap to
    paper over.
  - `examples/backends.cell` is scalar-only and all three backends carry it;
    each one compiles, links and prints `24`. `examples/hello.cell` uses a
    struct, and as of the MLIR struct work all three backends carry it: it
    prints `42` through C, LLVM and MLIR alike.

## The backend toolchain, and where it actually lives

`llc`, `opt`, `mlir-opt` and `mlir-translate` are **not on PATH** on this
machine. They are in the Homebrew LLVM keg:

```bash
/opt/homebrew/opt/llvm/bin/mlir-opt --version    # Homebrew LLVM 23.1.0
```

Two measured facts that will otherwise cost you an hour each:

- **`zig cc -x ir` does not work.** It fails with `language not recognized: ir`.
  Use `cc` for anything involving `.ll` files. The tests do.
- **Do not put a `target triple` in emitted IR.** `clang -x ir` then warns
  `-Woverride-module`. Let the driver supply the host's triple.

The MLIR lowering pipeline is verified end to end, not quoted from docs.
`mlirmit.lowering_passes` is the array the test and the file header both use,
so they cannot drift:

```bash
mlir-opt out.mlir --verify-each
mlir-opt out.mlir --expand-strided-metadata --finalize-memref-to-llvm \
                  --convert-cf-to-llvm --convert-func-to-llvm \
                  --convert-arith-to-llvm --reconcile-unrealized-casts -o low.mlir
mlir-translate --mlir-to-llvmir low.mlir -o out.ll
llc -filetype=obj out.ll -o out.o && cc out.o cell_rt.o drv.c -o prog
```

The MLIR backend uses the **`cf`** dialect, not `scf`, and that is load
bearing. Cell has early `return`, and a `return` inside an `scf.if` region is
invalid because the default dialect inside that region is not `func`;
`mlir-opt` rejects it with the very unhelpful ``Dialect `' not found for custom
op 'return'``. Do not "tidy" the branches back into `scf.if`. A test pins it.
- Stem pairing is implemented: a `.body`/`.bod` file is checked with its
  same-directory `.cell`/`.cel` stem-mate. A body with no module is an error.
  `.txt` and extensionless paths still load as a standalone module.

`docs/SPEC.md` section 12 is a construct-by-construct status index, counted
rather than estimated. Cite it instead of guessing, and update it when you
change what is true.

Syntax parsing is not implementation. Verify a claim by running the compiler.

## Layout

There are now two paths below `check`, and only the newer one has an IR.
`codegen.zig` still walks the AST directly; `hir.zig` sits between `check` and
the two newer backends. That asymmetry is deliberate and temporary: re-seating
the C emitter on the HIR is the risky half, because 27 codegen tests assert its
exact output text, so the HIR and the new backends landed **purely additive**
and left all of those tests untouched. Re-seating is a separate slice with its
own differential harness.

One compilation unit flows through the stages in this order. `load.zig`
classifies the path by extension, finds a same-directory stem-mate when the
path is a body, and merges the module's declarations into the body unit;
`lexer` and `parser` produce an `ast.Module`; `typecheck.Checker` and
`borrowck.Checker` then run **independently**, each accumulating into its own
`diag.Bag`. `root.check` prints both bags and returns `error.TypeError` if
either has errors, so borrowck still runs and still reports when typecheck has
already failed. `codegen.Generator` lowers a checked module to C against
`runtime/cell_rt.h`.

`src/root.zig` is the library entry and exports `compile`, `check`, `emit`.
`src/main.zig` is the CLI (`check`, `dump`, `emit`, `version`, `help`) and
declares the C runtime symbols as `extern`, since this tree deliberately avoids
`@cImport`. The compiler stages live in `src/cell/`: `lexer`, `parser`, `ast`,
`typecheck`, `borrowck`, `codegen`, `diag`, plus `hir` (the typed IR) and the
two backends built on it, `llvmemit` and `mlirmit`.

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
