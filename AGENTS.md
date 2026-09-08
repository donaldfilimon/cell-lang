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

**`--test-filter` fails toward a FALSE GREEN here, and more sharply than the usual "a filter matching nothing exits 0".** Re-measured on this toolchain:

```sh
zig test src/root.zig --test-filter "this-name-does-not-exist-anywhere"
# EXIT: 0
# 1/1 root.test_0...OK
# All 1 tests passed.
```

It does **not** print `All 0 tests passed`. `src/root.zig:143` is an anonymous `test { std.testing.refAllDecls(@This()); }`, so it has no name for a filter to exclude, always runs, and always passes. A typo'd filter therefore produces a plausible pass with a real count at exit 0. Two consequences, both of which bite:

- **Confirm the NAMED test you asked for appears in the output.** The count is not evidence that your filter matched anything.
- **The count is always one higher** than the number of named tests that matched, in `src/root.zig`.

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

- Borrow rules enforced by `src/cell/borrowck.zig` (see its header comment for the exact current set; it is independent of the typechecker). As of now: R1, R2, R3, R3a, R4, R5, R6, R8, R14, R15, plus ONE clause of R10: an `arc` place may not be made **unique**, refused at four positions (an `owned` parameter, an `owned` binding, an assignment to an `owned` place, and an `owned` struct field). Every `arc`-to-`arc` use stays legal. The rest of R10, including move-into-`arc`, is still designed only.
- **Non-lexical lifetimes for NAMED loans are enforced** (OWNERSHIP.md 0.3, slices 1 and 2). A named loan ends as soon as its holder is provably never reached again, and all four conflict sites (a new borrow, a read, a move, an assignment) skip such a loan. It needed no control-flow graph and `src/cell/liveness.zig` is NOT consumed: R8 forbids a borrow escaping its block, so the claim is decidable on the AST. `dead` requires both a forward scan and a window scan over the loan's own block, and the window whitelists exactly one position, a direct call argument, rejecting every other mention. **Slice 3, a taint closure over derived bindings, is deliberately absent:** `let exclusive f = e` makes the loan `ineligible`, which rejects, and rejecting is always safe here. `loanStatusAt` is cross-checked at runtime in every safety-checked build against `oracleDead`, a second predicate that greps the whole function instead of walking regions; a disagreement panics rather than shipping. `examples/nll_dead_borrow.cell` is the corpus form, `examples/rejected/aliasing.cell` the companion rejection.
- Construct-by-construct status (implemented / parsed not enforced / designed not implemented) is in `docs/SPEC.md` section 12. Cite the file; update counts and tags when behavior changes.
- `cell check` runs typecheck and borrowck independently into separate `diag.Bag`s; both are printed and either error produces `error.TypeError`.
- Drop insertion IS present in the C backend as of `7eaca7a`, and only there: `codegen.zig` emits scope drops, deliberately conservative (a parameter, a match-arm binding, a `record` shape and an R3a revival are never dropped) and written to fail toward a leak rather than a double free. The LLVM and MLIR backends emit no drops.
- `arc` retain/release IS present in the C backend (and only there): boxing for a literal or call result, `cell_arc_clone` at OWNERSHIP.md R11's three retain-a-place sites, the deliberate non-retain for a `shared` parameter, and the drop pass for release. **Five** gaps remain, every one of them measured as a leak rather than assumed to be one: an `arc` parameter is never released by a Cell body (no parameter is dropped); a struct with an `arc` field is never dropped; a block-scoped `arc` local is never released at all, which in a `while` body is unbounded; reassigning an `arc` `var` leaks the previous box; and an `owned` String or list PLACE bound as `arc` is left as a loud C type error rather than boxed, because R10's move-into-`arc` is unimplemented in `borrowck.zig` and boxing an un-moved place would double free it. A sixth, an unbound `arc` temporary unboxed for a `shared` parameter dropping its handle on the floor, was **CLOSED in `460b9a3`** and is measured at 0; any line still counting six is stale. The `leaks` numbers are pinned by `tools/check.sh`'s `== leaks ==` stage against fixtures under `examples/leaks/`, as constants carrying the commit they were measured at, and that gate is the authority rather than any number written in prose; `docs/OWNERSHIP.md` R11 says what each gap IS. **Do not restate that as "arc never dangles":** two earlier versions of this line said exactly that, and review falsified both. **Seven** use-after-frees have now been found and fixed across three review rounds, each with a test: a returned `arc` FIELD handed out unretained, a SHADOWED `arc` local released twice because drops are spelled by name, an `arc` place flowing out of an `if` branch, one flowing out of a `match` arm in return position, an `arc` place passed to an `owned` parameter, an `arc` match-arm binding returned from a BLOCK arm body (which the round that removed `Local.is_param` had derived to be unreachable), and `let owned ys: [Int] = xs`, a double free of the buffer that the parameter-position guard did not reach. The last two are refused by R10 rather than retained, because no retain can fix a double free of the buffer. Each round was falsified the same way: the second batch was missed because the search covered return-position PLACES and not VALUE positions, and the third because it enumerated two forms of a `match` arm body and asserted a property of all of them. `docs/OWNERSHIP.md` R11 tables the positions AND the arm-body forms the current search covered. `examples/arc.cell` compiles, links against `examples/arc_host.c`, runs, and prints a strong count.
- Generics, `Result<T,E>`, enum payloads, and loops other than `while` are not present. NLL is present for named loans only, with the boundary stated above; nothing shortens a temporary loan beyond the two exceptions 0.3 already had.

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
