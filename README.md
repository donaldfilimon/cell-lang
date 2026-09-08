# Cell

**Cell** is a systems language that combines:

| From | What Cell takes |
|------|-----------------|
| **Rust** | Ownership, borrowing, move semantics, algebraic data types, `Result` |
| **Swift** | Value/reference clarity, ergonomic syntax, optionals (`T?`), ARC for shared objects |
| **Zig** | Explicit control, comptime-friendly host, zero-hidden-control-flow ethos, C ABI first |

The **toolchain host** is Zig **0.17** (`build.zig`), and the project
first-class supports:

- **`.zig`**: compiler, typechecker, codegen driver
- **`.c` / `.cpp`**: runtime + C++ helpers
- **`.swift`**: optional Apple-platform bridge
- **`.cell` / `.cel` / `.body` / `.bod`**: Cell source programs

## Documentation

- **[`docs/SPEC.md`](docs/SPEC.md)**: the language specification. Every
  construct is tagged **implemented**, **parsed but not enforced**, or
  **designed but not implemented**, and the tags were assigned by reading the
  source and running the compiler.
- **[`docs/OWNERSHIP.md`](docs/OWNERSHIP.md)**: the numbered, enforceable rules
  a borrow checker must implement, each with a violating example and the
  diagnostic a user should see.
- **[`examples/README.md`](examples/README.md)**: the pass/fail contract every
  example satisfies, and how to check it.
- **`runtime/cell_rt.h`**: the authoritative C ABI value model.

## Layout

```
cell-lang/
  build.zig / build.zig.zon   # Zig 0.17 multi-language build
  src/                        # Cell compiler (Zig)
  runtime/                    # C + C++ runtime (cell_rt)
  swift/                      # Swift bridge (CellBridge.swift)
  docs/                       # language specification and ownership rules
  examples/                   # .cell samples, with checkable expectations
  stdlib/                     # prelude declarations
```

## Ownership keywords

```cell
owned T        // unique owner (Rust T / move)
shared T       // immutable borrow (Rust &T, Swift borrowing)
exclusive T    // mutable borrow (Rust &mut T, Swift inout)
arc T          // shared ownership (Swift class / Arc)
copy T         // value / trivial copy (Swift struct default)
```

Ownership defaults to `owned` when omitted, in every position, so a bare
`f(x)` is a move. Move, aliasing, escape, immutable-assignment and call-site
agreement rules are enforced, and so is `arc` retain/release in the C backend.
See *Status* for what that does and does not cover.

## Source file extensions

Cell recognizes four extensions in two roles: `.cell` and `.cel` are module
files, `.body` and `.bod` are body files, and a body is paired to its module by
filename stem. `docs/SPEC.md` section 1.2 is normative, and
`examples/pairing/` is a worked example.

Stem pairing is implemented: `cell check examples/pairing/geometry.body`
resolves names from `geometry.cell`. A body with no stem-mate is an error.
`.txt` and extensionless paths still load as a standalone module.

## Requirements

- Zig `0.17.x`. This tree is developed against `0.17.0-dev.2018+ab30a0b9a`.
- A C toolchain (Clang).
- Optional: C++20 (`-Dcxx=true`, default on).
- Optional: Swift (`swiftc`, macOS; `-Dswift=true`, default on).

## Build

The canonical checkout is `~/dev/active/cell-lang`.

```sh
cd ~/dev/active/cell-lang

# zig + c + cxx, the verified configuration
zig build -Dswift=false

# full host, including the Swift bridge (macOS)
zig build

# zig + c only
zig build -Dswift=false -Dcxx=false

# run the CLI
zig build run -- version
zig build run -- check examples/hello.cell
zig build run -- dump  examples/ownership.cell
zig build run -- emit  examples/hello.cell

# tests
zig build test
```

Two notes on the build, both worth knowing before you trust a green result:

- `-Dswift=false` is the configuration this tree's documentation was verified
  against. The default Swift path hardcodes `/Applications/Xcode-beta.app`
  library paths in `build.zig`, so it is machine-specific.
- Always pass `-Dswift=false` unless you are deliberately testing the Swift
  bridge. `zig build test -Dswift=false` now covers typecheck, borrow check,
  and emit, including a `cc -c` of generated C.

## Status

The parsed surface is enforced and executable, through **three backends**.

`cell check` typechecks and borrow-checks. `cell emit` produces C that `cc -c`
accepts for `examples/hello.cell`, `examples/control_flow.cell`, and
`examples/ownership.cell`; `examples/hello.cell` linked against
`runtime/cell_rt.c` prints `42`. `examples/arc.cell` compiles and runs too,
linked against `examples/arc_host.c`, and prints a live refcount.

`cell emit --target=llvm` and `cell emit --target=mlir` produce textual LLVM IR
and MLIR by way of a typed IR in `src/cell/hir.zig`. Both are verified by
**running** their output, not by reading it: `examples/backends.cell` compiles,
links against the runtime and prints `24` through all three backends, and the
LLVM path also builds `examples/hello.cell` into a native executable that
prints `42`.

Both newer backends are deliberately **scalar-first**. `String`, `[T]`, `T?`,
`Result` and `arc` are refused with a `cannot lower` diagnostic at the offending
span rather than emitted as something that merely looks right. The reason is
concrete: an aggregate crossing the C boundary means choosing a calling
convention by hand on AArch64, and every aggregate constructor in
`runtime/cell_rt.h` is `static inline` and so has no symbol to call. The MLIR
MLIR backend carries structs too, as `!llvm.struct`, so `examples/hello.cell`
now runs through all three backends and prints `42` from each.

Enforced ownership rules, read off `src/cell/borrowck.zig`'s own header
rather than from memory: **R1, R2, R3, R3a, R4, R5, R6, R8, R14, R15**, plus
the first clause of **R10** (an `arc` place may not be made unique, refused at
four positions). `arc` retain and release are emitted by the C backend, with
the gaps named honestly in `docs/OWNERSHIP.md` R11 and measured rather than
guessed. Still designed and not implemented: non-lexical lifetimes, generics,
`Result<T,E>`, and enum payloads. `.cell`/`.cel` modules pair with
`.body`/`.bod` by stem. See `docs/SPEC.md` section 12 and `docs/OWNERSHIP.md`.

**Loops exist.** `while` is a keyword, with `break` and `continue`;
`examples/loops.cell` runs through all three backends and prints `55` from
each. An earlier version of this section said the opposite and cited a rejected
example that no longer exists, which is the kind of claim this project's own
status-honesty standard exists to prevent. Loops also brought their own
ownership rule, R2.a, for a move inside a loop body. `for` and `loop` are not
implemented.

Cell has no measured performance characteristics and no ABI-stability
guarantee. Memory-safety claims cover only the rules the checker actually
enforces.

## Checking any of this yourself

`tools/check.sh` is the gate and its exit code is the verdict. Six stages:
build; unit tests with the count printed; the four corpus contracts in
`examples/README.md`; LLVM-versus-MLIR verdict agreement on every example;
that emitted MLIR actually **lowers** (a verdict is not a lowering, and an
example spent its whole life on the accepted side while emitting text
`mlir-opt` could never consume); and real execution, where emitted code is
compiled, linked against the runtime, run, and its answer compared.

```sh
zig build -Dswift=false     # -Dswift=false is required; see Requirements
tools/check.sh
```

To run one program of your own through all three backends,
`.claude/skills/run-cell-lang/driver.sh --expect <value> yourfile.cell` emits,
compiles, links, runs and compares for each. It checks the program's exit
status as well as its output, because a program that prints the right answer
and then dies is not a pass.

Counts are deliberately not quoted here. The test count moved by more than
thirty in a single evening, and a number this file cannot keep current is worse
than no number: run the gate and read its own output.

## License

MIT
