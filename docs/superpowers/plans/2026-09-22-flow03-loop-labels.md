# FLOW-03: `loop` and Zig-style Loop Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `loop { }` (exactly `while true { }`) and Zig-style loop labels (`outer: while c { }`, `outer: loop { }`, `break :outer`, `continue :outer`) to Cell, lowered correctly on the C, LLVM and MLIR backends, with borrowck, drops and leak pins that account for a jump leaving several loops at once.

**Architecture:** The parser turns `loop` into the `while_stmt` a `while true` would build, so no later stage has a `loop` case. Labels are carried on the AST (`while_stmt.label`, `ast.Jump.label`), checked by typecheck (unknown and repeated labels refused), and resolved exactly once in `hir.lower` to a depth (`brk: u32`, `cont: u32`, loops left beyond the innermost) that `cfg`, `liveness`, `llvmemit` and `mlirmit` index into their own loop stacks. borrowck and the C emitter walk the AST, so each resolves the label against its own loop stack and acts on the TARGET loop only: borrowck saves `break` state into and asks R2.a of the target frame; C releases every local since the target loop's mark and jumps with `goto` to a label placed at the target.

**Tech Stack:** Zig master `0.17.0-dev.2251+1175a3e99` (the repo's pin), the Cell compiler in `src/cell/`, C runtime in `runtime/`, Homebrew LLVM/MLIR (`mlir-opt`, `mlir-translate`, `llc`), the gate `tools/check.sh`.

**Spec:** `docs/superpowers/specs/2026-09-21-mod02-flow03-ir-first-design.md` (drafted as `~/Archive/2026-09-21-goal-ledger-rework/drafts/2026-09-21-mod02-flow03-ir-first-design.md`; approved by Donald 2026-09-22). This plan covers FLOW-03 only: the Rulings' D-F1 and D-F2, the "Labels (D-F1, D-F2)" architecture section, invariants 13 to 16, the label rows of "Error handling", and slices 1 and 2 of "Slices, in order". MOD-02 (D1 to D6) has its own plan, `docs/superpowers/plans/2026-09-22-mod02-modules-ir-first.md`.

**Provenance of the code below.** Every code block in Tasks 1 to 7 was built and run on a `git archive` export of `798d50c` before this plan was written: all tests named here passed (`All 731 tests passed.` at the end, 701 at the base), `tools/check.sh` exited 0 with verdict `clean`, `tools/sweep-backends.sh` reported `88 programs probed, 0 issue(s)`, and the Task 1 and Task 2 intermediate states were each built and tested on their own. HEAD has moved since (the codegen split, below), so line numbers are never cited; functions and tests are cited by name.

## Global Constraints

- **IR-first (Rulings).** Every slice lands on all three backends at once; FLOW-03 is not done until LLVM and MLIR print the same pinned answer as C for `examples/loop.cell` (21) and `examples/labels.cell` (227).
- **Flip criterion (Rulings), verbatim:** "every LLVM/MLIR leak pin in gate stage 7 reads 0." The IR pins this plan adds (`LEAK_LABELLED_BREAK_{LLVM,MLIR}`, `LEAK_LABELLED_CONTINUE_{LLVM,MLIR}`) join it; say so in each fixture header.
- **D-F1:** `loop` means exactly `while true` and is a statement. No `break` with a value.
- **D-F2:** Zig-style labels: `outer: while`, `outer: loop`, `break :outer`, `continue :outer`. Not `'name`.
- **Out of scope (What stays out):** `defer` (D-F3), `for` (D-F4), labelled blocks (`blk: { .. break :blk v }`), `break` with a value.
- **Target frame only (spec, borrowck):** a labelled jump's state reaches the target frame's borrowck facts and no intermediate frame's (invariant 14). `continue :outer` after moving a place declared inside the outer body is ACCEPTED; after moving a place declared before the outer loop it is REFUSED.
- **Invariants 13 to 16 (spec, verbatim):**
  13. A labelled jump runs the drops of every loop it leaves exactly once: every owning local declared since the target loop's mark is released on the jump, or later on the path the jump reaches, never both, never neither, and no local of the target's enclosing scope is released.
  14. A labelled jump's state reaches the target frame's borrowck facts and no intermediate frame's.
  15. `loop { B }` and `while true { B }` produce the same HIR, CFG and emitted code for all three backends.
  16. Every refusal names its reason; no case falls through to emitting a guess (an unresolved HIR label is `cannot lower`).
- **Label errors (spec wording):** `no enclosing loop is labelled 'outr'`; `label 'outer' is already used by an enclosing loop` (the location is a same-file `note`, see Task 2).
- **The gate** is `tools/check.sh`; its exit code is the verdict. It runs well past two minutes: redirect it to a log, read the exit code from the command itself (never through a pipe), and confirm against the `== verdict ==` line. Every task ends with it green.
- **Always `-Dswift=false`** on `zig build` and `zig build test`.
- **`--test-filter` trap:** a filter that matches nothing still prints `All 1 tests passed.` (the anonymous `refAllDecls` test in `src/root.zig` always runs). Every test run below says "confirm the named test appears in the output": read the test NAME in the log, not the count. `zig build test` rejects `--test-filter`; use `zig test src/root.zig --test-filter "<name>"` from the repo root (the llvmemit, mlirmit and codegen tests shell out to `cc` against `runtime/`, so run them from the root).
- **Zig master idioms:** `std.ArrayList(T) = .empty`, allocator-passing `append`/`deinit`/`pop`, and **no declarations between container fields** (the compiler refuses a `const` placed between two fields; measured while building this plan).
- **No em dashes** in source comments, docs, examples or commit messages.
- **Commit trailer:** every commit message ends with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **Concurrent work in the tree.** A peer session split `borrowck.zig` into `src/cell/borrowck/*.zig` (at `798d50c`) and is splitting `codegen.zig` into `src/cell/codegen/*.zig` (at `3543233` the free helpers `endsInJump`, `armDiverges`, `blockExit`, `exprUses`, `collectIdentsStmts`, `reachFromStmts` and the structs `Exit`, `OwningTemp`, `SkipLabel` already live in `src/cell/codegen/helpers.zig`). Before editing codegen, locate each function by name: `grep -rn 'fn emitLoopExitDrops\|fn skipLabelFor\|fn emitStmt\|const SkipLabel\|loop_marks:' src/cell/codegen.zig src/cell/codegen/`. "In src/cell/codegen.zig or its split successor under src/cell/codegen/" below means exactly that grep's answer. Run the cwd sweep from `~/CLAUDE.md` and ask a live peer before touching a file it is editing.
- **Cite, do not quote, the test count:** each gate step records the `All N tests passed.` line the gate prints under `== tests ==`.
- **Pins only fall.** Never loosen an existing pin in `tools/check.sh`.
- **After any ownership-lowering change** (Tasks 4 and 5) run `tools/sweep-backends.sh` and require `0 issue(s)`.

---

## File Structure

| File | Change | Task |
|---|---|---|
| `src/cell/parser.zig` | `parseLoop`; later `parseWhile`/`parseLoop` take a label, `parseJumpLabel`, `peekIs`, the `ident :` statement peek | 1, 2 |
| `src/cell/lexer.zig` | reserved-word comment (no token change) | 1 |
| `src/cell/ast.zig` | `while_stmt.label`, `pub const Jump`, `break_stmt: Jump`, `continue_stmt: Jump` | 2 |
| `src/cell/typecheck.zig` | `loop_depth: u32` becomes `loop_labels: std.ArrayList(LoopLabel)`, `loopLabelIndex`, two label errors, a temporary nested-jump refusal (added Task 2, removed Task 5) | 2, 5 |
| `src/cell/hir.zig` | `brk: u32`, `cont: u32`, `Lowerer.loop_labels`, `jumpDepth` | 3 |
| `src/cell/cfg.zig` | `lowerJump(kind, depth)`, fixture payloads | 3 |
| `src/cell/liveness.zig` | `Walker.jump(depth)`, fixture payloads | 3 |
| `src/cell/llvmemit.zig`, `src/cell/mlirmit.zig` | `break_label`/`continue_label` (`break_block`/`continue_block`) become a `loop_targets` stack, `loopTarget` | 3 |
| `src/cell/borrowck/model.zig`, `src/cell/borrowck/stmts.zig`, `src/cell/borrowck.zig` | `LoopFrame.label`, `jumpTarget`, `saveBreakState(label)`, `checkContinue(span, label)`, header sentence | 4 |
| `src/cell/codegen.zig` or its split successor | `loop_jumps`, `next_loop_label`, `LoopJump`, `jumpTarget`, `emitJump`, `emitLoopExitDrops(key, target, indent)`, `skipLabelFor` by loop key, labelled `while` emission | 5 |
| test files | `src/cell/parser.zig`, `src/cell/typecheck.zig`, `src/cell/hir.zig`, `src/cell/cfg.zig`, `src/cell/liveness.zig`, `src/cell/llvmemit.zig`, `src/cell/mlirmit.zig`, `src/cell/borrowck/tests_loops.zig`, the codegen test file, `src/root.zig` | 1 to 5 |
| `examples/loop.cell`, `examples/labels.cell` | new, with `// EXPECT-OUTPUT:` | 1, 6 |
| `examples/rejected/unknown_label.cell`, `duplicate_label.cell`, `labelled_continue_move.cell` | new | 2, 6 |
| `examples/leaks/labelled_break.cell`, `labelled_continue.cell` | new | 6 |
| `tools/check.sh` | stage 6 rows `loop 21`, `labels 227`; six `LEAK_LABELLED_*` pins and their stage 7 rows | 1, 6 |
| `docs/SPEC.md`, `docs/FEATURES.md`, `docs/OWNERSHIP.md`, `examples/README.md`, `examples/leaks/README.md` | status and design text | 6, 7 |

The AST walks that mention `break_stmt`/`continue_stmt` were enumerated with `grep -rn 'break_stmt\|continue_stmt' src/cell` (spec, Labels). Only these change meaning and are edited: typecheck `checkStmt`; `hir.Lowerer.lowerStmt`; borrowck `checkStmtKind`, `checkContinue`, `saveBreakState` (and `checkWhile`, which pushes the frame); codegen `emitStmt` (the `while_stmt`, `break_stmt` and `continue_stmt` prongs), `emitLoopExitDrops`, `skipLabelFor`. These are label-blind by construction and need no edit, because a jump of any label is still a jump and still names no binding: borrowck `branchDiverges` (a branch ending in any jump diverges), `stmtUsesName`, `stmtPropagatesName`, `oracleDeclCountStmts`, the statement walk under `oracleDeclCountStmts`, `oracleFindStmt`; the test helpers `firstJumpIn`, `firstWhileIn`; codegen `endsInJump` and `armDiverges` (a block ending in a labelled jump already emitted its drops, since the target's mark is at or below the block's), `blockExit`, `collectIdentsStmts`, `reachFromStmts`, `stmtUses`, `collectOwningResultsInStmts`. NLL (`loanStatusAt`) needs no change either: its forward half counts the current statement in full, and the current statement at the loan's block level is the whole enclosing loop, so a labelled back edge is already covered. Their prongs `.break_stmt, .continue_stmt => ...` keep compiling after Task 2 because a multi-item prong without a capture accepts any payload.

---

### Task 1: `loop` is `while true` (D-F1)

**Files:**
- Modify: `src/cell/parser.zig` (`parseStmt`, new `parseLoop`)
- Modify: `src/cell/lexer.zig` (the reserved-word comment above `kw_while` in `TokenKind`)
- Modify: `tools/check.sh` (stage 6 `for pair in` list)
- Create: `examples/loop.cell`
- Test: `src/cell/parser.zig`, `src/cell/typecheck.zig`, `src/cell/borrowck/tests_loops.zig`, `src/root.zig`

**Interfaces:**
- Consumes: `Parser.parseBlockBody`, `Parser.stmt`, `Parser.expect`, `tokenSpan`, `Parser.prev`; `root.compile`, `root.emitFor`, `root.Target`; `hir.lower`; `cfg.build`.
- Produces: `fn parseLoop(self: *Parser, start: Token) ParseError!ast.Stmt` (Task 2 adds a `label: ?[]const u8` parameter); `fn emitText(a: std.mem.Allocator, source: []const u8, target: Target) ![]const u8` in `src/root.zig` (private test helper).

- [ ] **Step 1: Write the failing parser test**

Append to the end of `src/cell/parser.zig`:

```zig
test "loop parses as a while whose condition is a synthesized true" {
    var tp = try parseForTest(
        \\pub fn f() {
        \\  loop {
        \\    break
        \\  }
        \\}
    );
    defer tp.deinit();
    const w = onlyStmt(tp.module).kind.while_stmt;
    try std.testing.expect(w.cond.kind.bool);
    // The synthesized condition spans the `loop` keyword, so a diagnostic
    // about it points at source the user wrote.
    try std.testing.expectEqual(@as(u32, 2), w.cond.span.line);
    try std.testing.expectEqual(@as(u32, 3), w.cond.span.column);
    try std.testing.expectEqual(@as(u32, 4), w.cond.span.end - w.cond.span.start);
    try std.testing.expectEqual(@as(usize, 1), w.body.len);
    try std.testing.expect(w.body[0].kind == .break_stmt);
}
```

- [ ] **Step 2: Write the failing typecheck, borrowck and whole-pipeline tests**

Append to the end of `src/cell/typecheck.zig`:

```zig
test "loop is a loop: break and continue inside it are accepted" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    loop {
        \\        continue
        \\        break
        \\    }
        \\}
    );
    try t.expectClean();
}
```

Append to the end of `src/cell/borrowck/tests_loops.zig`:

```zig
// ── `loop` and labelled jumps (FLOW-03, 2026-09-22) ───────────────────────

test "R2.a: loop is while true, so a move in it is refused the same way" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    loop {
        \\        take(v)
        \\    }
        \\}
    ,
        \\t.cell:6:14: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:5:5: note: 'v' is declared outside this loop; assign to it before the end of the body to revive it
        \\
    );
}
```

Append to the end of `src/root.zig` (invariant 15):

```zig
/// Emit `source` for `target` into an arena-owned string.
fn emitText(a: std.mem.Allocator, source: []const u8, target: Target) ![]const u8 {
    var module = try compile(a, source, "t.cell");
    var out: Io.Writer.Allocating = .init(a);
    var err_buf: [4096]u8 = undefined;
    var errw = Io.Writer.fixed(&err_buf);
    try emitFor(a, &module, source, &out.writer, target, &errw);
    return out.written();
}

test "loop and while true emit byte-identical C, LLVM IR and MLIR, over the same CFG" {
    // Spec invariant 15: `loop` is parsed as `while true`, so no stage can
    // tell the two apart. Byte-identical output on all three targets is the
    // whole-pipeline form of that claim.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const with_loop =
        \\pub fn f(copy n: Int) -> Int {
        \\    var i = 0
        \\    loop {
        \\        i = i + 1
        \\        if i > n {
        \\            break
        \\        }
        \\    }
        \\    return i
        \\}
    ;
    const with_while =
        \\pub fn f(copy n: Int) -> Int {
        \\    var i = 0
        \\    while true {
        \\        i = i + 1
        \\        if i > n {
        \\            break
        \\        }
        \\    }
        \\    return i
        \\}
    ;
    for ([_]Target{ .c, .llvm, .mlir }) |target| {
        try std.testing.expectEqualStrings(
            try emitText(a, with_while, target),
            try emitText(a, with_loop, target),
        );
    }

    var bag: diag.Bag = .init("t.cell", null);
    defer bag.deinit(a);
    var m1 = try compile(a, with_loop, "t.cell");
    var m2 = try compile(a, with_while, "t.cell");
    const h1 = try hir.lower(a, &m1, &bag);
    const h2 = try hir.lower(a, &m2, &bag);
    try std.testing.expect(!bag.hasErrors());
    const g1 = (try cfg.build(a, &h1.fns[0])).?;
    const g2 = (try cfg.build(a, &h2.fns[0])).?;
    try std.testing.expectEqual(g2.blocks.len, g1.blocks.len);
    for (g1.blocks, g2.blocks) |b1, b2| {
        try std.testing.expectEqual(b2.kind, b1.kind);
        try std.testing.expectEqualSlices(u32, b2.succs, b1.succs);
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `zig test src/root.zig --test-filter "loop" > /tmp/flow03-t1.log 2>&1; echo "exit $?"; grep -E 'loop parses|loop is a loop|loop is while true|byte-identical|error:|FAIL|passed|failed' /tmp/flow03-t1.log`
Expected: non-zero exit. `loop` has no parser rule yet, so each of the four tests fails with `error.UnexpectedToken` from `parseModule` (the parser reads `loop` as the start of an expression). Confirm all four test names appear in the output.

- [ ] **Step 4: Add the parser rule**

In `src/cell/parser.zig`, in `parseStmt`, add the `loop` line directly after the `while` line:

```zig
        if (self.match(.kw_while)) return self.parseWhile(start);
        if (self.match(.kw_loop)) return self.parseLoop(start);
```

and add this function directly after `parseWhile`:

```zig
    /// `loop { ... }` (SPEC 7.6, D-F1): exactly `while true { ... }`, and a
    /// statement. The `loop` keyword has just been consumed. The condition is
    /// a synthesized `true` literal spanning that keyword, so every later
    /// stage sees an ordinary `while_stmt` and none of them has a case of its
    /// own for `loop`. There is no `break` with a value.
    fn parseLoop(self: *Parser, start: Token) ParseError!ast.Stmt {
        const cond: ast.Expr = .{ .kind = .{ .bool = true }, .span = tokenSpan(self.prev()) };
        try self.expect(.l_brace);
        const body = try self.parseBlockBody();
        return self.stmt(.{ .while_stmt = .{ .cond = cond, .body = body } }, start);
    }
```

In `src/cell/lexer.zig`, in the comment above `kw_while` in `TokenKind`, replace

```zig
    // Of these only while/break/continue are scheduled to gain rules. The rest
    // are reserved so that programs do not come to depend on them as names.
```

with

```zig
    // while/break/continue have rules, and so does `loop` since 2026-09-22
    // (SPEC 7.6: it parses as `while true`). `for` and `defer` are designed
    // and deferred by ruling (D-F3, D-F4). The rest are reserved so that
    // programs do not come to depend on them as names.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zig test src/root.zig --test-filter "loop" > /tmp/flow03-t1.log 2>&1; echo "exit $?"; grep -E 'loop parses|loop is a loop|loop is while true|byte-identical|passed|failed' /tmp/flow03-t1.log`
Expected: `exit 0`, and these four names each followed by `...OK`: `parser.test.loop parses as a while whose condition is a synthesized true`, `typecheck.test.loop is a loop: break and continue inside it are accepted`, `tests_loops.test.R2.a: loop is while true, so a move in it is refused the same way`, `root.test.loop and while true emit byte-identical C, LLVM IR and MLIR, over the same CFG`. Confirm the named tests appear.

- [ ] **Step 6: Add the example and its stage 6 row**

Create `examples/loop.cell`:

```cell
// `loop { }` is `while true { }` and nothing else (SPEC 7.6, D-F1 ruled
// 2026-09-21). It is a statement, it carries no value, and `break` inside it
// takes no value. The parser builds the same `while_stmt` a `while true`
// would, so every checker and backend sees one construct, not two; the
// `loop and while true` test in src/root.zig pins that the emitted C, LLVM IR
// and MLIR are byte-identical.
//
// All three backends print 21:
//   cell emit               examples/loop.cell   -> C
//   cell emit --target=llvm examples/loop.cell   -> LLVM IR
//   cell emit --target=mlir examples/loop.cell   -> MLIR
//
// 21 is 1+2+3+4+5+6, the sum `sum_until` reaches before its `break`.

pub fn print_int(copy value: Int);

/// A `loop` leaves only through `break` (or `return`).
pub fn sum_until(copy limit: Int) -> Int {
    var total = 0
    var i = 0
    loop {
        i = i + 1
        if i > limit {
            break
        }
        total = total + i
    }
    return total
}

// EXPECT-OUTPUT: 21
pub fn main() {
    print_int(sum_until(copy 6))
}
```

`pub fn main() {` must start its line: stage 8 only runs files matching `grep -q '^pub fn main() *{'`.

In `tools/check.sh`, stage 6 (`== execution ==`), extend the list so a backend that REFUSES the file fails the gate (stage 8 runs only the backends that emit, and stage 4 would pass if LLVM and MLIR both refused):

```sh
for pair in "hello 42" "backends 24" "loops 55" "loop 21"; do
```

Run: `zig build -Dswift=false > /tmp/flow03-build.log 2>&1; echo "build exit $?"` then `.claude/skills/run-cell-lang/driver.sh --no-build --expect 21 examples/loop.cell`
Expected: `build exit 0`; the driver prints `ok    C    -> 21`, `ok    LLVM -> 21`, `ok    MLIR -> 21` and `clean`.

- [ ] **Step 7: Run the gate**

Run: `tools/check.sh > /tmp/flow03-gate-1.log 2>&1; echo "gate exit $?"; grep -E '^  \.\.\.\.  All [0-9]+ tests passed|loop ' /tmp/flow03-gate-1.log; sed -n '/^== verdict ==/,$p' /tmp/flow03-gate-1.log`
Expected: `gate exit 0`; stage 6 prints `ok    C    loop -> 21` (and LLVM, MLIR); stage 8 prints `loop  C/LLVM/MLIR -> 21`; the verdict is `clean`, or names only SKIPs for missing MLIR tools. Record the `All N tests passed.` line.

- [ ] **Step 8: Commit**

```bash
git add src/cell/parser.zig src/cell/lexer.zig src/cell/typecheck.zig src/cell/borrowck/tests_loops.zig src/root.zig examples/loop.cell tools/check.sh
git commit -m "feat(parser): loop is while true (FLOW-03 D-F1)

loop { B } parses to the while_stmt that while true { B } builds, with a
true condition spanning the keyword, so no checker or backend has a loop
case. C, LLVM IR and MLIR are pinned byte-identical (spec invariant 15);
examples/loop.cell prints 21 on all three backends and joins stage 6.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Labels in the frontend: AST, parser, typecheck (D-F2)

After this task a label parses and typechecks, and a labelled jump that names the loop it is directly in is a plain `break`/`continue`, which every backend already lowers correctly. A jump that leaves a NESTED loop is refused by typecheck with a temporary error until Task 5, so no commit between Task 2 and Task 5 lets any backend emit a plain `break` for it (invariant 16 at every commit, not only at the end).

**Files:**
- Modify: `src/cell/ast.zig` (`Stmt.Kind`, new `Jump`)
- Modify: `src/cell/parser.zig` (`parseWhile`, `parseLoop`, `parseStmt`, new `parseJumpLabel`, new `peekIs`)
- Modify: `src/cell/typecheck.zig` (`Checker.loop_depth`, `deinit`, `checkStmt`, new `loopLabelIndex`)
- Create: `examples/rejected/unknown_label.cell`, `examples/rejected/duplicate_label.cell`
- Test: `src/cell/parser.zig`, `src/cell/typecheck.zig`, `src/root.zig`

**Interfaces:**
- Consumes: Task 1's `parseLoop`.
- Produces:
  - `ast.Stmt.Kind.while_stmt: struct { cond: Expr, body: []Stmt, label: ?[]const u8 = null }`
  - `pub const ast.Jump = struct { label: ?[]const u8 = null }`; `break_stmt: Jump`, `continue_stmt: Jump`
  - `fn parseWhile(self: *Parser, start: Token, label: ?[]const u8) ParseError!ast.Stmt`, `fn parseLoop(self: *Parser, start: Token, label: ?[]const u8) ParseError!ast.Stmt`, `fn parseJumpLabel(self: *Parser) ParseError!?[]const u8`, `fn peekIs(self: *const Parser, offset: usize, kind: TokenKind) bool`
  - `typecheck.Checker.loop_labels: std.ArrayList(LoopLabel)`, `const LoopLabel = struct { name: ?[]const u8, span: ast.Span }`, `fn loopLabelIndex(self: *const Checker, name: []const u8) ?usize`
  - Diagnostic texts: `no enclosing loop is labelled '<name>'`; `label '<name>' is already used by an enclosing loop` plus note `the enclosing loop labelled '<name>' is here`; temporary `'<break|continue> :<name>' leaves a nested loop, which is not lowered yet`.

- [ ] **Step 1: Write the failing parser tests**

In `src/cell/parser.zig`, replace the Task 1 test `loop parses as a while whose condition is a synthesized true` with these three tests (the first is Task 1's test plus the two label assertions):

```zig
test "loop parses as a while whose condition is a synthesized true" {
    var tp = try parseForTest(
        \\pub fn f() {
        \\  loop {
        \\    break
        \\  }
        \\}
    );
    defer tp.deinit();
    const w = onlyStmt(tp.module).kind.while_stmt;
    try std.testing.expect(w.cond.kind.bool);
    // The synthesized condition spans the `loop` keyword, so a diagnostic
    // about it points at source the user wrote.
    try std.testing.expectEqual(@as(u32, 2), w.cond.span.line);
    try std.testing.expectEqual(@as(u32, 3), w.cond.span.column);
    try std.testing.expectEqual(@as(u32, 4), w.cond.span.end - w.cond.span.start);
    try std.testing.expect(w.label == null);
    try std.testing.expectEqual(@as(usize, 1), w.body.len);
    try std.testing.expect(w.body[0].kind.break_stmt.label == null);
}

test "a label before while or loop is carried, and jumps carry the label they name" {
    var tp = try parseForTest(
        \\pub fn f(copy n: Int) {
        \\  outer: while n > 0 {
        \\    inner: loop {
        \\      break :outer
        \\      continue :inner
        \\      break
        \\    }
        \\  }
        \\}
    );
    defer tp.deinit();
    const outer_stmt = onlyStmt(tp.module);
    const outer = outer_stmt.kind.while_stmt;
    try std.testing.expectEqualStrings("outer", outer.label.?);
    // The statement's span starts at the label, not at `while`.
    try std.testing.expectEqual(@as(u32, 3), outer_stmt.span.column);
    const inner = outer.body[0].kind.while_stmt;
    try std.testing.expectEqualStrings("inner", inner.label.?);
    try std.testing.expect(inner.cond.kind.bool);
    try std.testing.expectEqualStrings("outer", inner.body[0].kind.break_stmt.label.?);
    try std.testing.expectEqualStrings("inner", inner.body[1].kind.continue_stmt.label.?);
    try std.testing.expect(inner.body[2].kind.break_stmt.label == null);
}

test "a label must be followed by while or loop, and a jump label must be a name" {
    try std.testing.expectEqualStrings(
        "a label must be followed by 'while' or 'loop'",
        try parseErrorFor("pub fn f() {\n  outer: let x = 1\n}"),
    );
    try std.testing.expectEqualStrings(
        "expected identifier",
        try parseErrorFor("pub fn f() {\n  loop {\n    break :\n  }\n}"),
    );
}
```

- [ ] **Step 2: Write the failing typecheck and shipped-check tests**

Append to the end of `src/cell/typecheck.zig`:

```zig
test "a label on while or loop is accepted, and a jump may name the loop it is in" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(copy n: Int) {
        \\    outer: while n > 0 {
        \\        break :outer
        \\    }
        \\    again: loop {
        \\        if n > 1 {
        \\            continue :again
        \\        }
        \\        break :again
        \\    }
        \\}
    );
    try t.expectClean();
}

test "a jump naming no enclosing loop is reported at the jump" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    outer: loop {
        \\        break :outr
        \\    }
        \\    inner: loop {
        \\        break
        \\    }
        \\    loop {
        \\        continue :inner
        \\    }
        \\}
    );
    try t.expectCount(2);
    try t.expectDiag(0, .err, 3, 9, "no enclosing loop is labelled 'outr'");
    // `inner` labels a SIBLING loop that has already ended, not an enclosing one.
    try t.expectDiag(1, .err, 9, 9, "no enclosing loop is labelled 'inner'");
}

test "a label repeating an enclosing loop's is reported, and siblings may share one" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    outer: loop {
        \\        outer: loop {
        \\            break
        \\        }
        \\        break
        \\    }
        \\    outer: loop {
        \\        break :outer
        \\    }
        \\}
    );
    try t.expectCount(2);
    try t.expectDiag(0, .err, 3, 9, "label 'outer' is already used by an enclosing loop");
    try t.expectDiag(1, .note, 2, 5, "the enclosing loop labelled 'outer' is here");
}

test "a jump in a loop's condition belongs to the enclosing loop" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    loop {
        \\        outer: while { break :outer
        \\            true } {
        \\            break
        \\        }
        \\    }
        \\}
    );
    // The `break :outer` runs before `outer`'s body is entered, so `outer`
    // does not enclose it yet; the unlabelled `loop` around it does.
    try t.expectCount(1);
    try t.expectDiag(0, .err, 3, 24, "no enclosing loop is labelled 'outer'");
}

test "TEMPORARY: a labelled jump out of a nested loop is refused until it is lowered" {
    // FLOW-03 plan Task 5 deletes this test with the refusal it pins.
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    outer: loop {
        \\        loop {
        \\            continue :outer
        \\        }
        \\        break :outer
        \\    }
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 4, 13, "'continue :outer' leaves a nested loop, which is not lowered yet");
}
```

Append to the end of `src/root.zig`:

```zig
test "shipped check refuses a jump to a label no enclosing loop carries" {
    try expectCheckHas(
        \\pub fn f() {
        \\    outer: loop {
        \\        break :outr
        \\    }
        \\}
    , "error: no enclosing loop is labelled 'outr'");
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `zig test src/root.zig --test-filter "label" > /tmp/flow03-t2.log 2>&1; echo "exit $?"; tail -30 /tmp/flow03-t2.log`
Expected: non-zero exit, and the test build fails to compile first, with errors naming `label`: the parser test reads `w.label`, which `while_stmt` does not have yet, and `.break_stmt.label`, which a payload-less tag cannot supply. That compile failure is the red state for every test in this step.

- [ ] **Step 4: Add the label fields to the AST**

In `src/cell/ast.zig`, in `Stmt.Kind`, replace

```zig
        while_stmt: struct { cond: Expr, body: []Stmt },
        break_stmt,
        continue_stmt,
    };
};
```

with

```zig
        ///
        /// `label` is the `name` of `name: while c { }` or `name: loop { }`
        /// (SPEC 7.7), null when none was written. `loop { B }` is parsed as
        /// `while true { B }`, so there is no separate loop node and no later
        /// stage can treat the two differently.
        while_stmt: struct { cond: Expr, body: []Stmt, label: ?[]const u8 = null },
        break_stmt: Jump,
        continue_stmt: Jump,
    };
};

/// The payload of `break` and `continue`: the loop label a `break :name` or
/// `continue :name` names, or null for a plain jump, which targets the
/// innermost enclosing loop. Resolved against the enclosing loops by
/// typecheck (which refuses a name no enclosing loop carries) and again, to a
/// depth, by `hir.lower`; nothing downstream of HIR sees a name.
pub const Jump = struct {
    label: ?[]const u8 = null,
};
```

(The three `///` lines continue the existing doc comment on `while_stmt`.)

- [ ] **Step 5: Parse labels and labelled jumps**

In `src/cell/parser.zig`, replace `parseWhile` and Task 1's `parseLoop` with:

```zig
    ///
    /// `start` is the first token of the statement: the label when one was
    /// written, so the statement's span (and every diagnostic about the loop)
    /// covers `outer: while ...` from its first byte.
    fn parseWhile(self: *Parser, start: Token, label: ?[]const u8) ParseError!ast.Stmt {
        const cond = try self.parseNoStructLitExpr();
        // parseBlockBody does not consume the opening brace; every caller
        // does it, and forgetting silently swallows the enclosing function's
        // closing brace instead of failing here.
        try self.expect(.l_brace);
        const body = try self.parseBlockBody();
        return self.stmt(.{ .while_stmt = .{ .cond = cond, .body = body, .label = label } }, start);
    }

    /// `loop { ... }` (SPEC 7.6, D-F1): exactly `while true { ... }`, and a
    /// statement. The `loop` keyword has just been consumed. The condition is
    /// a synthesized `true` literal spanning that keyword, so every later
    /// stage sees an ordinary `while_stmt` and none of them has a case of its
    /// own for `loop`. There is no `break` with a value.
    fn parseLoop(self: *Parser, start: Token, label: ?[]const u8) ParseError!ast.Stmt {
        const cond: ast.Expr = .{ .kind = .{ .bool = true }, .span = tokenSpan(self.prev()) };
        try self.expect(.l_brace);
        const body = try self.parseBlockBody();
        return self.stmt(.{ .while_stmt = .{ .cond = cond, .body = body, .label = label } }, start);
    }

    /// The optional `:name` after `break` or `continue` (SPEC 7.7).
    fn parseJumpLabel(self: *Parser) ParseError!?[]const u8 {
        if (!self.match(.colon)) return null;
        return try self.expectIdent();
    }
```

(The first `///` line continues the existing doc comment above `parseWhile`.) In `parseStmt`, replace the block from `if (self.match(.kw_while))` through the `continue_stmt` return with:

```zig
        if (self.match(.kw_while)) return self.parseWhile(start, null);
        if (self.match(.kw_loop)) return self.parseLoop(start, null);
        // `name: while ...` and `name: loop ...` (SPEC 7.7). Two tokens decide
        // it, an identifier and then `:`, and no other statement can begin
        // that way: an expression never starts `ident :` (a struct literal's
        // `name: value` sits inside its braces), so this takes nothing from
        // the expression fallthrough below.
        if (self.check(.ident) and self.peekIs(1, .colon)) {
            const label = self.advance().lexeme;
            _ = self.advance(); // the `:`
            if (self.match(.kw_while)) return self.parseWhile(start, label);
            if (self.match(.kw_loop)) return self.parseLoop(start, label);
            return self.fail("a label must be followed by 'while' or 'loop'");
        }
        if (self.match(.kw_break)) {
            const label = try self.parseJumpLabel();
            _ = self.match(.semicolon);
            return self.stmt(.{ .break_stmt = .{ .label = label } }, start);
        }
        if (self.match(.kw_continue)) {
            const label = try self.parseJumpLabel();
            _ = self.match(.semicolon);
            return self.stmt(.{ .continue_stmt = .{ .label = label } }, start);
        }
```

Add `peekIs` directly after `check` in the token-cursor section:

```zig
    /// Whether the token `offset` places past the current one is `kind`.
    /// Bounded: a peek past the end is a mismatch, never an index out of
    /// range (a hand-built token slice in a test need not end in `eof`).
    fn peekIs(self: *const Parser, offset: usize, kind: TokenKind) bool {
        const i = self.index + offset;
        if (i >= self.tokens.len) return false;
        return self.tokens[i].kind == kind;
    }
```

- [ ] **Step 6: Replace typecheck's loop counter with a label stack**

In `src/cell/typecheck.zig`, `Checker`, replace the `loop_depth` field and its comment with:

```zig
    /// The `while` bodies enclosing the statement being checked, innermost
    /// last, each with its label (null when none was written) and the span of
    /// its statement. `break` and `continue` outside a loop have nothing to
    /// jump to and would emit C that does not compile, and a label no
    /// enclosing loop carries names nothing, so both are rejected here rather
    /// than downstream. A loop's condition is checked before its entry is
    /// pushed, so a jump in the condition belongs to the enclosing loop, the
    /// same rule `hir.lower`, borrowck and codegen follow.
    loop_labels: std.ArrayList(LoopLabel) = .empty,

    const LoopLabel = struct { name: ?[]const u8, span: ast.Span };
```

This must be the LAST field before the existing `pub const Symbol` declaration (it is, in place of `loop_depth`): Zig master refuses a declaration between two fields.

In `deinit`, add `self.loop_labels.deinit(self.allocator);` right after `self.scopes.deinit(self.allocator);`.

In `checkStmt`, replace the body of the `.while_stmt` prong after its condition check, and the `.break_stmt, .continue_stmt` prong, with:

```zig
                // A label may not repeat one already enclosing it: `break
                // :outer` would then name two loops. Sibling loops may reuse
                // a name, because neither encloses the other.
                if (w.label) |name| {
                    if (self.loopLabelIndex(name)) |i| {
                        try self.errf(stmt.span, "label '{s}' is already used by an enclosing loop", .{name});
                        try self.diagnostics.note(
                            self.allocator,
                            self.loop_labels.items[i].span,
                            try std.fmt.allocPrint(self.arena(), "the enclosing loop labelled '{s}' is here", .{name}),
                        );
                    }
                }
                // The body is a scope of its own, so a binding declared in it
                // does not leak past the loop.
                self.pushScope();
                defer self.popScope();
                try self.loop_labels.append(self.allocator, .{ .name = w.label, .span = stmt.span });
                defer _ = self.loop_labels.pop();
                for (w.body) |*s2| try self.checkStmt(@constCast(s2));
            },
            .break_stmt, .continue_stmt => |j| {
                const word = if (stmt.kind == .break_stmt) "break" else "continue";
                if (self.loop_labels.items.len == 0) {
                    try self.errf(stmt.span, "'{s}' is only valid inside a loop", .{word});
                } else if (j.label) |name| {
                    if (self.loopLabelIndex(name)) |i| {
                        // TEMPORARY, FLOW-03 plan Tasks 2 to 5: no backend
                        // lowers a jump out of a nested loop until Task 5
                        // lands, and a plain `break`/`continue` would leave
                        // the wrong loop. Task 5 deletes this branch.
                        if (i + 1 != self.loop_labels.items.len) {
                            try self.errf(stmt.span, "'{s} :{s}' leaves a nested loop, which is not lowered yet", .{ word, name });
                        }
                    } else {
                        try self.errf(stmt.span, "no enclosing loop is labelled '{s}'", .{name});
                    }
                }
            },
```

Add, directly before `fn errf`:

```zig
    /// The innermost enclosing loop labelled `name`, as an index into
    /// `loop_labels`, or null when no enclosing loop carries it.
    fn loopLabelIndex(self: *const Checker, name: []const u8) ?usize {
        var i = self.loop_labels.items.len;
        while (i > 0) {
            i -= 1;
            const l = self.loop_labels.items[i].name orelse continue;
            if (std.mem.eql(u8, l, name)) return i;
        }
        return null;
    }
```

No other file needs an edit for the new payloads: `hir.Lowerer.lowerStmt`, borrowck `checkStmtKind` and codegen `emitStmt` match `.break_stmt`/`.continue_stmt` without a capture, which still compiles, and for every program typecheck now accepts the label is either absent or names the innermost loop, where their plain-jump lowering is exactly right.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `zig build -Dswift=false > /tmp/flow03-build.log 2>&1; echo "build exit $?"; zig test src/root.zig --test-filter "label" > /tmp/flow03-t2.log 2>&1; echo "exit $?"; grep -E 'label|passed|failed' /tmp/flow03-t2.log`
Expected: `build exit 0`, `exit 0`, and each of these names followed by `...OK`: `a label before while or loop is carried, and jumps carry the label they name`, `a label must be followed by while or loop, and a jump label must be a name`, `a label on while or loop is accepted, and a jump may name the loop it is in`, `a label repeating an enclosing loop's is reported, and siblings may share one`, `TEMPORARY: a labelled jump out of a nested loop is refused until it is lowered`, `shipped check refuses a jump to a label no enclosing loop carries`. Then run `zig test src/root.zig --test-filter "enclosing loop" > /tmp/flow03-t2b.log 2>&1; echo "exit $?"; grep -E 'OK|passed' /tmp/flow03-t2b.log` and confirm `a jump naming no enclosing loop is reported at the jump` and `a jump in a loop's condition belongs to the enclosing loop` appear with `...OK`. Finally `zig test src/root.zig --test-filter "loop parses" > /tmp/flow03-t2c.log 2>&1; echo "exit $?"; grep OK /tmp/flow03-t2c.log` must show `loop parses as a while whose condition is a synthesized true...OK`.

- [ ] **Step 8: Add the two rejected examples**

Create `examples/rejected/unknown_label.cell`:

```cell
// EXPECT: currently-rejected
// Violates: SPEC 7.7 (a labelled `break` or `continue` must name an enclosing
// loop).
//
// `outr` is a typo for `outer`. The typechecker refuses it at the jump,
// rather than letting any stage guess that the innermost loop was meant:
//
//   error: no enclosing loop is labelled 'outr'
//
// A label on a sibling loop that has already ended does not count either;
// only loops that ENCLOSE the jump do. The text is pinned by the typecheck
// test "a jump naming no enclosing loop is reported at the jump".

pub fn main() {
    var i = 0
    outer: while i < 3 {
        i = i + 1
        loop {
            break :outr
        }
    }
}
```

Create `examples/rejected/duplicate_label.cell`:

```cell
// EXPECT: currently-rejected
// Violates: SPEC 7.7 (a label may not repeat one already enclosing it).
//
// Two enclosing loops both called `outer` would make `break :outer` name two
// loops. Sibling loops may reuse a name, because neither encloses the other.
//
//   error: label 'outer' is already used by an enclosing loop
//   note: the enclosing loop labelled 'outer' is here
//
// The text is pinned by the typecheck test "a label repeating an enclosing
// loop's is reported, and siblings may share one".

pub fn main() {
    outer: loop {
        outer: loop {
            break :outer
        }
        break
    }
}
```

Run: `for f in unknown_label duplicate_label; do ./zig-out/bin/cell check examples/rejected/$f.cell; echo "$f exit $?"; done`
Expected: `examples/rejected/unknown_label.cell:19:13: error: no enclosing loop is labelled 'outr'` then `unknown_label exit 1`; `examples/rejected/duplicate_label.cell:15:9: error: label 'outer' is already used by an enclosing loop`, `examples/rejected/duplicate_label.cell:14:5: note: the enclosing loop labelled 'outer' is here`, then `duplicate_label exit 1`.

- [ ] **Step 9: Run the gate**

Run: `tools/check.sh > /tmp/flow03-gate-2.log 2>&1; echo "gate exit $?"; grep -E 'All [0-9]+ tests passed' /tmp/flow03-gate-2.log; sed -n '/^== verdict ==/,$p' /tmp/flow03-gate-2.log`
Expected: `gate exit 0`, verdict `clean` (or SKIP-only). Stage 3 checks both new files are rejected. Record the test count.

- [ ] **Step 10: Commit**

```bash
git add src/cell/ast.zig src/cell/parser.zig src/cell/typecheck.zig src/root.zig examples/rejected/unknown_label.cell examples/rejected/duplicate_label.cell
git commit -m "feat(frontend): Zig-style loop labels parse and typecheck (FLOW-03 D-F2)

outer: while c { }, outer: loop { }, break :outer and continue :outer
parse onto while_stmt.label and ast.Jump. typecheck keeps a label stack:
an unknown label and a label repeating an enclosing one are refused, and
siblings may share a name. Until the backends lower it (plan Task 5), a
labelled jump out of a nested loop is refused rather than emitted as a
plain break.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Resolve labels in HIR; CFG, liveness, LLVM and MLIR follow the depth

**Files:**
- Modify: `src/cell/hir.zig` (`Stmt.Kind.brk`/`cont`, `Lowerer.loop_labels`, `Lowerer.lowerFn`, `Lowerer.lowerStmt`, new `Lowerer.jumpDepth`)
- Modify: `src/cell/cfg.zig` (`Builder.lowerStmt`, `Builder.lowerJump`; fixtures in tests `break targets the loop exit, continue targets the condition`, `a fully-diverging if/else inside a loop leaves the condition block's preds free of the dead join`, `nested control flow: an if inside a while inside a match arm`)
- Modify: `src/cell/liveness.zig` (`Walker.walkStmt`, `Walker.jump`; fixtures in tests `break and continue: liveness reaches the loop exit through both`, `the zero-predecessor join shape does not destabilize the fixpoint`)
- Modify: `src/cell/llvmemit.zig` (`Emitter.break_label`, `Emitter.continue_label`, `emitStmt`, new `loopTarget`)
- Modify: `src/cell/mlirmit.zig` (`Emitter.break_block`, `Emitter.continue_block`, `emitStmt`, new file-scope `LoopTarget`, new `loopTarget`)
- Test: `src/cell/hir.zig`, `src/cell/cfg.zig`, `src/cell/liveness.zig`, `src/cell/llvmemit.zig`, `src/cell/mlirmit.zig`

**Interfaces:**
- Consumes: Task 2's `while_stmt.label`, `ast.Jump.label`.
- Produces:
  - `hir.Stmt.Kind.brk: u32`, `hir.Stmt.Kind.cont: u32`: loops left beyond the innermost; consumers index `len - 1 - n`.
  - `fn jumpDepth(self: *Lowerer, span: Span, label: ?[]const u8) LowerError!u32`, diagnostic `cannot lower: no enclosing loop is labelled '<name>'`.
  - `fn lowerJump(self: *Builder, kind: enum { brk, cont }, depth: u32) CfgError!void`; `fn jump(self: *Walker, depth: u32) void`.
  - llvmemit and mlirmit: `loop_targets: std.ArrayList(LoopTarget)`, `LoopTarget = struct { brk: []const u8, cont: []const u8 }`, `fn loopTarget(self: *const Emitter, depth: u32) ?LoopTarget`.

These unit tests bypass typecheck (`lowerSource`, hand-built HIR, the emitters' own `emitSource`), so they exercise nested labelled jumps while Task 2's temporary refusal still guards `cell check`.

- [ ] **Step 1: Write the failing HIR tests**

Append to the end of `src/cell/hir.zig`:

```zig
test "a labelled jump lowers to how many loops it leaves beyond the innermost" {
    var l = try lowerSource(
        \\pub fn f(copy n: Int) {
        \\    outer: while n > 0 {
        \\        mid: loop {
        \\            loop {
        \\                break :outer
        \\                continue :mid
        \\                break
        \\                continue
        \\            }
        \\        }
        \\    }
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const outer = l.module.findFn("f").?.body.?[0].kind.while_loop;
    const mid = outer.body[0].kind.while_loop;
    const inner = mid.body[0].kind.while_loop;
    try std.testing.expectEqual(@as(u32, 2), inner.body[0].kind.brk);
    try std.testing.expectEqual(@as(u32, 1), inner.body[1].kind.cont);
    try std.testing.expectEqual(@as(u32, 0), inner.body[2].kind.brk);
    try std.testing.expectEqual(@as(u32, 0), inner.body[3].kind.cont);
}

test "a label naming the innermost loop lowers exactly like a plain jump" {
    var l = try lowerSource(
        \\pub fn f() {
        \\    here: loop {
        \\        break :here
        \\    }
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const w = l.module.findFn("f").?.body.?[0].kind.while_loop;
    try std.testing.expectEqual(@as(u32, 0), w.body[0].kind.brk);
}

test "an unresolvable label is cannot lower, never a guess at the innermost loop" {
    // Unchecked input: typecheck refuses this before any backend runs.
    var l = try lowerSource(
        \\pub fn f() {
        \\    loop {
        \\        break :nowhere
        \\    }
        \\}
    );
    defer l.deinit();
    try std.testing.expect(l.diagnostics.hasErrors());
    var found = false;
    for (l.diagnostics.list.items) |d| {
        if (std.mem.eql(u8, d.message, "cannot lower: no enclosing loop is labelled 'nowhere'")) found = true;
    }
    try std.testing.expect(found);
}
```

- [ ] **Step 2: Write the failing CFG and liveness tests**

Append to the end of `src/cell/cfg.zig`:

```zig
test "a labelled break targets the outer loop's exit, a labelled continue its condition" {
    // `outer: while { while { if c { break :outer } else { continue :outer } } }`,
    // as HIR hands it over: depth 1 on both jumps. The inner loop gets no
    // edge from either path; only its own condition reaches its exit.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var brk_stmt = hir.Stmt{ .span = test_span, .kind = .{ .brk = 1 } };
    var cont_stmt = hir.Stmt{ .span = test_span, .kind = .{ .cont = 1 } };
    var then_body = oneStmtBlock(&brk_stmt);
    var else_body = oneStmtBlock(&cont_stmt);
    var if_cond = boolExpr(true);
    const if_e = unitExpr(.{ .if_expr = .{
        .cond = &if_cond,
        .then_body = &then_body,
        .else_body = &else_body,
    } });
    var inner_body = [_]hir.Stmt{exprStmt(if_e)};
    const inner_cond = boolExpr(true);
    var outer_body = [_]hir.Stmt{
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = inner_cond, .body = &inner_body } } },
    };
    const outer_cond = boolExpr(true);
    var stmts = [_]hir.Stmt{
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = outer_cond, .body = &outer_body } } },
    };
    const f = testFn(&stmts);

    const g = (try build(a, &f)).?;
    try assertPredsSuccsAgree(g);

    const entry = findBlock(g, g.entry);
    const outer_cond_b = findBlock(g, entry.succs[0]);
    const outer_body_b = findBlock(g, outer_cond_b.succs[0]);
    const outer_exit_b = findBlock(g, outer_cond_b.succs[1]);
    const inner_cond_b = findBlock(g, outer_body_b.succs[0]);
    const inner_body_b = findBlock(g, inner_cond_b.succs[0]);
    const inner_exit_b = findBlock(g, inner_cond_b.succs[1]);
    try std.testing.expectEqual(BlockKind.while_cond, inner_cond_b.kind);

    try std.testing.expectEqual(Terminator.branch, inner_body_b.term);
    const then_b = findBlock(g, inner_body_b.succs[0]);
    const else_b = findBlock(g, inner_body_b.succs[1]);
    try std.testing.expectEqual(Terminator.goto, then_b.term);
    try std.testing.expectEqual(outer_exit_b.id, then_b.succs[0]);
    try std.testing.expectEqual(Terminator.goto, else_b.term);
    try std.testing.expectEqual(outer_cond_b.id, else_b.succs[0]);

    // The inner exit is reached only by the inner condition failing, and
    // falls through to the outer back edge.
    try std.testing.expectEqual(@as(usize, 1), inner_exit_b.preds.len);
    try std.testing.expectEqual(inner_cond_b.id, inner_exit_b.preds[0]);
    try std.testing.expectEqual(outer_cond_b.id, inner_exit_b.succs[0]);
    // Every path through the inner body jumps, so its condition is entered
    // once from the outer body and never from a back edge.
    try std.testing.expectEqual(@as(usize, 1), inner_cond_b.preds.len);
    // The outer condition: entry, the labelled continue, the inner exit.
    try std.testing.expectEqual(@as(usize, 3), outer_cond_b.preds.len);
    // The outer exit: its own condition failing, and the labelled break.
    try std.testing.expectEqual(@as(usize, 2), outer_exit_b.preds.len);
}
```

Append to the end of `src/cell/liveness.zig`:

```zig
test "a labelled break keeps the walker in lockstep and carries liveness to the outer exit" {
    // `let s = 1; outer: while { while { break :outer } }; return s`. The
    // jump allocates no block in either traversal, so `analyze` must not
    // return GraphMismatch, and `s` must be live through the inner loop,
    // because the labelled break reaches the read after the outer loop.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var bindings = [_]hir.Binding{dummyBinding(0)};

    var inner_body = [_]hir.Stmt{.{ .span = test_span, .kind = .{ .brk = 1 } }};
    const inner_cond = boolExpr(true);
    var outer_body = [_]hir.Stmt{
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = inner_cond, .body = &inner_body } } },
    };
    const outer_cond = boolExpr(true);
    var stmts = [_]hir.Stmt{
        letStmt(0, intExpr(1)),
        .{ .span = test_span, .kind = .{ .while_loop = .{ .cond = outer_cond, .body = &outer_body } } },
        retStmt(refExpr(0)),
    };
    const f = testFn(&stmts, &bindings);

    const g = (try cfg.build(a, &f)).?;
    const r = try analyze(a, &f, &g);

    const entry = findBlock(g, g.entry);
    const outer_cond_b = findBlock(g, entry.succs[0]);
    const outer_body_b = findBlock(g, outer_cond_b.succs[0]);
    const outer_exit_b = findBlock(g, outer_cond_b.succs[1]);
    const inner_cond_b = findBlock(g, outer_body_b.succs[0]);
    const inner_body_b = findBlock(g, inner_cond_b.succs[0]);

    // The labelled break is the inner body's only statement: its block's
    // one successor is the OUTER exit.
    try std.testing.expectEqual(outer_exit_b.id, inner_body_b.succs[0]);
    try std.testing.expect(r.live_out[inner_body_b.id][0]);
    try std.testing.expect(r.live_in[inner_cond_b.id][0]);
    try std.testing.expect(hasLastUse(r.last_uses, outer_exit_b.id, 0));
}
```

- [ ] **Step 3: Write the failing emitter tests**

Append to the end of `src/cell/llvmemit.zig`:

```zig
test "a labelled break branches to the outer loop's end block, a labelled continue to its condition" {
    var e = try emitSource(
        \\pub fn f(copy n: Int) -> Int {
        \\  var i = 0
        \\  outer: while i < n {
        \\    i = i + 1
        \\    loop {
        \\      if i > 2 {
        \\        break :outer
        \\      }
        \\      continue :outer
        \\    }
        \\  }
        \\  return i
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    // The outer loop takes labels 0 to 2 (cond, body, end), the inner loop
    // 3 to 5, so the two jumps name the OUTER blocks.
    try expectContains(e.text, "loop.end.2:");
    try expectContains(e.text, "  br label %loop.end.2\n");
    try expectContains(e.text, "  br label %loop.cond.0\n");
}

test "labelled jumps compute the same answer the C backend does" {
    // find(12) stops at 2 * 6 and returns 206; rows(4) adds 1 + 2 per outer
    // iteration and skips the `+ 1000`, 12. The C backend prints 218 too
    // (examples/labels.cell carries the same two functions).
    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub fn find(copy target: Int) -> Int {
        \\  var found = 0
        \\  var i = 0
        \\  outer: while i < 10 {
        \\    i = i + 1
        \\    var j = 0
        \\    while j < 10 {
        \\      j = j + 1
        \\      if i * j == target {
        \\        found = i * 100 + j
        \\        break :outer
        \\      }
        \\    }
        \\  }
        \\  return found
        \\}
        \\pub fn rows(copy n: Int) -> Int {
        \\  var r = 0
        \\  var i = 0
        \\  outer: while i < n {
        \\    i = i + 1
        \\    var j = 0
        \\    while j < n {
        \\      j = j + 1
        \\      r = r + j
        \\      if j == 2 {
        \\        continue :outer
        \\      }
        \\    }
        \\    r = r + 1000
        \\  }
        \\  return r
        \\}
        \\pub fn main() {
        \\  print_int(find(copy 12) + rows(copy 4))
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    const out = try runEmitted(e.text);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("218\n", out);
}
```

Append to the end of `src/cell/mlirmit.zig`:

```zig
test "labelled jumps lower through MLIR to the same answer the C backend prints" {
    // Same program as llvmemit's labelled-jump test: find(12) is 206 and
    // rows(4) is 12. A labelled jump that branched to the INNER loop's
    // blocks would print something else (find would keep scanning; rows
    // would add the 1000s).
    const gpa = std.testing.allocator;
    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub fn find(copy target: Int) -> Int {
        \\  var found = 0
        \\  var i = 0
        \\  outer: while i < 10 {
        \\    i = i + 1
        \\    var j = 0
        \\    while j < 10 {
        \\      j = j + 1
        \\      if i * j == target {
        \\        found = i * 100 + j
        \\        break :outer
        \\      }
        \\    }
        \\  }
        \\  return found
        \\}
        \\pub fn rows(copy n: Int) -> Int {
        \\  var r = 0
        \\  var i = 0
        \\  outer: while i < n {
        \\    i = i + 1
        \\    var j = 0
        \\    while j < n {
        \\      j = j + 1
        \\      r = r + j
        \\      if j == 2 {
        \\        continue :outer
        \\      }
        \\    }
        \\    r = r + 1000
        \\  }
        \\  return r
        \\}
        \\pub fn main() {
        \\  print_int(find(copy 12) + rows(copy 4))
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    const out = try runThroughMlir(gpa, e.text);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("218\n", out);
}
```

`runThroughMlir` returns `error.SkipZigTest` when `mlir-opt`, `mlir-translate` or `llc` is missing; a SKIP is a weaker run, never a pass.

- [ ] **Step 4: Run the tests to verify they fail**

Run: `zig test src/root.zig --test-filter "label" > /tmp/flow03-t3.log 2>&1; echo "exit $?"; grep -E 'error:' /tmp/flow03-t3.log | head -5`
Expected: non-zero exit, a compile error first: the new tests construct `.{ .brk = 1 }` and read `.kind.brk` as a `u32`, while `hir.Stmt.Kind.brk` is still a bare tag (`type 'void'` / `no field` style errors naming `brk`).

- [ ] **Step 5: Resolve the label in HIR**

In `src/cell/hir.zig`, `Stmt.Kind`, replace `brk,` and `cont,` with:

```zig
        /// `break` and `continue`. The payload is how many loops the jump
        /// leaves BEYOND the innermost enclosing one: 0 is a plain jump (or a
        /// label naming the innermost loop), 1 targets the loop around it,
        /// and so on. `lower` resolves the label once; every consumer indexes
        /// its own loop stack at `len - 1 - n` and never sees a name.
        brk: u32,
        cont: u32,
```

In `Lowerer`, add after the `depth: u32 = 0,` field:

```zig
    /// The labels of the loops enclosing the statement being lowered,
    /// innermost last, null for an unlabelled loop. Pushed after a loop's
    /// condition is lowered, so a jump in the condition belongs to the
    /// enclosing loop, as typecheck decides it.
    loop_labels: std.ArrayList(?[]const u8) = .empty,
```

In `lowerFn`, add `self.loop_labels.clearRetainingCapacity();` after `self.scope.clearRetainingCapacity();`.

In `lowerStmt`, replace the `.while_stmt`, `.break_stmt` and `.continue_stmt` prongs with:

```zig
            .while_stmt => |w| {
                const cond = try self.lowerExpr(&w.cond);
                self.pushScope();
                try self.loop_labels.append(self.arena, w.label);
                const body = try self.lowerStmts(w.body);
                _ = self.loop_labels.pop();
                self.popScope();
                return .{ .span = stmt.span, .kind = .{ .while_loop = .{ .cond = cond, .body = body } } };
            },
            .break_stmt => |j| return .{ .span = stmt.span, .kind = .{ .brk = try self.jumpDepth(stmt.span, j.label) } },
            .continue_stmt => |j| return .{ .span = stmt.span, .kind = .{ .cont = try self.jumpDepth(stmt.span, j.label) } },
```

Add, directly before `fn lowerPlace`:

```zig
    /// How many loops a jump leaves beyond the innermost: 0 for a plain jump
    /// and for a label naming the innermost loop. A label no enclosing loop
    /// carries is reachable only in a module typecheck refused; it is `cannot
    /// lower`, never a guess at the innermost loop (spec invariant 16).
    fn jumpDepth(self: *Lowerer, span: Span, label: ?[]const u8) LowerError!u32 {
        const name = label orelse return 0;
        var i = self.loop_labels.items.len;
        while (i > 0) {
            i -= 1;
            const l = self.loop_labels.items[i] orelse continue;
            if (std.mem.eql(u8, l, name)) return @intCast(self.loop_labels.items.len - 1 - i);
        }
        try self.cannotLower(span, try std.fmt.allocPrint(self.arena, "no enclosing loop is labelled '{s}'", .{name}));
        return 0;
    }
```

- [ ] **Step 6: Index the loop stacks by depth in CFG and liveness**

In `src/cell/cfg.zig`, `Builder.lowerStmt`, replace the two jump prongs with:

```zig
            .brk => |depth| try self.lowerJump(.brk, depth),
            .cont => |depth| try self.lowerJump(.cont, depth),
```

and replace the head of `lowerJump` (signature through the `target` line) with:

```zig
    /// `depth` is the HIR payload: loops left beyond the innermost, so the
    /// target is `loops[len - 1 - depth]`. A labelled `break` gets an edge to
    /// the OUTER loop's exit and a labelled `continue` one to its condition;
    /// the loops in between get no edge from this path at all.
    fn lowerJump(self: *Builder, kind: enum { brk, cont }, depth: u32) CfgError!void {
        const c = self.cur orelse return;
        // `break`/`continue` outside a loop, and a label no enclosing loop
        // carries, are already rejected by `typecheck.zig`, so the target
        // loop context is always open here; a fixture that violates this is
        // a bug in the fixture, and the assert says so plainly instead of
        // building a silently wrong graph.
        std.debug.assert(self.loops.items.len > depth);
        const target = self.loops.items[self.loops.items.len - 1 - depth];
```

In the three cfg tests named under **Files**, change every `hir.Stmt{ .span = test_span, .kind = .brk }` to `hir.Stmt{ .span = test_span, .kind = .{ .brk = 0 } }` and every `.kind = .cont }` to `.kind = .{ .cont = 0 } }` (five sites; `grep -n 'kind = .brk\|kind = .cont' src/cell/cfg.zig` must print nothing afterwards).

In `src/cell/liveness.zig`, `Walker.walkStmt`, replace the two jump prongs, and `jump`, with:

```zig
            .brk => |depth| self.jump(depth),
            .cont => |depth| self.jump(depth),
        }
    }

    /// Mirrors `cfg.Builder.lowerJump`, which asserts the same bound. A jump
    /// allocates no block and records no op whatever loop it targets, so a
    /// labelled jump changes nothing here but the assertion: the lockstep
    /// with `cfg.Builder` (and the `GraphMismatch` check guarding it) holds
    /// unchanged.
    fn jump(self: *Walker, depth: u32) void {
        if (self.cur == null) return;
        std.debug.assert(self.loop_depth > depth);
        self.cur = null;
    }
```

and update the four fixture sites in the two liveness tests named under **Files** the same way (`grep -n 'kind = .brk\|kind = .cont' src/cell/liveness.zig` prints nothing afterwards).

- [ ] **Step 7: Turn the emitters' jump targets into stacks**

In `src/cell/llvmemit.zig`, `Emitter`, replace the `break_label`/`continue_label` fields and their comment with the following (they are the last fields, so `LoopTarget` may follow them):

```zig
    /// Where a `break` and a `continue` jump, for every loop enclosing the
    /// statement being emitted, innermost last. A jump with HIR depth `n`
    /// takes entry `len - 1 - n`. Empty outside a loop, which the
    /// typechecker already rejects.
    loop_targets: std.ArrayList(LoopTarget) = .empty,

    const LoopTarget = struct { brk: []const u8, cont: []const u8 };
```

In `emitStmt`'s `.while_loop` prong, replace the four `saved_*`/assignment lines, the body loop and the two restores with:

```zig
                try self.loop_targets.append(self.arena, .{ .brk = end_b, .cont = cond_b });
                for (w.body) |s2| try self.emitStmt(&s2);
                _ = self.loop_targets.pop();
```

Replace the `.brk` and `.cont` prongs with:

```zig
            .brk => |depth| {
                const target = self.loopTarget(depth) orelse return;
                try self.out.print("  br label %{s}\n", .{target.brk});
                self.terminated = true;
            },
            .cont => |depth| {
                const target = self.loopTarget(depth) orelse return;
                try self.out.print("  br label %{s}\n", .{target.cont});
                self.terminated = true;
            },
```

Add directly before `fn nextLabel`:

```zig
    /// The loop a jump of HIR depth `depth` targets, or null when fewer
    /// loops enclose it (unreachable after typecheck).
    fn loopTarget(self: *const Emitter, depth: u32) ?LoopTarget {
        const n = self.loop_targets.items.len;
        if (depth >= n) return null;
        return self.loop_targets.items[n - 1 - depth];
    }
```

In `src/cell/mlirmit.zig`, the jump fields sit BETWEEN other fields, so the struct type must go at file scope. Add directly before `const Emitter = struct {`:

```zig
/// A loop's two jump targets: `brk` is its end block, `cont` its condition.
const LoopTarget = struct { brk: []const u8, cont: []const u8 };
```

replace the `break_block`/`continue_block` fields (keep their neighbours) with:

```zig
    /// Where a `break` and a `continue` jump, for every loop enclosing the
    /// statement being emitted, innermost last. A jump with HIR depth `n`
    /// takes entry `len - 1 - n`. Empty outside a loop, which the
    /// typechecker already rejects.
    loop_targets: std.ArrayList(LoopTarget) = .empty,
```

and apply the same three edits as llvmemit: in `.while_loop`, `try self.loop_targets.append(self.arena, .{ .brk = end_b, .cont = cond_b });` / body / `_ = self.loop_targets.pop();`; the jump prongs:

```zig
            .brk => |depth| {
                const target = self.loopTarget(depth) orelse return;
                try self.line("cf.br {s}", .{target.brk});
                self.returned = true;
            },
            .cont => |depth| {
                const target = self.loopTarget(depth) orelse return;
                try self.line("cf.br {s}", .{target.cont});
                self.returned = true;
            },
```

and the same `loopTarget` function, placed directly before `fn nextBlock`.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `zig build -Dswift=false > /tmp/flow03-build.log 2>&1; echo "build exit $?"; zig test src/root.zig --test-filter "label" > /tmp/flow03-t3.log 2>&1; echo "exit $?"; grep -E 'hir.test|cfg.test|liveness.test|llvmemit.test|mlirmit.test|SKIP|passed|failed' /tmp/flow03-t3.log`
Expected: `build exit 0`, `exit 0`, and `...OK` (not SKIP) after each of: `a labelled jump lowers to how many loops it leaves beyond the innermost`, `a label naming the innermost loop lowers exactly like a plain jump`, `an unresolvable label is cannot lower, never a guess at the innermost loop`, `a labelled break targets the outer loop's exit, a labelled continue its condition`, `a labelled break keeps the walker in lockstep and carries liveness to the outer exit`, `a labelled break branches to the outer loop's end block, a labelled continue to its condition`, `labelled jumps compute the same answer the C backend does`, `labelled jumps lower through MLIR to the same answer the C backend prints`. Confirm the named tests appear. Then `zig build test -Dswift=false > /tmp/flow03-t3b.log 2>&1; echo "exit $?"` must print `exit 0`: the whole suite, including the five cfg and liveness tests whose fixtures changed payload (their names are listed under **Files**).

- [ ] **Step 9: Run the gate**

Run: `tools/check.sh > /tmp/flow03-gate-3.log 2>&1; echo "gate exit $?"; grep -E 'All [0-9]+ tests passed' /tmp/flow03-gate-3.log; sed -n '/^== verdict ==/,$p' /tmp/flow03-gate-3.log`
Expected: `gate exit 0`, verdict `clean` (or SKIP-only). Record the test count.

- [ ] **Step 10: Commit**

```bash
git add src/cell/hir.zig src/cell/cfg.zig src/cell/liveness.zig src/cell/llvmemit.zig src/cell/mlirmit.zig
git commit -m "feat(hir): resolve loop labels once; CFG and IR emitters follow the depth

hir.Stmt brk and cont carry how many loops a jump leaves beyond the
innermost, resolved in lowerStmt; an unknown label is cannot lower.
cfg.Builder.lowerJump and liveness.Walker index their loop stacks by it,
keeping the GraphMismatch lockstep; llvmemit and mlirmit keep a stack of
break and continue targets. Labelled jumps print 218 on LLVM and MLIR.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: borrowck asks the target frame only (invariant 14)

**Files:**
- Modify: `src/cell/borrowck/model.zig` (`LoopFrame` doc, new field `label`, `breaks` doc)
- Modify: `src/cell/borrowck/stmts.zig` (`checkWhile` frame push, new `jumpTarget`, `checkContinue`, `saveBreakState`, `checkStmtKind`)
- Modify: `src/cell/borrowck.zig` (`Checker` method re-exports; the R2.a paragraph of the module header)
- Test: `src/cell/borrowck/tests_loops.zig`

**Interfaces:**
- Consumes: Task 2's `while_stmt.label`, `ast.Jump.label`.
- Produces: `LoopFrame.label: ?[]const u8 = null` (first field); `pub fn jumpTarget(self: *Checker, label: ?[]const u8) ?*LoopFrame` re-exported as `Checker.jumpTarget`; `pub fn checkContinue(self: *Checker, span: Span, label: ?[]const u8) Error!void`; `pub fn saveBreakState(self: *Checker, label: ?[]const u8) Error!void`. A `break :label` is appended to the TARGET frame's `breaks`, so `skipBreakLoop(break_key)` returns the target loop's key; codegen (Task 5) relies on that.

Harness tests run borrowck alone (no typecheck), so nested labelled jumps are testable while Task 2's refusal still stands.

- [ ] **Step 1: Write the failing tests**

Append to the end of `src/cell/borrowck/tests_loops.zig`, after Task 1's `loop` test (the section comment from Task 1 already heads it):

```zig
// A `break :outer` or `continue :outer` is asked of the OUTER frame only
// (spec invariant 14). Control on that path never reaches the back edge or
// the after-loop point of any loop in between, so those frames see neither.

test "R2.a: continue :outer after moving a place declared in the outer body is accepted" {
    // The next OUTER iteration declares a fresh `v`, so the move is not
    // carried. Asking every frame the jump passes would wrongly refuse this:
    // the inner frame carries `v` (declared before the inner loop).
    try expectAccepted(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var i = 0
        \\    outer: while i < 3 {
        \\        i = i + 1
        \\        var owned v: String = "a"
        \\        var j = 0
        \\        while j < n {
        \\            j = j + 1
        \\            if j == 2 {
        \\                take(v)
        \\                continue :outer
        \\            }
        \\        }
        \\    }
        \\}
    );
}

test "R2.a: continue :outer after moving a place declared before the outer loop is refused" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    outer: while i < 3 {
        \\        i = i + 1
        \\        var j = 0
        \\        while j < n {
        \\            j = j + 1
        \\            if j == 2 {
        \\                take(v)
        \\                continue :outer
        \\            }
        \\        }
        \\        v = "b"
        \\    }
        \\}
    ,
        \\t.cell:12:22: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:13:17: note: this 'continue' is reached before 'v' is assigned again
        \\
    );
}

test "R2: break :outer while moved reaches the code after the OUTER loop" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    outer: while i < 3 {
        \\        i = i + 1
        \\        var j = 0
        \\        while j < n {
        \\            j = j + 1
        \\            if j == 2 {
        \\                take(v)
        \\                break :outer
        \\            }
        \\        }
        \\        v = "b"
        \\    }
        \\    take(v)
        \\}
    ,
        \\t.cell:18:10: error: use of 'v' after it was moved
        \\t.cell:12:22: note: 'v' was moved here by the call to 'take'
        \\
    );
}

test "R2: break :outer's state skips the inner loop's after-loop point" {
    // If the labelled break saved into the INNER frame, `v` would be dead
    // after the inner loop and `take(v)` below it would be a use after
    // move. The path that moved `v` leaves both loops, so it never gets there.
    try expectAccepted(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    outer: while i < 3 {
        \\        i = i + 1
        \\        var j = 0
        \\        while j < n {
        \\            j = j + 1
        \\            if j == 2 {
        \\                take(v)
        \\                break :outer
        \\            }
        \\        }
        \\        take(v)
        \\        v = "b"
        \\    }
        \\}
    );
}

test "a labelled skip-revival break is recorded against the loop it names" {
    // The skip-revival shape of `after_loop_skip is live for a skip-revival
    // break`, with the `break` moved into a nested loop and naming the
    // outer one. borrowck appends it to the OUTER frame's `breaks`, so the
    // outer loop gets the skip record and codegen's `skipLabelFor` finds it
    // by loop key (it is not the innermost loop at the jump).
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    outer: while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        while i > n {
        \\            break :outer
        \\        }
        \\        v = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const outer_key = @intFromPtr(&h.fnBody("f")[2]);
    try std.testing.expect(!h.checker.liveAtExit(.after_loop, outer_key, v));
    try std.testing.expect(h.checker.liveAtExit(.after_loop_skip, outer_key, v));
    try std.testing.expectEqual(@as(?usize, outer_key), h.checker.skipBreakLoop(h.firstJump("f")));
}

test "R2.a: an unconditional move then continue :outer is still refused by the inner loop, conservatively" {
    // Not a labelled-jump rule: the inner loop's body-end check does not
    // track that statements after a jump are unreachable, exactly as
    // `take(v); break` is refused today. Written inside `if j == 2 { .. }`
    // (the accepted test above) the branch's moves stay out of the merge.
    // Pinned so a later divergence walk that relaxes it is a visible change.
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var i = 0
        \\    outer: while i < 3 {
        \\        i = i + 1
        \\        var owned v: String = "a"
        \\        var j = 0
        \\        while j < n {
        \\            j = j + 1
        \\            take(v)
        \\            continue :outer
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:11:18: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:9:9: note: 'v' is declared outside this loop; assign to it before the end of the body to revive it
        \\
    );
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig test src/root.zig --test-filter "outer" > /tmp/flow03-t4.log 2>&1; echo "exit $?"; grep -E 'tests_loops|FAIL|passed|failed' /tmp/flow03-t4.log`
Expected: non-zero exit; measured on the pre-change code:
- `continue :outer after moving a place declared in the outer body is accepted` FAILS: the inner frame reports `t.cell:12:22: error: 'v' is moved inside a loop, ...` and `t.cell:13:17: note: this 'continue' is reached before 'v' is assigned again`.
- `break :outer while moved reaches the code after the OUTER loop` FAILS: no diagnostic at all (the move is lost into the inner frame and revived by `v = "b"`, which ran as a double free).
- `break :outer's state skips the inner loop's after-loop point` FAILS with `t.cell:16:14: error: use of 'v' after it was moved`.
- `a labelled skip-revival break is recorded against the loop it names` FAILS at the `after_loop_skip` expectation.
- `continue :outer after moving a place declared before the outer loop is refused` and `an unconditional move then continue :outer ...` PASS already (the inner frame reports the same spans); they pin that the change keeps refusing.
Confirm all six names appear.

- [ ] **Step 3: Give each frame its label and resolve a jump to its target frame**

In `src/cell/borrowck/model.zig`, replace the doc comment above `pub const LoopFrame = struct {` and add the `label` field as the struct's FIRST field:

```zig
/// One `while` whose body is being walked. A plain `break` or `continue`
/// targets the innermost `while`; a labelled one targets the innermost frame
/// carrying its label (SPEC 7.7). Either way ONLY the target frame is
/// consulted: control on that path never reaches the back edge or the
/// after-loop point of a loop in between. See `checkWhile` and `jumpTarget`.
pub const LoopFrame = struct {
    /// The loop's label, null when none was written.
    label: ?[]const u8 = null,
```

and extend the `breaks` field's doc to:

```zig
    /// The address of every `break` that leaves THIS loop (not a nested
    /// one), including a `break :label` naming this loop from inside a
    /// nested one, for the skip-revival rule in `checkWhile`.
```

In `src/cell/borrowck/stmts.zig`, `checkWhile`, add `.label = w.label,` as the first initializer of the `self.loop_frames.append(self.allocator, .{ ... })` call.

Replace `checkContinue` (doc comment and head through its `const frame = ...` line) with the following, keeping the rest of its body unchanged:

```zig
/// The frame a jump targets: the innermost for a plain jump, the innermost
/// frame carrying `label` otherwise. Null outside a loop and for a label no
/// enclosing loop carries: typecheck refuses both, and this checker runs
/// independently of it, so neither may crash here. The pointer is into
/// `loop_frames` and stays valid until the next push, which no caller makes
/// while holding it.
pub fn jumpTarget(self: *Checker, label: ?[]const u8) ?*LoopFrame {
    const frames = self.loop_frames.items;
    if (frames.len == 0) return null;
    const name = label orelse return &frames[frames.len - 1];
    var i = frames.len;
    while (i > 0) {
        i -= 1;
        const l = frames[i].label orelse continue;
        if (std.mem.eql(u8, l, name)) return &frames[i];
    }
    return null;
}

/// R2.a at a `continue`: the jump reaches the next iteration of its TARGET
/// loop, so every move that frame carries is a use-after-move there,
/// exactly as it would be at the end of that loop's body. The body end
/// never sees this path when a revival follows the `continue`. A
/// `continue :outer` asks the outer frame only: a place declared inside
/// the outer body is not carried by it (the next outer iteration declares
/// it afresh), and the inner loops it leaves never reach their back edge.
pub fn checkContinue(self: *Checker, span: Span, label: ?[]const u8) Error!void {
    const frame = self.jumpTarget(label) orelse return;
```

Replace `saveBreakState` (doc comment and head through its `const frame = ...` line) with the following, keeping the rest unchanged:

```zig
/// A `break` leaves its TARGET loop in the state it was taken in, which
/// the body end never sees when a revival follows it. Every outer dead
/// entry is kept, including one already dead on entry: the `break` path
/// also skips a later revival of that one. A `break :outer` saves into the
/// outer frame only; the loops in between never reach their after-loop
/// point on this path.
pub fn saveBreakState(self: *Checker, label: ?[]const u8) Error!void {
    const frame = self.jumpTarget(label) orelse return;
```

In `checkStmtKind`, replace the `.break_stmt` and `.continue_stmt` prongs with:

```zig
        .break_stmt => |j| {
            try self.saveBreakState(j.label);
            if (self.jumpTarget(j.label)) |frame| {
                try frame.breaks.append(self.allocator, @intFromPtr(stmt));
            }
            try self.recordExit(.jump, @intFromPtr(stmt));
        },
        .continue_stmt => |j| {
            try self.checkContinue(stmt.span, j.label);
            try self.recordExit(.jump, @intFromPtr(stmt));
        },
```

In `src/cell/borrowck.zig`, `Checker`, add after `pub const saveBreakState = bk_stmts.saveBreakState;`:

```zig
    pub const jumpTarget = bk_stmts.jumpTarget;
```

and in the module header, extend the R2.a paragraph's last sentence (the one ending "was enumerated and a property of all of them asserted.") with:

```zig
//! was enumerated and a property of all of them asserted. A labelled jump
//! (`break :outer`, `continue :outer`, 2026-09-22) is asked of the loop it
//! TARGETS and of no loop in between (`jumpTarget`): control on that path
//! reaches neither the back edge nor the after-loop point of an inner loop.
```

Consequences that stay deliberately conservative (leak direction, not double free): the inner loop's `collectSkipRevival` meets a dead `.jump` record whose key is not in its own `breaks` and clears its skip set; its `afterLoopHolds` sees the same record and grants no `after_loop`; `loop_moved` still poisons an outer-body local moved inside the inner loop. None of these needs code.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig test src/root.zig --test-filter "outer" > /tmp/flow03-t4.log 2>&1; echo "exit $?"; grep -E 'tests_loops|passed|failed' /tmp/flow03-t4.log` and `zig test src/root.zig --test-filter "labelled skip-revival" > /tmp/flow03-t4b.log 2>&1; echo "exit $?"; grep -E 'OK|passed' /tmp/flow03-t4b.log`
Expected: both `exit 0`; `...OK` after all six new test names (the unconditional one matches "outer" too) and after every pre-existing `tests_loops` test the filter catches. Confirm the named tests appear.

- [ ] **Step 5: Run the sweep and the gate**

Run: `tools/sweep-backends.sh > /tmp/flow03-sweep-4.log 2>&1; echo "sweep exit $?"; tail -1 /tmp/flow03-sweep-4.log`
Expected: `sweep exit 0` and `... programs probed, 0 issue(s)`.

Run: `tools/check.sh > /tmp/flow03-gate-4.log 2>&1; echo "gate exit $?"; grep -E 'All [0-9]+ tests passed' /tmp/flow03-gate-4.log; sed -n '/^== verdict ==/,$p' /tmp/flow03-gate-4.log`
Expected: `gate exit 0`, verdict `clean` (or SKIP-only); stage 11 (rule lists) stays green (no R-token changed). Record the test count.

- [ ] **Step 6: Commit**

```bash
git add src/cell/borrowck/model.zig src/cell/borrowck/stmts.zig src/cell/borrowck.zig src/cell/borrowck/tests_loops.zig
git commit -m "feat(borrowck): a labelled jump is asked of its target loop only

LoopFrame carries its label and jumpTarget resolves a jump to the frame
it names. break :outer saves its state into and is recorded against the
outer frame; continue :outer asks R2.a of the outer frame (spec invariant
14). continue :outer after moving a place declared inside the outer body
is accepted; declared before the outer loop it is refused.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: C lowers a labelled jump as a `goto` at the target's mark; lift the temporary refusal

**Files:**
- Modify (in src/cell/codegen.zig or its split successor under src/cell/codegen/): `Generator` fields `loop_marks` (doc), new `loop_jumps`, new `next_loop_label`; `emitStmt` (`while_stmt`, `break_stmt`, `continue_stmt` prongs); `emitLoopExitDrops`; new `jumpTarget`, new `emitJump`; `skipLabelFor`; new struct `LoopJump` beside `SkipLabel`
- Modify: `src/cell/typecheck.zig` (delete Task 2's temporary branch and test)
- Test: the codegen test file (today the end of `src/cell/codegen.zig`; after the split, whichever `src/cell/codegen/*.zig` holds `test "a temporary owned String scrutinee is released once on every path out"`), `src/cell/typecheck.zig`

**Interfaces:**
- Consumes: Task 2's `ast.Jump.label`, `while_stmt.label`; Task 4's `Checker.skipBreakLoop` returning the TARGET loop's key for a labelled break.
- Produces:
  - `const LoopJump = struct { label: ?[]const u8, id: usize, brk_used: bool = false, cont_used: bool = false }` (make it `pub const` if `SkipLabel` is `pub` in `helpers.zig`, and import it into the file declaring `Generator` the same way `SkipLabel` is imported)
  - `Generator.loop_jumps: std.ArrayList(LoopJump) = .empty`, pushed and popped with `loop_marks`; `Generator.next_loop_label: usize = 0`
  - `fn emitLoopExitDrops(self: *Generator, key: Exit, target: usize, indent: usize) EmitError!void`
  - `fn jumpTarget(self: *const Generator, label: ?[]const u8) ?usize`
  - `fn emitJump(self: *Generator, stmt: *const ast.Stmt, label: ?[]const u8, kind: enum { brk, cont }, indent: usize) EmitError!void`
  - C shapes: `goto cell_brk_<n>;` / `cell_brk_<n>:;` after the loop's `}` and before `emitAfterLoopDrops`; `goto cell_cont_<n>;` / `cell_cont_<n>:;` at the end of the loop's own block, after an extra `{ }` holding the body; unknown label (unchecked input) `goto cell_no_loop_labelled_<name>;`.

**Two decisions this task implements, both measured while building the plan.** (1) A C label is written only when a `goto` to it was actually emitted (`brk_used`/`cont_used`, set by `emitJump`), not decided by pre-scanning the body: `-Wall -Wextra -Werror` (stage 9 and `expectCompiles`) makes an unused label an error (`error: unused label 'l' [-Werror,-Wunused-label]`), and a pre-scan wrote `cell_brk_<n>:;` for a loop whose only labelled break was a skip-revival break redirected to `cell_skip_<n>`. (2) Every labelled loop's body is emitted inside one extra `{ }`, because that block must open before the body is emitted, when it is not yet known whether a `continue :label` will need it; unlabelled loops keep their C byte for byte.

- [ ] **Step 1: Write the failing codegen tests**

Append to the codegen test file:

```zig
test "break :outer releases every local since the outer body opened, once, then jumps past the loop" {
    // Spec invariant 13: `a` (outer body) and `b` (inner body) are both
    // released on the jump, exactly once, and the label sits after the outer
    // loop, before anything that runs after it.
    var e = try emitSource(
        \\pub fn str_from_int(copy v: Int) -> String;
        \\pub fn str_len(shared s: String) -> Int;
        \\pub fn f(copy i: Int) -> Int {
        \\  var n = 0
        \\  outer: loop {
        \\    let owned a = str_from_int(i)
        \\    var j = 0
        \\    while j < 3 {
        \\      let owned b = str_from_int(j)
        \\      n = n + str_len(a) + str_len(b)
        \\      if j == 1 {
        \\        break :outer
        \\      }
        \\      j = j + 1
        \\    }
        \\  }
        \\  return n
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "goto cell_brk_0;", 1);
    try expectLineBefore(f, "goto cell_brk_0;", "cell_string_free(&a);");
    // Each is released twice in the text: once on the jump and once at its
    // own body's end (a different path). Innermost first on the jump.
    try expectOccurrences(f, "cell_string_free(&b);", 2);
    try expectOccurrences(f, "cell_string_free(&a);", 2);
    try expectBefore(f, "cell_string_free(&b);", "cell_string_free(&a);");
    try expectOccurrences(f, "cell_brk_0:;", 1);
    try expectBefore(f, "cell_brk_0:;", "return n;");
    try expectAbsent(f, "cell_cont_");
    try expectCompiles(e.text);
}

test "continue :outer releases the same locals and lands outside the block holding the body" {
    var e = try emitSource(
        \\pub fn str_from_int(copy v: Int) -> String;
        \\pub fn str_len(shared s: String) -> Int;
        \\pub fn g(copy i: Int) -> Int {
        \\  var n = 0
        \\  var k = 0
        \\  outer: while k < 2 {
        \\    k = k + 1
        \\    let owned a = str_from_int(i)
        \\    var j = 0
        \\    while j < 3 {
        \\      let owned b = str_from_int(j)
        \\      n = n + str_len(a) + str_len(b)
        \\      j = j + 1
        \\      if j == 2 {
        \\        continue :outer
        \\      }
        \\    }
        \\  }
        \\  return n
        \\}
    );
    defer e.deinit();
    const g = try fnDef(e.text, "g");
    try expectOccurrences(g, "goto cell_cont_0;", 1);
    try expectLineBefore(g, "goto cell_cont_0;", "cell_string_free(&a);");
    // The label follows the block that closes the body's scope, so the jump
    // crosses no declaration; and the loop's own `}` follows the label.
    try expectLineBefore(g, "cell_cont_0:;", "}");
    try expectAbsent(g, "cell_brk_");
    try expectCompiles(e.text);
}

test "a labelled jump releases an untaken owning temporary of the loop it leaves" {
    // `emitTempReleases(target + 1)`: the match scrutinee is made in the
    // outer body (loop depth 1), so `break :outer` (target 0) releases it,
    // while a plain `break` of the inner loop would have released only
    // temporaries of depth 2 and leaked it.
    var e = try emitSource(
        \\pub fn str_from_int(copy v: Int) -> String;
        \\pub fn t(copy n: Int) -> Int {
        \\  var i = 0
        \\  outer: while i < n {
        \\    i = i + 1
        \\    match str_from_int(i) {
        \\      "3" => {
        \\        while true {
        \\          break :outer
        \\        }
        \\      },
        \\      _ => {},
        \\    }
        \\  }
        \\  return i
        \\}
    );
    defer e.deinit();
    const t = try fnDef(e.text, "t");
    try expectLineBefore(t, "goto cell_brk_0;", "cell_string_free(&_cell_t0);");
    try expectCompiles(e.text);
}

test "a labelled jump that names the innermost loop is a plain break, and no C label is written" {
    // -Wall makes an unused label an error, so a labelled loop nobody
    // leaves from a nested loop must not get one.
    var e = try emitSource(
        \\pub fn u(copy n: Int) {
        \\  var i = 0
        \\  here: loop {
        \\    i = i + 1
        \\    if i > n {
        \\      break :here
        \\    }
        \\    continue :here
        \\  }
        \\}
    );
    defer e.deinit();
    const u = try fnDef(e.text, "u");
    try expectOccurrences(u, "break;", 1);
    try expectOccurrences(u, "continue;", 1);
    try expectAbsent(u, "cell_brk_");
    try expectAbsent(u, "cell_cont_");
    try expectAbsent(u, "goto");
    try expectCompiles(e.text);
}

test "a skip-revival break :outer jumps past the outer loop's release, and writes no unused label" {
    // borrowck records the labelled break against the OUTER loop, whose skip
    // label is not the top of `skip_labels` at the jump; `skipLabelFor`
    // finds it by loop key. The `goto cell_brk_` the jump would otherwise
    // take is never emitted, so `cell_brk_0:;` must not be either.
    var e = try emitSource(
        \\pub fn take(owned s: String) { }
        \\pub fn s(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  outer: while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    while i > n {
        \\      break :outer
        \\    }
        \\    v = "b"
        \\  }
        \\}
    );
    defer e.deinit();
    const s = try fnDef(e.text, "s");
    try expectOccurrences(s, "goto cell_skip_0;", 1);
    try expectLineBefore(s, "cell_skip_0:;", "cell_string_free(&v);");
    try expectAbsent(s, "cell_brk_");
    try expectCompiles(e.text);
}

test "an unknown label emits a goto cc refuses, never a guess at a loop" {
    // Unchecked input (emitSource runs no typecheck). Spec invariant 16.
    var e = try emitSource(
        \\pub fn f() {
        \\  loop {
        \\    break :nowhere
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "goto cell_no_loop_labelled_nowhere;");
    try expectAbsent(f, "break;");
}
```

- [ ] **Step 2: Flip the typecheck test from refusal to acceptance**

In `src/cell/typecheck.zig`, delete the test `TEMPORARY: a labelled jump out of a nested loop is refused until it is lowered` and append:

```zig
test "a labelled jump names an enclosing loop, from any depth" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(copy n: Int) {
        \\    outer: while n > 0 {
        \\        inner: loop {
        \\            if n > 1 {
        \\                break :outer
        \\            }
        \\            continue :inner
        \\        }
        \\    }
        \\    again: loop {
        \\        break :again
        \\    }
        \\}
    );
    try t.expectClean();
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `zig test src/root.zig --test-filter "outer" > /tmp/flow03-t5.log 2>&1; echo "exit $?"; grep -E 'codegen.test|FAIL|passed|failed' /tmp/flow03-t5.log` and `zig test src/root.zig --test-filter "from any depth" > /tmp/flow03-t5b.log 2>&1; echo "exit $?"; grep -E 'leaves a nested|FAIL|OK' /tmp/flow03-t5b.log`
Expected: both non-zero. The codegen tests fail because the C still emits `break;`/`continue;` for a labelled jump (`goto cell_brk_0;` not found; only `b` released at the jump). The typecheck test prints `5:17: error: 'break :outer' leaves a nested loop, which is not lowered yet` and fails with `TestUnexpectedDiagnosticCount`. Confirm the names appear.

- [ ] **Step 4: Add the loop-jump stack to `Generator`**

Locate the pieces first: `grep -rn 'loop_marks:\|const SkipLabel\|fn emitLoopExitDrops\|fn skipLabelFor\|\.break_stmt =>' src/cell/codegen.zig src/cell/codegen/`.

Beside `SkipLabel`, add:

```zig
/// One enclosing loop as `emitJump` sees it: its label (null when none was
/// written), the number its C labels carry, and whether a jump from a
/// nested loop has already been emitted as `goto cell_brk_<id>` or
/// `goto cell_cont_<id>`. A C label is written only when its flag is set,
/// because `-Wall` makes an unused label an error, and a labelled jump at
/// the loop's own level (a plain `break`/`continue`) or a skip-revival
/// `break` (`goto cell_skip_<n>`) uses neither.
const LoopJump = struct {
    label: ?[]const u8,
    id: usize,
    brk_used: bool = false,
    cont_used: bool = false,
};
```

In `Generator`, change the last sentence of the `loop_marks` doc comment from "`emitLoopExitDrops` reads the top of this stack." to "`emitLoopExitDrops` reads the entry of the loop the jump TARGETS, which a labelled jump may place below the top." and add directly after the `loop_marks` field:

```zig
    /// One entry per `loop_marks` entry, pushed and popped with it: the
    /// loop's label (null when none was written) and the number its C labels
    /// carry. A labelled jump resolves against this to an index `t`, then
    /// drops since `loop_marks[t]`; see `emitJump`.
    loop_jumps: std.ArrayList(LoopJump) = .empty,
    /// The next labelled loop's number, unique within the translation unit,
    /// so `cell_brk_<n>` and `cell_cont_<n>` never collide across functions.
    next_loop_label: usize = 0,
```

- [ ] **Step 5: Emit labelled loops and jumps**

In `emitStmt`'s `.while_stmt` prong, replace everything from `try self.writeIndent(indent);` / `try out.writeAll("while (");` through the `try out.writeAll("}\n");` that closes the loop (keep the skip-label setup above it and the `emitAfterLoopDrops` / skip-label tail below it) with:

```zig
                // A labelled loop's body goes inside one extra block, so a
                // `continue :label` from a nested loop can land on
                // `cell_cont_<n>:;` OUTSIDE the scope of every body local and
                // cross no declaration. Unlabelled loops keep their C byte
                // for byte.
                var label_id: usize = 0;
                if (w.label != null) {
                    label_id = self.next_loop_label;
                    self.next_loop_label += 1;
                }
                try self.writeIndent(indent);
                try out.writeAll("while (");
                try self.emitCond(&w.cond, indent);
                try out.writeAll(") {\n");
                const body_indent = if (w.label != null) indent + 8 else indent + 4;
                if (w.label != null) {
                    try self.writeIndent(indent + 4);
                    try out.writeAll("{\n");
                }
                try self.loop_marks.append(self.arena, self.locals.items.len);
                try self.loop_jumps.append(self.arena, .{ .label = w.label, .id = label_id });
                try self.loop_bodies.append(self.arena, w.body);
                try self.emitStmts(w.body, body_indent);
                _ = self.loop_bodies.pop();
                const jumps = self.loop_jumps.pop().?;
                _ = self.loop_marks.pop();
                if (w.label != null) {
                    try self.writeIndent(indent + 4);
                    try out.writeAll("}\n");
                }
                if (jumps.cont_used) {
                    try self.writeIndent(indent + 4);
                    try out.print("cell_cont_{d}:;\n", .{label_id});
                }
                try self.writeIndent(indent);
                try out.writeAll("}\n");
                // `break :label` from a nested loop lands here: after the
                // loop and before its after-loop releases, exactly where a
                // plain `break` of this loop lands.
                if (jumps.brk_used) {
                    try self.writeIndent(indent);
                    try out.print("cell_brk_{d}:;\n", .{label_id});
                }
```

Replace the `.break_stmt` and `.continue_stmt` prongs with:

```zig
            .break_stmt => |j| try self.emitJump(stmt, j.label, .brk, indent),
            .continue_stmt => |j| try self.emitJump(stmt, j.label, .cont, indent),
```

Replace `emitLoopExitDrops` (with its doc comment) by the following three functions:

```zig
    /// The `break`/`continue` drop point: everything declared since the
    /// TARGET loop's body opened (`loop_marks[target]`), which includes the
    /// locals of every nested loop, block, `if` branch and arm body the jump
    /// sits inside, and nothing declared outside the target. Temporaries
    /// are released from depth `target + 1`, because a temporary's
    /// `loop_depth` is `loop_marks.len` when it was made: one created in the
    /// target's body has depth `target + 1` or more. A plain jump passes the
    /// innermost index, `len - 1`, which is exactly what this did before
    /// labels. Out of range is defensive: typecheck refuses a jump outside a
    /// loop.
    fn emitLoopExitDrops(self: *Generator, key: Exit, target: usize, indent: usize) EmitError!void {
        if (target >= self.loop_marks.items.len) return;
        const mark = self.loop_marks.items[target];
        const saved = self.drop_exit;
        self.drop_exit = key;
        defer self.drop_exit = saved;
        try self.emitDropsSince(mark, indent, key);
        // Temporaries created inside the loop this jump leaves.
        try self.emitTempReleases(target + 1, indent);
    }

    /// The loop a jump targets, as an index into `loop_marks`/`loop_jumps`:
    /// the innermost for a plain jump, the innermost loop carrying `label`
    /// otherwise. Null outside a loop, or for a label no enclosing loop
    /// carries; typecheck refuses both, so only an unchecked module gets here.
    fn jumpTarget(self: *const Generator, label: ?[]const u8) ?usize {
        const n = self.loop_jumps.items.len;
        if (n == 0) return null;
        const name = label orelse return n - 1;
        var i = n;
        while (i > 0) {
            i -= 1;
            const l = self.loop_jumps.items[i].label orelse continue;
            if (eq(l, name)) return i;
        }
        return null;
    }

    /// `break`, `continue`, `break :label` and `continue :label`. The drops
    /// are the target loop's (`emitLoopExitDrops`), then the jump itself:
    /// a plain `break`/`continue` when the target is the innermost loop, so
    /// every unlabelled program's C is unchanged; `goto cell_brk_<n>` or
    /// `goto cell_cont_<n>` when it is an outer one, marking that loop's
    /// `LoopJump` so the label gets written; `goto cell_skip_<n>` for a
    /// skip-revival `break` of any loop (`skipLabelFor`).
    fn emitJump(
        self: *Generator,
        stmt: *const ast.Stmt,
        label: ?[]const u8,
        kind: enum { brk, cont },
        indent: usize,
    ) EmitError!void {
        const out = self.writer;
        const word = if (kind == .brk) "break" else "continue";
        const target = self.jumpTarget(label) orelse {
            // Unchecked input only. A plain jump outside a loop keeps its old
            // spelling, which `cc` refuses; an unknown label becomes a `goto`
            // to a label that does not exist, which `cc` also refuses. Neither
            // guesses a loop (spec invariant 16).
            try self.writeIndent(indent);
            if (label) |l| {
                try out.print("goto cell_no_loop_labelled_{s};\n", .{l});
            } else {
                try out.print("{s};\n", .{word});
            }
            return;
        };
        try self.emitLoopExitDrops(.{ .kind = .jump, .key = @intFromPtr(stmt) }, target, indent);
        try self.writeIndent(indent);
        if (kind == .brk) {
            if (self.skipLabelFor(@intFromPtr(stmt))) |id| {
                try out.print("goto cell_skip_{d};\n", .{id});
                return;
            }
        }
        if (target + 1 == self.loop_jumps.items.len) {
            try out.print("{s};\n", .{word});
            return;
        }
        const loop = &self.loop_jumps.items[target];
        switch (kind) {
            .brk => loop.brk_used = true,
            .cont => loop.cont_used = true,
        }
        try out.print("goto cell_{s}_{d};\n", .{ if (kind == .brk) "brk" else "cont", loop.id });
    }
```

Replace `skipLabelFor` (with its doc comment) by:

```zig
    /// The label a skip-revival `break` jumps to, or null for a plain
    /// `break`. Searched by the loop borrowck recorded, not read off the
    /// top: a `break :outer` from inside a nested loop is recorded against
    /// the outer loop (`LoopFrame.breaks`), whose entry is not the top.
    fn skipLabelFor(self: *const Generator, break_key: usize) ?usize {
        const checker = self.checker orelse return null;
        const loop_key = checker.skipBreakLoop(break_key) orelse return null;
        var i = self.skip_labels.items.len;
        while (i > 0) {
            i -= 1;
            const sl = self.skip_labels.items[i];
            if (sl.loop_key == loop_key) return sl.id;
        }
        return null;
    }
```

If `emitJump` ends up in a different file from `eq` after the split, import `eq` the way its neighbours do (`grep -n 'const eq' src/cell/codegen*.zig src/cell/codegen/*.zig`).

- [ ] **Step 6: Delete the temporary refusal**

In `src/cell/typecheck.zig`, `checkStmt`, replace the labelled-jump branch with:

```zig
                } else if (j.label) |name| {
                    if (self.loopLabelIndex(name) == null) {
                        try self.errf(stmt.span, "no enclosing loop is labelled '{s}'", .{name});
                    }
                }
```

Run: `grep -n 'not lowered yet\|TEMPORARY' src/cell/typecheck.zig; echo "grep exit $?"`
Expected: no output and `grep exit 1`.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `zig build -Dswift=false > /tmp/flow03-build.log 2>&1; echo "build exit $?"; zig test src/root.zig --test-filter "label" > /tmp/flow03-t5.log 2>&1; echo "exit $?"; grep -E 'codegen.test|typecheck.test|passed|failed' /tmp/flow03-t5.log; zig test src/root.zig --test-filter "outer" > /tmp/flow03-t5c.log 2>&1; echo "exit $?"; grep -E 'codegen.test|passed|failed' /tmp/flow03-t5c.log`
Expected: `build exit 0` and both `exit 0`; `...OK` after each of the six codegen test names from Step 1 and after `a labelled jump names an enclosing loop, from any depth`. Confirm the named tests appear.

Then drive the Task 3 program end to end now that `cell check` accepts it: write the `find`/`rows` program from Task 3 Step 3 (the llvmemit test source) to `/tmp/flow03-labels-probe.cell`, run `.claude/skills/run-cell-lang/driver.sh --no-build --expect 218 /tmp/flow03-labels-probe.cell` and expect `ok` for C, LLVM and MLIR and `clean`.

- [ ] **Step 8: Run the sweep and the gate**

Run: `tools/sweep-backends.sh > /tmp/flow03-sweep-5.log 2>&1; echo "sweep exit $?"; tail -1 /tmp/flow03-sweep-5.log`
Expected: `sweep exit 0` and `0 issue(s)`.

Run: `tools/check.sh > /tmp/flow03-gate-5.log 2>&1; echo "gate exit $?"; grep -E 'All [0-9]+ tests passed' /tmp/flow03-gate-5.log; sed -n '/^== verdict ==/,$p' /tmp/flow03-gate-5.log`
Expected: `gate exit 0`, verdict `clean` (or SKIP-only). Every unlabelled example's C is unchanged, so every existing leak pin holds. Record the test count.

- [ ] **Step 9: Commit**

```bash
git add src/cell/typecheck.zig src/cell/codegen.zig src/cell/codegen/
git commit -m "feat(codegen): labelled jumps drop to the target's mark and goto it

emitJump resolves a jump against loop_jumps, releases every local and
untaken temporary since the TARGET loop's mark (emitLoopExitDrops with
target and target + 1), then emits a plain break or continue for the
innermost loop, goto cell_brk_<n> after the target loop, or goto
cell_cont_<n> after the extra block holding its body. A label is written
only when a goto used it. skipLabelFor searches by loop key. The
temporary typecheck refusal of nested labelled jumps is gone.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

(`git add src/cell/codegen/` only if the codegen edits landed in split files; check `git status --short` first and add exactly the files you changed.)

---

### Task 6: Examples, leak fixtures and gate pins

**Files:**
- Create: `examples/labels.cell`, `examples/rejected/labelled_continue_move.cell`, `examples/leaks/labelled_break.cell`, `examples/leaks/labelled_continue.cell`
- Modify: `tools/check.sh` (stage 6 list; `LEAK_*` constants block; stage 7 `run_c_leaks`/`run_ir_leaks` rows)
- Modify: `examples/README.md`, `examples/leaks/README.md`

**Interfaces:**
- Consumes: everything above; `run_c_leaks` (`ex host want note [src]`, two witnesses, `leaks -atExit` and the malloc counter) and `run_ir_leaks` (`ex backend want note [src] [host]`, one witness) in `tools/check.sh` stage 7.
- Produces: `LEAK_LABELLED_BREAK_C=0`, `LEAK_LABELLED_BREAK_LLVM`, `LEAK_LABELLED_BREAK_MLIR`, `LEAK_LABELLED_CONTINUE_C=0`, `LEAK_LABELLED_CONTINUE_LLVM`, `LEAK_LABELLED_CONTINUE_MLIR`.

- [ ] **Step 1: Add the labels example and its rejected twin**

Create `examples/labels.cell`:

```cell
// Labelled loops (SPEC 7.7, D-F2 ruled 2026-09-21): `name: while c { }` or
// `name: loop { }`, and `break :name` / `continue :name` from anywhere inside
// it, including from inside a nested loop. The spelling is Zig's.
//
// All three backends print 227:
//   cell emit               examples/labels.cell   -> C
//   cell emit --target=llvm examples/labels.cell   -> LLVM IR
//   cell emit --target=mlir examples/labels.cell   -> MLIR
//
// 227 = 206 (find_pair) + 12 (count_rows) + 9 (moved_then_continue).

pub fn print_int(copy value: Int);
pub fn str_from_int(copy v: Int) -> String;
pub fn str_len(shared s: String) -> Int;

pub fn take(owned s: String) -> Int {
    return str_len(s)
}

/// `break :outer` leaves both loops at once. The first pair whose product is
/// `target` is 2 * 6, so this returns 206.
pub fn find_pair(copy target: Int) -> Int {
    var found = 0
    var i = 0
    outer: while i < 10 {
        i = i + 1
        var j = 0
        while j < 10 {
            j = j + 1
            if i * j == target {
                found = i * 100 + j
                break :outer
            }
        }
    }
    return found
}

/// `continue :outer` skips the rest of the outer body, so `rows + 1000`
/// never runs. Each of the `n` outer iterations adds 1 + 2, so this
/// returns 12 for n = 4.
pub fn count_rows(copy n: Int) -> Int {
    var rows = 0
    var i = 0
    outer: while i < n {
        i = i + 1
        var j = 0
        while j < n {
            j = j + 1
            rows = rows + j
            if j == 2 {
                continue :outer
            }
        }
        rows = rows + 1000
    }
    return rows
}

/// `loop` with a label, a labelled `break` that names the innermost loop
/// (a plain `break` in every backend), and the case docs/OWNERSHIP.md R2.a
/// accepts: `v` is declared inside the outer body, so `continue :outer`
/// after moving it is fine, because the next outer iteration declares a
/// fresh `v`. R2.a asks only the loop a jump targets. Each of the three
/// outer iterations adds 1 and then `take`s a two-digit string, so this
/// returns 9.
pub fn moved_then_continue() -> Int {
    var total = 0
    var i = 0
    outer: loop {
        i = i + 1
        if i > 3 {
            break :outer
        }
        let owned v = str_from_int(i * 10)
        var j = 0
        while j < 5 {
            j = j + 1
            if j == 2 {
                total = total + take(v)
                continue :outer
            }
            total = total + j
        }
    }
    return total
}

// EXPECT-OUTPUT: 227
pub fn main() {
    print_int(find_pair(copy 12) + count_rows(copy 4) + moved_then_continue())
}
```

Create `examples/rejected/labelled_continue_move.cell`:

```cell
// EXPECT: currently-rejected
// Violates: docs/OWNERSHIP.md R2.a, asked of the loop a labelled jump
// TARGETS (spec invariant 14).
//
// `v` is declared before `outer`, moved inside the inner loop, and then
// `continue :outer` starts the next OUTER iteration, which would use `v`
// after the move. R2.a asks the outer frame, and the outer frame carries `v`:
//
//   error: 'v' is moved inside a loop, so the next iteration would use it
//          after the move
//   note: this 'continue' is reached before 'v' is assigned again
//
// Its accepted twin is `moved_then_continue` in examples/labels.cell: there
// `v` is declared INSIDE the outer body, the next outer iteration declares a
// fresh one, and the same jump is fine. Asking every frame the jump passes
// would refuse that twin too, because the inner frame carries `v`. The text
// is pinned by the borrowck test "R2.a: continue :outer after moving a place
// declared before the outer loop is refused".

pub fn take(owned s: String) { }

pub fn main() {
    var owned v: String = "a"
    var i = 0
    outer: while i < 3 {
        i = i + 1
        var j = 0
        while j < 3 {
            j = j + 1
            if j == 2 {
                take(v)
                continue :outer
            }
        }
        v = "b"
    }
}
```

Run: `.claude/skills/run-cell-lang/driver.sh --no-build --expect 227 examples/labels.cell; ./zig-out/bin/cell check examples/rejected/labelled_continue_move.cell; echo "rejected exit $?"`
Expected: `ok    C    -> 227`, `ok    LLVM -> 227`, `ok    MLIR -> 227`, `clean`; then `examples/rejected/labelled_continue_move.cell:31:22: error: 'v' is moved inside a loop, ...`, `...:32:17: note: this 'continue' is reached before 'v' is assigned again`, `rejected exit 1`.

Also compile the C under the stage 9 flags and ASan by hand once: `./zig-out/bin/cell emit examples/labels.cell > /tmp/flow03-labels.c && cc -std=c11 -Wall -Wextra -Werror -fsanitize=address -I runtime /tmp/flow03-labels.c runtime/cell_rt.c -o /tmp/flow03-labels && /tmp/flow03-labels; echo "asan exit $?"` → prints `227`, `asan exit 0`.

- [ ] **Step 2: Add the two leak fixtures**

Create `examples/leaks/labelled_break.cell`:

```cell
// FLOW-03 (2026-09-22): `break :outer` taken from inside a nested loop must
// release, exactly once, every owning local declared since the OUTER loop's
// body opened: here `a` (outer body) and `b` (inner body), and nothing
// declared outside the outer loop (spec invariant 13). Three owned Strings
// per call (`a`, then `b` for j = 0 and j = 1), 1000 calls.
//
// Pinned: C 0 on both witnesses; this is a requirement, not a measurement,
// and a nonzero C count means the labelled jump dropped too little. LLVM and
// MLIR are pinned at their measured count on the malloc counter (the only
// witness an IR build carries, see tools/check.sh): they have no drop pass.
// Those two IR pins join the default-target flip criterion (spec
// 2026-09-21-mod02-flow03-ir-first-design.md, Rulings): `--target` flips to
// LLVM only when every LLVM/MLIR leak pin in gate stage 7 reads 0.
//
// Status: parses, passes `cell check`; C, LLVM and MLIR; lives under
// examples/leaks/.

pub fn print_int(copy value: Int);
pub fn str_from_int(copy v: Int) -> String;
pub fn str_len(shared s: String) -> Int;

pub fn once(copy i: Int) -> Int {
    var n = 0
    outer: loop {
        let owned a = str_from_int(i)
        var j = 0
        while j < 3 {
            let owned b = str_from_int(j)
            n = n + str_len(a) + str_len(b)
            if j == 1 {
                break :outer
            }
            j = j + 1
        }
    }
    return n
}

pub fn main() {
    var i = 0
    var n = 0
    while i < 1000 {
        n = n + once(i)
        i = i + 1
    }
    print_int(n)
}
```

Create `examples/leaks/labelled_continue.cell`:

```cell
// FLOW-03 (2026-09-22): `continue :outer` taken from inside a nested loop must
// release, exactly once, every owning local declared since the OUTER loop's
// body opened: here `a` (outer body) and `b` (inner body), and nothing
// declared outside the outer loop (spec invariant 13). The C lowering jumps
// to `cell_cont_<n>:;`, outside the block holding the outer body, so the
// jump crosses no declaration. Three owned Strings per outer iteration (`a`,
// then `b` for j = 0 and j = 1), two outer iterations per call, 1000 calls.
//
// Pinned: C 0 on both witnesses; this is a requirement, not a measurement,
// and a nonzero C count means the labelled jump dropped too little. LLVM and
// MLIR are pinned at their measured count on the malloc counter (the only
// witness an IR build carries, see tools/check.sh): they have no drop pass.
// Those two IR pins join the default-target flip criterion (spec
// 2026-09-21-mod02-flow03-ir-first-design.md, Rulings): `--target` flips to
// LLVM only when every LLVM/MLIR leak pin in gate stage 7 reads 0.
//
// Status: parses, passes `cell check`; C, LLVM and MLIR; lives under
// examples/leaks/.

pub fn print_int(copy value: Int);
pub fn str_from_int(copy v: Int) -> String;
pub fn str_len(shared s: String) -> Int;

pub fn once(copy i: Int) -> Int {
    var n = 0
    var k = 0
    outer: while k < 2 {
        k = k + 1
        let owned a = str_from_int(i)
        var j = 0
        while j < 3 {
            let owned b = str_from_int(j)
            n = n + str_len(a) + str_len(b)
            j = j + 1
            if j == 2 {
                continue :outer
            }
        }
    }
    return n
}

pub fn main() {
    var i = 0
    var n = 0
    while i < 1000 {
        n = n + once(i)
        i = i + 1
    }
    print_int(n)
}
```

Run: `for f in labelled_break labelled_continue; do .claude/skills/run-cell-lang/driver.sh --no-build examples/leaks/$f.cell; done`
Expected: `labelled_break` prints `7780` on C, LLVM and MLIR; `labelled_continue` prints `15560` on all three (these files carry no `EXPECT-OUTPUT`: `examples/leaks/` is invisible to stage 8; the numbers only prove the three backends agree before the counts are measured). Stage 4's leak-fixture loop requires LLVM and MLIR to both accept them, which they do.

- [ ] **Step 3: Pin the counts in the gate**

In `tools/check.sh`, after `LEAK_FIELD_REVIVAL=0` (the last constant of the leak block), add:

```sh
# FLOW-03 labelled jumps (2026-09-22): `break :outer` and `continue :outer`
# from inside a nested loop, each crossing an owning local in the outer body
# and one in the inner. C must release both on the jump: 0 is a requirement
# (spec invariant 13). The IR rows are the backends' measured counts, one
# witness, and join the default-target flip criterion (every LLVM/MLIR pin
# at 0), because the IR has no drop pass yet.
LEAK_LABELLED_BREAK_C=0
LEAK_LABELLED_BREAK_LLVM=3000
LEAK_LABELLED_BREAK_MLIR=3000
LEAK_LABELLED_CONTINUE_C=0
LEAK_LABELLED_CONTINUE_LLVM=6000
LEAK_LABELLED_CONTINUE_MLIR=6000
```

The IR values are the measurement taken while writing this plan (every owned String those backends allocate: 3 per call and 6 per call, 1000 calls). If your first run reads different IR numbers, do not copy the plan: stop, find out why, and pin what the gate measures only once it is explained (a lower number means an IR drop pass partly landed; a higher one is a regression). The C values are not measurements and may not be changed.

In stage 7, after the `run_ir_leaks owned_string mlir ...` row and before the closing `fi`, add:

```sh
    run_c_leaks labelled_break "" "$LEAK_LABELLED_BREAK_C" "FLOW-03 break :outer releases the outer and inner bodies' locals, 2026-09-22"
    run_ir_leaks labelled_break llvm "$LEAK_LABELLED_BREAK_LLVM" "FLOW-03 break :outer; no IR drop pass; joins the flip criterion, 2026-09-22"
    run_ir_leaks labelled_break mlir "$LEAK_LABELLED_BREAK_MLIR" "FLOW-03 break :outer; no IR drop pass; joins the flip criterion, 2026-09-22"
    run_c_leaks labelled_continue "" "$LEAK_LABELLED_CONTINUE_C" "FLOW-03 continue :outer releases the outer and inner bodies' locals, 2026-09-22"
    run_ir_leaks labelled_continue llvm "$LEAK_LABELLED_CONTINUE_LLVM" "FLOW-03 continue :outer; no IR drop pass; joins the flip criterion, 2026-09-22"
    run_ir_leaks labelled_continue mlir "$LEAK_LABELLED_CONTINUE_MLIR" "FLOW-03 continue :outer; no IR drop pass; joins the flip criterion, 2026-09-22"
```

In stage 6, extend the list from Task 1:

```sh
for pair in "hello 42" "backends 24" "loops 55" "loop 21" "labels 227"; do
```

- [ ] **Step 4: Update the example indexes**

In `examples/README.md`, add after the `loops.cell` row of the top-level table:

```markdown
| `labels.cell` | labelled loops, `break :outer` and `continue :outer` from a nested loop, and the R2.a case a labelled `continue` accepts (SPEC 7.7); prints 227 through all three backends |
```

and, for Task 1's example (Task 1 did not touch this file):

```markdown
| `loop.cell` | `loop { }`, which is exactly `while true { }` (SPEC 7.6); prints 21 through all three backends |
```

and, directly before the paragraph that starts "`skip_revival_jump.cell` carries R2.a's jump clause":

```markdown
`unknown_label.cell` and `duplicate_label.cell` pin SPEC 7.7's two label
refusals (a label no enclosing loop carries, and a label repeating an
enclosing loop's), and `labelled_continue_move.cell` pins R2.a asked of the
loop a `continue :outer` targets (2026-09-22); its accepted twin is
`moved_then_continue` in `examples/labels.cell`.
```

In `examples/leaks/README.md`, replace the opening count sentence "Thirty-one fixtures, twenty-nine measured on the C backend and two IR backend pins (below)." with (recount first: `ls examples/leaks/*.cell | wc -l` must print 33; if it does not, write the number it prints):

```markdown
Thirty-three fixtures: twenty-nine measured on the C backend only, two IR
backend pins, and two FLOW-03 labelled-jump fixtures measured on all three
backends (both below).
```

and in the "IR backend pins" table add, after the `ir_string_conversion.cell` row:

```markdown
| `labelled_break.cell` | FLOW-03: `break :outer` from a nested loop crossing an owning local in each body; C releases both on the jump, 0 on both witnesses (a requirement, spec invariant 13); LLVM and MLIR 3000 (2026-09-22) |
| `labelled_continue.cell` | FLOW-03: `continue :outer` from a nested loop, the same shape; C 0 on both witnesses; LLVM and MLIR 6000 (2026-09-22) |

Every LLVM/MLIR pin here is part of the default-target flip criterion
(`docs/superpowers/specs/2026-09-21-mod02-flow03-ir-first-design.md`,
Rulings): `--target` flips from C to LLVM only when all of them read 0.
```

- [ ] **Step 5: Run the gate**

Run: `tools/check.sh > /tmp/flow03-gate-6.log 2>&1; echo "gate exit $?"; grep -E 'All [0-9]+ tests passed|labelled|labels|  loop ' /tmp/flow03-gate-6.log; sed -n '/^== verdict ==/,$p' /tmp/flow03-gate-6.log`
Expected (measured on the prototype): `gate exit 0`; stage 6 `ok    C    labels -> 227` and the LLVM and MLIR rows; stage 7 `ok    leaks labelled_break -> 0 leaks, counter LIVE=0`, `ok    ir leaks labelled_break (llvm) -> counter LIVE=3000`, `(mlir) -> counter LIVE=3000`, `ok    leaks labelled_continue -> 0 leaks, counter LIVE=0`, `ok    ir leaks labelled_continue (llvm) -> counter LIVE=6000`, `(mlir) -> counter LIVE=6000`; stage 8 `labels  C/LLVM/MLIR -> 227` and `loop  C/LLVM/MLIR -> 21`; stage 9 (ASan, `-Wall -Wextra -Werror`) green; verdict `clean` (or SKIP-only). A stage 7 SKIP for missing `leaks` or `mlir-opt` makes the run weaker: say so.

- [ ] **Step 6: Commit**

```bash
git add examples/labels.cell examples/rejected/labelled_continue_move.cell examples/leaks/labelled_break.cell examples/leaks/labelled_continue.cell tools/check.sh examples/README.md examples/leaks/README.md
git commit -m "test(examples): labelled loops print 227 on all three backends; leak pins

examples/labels.cell carries break :outer, continue :outer, a labelled
loop and the R2.a case a labelled continue accepts; its refused twin is
examples/rejected/labelled_continue_move.cell. The labelled_break and
labelled_continue leak fixtures pin C at 0 on both witnesses and LLVM and
MLIR at 3000 and 6000, which join the default-target flip criterion.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Specification, feature matrix and ownership docs

**Files:**
- Modify: `docs/SPEC.md` (sections 2.5, 7.6, 7.7, and the section 12 status index)
- Modify: `docs/FEATURES.md` (the FLOW-03 row)
- Modify: `docs/OWNERSHIP.md` (R2.a, the paragraph beginning "Only the innermost loop is consulted")

**Interfaces:**
- Consumes: the behaviour pinned by Tasks 1 to 6; the numbers 21, 227, 3000, 6000.
- Produces: no code. `sh tools/check-rule-lists.sh` (gate stage 11) must stay green after each edit.

- [ ] **Step 1: Rewrite SPEC 2.5's status paragraph**

In `docs/SPEC.md` section 2.5, replace

```markdown
**Status: implemented.** These lex as keywords as of the union stage recorded
in 0.8. None of them has a parser rule yet, which is the point: using one as a
name is now a parse error rather than a silent misreading.
```

with

```markdown
**Status: implemented.** These lex as keywords as of the union stage recorded
in 0.8. `while`, `break`, `continue` (section 7.6, 7.7) and, since 2026-09-22,
`loop` have parser rules; the rest have none, which is the point: using one as
a name is a parse error rather than a silent misreading.
```

- [ ] **Step 2: Rewrite SPEC 7.6 for `loop`**

Replace the section's status line and grammar block

```markdown
**Status: implemented (`while`). `for` and `loop` are designed, not
implemented.**

```
while_stmt = "while" expr_no_struct_lit block
```
```

with

```markdown
**Status: implemented (`while`, and `loop` since 2026-09-22). `for` is
designed, not implemented, and deferred by ruling (D-F4).**

```
loop_stmt  = [ label ":" ] ( while_stmt | loop )
while_stmt = "while" expr_no_struct_lit block
loop       = "loop" block
```

`loop { B }` means exactly `while true { B }` (ruled 2026-09-21, D-F1). It is
a statement, like `while`, and there is no `break` with a value. The parser
builds the same node for both, with a `true` condition spanning the `loop`
keyword, so no checker or backend can treat them differently: the C, LLVM IR
and MLIR they emit are byte-identical (pinned in `src/root.zig`).
`examples/loop.cell` prints 21 through all three backends. Like `while true`,
a `loop` whose body always `return`s still needs a `return` after it in a
function declared to return a value: the missing-return check does not reason
about loops.
```

and in the paragraph that begins "`for`, `loop`, and iteration over a collection remain designed.", change those words to "`for` and iteration over a collection remain designed." (leave the rest of that paragraph as it is).

- [ ] **Step 3: Rewrite SPEC 7.7 for labels**

Replace the heading `### 7.7 \`break\` and \`continue\`` and everything after it up to, not including, the paragraph that begins **Both carry an ownership rule**, with:

```markdown
### 7.7 `break`, `continue` and labels

**Status: implemented; labels since 2026-09-22 (D-F2), on all three
backends.**

```
break_stmt    = "break" [ ":" label ]
continue_stmt = "continue" [ ":" label ]
label         = ident
```

A plain `break` or `continue` applies to the innermost enclosing loop. A loop
may carry a label, written Zig's way before `while` or `loop`
(`outer: while c { }`, `outer: loop { }`), and `break :outer` /
`continue :outer` then apply to the innermost enclosing loop with that label,
from any depth inside it. `examples/labels.cell` prints 227 through all three
backends. Using either jump outside a loop, naming a label no enclosing loop
carries, or repeating a label an enclosing loop already has, is an error
reported by the typechecker, so the diagnostic points at Cell source rather
than at emitted code:

> `err: 'break' is only valid inside a loop`
> `err: no enclosing loop is labelled 'outr'`
> `err: label 'outer' is already used by an enclosing loop`
> `note: the enclosing loop labelled 'outer' is here`

Sibling loops may reuse a label, because neither encloses the other, and a
label nothing jumps to is allowed. A loop's condition is checked before its
body is entered, so a jump inside the condition belongs to the loop around
it, not to the loop the condition controls. Neither jump carries a value, and
labelled blocks (`blk: { .. break :blk v }`) are not part of the language.

**How a labelled jump is lowered.** `hir.lower` resolves the label once, to
the number of loops the jump leaves beyond the innermost (0 is a plain jump),
and every IR consumer indexes its loop stack with it: the CFG adds its edge to
the target loop's exit or condition, and LLVM and MLIR branch to the target's
end or condition block. The C backend releases every owning local declared
since the TARGET loop's body opened, and every untaken owning temporary made
inside it, then jumps: `goto cell_brk_<n>` lands right after that loop, before
anything that runs after it, and `goto cell_cont_<n>` lands at the end of the
loop's own block, outside the block that holds its body, so the jump crosses
no declaration. A labelled jump that names the innermost loop is a plain
`break` or `continue`. The leak fixtures `examples/leaks/labelled_break.cell`
and `labelled_continue.cell` pin C at 0 on both witnesses; LLVM and MLIR free
nothing yet (no IR drop pass), and their pins join the default-target flip
criterion.
```

Then, in the ownership paragraph that follows, replace

```markdown
**Both carry an ownership rule** (`docs/OWNERSHIP.md` R2.a, jump clause,
2026-09-16). A `continue` reached while a place declared outside the loop is
moved and not yet revived is refused, because the next iteration would use
it after the move:
```

with

```markdown
**Both carry an ownership rule** (`docs/OWNERSHIP.md` R2.a, jump clause,
2026-09-16), asked of the loop the jump TARGETS and of no loop in between
(2026-09-22). A `continue` reached while a place declared outside its target
loop is moved and not yet revived is refused, because the next iteration of
that loop would use it after the move:
```

and "A `break` taken in that state is accepted, but the place is dead after the loop, so a later use" with "A `break` taken in that state is accepted, but the place is dead after its target loop, so a later use".

- [ ] **Step 4: Update the section 12 status index**

In the Lexical table, replace the reserved-words row with these two rows:

```markdown
| Reserved words that are lexed and NOT implemented (`for`, `async`, `await`, `defer`, `impl`, `trait`, ...) | designed, not implemented |
| `loop` | implemented 2026-09-22: parses as `while true` (7.6) |
```

In the statements table, add directly after the `| Loops and \`break\` / \`continue\` | ... |` row (a historical row; leave it):

```markdown
| `loop`, loop labels, `break :label` / `continue :label` | implemented 2026-09-22 on all three backends (7.6, 7.7) |
```

- [ ] **Step 5: Update the FLOW-03 row and OWNERSHIP R2.a**

In `docs/FEATURES.md`, replace the FLOW-03 row with:

```markdown
| FLOW-03 for/loop/labels/defer | partial | partial | partial | partial | `loop` (exactly `while true`) and Zig-style labels (`outer: while`, `outer: loop`, `break :outer`, `continue :outer`) since 2026-09-22 on all three backends, resolved once in HIR; unknown and repeated labels refused by typecheck; R2.a asked of the target loop only. C releases every local a labelled jump leaves (leak fixtures `labelled_break`, `labelled_continue` pinned at 0); LLVM/MLIR free none (pins 3000 and 6000, part of the default-target flip criterion). `for` and `defer` stay reserved, deferred by ruling (D-F3, D-F4) | [loop](../examples/loop.cell), [labels](../examples/labels.cell), [unknown label](../examples/rejected/unknown_label.cell), [labelled continue move](../examples/rejected/labelled_continue_move.cell) | M4/M5 |
```

In `docs/OWNERSHIP.md`, R2.a, replace the paragraph

```markdown
Only the innermost loop is consulted, since a jump targets the innermost
`while` (SPEC 7.7). An inner loop's `break` state reaches the outer body
through the inner loop's own union, so a skip-revival `break` in an inner loop
is refused at the outer body end. Corpus:
`examples/rejected/skip_revival_jump.cell`, which carries the measurements.
```

with

```markdown
Only the loop a jump TARGETS is consulted: the innermost `while` for a plain
jump, the loop it names for `break :outer` or `continue :outer` (SPEC 7.7,
2026-09-22). No loop in between is asked, because control on that path never
reaches its back edge or its after-loop point. So `continue :outer` after
moving a place declared inside the outer body is accepted (the next outer
iteration declares it afresh; `examples/labels.cell`, `moved_then_continue`),
and the same jump after moving a place declared before the outer loop is
refused (`examples/rejected/labelled_continue_move.cell`). A `break :outer`
taken while a place is moved leaves it dead after the OUTER loop, and not
after the inner one. An inner loop's plain `break` state reaches the outer
body through the inner loop's own union, so a skip-revival `break` in an inner
loop is refused at the outer body end. Corpus:
`examples/rejected/skip_revival_jump.cell`, which carries the measurements.
```

- [ ] **Step 6: Check the docs and run the gate**

Run: `sh tools/check-rule-lists.sh; echo "rule lists exit $?"; git diff HEAD~7 -- docs examples src tools | grep '^+' | grep -c "$(printf '\342\200\224')"`
Expected: `ok    every document mentions every enforced rule`, `rule lists exit 0`, and an em dash count of `0` over every line this plan added (adjust `HEAD~7` to the commit before Task 1 if other commits landed in between).

Run: `tools/check.sh > /tmp/flow03-gate-7.log 2>&1; echo "gate exit $?"; grep -E 'All [0-9]+ tests passed' /tmp/flow03-gate-7.log; sed -n '/^== verdict ==/,$p' /tmp/flow03-gate-7.log`
Expected: `gate exit 0`, verdict `clean` (or SKIP-only). Record the final test count; the prototype read `All 731 tests passed.` against a base of 701 (the base moves, so quote your own).

- [ ] **Step 7: Commit**

```bash
git add docs/SPEC.md docs/FEATURES.md docs/OWNERSHIP.md
git commit -m "docs: loop and loop labels in SPEC 2.5, 7.6, 7.7, FEATURES FLOW-03, R2.a

SPEC 7.7 replaces \"labelled loops are not designed\" with the design as
built: grammar, the three typecheck refusals, target-only R2.a, and the
HIR depth and C goto lowering. FLOW-03 reads partial on every layer with
for and defer deferred; OWNERSHIP R2.a says a labelled jump asks its
target loop only.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage.**
- D-F1 `loop` = `while true`, statement, no break-with-value: Task 1 (parser, invariant 15 test across C/LLVM/MLIR and CFG, `examples/loop.cell`, stage 6 row, lexer comment).
- D-F2 Zig-style labels, parser two-token peek, `while_stmt.label`, `Jump.label`: Task 2.
- typecheck `loop_depth` becomes a label stack; unknown and duplicate labels; siblings may reuse: Task 2 (tests and `examples/rejected/unknown_label.cell`, `duplicate_label.cell`).
- HIR resolves once to `brk: u32`/`cont: u32`; unresolved is `cannot lower`: Task 3.
- `cfg.Builder.lowerJump` indexes `len - 1 - n`; `liveness.Walker` asserts `loop_depth > n` and stays in lockstep (`GraphMismatch`): Task 3.
- llvmemit and mlirmit singletons become stacks: Task 3, with run tests printing 218.
- borrowck target frame only (`saveBreakState`, `breaks`, `checkContinue`), accepted and refused `continue :outer` cases: Task 4; `examples/rejected/labelled_continue_move.cell` and `labels.cell`'s `moved_then_continue`: Task 6.
- C `goto` at the target's mark: `emitDropsSince(target_mark)`, `emitTempReleases(target + 1)`, `cell_brk_<n>` before `emitAfterLoopDrops`, `cell_cont_<n>` outside the body block, innermost target emits plain jumps, `skipLabelFor` by `loop_key`: Task 5.
- Invariant 13: Task 5 codegen tests and Task 6 leak fixtures (C 0 on both witnesses). Invariant 14: Task 4. Invariant 15: Task 1. Invariant 16: Task 2 (refusals), Task 3 (`cannot lower`), Task 5 (C `goto cell_no_loop_labelled_<name>`), and Task 2's temporary refusal keeps it true at every intermediate commit.
- Error handling wording for labels: Tasks 2 and 7.
- Testing section: parser/typecheck (Task 2), cfg/liveness (Task 3), emitter text tests (`goto` in Task 5; LLVM label text in Task 3), corpus `examples/loop.cell` and `examples/labels.cell` with `EXPECT-OUTPUT` on all three backends (Tasks 1, 6), rejected cases (Tasks 2, 6), leak fixtures with IR pins that join the flip criterion (Task 6).
- Slice 1 and slice 2 of "Slices, in order", including "SPEC 7.7 rewritten": Tasks 1 to 7; each ends with `tools/check.sh` exit 0, `driver.sh --expect` on each new example, pins only falling (new pins only), and `sweep-backends.sh` at 0 after the ownership-lowering tasks (4, 5).

**Placeholder scan.** No TBD, TODO or "similar to Task N"; every code step carries its code. The one value the executor must confirm rather than copy is each IR leak pin, and Task 6 Step 3 states the measured value and what a different reading means.

**Type consistency.** `parseLoop(start)` (Task 1) becomes `parseLoop(start, label)` (Task 2), both call sites updated in Task 2. `ast.Jump.label: ?[]const u8` is read as `j.label` in typecheck, HIR, borrowck and codegen. `hir.Stmt.Kind.brk/cont: u32` is consumed by `lowerJump(kind, depth: u32)`, `Walker.jump(depth: u32)` and `loopTarget(depth: u32)`. `Checker.jumpTarget(label) ?*LoopFrame` (borrowck) and `Generator.jumpTarget(label) ?usize` (codegen) are distinct methods on distinct types. `emitLoopExitDrops(key, target, indent)` has one caller, `emitJump`. `LoopJump.brk_used`/`cont_used` are set in `emitJump` and read after `loop_jumps.pop()` in the `while_stmt` prong.

## Spec gaps and decisions this plan makes

1. **The spec's `(main.cell:2:1)` in the duplicate-label message** would render `(:2:1)`: typecheck's bag has no path set by `root.check`. The plan uses the per-file convention instead, an error at the repeated label plus a `note` at the enclosing loop (Task 2).
2. **`-Wunused-label`.** The spec places `cell_brk_<n>`/`cell_cont_<n>` unconditionally; `-Wall -Wextra -Werror` refuses an unused label, and a skip-revival `break :outer` never uses `cell_brk_<n>`. Labels are written only when a `goto` to them was emitted, and every labelled loop's body gets the extra `{ }` (Task 5).
3. **An unconditional `take(v); continue :outer` inside the inner loop** (not inside an `if` arm) is refused by the INNER loop's body-end R2.a, because statements after a jump are still walked, as `take(v); break` is refused today. The spec's accepted case is accepted only in the `if j == 2 { take(v); continue :outer }` shape. Pinned by a Task 4 test as conservative, not fixed.
4. **Intermediate commits.** Between Task 2 and Task 5 typecheck refuses a labelled jump out of a nested loop, so no commit lets a backend emit a plain `break` for it.
5. **Temporary release depth** for a labelled jump is `target + 1`, not the spec's "`emitTempReleases(target_depth)`" if read as the stack index (Task 5 test pins it).
6. **Unused labels are allowed** (no warning); the spec is silent. Stated in SPEC 7.7.
7. **C has no diagnostic channel**, so an unresolved label in unchecked input emits `goto cell_no_loop_labelled_<name>;`, which `cc` refuses, satisfying invariant 16 for C.
8. **Stage 8 alone cannot prove "all three backends"**: it runs only the backends that emit, and stage 4 passes when LLVM and MLIR both refuse. `loop 21` and `labels 227` are also stage 6 rows (Tasks 1, 6).
9. **`loop { return x }` in a `-> Int` function still needs a trailing `return`**, exactly as `while true` does; unchanged by design and documented (Task 7).
10. **Out of scope, noted only:** SPEC 7.6 still says Cell has "no indexing operator", stale since indexing landed (TYPE-04); `loop_moved` poisoning leaks an outer-body owned local moved in an inner loop on the path where the inner loop exits normally (conservative, pre-existing).
