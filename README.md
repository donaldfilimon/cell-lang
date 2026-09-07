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
`f(x)` is a move. Move, aliasing, escape, and immutable-assignment rules are
enforced; call-site prefixes and `arc` retain/release are not. See *Status*.

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
- Always pass `-Dswift=false` unless you are deliberately testing the Swift
  bridge. `zig build test -Dswift=false` now covers typecheck, borrow check,
  and emit, including a `cc -c` of generated C.

## Status

The parsed surface is enforced and executable. `cell check` typechecks and
borrow-checks. `cell emit` produces C that `cc -c` accepts for
`examples/hello.cell`, `examples/control_flow.cell`, and
`examples/ownership.cell`; `examples/hello.cell` linked against
`runtime/cell_rt.c` prints `42`. `examples/arc.cell` does not compile until
arc boxing exists.

Ownership rules R2 (use-after-move), R3 (move-out-of-borrow), R5 (shared XOR
exclusive), R8 (escaping borrow), and R14 (immutable assignment, including
fields) are enforced. Call-site ownership prefixes are still discarded (R15).
Retain/release for `arc`, loops, generics, `Result<T,E>`, enum payloads, and
`.cell`/`.body` stem pairing are still designed. See `docs/SPEC.md` section 12
and `docs/OWNERSHIP.md`.

There are no loops of any kind. `while` is not a keyword, so a loop-shaped
program is a call plus a discarded block; today `cell check` rejects
`examples/rejected/while_is_not_a_loop.cell` as `unknown identifier 'while'`.

Cell has no measured performance characteristics and no ABI-stability
guarantee. Memory-safety claims cover only the rules the checker actually
enforces.

## License

MIT
