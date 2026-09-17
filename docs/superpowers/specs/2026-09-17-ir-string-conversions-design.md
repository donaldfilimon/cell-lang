# IR String step (a): conversions and runtime declarations

Status: direction approved by Donald 2026-09-17 ("pin the IR leak, then
build": conversions, indexing, list literals, then a drop pass ported onto
HIR). This document is step (a). A planning pass read the code on 2026-09-17
(at `291b8d8`) and produced it. Line anchors are from that pass and will
drift.

## Where things stand

- **The conversion helper is a real function.** `cell_string_from_str` is
  declared at `runtime/cell_rt.h:195` and defined at `cell_rt.c:38`. Clang
  lowers it as `declare void @cell_string_from_str(ptr sret(%struct.cell_string), [2 x i64])`.
- **`examples/owned_string.cell` is refused 10 times by each IR emitter.**
  - Seven of those are borrowed-to-owned conversions.
  - Two are value-slot refusals, where a `match` arm yields an owned String
    into a slot typed as a borrowed view.
  - The C backend converts at eight positions.
- **C handles three more positions:**
  - an unannotated `let owned s = "ab"` stays a view;
  - `s = "cd"` through `exclusive s: String` converts;
  - a binding pattern over a borrowed scrutinee binds a view.
- **Both IR emitters misread String places.** `.ref` and `.field` read a
  String as a borrowed view whatever the slot really holds (the "type lie").
- **No IR drop pass exists yet.** `examples/leaks/ir_owned_string.cell` pins
  the leak at LIVE=3000 for LLVM and for MLIR.

## Design

### 1. One conversion funnel, in HIR

- **New function.** `Lowerer.convertTo(e, want_ty, want_own) Expr` plays the
  role of the C backend's `emitConversion`. It decides from the pair of what
  the expression has (`e.own`, see section 4) and what the slot wants.
- **Borrowed view into an owning slot.** The expression is wrapped in a
  synthetic call to `cell_string_from_str` (section 3). Any source is safe,
  because the call copies.
- **Owning value into a view slot.** The expression is wrapped in a new
  `string_view` node, but only when it is a place. A temporary is left alone,
  so the emitters refuse it, which is what C does.
- **`block`, `if` and `match`.** The function recurses into the tail, the
  branches or the arms, and stamps the node's ownership with the wanted one.
  A `match` or `if` with no destination takes its first arm's ownership, as
  C's `inferExpr` does.

Where it is called:

| Position | What the slot wants |
|---|---|
| `let` | the annotation; only an annotated `let` converts |
| assignment | the target binding's ownership, or the field's (a new `FieldSel.ownership`) |
| call argument | the parameter's type and mode |
| struct-literal field | the field's declared ownership |
| `return` | the declared return (`ret_own` joins the Lowerer) |
| string-pattern `match` scrutinee | a shared view |

- **The emitters' `fits()` check stays as a backstop.** Its message changes
  to "hir.lower inserted no conversion here". A position the funnel misses
  still refuses, and never stores 16 bytes into a 24-byte slot.
- **Still not converted, and still refused by both emitters:**
  - an unannotated `let`;
  - binding patterns;
  - Option and Result payloads.

### 2. Reading an owned String as a view

- **New HIR node.** `Expr.Kind.string_view` is added to `cfg.zig` and to
  `liveness.zig` together, because those two walks mirror each other.
- **LLVM.** It reads fields 0 and 1 of the `%cell_string` and builds a
  `%cell_str` with two `insertvalue`s.
- **MLIR.** It dereferences first when the operand is an address, then builds
  the same shape with `llvm.extractvalue`, `llvm.mlir.undef` and
  `llvm.insertvalue`.
- **The type lie is removed in the same change.**
  - `.ref` loads the slot's real type.
  - `.field` uses the owned-aware type.
  - `emitStringEq` gains a `fits` guard.
- **Value slots.** They take their type from `e.own orelse .shared`. For an
  aggregate value slot, MLIR uses an `llvm.alloca`, because a `memref` cannot
  hold a struct.

### 3. Runtime callees, declared through HIR

- **`hir.Fn` gains an origin.** `origin: enum { source, runtime }`.
- **A comptime table lists the runtime callees.** The first entry is
  `cell_string_from_str(shared String) -> owned String`.
  `Lowerer.runtimeCall` builds the call and records that the entry was used.
- **When lowering finishes, each used entry is resolved.**
  - A source declaration of the same symbol with an equal signature is reused.
  - A body, or a mismatched signature, is refused as a conflicting
    declaration.
  - Otherwise a bodyless `Fn` named `$rt.string_from_str` is added. That name
    cannot collide with `findFn`.
- **Neither emitter changes.** The existing declaration path already prints
  the right ABI: `sret` plus the `[2 x i64]` argument in LLVM, and
  `llvm.sret` plus a coerced argument in MLIR.
- **Step (b) reuses this table** for the indexing helpers.

### 4. The HIR ownership fact

- **`Expr` gains a defaulted field.** `own: ?Ownership = null`.
- **It is set on:**
  - `.ref`, from the binding;
  - `.field`, from the field;
  - `.call`, from `ret_ownership`;
  - string constants and `string_view`, as `.shared`;
  - `block`, `if` and `match`, by `convertTo`.
- **The emitters read this field instead of re-deriving ownership.** That
  closes both the type lie and the value-slot defect. Ownership still stays
  out of `Ty`.

## Testing and gate

- **hir tests:**
  - one synthetic `cell_string_from_str` call at each of the eight positions,
    plus the exclusive write-through and `let copy s: String = "ab"`;
  - `string_view` inserted for an owned place and not for an owned temporary;
  - a matching user declaration reused, and a conflicting one refused;
  - the unannotated `let` and binding patterns left unconverted;
  - a `match` with a destination stamping its ownership.
- **llvmemit tests.**
  - **Flip** the conversion refusal test to "converted at every position".
    It pins one declaration, N calls, and `store %cell_string` into the slot.
  - **Keep** the `-> arc String` case refused, and keep the unannotated `let`
    as the backstop refusal.
  - **Pin the view emission text.**
  - **New lowering cases:** an exclusive String passed to a shared parameter,
    and a String match on an owned scrutinee.
  - **One run test** that prints the expected sum.
- **mlirmit tests:**
  - the same flip;
  - a run of a String-valued match, which exercises the `llvm.alloca` slot.
- **Gate:**
  - **Stage 4:** `owned_string` moves from refused-by-both to accepted-by-both.
  - **Stage 5:** lowers it.
  - **Stage 6:** gains an optional host argument for the LLVM and MLIR rows,
    plus `owned_string 44` rows for both.
  - **Stage 8:** already links hosts into every leg and checks
    `EXPECT-OUTPUT: 44`.
  - **Stage 10:** now also compares `cell_string_from_str` and the helper
    signatures against C. They must agree without a pin.
- **Leak pins (stage 7, one witness):**
  - `run_ir_leaks` gains optional source and host arguments.
  - New rows cover `owned_string` in LLVM and MLIR, plus its C row.
  - A new looped fixture, `examples/leaks/ir_string_conversion.cell`, runs the
    eight positions 1000 times with no host.
  - **Measure every count before pinning it.** A non-zero C count is a
    separate finding to disclose.
  - `ir_owned_string` must stay at 3000.

## Risks and how each is falsified

1. **A 16-byte store into a 24-byte slot.** The `fits` backstop stays. A
   helper also asserts that no `store %cell_str` goes into a `%cell_string`
   slot anywhere in the flipped table.
2. **A position that does not copy.** Checked three ways:
   - an exact call count;
   - stage 8 printing 44 on all three backends;
   - a manual ASan run with an ASan-built host and runtime.
3. **Removing the type lie breaks a reader that relied on it.** Audit every
   `llType` and `mlirType` call. Stages 6 and 8 on `prelude.cell` and the
   3000 pin must still pass.
4. **Two owners of one buffer.** A view is never taken of a temporary, and a
   test pins that. There is no double free today because the IR frees
   nothing, and step (c) must free synthetic call results.
5. **A runtime symbol collides with a user declaration.** The collision tests
   cover this.
6. **An MLIR `memref` of a struct.** Stage 5 and the run test catch it.
7. **An exclusive write-through overwrites the old buffer without freeing
   it**, as C does. This only leaks; it goes in `docs/OWNERSHIP.md`.
8. **C and IR diverge on the unannotated `let` and on binding patterns.** Both
   IR backends keep refusing them, and each case has a test.
9. **New stage-10 comparisons fail.** Never add a pin to make them pass.

## Commits (TDD, each opening with its failing test)

1. **`Expr.own`.** Add it, plus `FieldSel.ownership` and first-arm stamping.
   Tests are in hir only.
2. **`string_view` and the `.ref`/`.field` fix, in both emitters.**
   - The node, its insertion, and its `cfg` and `liveness` arms.
   - The `.ref`/`.field` fix and the `emitStringEq` guard.
   - The gate stays green, with `ir_owned_string` still at 3000.
3. **Value slots typed from `e.own`.** Includes the MLIR `llvm.alloca` slot.
4. **The runtime-callee table and `convertTo` at every position.**
   - Covers deduplication and collisions.
   - The emitter test tables are flipped in the same commit.
5. **Gate changes.**
   - The stage-6 host argument and its rows.
   - The `run_ir_leaks` extension and the new fixture.
   - The measured pins and their comments.
6. **Documentation.**
   - `AGENTS.md` and `CLAUDE.md`, and `owned_string.cell`'s header.
   - The emitter module headers and FEATURES.
   - SPEC section 12, `examples/README.md`, and OWNERSHIP.
   - The `fits` wording.
7. **Optional: `cell_panic` onto the runtime table.**
