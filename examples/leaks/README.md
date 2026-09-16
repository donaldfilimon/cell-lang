# `examples/leaks/`

Seven fixtures, one per measurable gap in `docs/OWNERSHIP.md` R11's "Still
broken" table and its CLOSED paragraphs (five until 2026-09-15, six until
2026-09-16; six of the seven are closed and pinned at 0). Each isolates exactly one disclosed `arc` retain/release gap
and loops it 1000 times so a leak is a stable count, not noise.

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
| `value_block_local.cell` | the residual of row 4's closure: an `arc` local declared in a VALUE-position block was not released at that block's exit (measurable since 2026-09-15, when a block began to type as its tail); **CLOSED 2026-09-15** the same evening by `emitValueBlockDrops`, kept and pinned at 0 |
| `partial_move_field.cell` | not a numbered row: a record with one owning field moved out was skipped whole, leaking its other owning field; **CLOSED 2026-09-16** by field-path move records in borrowck and `emitPartialRecordDrop` in codegen, kept and pinned at 0. A field moved on only one branch still leaks by design and is not measured here |

R11's sixth disclosed gap (an `owned` String or list place bound as `arc`) was
never a runtime leak: it was a C type error, then a borrowck refusal, and since
2026-09-16 it is implemented at `let` for a whole binding, measured at 0 with
both witnesses outside the gate. There is no fixture for it here.

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
