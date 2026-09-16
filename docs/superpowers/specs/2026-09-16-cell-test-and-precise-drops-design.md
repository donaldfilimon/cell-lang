# `cell test`, and precise drops for R16's residuals

Design, approved 2026-09-16 (Donald, via `/superpowers:brainstorming` under
the compiler goal). Two sub-projects, independent of each other, both after
the prelude (`2026-09-16-optional-result-and-prelude-design.md`, section A)
lands:

- **C.** A `cell test` command that runs a directory of Cell programs.
- **D.** Release at the four exits that still leak by design in
  `docs/OWNERSHIP.md` R16, by extending borrowck's per-exit liveness rather
  than by runtime drop flags or a CFG-based drop pass.

Decisions recorded here were Donald's and are not open: discovery is a
`tests/` directory of programs (not `test_*` functions, not a `test`
keyword); D reaches CFG precision for the named residuals without re-seating
the C backend on the HIR and without consuming `cfg.zig`/`liveness.zig`.

## C. `cell test`

### C.1 Contract

```
cell test [dir]          # default: tests/
```

For every `*.cell` (and `*.cel`) file directly inside `dir`, sorted by
name, `cell test` runs the program through the same recipe `cell run` uses
(`src/main.zig`: check, emit C, stage beside the embedded runtime under
`$TMPDIR`, `$CC`, execute). A file `<stem>_host.c` beside a program is that
program's hand-written host and is passed exactly as `cell run` passes a
`.c` positional. Body files (`.body`/`.bod`) are not run on their own; they
are reached through their stem-mate the way `cell run` reaches them.

Verdict per program:

- The program passes when its exit status is 0 and, if its source carries a
  line `// EXPECT-OUTPUT: <text>` (the corpus convention `tools/check.sh`
  stage 8 already reads), its stdout equals `<text>` followed by a single
  newline.
- A program that fails `cell check`, fails `cc`, exits nonzero, dies by
  signal, or prints something other than its expectation fails. The reason
  is printed as `cell run` would print it.

Output, one line per program, in order, then one summary line:

```
ok    add.cell
ok    strings.cell (output matched)
FAIL  overflow.cell (exit 134: program terminated by signal SIGABRT)
2 passed, 1 failed
```

The command exits 0 when every program passed, 1 when any failed, and 2
when `dir` does not exist or holds no program: an empty suite must never
read as green. Every program runs even after a failure. A `--target=` or
`-o` argument is refused (`test` compiles the C target only, like `build`).

### C.2 Implementation

`src/main.zig` only:

- `Command` gains `test`; the usage text gains the command; the existing
  test that checks the usage text against the enum's reflected field names
  keeps them matched. `parseCommand("test")` stops returning null (the test
  that asserts it does is inverted).
- The staging-and-running body that `build`/`run` share is factored into
  `fn runProgram(init, arena, io, cwd, path, hosts, err_w) !RunOutcome`
  returning `{ status: u8, stdout: []const u8 }` where the child is spawned
  with a piped stdout (the `run` command keeps inheriting stdio, so
  `runProgram` takes a `capture_stdout: bool`).
- `fn testDir(...)` lists the directory (`cwd.openDir(io, dir).iterate()`
  in this Zig's `std.Io` API; read `load.zig` for the directory calls the
  loader already uses), sorts names, pairs hosts, calls `runProgram` per
  file, reads `EXPECT-OUTPUT` with the same line scan stage 8's shell uses
  (`grep -m1 '^// EXPECT-OUTPUT:'` becomes a `std.mem` scan of the source),
  prints the lines above, and returns the exit code.

### C.3 Evidence

- Unit tests in `src/main.zig`: `parseCommand("test")`; argument shapes
  (`cell test`, `cell test dir`, `cell test dir extra` refused,
  `cell test --target=llvm` refused); the expectation scan (`EXPECT-OUTPUT`
  present, absent, malformed) as a pure function over source text; the
  report line formatting as a pure function.
- A `tests/` directory in this repository with three programs: one that
  prints and pins its output, one with a `_host.c`, one that only exits 0.
- Gate stage 14, `cli test`: runs `cell test tests/` and expects exit 0 with
  `3 passed, 0 failed`; then copies the three programs plus a fourth that
  `assert(false)`s into `$TMP/tests-red/` and expects exit 1 with
  `3 passed, 1 failed` and a `FAIL` line naming it; then runs against an
  empty directory and expects exit 2. Falsified before trusted, the way
  stage 12 was.
- `docs/FEATURES.md` CLI-02: `test` moves from absent to `checked`;
  `README.md` Status: "There is no `cell test`" becomes history; `CLAUDE.md`
  and `AGENTS.md` command lists gain the command.

## D. Precise drops for R16's residuals

### D.1 What leaks today and why

`docs/OWNERSHIP.md` R16 and `codegen.zig`'s module comment name four shapes
that still leak after the 2026-09-16 `exit_liveness` work:

1. a var moved on one branch of an `if`/`match` and not on the other: the
   merge records it dead, so the path that kept the value never releases it;
2. a `break`/`continue`: no exit is recorded at a jump, so
   `emitLoopExitDrops` releases only never-moved locals;
3. a value-position block's tail: `emitValueBlockDrops` skips every local
   the tail can reach and has no liveness for the rest;
4. a revived record: `moved_paths` is permanent, so a record reassigned
   whole after a move is never released.

All four are "the walk did not record this exit", not "the walk cannot
know". borrowck walks every path (`checkIf`/`checkMatch` start each branch
from the entry state), so it can record liveness at each of these points
with the same `ExitLiveness` entries it records at block ends and returns.

### D.2 Rules

`Checker.exit_liveness` gains three `ExitKind`s and one refinement:

- **`branch_end`**, keyed by the address of the branch body's statement
  slice (an `if` branch, an `else` branch, a `match` arm body), recorded
  after the branch is walked and BEFORE the merge. codegen's branch emitters
  (`emitIfStmt`, `emitMatch`'s `emitArmBody`) ask, at the end of each
  branch, for every binding declared OUTSIDE the branch and visible: release
  it here when `liveAtExit(.branch_end, key)` is true AND the binding is not
  live after the merge (`liveAtExit` at the enclosing block's end, or at the
  next recorded exit on this path, is false). The second condition is what
  keeps a value that survives the merge from being released early; the
  first is what closes residual 1. A binding both branches move, or neither
  moves, changes nothing.
- **`jump`**, keyed by the `break`/`continue` statement's address, recorded
  when the jump is checked. `emitLoopExitDrops` receives the key and applies
  the same admission as a block end: a moved binding is released only where
  this says live. The existing loop guards stand (`loop_moved`, and the
  in-loop invalidation), so an outer binding moved anywhere in the loop is
  still never live at a jump; what closes is a binding declared INSIDE the
  loop body, revived before the jump.
- **`value_block_end`**, keyed by the block's statement slice, recorded after
  the tail expression is checked. `emitValueBlockDrops` already computes
  which locals the tail can reach; for the rest it now admits a moved local
  when `liveAtExit(.value_block_end, key)` says live, releasing it after the
  tail has been emitted into its destination (the temporary the statement
  expression already uses).
- **Records at every exit kind:** a record binding is admitted for a whole
  release at an exit when it was reassigned whole after its last move and no
  field path of it is dead on this path (`findDead` over the binding and
  every recorded field path). `recordExit` computes that per binding from
  `dead`, which is per path, rather than from `moved_paths`, which is
  permanent. A record with a field moved AFTER the revival keeps today's
  behaviour (partial glue from `moved_paths`), and per-field revival is out
  of scope.

Every admission is asymmetric the way the existing ones are: a missing or
false record keeps the leak; only a recorded `live = true` releases. Nothing
here can turn a leak into a double free without borrowck having walked the
path and said so.

### D.3 Codegen

- `Exit` gains the new kinds; `blockExit`-style helpers key each site.
- `emitIfStmt` and `emitArmBody` call a new `emitBranchEndDrops(key,
  indent)` before their closing brace; it iterates the visible locals
  declared outside the branch (locals below the branch's `mark`) and applies
  D.2's two-condition rule through `checker.liveAtExit`. Locals declared
  inside the branch are already released by the block-scoped rule.
- `emitLoopExitDrops(indent)` becomes `emitLoopExitDrops(key, indent)`.
- `emitValueBlockDrops` takes the `value_block_end` key.
- The record admission moves from `wasWhollyMoved` to a per-exit query,
  `checker.recordLiveAtExit(kind, key, binding)`.

### D.4 Evidence

- Four new fixtures under `examples/leaks/`, one per residual
  (`branch_move.cell`, `loop_jump_revival.cell`, `value_block_revival.cell`,
  `revived_record.cell`), each looping 1000 times, measured BEFORE the change
  with the leaks host and the malloc counter (the number is the residual's
  size, recorded in the fixture header and the gate comment), then AFTER,
  pinned at 0 with both witnesses, ASan clean.
- borrowck tests per exit kind (the recorded liveness for each shape, and
  the shapes that must stay unreleased: a binding both branches move, an
  outer binding moved in a loop, a tail-reachable local, a record with a
  post-revival field move).
- codegen tests pinning the emitted release position for each exit kind and
  `expectCompiles`; the four "must stay unreleased" shapes pinned with
  `expectAbsent`.
- `docs/OWNERSHIP.md` R16's "what still leaks, by design" list shrinks to
  the per-field record case; `codegen.zig`'s module comment and
  `docs/SPEC.md`'s drop-insertion row updated; the sweep re-run.

## Out of scope, stated

- Per-field revival state for records (a field moved, then the field
  reassigned): stays a disclosed leak.
- Consuming `cfg.zig`/`liveness.zig`, and the HIR re-seat of the C backend:
  Donald chose not to; the scaffolding stays, its headers already say it is
  unconsumed.
- Runtime drop flags: rejected in favour of static per-exit decisions.
- `cell test` running tests in parallel, filtering by name, or timing: not
  asked for.
