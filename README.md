# Cell

**Cell** is a systems language that combines:

| From | What Cell takes |
|------|-----------------|
| **Rust** | Ownership, borrowing, move semantics, algebraic data types, `Result` |
| **Swift** | Value/reference clarity, ergonomic syntax, optionals (`T?`), ARC for shared objects |
| **Zig** | Explicit control, comptime-friendly host, zero-hidden-control-flow ethos, C ABI first |

The **toolchain host** is Zig **0.17** (`build.zig`), and the project first-class supports:

- **`.zig`** — compiler, typechecker, codegen driver  
- **`.c` / `.cpp`** — runtime + C++ helpers  
- **`.swift`** — optional Apple-platform bridge  
- **`.cell`** — Cell source programs  

## Layout

```
cell-lang/
  build.zig / build.zig.zon   # Zig 0.17 multi-language build
  src/                        # Cell compiler (Zig)
  runtime/                    # C + C++ runtime (cell_rt)
  swift/                      # Swift bridge (CellBridge.swift)
  examples/                   # .cell samples
  stdlib/                     # prelude sketches
```

## Ownership keywords

```cell
owned T        // unique owner (Rust T / move)
shared T       // immutable borrow (Rust &T, Swift borrowing)
exclusive T    // mutable borrow (Rust &mut T, Swift inout)
arc T          // shared ownership (Swift class / Arc)
copy T         // value / trivial copy (Swift struct default)
```

## Requirements

- Zig `0.17.x` (this tree targets `0.17.0-dev`)
- C toolchain (Clang)
- Optional: C++20 (`-Dcxx=true`, default on)
- Optional: Swift (`swiftc`, macOS; `-Dswift=true`, default on)

## Build

```sh
cd /Volumes/ExtremeSSD/public/cell-lang

# full host (zig + c + cxx + swift on macOS)
zig build

# zig + c only
zig build -Dswift=false -Dcxx=false

# run CLI
zig build run -- version
zig build run -- check examples/hello.cell
zig build run -- dump examples/ownership.cell
zig build run -- emit examples/hello.cell

# tests
zig build test
```

## Status

MVP: lexer → parser → light typecheck → C ABI IR sketch.  
Not yet: full borrow checker, LLVM/MLIR backend, package manager.

## License

MIT
