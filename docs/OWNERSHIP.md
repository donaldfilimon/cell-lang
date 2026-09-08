# Cell Ownership Rules

Normative rules for the Cell borrow checker, written to be implemented directly
from this file.

**Snapshot: commit `9fb12af`, 2026-09-06, with corrections through `8dd5673`.** The compiler is under active
rewrite; `src/` moved twice while this was being written. Every "blocked on"
note below was re-verified against `9fb12af`, and several notes that an earlier
draft carried are now **unblocked**, because the parser gained field-access
nodes, structured patterns, and source spans. If a note here disagrees with the
source, believe the source.

**Implementation status.** `src/cell/borrowck.zig` is wired into `cell check`
and enforces R2 (use-after-move), R3 (move-out-of-borrow), R5 (shared XOR
exclusive), R8 (escaping borrow), R14 (assignment through an immutable place,
including fields), and R15 (call-site annotation agreement). Diagnostics name
the place and land at the use site. That file's header comment is the
authoritative list and moves with the code; believe it over this paragraph.
NLL is still designed. **R11** retain-release insertion is implemented in the
C backend, with the gaps R11 itself names; **R10**'s move-into-`arc` is not
implemented in the checker, which is why one of those gaps exists. **R2.a**
(a move inside a loop) landed with `while`. Stem pairing has
since landed (SPEC section 1.2).

---

## 0. Conventions

### 0.1 Diagnostic format

`src/cell/diag.zig` fixes the shape:

```
path:line:column: error: message
```

with the offending source line and a caret beneath it when the bag was
constructed with a source buffer. `Bag.err`, `Bag.warning`, and `Bag.note` each
take an `ast.Span`. Every diagnostic below is spelled as the `message` text and
should be pushed through one of those.

**Spans are available.** As of `262ee09` every `Expr`, `Stmt`, `Item`, and
`Pattern` is a `{ kind, span }` wrapper, and every token carries byte offsets
plus line and column. Rules that need two locations (a move and its later use)
have both, and should emit an `err` at the use and a `note` at the move. An
earlier draft listed span support as a prerequisite; it is done.

### 0.2 Terms

- **Place**: a binding, or a field path rooted at a binding (`buf`, `buf.len`).
  `ast.rootName` walks a field chain down to its base binding and returns null
  for anything that is not a place.
- **Move**: transfer of ownership away from a place. The source becomes
  **dead**.
- **Dead**: a place whose value has been moved out. Reading, borrowing, or
  passing a dead place is an error until it is reassigned.
- **Borrow**: a non-owning reference to a place, either `shared` (read) or
  `exclusive` (read and write).
- **Loan**: an active borrow, tracked from its creation to the end of its
  scope.
- **Live**: not dead, and not the source of an incompatible active loan.

### 0.3 Borrow scope: the lexical choice

**A loan lives from its creation to the end of the innermost enclosing block.**
Cell uses lexical borrow scopes, not non-lexical lifetimes.

Two exceptions narrow it, and both make the common case work without analysis:

1. A borrow created as a call argument (`f(shared x)`, `f(&x)`) ends when that
   call statement completes. It does not survive to the end of the block.
2. A borrow created inside an `if` condition or a `match` scrutinee ends when
   that expression finishes.

The choice is deliberate. Lexical scoping is decidable by a single pass with a
scope stack, needs no control-flow graph, and can be implemented against the
AST as it stands. NLL is more permissive and strictly better for users, and it
is the right target once there is a CFG. Every program accepted under lexical
scoping is still accepted under NLL, so tightening now and relaxing later never
breaks source compatibility. When a rejection would be accepted under NLL, say
so in a `note`, so a user knows the rejection is the checker's conservatism and
not their bug.

### 0.4 What the checker walks

**This prerequisite is now met.** As of commit `8dd5673` the checker has a
scope stack. Re-measured: a file where `a()` declares an immutable `x` and
`b()` assigns to an otherwise undeclared `x` now reports
`unknown identifier 'x'`, where before `8dd5673` it reported the immutability
error, which was the right diagnostic for the wrong reason.

Everything below was written against the older, module-wide symbol table, and
R13.4 named fixing it as the blocking prerequisite. It no longer blocks. Verify
the scope stack's shape against `src/cell/typecheck.zig` before building on it,
rather than against this paragraph.

---

## 1. Moves and use-after-move

### R1. Ownership defaults to `owned`

An omitted annotation means `owned`, in every position: parameters, struct
fields, `let`, and `var`. That is what the parser does
(`parseOwnership() orelse .owned`) and the checker must agree.

The consequence is the first thing to teach users: **a bare call argument
moves.**

```cell
pub fn take(owned b: Buffer) { }

pub fn main() {
    let owned buf = Buffer { data: [], len: 0 }
    take(buf)      // moves, because the parameter is owned
    take(buf)      // R2 violation
}
```

### R2. Using a place after it is moved is an error

A place is dead after it is:

- passed to an `owned` parameter,
- returned,
- bound to a new `owned` binding (`let owned b = a`),
- assigned to another place,
- moved into a `match` arm binding (R7).

```cell
pub fn main() {
    let owned buf = Buffer { data: [], len: 0 }
    take(owned buf)
    grow(exclusive buf, shared 16)
}
```

> `err: use of 'buf' after it was moved`
> `note: 'buf' was moved here by the call to 'take'`

Corpus: `examples/rejected/use_after_move.cell`, which passes `cell check`
today and must not once this rule exists.

### R3. Moving out of a borrow is an error

A `shared` or `exclusive` parameter is not owned, so it cannot be moved from,
and neither can a field of one.

```cell
pub fn steal(exclusive b: Buffer) -> Buffer {
    return b
}
```

> `err: cannot move out of 'b': it is an exclusive borrow, not an owner`

The same applies to `shared`, with `shared borrow` in the message. Returning a
field of a borrow (`return b.data`) is the same error, reported on the field
path. `ast.rootName(&expr)` gives the binding to name in the message.

### R2.a. A move inside a loop is a use-after-move on the next iteration

Moving out of a place declared **outside** a loop body, from **inside** that
body, is an error unless the place is reassigned before the body ends.

```cell
var owned buf = make()
var i = 0
while i < 3 {
    take(owned buf)
    i = i + 1
}
```

> `err: 'buf' is moved inside a loop, so the next iteration would use it after the move`
> `note: 'buf' is declared outside this loop; assign to it before the end of the body to revive it`

**Why this rule has to exist.** Section 0.3 chose lexical loans on the stated
ground that they are decidable in one pass with a scope stack and need no
control-flow graph. A loop is a back edge, which breaks that assumption
directly: the single pass marks `buf` dead once and never revisits it, so
nothing catches the second iteration.

**How it is checked.** A place moved inside the body and still dead when the
body ends would be read dead on the next iteration. The dead list already
tracks exactly that, and R3a already REMOVES a place from it on assignment, so
"still dead at the end of the body" is precisely "moved and not revived".
Revival therefore works for free:

```cell
while i < 3 {
    take(owned buf)
    buf = make()        // R3a revives it; the loop is accepted
    i = i + 1
}
```

A place declared **inside** the body is fresh each iteration and is never
subject to this rule.

**Where it is conservative, stated plainly.** A body that always `break`s
before reaching the move is rejected anyway, because this rule does not track
which paths reach the end of the body. That is the same trade section 0.3
already made, and it carries the same guarantee: every program accepted under
this rule is still accepted under a real control-flow analysis, so tightening
now and relaxing later never breaks source compatibility.

### R3a. A moved-from place may be revived by assignment

Assigning a fresh value to a dead place makes it live again. This is the escape
hatch that keeps R2 usable.

```cell
pub fn main() {
    var owned buf = Buffer { data: [], len: 0 }
    take(owned buf)                       // buf is dead
    buf = Buffer { data: [], len: 0 }     // buf is live again
    take(owned buf)                       // fine
}
```

The target must be mutable, so R14 applies first: reviving a `let` binding is
an immutable-assignment error, not a revival.

### R4. Any number of `shared` borrows may coexist

Shared borrows do not conflict with each other:

```cell
pub fn main() {
    let owned buf = Buffer { data: [], len: 0 }
    read(shared buf)
    read(shared buf)
}
```

### R5. Shared XOR exclusive

**While an `exclusive` loan of a place is live, no other loan of that place,
shared or exclusive, may exist, and the place itself may not be read.** While
any `shared` loan is live, no `exclusive` loan may be created.

This is the core aliasing rule and the reason the model is worth having.

```cell
pub fn main() {
    let owned buf = Buffer { data: [], len: 0 }
    let exclusive e = &mut buf
    read(shared buf)
    use_it(e)
}
```

> `err: cannot borrow 'buf' as shared: it is already borrowed as exclusive`
> `note: the exclusive borrow starts here and lasts to the end of this block`

The reverse case:

> `err: cannot borrow 'buf' as exclusive: it is already borrowed as shared`

And reading the owner directly through an exclusive loan:

> `err: cannot use 'buf' while it is exclusively borrowed`

Under the call-argument exception in 0.3, `read(shared buf)` followed by
`grow(exclusive buf, shared 1)` on consecutive statements is fine, because the
first loan ended when its call finished. Only loans bound to a name persist to
the end of the block.

**Still blocked, but only halfway.** `let exclusive e = &mut buf` parses and
builds a `unary` node with `UnaryOp.ref_exclusive` over an `ident`, so the
provenance *is* recoverable from the AST: walk the initializer, and if it is a
reference unary, record the binding as a loan of `rootName(operand)`. What is
missing is the checker state to hold that, not information in the tree.

### R6. Field borrows are disjoint

Borrowing `buf.data` and `buf.len` at the same time is legal, because they are
different places. Borrowing `buf` while `buf.len` is borrowed is not.

```cell
pub fn main() {
    let owned buf = Buffer { data: [], len: 0 }
    let exclusive d = &mut buf.data
    take(owned buf)
}
```

> `err: cannot move 'buf': its field 'buf.len' is borrowed`

Conflict test: two places conflict if either is a prefix of the other.

**Unblocked.** An earlier draft called this blocked on the parser, and that is
no longer true: `Expr.field` carries a real `base` pointer and a field name, so
a place can be represented as the vector of names from `rootName` outward and
compared by prefix. Nothing in the tree is missing.

### R7. A pattern binding inherits the scrutinee's ownership

Matching on an `owned` place moves it into the arm's bindings. Matching on a
`shared` borrow binds `shared`. Matching on `exclusive` binds `exclusive`.

```cell
pub fn main() {
    let owned c = classify()
    match c {
        other => consume(owned other),
        _ => 0,
    }
    use_it(shared c)
}
```

> `err: use of 'c' after it was moved`
> `note: 'c' was moved here by the match on it`

If any arm moves out of the scrutinee, the scrutinee is dead after the whole
`match`, not just in that arm.

**Unblocked for the patterns that exist.** `match` parses, and `Pattern.Kind`
has a real `binding` case, so a binding pattern can be given the scrutinee's
mode today. Two caveats stay: `Pattern` has no subpattern case, so this rule
cannot yet reach a payload binding (`Some(x)` does not parse, SPEC 8.3); and
the parser decides binding-versus-variant by whether the first letter is
uppercase, so a lowercase enum variant will be treated as a binding and
silently moved. That heuristic is the checker's problem to remove, and until it
is removed R7 inherits it.

### R8. A borrow may not outlive its referent

A function may not return a `shared` or `exclusive` reference, and may not
store one in a struct field, because Cell has no lifetime parameters to relate
the reference to its source.

```cell
pub fn peek(shared b: Buffer) -> shared Buffer {
    return b
}
```

> `err: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call`
> `note: return an 'owned' or 'arc' value instead`

This rule is a deliberate simplification for this revision; lifetime parameters
would replace it. Until then, a function that wants to hand back a reference
must hand back an `arc`. R11's "do not retain for a `shared` parameter"
optimization depends on this rule holding.

---

## 2. `arc`

### R9. `arc` grants shared access only

An `arc` value may be read and may be retained. It may **not** be mutated, and
it may not be borrowed as `exclusive`.

```cell
pub fn rename(arc n: String) {
    n = "other"
}
```

> `err: cannot assign through 'n': 'arc' grants shared access only`
> `note: mutation through 'arc' needs interior mutability, which Cell does not have yet`

Today this is caught, but by R14 and with R14's generic message, because
`checkFn` derives parameter mutability as `ownership == .exclusive or
ownership == .owned` and `arc` therefore lands on the immutable side. Measured.
That agreement is a derivation, not a rule; R9 should be stated explicitly so
the message explains the actual reason.

This is the conservative half of the Swift analogue. A Swift `class` reference
does permit mutation, and Cell will need either interior mutability or a
uniqueness check to allow it. Choosing conservatively now means a later
revision can relax the rule without invalidating existing programs.

### R10. `arc` and the other four modes

| Combination | Legal | Rule |
|---|---|---|
| `arc` place to an `arc` parameter | yes | retains; both holders live afterward |
| `arc` place to a `shared` parameter | yes | borrows the pointee for the call; no retain |
| `arc` place to an `exclusive` parameter | no | R9 |
| `arc` place to an `owned` parameter | no | see below. **IMPLEMENTED** in `borrowck.zig`, the only clause of R10 that is, and enforced at four positions rather than just this one |
| `owned` place to an `arc` parameter | yes | moved into a fresh `arc` box; the source is dead by R2 |
| `shared` or `exclusive` borrow to an `arc` parameter | no | see below |
| `copy` and `arc` on the same declaration | no | see below |

> `err: cannot pass 'arc' value 'n' to 'owned' parameter 'b': ownership is shared and cannot be made unique`
> `note: an 'owned' callee frees the value, and the 'arc' box would free it again`

That first row is enforced today, and the reason it is a REFUSAL rather than a
retain is worth stating, because "insert a `cell_arc_clone`" is the wrong
instinct here and was tried. `owned [T]` and `shared [T]` lower to the **same**
C type, `cell_slice_t` by value, so the C backend's unbox emitted
`take((*(const cell_slice_t *)xs.ptr))` and it compiled clean at
`-Wall -Wextra -Werror`. `runtime/cell_rt.h` section 7 makes an `owned` callee
responsible for the eventual free, and `cell_slice_drop_glue` frees the same
**buffer** again when the box dies. `cell_arc_clone` increments a refcount, and
the buffer is not what the refcount governs, so no retain can fix it.

**The refusal covers four positions, not one**, and the parameter row above is
only the first of them. An earlier revision refused the parameter alone and
said "only the conversion is refused", which was wrong twice over: the word
`parameter` was missing, and the other three positions were reachable.
Enumerated and each one measured:

| Position | Before the refusal |
|---|---|
| a call argument to an `owned` parameter | ASan double free, exit 134 |
| `let owned ys: [Int] = xs` | ASan double free, exit 134 |
| `ys = xs`, writing into an `owned` place | ASan double free, exit 134 |
| an `owned` struct field in a literal | not a double free **yet**: this backend never drops a `record`, so the field's buffer is freed once by the box's glue and the record merely outlives it. It becomes a double free when struct drops land, so it is refused with the others |

The `owned String` analogue of each was already a loud C type error, because
`owned String` and `shared String` do not share a C type, and `return xs` from
a `-> [Int]` function is loud for the same reason. They are refused here too on
purpose: one rule that holds for every type beats a rule whose enforcement
depends on which two C types happen to coincide.

**What stays legal**, since "the conversion is refused" has to be scoped to
mean something: every `arc`-to-`arc` use. `let arc xs = [1, 2, 3]` builds the
box, `let arc b = a` clones, an `arc` argument to an `arc` parameter clones,
and an `arc` argument to a `shared` parameter borrows without cloning. Only
making an `arc` place UNIQUE is refused. See
`examples/rejected/arc_to_owned.cell`.

The refusal is enforced by `cell check` and, **measured rather than assumed**,
by `cell emit` as well: `src/main.zig:164` calls `cell.check` before
`emitFor`, and `cell emit --target=c examples/rejected/arc_to_owned.cell`
exits 1 with this diagnostic and writes no C. An earlier revision of this
paragraph said `cell emit` does not run borrowck "true of every rule in this
file"; that is false for the CLI command. It is true of the LIBRARY entry point
`root.emitFor`, which takes an already-loaded module and runs no checker, so a
tool calling the library directly is on its own.

> `err: cannot create an 'arc' from a borrow: 'b' is a shared borrow and does not own its value`

> `err: 'copy' and 'arc' are mutually exclusive: an 'arc' value is shared by reference, not duplicated`

An `arc` place is **never** made dead by passing it. That is the whole point of
the mode, and the main practical difference from `owned`.

### R11. Retain and release insertion

The checker decides where these go; codegen emits them. The runtime functions
exist and work: `cell_arc_new`, `cell_arc_clone` (increment), and
`cell_arc_drop` (decrement, and call the drop function at zero), all in
`runtime/cell_rt.c`. **The refcounts are atomic** as of `562f116`, with the
`_Atomic` confined to the `.c` file behind an opaque `struct cell_rc_box` so
the header still compiles as C++20. An earlier draft said the counts were
non-atomic and that `arc` was therefore single-threaded; that is no longer
true, and the retain/release scheme below is thread safe with respect to the
count itself. It says nothing about the pointee, which is not synchronized.

Insert a **retain** (`cell_arc_clone`):

1. When an `owned` value is passed to or bound as `arc`: emit `cell_arc_new`
   rather than a clone, since the box does not exist yet.
2. When an `arc` place is passed to an `arc` parameter, at the call site,
   before the call. The callee then owns its own reference.
3. When an `arc` place is bound to a new `arc` binding (`let arc b = a`), after
   which both `a` and `b` are live.
4. When an `arc` place is stored in a struct field.

Insert a **release** (`cell_arc_drop`):

1. At the end of the innermost block in which an `arc` binding was created, for
   each such binding, in reverse creation order.
2. At each `return`, for every `arc` binding live at that point, **except** the
   one being returned.
3. Never for an `arc` parameter that is returned: a returned `arc` is returned
   **already retained**, and the caller owns that reference and must release
   it. `runtime/cell_rt.h` section 7 states the same contract from the C side.

Do **not** retain when an `arc` place is passed to a `shared` parameter. The
call cannot outlive the caller's own reference, so the caller's retain already
covers it. This is the one optimization the rule set builds in, and it is safe
precisely because of R8.

**Retain is implemented in the C backend; release is the drop pass, and the
two do not yet meet everywhere.** An earlier draft of this paragraph said
`arc T` mapped to `void*` and that no value of the right shape existed to pass
to these functions. That is stale: `arc T` is `cell_arc_t` (SPEC 10.3), an
`arc` binding is a `cell_arc_t` whether or not it carries a type annotation,
and `src/cell/codegen.zig` emits all four retains and the scope releases.
`examples/arc.cell` compiles, links against `runtime/cell_rt.c`, runs, and
prints a strong count that this rule set predicts.

What holds today, in the C backend alone (`llvmemit.zig` and `mlirmit.zig`
refuse `arc` outright and emit no drops at all):

- Retain rule 1 boxes a literal, a call result, or a `shared` view with
  `cell_arc_from_string` / `cell_arc_from_slice`. It does **not** box an
  `owned` String or list PLACE, because those helpers move their argument
  while `borrowck.zig`'s `checkLet` moves an initializer place only for
  `.owned` and an `.arc` call argument only reads it. R10's "moved into a
  fresh `arc` box; the source is dead by R2" is therefore unimplemented in the
  front end, and until it lands the backend leaves a C type error rather than
  emitting a silent double free.
- Retain rules 2, 3, and 4 emit `cell_arc_clone`, at the call site before the
  call, at the binding, and at the struct field store.
- The `shared`-parameter non-retain holds, and is asserted by an explicit
  absence test.
- Release rule 1 is function-scoped rather than block-scoped, and reverse
  creation order holds within that scope.
- Release rule 2's "except the one being returned" is paid for on the retain
  side instead: a returned `arc` local is cloned into the return temporary, so
  the drop that follows takes the count back to exactly the reference the
  caller now owns. This is because an `arc` place is never made dead by
  borrowck (`isDuplicable`, R10 by design), so the drop pass cannot recognize
  the exception itself.
- Release rule 3 holds for every returned `arc` place, and the rule codegen
  applies is stated as an exception rather than a list: **retain every
  returned `arc` place except a parameter returned directly.** A parameter is
  the one reference the frame received pre-retained and hands straight back.
  A local, a FIELD (`s.name`), and a match-arm binding all belong to something
  the caller does not own, so each is cloned.

### What still goes wrong, with the evidence for each

This section has been rewritten twice after review falsified it, and the
history is the most useful thing in it. Version one said the remaining gaps
were "leaks, never use-after-free"; review found two use-after-frees it
covered. Version two repeated the claim in softer words after a re-derivation
that searched **return-position places**; review found three more, all of them
on paths that are not places at all. So the claim is now stated together with
the shape of the search behind it, and the shape is the part that matters.

**Fixed, with tests, and named so the next reader knows what the tests are
for:**

1. **A returned `arc` field.** `return s.name` emitted a bare `return
   s->name;`, handing the caller the record's reference to release.
2. **A shadowed `arc` local.** Drops are spelled by name, so two visible
   bindings sharing one released the inner box twice and the outer never.
3. **An `arc` place flowing out of an `if`-expression branch.**
   `let arc r = if (c > 0) { a } else { b }` assigned into the statement
   expression's temporary without a retain, so `r` aliased `a`'s box and scope
   exit released both.
4. **An `arc` place flowing out of a `match` arm in return position.**
   `return match c { 0 => a, _ => a }`. A `match` IS valued in return position
   where an `if` is not, and it is not a place, so the return-position rule
   never saw it and `cell_arc_drop(a)` ran before the `return`.
5. **An `arc` place passed to an `owned` parameter**, now refused by R10 above
   rather than retained, because no retain can fix a double free of the
   buffer.

Numbers 3 and 4 had one root cause: a value slot is a position with a declared
type exactly as a parameter, a `let`, or a struct field is, and it was the only
such position not asking the conversion question. All five were silent at
`cell check` and clean under `-Wall -Wextra -Werror`; only running them showed
anything.

**Still broken, all of them leaks, each measured rather than asserted:**

| Gap | Evidence |
|---|---|
| A Cell body never releases its own `arc` parameter (no parameter is dropped), so every call-site retain into one leaks a reference | by construction; `examples/arc_host.c` is the ABI-correct contrast, and `examples/arc.cell` reports 0 leaks because of it |
| A struct holding an `arc` field is never dropped, so rule 4's retain leaks | `record` shapes are excluded from `hasDropCall` |
| An `arc` value unboxed for a `shared` parameter without ever being bound (`inspect(shared fresh())`) drops its handle on the floor | `leaks`: **2998 leaks / 63968 bytes** over 1000 iterations |
| An `arc` local declared inside a block OR A MATCH ARM is never released, because release is function-scoped and both are popped before the drop pass runs; inside a `while` body that is unbounded | `leaks`: **2997 leaks / 63936 bytes** over 1000 iterations for the block form |
| Reassigning an `arc` `var` leaks the previous box (`var arc v = "one"` then `v = "two"`), the same class as the R3a-revival leak R16 documents for `owned` | `leaks`: **3 leaks / 64 bytes** for a single reassignment |
| An `owned` String or list PLACE bound as `arc` is not boxed at all, and is left as a C type error rather than a silent double free | see retain rule 1 above |

### What the search covered, which is the honest form of the claim

Not "every remaining gap is a leak", which has been falsified twice. What can
be said is which positions were examined and with what.

**Place positions**: a `let`/`var` initializer, a call argument, a struct
literal field, a list element, an assignment's right side, and a `return`,
each for a bare identifier, a field path including a nested one
(`o.inner.name`), a parameter, and a shadowed binding.

**Value positions**, the ones version two missed and version three added: an
`if`-expression branch, a `match` arm, a block's trailing expression, and each
of those in initializer, return, and call-argument position, plus a `match`
scrutinee. A program exercising five of them at once runs clean under
AddressSanitizer and UndefinedBehaviorSanitizer, and its `leaks` output
accounts for exactly the three disclosed leaks above and nothing else. Two
value paths cannot be reached at all today for an unrelated reason:
typecheck gives every `if`-expression the type `()`, so an if-derived value
cannot flow into a typed parameter or an annotated binding, and the
un-annotated `let` is the reachable form.

**FORMS OF A MATCH ARM BODY**, added in version four because asserting a
property of "an arm body" from two of its forms is what reopened a
use-after-free. All five were written as programs and run, not reasoned about:

| Form | Result |
|---|---|
| `b => b`, the binding as the arm's value | reaches `emitValueInto`, cloned |
| `b => return b` | **parse error**, `return` is not an expression |
| a trailing `match` as a function's value | **typecheck error**, missing return |
| `b => { return b }`, a BLOCK arm body | reaches `returnedArcNeedsRetain`, cloned. This is the form that was missed |
| `b => { if (c) { return b } else { return b } }` | both branches reach it, both cloned |
| `b => { let arc keep = b ... }` | reaches `emitArgLike`, cloned |

**POSITIONS THAT MAKE AN `arc` PLACE UNIQUE**, added in version four, all
four enumerated rather than waiting for the next one to be reported: an
`owned` parameter, an `owned` binding, an assignment into an `owned` place,
and an `owned` struct field. R10 above refuses all four and tables what each
one did before the refusal.

**What that is not.** It is not a proof. It is a list of positions that were
written as programs and run. A position not on that list has not been ruled
out, and the record of this section is that unexamined positions have twice
contained a dangling reference.

**The landmine that was here is now a scar, and the scar is more useful.**
An earlier revision of this paragraph said `returnedArcNeedsRetain` could
safely spell R11 rule 3's exception as "not droppable", because a match-arm
binding could not reach it: `return` is not an expression in this grammar, so
`b => return b` does not parse, and a trailing `match` is not an implicit
return. **Both of those facts are true and the conclusion was false.** An arm
body may be a BLOCK, and a block's contents are statements, so

```cell
match s { b => { return b } }
```

parses, passes `cell check`, and reaches that branch; a nested `if` inside such
a block is a second form. Removing the `Local.is_param` field on that
derivation reopened a use-after-free that had been fixed. The field is
restored, the exception is parameter-only again, and both forms have tests.

The general lesson, which is the reason this paragraph is kept rather than
deleted: **enumerate the forms of a construct before asserting a property of
all of them.** Two forms of an arm body were checked and a third existed. The
same failure produced every finding in this section's history.

One cost of the restored field, stated because it is a real trade and not a
free win: when the scrutinee is an `arc` PARAMETER, the arm binding copies a
reference the function never releases, so cloning it leaks one instead of
dangling. Codegen cannot tell that scrutinee apart from a local one here, and
the asymmetry says take the leak.

A hand-written C callee that honours `cell_rt.h` section 7 and releases its
`arc` parameter balances exactly; `examples/arc_host.c` is one.

---

## 3. `copy`

### R12. What `copy` exempts

A `copy` place is exempt from R2, R3, and R6. Passing it, returning it, or
binding it duplicates the value; the source stays live.

```cell
pub fn main() {
    let copy n = 42
    consume(copy n)
    consume(copy n)   // legal: n was duplicated, not moved
}
```

`copy` does **not** exempt a place from R14: a `copy` binding declared with
`let` is still immutable, and assigning to it is still an error. Copyability
and mutability are independent, and the current checker already treats them so.

`copy` is an assertion by the programmer, not a derived property. A conforming
implementation must eventually reject it on types that own a resource:

> `err: 'copy' is not valid for 'Buffer': it owns a field of type '[Byte]'`

That check requires a type representation, which does not exist. Until it does,
**`copy` on a resource-owning type is an unchecked correctness hole**: it will
produce a shallow duplicate and then a double free. Say that plainly in user
documentation rather than implying `copy` is safe.

---

## 4. Annotation agreement

### R13. Annotations must be consistent

**R13.0 -- the borrow sigils are spellings, not annotations.** `&x` spells
`shared x`; `&mut x`, `&var x` and `&exclusive x` all spell `exclusive x`.
`refKind` normalizes every one of them to a `LoanKind` before any rule runs, so
none of R1-R17 has a case for them and R15 compares a sigil-derived mode
against a parameter exactly as it compares a written keyword. `&var` was
admitted from the CELL v2.0 surface and required no change to this checker.


1. A parameter may be annotated before the name (`shared a: Int`) or on the
   type (`a: shared Int`), never both.

   > `err: parameter 'a' is annotated twice: 'owned' before the name and 'shared' on the type`

2. The canonical form is before the name for parameters and struct fields, and
   on the type for return types and nested positions. A non-canonical form is a
   warning, not an error.

   > `warning: write 'shared a: Int' rather than 'a: shared Int' for a parameter`

3. A body file's definition must match its declaration exactly on ownership
   (SPEC 1.2, rule 11).

   > `err: 'grow' body does not match its declaration: parameter 1 is declared 'exclusive Buffer' but defined 'owned Buffer'`

4. **Prerequisite: scope the symbol table. DONE as of `8dd5673`.** The checker
   must push a scope per function and per block, because a module-wide map
   produces false positives and false negatives across function boundaries.
   Measured as fixed in 0.4. This no longer blocks the rules below.

### R14. Assignment requires a mutable place

Enforced by `src/cell/borrowck.zig`, not by the typechecker. Typecheck still
rejects a type mismatch on assignment; it does not also report R14.

```cell
pub fn main() {
    let copy x = 1
    x = 2
}
```

> `err: cannot assign to immutable binding 'x'`
> `note: 'x' is declared immutable here`

Measured: this fires with a real path, line, and column, names the place, notes
the `let`, and exits 1. `cell check examples/rejected/immutable_assign.cell`
prints the error once.

What works, verified:

- The target is an expression, and `ast.rootName` finds the base binding, so
  **field assignment is checked**: `b.len = 1` where `b` is an immutable `let`
  is an error.
- Parameter mutability follows the ownership mode: `exclusive` and `owned` are
  mutable; `shared`, `arc`, and `copy` are not. Measured for all three
  immutable modes.
- Diagnostics go through `Bag.render`, so they carry the source line and caret.

There is still no check that the target is *assignable* at all. Assigning to a
literal or a call result is accepted and emits nonsense C:

> `err: cannot assign to this expression: only a binding or a field of one is assignable`

### R15. Call-site annotation must match the parameter

An explicit ownership prefix on a call argument must equal the callee's
parameter annotation. Omitting it is legal and infers from the signature.

```cell
pub fn take(owned b: Buffer) { }

pub fn main() {
    let owned buf = Buffer { data: [], len: 0 }
    take(shared buf)
}
```

> `err: 'take' expects parameter 'b' as 'owned', but the argument is passed as 'shared'`

`&x` is an alternative spelling of `shared x` and `&mut x` of `exclusive x`, so
the same check applies to those, and those two *do* survive into the AST as
`UnaryOp.ref_shared` and `UnaryOp.ref_exclusive`.

**Implemented as of `67529a9`.** This rule was blocked on the parser for most
of the project's life: `parsePrimary` consumed the ownership keyword and
returned the operand's kind with only the span widened, so the prefix never
reached the checker. Three commits closed it. `b39c158` keeps the prefix as an
`annotated` wrapper on the argument node, `9917ec7` teaches `refKind` to peel
that wrapper so a written prefix does not disturb loan provenance, and
`67529a9` compares the written mode against the parameter's and reports the
diagnostic above.

Codegen learned about the new node (both `b39c158` and `9917ec7` touch
`codegen.zig`) but the emitted C for a call is unchanged: it still takes its
mangling and its address-of from the callee's signature, so `exclusive` still
emits `cell_grow(&buf, 16)`. The codegen test `a call site is lowered against
the callee's parameter ownership` pins that. The prefix is a checked assertion
about the call, not a lowering instruction.

---

## 5. Drops

### R16. An `owned` place is destroyed at the end of its scope

**Partially implemented as of `codegen.zig`'s drop insertion (task 3).** The C
backend now emits `cell_string_free`, `cell_slice_free`, or `cell_arc_drop`
for an `owned` or `arc` `let`/`var` local that borrowck's move analysis never
marks moved, at the end of its function's body and before every `return`, in
reverse declaration order. This is **not** the rule as stated above, in three
ways, and each is a real, documented gap rather than an oversight:

- **Function-scoped, not block-scoped.** A local declared inside a nested
  `if`/`match`/`while` block is dropped only if it is still live at the
  function's own end or at a `return`; if its enclosing block ends normally
  without either, it leaks. The rule above says "its innermost block";
  this implementation drops at the innermost *function*.
- **Conservative on moves, in the leak-safe direction.** Borrowck's move
  tracking merges branches conservatively (a move in one arm of an `if`
  marks the place moved for everything after it, whether or not that arm
  ran), so a conditionally-moved value is never dropped on any path,
  including the paths where it was not actually moved. That is a real leak,
  and it is intentional: dropping a maybe-moved place risks a double free,
  and leaking is the strictly safer failure.
- **"Moved" means moved anywhere in the function, once, permanently.** A
  `var` that is moved and later revived by a fresh assignment (R3a) is
  never dropped either, even though it holds a fresh, unmoved value at the
  function's end. The revived value leaks.

Also out of scope: a `struct` with owning fields is never destroyed (its
fields would need a generated per-struct drop function, a separate task),
and a parameter is never dropped (its value's ownership already transferred
to this function's *caller*'s intent, and only the function that consumed it
by moving it further would be the one to drop it -- which nothing here does
yet either, so a value moved into a function call also leaks today). R16 is
therefore **not complete**: what changed is that Cell no longer leaks
*every* `owned`/`arc` local unconditionally, not that it now leaks none.

### R17. Double free is prevented by R2, not by a runtime check

The model has no runtime ownership tracking, no sentinel value, and no
poisoning. Every double-free and use-after-free guarantee this document
describes rests entirely on the static rules above being implemented and
correct. **Until the checker exists, Cell provides no memory-safety guarantee
of any kind**, and no document in this repository should say otherwise.

---

## 6. Implementation order

Ordered so each step is testable and none depends on a later one. Steps marked
*(front end)* need a change under `src/cell/` outside the checker.

1. **Prerequisites.** Scoping (R13.4) is **done** as of `8dd5673`. What remains:
   fix R14's message, note, and rendering, and confirm parse errors reach the
   user (SPEC 11 and 0.5). None of these change the language.
2. **R1, R2, R3, R3a**: moves and use-after-move for whole bindings. Highest
   value, and needs only a per-place live/dead flag plus the spans that already
   exist. `examples/rejected/use_after_move.cell` is the first test.
3. *(front end)* **Keep the call-argument ownership annotation**, then **R15**
   and the explicit form of **R9**. The annotation and **R15** are **done** as
   of `67529a9`; the explicit form of **R9** is not.
4. **R4, R5**: shared XOR exclusive, with the lexical loan scopes of 0.3.
   Needs loan provenance recovered from `&`/`&mut` initializers.
5. **R6**: field-path disjointness, using `Expr.field` and `rootName`.
6. **R7**: pattern binding ownership, for the pattern forms that exist.
7. *(codegen)* **R10, R11**: `arc` semantics and retain/release insertion.
   Needs `arc T` to lower to `cell_arc_t` first.
8. **R12**: `copy` checking. Needs a type representation.
9. **R8, R17**: escape checking and the runtime side of the double-free
   guarantee. **R16 (drop insertion) is partially done** without a
   control-flow graph, by consuming borrowck's existing conservative move
   tracking directly (function-scoped, `let`/`var` locals only, structs
   excluded); see R16 above for exactly what landed and what did not.
   Revisiting 0.3 in favor of NLL is still gated on a real control-flow
   graph, which nothing here builds.

Steps 1 through 3 would give Cell a real move checker. Everything after that is
the harder half.

---

## 7. Related documents

- `docs/SPEC.md`: the language specification, section 4 on the five annotations
  and section 12's construct-by-construct status index.
- `examples/ownership.cell`: the annotations as they parse today.
- `examples/rejected/`: programs that pass `cell check` today and that a
  conforming implementation must reject. Each names the rule it violates, and
  together they are the checker's first test corpus.
