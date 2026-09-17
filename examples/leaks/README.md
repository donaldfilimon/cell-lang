# `examples/leaks/`

Eighteen fixtures: R11's measurable gaps and their CLOSED pins (seven,
including the value-block residual and the `owned` twin of row 5); R16's
revival leak (`revived_var.cell`, closed 2026-09-16) and eight closed
residuals (`branch_move`, `loop_jump_revival`, `value_block_revival`,
`revived_record`, `loop_cross`, `partial_nested_field`, `branch_field`, `field_revival`); the partial-move pin; and one regression pin for an
implemented feature (`arc_box_move.cell`, below). Each isolates exactly one
disclosed retain/release shape and loops it 1000 times so a leak is a
stable count, not noise.

**These programs assert leaks that currently exist.** That is deliberate:
pinning the count in `tools/check.sh` is what makes a later fix to one of
R11's gaps *visible* (the pinned number drops) instead of silent, and what
makes a regression that makes one worse, or opens a new one, *fail the gate*
instead of shipping quietly. A file here that starts "failing" because its
count moved is reporting real information about codegen; the fix is in
`src/`, or in updating the pinned constant plus `docs/OWNERSHIP.md`'s row
when a gap has genuinely closed, never in loosening the check.

This is a **separate directory**, not more files under `examples/*.cell`,
specifically so these fixtures are invisible to the top-level corpus,
backend-agreement, and MLIR-lowering loops in `tools/check.sh` and
`examples/README.md`: they exist to be measured by `leaks`, not to declare a
`cell check` or backend-agreement contract of their own (though every one of
them does pass `cell check`, and LLVM/MLIR refuse all of them outright, the
same as `examples/arc.cell`, since none lowers a scalar-only program).

| Fixture | R11 row |
|---|---|
| `param_never_released.cell` | 1: a Cell body never released its own `arc` parameter; **CLOSED 2026-09-16** by admitting `owned` and `arc` parameters to the drop pass, kept and pinned at 0 |
| `struct_arc_field.cell` | 2: a struct holding an `arc` field was never dropped. CLOSED 2026-09-15 by per-struct drop glue, pinned at 0 |
| `unbound_shared_temp.cell` | 3: an unbound `arc` temporary unboxed for a `shared` parameter |
| `block_scoped_local.cell` | 4: a block-scoped `arc` local is never released; **CLOSED 2026-09-15**, kept and pinned at 0 |
| `reassigned_var.cell` | 5: reassigning an `arc` `var` leaked the previous box; **CLOSED 2026-09-15** by the reassignment pre-drop in `emitAssign`, kept and pinned at 0 |
| `reassigned_owned_var.cell` | not an R11 row: row 5's `owned` twin. Reassigning an `owned` String or list var leaked the old value (4000 before on both witnesses, including two stores whose var is moved only afterwards); **CLOSED 2026-09-16** by extending `emitAssign`'s pre-drop, decided per store from borrowck's `assign_liveness`, pinned at 0. A store whose target was already moved (R3a revival), or that sits in a `while` body moving it, keeps its leak by design and is not measured here |
| `owned_string_optional.cell` | owning `String?` (sub-project 4, 2026-09-17): every shape of `optional_string.cell` plus untaken temporaries and a reassignment, 1000 times; 0 on both witnesses (8000 allocations), ASan clean by hand; the release measured 5000 when emptied |
| `owned_string_err.cell` | owning `String` in `Err` and in both sides (sub-project 3, 2026-09-17): every shape of `results_err_string.cell` plus untaken temporaries, 1000 times; 0 on both witnesses (8000 allocations), ASan clean by hand; the `Err` release measured 4000 when emptied |
| `owned_string_result.cell` | owning `String` in `Ok` (2026-09-17): every shape of `results_string.cell`, 1000 times; 0 on both witnesses (8798 allocations), ASan clean by hand; the temporary-scrutinee release measured 2000 when removed |
| `owned_scalar_wrappers.cell` | not an R11 row: owned scalar `Result<T, E>` and `T?` values built, passed `owned`, returned, reassigned and dropped 1000 times. They hold no heap memory (scalar `T` and `E`), so the count is 0 on both witnesses; **pinned at 0 2026-09-17** so a future resource-bearing payload surfaces here instead of leaking silently |
| `revived_var.cell` | not an R11 row: OWNERSHIP.md R16's revival leak. A var moved and then revived (R3a) was never released at scope end (5000 before on both witnesses, one per drop point: body end, `return`, nested block end, `owned` parameter, list); **CLOSED 2026-09-16** by borrowck's per-exit liveness (`exit_liveness`), pinned at 0 |
| `value_block_local.cell` | the residual of row 4's closure: an `arc` local declared in a VALUE-position block was not released at that block's exit (measurable since 2026-09-15, when a block began to type as its tail); **CLOSED 2026-09-15** the same evening by `emitValueBlockDrops`, kept and pinned at 0 |
| `arc_box_move.cell` | not a gap: R10 move-into-`arc` at `let`, at a direct `-> arc` return, by assignment into a whole `var arc`, as an argument to an `arc` parameter and into a struct literal's `arc` field, all IMPLEMENTED 2026-09-16; pinned at 0 as a regression guard (a drift between borrowck's move and codegen's box is a double free or a leak). A move on one branch only leaks by design and is not measured |
| `partial_move_field.cell` | not a numbered row: a record with one owning field moved out was skipped whole, leaking its other owning field; **CLOSED 2026-09-16** by field-path move records in borrowck and `emitPartialRecordDrop` in codegen, kept and pinned at 0 |
| `partial_nested_field.cell` | R16 residual: a nested field whose sibling was moved (`p.inner.a` moved, `p.inner.b` leaked because the whole `inner` field was skipped); **CLOSED 2026-09-16** by recursing `emitPartialRecordDrop`, 1000 -> 0 |
| `branch_move.cell` | R16 residual 1: a var moved on one branch; **CLOSED 2026-09-16** by branch-end releases, 501 -> 0 |
| `loop_jump_revival.cell` | R16 residual 2: a revived loop-local at continue; **CLOSED 2026-09-16** by jump releases, 1000 -> 0 |
| `value_block_revival.cell` | R16 residual 3: a revived var in a value block; **CLOSED 2026-09-16** by value-block-end releases, 1000 -> 0 |
| `revived_record.cell` | R16 residual 4: a record revived after a whole move; **CLOSED 2026-09-16** by record-revival admission, 1000 -> 0 |
| `loop_cross.cell` | R16 residual: a var moved inside a `while` it was declared outside of; **CLOSED 2026-09-16** by after_loop releases, 1000 -> 0 |
| `branch_field.cell` | R16 residual 1 at field granularity: a field moved on only one branch of an `if` leaked on the other; **CLOSED 2026-09-16** by branch-end field releases (live here, dead after the merge), 1000 -> 0 |
| `field_revival.cell` | R16 residual: a field revived after it was moved leaked the new value; **CLOSED 2026-09-16** by retracting the revived path from `fieldWasMoved`, 1000 -> 0 |

## IR backend pins

The LLVM and MLIR backends have no drop pass, so every owned `String` they
build is never freed. These rows are measured with ONE witness, the malloc
counter, because an IR object cannot take `leak_host.c`'s renamed `main`; each
also has a C row on both witnesses. A drop in an IR pin means an IR drop pass
landed.

| Fixture | What it pins |
|---|---|
| `ir_owned_string.cell` | owned Strings the IR backends accepted before any conversion existed: C 0, LLVM and MLIR 3000 (2026-09-17) |
| `ir_string_conversion.cell` | the eight borrowed-view to owned-`String` positions of `examples/owned_string.cell`, which the IR backends convert through `cell_string_from_str` since IR String step (a): nine allocations per call, C 0, LLVM and MLIR 9000 (2026-09-17) |

`tools/check.sh` also measures `examples/owned_string.cell` itself with its
host in this stage: C 0, LLVM and MLIR 8 (nine allocations, one freed by the
host's `take`).

R11's sixth disclosed gap (an `owned` String or list place bound as `arc`) was
never a runtime leak: it was a C type error, then a borrowck refusal, and since
2026-09-16 it is implemented at `let`, at a direct `-> arc T` return, by
assignment into a whole `var arc`, as an argument to an `arc` parameter and
into a struct literal's `arc` field, for a whole binding. It has no gap
fixture, because there was never a leak to pin, but all five implemented
positions are pinned at 0 by `arc_box_move.cell`: the
move is correct only while borrowck records the source as moved and codegen
boxes it and skips its drop, and a drift on either side shows up there.

Run them all, with the pinned expected counts, via `tools/check.sh`'s `leaks`
stage. That stage SKIPS loudly (not silently) when the macOS `leaks` tool is
unavailable.

Three `.c` files sit beside the fixtures and are part of how they are
measured, not fixtures themselves. `leak_host.c` is the real `main` for every
fixture: the emitted C is compiled with `-Dmain=cell_program_main`, and the
host runs it and then overwrites the stack before returning, because
`leaks -atExit` is a conservative scanner and used to find the last
iteration's three boxes through a stale stack slot, reporting 2997 for a
program that leaks 3000. `malloc_counter.h` and `malloc_counter.c` are the
independent witness: `-include`d into the emitted C and the runtime (never
into `malloc_counter.c` itself), they count every block obtained and never
freed and print `MALLOC_COUNTER ALLOC= FREE= LIVE=` to stderr at exit. The
stage requires the `leaks` count and LIVE to both equal the pin, so a pin can
never again move on one witness. The trap note on the leaks stage in
`tools/check.sh` carries the measurements that proved the under-count.
