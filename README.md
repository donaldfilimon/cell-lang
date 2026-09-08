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

Cell has three backends with different current coverage. Parsing, checking,
lowering, execution and resource cleanup are separate capabilities. See
[the capability matrix](docs/FEATURES.md) for current boundaries and the
[completion program](docs/superpowers/plans/2026-09-08-full-language-completion.md)
for the approved parity and release target.

`cell check` typechecks and borrow-checks. The retained fixture contracts say
that C emission compiles for `examples/hello.cell`,
`examples/control_flow.cell`, and `examples/ownership.cell`; the recorded
execution expectations are `42` for `examples/hello.cell` and a live refcount
for `examples/arc.cell` linked with `examples/arc_host.c`. A current
qualification report, rather than these present source descriptions, is the
evidence that those contracts pass on a particular revision and machine.

`cell emit --target=llvm` and `cell emit --target=mlir` produce textual LLVM IR
and MLIR by way of a typed IR in `src/cell/hir.zig`. Their retained execution
contracts expect `examples/backends.cell` to print `24` through all three
backends and `examples/hello.cell` to print `42`. The gate tests those outputs;
this paragraph does not claim a fresh run.

Both newer backends are deliberately **scalar-first**, with selected aggregate
operations. Support depends on ownership, expression position and ABI placement,
not just the type name. Unsupported operations should produce `cannot lower`;
the gate separately records disclosed ABI defects where this contract is still
incomplete. Runtime aggregate helpers that are `static inline` need callable
equivalents before IR backends can use them. The MLIR backend carries structs
as `!llvm.struct`, including the `examples/hello.cell` execution contract.

Enforced ownership rules, read off `src/cell/borrowck.zig`'s own header
rather than from memory: **R1, R2, R2.a, R2.b, R3, R3a, R4, R5, R6, R7's
consumption clause, R8, R9,
R14, R15 and R18**, plus one clause of **R10** (an `arc` value may not be made
unique, refused at **six** consumption sites). `arc` retain and release are
emitted by the C backend, with the gaps named honestly in
`docs/OWNERSHIP.md` R11 and measured rather than guessed.

That sentence claimed to be read off the header and was not: it omitted R2.a,
R2.b, R9 and R18, said four positions where the header says six, and named
non-lexical lifetimes as unimplemented. **Non-lexical lifetimes ARE enforced
for named loans** (slices 1 and 2 of `docs/OWNERSHIP.md` 0.3): a named loan
ends as soon as its holder is provably never reached again. Only slice 3, a
taint closure over derived bindings, is absent, and `let exclusive f = e`
therefore stays `ineligible`, which rejects, and rejecting is safe. The list
even contradicted itself, since the paragraph below names R2.a as a rule that
loops brought in. Cite the header; do not copy it.

Still designed and not implemented: generics, `Result<T,E>`, and enum
payloads. `.cell`/`.cel` modules pair with
`.body`/`.bod` by stem. See `docs/SPEC.md` section 12 and `docs/OWNERSHIP.md`.

**Loops exist.** `while` is a keyword, with `break` and `continue`; the retained
`examples/loops.cell` contract expects `55` from all three backends. An earlier
version of this section said the opposite and cited a rejected
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
