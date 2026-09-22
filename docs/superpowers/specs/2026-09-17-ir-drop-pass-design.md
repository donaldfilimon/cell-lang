# IR String step (c): a drop pass on HIR

Status: direction approved by Donald 2026-09-17 ("pin the IR leak, then
build": conversions, indexing, list literals, then a drop pass ported onto
HIR). Step (a) has landed; step (b) is drafted separately. This document is
step (c). A planning pass read the code on 2026-09-17 at `ccfb331` and
produced it. It edited nothing in the repository: every probe ran in an
exported tree under `/private/tmp/claude-501/stepc/`, and the reproducers
cited below sit in `/private/tmp/claude-501/stepc/repro/`. Line anchors are
from `ccfb331` and will drift.

The `/private/tmp` reproducer paths below are session scratch and may be
gone; each defect that gets fixed carries its reproducer into a test or a
corpus example. Status 2026-09-17: under Donald's review, no code yet.

## Where things stand

- **Neither IR backend frees anything.** The pins in `tools/check.sh` stage 7
  were re-measured here with the malloc counter and reproduce exactly:

  | Fixture | C | LLVM | MLIR |
  |---|---|---|---|
  | `leaks/ir_owned_string` | 0 (ALLOC 3000) | 3000 | 3000 |
  | `leaks/ir_string_conversion` | 0 (ALLOC 9000) | 9000 | 9000 |
  | `owned_string` + host | 0 (ALLOC 9) | 8 | 8 |

- **The C drop pass is the reference, and it is AST-driven.** It lives in
  `codegen.zig` and asks `borrowck.Checker` every question:
  - `pendingDropsSince` (1403) admits a local only when it is `droppable`,
    annotated `owned` or `arc`, `needsDrop`, not shadowed (`isShadowedAt`),
    and either unmoved (`wasMoved`) or live at this exit (`liveAtExit`);
  - drop points: the end of a statement block (`emitStmts`), `return`
    (`emitReturnStmt` 1576, value hoisted into a temporary first), `break`
    and `continue` (`emitLoopExitDrops` 1487), after a loop
    (`emitAfterLoopDrops` 1527, plus `after_loop_skip` lowered as a `goto`),
    a branch end (`emitBranchEndDrops` 1985, with a synthesized `else`), a
    value block end (`emitValueBlockDrops` 2516, skipping everything the
    tail can reach);
  - a record is released through generated glue, or field by field when
    only some fields moved (`emitPartialRecordDrop`);
  - an owned reassignment releases the old value first, only when
    `assignReleasesOldValue` (keyed by the target name's `ptr`) vouches for
    that store (`reassignedDroppableLocal` 1007);
  - early exits release untaken owning `match` scrutinee temporaries
    (`owning_temps`, `emitTempReleases` 1621, `fdf36ed`). Only owning
    `Result` and `T?` are tracked; a `String` scrutinee temporary is not.
- **The id-numbering agreement.** Codegen keeps its own `next_binding_id`
  and assigns ids at the points borrowck's `declare` runs. `pushLocal`
  (4031) requires positive confirmation from `Checker.bindingName`, and an
  unconfirmed local is never dropped.
- **The borrowck facts are keyed by AST addresses.**
  - `moved` and `moved_paths` by binding id;
  - `assign_liveness` by the target identifier's `name.ptr`;
  - `exit_liveness` and `exit_field_liveness` by `(ExitKind, key)`, where
    the key is a statement address, a statement slice's `ptr`, or a branch
    expression's address;
  - `wrap_moves` by the `Ok` operand's address.

  HIR keeps none of these addresses.
- **`cfg.zig` and `liveness.zig` do not supply what a drop pass needs.**
  - They compute liveness (use and def), not move state. A move is an
    ordinary `ref` read there.
  - They know nothing of borrowck's conservatism (a one-branch move poisons
    the rest of the function), which is exactly what keeps C safe.
  - They stay scaffolding in this step.
- **HIR facts that exist and matter:**
  - `Expr.own` (step (a));
  - `Binding.ownership` and `Binding.is_param`;
  - `FieldSel.ownership`;
  - `ArgMode.param` per call argument;
  - `Fn.origin` and `runtime_callees` with the collision check in
    `resolveRuntime`.
- **HIR facts that are missing:**
  - the borrowck id of each binding (a slot is per function; a borrowck id
    is per module);
  - whether a binding may be dropped at all. `lowerPattern` stamps a
    binding pattern `.owned` (hir.zig 1288), so a pass keyed on ownership
    alone would free a match-arm binding, which is a bitwise copy of its
    scrutinee. That is the double free C's `droppable = false` prevents;
  - any move fact or exit-liveness fact.
- **`root.emitFor` runs no borrow checker** before `hir.lower` (root.zig
  97 to 121). Codegen runs its own inside `emitModule`.
- **The emit path for a drop already exists.** A bodyless
  `string_free(exclusive s: String)` gets the symbol `cell_string_free`
  (`symbolFor`). Hand-written `string_free(exclusive t)` and
  `string_free(exclusive t.name)` calls lower in both emitters with no
  change:
  - LLVM: `call void @cell_string_free(ptr %slot2)`,
    `declare void @cell_string_free(ptr)`;
  - MLIR: `call @cell_string_free(%3) : (!llvm.ptr) -> ()`;
  - clang declares `declare void @cell_string_free(ptr noundef)`, and stage
    10 strips `noundef` (check.sh 1717), so the declarations agree;
  - measured (`repro/handdrop.cell`): `ir_owned_string`'s shape drops to
    LIVE 0 on both backends and runs ASan-clean.
- **Except for a field place in MLIR.** LLVM passes
  `string_free(exclusive t.name)` as a `getelementptr` into the slot. MLIR
  `extractvalue`s the field into a fresh `llvm.alloca` and passes that
  copy. The free hits the right buffer, so LIVE still reads 0, but
  `t.name` is left dangling. This is defect 5 below, and inlined record
  drops depend on fixing it.

## Design

### 1. A drop is a synthetic runtime call, inserted by `hir.lower`

- **New runtime callee.** `Runtime.string_free` joins `runtime_callees`:
  `$rt.string_free`, symbol `cell_string_free`, one parameter
  `exclusive String`, return unit. `resolveRuntime` already declares it
  once, reuses an identical user declaration, and refuses a conflicting one.
- **A drop is `Stmt.Kind.expr` holding that call.**
  - The argument is the place: a `.ref` of the slot, or a `.field` chain
    rooted at one.
  - Its mode is `{ .param = .exclusive, .written = .exclusive }`.
- **Why a call and not a new `Stmt.Kind.drop`:**
  - no emitter changes for a whole binding. Both emitters pass an
    `exclusive` String argument that is a `.ref` as the slot's ADDRESS
    (`a6c41e8`). That is required: the runtime zeroes what it frees, and a
    spilled copy would leave the slot holding a dangling pointer. A
    `.field` argument is an address in LLVM and a spilled copy in MLIR
    (defect 5), so record drops need that MLIR fix first (commit 5a);
  - stage 10 compares the declaration for free;
  - `cfg.zig` and `liveness.zig` see an ordinary call over a `ref`, so the
    rule that their two walks change together is not triggered at all.
- **The alternative is deferred.** A dedicated `drop` node is easier to find
  in tests and dumps, but it costs a paired arm in `cfg.Builder` and
  `liveness.Walker`, plus an arm in each emitter. Revisit it when `arc` or
  `[T]` drops arrive, since those need more than one runtime symbol.
- **Pin the shape, do not assume it.** The synthetic call must be exactly
  what `lowerExpr` produces for the source form `string_free(exclusive x)`:
  - a bare `.ref`, since the written prefix is stripped;
  - `modes[i].param == .exclusive`;
  - `own` left null on the argument.

  Commit 1 carries a test that lowers the source form and compares it
  field by field with the helper's output.

### 2. Where the pass runs: inside `Lowerer`, with the checker

- **Why the placement is forced.** `hir.lower` is the only point that holds
  both the AST addresses borrowck keys its facts on and the HIR slots the
  drops must name. A separate pass over finished HIR would first need every
  exit key copied onto HIR nodes: statement addresses, slice pointers,
  branch expression addresses and assignment `name.ptr`s. That means
  opaque integers on half the node kinds.
- **`lower` gains an optional checker.** A new
  `lowerChecked(allocator, module, diagnostics, checker: ?*const borrowck.Checker)`
  is added, and the existing three-argument `lower` stays as a wrapper that
  passes `null`.
  - With `null`, no drop is inserted. That matches codegen's
    `checker orelse return` and keeps every existing caller compiling and
    unchanged: the hir tests, `llvmemit.zig` 2011, `root.zig` 515, and the
    hand-built HIR in the cfg and liveness tests.
  - The emitter drop tests need their own `Checker` and call
    `lowerChecked`.
  - `hir.zig` stops being a leaf that imports only `ast`, `types`, `diag`
    and `abi`. That is stated here, not hidden. `cfg.zig` and
    `liveness.zig` remain leaves.
- **`root.emitFor` runs a checker** exactly as `codegen.emitModule` does:
  one `checkModule` over the whole module, `hasErrors` not consulted, freed
  after emission.
- **The Lowerer mirrors codegen's drop bookkeeping:**
  - a `locals` stack of `{slot, bc_id, droppable}` with marks per scope;
  - a `loop_marks` stack;
  - `current_after`;
  - the same emission points, in the same order (release in reverse
    declaration order).
- **Emission stays identical when nothing needs dropping.** A function with
  no droppable local produces the same HIR as today, node for node, so
  stage 4 and stage 5 output for the 22 examples each backend accepts does
  not churn. `emitReturnStmt`'s byte-for-byte rule is the precedent.

### 3. The HIR facts to add

- **`Binding.bc_id: ?u32`.**
  - The borrowck id, assigned by a mirrored module-wide counter at the
    points borrowck declares, and confirmed with `bindingName`.
  - Null when unconfirmed, so the binding is never dropped (fail toward a
    leak).
  - It adds one global check C lacks: after lowering, the counter equals
    `checker.next_binding_id`, or the module inserts no drops at all.
- **Known declaration-order hazards, each with a test:**
  - **Bodyless function parameters.** HIR creates their slots (lowerFn
    526), but borrowck returns before declaring them (borrowck 711 to 722).
    The mirrored counter must skip them, or every later id in the module is
    off by the parameter count.
  - **Payload bindings.** `Ok(x)` and `Some(x)` payload bindings are
    declared by borrowck for every `wrap_pattern` with a binding (2686).
    HIR declares them only on the scalar paths it lowers, but a module that
    reaches `cannotLower` emits nothing, so the drift cannot reach an
    emitter. The test pins that.
  - **Runtime `Fn`s.** `resolveRuntime` appends them after lowering. They
    take no ids.
  - **Scratch slots.** The return temporary in section 4 must bypass the
    counter, as codegen's `pushScratchLocal` does.
- **`Binding.droppable: bool`.**
  - True for `let` and `var` bindings and for parameters of a body.
  - False for a binding pattern, a payload binding and a scratch slot.
  - It is a candidate flag only; section 4's checks still apply.
- **No move node.** Move and liveness facts stay in the checker and are
  read at lowering time, as in C. Recording them on HIR nodes would be a
  second copy of borrowck's state that nothing could keep in step.

### 4. The first slice: what is freed

The rule is C's `pendingDropsSince`, restricted to the owning String
representation (`stringRep == .owning`, which excludes `arc`):

| Admitted | Drop point | C counterpart |
|---|---|---|
| unmoved `owned` String `let`/`var` | end of its statement list (function body, `while` body, bare block, `if` branch, `match` arm body) | `emitStmts` |
| unmoved `owned` String parameter of a body | function end | R11 row 1 |
| the same | before `ret` (value hoisted into a scratch slot first) | `emitReturnStmt` |
| the same, declared since the innermost loop mark | before `brk` and `cont` | `emitLoopExitDrops` |
| a record local with owning String fields, unmoved | the same points, one `string_free(exclusive x.f)` per owning field, reverse declaration order, recursing into nested records | `cell_drop_<Name>` glue, inlined |
| an owned String `var` reassigned | before the store, value hoisted first, only when `assignReleasesOldValue` | `reassignedDroppableLocal` |

- **Row 1 is guarded by shadowing.** `isShadowedAt` is not needed as a name
  check, because HIR names slots, not identifiers. A shadowed outer binding
  therefore CAN be dropped correctly in HIR, where C leaks it. The spec
  keeps C's behaviour in slice 1 anyway (skip a shadowed binding), so the
  two backends agree on the counter, and records the lift as an open
  question.
- **A record is inlined, not given glue.** Probe `repro/conv_rec.cell`:
  `string_free(exclusive t.name)` lowers in both emitters and takes
  `ir_string_conversion` to 0. There are no generated functions and no new
  stage-10 symbols.
- **That 0 is not yet evidence of correctness in MLIR.** It frees a
  spilled copy, and a copy frees the same buffer (defect 5). The field
  drop is safe only once MLIR passes the field's address. A record with any moved path is skipped whole in
  slice 1, rather than porting `emitPartialRecordDrop`.
- **The return hoist.**
  - `return e` with pending drops becomes
    `let $r = e; <drops>; return $r`.
  - `$r` is a non-droppable scratch binding of the declared return type and
    ownership.
  - A `return` with no pending drop is emitted unchanged.

### 5. What stays leaking, and how it is pinned

Each item is a deliberate skip on the leak side, so each has a measured pin
or an existing refusal.

- **Anything `wasMoved` answers true for.** Slice 1 does not port
  `liveAtExit` revival, so a moved-then-revived `var` leaks its revived
  value.
  - `repro/shape-matrix/revival.cell` measures C 0 and IR 2000.
    Hand-dropping it the way slice 1 would (`repro/revival_slice1.cell`:
    `sink` frees its parameter, and the moved `s` is not dropped) measures
    1000 on both IR backends.
  - Move-on-one-branch, revival and branch-end releases are slice 2.
- **`after_loop` and `after_loop_skip` are not ported.** HIR has no `goto`
  for the skip form. More importantly, the C `after_loop` release has a
  defect (see *Defects found*), and porting it would copy that defect.
- **Value-block locals.** C skips every local the tail can reach, so this
  leaks in C too for a String read by the tail. A value block cannot hold
  a drop after its tail without a scratch slot; slice 2.
- **Temporaries.**
  - A `match` over an owned String temporary is refused by both IR
    backends today (`repro/shape-matrix/match_temp_scrut.cell`). C accepts
    it and leaks 1000 per 1000 calls.
  - A discarded owned String call result leaks on all three backends
    (`repro/discard.cell`, 2000 each). See *Defects found*.
  - Slice 1 frees no temporary, so the IR matches C here.
- **Synthetic conversion results.** Every `cell_string_from_str` call step
  (a) inserts lands in a declared destination, and each is freed or moved
  exactly once by rows already in section 4:
  - a `let` or `var` is freed as its binding;
  - an assignment is freed by the next pre-drop or at scope end;
  - an `owned` call argument moves into the callee, which frees its
    parameter;
  - a struct-literal field is freed by the inlined record drop;
  - a `return` moves to the caller;
  - a value-slot arm flows into its destination.

  None is a bare temporary, because `convertTo` never converts where the
  slot wants a view. `ir_string_conversion` exercises all eight positions
  and is the witness.
- **A write through `exclusive String`** overwrites without freeing, as in
  C (disclosed at step (a)).
- **A field store** `t.name = ...` leaks the old value in C (1000 in
  `repro/field_assign.cell`). Slice 1 does not pre-drop a field. See
  *Defects found*.
- **`[String]` elements** are never released in C and are refused as list
  literals by both IR backends. Step (d) owns them.

### 6. Double-free risk, and how each is falsified

- **Where the risk lives.** A drop is a double free exactly when another
  slot holds a bitwise copy of the same buffer and is also freed. That
  happens in four ways:
  - an `owned` argument or `return` copies the header;
  - a match-arm binding copies the scrutinee;
  - a record field copies a local;
  - a pre-drop runs where the old value was already moved.
- **A duplicated drop of the SAME slot is harmless only when the argument
  is the slot's address**, because `cell_string_free` zeroes it. That
  makes the mutation "emit every drop twice" a witness for address
  semantics rather than for move facts. Measured with
  `repro/conv_rec_twice.cell`, which frees `t.name` twice:
  - LLVM exits 0, ASan-clean;
  - MLIR exits 134 with `attempting double-free`, which is defect 5.

  After the MLIR fix, both backends must exit 0 on it.
- **Why ASan works on IR legs, and its limit.** Measured here:
  - An uninstrumented IR object linked with an ASan-built `cell_rt.c` and
    host catches a double free (`repro/dbl_mut.ll`: `attempting
    double-free`, exit 134).
  - It also catches a heap-use-after-free read inside the runtime
    (`repro/uaf_mut2.ll`: `heap-use-after-free` in `cell_print`, exit 134).
  - This is sufficient for the String surface because every heap
    dereference today is inside `cell_rt.c` or a host:
    - `string_view` reads the stack header, not the buffer;
    - `str_eq`, `str_len` and `print` are runtime functions.
  - **The limit.** Step (b) indexing adds direct heap loads to the IR, and
    this witness stops covering those loads. Adding `sanitize_address` to an
    emitted `define` and compiling with `-fsanitize=address -x ir` produced
    no `__asan_report` references at `-O0` here, so instrumenting IR is an
    open question, not a claim.
- **Falsifiers, all mechanical:**
  1. **ASan on every runnable corpus program through LLVM and MLIR.**
     - Today, 29 examples have a `main`, 22 emit on each backend, and all
       44 legs run ASan-clean (`repro/asan-baseline-sweep.txt`).
     - Stage 9 gains these legs with the precise claim above, and its
       header's reason for skipping them is corrected.
  2. **A mutation that disables the `wasMoved` filter.** A Zig test shells
     to `cc` as codegen's ASan tests do, and `repro/dbl.cell` with its host
     must exit 134. Restored, it must exit 0 and print 10.
  3. **A mutation that sets `droppable = true` on a binding pattern.** A
     match that binds its owned scrutinee and also drops the scrutinee
     place must exit 134.
  4. **The doubled drop above**, kept as a permanent run test on both
     backends.
  5. **A mutation that deletes one drop.** A test-only switch skips the
     Nth inserted drop. `ir_owned_string` must read exactly 1000 above its
     new pin, which proves the pin is sensitive to the drop it credits.
  6. **Answer checks.** `EXPECT-OUTPUT` goes on every new fixture, and each
     fixture runs through stage 8. The after-loop defect below is invisible
     to both the malloc counter and ASan (the free zeroes the header, so
     the later read sees an empty view), and only the printed answer shows
     it.
  7. **The leak pins, measured before pinning** (section 7).

### 7. Gate changes

- **Stage 7, predicted from hand-dropped probes and to be measured again
  on the real pass before any constant moves:**

  | Pin | Now | Slice 1 without record drops | Slice 1 |
  |---|---|---|---|
  | `LEAK_IR_OWNED_STRING_{LLVM,MLIR}` | 3000 | 0 | 0 |
  | `LEAK_IR_STRING_CONVERSION_{LLVM,MLIR}` | 9000 | 1000 | 0 |
  | `LEAK_OWNED_STRING_{LLVM,MLIR}` | 8 | 1 | 0 |

  The probes are `repro/handdrop.cell`, `conv_norec.cell`,
  `conv_rec.cell`, `os_norec.cell` and `os_rec.cell`. All ran ASan-clean
  on both backends and printed 4890, 44000 and 44.
- **New fixtures, three backends each, the C count disclosed where it is
  not 0:**
  - `leaks/ir_param_drop.cell`: an owned parameter of a body, and a move
    into it;
  - `leaks/ir_loop_drop.cell`: loop locals with `break` and `continue`;
  - `leaks/ir_revival.cell`: pins the slice-1 leak, which slice 2 closes;
  - `leaks/owned_discard.cell`: C, LLVM and MLIR at 2000 today.
- **`run_ir_leaks` stays one witness.** `leaks -atExit` still cannot wrap
  an IR `main`.
- **Stage 9** gains LLVM and MLIR legs, linked against an ASan-built
  runtime and host.
- **Stage 10** compares `cell_string_free` against C with no pin. A
  disagreement is a defect, not a pin.
- **Stage 4 and stage 5** must stay green and unchanged in verdicts.
  Emitted text changes only in functions that gained drops.

## Defects found along the way (at `ccfb331`; 1 to 4 in C, 5 in MLIR)

1. **After-loop release frees a String that a later statement reads. This
   is a silent wrong answer.**
   - Reproducer: `repro/after_loop_uaf.cell` with
     `repro/after_loop_uaf_host.c`, whose `take` frees its argument.
   - C emits `cell_string_free(&s); cell_print(cell_string_as_str(&s));`
     after the loop and prints an empty line. LLVM and MLIR print `again`.
   - `repro/loop_outer_revive.cell` prints 4890 in C against the
     hand-computed 5890 in LLVM and MLIR.
   - Both are counter-clean (C: ALLOC 3, FREE 3) and ASan-clean, because
     `cell_string_free` zeroes the header, so the read sees a null view.
   - The likely mechanism, read but not bisected:
     - `emitAfterLoopDrops` skips a release only when `current_after`'s
       exit records the binding live;
     - `loop_moved` poisons that `block_end` record to false;
     - so a use later in the same statement list is never consulted, and
       the release runs before it.
   - If the reading were not a view but an `owned` move of a copy, this
     could become a double free. That is not measured.
2. **A discarded owned String call result leaks on all three backends.**
   - Reproducer: `repro/discard.cell`, measured at 2000 per 1000 calls in
     each backend.
   - `emitDiscarded` releases nothing for a String.
   - No disclosure was found in `docs/OWNERSHIP.md` (grep for "discard" and
     "unbound" found only the `arc` row).
3. **A field store leaks the old owned value in C.**
   - Reproducer: `repro/field_assign.cell`, 1000 per 1000 calls.
   - `t.name = ...` has no pre-drop, because `reassignedDroppableLocal`
     takes only a bare identifier.
   - No disclosure was found by grep. It may be known under another
     wording.
4. **A match over an owned String temporary leaks in C.**
   - Reproducer: `repro/shape-matrix/match_temp_scrut.cell`, 1000 per 1000
     calls.
   - `owning_temps` tracks only `hasOwningGlue` shapes.
   - Both IR backends refuse this program, so there is no backend
     disagreement.
   - CLOSED in C 2026-09-17: a call's owned String scrutinee joins
     `owning_temps` (`examples/leaks/match_string_temp.cell` pinned at 0).

5. **An MLIR `exclusive` argument that is a field place is passed as a
   spilled copy, so a write through it is lost. This is a silent wrong
   answer.**
   - Reproducer: `repro/field_exclusive_write.cell` (no host). `put`
     writes `s = str_from_int(42)` through `exclusive s`, and `main` passes
     `exclusive t.name` and then prints it.
   - C and LLVM print `42`. MLIR prints `7`.
   - The emitted MLIR `llvm.extractvalue`s the field, stores it into a
     fresh `llvm.alloca`, and passes that pointer (see
     `repro/conv_rec_mlir_count.mlir`, lines 336 to 341).
   - `cell check` accepts the program, and stage 8 has no example that
     passes a field by `exclusive`.
   - It is the MLIR twin of the LLVM spilled-copy defect that `a6c41e8`
     fixed for bindings. Stage 4 cannot see it, because both backends
     accept the program.

## Testing

- **hir tests (checker-backed):**
  - the synthetic drop equals the lowered source form;
  - a drop is inserted at each row of section 4, and at no other point;
  - no drop for a moved binding, a binding pattern, a payload binding, a
    `shared` or `copy` binding, or an `arc` binding;
  - no drop without a checker;
  - the bodyless-parameter id skip;
  - the whole-module counter check;
  - the return hoist appears only when a drop is pending.
- **llvmemit and mlirmit tests:**
  - the text of a drop: `call void @cell_string_free(ptr %slotN)` and the
    MLIR equivalent;
  - the `exclusive` argument is the slot or field address, never a spilled
    copy;
  - one run test per backend under ASan, with the `wasMoved` mutation as a
    negative control.
- **The cfg and liveness tests** stay unchanged. One test builds a graph
  over a lowered function with drops, to show the call form needs no new
  arm.

## Risks

1. **Id drift between the Lowerer and borrowck.** This is the whole
   safety argument, as in C.
   - Positive confirmation per binding, plus the whole-module count check.
   - The bodyless-parameter test.
   - Drift can only cause a leak, and a leak moves a pin.
2. **A drop of a copy's source**, through an arm binding, a payload, an
   `owned` argument, a `return` or a record field. Handled by `droppable`
   and `wasMoved`, and falsified by mutations 2 and 3.
3. **A drop before a read** in the same expression (`return f(shared s)`)
   or in a later statement (the C after-loop defect).
   - The return hoist handles the first.
   - Not porting `after_loop` avoids the second.
   - `EXPECT-OUTPUT` is the witness, since neither ASan nor the counter
     sees a zeroed header.
4. **An `exclusive` argument lowered as a copy** frees the right buffer
   and leaves the slot dangling, so the next drop of that slot is a double
   free.
   - This is live today for MLIR field places (defect 5).
   - Pinned by the emitter text test and by the doubled-drop run test.
5. **Churn in stage 4 and 5 text.** Emission is identical when no drop is
   pending.
6. **`hir.zig` gains a `borrowck` import**, and `borrowck.zig` is 10k lines.
   Compile time and the leaf-module story both change. Stated in the module
   header.
7. **A user declaration named `string_free`.**
   - `resolveRuntime` reuses an identical one and refuses a different one.
   - A test covers each.
8. **ASan coverage overstated after step (b).** Recorded in the stage 9
   header when (b) lands.

## Commits (TDD, each opening with its failing test)

1. **`Runtime.string_free` and the synthetic-drop helper.** Includes the
   equality test against the lowered source form and the collision tests.
   No drops are inserted yet.
2. **`Binding.bc_id` and `Binding.droppable`, plus the mirrored counter.**
   - Includes positive confirmation, the bodyless-parameter skip and the
     whole-module check.
   - `lower` takes an optional checker, and `root.emitFor` passes one.
3. **Scope-end, `return` (with hoist), `break` and `continue` drops for
   owned String locals and parameters.**
   - Includes the hir and emitter tests, the ASan run test, and the
     `wasMoved` and arm-binding mutations as negative controls.
4. **Reassignment pre-drop from `assign_liveness`.**
5. **Record drops, in two commits.**
   - 5a: MLIR passes an `exclusive` field place by address. Its failing
     tests are `repro/field_exclusive_write.cell` (must print 42) and the
     doubled drop (must exit 0).
   - 5b: inlined record field drops for unmoved records.
6. **Gate changes.**
   - Measure, then move the stage 7 pins with the commit cited.
   - The new fixtures with `EXPECT-OUTPUT`.
   - Stage 9 IR legs and the corrected header.
7. **Documentation.**
   - `AGENTS.md` and `CLAUDE.md` ("neither frees" becomes the slice-1
     list).
   - The `hir.zig` header (no longer a leaf), `cfg.zig` and `liveness.zig`
     ("nothing consumes" stays true).
   - OWNERSHIP R11 and R16 rows, FEATURES, and the stage 7 comments.
8. **Separately, not in this step:** C fixes for defects 1 to 4, each with
   its fixture, so that slice 2 ports a correct `after_loop`. Defect 5 is
   in this step, as commit 5a.

**Ruled 2026-09-21 by Donald.** Q1 is moot: defect 1 was fixed in C by
`938960f`. Q2: fix discarded owned results in C now (`748df08`); the IR legs
wait for this pass. Q3: the IR drops a shadowed binding correctly, so the leak
fixture pins a count per backend (C keeps its disclosed leak). Q4: record drops
are inline per field, with no glue symbols. Q5: a narrow `DropFacts` interface
that borrowck implements; `hir.zig` does not import `borrowck.zig`. Q6 and Q7
stay open and are asked when slice 2 starts. Defects 2 to 5 are fixed or
pinned: `748df08` (C only), `673f996` (three shapes still disclosed),
`23942c8`, `7e8491f` (this document's commit 5a). Slice 1 waits for the
borrowck/codegen split, since `DropFacts` lives in borrowck. The default
`--target` flips to LLVM when every LLVM/MLIR leak pin in gate stage 7 reads 0.

## Open questions for Donald

1. **Should defect 1 be fixed in C before step (c) starts, or in
   parallel?** Slice 1 does not depend on it, and slice 2's `after_loop`
   port does.
2. **Discarded owned results.** Fix them in all three backends now, which
   is simple because a discarded temporary has exactly one owner, or pin
   them at 2000 everywhere until a temporaries slice?
3. **Shadowed bindings.** HIR can drop a shadowed outer binding correctly
   because it names slots. Allow that in slice 1, letting the IR backends
   free what C leaks, or keep C parity so the counters agree?
4. **Record drops.** Inline them per field (proposed; no new symbols), or
   generate glue functions as C does, which adds stage-10 surface?
5. **`hir.zig` importing `borrowck.zig`.** Is that acceptable? The
   alternative is a narrow fact interface (`DropFacts`, with function
   pointers or a vtable) that borrowck implements, so `hir.zig` stays
   free of the 10k-line import.
6. **Stage 9 on IR legs.** Adopt the runtime-and-host-only ASan witness now
   with its stated limit, or wait for an instrumented-IR answer before
   step (b)?
7. **Slice 2's order:** revival and branch-end releases first, or
   value-block and `return`-in-loop first?
