# Precise drops for R16's residuals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Release a value on the path that kept it when a sibling path moved it, at `break`/`continue`, at a value block's end, and for a record revived after a move, so `docs/OWNERSHIP.md` R16's "still leaks, by design" list shrinks to the per-field record case.

**Architecture:** borrowck already records per-exit liveness (`Checker.exit_liveness`, `ExitKind.block_end`/`return_stmt`) and codegen releases a moved var only where `liveAtExit` says live. This plan adds three exit kinds (`branch_end`, `jump`, `value_block_end`) recorded by the same walk, a per-exit record admission computed from the per-path `dead` list instead of the permanent `moved_paths`, and the codegen drop points that consume them. Every admission stays asymmetric: no record or a false record keeps the leak.

**Tech Stack:** Zig master, the leaks host and malloc counter under `examples/leaks/`, AddressSanitizer through `cc`, `tools/check.sh`.

**Spec:** `docs/superpowers/specs/2026-09-16-cell-test-and-precise-drops-design.md`, section D. Independent of plans B, A and C in code; scheduled after them.

## Global Constraints

- Every `zig` command takes `-Dswift=false`; capture exit codes directly; confirm named tests in `zig test` output.
- No em dashes. Zig idioms as found.
- **Measure before pinning.** Every fixture's count is measured with the gate's own recipe (emit; `cc -fsanitize=address -include examples/leaks/malloc_counter.h -Dmain=cell_program_main -c` the program; link `examples/leaks/leak_host.c` and `malloc_counter.c` compiled WITHOUT the `-include`; run; read `MALLOC_COUNTER ... LIVE=`) before and after the change, and the before number goes into the fixture header and the gate comment.
- **Asymmetry is law.** A release is emitted only where borrowck recorded `live = true` at that exact exit key. Removing any guard must be measured as an AddressSanitizer failure before the guard is kept; a guard that cannot be falsified is not evidence.
- The existing loop guards (`loop_moved`, the in-loop invalidation in `checkWhile`) are not weakened.
- Work on `main`; commit after each task; gate `verdict: clean` at the end of Task 5; `tools/sweep-backends.sh` re-run.

---

### Task 1: Fixtures that measure the four residuals

**Files:**
- Create: `examples/leaks/branch_move.cell`, `examples/leaks/loop_jump_revival.cell`, `examples/leaks/value_block_revival.cell`, `examples/leaks/revived_record.cell`
- Modify: `examples/leaks/README.md` (four rows), `tools/check.sh` (four pinned constants at the measured BEFORE values, four `run_c_leaks` rows)

**Interfaces:**
- Produces: `LEAK_BRANCH_MOVE`, `LEAK_LOOP_JUMP_REVIVAL`, `LEAK_VALUE_BLOCK_REVIVAL`, `LEAK_REVIVED_RECORD` in `tools/check.sh`, each set to the measured before-count so the gate stays green until the fix moves them.

- [ ] **Step 1: Write the four programs**

`examples/leaks/branch_move.cell`:

```cell
// R16 residual 1: a var moved on one branch leaks on the other. `take(v)`
// runs when c > 0; when it does not, v is still owned at the merge, but the
// merge records it dead (a branch move is recorded as a move), so the scope
// end never releases it. Half the calls take the moving branch.
//
// BEFORE (measured, see the gate constant): one String per non-moving call.
// AFTER: 0, released at the end of the branch that kept it.
//
// Status: parses, passes `cell check`; C only; lives under examples/leaks/.

pub fn print_int(copy value: Int);

pub fn take(owned s: String) {
}

pub fn one_branch(copy c: Int) {
    var owned v: String = "branch"
    if c > 0 {
        take(v)
    }
}

pub fn main() {
    var i = 0
    while i < 1000 {
        one_branch(i - 500)
        i = i + 1
    }
    print_int(i)
}
```

`examples/leaks/loop_jump_revival.cell`:

```cell
// R16 residual 2: a var declared inside a loop body, moved and then revived
// before a `continue`, leaks at the jump: no exit is recorded there, so
// `emitLoopExitDrops` releases only never-moved locals.
//
// BEFORE (measured): one String per iteration that takes the continue.
// AFTER: 0.

pub fn print_int(copy value: Int);

pub fn take(owned s: String) {
}

pub fn body(copy n: Int) {
    var i = 0
    while i < n {
        i = i + 1
        var owned v: String = "a"
        take(v)
        v = "b"
        if i > 0 {
            continue
        }
    }
}

pub fn main() {
    var i = 0
    while i < 100 {
        body(10)
        i = i + 1
    }
    print_int(i)
}
```

`examples/leaks/value_block_revival.cell`:

```cell
// R16 residual 3: a var revived inside a VALUE-position block is not
// released at the block's end, because that exit is not recorded and
// `emitValueBlockDrops` only skips what the tail can reach.
//
// BEFORE (measured): one String per call.  AFTER: 0.

pub fn print_int(copy value: Int);

pub fn take(owned s: String) {
}

pub fn in_value_block() -> Int {
    let copy n = {
        var owned v: String = "a"
        take(v)
        v = "b"
        3
    }
    return n
}

pub fn main() {
    var i = 0
    while i < 1000 {
        let copy r = in_value_block()
        i = i + 1
    }
    print_int(i)
}
```

`examples/leaks/revived_record.cell`:

```cell
// R16 residual 4: a record moved whole and then reassigned whole is never
// released, because the scope-end admission reads `moved_paths`, which is
// permanent.
//
// BEFORE (measured): the record's owning field per call.  AFTER: 0.

pub struct Box {
    owned s: String
}

pub fn print_int(copy value: Int);

pub fn take(owned b: Box) {
}

pub fn revive_record() {
    var owned b = Box { s: "one" }
    take(b)
    b = Box { s: "two" }
}

pub fn main() {
    var i = 0
    while i < 1000 {
        revive_record()
        i = i + 1
    }
    print_int(i)
}
```

- [ ] **Step 2: Measure each BEFORE**

For each fixture, after `zig build -Dswift=false`:

```sh
T=/private/tmp/leakprobe; mkdir -p $T
./zig-out/bin/cell check examples/leaks/<name>.cell || echo "REFUSED"
./zig-out/bin/cell emit examples/leaks/<name>.cell > $T/p.c
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address -g -I runtime -include examples/leaks/malloc_counter.h -Dmain=cell_program_main -c $T/p.c -o $T/p.o
cc -std=c11 -fsanitize=address -g -I runtime -include examples/leaks/malloc_counter.h -c runtime/cell_rt.c -o $T/rt.o
cc -std=c11 -fsanitize=address -g -I runtime -include examples/leaks/malloc_counter.h -c examples/leaks/leak_host.c -o $T/host.o
cc -std=c11 -fsanitize=address -g -c examples/leaks/malloc_counter.c -o $T/mc.o
cc -fsanitize=address $T/p.o $T/rt.o $T/host.o $T/mc.o -o $T/p && $T/p; echo "EXIT: $?"
```

Record the `LIVE=` figure per fixture. If `cell check` REFUSES a fixture (a shape borrowck rejects today, for example a move of a loop-outer binding), rewrite the fixture to the accepted shape that still exhibits the leak and say so in its header; a fixture must pass `cell check`. If one measures 0 already, the residual is not what the spec says it is: stop, record the measurement in the report, and report DONE_WITH_CONCERNS.

- [ ] **Step 3: Pin the BEFORE values and wire the rows**

In `tools/check.sh`, beside the other `LEAK_*` constants, one comment block per fixture stating the shape, the before number and its date, then the constant at that number. Add four `run_c_leaks <name> "" "$LEAK_<NAME>" "R16 residual N, measured YYYY-MM-DD, OPEN"` rows. Add four rows to `examples/leaks/README.md`'s table. Run the gate's leaks stage alone if the script exposes it, else the whole gate: `tools/check.sh > /private/tmp/gate.log 2>&1; echo "EXIT: $?"` must be clean (the fixtures assert the leaks that exist, on purpose).

- [ ] **Step 4: Commit**

```bash
git add examples/leaks/ tools/check.sh
git commit -m "leaks: four fixtures pin R16's remaining residuals at their measured sizes"
```

---

### Task 2: borrowck records branch ends and jumps

**Files:**
- Modify: `src/cell/borrowck.zig` (`ExitKind`, `checkIf`, `checkMatch`, `checkStmtKind`'s jump arm, `checkBlockStmts`, tests)

**Interfaces:**
- Produces: `ExitKind.branch_end` (key: the branch body's statement slice pointer, or the branch expression's address when the branch is not a block), `ExitKind.jump` (key: the `break`/`continue` statement's address), `ExitKind.value_block_end` (key: the block's statement slice pointer; recorded by `openBlockTail`'s consumers after the tail is checked). All through the existing `recordExit(kind, key)`.

- [ ] **Step 1: Failing tests**

```zig
test "branch ends record liveness before the merge" {
    // Uses the checker directly: check the program, then ask liveAtExit
    // with the keys codegen would use. `checkSource` (or the file's helper
    // that returns the Checker) gives access to `exit_liveness`.
    var c = try checkForTest(
        \\pub fn take(owned s: String);
        \\pub fn f(copy c: Int) {
        \\    var owned v: String = "a"
        \\    if c > 0 {
        \\        take(v)
        \\    } else {
        \\        c = c + 1
        \\    }
        \\}
    );
    defer c.deinit();
    const v = c.bindingIdOf("v").?;
    const if_expr = c.firstIf("f");
    // then-branch: moved, dead; else-branch: live; block end after merge: dead.
    try std.testing.expect(!c.checker.liveAtExit(.branch_end, branchKey(if_expr.then_body), v));
    try std.testing.expect(c.checker.liveAtExit(.branch_end, branchKey(if_expr.else_body.?), v));
    try std.testing.expect(!c.checker.liveAtExit(.block_end, blockKey("f"), v));
}

test "a jump records liveness at the jump" {
    var c = try checkForTest(
        \\pub fn take(owned s: String);
        \\pub fn f(copy n: Int) {
        \\    var i = 0
        \\    while i < n {
        \\        i = i + 1
        \\        var owned v: String = "a"
        \\        take(v)
        \\        v = "b"
        \\        if i > 0 {
        \\            continue
        \\        }
        \\    }
        \\}
    );
    defer c.deinit();
    const v = c.bindingIdOf("v").?;
    try std.testing.expect(c.checker.liveAtExit(.jump, c.firstJumpKey("f"), v));
}
```

`checkForTest`, `bindingIdOf`, `firstIf`, `firstJumpKey`, `branchKey`, `blockKey` do not exist yet: this task adds them as test-only helpers at the bottom of `borrowck.zig`, built on whatever the existing tests use to run the checker (read `expectAccepted`'s body near line 4987 for how a Checker is created and run; the helper returns that Checker plus the parsed module so the AST node addresses can be recovered by walking `module.items`). Keys: `branchKey(e)` is `@intFromPtr(e.kind.block.ptr)` for a block branch, else `@intFromPtr(e)`; `blockKey(fn_name)` is the function body slice pointer; `firstJumpKey` is the address of the first `break`/`continue` statement found by walking the function.

- [ ] **Step 2: Run to see them fail** (`zig test src/cell/borrowck.zig --test-filter "record liveness" 2>&1 | tail -5`).

- [ ] **Step 3: Implement**

`ExitKind` gains:

```zig
    /// The end of one `if` branch or `match` arm body, keyed like a
    /// block end (the body's statement slice) or, for a non-block branch,
    /// by the branch expression's address. Recorded BEFORE the merge.
    branch_end,
    /// A `break` or `continue`, keyed by the statement's address.
    jump,
    /// The end of a value-position block, keyed by its statement slice,
    /// recorded after the tail is checked.
    value_block_end,
```

`checkIf`: after `try self.checkExpr(i.then_body);` add `try self.recordExit(.branch_end, branchKeyOf(i.then_body));`; after the else `checkExpr` add the same for `else_body`. `checkMatch`: after `try self.checkExpr(arm.body);` (inside the arm loop, before `popScope`) add `try self.recordExit(.branch_end, branchKeyOf(arm.body));`. Helper:

```zig
/// The key codegen uses for a branch body: the block's statement slice
/// when the branch is a block, else the expression itself.
fn branchKeyOf(e: *const ast.Expr) usize {
    return switch (e.kind) {
        .block => |stmts| if (stmts.len > 0) @intFromPtr(stmts.ptr) else @intFromPtr(e),
        else => @intFromPtr(e),
    };
}
```

Note `checkBlockStmts` already records `.block_end` for a non-empty block, so a block branch gets two records with the same key and different kinds; that is intended, codegen asks for `.branch_end`.

Jump: in `checkStmtKind`, `.break_stmt, .continue_stmt => try self.recordExit(.jump, @intFromPtr(stmt)),` (the `stmt` pointer is the one `checkStmt` passes in; confirm the parameter name).

Value block: find where `openBlockTail` consumers check the tail (the `let`, assignment, return, call-argument and field sites); after the tail expression is checked and BEFORE `closeBlockTail`, record `.value_block_end` keyed by `@intFromPtr(stmts.ptr)` of the opened block. The cleanest single point is inside `closeBlockTail` if it still has the block in hand; if it does not, add the record at each site that calls it (read `openBlockTail`/`closeBlockTail` at ~line 1314 first and choose the one place through which every value block passes; write down which in the report).

`recordExit` needs no change: it records every visible binding's liveness from `dead` and `loop_moved`.

- [ ] **Step 4: Run** the two tests, then `zig test src/cell/borrowck.zig 2>&1 | tail -2` (all green), then `zig build test -Dswift=false > /private/tmp/t.log 2>&1; echo "EXIT: $?"` (codegen tests must still pass: nothing consumes the new kinds yet).

- [ ] **Step 5: Commit**

```bash
git add src/cell/borrowck.zig
git commit -m "borrowck: record liveness at branch ends, jumps and value-block ends"
```

---

### Task 3: codegen releases at branch ends and jumps

**Files:**
- Modify: `src/cell/codegen.zig` (`Exit`, `emitBranchStmt`/`emitIfStmt`, `emitArmBody`, `emitLoopExitDrops` and its two callers, tests)

**Interfaces:**
- Consumes: `ExitKind.branch_end`, `.jump`; `checker.liveAtExit`.
- Produces: `fn emitBranchEndDrops(self, branch: *const ast.Expr, mark: usize, next_exit: Exit, indent) EmitError!void`; `emitLoopExitDrops(self, key: Exit, indent)`.

- [ ] **Step 1: Failing tests**

```zig
test "a var moved on one branch is released at the end of the other" {
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn f(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    take(v)
        \\  } else {
        \\    c = c + 1
        \\  }
        \\}
        \\pub fn g(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    take(v)
        \\  }
        \\}
        \\pub fn both(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    take(v)
        \\  } else {
        \\    take(v)
        \\  }
        \\}
        \\pub fn neither(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    c = c + 1
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    // Exactly one release, inside the else branch, none at scope end.
    try expectOccurrences(f, "cell_string_free(&v);", 1);
    try expectLineBefore(f, "cell_string_free(&v);", "c = c + 1;");
    // g has no else: the release is emitted in a synthesized else.
    const g = try fnDef(e.text, "g");
    try expectOccurrences(g, "cell_string_free(&v);", 1);
    try expectContains(g, "} else {\n    cell_string_free(&v);\n  }");
    const both = try fnDef(e.text, "both");
    try expectAbsent(both, "cell_string_free(&v);");
    // neither: unchanged, one scope-end release.
    const neither = try fnDef(e.text, "neither");
    try expectOccurrences(neither, "cell_string_free(&v);", 1);
    try expectLineBefore(neither, "cell_string_free(&v);", "}");
    try expectCompiles(e.text);
}

test "a revived loop-local is released at a continue" {
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn f(copy n: Int) {
        \\  var i = 0
        \\  while i < n {
        \\    i = i + 1
        \\    var owned v: String = "a"
        \\    take(v)
        \\    v = "b"
        \\    if i > 0 {
        \\      continue
        \\    }
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    // One at the continue, one at the body end: two, and the continue's
    // comes first.
    try expectOccurrences(f, "cell_string_free(&v);", 2);
    try expectBefore(f, "cell_string_free(&v);\n      continue;", "cell_string_free(&v);\n  }");
    try expectCompiles(e.text);
}
```

(`expectBefore` exists at ~line 3929; read its contract.) Indentation in the needles follows the emitter's two-space scheme; if the first run shows different whitespace, read the emitted text and correct the needle, not the emitter.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

`Exit`'s `kind` is `borrowck.ExitKind`, so the new kinds are already representable. Branch-end drops:

```zig
    /// D.2's two-condition rule at the end of one branch: a local declared
    /// OUTSIDE the branch (index below `mark`) that borrowck recorded live
    /// at this branch's end AND not live at `after` (the exit that follows
    /// the merge on this path) is released here, because no later point
    /// will. Both conditions read recorded entries; a missing record on
    /// either side keeps the leak.
    fn emitBranchEndDrops(self: *Generator, branch: *const ast.Expr, mark: usize, after: Exit, indent: usize) EmitError!void {
        const checker = self.checker orelse return;
        const here: Exit = .{ .kind = .branch_end, .key = branchKey(branch) };
        var i = mark;
        while (i > 0) {
            i -= 1;
            const local = self.locals.items[i];
            if (!local.droppable) continue;
            if (local.ownership != .owned and local.ownership != .arc) continue;
            if (!try self.needsDrop(local.ty)) continue;
            if (local.ty.shape == .record) continue; // Task 5
            if (!checker.wasMoved(local.id)) continue; // never moved: scope end handles it
            if (!checker.liveAtExit(here.kind, here.key, local.id)) continue;
            if (checker.liveAtExit(after.kind, after.key, local.id)) continue;
            try self.emitDropFor(indent, local);
        }
    }
```

with `fn branchKey(e: *const ast.Expr) usize` mirroring borrowck's `branchKeyOf` exactly (same rule, same function shape; put a comment on each pointing at the other).

`emitIfStmt`/`emitBranchStmt` need the `after` exit: the enclosing statement list's `blockExit(stmts)`. Thread it: `emitStmt` already receives `rest`; extend `emitIfStmt(i, after: Exit, indent)` and `emitBranchStmt(e, after, indent)` where `after` is the exit of the statement list containing the `if` (from `emitStmts`, which knows `stmts`; for the function body, `blockExit(body)`). Inside `emitBranchStmt`'s `.block` arm, after `emitStmts(stmts, indent + 1)` and before the closing brace, call `emitBranchEndDrops(e, mark_at_branch_entry, after, indent + 1)` where `mark_at_branch_entry` is `self.locals.items.len` captured before the branch body was emitted. When an `if` has no `else` and some outer local would be released by the else rule, synthesize `else { <drops> }`: compute the would-be drops for a null branch by calling `emitBranchEndDrops` against `after` alone (a helper `branchNeedsSynthesizedElse` that runs the same loop without emitting); if any, emit ` else {\n`, the drops, `}`. borrowck records no `.branch_end` for a missing else, so make `liveAtExit(.branch_end, key_of_missing_else)` read as "live if not moved before the if": record, in Task 2's `checkIf`, a `.branch_end` for a missing else keyed by `@intFromPtr(i)` (the if expression itself) after restoring the entry state; add that line to Task 2 now if it was not done (it is part of this task's interface: key = the `if_expr` node's address).

Jumps: `emitLoopExitDrops(self, key: Exit, indent)` passes `key` into `emitDropsSince(mark, indent, key)` instead of null; the two callers pass `.{ .kind = .jump, .key = @intFromPtr(stmt) }` (the `Stmt` pointer `emitStmt` receives).

- [ ] **Step 4: Run** the two tests, then the whole codegen file, then `zig build test`.

- [ ] **Step 5: Measure the two fixtures AFTER, re-pin, commit**

Repeat Task 1 Step 2's probe for `branch_move.cell` and `loop_jump_revival.cell`: both must read `LIVE=0`, exit 0, no ASan report. Set `LEAK_BRANCH_MOVE=0` and `LEAK_LOOP_JUMP_REVIVAL=0`, update their comments ("CLOSED <date> by branch-end / jump releases; measured N -> 0 on both witnesses") and the `run_c_leaks` labels and README rows. Falsify a guard once: comment out the `liveAtExit(after...)` continue in `emitBranchEndDrops`, rebuild, run `branch_move.cell`'s probe with `neither`-shaped code: it must NOT double free (that shape has no move); instead falsify with `both`: make `emitBranchEndDrops` ignore `here` and run the `both` shape from the codegen test through ASan; expect exit 134. Restore. Record the falsification in the commit message.

```bash
git add src/cell/codegen.zig src/cell/borrowck.zig examples/leaks/README.md tools/check.sh
git commit -m "codegen: release at branch ends and jumps where borrowck recorded the value live (R16 residuals 1 and 2 closed)"
```

---

### Task 4: value-block ends

**Files:**
- Modify: `src/cell/codegen.zig` (`emitValueBlockDrops`), `src/cell/borrowck.zig` (if Task 2 deferred the value-block record to the call sites), tests, fixture pin

- [ ] **Step 1: Failing test**

```zig
test "a var revived in a value block is released after the tail" {
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn f() -> Int {
        \\  let copy n = {
        \\    var owned v: String = "a"
        \\    take(v)
        \\    v = "b"
        \\    3
        \\  }
        \\  return n
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&v);", 1);
    // After the tail is stored into the destination temporary.
    try expectBefore(f, "= 3;", "cell_string_free(&v);");
    try expectCompiles(e.text);
}
```

- [ ] **Step 2: Implement**

`emitValueBlockDrops(self, mark, stmts, tail, dest, indent)`: replace `pendingDropsSince(mark, null)` with `pendingDropsSince(mark, .{ .kind = .value_block_end, .key = @intFromPtr(stmts.ptr) })`. The tail-reach skip stays exactly as it is (a moved-and-revived local the tail reaches is still skipped; that is the over-approximation the function documents). Confirm the drops are emitted AFTER the tail's store into `dest` (read the caller in `emitValueExpr`'s `.block` arm; if the drops precede the store, move the call after it, which is the order the existing `value_block_local` fixture already relies on).

- [ ] **Step 3: Measure, re-pin, commit** (`value_block_revival.cell` to 0, both witnesses, ASan clean).

```bash
git add src/cell/codegen.zig src/cell/borrowck.zig examples/leaks/README.md tools/check.sh
git commit -m "codegen: release a revived local at a value block's end (R16 residual 3 closed)"
```

---

### Task 5: revived records

**Files:**
- Modify: `src/cell/borrowck.zig` (`recordExit` record admission, `recordLiveAtExit`), `src/cell/codegen.zig` (`pendingDropsSince` record arm, `emitBranchEndDrops` record arm), tests, fixture pin, docs

- [ ] **Step 1: Failing tests**

borrowck:

```zig
test "a record reassigned whole after a move is live at scope end" {
    var c = try checkForTest(
        \\pub struct Box { owned s: String }
        \\pub fn take(owned b: Box);
        \\pub fn f() {
        \\    var owned b = Box { s: "one" }
        \\    take(b)
        \\    b = Box { s: "two" }
        \\}
        \\pub fn g() {
        \\    var owned b = Box { s: "one" }
        \\    take(b)
        \\    b = Box { s: "two" }
        \\    let owned moved: String = b.s
        \\}
    );
    defer c.deinit();
    try std.testing.expect(c.checker.recordLiveAtExit(.block_end, blockKey("f"), c.bindingIdOf("b").?));
    try std.testing.expect(!c.checker.recordLiveAtExit(.block_end, blockKey("g"), c.bindingIdIn("g", "b").?));
}
```

codegen:

```zig
test "a revived record is released whole at scope end; a post-revival field move keeps the partial glue" {
    var e = try emitSource(
        \\pub struct Box { owned s: String }
        \\pub fn take(owned b: Box);
        \\pub fn f() {
        \\  var owned b = Box { s: "one" }
        \\  take(b)
        \\  b = Box { s: "two" }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_drop_Box(&b);", 1);
    try expectLineBefore(f, "cell_drop_Box(&b);", "b = (cell_Box){ .s = cell_string_from_str(cell_str_from_parts(\"two\", 3)) };");
    try expectCompiles(e.text);
}
```

(The glue's name and the literal's emitted spelling: read an existing record test near "per-struct drop glue" for the exact text and adjust the needles.)

- [ ] **Step 2: Implement**

borrowck: `recordExit` already appends one `ExitLiveness` per visible binding with `live` computed from `dead` and `loop_moved`; for a record binding that is exactly what the spec wants when "no field path is dead": extend the `live` computation to also scan `dead` for entries whose `binding` matches with ANY path (today `findDead` may already match by prefix; read it). Add:

```zig
    /// A record binding is released whole at an exit when it holds a value
    /// there (revived after any move) and no field path of it is dead on
    /// this path. Same records as `liveAtExit`; the per-field condition is
    /// what `recordExit` already folds in for a record binding.
    pub fn recordLiveAtExit(self: *const Checker, kind: ExitKind, key: usize, binding: u32) bool {
        return self.liveAtExit(kind, key, binding);
    }
```

and make `recordExit` compute `live = false` when any `dead` entry has `d.binding == b.id` regardless of path (it already does if `Dead` matches on binding alone; verify and add the path-insensitive check if not).

codegen `pendingDropsSince`'s record arm: today `if (checker.wasWhollyMoved(local.id)) continue;`. Change to: `if (checker.wasWhollyMoved(local.id)) { const e = exit orelse continue; if (!checker.recordLiveAtExit(e.kind, e.key, local.id)) continue; }` so a wholly moved record is still released where the exit says it holds a fresh value. The partial-move path (`emitPartialRecordDrop` from `moved_paths`) is unchanged; a record with a post-revival field move reads dead at the exit (its field path is in `dead`) and takes today's partial path. Remove the `if (local.ty.shape == .record) continue;` line from `emitBranchEndDrops` and apply the same admission there.

- [ ] **Step 3: Measure, re-pin, docs, gate, commit**

`revived_record.cell` to 0 on both witnesses, ASan clean. `docs/OWNERSHIP.md` R16: the "what still leaks, by design" sentences for the four residuals become CLOSED entries with the measured before/after, leaving the per-field record case; `codegen.zig`'s module comment paragraph on the same; `docs/SPEC.md`'s drop-insertion row. `tools/check.sh > /private/tmp/gate.log 2>&1; echo "CELL_GATE_EXIT: $?" >> /private/tmp/gate.log` reads `clean`; `tools/sweep-backends.sh` re-run and its count explained if it moved.

```bash
git add src/cell/borrowck.zig src/cell/codegen.zig examples/leaks/README.md tools/check.sh docs/OWNERSHIP.md docs/SPEC.md
git commit -m "drops: a record revived after a move is released where borrowck says it holds a value (R16 residual 4 closed)"
git push origin main
```

---

## Self-review

- Spec coverage: D.1 (Task 1 measures each), D.2 (Task 2 records; Task 5 records for records), D.3 (Tasks 3, 4, 5), D.4 (fixtures in Task 1 and re-pins in 3 to 5, tests per task, docs in Task 5).
- Placeholders: Task 2 leaves ONE decision to the implementer with instructions to record it (where the value-block exit is recorded: inside `closeBlockTail` or at its call sites) because the plan's author could not settle it without reading that function's body; Task 3 states the missing-else record as an interface addition to Task 2. Both are named, not hidden.
- Type consistency: `ExitKind.branch_end/jump/value_block_end`, `branchKeyOf` (borrowck) and `branchKey` (codegen) mirror each other; `recordLiveAtExit`; `emitBranchEndDrops(branch, mark, after, indent)`; `emitLoopExitDrops(key, indent)`.
