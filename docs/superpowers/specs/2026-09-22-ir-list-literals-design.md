# IR String step (d): list literals in the LLVM and MLIR backends

Status: **approved by Donald 2026-09-22 with its recommendations**; nothing
implemented yet. Q6 and Q7 are moot: F1 landed as `392a8e4` and C's inferred
`[String]` element (F2) as `04f645b`. **F3 is ruled fix, not pin:** a call
temporary (this document's `sum([i, 2, 3])`, and C's `unbound_list_temp`)
gets a temporaries drop slice on all three backends, so neither stays a
nonzero pin blocking the default `--target` flip.

Direction: steps (a) to (d) as approved 2026-09-17, and the 2026-09-21
ruling that `.cell -> HIR -> LLVM IR / MLIR` is primary, C only where needed,
the default `--target` flipping to LLVM when every LLVM/MLIR pin in stage 7
reads 0. Step (a) landed (`4aca38b`). Steps (b) (approved 2026-09-21) and (c)
(rulings 2026-09-21: DropFacts, shadowed drops, inline per-field record
drops) are NOT implemented at the measured commit. This document assumes (b)
lands first; open question 8 covers the other order.

Measured 2026-09-22 in `git archive bbe3b13` exports
(`/private/tmp/claude-501/stepd-export`, prototyped; `stepd-orig`, pristine;
probes in `stepd-probe/`, session scratch). The checkout reached `b004f70`
while this was drafted, 16 borrowck and codegen split commits later;
`git diff --stat bbe3b13 b004f70` is empty for `hir.zig`, both emitters,
`abi.zig`, `runtime/` and `tools/check.sh`. Anchors are `bbe3b13`'s; C and
borrowck functions are cited by name because both files are being split.

**Every design claim below was tested by a prototype.** About 60 lines went
into the exported `hir.zig`; no emitter line changed. The prototype has none
of the tests or refusals this spec requires and is not a patch to apply.
With it, `tools/check.sh` on the prototyped export exited 0 with verdict
`clean` (all 15 stages; stage 4 printed "llvm and mlir agree on every
example and leak fixture"), and every stage 7 pin held.

## Where things stand

- **Both IR emitters refuse every non-empty list literal, once per literal.**
  Probe `p1.cell` (`let owned xs: [Int] = [1, 2, 3]` and
  `let owned bs: [Byte] = [a, a, a]`; `cell check` says ok):

  ```
  p1.cell:5:27: error: cannot lower to LLVM IR: a non-empty list literal is not lowered to LLVM IR yet
  p1.cell:5:27: error: cannot lower to MLIR: a non-empty list literal is not lowered to MLIR yet
  ```

  (and the pair at 7:28), from the `.list_lit` arms of `llvmemit.zig` (:988)
  and `mlirmit.zig` (:1009). Both build `[]` inline as `{null, 0, 0}`.
  **No test pins either message:** with the prototype, `zig build test
  -Dswift=false` stayed green (287 runtime checks plus all Zig tests).
- **`hir.zig` (:970) lowers a literal tolerantly and ignores the
  destination.** It lowers each element with `lowerExpr` (no `expected`) and
  types the list by its FIRST element, `[unknown]` when empty.
- **C builds the list in a statement expression** (`codegen.zig`
  `emitListLit`). For `[1, 2, 3]`:

  ```c
  cell_slice_t xs = ({
    cell_slice_t _cell_t0 = cell_slice_alloc(sizeof(int64_t), 3);
    int64_t _cell_t1 = (int64_t){0};
    _cell_t1 = 1;
    (void)cell_slice_push(&_cell_t0, sizeof(int64_t), &_cell_t1);
    /* 2 and 3 the same way */ _cell_t0; });
  /* ... */ cell_slice_free(&xs);
  ```

  The element C type is the declared one when `emitArgLike` or a value slot
  hands it down (`want_elem`), else `inferExpr` of the first item. The push
  result is discarded (F4). Elements run left to right, one statement each:
  `[next(), next(), next()]` with a counting host reads back `123`.
- **Runtime (`cell_rt.h` section 3):** one type-erased 24-byte
  `cell_slice_t {ptr, len, cap}`; `cell_slice_alloc(elem_size, cap)` (:230),
  `cell_slice_push(s, elem_size, const void *)` (:236, `bool`, grows 4, 8,
  16), `cell_slice_free` (:242). The only typed builder is `cell_bytes_push`
  (:630), which panics on OOM. The typed readers `cell_list_*_at` exist.
- **`abi.layoutOf` (`abi.zig`:86) lays out every `[T]` as 24 bytes, whatever
  the element**, and returns null for `arc [T]` (:36, `f4cc32e`). So the IR
  never validates an element type through the ABI; the element selector in
  HIR is the only guard (risk 2).
- **The checker forces scalar literals to agree with the destination**
  (`typecheck.zig`:399, first element, all compatible). Measured refusals:
  `[Byte] = [7, 9]` and `[Int32] = [1, 2]` ("cannot initialize a binding of
  type [Byte] with a value of type [Int]"), `[Float] = [1.5, 2]` ("list
  element has type Int, expected Float"). For a checked scalar literal the
  first element's type IS the declared one.
- **borrowck's `.list_lit` arm** (`borrowck.zig`:2496 at `bbe3b13`,
  `borrowck/expr.zig`:186 at `b004f70`) already refuses an `arc` element (R10)
  and a resource-owning place as an element (R2.b); scalars are plain reads.

## Design

### 1. No new HIR node: a literal desugars to a value block

`hir.lower`'s `.list_lit` arm (inside `lowerExprIn`, so `expected` is in
hand) turns a non-empty `[e0, ..., en]` of element type `T` into:

```
{ let $list: owned [T] = [];      // new scratch slot, empty header
  $rt.<push_T>(exclusive $list, e0)
  ...
  $rt.<push_T>(exclusive $list, en)
  $list }                          // tail: the block's value, own = .owned
```

- **Element type.** `T` is `expected`'s element if it is a known list
  element, else the first lowered element's type; each element is lowered
  with `lowerExprIn(el, T)`. If both exist and differ, refuse (the checker
  makes that unreachable, so it guards lowering tests that skip `check`).
- **Pushes go through step (a)'s runtime table** (`Lowerer.runtimeCall`,
  `resolveRuntime`), one entry per element type, built by one comptime
  helper (`pushEntry` in the prototype):

  | `Runtime` tag | `name` | Cell signature | Symbol |
  |---|---|---|---|
  | `bytes_push` | `$rt.bytes_push` | `(exclusive xs: [Byte], copy value: Byte)` | `cell_bytes_push` (exists) |
  | `list_i64_push` | `$rt.list_i64_push` | `(exclusive xs: [Int], copy value: Int)` | `cell_list_i64_push` (new) |
  | `list_i32_push` | `$rt.list_i32_push` | `(exclusive xs: [Int32], copy value: Int32)` | `cell_list_i32_push` (new) |
  | `list_f64_push` | `$rt.list_f64_push` | `(exclusive xs: [Float], copy value: Float)` | `cell_list_f64_push` (new) |
  | `list_bool_push` | `$rt.list_bool_push` | `(exclusive xs: [Bool], copy value: Bool)` | `cell_list_bool_push` (new) |

  The five elements are exactly step (b)'s readable set, so everything an IR
  literal can build, IR code can read back.
- **Why not `cell_slice_push`.** The table types parameters as Cell `Ty`s,
  and Cell has no `void *` or `size_t`; per-type entries sharing one symbol
  would give it several signatures, which `resolveRuntime` refuses.
- **New runtime:** a `CELL_LIST_PUSH(fn, T)` macro beside `CELL_LIST_AT`,
  the `cell_bytes_push` body (push, `cell_panic` on failure), declared next
  to the readers. No `src/main.zig` `extern fn` change; stage 12 gets them
  through the `@embedFile`d runtime.
- **Allocation shape differs from C; the counts do not.** C allocates
  exactly `n` once; the IR grows from the empty header. The malloc counter
  counts `realloc(NULL)` as one allocation and other reallocs as none, so
  ALLOC and LIVE match C per literal (measured: ALLOC 1000 for 1000
  three-element literals, hand-desugared and prototyped).
- **Emitters change only their refusal text**, which becomes a backstop
  like step (a)'s `fits`: "a non-empty list literal reached the emitter;
  hir.lower desugars every one it accepts".
- **Empty `[]` keeps its shape** but under a typed `expected` now types
  `[T]`, not `[unknown]` (a behavior change; the gate stayed green).

### 2. Evaluation order

Source order, each element evaluated just before its own push, as C's
statement expression does; the `[next(), next(), next()]` probe reads `123`
on all three backends. Unlike step (b)'s risk 6, C sequences each element in
its own statement, so there is no order divergence to keep out of the corpus.

### 3. Element ownership

- **Scalars (`Byte`, `Int`, `Int32`, `Float`, `Bool`) are copied** into the
  buffer (`copy value`). The literal owns only the buffer.
- **Every other element stays refused**, `[String]` included ("cannot
  lower: a list literal whose element has no runtime push"). Measured
  reasons: C never releases `[String]` elements (`["ab", "c"]` and
  `[mks(), mks()]` bound `owned [String]` each leak 2000 per 1000 calls,
  both witnesses); unannotated, C builds 16-byte views (F2), so there is no
  C reference representation; and step (b) cannot read one back. Owning
  elements (R1: convert views through `convertTo(el, t_string, .owned)`,
  release elements in the drop) are open question 3.

### 4. Interaction with step (c)

- **The IR frees no list today, and step (c) as drafted will not either.**
  Its slice 1 admits only `stringRep == .owning` Strings and records. So a
  literal bound to an owned local leaks its buffer on both IR backends, and
  this step pins that rather than claiming otherwise (stage 7 table below).
- **`$list` must never be dropped.** Its tail is a bitwise copy of the
  header that flows into the destination; freeing `$list` as well would be a
  double free. Step (c) plans `Binding.droppable` (false for scratch slots)
  but its row "true for `let` and `var` bindings" would admit `$list`, which
  IS a `let`. This step adds `Binding.droppable: bool = true` now, sets it
  false for `$list`, and pins that with a hir test, so step (c) inherits the
  fact instead of rediscovering it. The same step sets it false for binding
  patterns and payload bindings (the `bindings.append` sites at `hir.zig`
  1288, 1323, 1372), three one-word edits that close the window in which a
  pattern binding reads as droppable.
- **`$list` has no AST counterpart, so it must not consume a borrowck id.**
  Step (c) ports C's id-numbering agreement onto HIR (positive confirmation
  through `DropFacts`). If that correlation counts `let`s, `$list` shifts
  every later binding in the function by one, confirmation fails on each,
  and every later owned local silently leaks: fail toward a leak still
  holds, but the stage 7 pin would read as "step (c) did not work". Rule:
  step (c)'s correlation skips `droppable = false` slots, and `hir.lower`,
  which is walking the AST when it makes the slot, assigns it no id.
- **Every literal lands in one owner:** a `let`/`var`, an `owned` argument
  (measured 0 on all three through a freeing host), a `return`, or an
  assignment (the old value is step (c)'s pre-drop row). The exception is a
  `shared` argument, an unbound temporary C leaks too (F3).
- **What closes the pin.** One new step (c) row, "unmoved `owned` `[scalar]`
  local or parameter: `cell_slice_free(exclusive x)`", mechanically the
  String row with a different callee. `cell_slice_free` is element-erased,
  so it needs either one table entry typed `(exclusive xs: [unknown])`, which
  `sameType` accepts (tag `.list`, `unknown` compatible), or one free per
  element type. Open question 5.

### 5. Invariants

1. `hir.lower` emits no non-empty `.list_lit`; each is a `.block` whose first
   statement is `let $list = []` and whose tail is `.ref $list`.
2. The push callee is chosen by the element `Ty` and is the one whose reader
   step (b) chose for the same `Ty`, so a list is written and read with the
   same stride.
3. `$list` is `owned`, `mutable`, not a parameter, `droppable = false`,
   carries no borrowck id, and is never entered in the name scope.
4. Each push is declared once per module; a matching user declaration (e.g.
   `examples/prelude.cell`'s `bytes_push`) is reused, a conflicting one refused.
5. Elements are evaluated once each, in source order, before the tail.
6. A refused literal yields exactly one diagnostic, and the refused node is
   an empty typed literal, so no emitter diagnostic follows it.

## Findings outside this step, measured while grounding it

- **F1. A silent LLVM miscompile: a `Byte` argument lacks `zeroext`.**
  `llvmemit.zig`:313 marks only `.boolean` parameters `zeroext`; clang
  declares `i8 noundef zeroext` for `uint8_t`, and Apple arm64 has the caller
  extend sub-32-bit arguments. Reproducer `z.cell`: `is7(a + c)` with
  `a: Byte = 250`, `c: Byte = 13`, host `cell_is7(uint8_t b)` built `-O2`.
  C prints 1; LLVM at the gate's `-O0` prints **0**, and 1 with `zeroext`
  hand-added (or at `-O2`). MLIR prints 1, but its lowered declaration also
  lacks `zeroext`, so that is `llc` instruction selection, not an attribute.
  Stage 10's header names `zeroext` as a blind spot ("not at all for `i8`");
  this is its first measured wrong answer. Non-blocking here
  (`cell_bytes_push` stores only the low byte; `[Byte]` rows read back
  correctly on all three). Its own commit, before step (d) (question 6).
- **F2. A silent C miscompile: an unannotated `[String]` literal of string
  literals.** `let owned ss = ["ab", "c"]` passes `cell check`; C infers
  `cell_str_t` from the first element and allocates 16-byte views
  (`cell_slice_alloc(sizeof(cell_str_t), 2)`), while `shared [String]` means
  owning 24-byte elements (R1). A host summing `.len` prints 275655268304
  where the annotated twin prints 3000 per 1000 calls. This is step (b)'s
  risk 5 live in C, on the inferred path `emitListLit` still keeps. The IR
  refuses the literal (section 3). Fix is C-side (infer an owning element
  and convert, as the declared path does) and out of this step.
- **F3. C leaks a list literal passed straight to a `shared` parameter.**
  `sum([i, 2, 3])`: 1000 per 1000 calls on both witnesses, and 1000 on both
  IR backends (hand-desugared). Same class as the pinned
  `unbound_list_temp` (2000), different shape.
- **F4. C ignores `cell_slice_push`'s failure** (`(void)cell_slice_push` in
  every `emitListLit` expansion), so an allocation failure mid-literal
  builds a shorter list silently. From reading the emitted C; not measured
  (it needs OOM injection). The IR pushes panic, as `cell_bytes_push` does.

## What stays refused

| Form | Refused by | Why |
|---|---|---|
| `[String]`, `[[T]]`, `[T?]`, records, enums, `Int8`/`UInt*`/`Float32` elements | `hir.lower` (one diagnostic) | no push, no reader; owning elements are open question 3 |
| `arc` element | borrowck R10 (`.list_lit` arm) | make-unique position |
| a resource-owning place as an element | borrowck R2.b | the source keeps its header |
| `arc [T]` destination | `abi.layoutOf` null (`f4cc32e`) | no retain/release in IR |
| `[Byte] = [7, 9]`, `[Int32] = [1, 2]` | checker | literals type as `[Int]`; destination typing is out of scope |

## Testing and gate

- **hir tests** (beside step (a)'s and (b)'s):
  - each element type lowers to a `.block`: one `let` of `[]`, n `.call`s
    to the right `symbol`, a `.ref` tail typed `[T]`, `own = .owned`; one
    `origin = .runtime` `Fn` per push however many literals use it;
  - `$list` has `droppable = false`; ordinary `let`s have `true`;
  - the element type comes from `expected` when present, from the first
    element otherwise, and a disagreement (lowered without `check`) refuses;
  - `[String]`, `[[Int]]` and `[Int8]` literals refuse with exactly one
    diagnostic and no emitter diagnostic after it;
  - a matching `bytes_push` declaration is reused; an `owned xs` spelling is
    refused.
- **llvmemit / mlirmit tests:**
  - pin the five `declare` lines as the prototype emits them:
    `declare void @cell_bytes_push(ptr, i8)` (with `zeroext` once F1 lands),
    `@cell_list_i64_push(ptr, i64)`, `(ptr, i32)`, `(ptr, double)`,
    `(ptr, i1 zeroext)`, and their `func.func private` MLIR twins;
  - the reworded backstop, reached by handing an emitter a hand-built HIR
    `.list_lit`;
  - one hostless run each: `[Byte]` through `bytes_len`, and (after step (b))
    `[Int]` indexed through `list_i64_at`.
- **Runtime harness** (`runtime/tests/test_cell_rt.c`): each new push
  appends, grows past 4, and preserves earlier elements.
- **Corpus example `examples/ir_list_literal.cell`, hostless after (b)** (a
  plan, not prototyped: `p4.cell` read its lists through a host):
  all five element types in a `let`, an unannotated `let`, a reassigned
  `var`, a `-> [Int]` return, an `owned` argument and a `while` body, with
  a counter making order visible. It declares the four new pushes as bodyless
  Cell functions (as `examples/prelude.cell` does `bytes_push`), because
  stage 10's C leg sees only what the emitted C declares or calls, and C's
  `emitListLit` calls `cell_slice_push`. `EXPECT-OUTPUT` computed on C first.
  The prototype's `p4.cell` printed 27212310 on all three (and on both IR
  legs under an ASan runtime and host); the loop probe printed `210 211 212`.
- **Gate:**
  - Stage 4: `ir_list_literal` accepted by both. `index.cell` stays refused
    until its last refusal goes (see commit 7). In the leak loop,
    `reassigned_owned_var` and `revived_var` flip from refused to accepted
    on BOTH IR backends (measured), which stage 4 checks only for agreement.
  - Stages 5, 6 (C/LLVM/MLIR rows), 8 (`EXPECT-OUTPUT`), 9 (C under ASan;
    run the IR legs under ASan by hand), 10 (five push comparisons per IR
    leg, zero new pins; never add one to pass).
- **Leak pins (stage 7). Prototype measurements, 1000 iterations; not pins,
  re-measure on the implementing commit:**

  | Fixture | C `leaks` / LIVE | LLVM LIVE | MLIR LIVE |
  |---|---|---|---|
  | `leaks/ir_list_literal` (the corpus shapes above, host `take` frees the owned argument) | 0 / 0 (ALLOC 9000) | 8000 | 8000 |
  | `leaks/ir_list_literal_temp` (`sum([i, 2, 3])`, F3) | 1000 / 1000 | 1000 | 1000 |
  | `leaks/reassigned_owned_var` IR rows (new: now lowerable) | 0 / 0 (pinned) | 8000 | 8000 |
  | `leaks/revived_var` IR rows (new) | 0 / 0 (pinned) | 10000 | 10000 |

  The last two (optional rows) include owned Strings, so they also witness
  step (c). Existing IR pins (3000, 9000, 8) must not move.

## Risks and how each is falsified

| # | Risk | Falsified by |
|---|---|---|
| 1 | `$list` double-freed once a drop pass lands | the `droppable` test; step (c)'s doubled-drop mutation over `ir_list_literal` |
| 2 | writer and reader strides disagree | a test that each push `Ty` equals its reader's; distinct values per type in `EXPECT-OUTPUT`; ASan |
| 3 | a push declared with the wrong ABI | stage 10 via the example's declarations; the pinned `declare` lines (F1 is the known gap) |
| 4 | elements evaluated twice or out of order | the counter in the example |
| 5 | the reused scratch slot grows across loop iterations | the `while` row (`210 211 212`) |
| 6 | a second diagnostic after a refusal | the one-diagnostic hir test |

## Commits (TDD, each opening with its failing test)

0. **Separately, before this step: F1**, `zeroext`/`signext` on `i8`/`i16`
   parameters and returns in both emitters, with `z.cell` as a corpus
   example and host.
1. **Runtime:** `CELL_LIST_PUSH` and the four pushes, harness checks.
2. **`Binding.droppable`**, defaulted true, false for pattern and payload
   bindings; hir tests only.
3. **The five table entries and the `.list_lit` desugar**, with the element
   rule, the refusals and `$list`'s `droppable = false`; hir tests.
4. **Emitter tests and the reworded backstops.**
5. **Corpus example, stage 6 rows, the two leak fixtures with measured pins
   and a stage 7 comment per pin**, plus the optional IR rows.
6. **Documentation:** `AGENTS.md`/`CLAUDE.md` codegen paragraph (list
   literals join the IR exceptions), both emitter module headers (`mlirmit`
   still lists "non-empty list literals" as refused), FEATURES EXPR-01 and
   TYPE-04 (LLVM/MLIR build scalar lists) and OWN-05 (the new IR pins), SPEC
   section 12, `docs/OWNERSHIP.md` (F2, F3, F4, the pins),
   `examples/leaks/README.md`, the `hir.zig` "Step (b) ... adds" table comment.
7. **Step (b) Q6:** annotate `index.cell`'s `let owned s = "Hi"` as
   `: String` (its last IR refusal once (b) and (d) land; measured with the
   prototype: its four literal refusals are gone and only indexing and that
   `let` remain), move it to accepted-by-both, and fold `ir_index` into it.

## Out of scope

Owning elements (`[String]`) and their release; the `[scalar]` drop row
(step (c)); moving C's `emitListLit` onto the typed pushes (it would give
stage 10 a C leg for free and fix F4, but touches `codegen.zig` mid-split);
F2's C fix; destination-typed literals in the checker; `push`/`len` for
lists in the prelude; exact-capacity preallocation; indexed assignment.

## Open questions for Donald

1. **Typed pushes, IR only now?** Recommended: yes; move C onto them in a
   later commit once the `codegen.zig` split lands, which also closes F4.
2. **Push from empty, or exact capacity?** Recommended: push. Exact capacity
   needs either four more `with_capacity` symbols or an erased entry, and
   LIVE is already equal; revisit only on a measured cost.
3. **`[String]` literals.** Refuse in the IR now (recommended), and design
   owning elements with their release as one piece, after step (c) slice 1.
4. **Add `Binding.droppable` in this step, pattern bindings included?**
   Recommended: yes, so step (c) inherits the scratch-slot and pattern facts
   with tests already pinning them.
5. **Extend step (c) slice 1 with the `[scalar]` row**, taking
   `ir_list_literal` 8000 -> 0 on both IR backends (the temp fixture stays
   at 1000 with C)? Recommended: yes, through one erased
   `cell_slice_free(exclusive xs: [unknown])` entry, since the C function is
   itself erased; this is on the path to the LLVM default-target flip.
6. **F1 first?** Recommended: yes, as commit 0; it is a live wrong answer
   and `[Byte]` literals widen the surface that passes `i8`.
7. **F2.** Fix C's inferred `[String]` element now (one `emitListLit`
   change, after the split), or refuse unannotated `[String]` literals in
   the checker until then? Recommended: refuse in the checker now, fix C
   later; a checker refusal is backend-neutral and loud.
8. **`index.cell` merge (commit 7) in this step?** Recommended: yes, as step
   (b) Q6 anticipated; if (b) has not landed, the example uses a host for
   reads (as the leak fixture does) and commit 7 waits for (b).
