---
name: run-cell-lang
description: Build, run, and drive the Cell language compiler (cell-lang). Use when asked to run, start, build, test, or smoke-test cell-lang, to compile or execute a .cell program, to check what a Cell program prints, or to compare the C, LLVM and MLIR backends against each other.
---

# Running cell-lang

cell-lang is a **compiler**, so "running it" means two different things and the
second is the one that matters. Running the compiler is `cell check` or
`cell emit`. Running a Cell *program* takes five steps no single command
performs: emit, compile, link against the C runtime, supply an entry point the
backend may not have emitted, and execute.

`.claude/skills/run-cell-lang/driver.sh` does the second. Point it at any
`.cell` file and it runs that program through every backend and reports what
each one printed.

All paths below are relative to the repository root. Verified 2026-09-07 on
Darwin arm64, Apple clang 21.0.0, zig `0.17.0-dev.2018+ab30a0b9a`.

## Prerequisites

- **Zig master.** `build.zig.zon` pins `.minimum_zig_version =
  "0.17.0-dev.2018+ab30a0b9a"`. On this machine that is `~/.zvm/bin/zig`, which
  is on PATH as `zig`. A release Zig will not build this.
- **A C compiler as `cc`.** Apple clang is what was used here. Needed for the
  runtime and for every emitted program.
- **Homebrew LLVM, only for the MLIR backend.** `mlir-opt`, `mlir-translate`
  and `llc` live in `/opt/homebrew/opt/llvm/bin` and are **not on PATH**. Without
  them the driver skips MLIR loudly rather than passing silently. Override with
  `LLVM_BIN=`.

No `apt-get` or `npm install` step exists. There are no package dependencies:
`build.zig.zon` declares `.dependencies = .{}`.

## Build

```sh
zig build -Dswift=false
```

**`-Dswift=false` is mandatory, every time.** The default enables a Swift bridge
that hardcodes a path inside `/Applications/Xcode-beta.app` and fails without
that exact beta installed. Nothing in this skill uses the Swift bridge.

## Run: a Cell program (the agent path)

```sh
.claude/skills/run-cell-lang/driver.sh --expect 42 examples/hello.cell
```

```
== examples/hello.cell ==
  ok    cell check
  ok    C    -> 42
  ok    LLVM -> 42
  ok    MLIR -> 42

  clean
```

Options, all exercised:

| Option | Effect |
|---|---|
| `--expect TEXT` | require that exact stdout; without it the output is only reported |
| `--host FILE.c` | link an extra C source, for a program with bodyless declarations. Repeatable |
| `--backends LIST` | subset of `c,llvm,mlir`. **Naming a backend makes its refusal a failure**; the default does not |
| `--no-build` | use `zig-out/bin/cell` as-is |

It exits 0 only if every selected backend built, ran, and matched. Verified
commands:

```sh
.claude/skills/run-cell-lang/driver.sh --expect 24 examples/backends.cell
.claude/skills/run-cell-lang/driver.sh --no-build --expect 55 examples/loops.cell
.claude/skills/run-cell-lang/driver.sh --no-build --host examples/arc_host.c --expect 13 examples/arc.cell
```

It works on a file you just wrote, which is the point. This exact program was
written from scratch and printed `55` through all three backends:

```cell
pub fn print_int(copy value: Int);

pub fn fib(copy n: Int) -> Int {
    var copy a = 0
    var copy b = 1
    var copy i = 0
    while i < n {
        var copy t = a + b
        a = b
        b = t
        i = i + 1
    }
    return a
}

pub fn main() {
    print_int(fib(10))
}
```

## Run: the compiler itself (the human path)

```sh
./zig-out/bin/cell --help
./zig-out/bin/cell check examples/hello.cell
./zig-out/bin/cell dump examples/hello.cell
./zig-out/bin/cell emit --target=c examples/hello.cell
./zig-out/bin/cell emit --target=llvm examples/backends.cell
./zig-out/bin/cell emit --target=mlir examples/backends.cell
```

`emit` writes C, LLVM IR or MLIR to **stdout**. It does not compile or run
anything, which is why the driver exists.

## Test

```sh
tools/check.sh
```

That is the project gate and its exit code is the verdict: build, unit tests
with the count printed, the four corpus contracts, LLVM-versus-MLIR verdict
agreement on every example, and execution of a fixed set of programs.

**`tools/check.sh` and `driver.sh` answer different questions.** check.sh asks
"is the repository green" over a fixed set with hardcoded expected answers.
driver.sh asks "what does THIS program do", for any file. Neither replaces the
other, and only check.sh pins the two newer backends to the same verdict.

```sh
zig build test -Dswift=false          # unit tests; prints NOTHING on success
zig test src/root.zig 2>&1 | tail -1  # the count
```

## Gotchas

- **A failed `zig build` leaves the PREVIOUS binary in `zig-out/bin/cell`.**
  Running it then tests code that no longer exists. The driver checks the build's
  exit code and refuses to continue, printing `BUILD FAILED ... is now STALE`.
  Confirmed by appending garbage to `src/main.zig`.
- **A green build is not proof the binary matches your source if anything else is
  writing the tree.** A `zig build` that races a concurrent writer returns 0
  against a stale binary. Confirm `git status --porcelain` is clean, then rebuild,
  before trusting emitted output.
- **The three backends disagree about the entry point.** C emits `int main`,
  LLVM emits `define i32 @main`, MLIR emits **no main at all** and needs a C
  driver calling `cell_main()`. The driver supplies one for MLIR only. Grep the
  emitted output before assuming; do not copy one backend's link line to another.
- **`zig cc -x ir` does not work** ("language not recognized: ir"). Use plain
  `cc` for `.ll` files, with `-Wno-override-module`.
- **LLVM and MLIR refusing a program is designed behaviour, not a break.** Both
  are scalar-first and emit a `cannot lower` diagnostic rather than plausible
  wrong code. `examples/arc.cell` is refused by both and this is correct. The
  driver reports that as `refuse`, not `FAIL`, unless you named the backend in
  `--backends`.
- **`examples/arc.cell` needs `examples/arc_host.c`.** It declares `observe` and
  `inspect` without bodies because it demonstrates the `arc` calling convention
  at the C boundary, and `observe` reads `cell_arc_strong_count`, which no Cell
  body can reach. Without the host it does not link.
- **`cmd | tail` reports tail's exit status, not the command's.** This has
  manufactured false green claims in this repository. Redirect to a file and echo
  `$?` from the command itself. Nothing whose status matters is piped in the
  driver.
- **`--test-filter` fails toward a false green here.** `src/root.zig` contains an
  anonymous `test { refAllDecls(@This()); }`, which has no name for a filter to
  exclude, so it always runs. A filter matching nothing prints `All 1 tests
  passed` at exit 0, not `All 0`. Check that the named test you asked for appears
  in the output.
- **A green `zig build test` says nothing about the language.** It does not run a
  single `.cell` program. Use the driver or `tools/check.sh`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Build fails inside `/Applications/Xcode-beta.app` | You omitted `-Dswift=false`. Always pass it. |
| `SKIP MLIR (mlir-opt/... not in ...)` | Homebrew LLVM missing or elsewhere. `LLVM_BIN=/path/to/llvm/bin driver.sh ...` |
| `cannot lower to LLVM IR` / `to MLIR` | Designed refusal by a scalar-first backend, not a bug. Use `--backends c`, or accept the `refuse` line. |
| `undefined symbol: _cell_observe` (or similar) | The program has bodyless declarations. Pass `--host` with the C file defining them. |
| `error: language not recognized: 'ir'` | You used `zig cc` on a `.ll`. Use `cc`. |
| `cell check` fails on a file under `examples/rejected/` | Expected: that corpus exists to be rejected. Read its `// EXPECT:` header. |
