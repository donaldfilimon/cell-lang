# `examples/leaks/`

Five fixtures, one per measurable gap in `docs/OWNERSHIP.md` R11's "Still
broken" table. Each isolates exactly one disclosed `arc` retain/release gap
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
| `param_never_released.cell` | 1: a Cell body never releases its own `arc` parameter |
| `struct_arc_field.cell` | 2: a struct holding an `arc` field is never dropped |
| `unbound_shared_temp.cell` | 3: an unbound `arc` temporary unboxed for a `shared` parameter |
| `block_scoped_local.cell` | 4: a block-scoped `arc` local is never released |
| `reassigned_var.cell` | 5: reassigning an `arc` `var` leaks the previous box |

R11's sixth disclosed gap (an `owned` String or list place bound as `arc`) is
not a runtime leak at all: it is refused as a C type error at compile time, so
there is nothing for `leaks` to measure and no fixture for it here.

Run them all, with the pinned expected counts, via `tools/check.sh`'s `leaks`
stage. That stage SKIPS loudly (not silently) when the macOS `leaks` tool is
unavailable.
