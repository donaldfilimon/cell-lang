# IR String step (b): indexing in the LLVM and MLIR backends

Status: direction approved by Donald 2026-09-17 ("pin the IR leak, then
build": conversions, indexing, list literals, then a drop pass ported onto
HIR). Step (a) landed in merge `4aca38b`. This document is step (b).

**Ruled 2026-09-21 by Donald: approved with this document's recommendations.**
Q3: C learns to view an owned-String value-block base (a codegen change, so it
waits for the borrowck/codegen split); `mk()[0]` stays refused. Q4: reusing a
user declaration of a reader stays exact-match only. Q5: `runEmitted` takes a
host, so all six readers run under `zig build test`. Q6: `ir_index` merges into
`index.cell` after step (d). Q1 was answered by `4a1f055`; Q2 by `368266a`,
which pinned `unbound_list_temp.cell` as its own fixture. Commit 1 below is
already done as `f4cc32e` and is dropped. Re-measure every line anchor before
building: they date from `4aca38b`.

A planning pass measured it on 2026-09-17, in a `git archive` export of
`4aca38b` under `/private/tmp/claude-501/stepb/tree`. The canonical checkout
had moved to `f68e948` by then. The two commits after `4aca38b` touch the
`String?` spelling and the leak docs, not indexing, the list layout or
`codegen.zig`. Line anchors are from `4aca38b` and will drift.

**Every design claim below was tested by a prototype.** About 40 lines went
into the exported `hir.zig`, and no emitter line changed. The measurements
come from that prototype, not from reading the code. The prototype is not a
patch to apply: it has none of the tests or refusals this spec requires.

## Where things stand

- **Indexing is typed in the checker and lowered in C only.**
  - `typecheck.zig:782` `checkIndex` gives `String` and `[Byte]` the type
    `Byte?`.
  - `[Int]`, `[Int32]`, `[Float]` and `[Bool]` get their element's optional.
  - Every other base is refused ("cannot index a value of type ...").
  - The index must be `Int`.
  - Indexed assignment is refused.
- **C calls six bounds-checked runtime readers and never inlines a read.**
  `codegen.zig:2737` `emitIndex` picks a reader, and `codegen.zig:4338`
  `listReader` picks the list reader from the element C type the list was
  built with.
- **None of the readers can panic.** A negative or out-of-range index returns
  `none`, and each reader is a real symbol (`cell_rt.c:432`, `:460`, `:465`).

  | Base | Reader (`cell_rt.h`) | Clang's declaration (arm64, `cc -S -emit-llvm -O0`) |
  |---|---|---|
  | `String` | `cell_opt_byte_t cell_str_byte_at(cell_str_t, int64_t)` (:624) | `declare i16 @cell_str_byte_at([2 x i64], i64 noundef)` |
  | `[Byte]` | `cell_opt_byte_t cell_bytes_at(cell_slice_t, int64_t)` (:629) | `declare i16 @cell_bytes_at(ptr noundef, i64 noundef)` |
  | `[Int]` | `cell_opt_i64_t cell_list_i64_at(cell_slice_t, int64_t)` (:636) | `declare [2 x i64] @cell_list_i64_at(ptr noundef, i64 noundef)` |
  | `[Int32]` | `cell_opt_i32_t cell_list_i32_at(...)` (:637) | `declare i64 @cell_list_i32_at(ptr noundef, i64 noundef)` |
  | `[Float]` | `cell_opt_f64_t cell_list_f64_at(...)` (:638) | `declare [2 x i64] @cell_list_f64_at(ptr noundef, i64 noundef)` |
  | `[Bool]` | `cell_opt_bool_t cell_list_bool_at(...)` (:639) | `declare i16 @cell_list_bool_at(ptr noundef, i64 noundef)` |

- **Both IR emitters refuse every index today.** `hir.zig:1082` reports
  "cannot lower: indexing is not lowered by the IR backends" and then leaves
  an `unresolved_ref "index"`. That produces a second error, and a `Some`/`None`
  arm over the index produces a third ("a Some/None pattern on a value that is
  not a scalar optional"). No test pins any of those messages.
- **The emitters already carry everything a reader call needs.**
  - A bodyless Cell declaration with the reader's signature
    (`pub fn peek(shared ns: [Int], copy i: Int) -> Int?;`) is accepted by
    both emitters.
  - Both print the declaration clang prints, minus attributes: `ptr` for the
    24-byte slice, `[2 x i64]` for `Int?` and `Float?`, `i64` for `Int32?`,
    and `i16` for `Byte?` and `Bool?`.
  - A call to it spills the slice into a fresh `alloca` and matches the
    optional it returns.
- **Only `examples/index.cell` indexes, and it stays refused after this
  step.** With the prototype its 13 index refusals disappear in both
  emitters. Two unrelated refusals remain:
  - four non-empty list literals, which are step (d);
  - `let owned s = "Hi"`, the unannotated `let` that step (a) left refused.

  So `index.cell` cannot move to accepted-by-both until step (d) lands and the
  `let` is annotated. Step (b) needs its own corpus example (section 6).

## Design

### 1. No new HIR node: an index is a runtime call

- **The `.index` arm lowers to `Lowerer.runtimeCall`.** It uses step (a)'s
  table:
  1. Lower the base.
  2. Lower the index with `lowerExprIn(ix.index, types.t_int)`, so an index
     literal is `i64` and a negated literal folds.
  3. Pick the callee from `base.ty` (section 2).
  4. For a `String` base only, pass the base through
     `convertTo(base, t_string, .shared)`.
  5. Return `runtimeCall(id, span, &.{ base, index })`.
- **The result is an ordinary `.call`.** It is typed as the element's optional
  and has `own = .owned`, which is meaningless for a scalar optional (see risk
  7).
- **`cfg.zig` and `liveness.zig` gain no arms.** Step (a)'s `string_view`
  needed both, and this step needs neither, because it adds no node kind.
- **A `String` base goes through the conversion funnel, unchanged.** The
  prototype measured each case:

  | Base | What `convertTo` does |
  |---|---|
  | a `shared` parameter, or a literal (`"abc"[2]`) | already a view; left alone |
  | an `owned` local or parameter | a place; wrapped in `string_view` |
  | an `exclusive` parameter | a place; wrapped in `string_view`, which dereferences |
  | a field (`b.name[0]`) | a place; wrapped in `string_view` |
  | an `if`/`match` over owned places | pushed into each branch |
  | an owned temporary (`mk()[0]`) | left owning, so the `fits` backstop refuses it ("a value of type %cell_string where %cell_str is expected, in a call argument") |

  C refuses that last case too, but only at `cc`, because it passes a
  `cell_string_t` to a `cell_str_t` parameter (finding F4). The IR refusal is
  the safe one, because a view of a temporary would outlive its only owner.
- **A list base needs no conversion.** A `[T]` is one 24-byte `cell_slice_t`
  for every ownership except `arc`, and the reader takes it `shared` (by
  value, so the IR passes a pointer to a caller-made copy).
  - `shared`, `owned` and `exclusive` parameters, owned locals, struct fields,
    the borrow sigil `(&xs)[0]`, and call temporaries all ran correctly in
    both emitters.
  - The `exclusive` parameter case loads the header through the pointer, then
    spills it.
- **Bounds and panic behaviour match C by construction.** Both backends call
  the same reader with the same `i64`.
  - Out of range and negative indices give `None` in all three backends
    (measured with `[2]`, `[3]` and `[-1]`).
  - Indexing itself never panics. The only panic nearby is a non-exhaustive
    `match`, which both IR emitters already lower to `cell_panic`.
  - **No IR fast path.** An inline GEP with its own bounds check would be a
    second copy of the bounds logic that stage 8 could only sample. Revisit
    only with a measurement that the call costs something.

### 2. Runtime table entries

- **Six entries join `Runtime` and `runtime_callees`** (`hir.zig:211`), built
  by one comptime helper so that each entry reads as a single line:

  | `Runtime` tag | `name` | Cell signature |
  |---|---|---|
  | `str_byte_at` | `$rt.str_byte_at` | `(shared xs: String, copy index: Int) -> Byte?` |
  | `bytes_at` | `$rt.bytes_at` | `(shared xs: [Byte], copy index: Int) -> Byte?` |
  | `list_i64_at` | `$rt.list_i64_at` | `(shared xs: [Int], copy index: Int) -> Int?` |
  | `list_i32_at` | `$rt.list_i32_at` | `(shared xs: [Int32], copy index: Int) -> Int32?` |
  | `list_f64_at` | `$rt.list_f64_at` | `(shared xs: [Float], copy index: Int) -> Float?` |
  | `list_bool_at` | `$rt.list_bool_at` | `(shared xs: [Bool], copy index: Int) -> Bool?` |

  - Each `symbol` is the C name in section 1's table.
  - `ret_ownership = .owned`, as an unannotated return is everywhere else.
  - The existing comptime assert keeps the enum and the table the same
    length.
  - A `Ty` such as `.{ .list = &types.t_int }` builds at comptime from the
    `types.zig` singletons. The prototype compiled with it.
- **The dispatch is a switch that names every accepted element.**
  - `.byte`, `.int`, `.int32`, `.float` and `.boolean` each map to a reader.
  - Every other element, and every non-`String`, non-list base, is refused in
    `hir.lower` with "cannot lower: indexing a value with no bounds-checked
    runtime reader".
  - The checker already refuses those programs, so the message is reachable
    only from lowering tests that skip `check`, as 27 codegen tests do.
- **The selector is the HIR `Ty`, not the element C type the list was built
  with.** The two agree today because every IR list comes from a declared
  signature. Step (d) must keep them agreeing (risk 5).
- **`resolveRuntime` needs no new logic.**
  - It declares each used reader once. A second use reuses the declaration,
    and the prototype declared each reader exactly once across 19 uses.
  - It reuses a matching source declaration: `pub fn list_i64_at(shared xs:
    [Int], copy index: Int) -> Int?;` emits cleanly.
  - It refuses a conflicting one. `owned xs` is refused even though its C ABI
    is the same, because `sameSignature` compares ownership. That is
    conservative, and the spec keeps it.
  - **Its message has to change.** It says "which a String conversion in this
    module calls", which is false for a reader. It becomes "which a
    String conversion or an index in this module calls", or else it names
    the `Runtime` tag.
- **Stage 10 checks the new declarations without a pin.** A reader called in
  a C body survives clang, so stage 10's C leg already carries its
  declaration, and `sig_join` compares it by name.
  - Measured with stage 10's own awk on the probe below: all six readers
    joined on the C, LLVM and MLIR legs, with zero disagreements.
  - The shapes were `i16|agg16|i64`, `i16|ptr|i64`, `agg16|ptr|i64`,
    `i64|ptr|i64`, `agg16|ptr|i64` and `i16|ptr|i64`.

### 3. Emitter changes: none required, one fix recommended

- **Measured, not assumed.** With only the `hir.zig` change:
  - both emitters accepted a probe covering all six readers and every base
    form in section 1;
  - `mlir-opt` lowered the MLIR output;
  - LLVM, MLIR and LLVM built with `-fsanitize=address` each printed
    `7031401152`, which is the hand-computed answer;
  - `zig build test -Dswift=false` exited 0 (287 runtime checks, plus all Zig
    tests).
- **An `arc [T]` base is a silent miscompile under the prototype, so step (b)
  must close it first** (finding F2).
  - `abi.zig:76` lays out `.list` as 24 bytes whatever the ownership. So
    `pub fn f(arc xs: [Int])`, and a struct field `arc items: [Int]`, are
    accepted by both emitters as a plain `ptr` to a slice, while C passes a
    `cell_arc_t`, which is also 24 bytes.
  - Under the prototype, `xs[0]` on such a parameter returned
    `has=1 value=4303230208` in LLVM, reading the box's pointer as element 0.
    C refused the same program at `cc`.
  - **Fix at the root, in its own commit:** `layoutOf` and `classifyParam`
    answer `null`/`.unclassified` for an `arc` list, as they already do for
    `arc String`. That also refuses the field.
  - **Add a local guard as well:** `hir.lower` refuses an index whose base
    has `own == .arc`, with a named message. `own` is set on `.ref`, `.field`
    and `.call`, and it passes through borrow sigils and value blocks.
- Everything else in both emitters stays as it is.

### 4. What stays refused

| Form | Refused by | Why |
|---|---|---|
| `[String][i]`, `[Int8][i]`, `[Float32][i]`, any other element | checker (`cannot index a value of type ...`), then `hir.lower` | no reader; what `[String][i]` owns is an open design question |
| an index that is not `Int` | checker | no truncation, as in C |
| `a[i] = x` | checker | indexed assignment is not implemented |
| an owned `String` temporary as the base | `fits` backstop | no view of a temporary |
| an `arc` `String` or `[T]` base | `abi.zig` after the fix, plus the `hir.lower` guard | no retain/release in IR |
| any base built from a non-empty list literal | the emitters' list-literal refusal | step (d) |
| `let owned s = "Hi"` then `s[0]` | `fits` backstop on the `let` | step (a) residual; C keeps it a view |

### 5. Findings outside this step, measured while grounding it

- **F1. A silent C miscompile. FIXED in `4a1f055`.** It began in `1eaed84`
  (branch-end releases, for a statement `if`) and `38e33a2` extended it to
  `match` arms. `~/tasks/goals.md` recorded the `38e33a2` design change
  ("every match arm now ends with branch-end releases") but not the defect;
  `docs/OWNERSHIP.md` now does.
  - **The shape.** An owned local is moved after a value-position `match` in
    a `let`. C then releases that local at the end of every arm of the
    unrelated `match`, and the later move reads a zeroed header.
  - **The reproducer:**
    ```
    let owned ns = host_ints()
    let copy e = match flag { true => 1, false => 0, }
    print_int(e + take(ns))
    ```
    It prints `1` in C and `43` in LLVM. ASan stays silent, because
    `cell_slice_free` zeroes the header and `free(NULL)` is legal.
  - **Where it starts.** Bisected with `git archive` builds: clean at
    `ac4ea64` (the parent of `38e33a2`), at `291b8d8` and at `1eaed84`;
    present at `38e33a2`, at `a46209b` and at `4aca38b`.
  - **Shapes that do not trigger it.** An `if` in the same position emits no
    release, and a later shared use (no move) is released correctly at scope
    end.
  - **Why no gate stage sees it.** No corpus program has this shape.
  - **Impact on step (b).** It must be fixed, or at least avoided, before
    `examples/ir_index.cell` is written, or stage 8 reports C against the IR
    backends on an indexing example for a reason unrelated to indexing. It
    showed up in exactly that way here.
- **F2. An `arc [T]` parameter is a live LLVM crash today, with no indexing
  involved.**
  - **The shape:** `pub fn h(arc ys: [Int]) -> Int?;` called as `h(xs)` with
    an owned `xs`.
  - **What each backend does.** C boxes the list
    (`cell_h(cell_arc_from_slice(xs))`). LLVM passes the raw slice by
    pointer, and a C host reading the `cell_arc_t` died with exit 139.
  - **Why stage 10 misses it.** The shapes coincide: both are `ptr`.
  - The fix is section 3's `abi.zig` change.
- **F3. C leaks an unbound owned list temporary passed to a `shared`
  position.**
  - `or0(host_ints()[0])` and `second(host_ints())` each measure 1000 in 1000
    iterations, on both `leaks` and the malloc counter.
  - This is the "nothing drops a call temporary" residual that
    `docs/OWNERSHIP.md` records, but no fixture pins it for lists.
- **F4. C refuses at `cc` two `String` bases that `cell check` accepts.**
  - **The bases.** An owned temporary, `mk()[0]`, and an `if` over two owned
    parameters, `(if c { a } else { b })[0]`.
  - **What C does.** Both pass a `cell_string_t` where `cell_str_t` is
    wanted. The refusal is loud, so it is safe.
  - **What the IR backends do.**
    - The temporary: they refuse it as well.
    - The `if`: they accept it, soundly. `convertTo` views each branch's
      place, and the result printed correctly.
  - **The divergence.** For the `if`, IR accepts a program the reference
    backend refuses. Open question 3 covers this.

## Testing and gate

- **hir tests** (in `hir.zig`, beside step (a)'s):
  - **Each of the six base types.** Lowers to a `.call` with the right
    `symbol`, typed as the element's optional, with one appended
    `origin = .runtime` `Fn` per reader used, however many uses there are.
  - **The index literal.** `xs[-1]` and `xs[1 + 1]` both type the index
    `Int`.
  - **`String` bases:**
    - a `string_view` is inserted for an owned local, an owned parameter, an
      exclusive parameter and a field;
    - none is inserted for a `shared` parameter or a literal;
    - an owned temporary is left owning.
  - **Refusals:**
    - an `arc` base: parameter, field and sigil forms;
    - `[String]`, `[Int8]` and unknown bases, lowered without `check`.
  - **Collisions.** A matching `list_i64_at` declaration is reused. An
    `owned xs` declaration is refused, and the message no longer says
    "String conversion".
- **`abi.zig` tests:**
  - `layoutOf(list, .arc) == null`;
  - `classifyParam(list, .arc) == .unclassified`;
  - the existing "an out-of-scope type is unclassified" test gains the list
    case.
- **llvmemit tests:**
  - **The declarations.** Pin the six lines, exactly as section 1's table has
    them without attributes.
  - **A hostless run.** Build `[Byte]` from `bytes_empty` and `bytes_push`,
    read `String` through literals and an annotated owned local, and index in
    and out of bounds.
    - The prototype printed `1101` for such a program on C and on LLVM.
    - Keep `expectNoViewStoredIntoOwningSlot`.
  - **The four remaining readers.** `[Int]`, `[Int32]`, `[Float]` and `[Bool]`
    have no Cell constructor, so either:
    - `runEmitted` gains an optional host C source, which is recommended
      because it is small and puts all six readers under `zig build test`; or
    - those four are covered only by gate stages 6 and 8.
  - **Refusals:**
    - the owned `String` temporary base, refused with the `fits` wording;
    - an `arc [Int]` parameter;
    - an `arc [Int]` call argument, which is F2.
- **mlirmit tests** (the run helper there is `runThroughMlir`, not
  `runEmitted`):
  - the same declaration pins, in MLIR spelling (`func.func private
    @cell_list_i64_at(!llvm.ptr, i64) -> !llvm.array<2 x i64>` and the other
    five);
  - the same refusals;
  - one run through `mlir-opt`.
- **A new corpus example: `examples/ir_index.cell` plus
  `examples/ir_index_host.c`.**
  - **Readers and bases.** Uses all six readers and every base form in
    section 1 (the section 3 probe is a starting point), with lists supplied
    by the host.
  - **Output.** Carries `EXPECT-OUTPUT`, computed on C first.
  - **Host flags.** `examples/ir_index_host.c` must be clean at
    `-std=c11 -Wall -Wextra -Werror -fsanitize=address`, because stage 9
    builds hosts that way.
  - **What it must avoid:**
    - F1's shape;
    - list literals;
    - unannotated owned `let`s;
    - index expressions with side effects (risk 6).
- **Gate:**
  - **Stage 4.** `ir_index` is accepted by both. `index.cell` stays refused by
    both, now only for list literals and the unannotated `let`, so its header
    and `examples/README.md` need the new reason.
  - **Stage 5.** Lowers `ir_index`.
  - **Stage 6.** Adds `run_c_host`, `run_llvm` and `run_mlir` rows for
    `ir_index` with its host. The host argument already exists.
  - **Stage 8.** Picks up `ir_index` and its host automatically
    (`examples/${n}_host.c`) and checks `EXPECT-OUTPUT`.
  - **Stage 9.** Runs the C build under ASan with the host automatically.
    Also run the LLVM build under ASan by hand; the prototype's did, with
    exit 0.
  - **Stage 10.** `ir_index` adds six reader comparisons per IR leg. They
    must agree without a pin, and never add a pin to make them pass.
- **Leak pins (stage 7):**
  - **A new looped fixture: `examples/leaks/ir_list_index.cell`,** 1000
    iterations, with a small host (`host_ints`).
  - **`run_c_leaks` and `run_ir_leaks` rows.** Both helpers already take a
    host argument.
  - **Prototype measurements, one fixture per row, 1000 iterations each.**
    These are not pins: measure them again on the implementing commit
    before pinning anything.

    | Row | C `leaks` / LIVE | LLVM LIVE | MLIR LIVE |
    |---|---|---|---|
    | control: a bound host list, not indexed | 0 / 0 | 1000 | 1000 |
    | a bound owned list, indexed | 0 / 0 | 1000 | 1000 |
    | a list passed to `shared` and indexed in the callee | 0 / 0 | 1000 | 1000 |
    | an annotated owned `String`, indexed | 0 / 0 | 1000 | 1000 |
    | a string literal, indexed | 0 / 0 | 0 | 0 |
    | an unbound temporary, `host_ints()[0]` (F3) | 1000 / 1000 | 1000 | 1000 |

  - **What the rows show.** Indexing allocates nothing, so every IR count is
    the owner the program already had, which step (c) must free.
  - **Predicted pins for the fixture:** it holds the bound owned list, the
    shared-callee list, the owned `String` and the literal rows (the control
    row is measurement only), so C 0 and 3000 for each IR backend. Row 6 is
    open question 2.
  - `ir_owned_string` must stay at 3000, and `ir_string_conversion` and
    `owned_string` must keep their pins.

## Risks and how each is falsified

1. **The type confusion in an `arc` list (F2).** Falsified by:
   - the `abi.zig` tests;
   - the emitter refusal tests;
   - an absent `arc` row in `ir_index`'s stage-10 comparison.

   Measure again with `grep -rl 'arc \['` over the corpus: no accepted IR
   example uses one today, so no stage-4 verdict moves.
2. **A reader declared with the wrong ABI** (for example `Byte?` as
   `{i8,i8}` rather than `i16`). Falsified by:
   - stage 10 comparing all six against clang;
   - the pinned declaration lines.
3. **A view taken of a temporary.** Falsified by:
   - the hir test that an owned temporary is left owning;
   - the emitter refusal test;
   - step (a)'s standing test.
4. **A reader applied with the wrong stride** (for example `[Int32]` read by
   `list_i64_at`). Falsified by:
   - the hir symbol-per-type test;
   - `ir_index` putting a distinct value in each list, so a stride error
     changes `EXPECT-OUTPUT`;
   - the ASan run.
5. **The stride selector drifts from C once list literals land.**
   - **The two selectors.** C uses the element C type the literal was built
     with; HIR uses `Ty`. The recorded first-element defect
     (`AGENTS.md`, "NOT memory-safety" bucket) is exactly this axis.
   - **What step (d) must add.** A test in which a literal's first element
     differs from the declared element, indexed on all three backends.
6. **Order of evaluation.**
   - **The difference.** C does not specify the order in which arguments are
     evaluated, and the IR evaluates the base before the index.
   - **Where it shows.** Only when both have visible side effects, for
     example `host_ints()[next()]`, where C and IR could print different
     output.
   - **How it is kept out.** `ir_index` keeps its indices pure. The same
     property holds for every call in the C backend today.
7. **`own = .owned` on a scalar optional result** is read by nothing today.
   If `[String]` indexing is ever designed, the reader's return ownership
   becomes load-bearing and must be decided then, not inherited from this
   table.
8. **F1 contaminates the new example.** Falsified by `ir_index` printing the
   same number on all three backends. If it cannot, fix F1 first rather than
   bending the example around it.
9. **The conflict message still says "String conversion".** A hir test pins
   the new wording.

## Commits (TDD, each opening with its failing test)

1. **`abi.zig` refuses `arc [T]`** (F2).
   - Tests are in `abi.zig`, plus emitter refusals for a parameter, a field
     and a call argument.
   - The gate stays green, and no corpus verdict moves: `examples/prelude.cell`
     is accepted by both IR emitters today and declares no `arc [T]` (only
     `stdlib/prelude.cell` has `arc String`, which both emitters already
     refuse).
   - `abi.zig` moved after this measurement (`241ea4a` changed
     `optionalBase`), so rebase this commit onto the current file when step
     (b) starts and re-run the `classifyParam` tests; do not trust the
     `4aca38b` anchors.
2. **F1: done, separately, as `4a1f055`** (2026-09-17). borrowck records
   `ExitKind.after_branch` and codegen skips a branch-end release for a
   binding still held after the merge; `examples/move_after_branch.cell`
   prints 140 on all three backends. Nothing remains for this step.
3. **The six table entries and the `.index` arm.**
   - Includes the `arc` guard and the reworded conflict message.
   - hir tests only.
4. **The emitter tests.**
   - The declaration pins, the hostless `[Byte]`/`String` run, the refusals,
     and the MLIR run.
   - `runEmitted` gains a host parameter if chosen.
5. **The corpus example and the gate.**
   - `examples/ir_index.cell` and its host.
   - Stage 6 rows, the leak fixture with its measured pins, and a stage-7
     comment for each pin.
6. **Documentation:**
   - the `AGENTS.md`/`CLAUDE.md` codegen paragraph (indexing joins the
     exceptions);
   - `index.cell`'s header and `examples/README.md` (new refusal reasons, the
     new example);
   - FEATURES `EXPR-02`, where LLVM and MLIR move from refused to partial, and
     `TYPE-04`;
   - the SPEC section 12 row for postfix indexing;
   - `docs/OWNERSHIP.md` (F3, and the IR index leak pins);
   - the `examples/leaks/README.md` table;
   - the `hir.zig` comment at the table ("Step (b) ... adds the indexing
     helpers here" becomes a statement of fact).

## Open questions for Donald

1. **F1.** Answered by doing: fixed separately, before step (b), as
   `4a1f055`. Nothing to decide unless Donald wants it handled differently.
2. **F3.** Pin C's unbound-temporary list leak (1000) as a disclosed row in
   `ir_list_index`, or leave that shape out of the fixture and record it in
   `docs/OWNERSHIP.md` only? The recommendation is a separate fixture with its
   own pin, so the gate sees it when precise drops land.
3. **F4.**
   - **The owned-`String` value-block base.** IR accepts
     `(if c { a } else { b })[0]` soundly, while C refuses it at `cc`. Should
     C learn to view it, or should IR refuse it for parity? The
     recommendation is to teach C (`emitArgLike` should view a value block of
     owned places), with IR unchanged.
   - **`mk()[0]`.** Both refuse it, but should the checker refuse it instead
     of `cc`?
4. **Reusing a user declaration of a reader.** It stays exact-match only (an
   `owned xs` spelling is refused even though its C ABI is the same). Is that
   acceptable?
5. **`runEmitted` with a host,** so that all six readers run under
   `zig build test`, or only `[Byte]` and `String` there, with the other four
   in the gate only?
6. **Ordering.** Should `index.cell` be rewritten after step (d) to use
   annotated `let`s, so that it becomes the three-backend example and
   `ir_index` merges into it, or should the two stay separate?
