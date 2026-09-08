# AGENTS.md

Canonical agent guidance for cell-lang. `CLAUDE.md` points here.

Cell compiler (Zig host) + C/C++/Swift runtime emitting C ABI. Language design in `README.md`, `docs/SPEC.md`, `docs/OWNERSHIP.md`. Example contracts in `examples/README.md`.

This is the canonical checkout. **CORRECTED 2026-09-07: it HAS a remote**, `https://github.com/donaldfilimon/cell-lang.git`, reachable (`git ls-remote --heads origin` answers). Earlier lines here and in `~/CLAUDE.md` calling it remoteless are stale. Verify ahead/behind rather than assuming either way; a commit that is not pushed still exists only on this disk.

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

- Borrow rules enforced by `src/cell/borrowck.zig` (see its header comment for the exact current set; it is independent of the typechecker). As of now: R1, R2, **R2.a**, **R2.b**, R3, R3a, R4, R5, R6, R8, **R9**, R14 (both clauses), R15, **R18**, plus ONE clause of R10: an `arc` value may not be made **unique**, refused at SIX consumption sites (an `owned` parameter, an `owned` binding, an assignment to an `owned` place, an `owned` struct field, a list-literal element, and a `return` whose declared return type is not `arc`). Every `arc`-to-`arc` use stays legal, `-> arc T` returning an `arc` local included. The rest of R10, including move-into-`arc`, is still designed only.

  **That one clause has been widened three times, along three different axes, and each widening found the previous one incomplete.** Hold the three apart, because a claim about one says nothing about the others:

  1. **Expression shape**, place versus value. The refusal called `placeOf` first at each position, and a `match` is valued and is not a place, so `take(owned match c { 0 => xs, _ => xs })` was ACCEPTED while `take(owned xs)` was refused. Closed in `23353e9`; the double free there was genuinely masked by the `cell_arc_clone` in the value temporary, re-measured at `23353e9^`.
  2. **Arc source**, a binding's annotation versus a signature's return type. `take(owned fresh())` with `fresh() -> arc [Int]` was accepted, because no place and no expression shape carries the `arc`-ness. **This one was NOT masked: a live AddressSanitizer double free at exit 134** from `460b9a3` onward, which is seven commits BEFORE the axis-1 fix whose message claims to land ahead of any such change. That ordering claim is false for this program and true for the one it fixed; both were emitted at both commits rather than reasoned about. Closed by reading the callee's return type.
  3. **Consumption site.** Four positions were enumerated and a property of every consumption asserted. A list-literal element and a `return` were never asked. Closed by asking at both.

  **The structural fix is not a longer enumeration.** `arcUniqueSource` used to return an optional place, so any form it did not recognise came back "none" and was PERMITTED: silence meant safe, and silence is what an unenumerated form produces. All three axes escaped through that one default. It now returns a total verdict whose undecidable case is REFUSED, so the next unenumerated form fails closed. `examples/rejected/arc_call_to_owned.cell` is the corpus form and carries the measurements; `docs/OWNERSHIP.md` R10 tables the six sites.
- **Non-lexical lifetimes for NAMED loans are enforced** (OWNERSHIP.md 0.3, slices 1 and 2). A named loan ends as soon as its holder is provably never reached again, and all four conflict sites (a new borrow, a read, a move, an assignment) skip such a loan. It needed no control-flow graph and `src/cell/liveness.zig` is NOT consumed: R8 forbids a borrow escaping its block, so the claim is decidable on the AST. `dead` requires both a forward scan and a window scan over the loan's own block, and the window whitelists exactly one position, a direct call argument, rejecting every other mention. **Slice 3, a taint closure over derived bindings, is deliberately absent:** `let exclusive f = e` makes the loan `ineligible`, which rejects, and rejecting is always safe here. `loanStatusAt` is cross-checked at runtime in every safety-checked build against `oracleDead`, a second predicate that greps the whole function instead of walking regions; a disagreement panics rather than shipping. `examples/nll_dead_borrow.cell` is the corpus form, `examples/rejected/aliasing.cell` the companion rejection.
- Construct-by-construct status (implemented / parsed not enforced / designed not implemented) is in `docs/SPEC.md` section 12. Cite the file; update counts and tags when behavior changes.
- `cell check` runs typecheck and borrowck independently into separate `diag.Bag`s; both are printed and either error produces `error.TypeError`.
- Drop insertion IS present in the C backend as of `7eaca7a`, and only there: `codegen.zig` emits scope drops, deliberately conservative (a parameter, a match-arm binding, a `record` shape and an R3a revival are never dropped) and written to fail toward a leak rather than a double free. The LLVM and MLIR backends emit no drops.
- `arc` retain/release IS present in the C backend and only there: boxing for a literal or call result, `cell_arc_clone` at OWNERSHIP.md R11's retain-a-place sites, the deliberate non-retain for a `shared` parameter, and the drop pass for release. `examples/arc.cell` compiles, links against `examples/arc_host.c`, runs, and prints a strong count.

  **Three separate counts live here and they were previously tangled into one paragraph. They count different things and none of them is a total.**

  **Leak gaps: FIVE remain.** An `arc` parameter is never released by a Cell body (no parameter is dropped); a struct with an `arc` field is never dropped; a block-scoped `arc` local is never released, which in a `while` body is unbounded; reassigning an `arc` `var` leaks the previous box; and an `owned` String or list PLACE bound as `arc` is left as a loud C type error rather than boxed, because R10's move-into-`arc` is unimplemented. A sixth, an unbound `arc` temporary dropping its handle on the floor, was CLOSED in `460b9a3` and now measures 0. A SEVENTH, never in the table, was `let owned ys: [Int] = fresh()` and `ys = fresh()` over an `arc`-returning callee, which emitted no drop and leaked the box; it is closed **by refusal** rather than by a release, so it gets no fixture and changes no gate constant. **The authority for these numbers is `tools/check.sh`'s `== leaks ==` stage**, which pins each against a fixture under `examples/leaks/` as a constant carrying the commit it was measured at. Prose here is not the authority; the gate is. `docs/OWNERSHIP.md` R11 says what each gap IS.

  **Memory-safety defects found and fixed by review: NINE**, each with a test. A returned `arc` FIELD handed out unretained; a SHADOWED `arc` local released twice, because drops are spelled by name; an `arc` place flowing out of an `if` branch; one flowing out of a `match` arm in return position; an `arc` place passed to an `owned` parameter; an `arc` match-arm binding returned from a BLOCK arm body, which the round that removed `Local.is_param` had derived to be unreachable; `let owned ys: [Int] = xs`, a double free of the buffer the parameter-position guard did not reach; R10's refusal being place-only, so every VALUE position escaped all four of its positions (masked by a clone rather than crashing); and an `arc` CALL RESULT passed to an `owned` parameter, `take(owned fresh())`, which unlike the one before it was **not** masked and ran as an AddressSanitizer double free at exit 134. The last four are refused by R10 rather than retained, because no retain can fix a double free of the BUFFER: `cell_arc_clone` governs the refcount.

  **A TENTH is found and NOT fixed, and it is counted separately for that reason.** The `str` -> owning-`String` conversion does not exist outside the `arc` direction. A string literal is a 16-byte borrowed `cell_str_t`; an owned `String` is a 24-byte `cell_string_t`; converting between them needs `cell_string_from_str`, which copies the characters. `emitArcConversion` returns false the instant `want.shape != .arc`, so **six positions convert nothing**: `return` from `-> String`, a `let owned` initializer, a `var owned` initializer, an `owned` call argument, a struct-literal field, and an assignment's right side. All six pass `cell check` with exit 0 and all six emit C that fails `-Wall -Wextra -Werror`. Measured again at `1dd0e6b` after wave 5's let-binding fix landed, which closes none of them: it is a different root cause, since the declared type is already correct and it is the INITIALIZER that is unconverted. **C is the safe backend here and LLVM is the unsafe one**, which inverts the usual reading: C refuses to compile all six, while `llvmemit.zig` and `mlirmit.zig` call zero runtime string constructors between them (`grep -c` returns 0 in both) and instead emit `alloca %cell_string` followed by `store %cell_str`, writing 16 bytes into a 24-byte slot, leaving `cap` uninitialized and `.ptr` aimed at a static literal. That is not a live use-after-free today only because neither backend emits drops; it becomes a free of a non-heap pointer the moment they do. Both backends are documented to refuse rather than emit plausible wrong code, so this is a breach of their own contract, and `let arc s: String = "ab"` is ALREADY refused by both -- the siblings were simply never enumerated. **The gate cannot see any of it: no corpus file returns a `String` from a body**, `examples/primitives.cell:33` only declares one bodyless, so the whole-corpus `-Werror` stage never compiles a str-into-String conversion, and a sanitizer would not help either because the corpus does not exercise the shape.

  **NOT memory-safety, and counted separately because they fail differently: FOUR.** A list literal took its element C type from the first element rather than the declared type, so `[String]` could hold `cell_arc_t` and a callee read a refcount box pointer as a length: silent, ASan-clean, and it PREDATED this work. The LLVM backend passed a spilled copy for an `exclusive` parameter, so a write-through printed 37 where C printed 42: silent, and two separate bugs, one per side of the call, either of which alone still printed 37. And whole-value assignment through an `exclusive` borrow emitted C that does not compile: loud, therefore the safe one. And a returned value was not boxed when the declared return type was `arc`, also a loud `cc` error, fixed in `294b33c`; it was omitted from this count until a re-review pointed out it fits the bucket's own definition.

  **Instances of ONE reasoning failure: TWENTY-ONE.** *A derivation that enumerated some forms of a construct and asserted a property of all of them.* Round 2 searched return-position PLACES and not VALUE positions. Round 3 enumerated two forms of a `match` arm body and asserted a property of all three. Round 4 enumerated R10's four POSITIONS and asserted a property of every CONSUMPTION. **Three of those are one axis: an enumeration of PLACE forms standing in for a claim about VALUE positions.** The fourth was `exprUsesName` recursing into a match arm's body and not its guard, where the switch was exhaustive over the union's VARIANTS while the recursion inside one variant was not exhaustive over that variant's FIELDS -- different claims, treated as one, in the very function held up as the structural defence against this failure. The fifth was a task brief that named `coerceArg` as the write-through bug when there were two, one per side of the call. The sixth was round 5 enumerating two ARC SOURCES, a binding annotation and an expression shape, and asserting a property of every source, which left a call result's signature return type as a live double free. The seventh is `docs/OWNERSHIP.md`'s own list-element row, which measured `[String]`, found `cc` refused it, and asserted the position was protected: for `[[Int]]` the C types coincide and nothing stopped it at all. The eighth, ninth and tenth all came from ONE fix, the MLIR whole-value write-through, and the pattern in them is worth more than the count. `.assign` enumerated the forms it had seen storing into a slot and asserted a property of all of them, so it stored a struct over a pointer. `is_ref` tested `i < f.param_count`, enumerating PARAMETERS and asserting a property of every BORROW, so a borrow bound to a local silently bound a copy. And the fix for that second one INTRODUCED the third: it changed what a borrow local holds without asking what READS it, so `let copy c = s` stored an address into a struct-shaped slot. **A brief warning that the twin defect had been two bugs, not one, was itself an undercount: it was four.** The lesson that generalises is not "count higher" but the second question that fix missed -- when you change a representation, ask what else reads it. An ELEVENTH is the controller's diagnosis of the `var exclusive` retarget gap, which named the wrong mechanism entirely and in the safe-sounding direction: it said `e` would dangle by aliasing a stale loan. Measured, `e` never dangles. The C backend does not retarget a borrow, it emits `*e = *&b;`, copying THROUGH the pointer, so `a` and `b` end up sharing one buffer and both are freed -- a live AddressSanitizer double free at exit 134, plus a leak of `a`'s original buffer. **borrowck modelled a retarget and codegen implemented a copy-through, and nothing reconciled them.** Refusing is correct under either reading, which is why the fix stands, but the language still has an undecided semantic here that refusal only defers. The TWELFTH is the controller's own AAPCS64 probe, and it is the cleanest example in this list. Told that `abi.zig` and `codegen.applyOwnership` disagreed, I re-ran the measurement the module documents and reported that `by_value` and `by_pointer` are *indistinguishable* -- both `ptr` -- so the ABI could not be wrong and only ownership could decide. **I probed 24-byte types only.** `cell_str_t` is 16 bytes and passes in REGISTERS: `int64_t f(cell_str_t s)` is `define i64 @f([2 x i64] %0)`, not `ptr`. So `exclusive String` really was emitting a WRONG SIGNATURE, a struct in x0/x1 where the callee reads a pointer from x0, and my "purely semantic, the ABI is fine" was an enumeration of the sizes I happened to test asserted over every aggregate. Thirteenth, fourteenth and fifteenth are the LLVM wave's own: a pointer/value rule written struct-only, `layoutOf(String, .exclusive)` answering 16 (the borrowed VIEW) where the object is the 24-byte owning buffer, and a borrow consumed BY VALUE handing over pointer bits, which made a program printing 84 in C and MLIR print 18400323745 in LLVM. The SIXTEENTH is the sharpest instance in this list, because it happened inside the paragraph that names the failure. `emitArcConversion`'s own doc comment records that an earlier version claimed "there is no second place to keep in step", found that false when `pub fn h() -> arc String { return "x" }` emitted `return cell_str_from_parts("x", 1);`, and then wrote: *"The claim to keep making is the enumeration, not the 'no second place': six positions reach this function, and the way the seventh gets found is by someone listing them again rather than by trusting a sentence that says the list is closed."* **The six positions were then re-listed for the `arc` axis only.** The identical view-into-owning conversion on the plain-`String` axis was never asked about, and is broken in all six of the very positions that sentence enumerates. Re-listing the positions is not the defence; re-listing them *for every axis that reaches them* is. The SEVENTEENTH, EIGHTEENTH and NINETEENTH all landed in one night of parallel work and none was found by the gate. The seventeenth is the strongest evidence that this failure is structural rather than a matter of care: an agent fixing the `let`-binding family **shipped a new silent double free in its own first commit and fixed it in its second**, by applying a binding's annotation for every mode without asking what reads the result, turning three loud `cc` errors into silent double frees and `var copy s = &mut name` from correct into a double free. That is the third time in this repository that the fix for one symptom introduced a new silent miscompile in the fixer's own commit. The eighteenth is a brief of mine that named FOUR consumption sites for R2.b when there were **six**; the two it missed, a call argument and a `return`, were both live exit-134 double frees, which is the fourth consecutive brief in this family to undercount (one became three, two became four, three became seven, four became six). The nineteenth is `checkLetInit`'s opening branch, which turns any SIGIL borrow into a loan and returns **without ever consulting the binding's ownership**, so `let owned xs = &list` never moves its lender and frees it twice, while the keyword spellings of the same intent move correctly: an enumeration of borrow *spellings* standing in for a claim about borrows, in a language whose own `examples/borrows.cell` declares all five spellings identical. The TWENTIETH is that same defect's other half, and it is the one that matters more: at a `let`, `refKind` caught the sigil forms while the KEYWORD forms fell through and silently MOVED the lender, and `ownedMoveSource`'s comment asserted that R3 and R15 covered the `owned` position when at a `let` neither rule ran at all. So one defect produced a crash on one spelling group and a silent wrong answer on the other, and only the crash was visible. The TWENTY-FIRST is mine: my brief for that fix tabulated FOUR spellings of which two crashed, and the implementer measured **nine, of which six crashed** -- including the unannotated `let xs = &list`, which R1 defaults to `owned`. That is the fifth consecutive brief in this family to undercount (1->3, 2->4, 3->7, 4->6, 4->9). **The count in a brief has never once been right, and the pattern is not that briefs are careless but that the person writing one enumerates the forms that produced the symptom they saw.** **Five of the twenty-one are the controller's**, which is the point of counting them here rather than in a report.

  **The structural answer stopped being "enumerate harder" at round 5**, because enumerating harder had been tried three times and found a new axis each time. R10's classifier now returns a TOTAL verdict whose undecidable case is refused, so an unenumerated form fails closed rather than being silently permitted. That does not make the reasoning failure impossible; it makes this rule's version of it loud.

  **Do not restate any of this as "arc never dangles".** Two earlier versions of this line said exactly that and review falsified both. `docs/OWNERSHIP.md` R11 tables the positions and the arm-body forms the current search covered, which is a record of what was looked at rather than a claim about what exists.
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

There IS a git remote (see the top of this file); it was added after the lines that said otherwise were written. That makes `origin` the backup of record for anything PUSHED, and only for that. Anything unpushed still exists on this disk alone, so check `git rev-list --count origin/main..main` before deciding a bundle is redundant, and re-bundle to `~/at-risk-bundles/` when it is not zero.

Run `tools/check.sh` (or at minimum the corpus loops + backend execution) after front-end or lowering changes before claiming completion.
