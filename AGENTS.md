# AGENTS.md

Canonical agent guidance for cell-lang. `CLAUDE.md` points here.

Cell compiler (Zig host) + C/C++/Swift runtime emitting C ABI. Language design in `README.md`, `docs/SPEC.md`, `docs/OWNERSHIP.md`. Example contracts in `examples/README.md`.

This is the canonical checkout (no git remote).

## Toolchain and gates

Targets Zig **master** (see `build.zig.zon` `.minimum_zig_version`; bump as toolchain moves).

```sh
zig version
zig env            # .std_dir for stdlib source; read it + langref when std API surprises
```

**Always pass `-Dswift=false`** (and usually `-Dcxx=false` only if dropping C++). Default enables Swift bridge which hardcodes `/Applications/Xcode-beta.app` paths and fails elsewhere. Use `-Dswift=true` only when deliberately testing the bridge.

Core commands:

```sh
zig build -Dswift=false                    # build the CLI
zig build test -Dswift=false               # library + CLI tests + runtime harness
zig build test-runtime -Dswift=false       # C ABI harness alone (exercises weak-symbol fallbacks)
./zig-out/bin/cell check examples/hello.cell
./zig-out/bin/cell emit --target=c|llvm|mlir examples/hello.cell
```

**Full gate** (build + tests + corpus contracts + backend agreement + execution):

```sh
tools/check.sh
```

It is the source of truth for what must be green. `zig build test` + `zig build examples` are insufficient (see below).

**Capture exit codes directly** (never `cmd | tail`; tail's status is reported):

```sh
zig build -Dswift=false > /private/tmp/cell-build.log 2>&1; echo "EXIT: $?"
```

**Stale binary trap**: a failed `zig build` leaves the *previous* `zig-out/bin/cell` in place. Check the build exit code before invoking the binary.

Build scratch belongs under `/private/tmp`. Never use iCloud paths or project `.cell-cache` for permanent artifacts.

## Tests

`zig build test -Dswift=false` prints nothing on success.

See count:

```sh
zig test src/root.zig 2>&1 | tail -1
```

Run a single test (filtering must be direct; `zig build test` does **not** accept `--test-filter`):

```sh
zig test src/root.zig --test-filter "escaping borrow"
zig test src/cell/borrowck.zig --test-filter "R5"
```

`zig test src/main.zig` does not work at all: it fails with `no module named 'cell'`, because the CLI's `@import("cell")` is supplied by `build.zig` (`--dep cell -Mcell=src/root.zig`) along with the runtime C sources the three `extern fn`s need. The CLI tests run only under `zig build test`.

`src/root.zig` pulls in the whole library via `refAllDecls`, including codegen tests that shell out to `cc -c`.

Always add tests with the code you change. Cite the count before claiming a green run.

## Example corpus (the language gate)

`zig build test` and `zig build examples` (only `hello.cell`) prove nothing about language behavior. The contracts live in `examples/README.md`.

After changes to lexer/parser/typecheck/borrowck/codegen, run the gate or the four loops:

- `examples/*.cell` must pass `cell check`
- `examples/future/*.cell` must fail `cell check`
- `examples/rejected/*.cell` must match their own `// EXPECT: currently-(accepted|rejected)`
- `examples/pairing/geometry.{cell,body}` must both pass (stem pairing)

See `examples/README.md` for the exact shell loops and the per-file demonstrations (including cross-backend execution of `hello.cell`, `backends.cell`, `loops.cell`).

`tools/check.sh` also verifies backend agreement (llvm vs mlir accept/refuse) and actual execution (emit + cc + link + run + output match) for the key cases.

## Status honesty

Syntax is not implementation. Verify by running the compiler.

- Borrow rules enforced by `src/cell/borrowck.zig` (see its header comment for the exact current set; it is independent of the typechecker). As of now: R1, R2, R3, R3a, R4, R5, R6, R8, R14, R15.
- Construct-by-construct status (implemented / parsed not enforced / designed not implemented) is in `docs/SPEC.md` section 12. Cite the file; update counts and tags when behavior changes.
- `cell check` runs typecheck and borrowck independently into separate `diag.Bag`s; both are printed and either error produces `error.TypeError`.
- Drop insertion IS present in the C backend as of `7eaca7a`, and only there: `codegen.zig` emits scope drops, deliberately conservative (a parameter, a match-arm binding, a `record` shape and an R3a revival are never dropped) and written to fail toward a leak rather than a double free. The LLVM and MLIR backends emit no drops.
- `arc` retain/release IS present in the C backend (and only there): boxing for a literal or call result, `cell_arc_clone` at OWNERSHIP.md R11's three retain-a-place sites, the deliberate non-retain for a `shared` parameter, and the drop pass for release. Six gaps remain, every one of them measured as a leak rather than assumed to be one: an `arc` parameter is never released by a Cell body (no parameter is dropped); a struct with an `arc` field is never dropped; an unbound `arc` temporary unboxed for a `shared` parameter drops its handle on the floor; a block-scoped `arc` local is never released at all, which in a `while` body is unbounded; reassigning an `arc` `var` leaks the previous box; and an `owned` String or list PLACE bound as `arc` is left as a loud C type error rather than boxed, because R10's move-into-`arc` is unimplemented in `borrowck.zig` and boxing an un-moved place would double free it. `docs/OWNERSHIP.md` R11 carries the `leaks` numbers for each. **Do not restate that as "arc never dangles":** an earlier version of this line said exactly that while two use-after-frees were live (a returned `arc` field handed out unretained, and a shadowed `arc` local released twice), both since fixed and both carrying tests. `examples/arc.cell` compiles, links against `examples/arc_host.c`, runs, and prints a strong count.
- NLL, generics, `Result<T,E>`, enum payloads, and loops other than `while` are not present.

## Codegen and backends

Three emitters selected by `cell emit --target=`:

- `c` (default): only one that lowers the whole language today (if/else, match, blocks, struct/list literals, mangled calls). Walks AST directly.
- `llvm`, `mlir`: go through `hir`; deliberately **scalar-first**. Refuse `String`, `[T]`, `T?`, `Result`, `arc` (and most aggregates crossing C boundary) with a `cannot lower` diagnostic at the span. Never emit plausible wrong code.

`examples/backends.cell` (scalar) and now `hello.cell` (with struct) and `loops.cell` execute through all three. `arc.cell` executes through C alone, and needs `examples/arc_host.c` for its two bodyless declarations; `tools/check.sh` runs it with `run_c_host`.

## Backend toolchain (measured, not assumed)

`llc`, `opt`, `mlir-opt`, `mlir-translate` live in the Homebrew keg, not on PATH:

```sh
/opt/homebrew/opt/llvm/bin/mlir-opt --version
# tools/check.sh respects LLVM_BIN=...
```

Critical measured facts:

- `zig cc -x ir` fails ("language not recognized: ir"). Use plain `cc` for `.ll` files.
- Never emit a `target triple` in IR (produces `-Woverride-module`).
- MLIR backend **must** use the `cf` dialect (not `scf`). Early `return` inside `scf.if` is invalid (default dialect is not `func`); `mlir-opt` rejects with an obscure message. See `src/cell/mlirmit.zig` and the pipeline in `tools/check.sh`.

Typical MLIR lowering (verify each step):

```sh
mlir-opt out.mlir --expand-strided-metadata --finalize-memref-to-llvm \
  --convert-cf-to-llvm --convert-func-to-llvm --convert-arith-to-llvm \
  --reconcile-unrealized-casts -o low.mlir
mlir-translate --mlir-to-llvmir low.mlir -o out.ll
llc -filetype=obj out.ll -o out.o && cc ...
```

## Layout and wiring (what changes how you work)

One unit: `load.zig` (classifies extension, pairs `.body`/`.bod` with same-dir `.cell`/`.cel` stem-mate, merges decls, enforces some pairing rules) → lexer/parser → `ast.Module` → `typecheck.Checker` + `borrowck.Checker` (independent) → (optional `hir.lower`) → emit.

- `src/root.zig`: library surface (`compile`, `check`, `emit`, `emitFor`, `loadAndCheck`, tests).
- `src/main.zig`: CLI dispatcher + the three `extern fn` declarations (`cell_rt_version`, `cell_cxx_probe`, `cell_swift_probe`) that pin runtime signatures. Changing the C side without updating these breaks the build in a way the C compiler cannot see.
- `runtime/cell_rt.h`: the ABI contract. Change it and the emitters together or emitted code stops linking.
- `src/cell/`: stages live here (`load`, `lexer`, `parser`, `ast`, `typecheck`, `borrowck`, `hir`, `codegen` (AST→C), `llvmemit`, `mlirmit`, `diag`...).
- `stdlib/prelude.cell`: bodyless declarations only (spec of intended surface; nothing is auto-imported; no module resolution exists yet).

Stem pairing lives in `load.zig`, and its diagnostics are its own, NOT `docs/OWNERSHIP.md` rules: missing module file, ambiguous module (both `.cell` and `.cel` exist), a declaration that already has a body, and body-versus-declaration signature mismatch (parameter count, per-parameter ownership and type, return type). No R-numbered rule is checked there. R8 is the escaping-borrow rule in `borrowck.zig`. R11 is `arc` retain-release: implemented in `codegen.zig`'s C backend with the gaps listed above, not in `llvmemit.zig` or `mlirmit.zig`, which refuse `arc`. R10 (move-into-`arc`) is designed, not implemented: `borrowck.zig`'s `checkLet` moves an initializer place only for `.owned`, and an `.arc` call argument only `readPlace`s it.

## Conventions

Match the Zig already present (master idioms): `std.ArrayList(T) = .empty`, allocator-passing methods, `std.Io`, `pub fn main(init: std.process.Init)`, etc. Do not rewrite toward older forms.

No em dashes in source comments, docs, or commit messages.

No git remote: all work is local. Re-bundle to `~/at-risk-bundles/` after meaningful changes.

Run `tools/check.sh` (or at minimum the corpus loops + backend execution) after front-end or lowering changes before claiming completion.
