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
`f(x)` is a move. **None of the five is enforced today**; see *Status* below.

## Source file extensions

Cell recognizes four extensions in two roles: `.cell` and `.cel` are module
files, `.body` and `.bod` are body files, and a body is paired to its module by
filename stem. `docs/SPEC.md` section 1.2 is normative, and
`examples/pairing/` is a worked example.

This is **designed, not implemented**. The compiler has no notion of a file
extension at all: `cell check` accepts `.txt` and a file with no extension just
as readily, and treats every input as one standalone module.

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
- `zig build test` is not a meaningful gate for the *language*. It exercises
  the lexer, the AST helpers, the parser, the diagnostic renderer, and the C
  runtime. It does not check that any example program behaves correctly,
  because no example program can be executed: see *Status*.

## Status

**The front end is real and the back end is a sketch.** As of commit
`9fb12af`, `docs/SPEC.md` counts 60 constructs implemented, 12 parsed but not
enforced, and 77 designed but not implemented.

What works: the lexer, the parser, the AST with source spans on every node,
structured match patterns, and the diagnostic machinery. What does not exist: a
type representation, a borrow checker, and code generation for control flow.

Three consequences, all measured rather than assumed:

- **Ownership is not enforced.** The five annotations parse, reach the AST, and
  are printed into the generated C as comments. There is no move checking, no
  aliasing check, and no retain or release for `arc`. The only rule the
  compiler enforces anywhere is assignment to an immutable binding.
- **Emitted C compiles only for declaration-only files.** `cc -c` on the output
  of `cell emit examples/declarations.cell` gives 0 errors; on
  `examples/hello.cell` it gives 3, and on `examples/ownership.cell` it gives
  6. Call sites are not name-mangled, struct and list literals are emitted as
  comments, and struct parameters are `void*`.
- **`if` and `match` generate nothing.** Both parse completely and codegen
  emits `/*if*/` and `/*match*/`. Cell produces no control flow.

There are also no loops of any kind, and because `while` is not a keyword and a
block is an expression, a loop-shaped program parses cleanly and does nothing.
See `examples/rejected/while_is_not_a_loop.cell`.

Cell has no measured performance characteristics and provides no memory-safety
guarantee. The safety properties `docs/SPEC.md` and `docs/OWNERSHIP.md`
describe are properties of the specified language, to be delivered by a checker
that does not exist yet.

## License

MIT
