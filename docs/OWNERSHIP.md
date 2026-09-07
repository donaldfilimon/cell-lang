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
R10/R11 retain-release insertion and NLL are still designed. Stem pairing has
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
| `arc` place to an `owned` parameter | no | see below |
| `owned` place to an `arc` parameter | yes | moved into a fresh `arc` box; the source is dead by R2 |
| `shared` or `exclusive` borrow to an `arc` parameter | no | see below |
| `copy` and `arc` on the same declaration | no | see below |

> `err: cannot pass 'arc' value 'n' to 'owned' parameter 'b': ownership is shared and cannot be made unique`

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

**Blocked on codegen, not on the front end.** `arc T` currently maps to `void*`
rather than to `cell_arc_t` (SPEC 10.3), so there is no value of the right
shape to pass to any of these functions.

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

Every `owned` binding still live at the end of its innermost block is destroyed
there, in reverse declaration order. A binding that was moved out (dead by R2)
is **not** destroyed: its new owner is responsible.

At a `return`, every live `owned` binding except the returned one is destroyed
first.

There is no destructor syntax and no drop code generation. `owned` emits
nothing today.

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
9. **R8, R16, R17**: escape checking and drop insertion. Needs a control-flow
   graph, at which point revisiting 0.3 in favor of NLL is worthwhile.

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
