# MOD-02 and FLOW-03, IR-first: modules, visibility, `loop` and labels

Status: **approved by Donald 2026-09-22** (three follow-ups ruled the same night, see Open questions); implementation plans (one per subsystem): `docs/superpowers/plans/2026-09-22-flow03-loop-labels.md` and `docs/superpowers/plans/2026-09-22-mod02-modules-ir-first.md`.

This turns Donald's 2026-09-21 rulings on
`docs/superpowers/specs/2026-09-21-mod02-flow03-decision-brief.md` into a
design. It was drafted outside the tree, editing nothing and building
nothing, while the peer session "Artifact review" split `borrowck.zig` and
`codegen.zig` into directories; the code was read between `1af509a` and
`8adc2e5` as those commits landed (`checkLet` is already in
`borrowck/bindings.zig`). **Functions are cited by name, not line.**

## Decision ids

The brief numbered its questions M1 to M6 and F1 to F4. `M1` to `M10` already
name the milestones in `docs/superpowers/plans/2026-09-08-full-language-completion.md`,
so "M3" in a commit message would be ambiguous. This spec renames them one
for one: M1 to M6 become **D1 to D6** (use path, scope, non-`pub` linkage,
symbol names, cycles, ownership across modules) and F1 to F4 become **D-F1
to D-F4** (`loop`, labels, `defer`, `for`).

## Rulings (Donald, 2026-09-21)

- **Direction: IR-first.** `.cell -> HIR -> LLVM IR / MLIR` is primary. C
  carries a feature only where it is still needed, which today means
  heap-owning programs, because the IR has no drop pass. `--target` stays C by
  default until the IR leak pins reach 0, then flips to LLVM. **Flip
  criterion: every LLVM/MLIR leak pin in gate stage 7 reads 0.** Today that is
  `LEAK_IR_OWNED_STRING_{LLVM,MLIR}=3000`, `LEAK_IR_STRING_CONVERSION_{LLVM,MLIR}=9000`
  and `LEAK_OWNED_STRING_{LLVM,MLIR}=8` in `tools/check.sh`, plus any IR pin
  added later, including the ones this spec adds. Stated this way the
  criterion needs no amendment when a pin is added.
- **MOD-02: every default in the brief, D1 to D6.**
  - D1's configured search root is a repeatable `--module-root DIR`.
  - **`std` is a reserved root mapped to the compiler's embedded `stdlib/`.**
    A `std.` path never touches the filesystem or the `--module-root` list.
    `use std.prelude` imports the 44 prelude declarations, called as
    `prelude.print_int(..)`. `use std.io` becomes "module not found".
  - **Types are mangled too:** a non-entry module's structs and enums become
    `cell_<module>_<Type>`, their drop glue `cell_drop_<module>_<Type>`.
  - **A bodyless declaration keeps `cell_<fn>` in every module.** It names an
    external C symbol (`prelude.print_int` must emit `cell_print_int`, which
    `runtime/cell_rt.h` defines and gate stage 13 checks).
  - **The entry module keeps `cell_main`,** so the LLVM `@main` wrapper and the
    gate's `drv.c` are unchanged.
  - `use std.prelude` is demonstrated in a new `examples/modules/` program. The
    no-op `use std.io` lines leave `hello.cell` and `declarations.cell`, which
    otherwise stay unchanged.
- **FLOW-03:** D-F1, `loop` means exactly `while true` and is a statement.
  D-F2, Zig-style labels: `outer: while`, `break :outer`, `continue :outer`
  (this replaces the brief's `'name` spelling). D-F3 (`defer`) and D-F4
  (`for`) are deferred.

What reverses the brief: its "first slice" kept multi-module programs C-only,
with the IR backends refusing them. Under IR-first every slice below lands on
all three backends at once, and none is done until LLVM and MLIR print the
same pinned answer as C.

## Where things stand (measured by reading)

- **`use` loads nothing.** `parser.parseItem` records `use a.b` as a flattened
  string (`parsePath`) in `ast.Item.Kind.use_decl` and discards a leading
  `pub`. `typecheck.Checker.collectItems`/`checkItem`, `hir.Lowerer.run` and
  the emitters all skip it. `load.load` reads one file, and pairs a
  `.body`/`.bod` entry with its `.cell`/`.cel` stem-mate (`findModuleMate`,
  `merge`); a `.cell` entry is never paired.
- **Symbols are decided twice.** `hir.Lowerer.symbolFor` and
  `codegen.symbolFor` both return `cell_<name>`, except a bodyless `assert` of
  arity 2 (`cell_assert_msg`, via `codegen.intrinsicSymbol`). `hir.Fn.symbol`
  is documented as "computed once here so every backend agrees", but C derives
  its own. `codegen.resolveCallee` mangles a dotted callee by joining segments
  (`io.print` to `cell_io_print`), which fails only at link time.
- **Linkage is uniform.** `codegen.emitPrototype` writes `// export` above a
  `pub fn` and nothing else changes; `llvmemit` writes `define {ret} @{sym}`;
  `mlirmit` writes `func.func @{sym}` for a definition and
  `func.func private @{sym}` for a bodyless declaration. `hir.Fn.is_public` is
  carried and read by no emitter.
- **Type identity is module-blind.** `types.Type.struct_type`/`enum_type` hold
  a bare name compared with `mem.eql` (`types.compatible`);
  `typecheck.Checker.structs`/`enums` are module-wide maps by bare name;
  `hir.Struct`/`hir.Enum` have `is_public` and no `symbol`. Every backend
  spells a type from its name: codegen `cell_<Name>`, `cell_drop_<Name>`,
  enum constants `cell_<Enum>_<Variant>`; llvmemit `%cell_<Name>` at several
  sites. Two modules defining `Point` would collide in the checker and in
  every backend. The plan does not mention this; the design below must.
- **Qualified spellings do not parse outside calls and fields.**
  `parser.parseType` takes one `ident` for a named type; the struct-literal
  head is `ident {` only (`parsePrimary`), so `geo.Point { .. }` is a field
  access followed by a block. `geo.area(..)` and `geo.Color.Red` already parse,
  as field chains.
- **Loops are innermost-only everywhere.** The AST's `break_stmt`/
  `continue_stmt` and HIR's `brk`/`cont` carry nothing;
  `typecheck.Checker.loop_depth` is a counter; `cfg.Builder.lowerJump` takes
  `loops.items[len - 1]`; `liveness.Walker` tracks depth only; llvmemit's
  `break_label`/`continue_label` and mlirmit's `break_block`/`continue_block`
  are singletons; borrowck's `saveBreakState`, `checkContinue` and
  `LoopFrame.breaks` use the top frame; codegen's `emitLoopExitDrops` reads
  the top of `loop_marks`, and `skipLabelFor` says "Only the innermost loop
  can own it". `kw_loop` lexes and has no parser rule.
- **The runtime embed is per file.** `src/main.zig` `@embedFile`s
  `cell_rt_h`/`cell_rt_c`, bound by `build.zig`'s `addAnonymousImport` on
  both modules compiling `main.zig`. `src/root.zig`, and so `load.zig`, has no
  such import, and `zig test src/root.zig` must keep working.

## Architecture

### Module graph (`load.zig`)

`load.loadGraph(allocator, io, cwd, entry_path, options, writer)` returns a
`Graph { units: []Unit }` in topological order, dependencies first, the entry
last. `Unit { name, path, dir, module: ast.Module, source, is_entry }`.
`options` carries `module_roots: []const []const u8` and
`std_modules: []const StdModule { name, source }`. `load.load` stays as the
single-unit entry for existing callers and tests until the checking slice
moves them over.

- **Unit name.** The last segment of the `use` path (`use std.prelude` is
  `prelude`, `use lib.geo` is `geo`), which is the qualifier D2 uses. The
  entry's name is its file stem and is never used as a qualifier.
- **Resolution, a total function over a `use` path.**
  1. `std` alone is refused (a root, not a module).
  2. `std.<rest>` looks up `<rest>` in `options.std_modules` and nowhere
     else. Today the table is `{ prelude }`, so `use std.io` and
     `use std.mem.alloc` are "module not found". A `std/` directory on disk,
     or `examples/prelude.cell` beside the importer, cannot shadow it.
  3. Any other `a.b.c` maps to the relative path `a/b/c` and tries, in
     order, the importing unit's directory, then each `--module-root` in
     command-line order. At each place `.cell` and `.cel` are both tested;
     both existing is the existing ambiguous-module error. The first place
     that has the file wins.
- **The std table lives in the CLI.** `load.zig` must not `@embedFile`: that
  would break `zig test src/root.zig`, the documented filter route.
  `build.zig` adds a third anonymous import (`cell_std_prelude`, bound to
  `stdlib/prelude.cell`) on the same two modules as `cell_rt_h`/`cell_rt_c`,
  and `main.zig` builds the table. Library tests pass a literal table. A new
  `stdlib/` file means a new table row, which is why a `std.` path can never
  mean "whatever is in a directory".
- **Stem pairing applies per module.** A resolved `geo.cell` with a
  same-directory `geo.body`/`geo.bod` loads as the merged pair through the
  existing `merge`, so its bodies exist and its functions mangle as
  definitions. The entry keeps today's rule (a `.body` path pairs, a `.cell`
  path does not), so no existing invocation changes meaning.
- **Cycles (D5).** Depth-first with an explicit stack of units in progress;
  meeting a unit on the stack refuses the program and prints the path.
- **Callers.** `root.loadAndCheck` and every `main.zig` path that loads a
  file (the dump/emit commands, `buildOrRun`, `runProgram`, `loadAndReport`,
  `testDir`) take the graph. `main.parseArgs` gains
  `--module-root DIR`: matched before the `a[0] == '-'` `unknown_option`
  branch, taking `args[i + 1]` the way `-o` does (`missing_module_root_value`
  when absent), stored in a bounded `module_root_buf` beside `host_buf`
  because `Invocation` is returned by value.

### Checking with qualified names

Each unit is checked on its own, in graph order, into its own `diag.Bag`
(bags are per file today, `diag.Bag.init(path, source)`), against the
exports of the units it `use`s. Nothing is transitive: a unit sees only what
it names in its own `use` lines.

- **Exports.** After a unit is checked its `pub` functions, structs and enums
  form an export table keyed by the qualified name (`geo.area`,
  `geo.Point`). Non-`pub` items are recorded too, only so a use of one can be
  refused by name rather than reported unknown (D2).
- **Type identity is the qualified name.** A struct or enum declared in a
  non-entry unit `geo` has identity `geo.Point`, inside `geo` as well (bare
  `Point` in `geo` resolves to it). The entry's types keep bare identities,
  so every existing program, test and emitted name is unchanged.
  `types.compatible` keeps comparing strings; diagnostics print `geo.Point`.
- **typecheck.** `checkCall` and `checkField` resolve a field chain rooted at
  an identifier that is not a local and is an imported unit's name through the
  export table. This follows the precedent `checkField` already sets for
  enums: a local binding of the same name wins. `parseType` accepts
  `ident "." ident` for a named type, and the struct-literal head accepts
  `ident "." ident "{"` under the same `no_struct_lit` rule as today.
  `geo.Color.Red` resolves module, then enum, then variant.
- **borrowck (D6).** borrowck stays signature-driven. The five sites that look
  a callee up by identifier (`checkLet`, `checkCall`, `arcCallResult`,
  `borrowSource`, `inferBindingType`, each `self.fns.get` over an ident) move
  to ONE helper, `calleeSignature(expr) ?ast.FnDef`, that answers for an
  ident and for a qualified callee alike, so a sixth site cannot be missed by
  enumeration. Imported signatures are inserted into the importer's table
  under their qualified key and are never walked as items: the importer does
  not re-run R12 or the escape checks on another unit's bodyless declarations,
  which were checked once in their own unit.

### Symbols and visibility, decided once in HIR

A new pure function in `hir.zig`, `decideSymbols(graph) SymbolTable`, runs
over the ASTs before any lowering and cannot fail except for a collision.
It is separate from `hir.lower` because lowering refuses programs C accepts
(`cannot lower`), and C must not depend on a lowering that may have refused.
`hir.Lowerer.symbolFor` and `codegen.symbolFor` both read the table.

| Item | Symbol | Linkage |
|---|---|---|
| bodyless declaration, any unit | `cell_<fn>` (or `cell_assert_msg`) | external |
| runtime callee (`Fn.origin == .runtime`) | the runtime's own | external |
| entry `main` with a body | `cell_main` | external, whatever its `pub` |
| other entry definition | `cell_<fn>` | external if `pub`, else internal |
| definition in non-entry unit `m` | `cell_<m>_<fn>` | external if `pub`, else internal |
| struct/enum in non-entry unit `m` | `cell_<m>_<T>`, glue `cell_drop_<m>_<T>`, constants `cell_<m>_<T>_<Variant>` | none (types are TU-local) |
| entry struct/enum | unchanged | none |

- `hir.Fn` gains `linkage: enum { external, internal }`; `hir.Struct` and
  `hir.Enum` gain `symbol`. Emitters read `linkage` and `symbol` and never
  `is_public` or a name.
- **LLVM:** internal is `define internal`. **MLIR** (measured 2026-09-21 by a
  throwaway spike, Homebrew LLVM 23.1.1, the `mlirmit.lowering_passes`
  pipeline): `func.func private @f(..) { body }` does NOT give internal
  linkage. `convert-func-to-llvm` keeps only `sym_visibility = "private"`,
  `mlir-translate` drops it, and the result is a plain external `define`
  (nm `T`) that a C host links against; it is not removed as dead code
  either. The working spelling is
  `func.func private @f(..) attributes {llvm.linkage = #llvm.linkage<internal>} { .. }`:
  `llvm.func internal`, then `define internal` (nm `t`), and a C caller fails
  with "Undefined symbols". A bodyless `func.func private @cell_print_int(i64)`
  stays an external `declare`; hand-written LLVM `define internal` behaves as
  the MLIR form does. So mlirmit writes `private` plus the attribute on every
  internal definition, and never the attribute on a bodyless declaration.
- **C:** internal is `static __attribute__((unused))`. The attribute is not
  cosmetic: `examples/pairing/geometry.body` defines a non-`pub` `origin`
  that nothing calls, and a bare `static` trips `-Wunused-function` under the
  `-Wall -Wextra -Werror` builds (stage 9, and the recipe `hello.cell`
  documents). codegen already uses the same spelling for drop glue for the
  same reason. `// export` stays above an external `pub` definition.
- `codegen.resolveCallee`'s joining branch is removed: a dotted callee is
  either a table hit or a refusal, never a guessed link-time name.
- **One entry point.** llvmemit's `@main` wrapper (which today matches any
  `Fn` named `main` with a body and no parameters) and codegen's
  `emitEntryPoint` (`findFn("main")`) key on the entry unit's `main` only; a
  `main` in another unit is an ordinary `cell_<m>_main`. mlirmit emits no
  wrapper and the gate links its output against `drv.c`'s
  `extern void cell_main(void)`, which is why entry `main` is external
  whatever its `pub`.
- **Output shape.** One program, one output per target: C writes every
  unit's types, prototypes, then bodies into one translation unit;
  `hir.lowerProgram(graph)` returns one `hir.Module` spanning all units, so
  llvmemit and mlirmit need no multi-file logic.

### Labels (D-F1, D-F2)

- **Parser.** `parseStmt` maps `kw_loop` to `while_stmt` with a synthesized
  `true` condition spanning the `loop` keyword. A label needs two-token
  lookahead (`ident` then `colon`) before the expression fallthrough, and
  must be followed by `while` or `loop`. `break`/`continue` take an optional
  `:ident`. `while_stmt` gains `label: ?[]const u8`; `break_stmt` and
  `continue_stmt` gain `label: ?[]const u8`.
- **typecheck.** `loop_depth` becomes a stack of `?label`; a labelled jump
  must name an enclosing loop; a label may not repeat one already enclosing
  it (sibling loops may reuse a name).
- **HIR resolves the label once.** `lowerStmt` keeps its own loop stack and
  lowers a jump to `brk: u32`/`cont: u32`, the number of loops left beyond
  the innermost (0 is today's plain jump). An unresolvable label in an
  unchecked module is `cannot lower`, not a guess. Every consumer indexes
  `len - 1 - n`: `cfg.Builder.lowerJump` adds its edge to that `LoopCtx`'s
  `exit` or `cond`; `liveness.Walker` asserts `loop_depth > n` and otherwise
  only ends the path, so its lockstep with `cfg.Builder` is unchanged and the
  `GraphMismatch` check still guards it; llvmemit's and mlirmit's singletons
  become stacks of `{break, continue}` targets.
- **borrowck, target frame only.** `break :outer` saves its state into the
  outer frame (`saveBreakState` on the target) and appends to that frame's
  `breaks`; `continue :outer` asks R2.a of the outer frame (`checkContinue` on
  the target). Frames in between see neither, because control never reaches
  their back edge or their after-loop point on this path. The plan's wording
  "R2.a asks every frame the jump passes" would wrongly refuse
  `take(v); continue :outer` inside an inner loop for a `v` declared in the
  outer body (the next outer iteration re-declares it); this spec takes the
  target-only reading and pins that case as accepted. The implementation plan
  enumerates the AST walks over `break_stmt`/`continue_stmt`
  (`grep -rn 'break_stmt\|continue_stmt' src/cell`).
- **C lowers a labelled jump as a `goto` at the target's mark.** It emits
  `emitDropsSince(target_mark)` and `emitTempReleases(target_depth)` (the
  same calls `emitLoopExitDrops` makes today, with the target's mark and
  depth in place of the top's), then:
  - `break :outer`: `goto cell_brk_<n>;`, with `cell_brk_<n>:;` right after the
    outer loop's `}` and before its `emitAfterLoopDrops`, which is where a
    plain `break` of that loop lands. A skip-revival break keeps going to
    `cell_skip_<n>`, so `skipLabelFor` searches `skip_labels` by `loop_key`
    instead of reading the top.
  - `continue :outer`: `goto cell_cont_<n>;`. A loop that is a labelled
    continue target is emitted as `while (c) { { body } cell_cont_<n>:; }`,
    so the label sits outside the scope of every body local and the jump
    crosses no declaration.
  - A labelled jump whose target is the innermost loop emits plain
    `break`/`continue`, so existing output does not change.

## Invariants

Each is testable, and each slice's tests name the ones it covers.

1. Every backend emits the same symbol for a function, and C, LLVM and MLIR
   read it from `hir.decideSymbols`; no emitter formats `cell_{s}` from a
   function or type name.
2. A bodyless declaration is never prefixed: `cell_<fn>` in every unit, and
   always external.
3. The entry unit's `main` is `cell_main` with external linkage in every
   backend, and only the entry unit gets a C/LLVM `main`.
4. Linkage is decided from (bodyless, origin, entry `main`, `pub`) only, and
   `is_public` is read by no emitter.
5. A non-`pub` definition is unreachable from outside the program: a C host
   calling it fails to link on C, LLVM and MLIR, and a host calling its `pub`
   sibling links.
6. No MLIR bodyless declaration carries `llvm.linkage`; every MLIR internal
   definition carries `llvm.linkage = #llvm.linkage<internal>`.
7. Two items with the same symbol in one program are refused before any
   emitter runs. Mangling by `_` is not injective (`a_b.c` and `a.b_c` both
   give `cell_a_b_c`; unit `drop` with type `X` gives `cell_drop_X`), so this
   check is what makes it sound; it extends the comparison
   `hir.Lowerer.resolveRuntime` already makes against runtime symbols.
8. A `std.` path never reads the filesystem: resolving it opens no file, with
   or without a `std/` directory or a `prelude.cell` beside the importer.
9. Resolution is deterministic: the same argv and tree give the same unit
   order and the same chosen file, and a not-found lists exactly the places
   tried, in the order tried.
10. A cycle is refused before any unit is checked.
11. An imported unit's bodyless declarations are checked once, in their own
    unit; importing them runs no R-rule over them again.
12. A non-`pub` item never resolves through a qualifier.
13. A labelled jump runs the drops of every loop it leaves exactly once:
    every owning local declared since the target loop's mark is released on
    the jump, or later on the path the jump reaches, never both, never
    neither, and no local of the target's enclosing scope is released.
14. A labelled jump's state reaches the target frame's borrowck facts and no
    intermediate frame's.
15. `loop { B }` and `while true { B }` produce the same HIR, CFG and emitted
    code for all three backends.
16. Every refusal names its reason; no case falls through to emitting a guess
    (`resolveCallee`'s joining branch is gone, an unresolved HIR label is
    `cannot lower`).

## Error handling

Format is the existing `path:line:col: error: ...` from `load.zig` and
`diag.Bag`. A bag is per file, so a location in another file is written into
the message text. Proposed wording:

- Not found, filesystem: `main.cell:3:1: error: module 'geo' not found; searched examples/modules/geo.cell, examples/modules/geo.cel, lib/geo.cell, lib/geo.cel`
- Not found, std: `main.cell:1:1: error: module 'std.io' not found; the embedded std root provides: std.prelude`
- Bare root: `error: 'std' is the standard root, not a module`
- Cycle: `a.cell:2:1: error: import cycle: a.cell -> b.cell -> a.cell`
- Name collision: `error: module name 'util' is already imported from a/util.cell (main.cell:3:1)`,
  or `error: 'geo' is both an imported module and a function declared in main.cell`
- Symbol collision: `error: symbol 'cell_a_b_c' is produced by both 'a_b.c' (a_b.cell:5:1) and 'a.b_c' (a.cell:9:1)`
- Private use: `main.cell:9:5: error: 'origin' is not public in module 'geometry' (declared without 'pub' at examples/pairing/geometry.body:33:1)`
- Re-export: `error: 'pub use' is not supported` (today `pub` is silently dropped)
- Labels: `error: no enclosing loop is labelled 'outr'`;
  `error: label 'outer' is already used by an enclosing loop (main.cell:2:1)`
- CLI: `error: --module-root needs a directory`; `error: --module-root 'lib': not a directory`

Refusal direction: every question the loader cannot answer (ambiguous file,
unreadable root, unknown std name) is an error, never a fallback.

## Testing

TDD per slice, red test first; the count quoted from the gate's own output.
Remember the `--test-filter` trap: a filter matching nothing prints
`All 1 tests passed`, so check the named test appears.

- **Unit tests.** `load.zig`: std resolution against a test `Dir` holding a
  `std/prelude.cell` that does not parse (proves it is never opened), root
  order, `.cell`/`.cel` ambiguity, cycle and not-found text. `main.zig`:
  `--module-root` repeated, missing value, over the bound. `hir.zig`: every
  symbol-table row, collision refusal. Parser/typecheck: `loop`, labels,
  unknown and duplicate labels. `cfg.zig`: a labelled edge targets the outer
  `exit`/`cond`; `liveness.zig`: lockstep over a labelled program. Emitter
  text tests for `define internal`, `llvm.linkage<internal>`,
  `static __attribute__((unused))` and `goto`.
- **Corpus.** `examples/loop.cell` (beside the existing `loops.cell`) and
  `examples/labels.cell`, each with `EXPECT-OUTPUT` on all three backends,
  the latter including the accepted `continue :outer` after moving a place
  declared inside the outer body. `examples/modules/`: an entry `main.cell`
  with `EXPECT-OUTPUT`, `use geo`, `use grid` and `use std.prelude`;
  `geo.cell` with a `pub` function, a non-`pub` helper and a `pub struct`;
  `grid.cell` + `grid.body`, a module plus a body pair.
- **Rejected.** `examples/rejected/`: `cycle_a.cell` and `cycle_b.cell` (each
  rejected, since each starts a cycle), `module_collision.cell`,
  `private_use.cell`, `unknown_label.cell`, `duplicate_label.cell`,
  `labelled_continue_move.cell` (R2.a on the target frame). Helper modules
  they import live in `examples/rejected/lib/`, which the flat
  `examples/rejected/*.cell` loop does not visit. The verdict loop checks
  only accept or reject, so each diagnostic's text is pinned by a unit test.
- **Private-symbol link test** (invariant 5), in stage 6: a host
  `examples/modules/private_link_host.c` calling the non-`pub`
  `cell_geo_<helper>` must FAIL to link on C, LLVM and MLIR, and a control
  host calling a `pub` sibling must link and run. A row that links when it
  must not is a FAIL, never a SKIP.
- **Leak fixtures.** `examples/leaks/labelled_break.cell` and
  `labelled_continue.cell`: 1000 iterations, an owning `String` declared in
  the outer body and one in the inner, a labelled jump crossing the inner
  loop. Pinned at 0 on C by both witnesses. Their LLVM/MLIR rows are pinned at
  the measured count, and join the flip criterion.
- **Gate globs.** `accepted_examples` (stages 4 and 5) and the stage 8 loop
  (`for f in examples/*.cell` before `== backend answers ==`) and the stage 10
  loop gain `examples/modules/*.cell`; so do stage 3's must-pass loop and the
  stage 9 sanitizer loop, which the plan's list (4, 5, 8, 10) omits. A
  non-entry module in that glob is also checked and emitted standalone as an
  entry, which is valid and cheap. `--module-root` gets one stage 12 row
  through `cell run`.
- **Stage 10 probe regex: verify, probably unchanged.** The awk pattern
  `/^(declare|define)[^@]*@cell_[A-Za-z0-9_]*[ ]*\(/` admits
  `define internal ... @cell_geo_area(`, `bareType` already drops `internal`
  and `private`, and the C probe's `sed` matches `static` prototypes too (a
  static function's address is legal in its own TU). The plan says "updated
  to match"; the first run on `examples/modules/` decides, and the slice
  records which.

## Slices, in order

Each ends with `tools/check.sh` exit 0 and a clean or SKIP-citing verdict,
quoted test count, `driver.sh --expect` on every new example, pins only
falling, and `sweep-backends.sh` at 0 after any ownership-lowering change.

1. **D-F1, `loop`.** Parser rule; `while` tests copied for borrowck R2.a,
   codegen drops and `cfg`; `examples/loop.cell`; the `lexer.zig`
   reserved-word comment updated.
2. **D-F2, labels.** AST payloads, typecheck label stack, HIR depth, `cfg`,
   liveness, both IR emitters, borrowck target frames, C `goto`;
   `examples/labels.cell`; the label rejections; both leak fixtures; SPEC 7.7
   rewritten ("Labelled loops are not designed" becomes the design above).
3. **D1/D5 loader.** `loadGraph`, the std table and its `build.zig` import,
   `--module-root`, cycle refusal, every caller moved. **The `use std.io` and
   `use std.mem.alloc` lines leave `hello.cell:10` and `declarations.cell:11-12`
   in this slice, not the last one:** from here on they are hard errors and
   the corpus stage would go red. Until slice 5, `emit` refuses any program
   with more than one unit on every target, so no unmangled multi-unit code is
   ever written.
4. **D2/D6 checking.** Export tables, qualified type identity,
   `parseType`/struct-literal qualification, `checkCall`/`checkField`,
   borrowck's `calleeSignature`, private-name refusal, `pub use` refusal.
5. **D3/D4 symbols and visibility.** `decideSymbols`, `Fn.linkage`,
   `Struct/Enum.symbol`, the emitters reading them, the MLIR attribute, C
   `static __attribute__((unused))`, the `resolveCallee` joining branch
   removed, the entry-only `main` rule, the collision refusal. Text tests
   that pin a non-`pub` entry definition's line change here (it becomes
   internal), in the same commit.
6. **Examples and gate.** `examples/modules/`, the rejected module cases, the
   private-symbol link rows, the glob changes, stage 10 verified, SPEC 8.4 and
   8.5 and `docs/FEATURES.md` rows updated from the gate's output.

## What stays out

- `defer` (D-F3) and `for` (D-F4), deferred by ruling. D-F3's ordering
  question (before or after the scope's drops) stays the first thing to rule.
- Glob imports, `use a as b` aliases, and `pub use` re-export (refused, not
  ignored).
- Separate IR or object files per module, and C header emission.
- Qualifiers deeper than one module segment in type position (`a.b.Point`);
  `use a.b` still binds `b`.
- Labelled blocks (`blk: { .. break :blk v }`) and `break` with a value.
- Package, network or version resolution; any search not named in D1.

## Open questions

**Ruled 2026-09-22 by Donald**, so none of the three below is open any more:
1, the local wins (as drafted); 2, a `pub` signature naming a non-`pub` type
is refused (as drafted); 3, **every `.cell` is paired with its `.body` mate,
the entry file included**, which is not the draft's default. The consequence
of 3: `cell check examples/pairing/geometry.cell` now checks the merged unit,
exactly as `cell check examples/pairing/geometry.body` does today. The
loader pairs every unit through one path (entry and imported alike), so
`load.load`'s early return for a non-body file goes away. Gate stage 3's
pairing loop must still pass both files, and a new `root.zig` test pins that
checking the `.cell` and checking the `.body` give the same diagnostics.
The text below is kept as drafted, for the record.


Donald has ruled on everything the brief asked. These are new, found while
designing; each carries the default this draft uses, so none blocks the
implementation plan.

1. **A local named like an imported module.** Default: the local wins, the
   precedent `typecheck.checkField` sets for enums, so `prelude.print_int`
   after `let prelude = ..` is a field access on the local. The alternative is
   refusing the shadowing `let`.
2. **A `pub` signature naming a non-`pub` type.** Default: refused
   ("`pub fn make` returns non-public type 'Hidden'"), since an importer could
   hold a value it cannot name. The alternative is allowing it, as C would.
3. **A `.cell` entry with a `.body` mate.** Default: unchanged (not paired),
   while an imported module is paired. The alternative pairs both, which
   changes what `cell check geometry.cell` means today.
