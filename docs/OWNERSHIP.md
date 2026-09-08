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
exclusive), R8 (escaping borrow), R9 (`arc` grants shared access only: no
exclusive borrow of an `arc` place and no write through one), R14 (assignment
through an immutable place, including fields, and the second clause that
refuses reassigning a binding which already holds a borrow), and R15
(call-site annotation agreement). Diagnostics name
the place and land at the use site. That file's header comment is the
authoritative list and moves with the code; believe it over this paragraph.
Named-loan NLL slices 1 and 2 are enforced as described in section 0.3;
derived-loan propagation remains conservative. See [FEATURES.md](FEATURES.md)
for the current cross-backend matrix, rather than treating this historical
summary as an exhaustive rule inventory. **R11** retain-release insertion is implemented in the
C backend, with the gaps R11 itself names; **R10**'s move-into-`arc` is not
implemented in the checker, which is why one of those gaps exists. R10's other
direction, an `arc` value made UNIQUE, IS implemented, at six consumption
sites and with a total verdict that refuses a source it cannot classify. **R2.a**
(a move inside a loop) landed with `while`. **R18** (an `owned` binding may not
be initialized from a borrow) landed after a live double free that every borrow
SPELLING reached differently. **R2.b** (an `owned` position is
asked of the EXPRESSION, and a value that may yield a place on some paths is
refused rather than read) landed after four live double frees; it is the
general rule R10's first axis was a special case of. Stem pairing has
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

### 0.3 Borrow scope: lexical, with a non-lexical end for named loans

**A loan lives from its creation to the end of the innermost enclosing block,
or until its holder can no longer be reached, whichever comes first.**

Three exceptions narrow the lexical bound, and the first two make the common
case work without analysis:

1. A borrow created as a call argument (`f(shared x)`, `f(&x)`) ends when that
   call statement completes. It does not survive to the end of the block.
2. A borrow created inside an `if` condition or a `match` scrutinee ends when
   that expression finishes.
3. **A NAMED loan ends as soon as its holder is provably never reached again.**
   This is the non-lexical rule, and it is enforced: `src/cell/borrowck.zig`'s
   `loanStatusAt` decides it, and all four conflict sites (a new borrow, a
   read, a move, an assignment) skip a loan it calls dead.

```cell
pub fn main() {
    let owned buf = Buffer { len: 0 }
    let exclusive e = &mut buf
    grow(exclusive e, shared 1)
    let copy n = read(&buf)         // accepted: `e` is dead after the call
}
```

`examples/nll_dead_borrow.cell` is the corpus form of this, one function per
conflict site.

#### What "provably never reached again" means, exactly

Two conditions, both required. Neither can see what the other sees, and
together they cover a loan's whole live range:

- **Forward.** The holder is mentioned nowhere from the statement being checked
  to the end of the block that owns the loan. The current statement counts in
  FULL, and so does any statement containing an inner block, so a use nested
  anywhere inside the current statement, and a use only a second loop iteration
  reaches, both read as "used".
- **Window.** Between the loan's own `let` and the statement being checked, at
  the loan's own block level, the holder is mentioned only as a **direct
  argument of a call** (optionally under an ownership keyword or a `&`/`&mut`
  sigil). Every other mention -- a `let` initializer, either side of an
  assignment, a `match` scrutinee or guard, a struct-literal field, a list
  element, an `if`/`match`/block value position -- ends the analysis in
  `ineligible`, which rejects.

The whitelist is stated as the complement on purpose. It does not enumerate the
positions that propagate a reference and assume the rest are safe; it names the
one position that provably cannot, and rejects everything else. **Rejecting is
always safe here. Only acceptance needs proof.**

#### Why a direct call argument cannot propagate a reference

R8. A callee may not return a `shared` or `exclusive` borrow and may not store
one in a struct field. Cell has no lifetime parameters, no references inside
aggregates, and no closures, so a callee has nowhere to put what it is handed.
`src/cell/borrowck.zig` carries a test named for this invariant; **if lifetime
parameters ever land, that test fails and this rule must be revisited with
it.**

#### Why this needs no control-flow graph

The same R8 argument. A loan value cannot escape the block that created it, so
its region is already bounded by the holder's lexical block, and the
non-lexical rule only shrinks that bound. "Is there a forward path from here
that still reaches this loan" is therefore answerable syntactically in this
language. An earlier revision of this document said revisiting 0.3 was gated on
a real control-flow graph; that was wrong, and the checker was not ported to
one.

`src/cell/liveness.zig` was measured against this and rejected: it is
SLOT-level where the borrow checker is PLACE-level (`buf` versus `buf.len`),
and its own doc comment records an unclosed allocation-order drift whose
failure direction is "a live slot reads as dead", which for a borrow checker
means accepting too much. It stays reserved for R16's drop pass.

#### What is deliberately NOT implemented

A **taint closure over derived bindings**. `let exclusive f = e` copies the loan
into a second holder, and the checker does not follow it: any such mention
makes the loan `ineligible`, so the program is rejected. That is conservative,
not unsound, and `examples/rejected/aliasing.cell` plus the last function of
`examples/nll_dead_borrow.cell` pin it.

Every program accepted under the older, purely lexical rule is still accepted,
so this relaxation cannot break source compatibility.

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

**That list names the forms a PLACE takes, and reading it as a list of
initializers is what R2.b below exists to correct.** Every one of the five
positions asked `placeOf` first and READ anything else, so an `owned` slot
filled by a `match` double freed. R2.b is where the question is asked of the
expression instead.

**The fifth entry STILL OVERCLAIMS, and this was measured rather than assumed.**
"Moved into a `match` arm binding (R7)" is not enforced as a MOVE: the
scrutinee is not moved at all, and R7's consumption clause below refuses the
consumption instead of performing the move. Read the entry as "consuming an
arm binding is refused", not as "the scrutinee is dead after the match".
Before that refusal existed:

```cell
pub fn mk() -> String;
pub fn take(owned s: String);

pub fn main() {
    let owned s1 = mk()
    match s1 { x => take(owned x) }
}
```

emits `cell_string_t x = s1;`, then `cell_take(x)` frees the buffer, then
`cell_string_free(&s1)` frees it again: **AddressSanitizer double free, exit
134**, measured at `1dd0e6b`. It behaves identically whether the scrutinee is a
plain place or a value shape (`match (match c { 0 => s1, _ => s1 }) { ... }` is
also 134), which is what tells it apart from R2.b: R2.b is about a consumption
site asking the wrong question, and this is a consumption site that asks no
question. It was **not fixed there**, deliberately; it is fixed under R7 below,
and by a REFUSAL rather than by the move. Moving the scrutinee changes what
`wasMoved` reports for every arm binding, and `codegen.zig`'s `pendingDrops`
reads exactly that, so it remains a separate change with its own measurement.

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

R3 is the move direction. **R18 below is the same principle read the other
way**: a borrow cannot hand ownership to a binding either.

### R18. An `owned` binding may not be initialized from a borrow

An `owned` binding takes ownership and is destroyed at the end of its scope
(R16). A borrow does not confer ownership, so the two cannot be combined: the
lender is still live, still owns its value, and is still dropped, and the
binding is dropped as well.

```cell
pub fn fresh() -> [Int];

pub fn main() {
    var owned list = fresh()
    let owned xs = &list
}
```

> `err: cannot bind a borrow of 'list' to the 'owned' binding 'xs': a borrow does not confer ownership`
>
> `note: R18: an 'owned' binding is destroyed at the end of its scope (R16), so binding one to a borrow frees the lender's value twice; write 'let shared xs' or 'let exclusive xs' to hold the borrow`

**This was a live double free, and the numbering is late because the rule is.**
Measured at `b61a107`: `cell check` exit 0, the emitted C carrying
`cell_slice_free(&xs)` and `cell_slice_free(&list)` for one buffer,
`cc -fsanitize=address` exit 0, and running it
`AddressSanitizer: attempting double-free` at **exit 134**.

**Asked of the whole initializer, and of every spelling.** R13.0 says the sigil
and keyword borrows are spellings of one construct, and before this rule they
got three different answers:

| `let owned xs = ...` | drops emitted | result |
|---|---|---|
| `&list`, `&mut list`, `&var list`, `&exclusive list` | 2 | exit 134, double free |
| `shared &list`, `exclusive &list` | 2 | exit 134, double free |
| `let xs = &list` (R1 default) | 2 | exit 134, double free |
| `shared list`, `exclusive list` | 1 | exit 0, and the lender silently MOVED |

`&list` and `shared list` emitted byte-identical C, so the initializer lowering
was never the defect; the number of scheduled drops was. `checkLetInit` opened
with a branch matching `refKind` -- the sigils -- that created a loan without
reading the binding's ownership, and returned before the `owned` move could
run. The keyword spellings missed that branch, fell through, and moved the
lender out from under a written `shared` prefix, which is the same defect
wearing exit 0.

The last two rows are why the rule refuses **all** of them. A fix that left
them split would be wrong even where the split is safe-versus-safe: the
language says they are one construct.

**Enforced by one question, not a list.** `src/cell/borrowck.zig` asks
`borrowSource` -- the classifier R14's rebinding clause already uses -- once,
above every branch that could answer differently. Its switch is exhaustive with
no `else`, so a new expression kind fails to compile rather than falling
through permissively, and a new borrow spelling is refused without a second
edit at this site. It also reaches shapes no enumeration would have listed: a
borrow supplied by one arm of an `if` or a `match`, and a callee whose declared
return type is a borrow.

**Not covered, stated rather than left to be found.** `.unresolved` is not
refused at this position, because R2.b's `ownedMoveSource` is total at the same
site and already reports the useful half of that set. What is left is a callee
this checker cannot resolve, which typecheck reports as an unknown name; an
indirect call returning a borrow would slip through, and this grammar has no
function values to write one with. The rule is also scoped to `owned`: an `arc`
or `copy` binding initialized from a borrow is R10's and R12's question, and
neither is asked here.

`examples/rejected/owned_from_borrow.cell` is the corpus form and lists every
spelling. `examples/let_binding_modes.cell` holds the legal neighbours the rule
must not eat: `let shared s = &buf` and `let exclusive e = &mut buf`.

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

### R2.b. An `owned` position is asked of the EXPRESSION, and an undecidable one is refused

R2's list above names the forms that move a **place**. Every consumption site
used to ask `placeOf` first: a place moved, and **anything else fell through to
an ordinary read**. That is an enumeration of place initializers standing in
for a claim about every initializer, and `placeOf` returns null for a `match`,
so this was accepted:

```cell
pub fn mk() -> String;
pub fn use_it(shared s: String) -> Int;

pub fn main() {
    var copy c = 0
    let owned s1 = mk()
    let owned s2: String = match c { 0 => s1, _ => s1 }
    print_int(use_it(shared s2))
}
```

`s1` was READ rather than moved, `wasMoved(s1)` stayed false, and codegen's
`pendingDrops` kept **both** `s1` and `s2`, because both are droppable,
`.owned`, have a drop call and are not moved. `emitValueInto`'s leaf emitted a
bitwise `_cell_t0 = s1;`, so the two headers held one buffer:

```
cell check                  exit 0
cc -fsanitize=address       exit 0
running it                  exit 134   AddressSanitizer: attempting double-free
```

Measured at `0e82266`. **There is no `arc` in this program.** It is ordinary
`owned String` code and it predates all of the `arc` ownership work; R10's axis
1 closed exactly this shape for `arc` sources and left it open for every other
source, which is what makes this the general rule and R10 a special case of it.

> `err: cannot bind the place 's1' reached through a branch to 'owned' binding 's2': which owned place it gives up cannot be resolved here`
> `note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path`

**Why refusal and not a move.** A `match` yielding a place from two arms is two
potential moves of ONE value, and deciding which arm ran is the dataflow
question section 0.3 deliberately does not answer. Reading it, which is what
happened before, is the one answer that is definitely wrong. Refusing is the
same trade 0.3 already made and carries the same guarantee: a program accepted
under this rule stays accepted under a real control-flow analysis.

**The classifier is total.** `ownedMoveSource` returns `no_owned_place`,
`place`, or `unknown`, and `unknown` is REFUSED. It is not an optional whose
"none" means permit, because that is the permissive default all three of R10's
widenings escaped through. A place reached through a branch is never `place`:
`ownedMoveBranch` promotes it to `unknown`, so no recursive arm can hand a
movable place back up.

**Six consumption sites, and the count is the point.** The brief that opened
this rule named four and two of the ones it did not name were live:

| Position | At `0e82266` |
|---|---|
| `let owned s2: String = match ...` | ASan double free, exit 134 |
| `s2 = match ...`, writing into an `owned` place | ASan double free, exit 134 |
| a call argument to an `owned` parameter | ASan double free, exit 134 |
| a `return` whose declared return type is not `arc` | ASan double free, exit 134 |
| an `owned` struct field in a literal | ASan double free, exit 134 after the copied field is moved out; now refused for resource-bearing destination types |
| a list-literal ELEMENT | latent: slice elements are never released (R11) |

The struct-field position now classifies the declared destination type. A
resource-bearing owned field permits only a fresh value; a place, borrow,
match alias or unresolved source is refused because aggregate transfer and
partial-move drop state are absent. Scalar and recursively resource-free fields
retain the existing behavior. List elements remain a separate transfer and
release gap.

**What still compiles**, since "refused" has to be scoped to mean something:

```cell
let owned s2: String = s1                                  // moves, R2 unchanged
let owned s2: String = match c { 0 => mk(), _ => mk() }     // fresh on every path
let owned n: Int = match c { 0 => 1, _ => 2 }               // scalar arms
let owned b: Box = Box { s: mk() }                          // fresh field value
```

**The named over-refusal.** A `match` over `copy` places in an `owned` slot was
accepted before this rule and is not now:

```cell
pub fn pick(copy c: Int, copy a: Int, copy b: Int) -> Int {
    return match c { 0 => a, _ => b }        // refused
}
```

A `copy` place is exempt from R2 by R12 and `pendingDrops` never drops one, so
an exemption looks free. It was considered and rejected: the exemption would be
an enumeration of the ownership modes this backend drops today asserted over
every `copy` place, which is the reasoning failure this rule is an instance of,
and the neighbouring claim is already false, because `copy String` is spellable
and `let owned s: String = a` over one emits a shallow header copy and frees
`a`'s buffer through `s`. Bind the value to a `copy` name and hand the name
over:

```cell
let copy r = match c { 0 => a, _ => b }
return copy r
```

Corpus: `examples/rejected/owned_move_through_match.cell`, which carries the
measurements.

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

#### R7's consumption clause: an arm binding may not be consumed while the scrutinee still owns the value

**Enforced.** `borrowck.zig`, `ArmOrigin` and `ownedMoveSource`'s
`.aliases_place`.

The scrutinee is READ, never moved, so an arm binding is an ALIAS of it and not
a second owner. Every `owned` consumption site asked `placeOf`, got a perfectly
good place rooted at the arm binding, and moved THAT, leaving the scrutinee
live and both headers holding one buffer.

```cell
pub fn main() {
    let owned s1 = mk()
    print_int(match s1 { x => take(owned x) })
}
```

> `err: cannot pass the match binding 'x' aliasing 's1' to 'owned' parameter 's': the scrutinee still owns the value`
> `note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again`

Measured at `4698dbc`, that program was `cell check` exit 0, `cc
-fsanitize=address` exit 0, running it exit 134. **Eleven shapes were live**,
not the one the brief named: the call argument, a `return`, an assignment into
an `owned` place, a `var owned` scrutinee, an `[Int]` scrutinee, a `shared [T]`
parameter as scrutinee, an arm binding nested one `match` deep, a multi-arm
`match` where only the last arm consumes, the same inside a `while`, an
`arc [Int]` place whose arm binding launders R10 (`take_list(owned a)` was
already refused, `match a { x => take_list(owned x) }` was exit 134), and that
`arc` case nested one deep as well.

**The condition is "does anything else still own this", not "is this an arm
binding".** A scrutinee with no place behind it -- a call result, a literal, a
fresh aggregate -- has no other owner, so
`match make() { x => take(owned x) }` still lowers and still runs (measured
exit 0 before and after).

That answer does **not** propagate to a nested `match`, and the first version of
this rule was wrong to let it. It reasoned that a scrutinee which is itself a
whole temporary arm binding has no other owner either, so
`match fresh() { x => match x { y => take(owned y) } }` could stay accepted.
Sound about ONE consumer, false about two:

```cell
match fresh() { x => match x { y => take(owned y) } + take(owned x) }
```

was **exit 134** under that version. `x` and `y` are two different bindings
holding one buffer, so R2's use-after-move cannot see it, and nesting a `match`
is the ONLY construct in this grammar that makes two live handles on one value
(`let owned y = x` moves `x`, which is why the `let` spelling was already safe).
The single-consumer nesting is therefore a documented over-refusal, and closing
the class beats keeping one contrived program.

**It reads, and does not refuse, at the struct-field and list-element
positions**, exactly as a plain `.place` does there. `Tag { name: x }` with an
aliasing `x` and `Tag { name: s1 }` with the scrutinee itself are one latent
hazard, R11's record drop and element release, and neither is a double free
today.

**The designed follow-up: MOVE the scrutinee instead.** Moving is the better
semantics, it would make `take(owned s1)` after the match report use-after-move
for the right reason instead of being silently accepted, and it would let the
refusals above become moves. It is not done yet because it changes `wasMoved`
for every arm binding and `codegen.zig`'s `pendingDrops` reads exactly that, so
it reschedules drops: three separate fixes in this repository shipped a new
silent miscompile in the fixer's own first commit by changing what a binding
holds or when it is dropped without asking what reads that. It needs its own
measurement of the emitted C, not a rider on a refusal.

**Residual, disclosed rather than left to be rediscovered.** The `.temp` row is
accepted today only because nothing drops a call temporary. So
`match make() { x => take(owned x) }` and its `arc` spelling LEAK rather than
double free, which is the safe direction under the same asymmetry R11 uses, and
they become double frees the day precise drops land. Whoever lands those drops
must revisit `ArmOrigin.temp`.

**Resolved by conservative refusal.** R2.b formerly left a plain place as a
READ at the struct-literal field position. That was unsafe whenever the copied
field was later moved back out:

```cell
let owned s1 = make()
let owned t: Tag = Tag { name: s1 }
take(owned t.name)
```

was exit 134. `t.name` was a bitwise copy of `s1` at a different place, so R2
saw no use-after-move and both were freed. The checker now refuses the field
initializer without pretending to move `s1`; true transfer remains blocked on
aggregate drop and partial-move state.

Corpus: `examples/rejected/owned_move_through_match_binding.cell`.

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

**IMPLEMENTED in `borrowck.zig`.** The rule has two halves and they are
enforced at different places, because they ask different questions.

**The borrow half: an `arc` place may not be borrowed as `exclusive`.**
Enforced in `createLoan`, which is the ONE point every exclusive loan passes
through, so the keyword form (`grow(exclusive s, ...)`), both sigil forms
(`&mut s`, `&exclusive s`), and both `let` forms (`let exclusive e = &mut s`,
`let exclusive e = s`) are all covered by one check rather than by five copies
of it. A `shared` borrow of an `arc` place stays legal, which R10's table
requires: it borrows the pointee without retaining, and R8 keeps it inside the
block.

**The mutation half: an `arc` place may not be written through.** Enforced in
`checkAssign`, asked of the STRICT prefixes of the target's path. `b.n = 2`
where `b` is `arc` mutates the shared value and is refused; `b = other` where
`b` is a `var arc` REBINDS the handle, does not touch the shared value, and
stays legal (it is R11's leak of the previous box, not R9's rule).

**R9 prints its own message for a write through a MUTABLE `arc` holder only**,
which today means a `var arc` binding. `let arc b` then `b.n = 2`, and an
`arc n: Buffer` parameter then `n.len = 1`, are both refused too, but by R14's
immutability check, which runs first and reports `cannot assign to immutable
binding`. Measured, both of them. The program is refused either way and no
mutation escapes; what varies is which rule explains it. Stating it here rather
than letting "R9 owns writes through `arc`" be read as more than it is, since
an overclaimed guarantee is exactly what this rule's implementation was
answering.

**The classifier is total and walks the whole chain**, the binding plus every
field segment, and a step whose annotation cannot be read is REFUSED rather
than permitted. That is the same discipline R10's `arcUniqueSource` had to
adopt, for the same reason: every one of R10's three widenings escaped through
a permissive default, and silence is what an unenumerated form produces. One
consequence bounds the over-refusal: a one-segment write such as
`b.len = b.len + 1` through an `exclusive b: Buffer` asks only about the
binding, so no struct has to resolve and the unresolved case cannot reach it.

**The unresolved case is REAL and it has had to be closed twice already**, both
times by teaching a declaration the struct type it was dropping, never by
weakening the verdict. `let exclusive e = &mut buf` carried no struct name, so
`&mut e.data` was undecidable; `checkLet` now propagates the referent's type
across the borrow. A `match` arm binding carried none either, so
`match src { x => use_bytes(&mut x.data) }` was undecidable; `checkMatch` now
propagates the scrutinee's type to the binding (the TYPE only, not the
ownership, so this is not R7). **Residual, stated rather than left to be
rediscovered:** an `if` or a block yielding a struct into an UNANNOTATED `let`
still leaves the binding with no struct type, so an exclusive borrow of one of
its fields is refused with "cannot be resolved here". Write the type
(`let owned s: Session = ...`) and it resolves. If a valid program starts
failing that way, the fix is another propagation like these two, not a
permissive default.

**What was measured before this landed**, every one at `cell check` exit 0
against `zig-out/bin/cell` built at `b3698a7`, and every emitted C accepted at
`-Wall -Wextra -Werror` except the last:

| Program | Emitted C | Loud? |
|---|---|---|
| `let arc s = "x"` then `grow(exclusive s)` | `cell_grow(((cell_string_t *)s.ptr))` | no, a mutable pointer into the shared box |
| the same with `grow(&mut s)` | identical | no |
| `H { arc h: String }` then `grow(&mut b.h)` | `cell_grow(((cell_string_t *)&b.h.ptr))` | no, and it aims at the handle's own pointer field |
| `var arc b` then `b.n = 2` | `cell_arc_t b = ...; b.n = 2;` | yes, `cc` refuses it |
| `grow(&mut fresh())` with `fresh() -> arc String` | `cell_grow(((cell_string_t *)&cell_fresh().ptr))` | yes, `cc` refuses the address of an rvalue |

The last row is the PLACE-versus-VALUE axis, R10's axis 1 recurring in a new
rule: `createLoan` is the choke point for exclusive loans and a loan is only
created for a place, so a value never reached it. It is refused now, in
`refuseArcValueBorrow`, at BOTH sites that can reach it, because `checkCall`
peels the sigil itself and hands `checkExpr` the operand rather than the unary
node. Fixing only the unary arm left the measured program accepted, which is
this file's own failure mode caught inside its own fix.

**`docs/SPEC.md` 4.1.4 claimed this was already forbidden while all five
compiled.** These docs underclaim elsewhere, which costs confidence and nothing
else; here the claim was that a class of aliasing mutation could not be
written, and it could. That is the one direction of documentation error this
repository cannot afford, and it is why the rule was implemented rather than
the sentence softened. `examples/rejected/arc_exclusive_borrow.cell` is the
corpus form and carries the measurements.

**What is still NOT R9's message.** The example above, `arc n: String` with
`n = "other"`, has an EMPTY path, so it is a rebind of the parameter's own
handle and R9's mutation half does not ask about it. It is still refused, still
by R14's immutability derivation (`checkFn` makes a parameter mutable exactly
when it is `owned` or `exclusive`, so `arc` lands on the immutable side), and
still with R14's generic message. `examples/rejected/arc_mutation.cell` pins
that, unchanged. The explicit R9 wording for a parameter rebind remains
designed only; the diagnostic above is what R9 prints for the forms it does
own.

**Why refusal and not a copy-on-write or a retain.** `arc` shares ONE value
between holders and Cell has no interior mutability, so a unique reference into
the box is an aliasing violation and a data race at once, and the refcounts are
atomic (SPEC 4.1.4) precisely because holders may be on different threads.
Nothing can be inserted that makes the write correct: either it is visible to
every holder, which R9 forbids, or the value is silently forked, which is not
what the program asked for.

This is the conservative half of the Swift analogue. A Swift `class` reference
does permit mutation, and Cell will need either interior mutability or a
uniqueness check to allow it. Choosing conservatively now means a later
revision can relax the rule without invalidating existing programs.

### R10. `arc` and the other four modes

| Combination | Legal | Rule |
|---|---|---|
| `arc` place to an `arc` parameter | yes | retains; both holders live afterward |
| `arc` place to a `shared` parameter | yes | borrows the pointee for the call; no retain |
| `arc` place to an `exclusive` parameter | no | R9. **IMPLEMENTED** in `borrowck.zig` as of the R9 work above, at `createLoan`, which covers every spelling of an exclusive borrow rather than this position alone |
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

**The refusal covers six positions, not one**, and the parameter row above is
only the first of them. An earlier revision refused the parameter alone and
said "only the conversion is refused", which was wrong twice over: the word
`parameter` was missing, and the other positions were reachable. A later one
said four, which was the same mistake with a bigger number. Enumerated and each
one measured:

| Position | Before the refusal |
|---|---|
| a call argument to an `owned` parameter | ASan double free, exit 134 |
| `let owned ys: [Int] = xs` | ASan double free, exit 134 |
| `ys = xs`, writing into an `owned` place | ASan double free, exit 134 |
| an `owned` struct field in a literal | a plain owned place was a live double free when the field was later extracted; resource-bearing destinations now require a fresh value |
| a list-literal ELEMENT, `let owned zss: [[Int]] = [xs, xs]` | accepted, and clean at `-Werror`. Not a use-after-free **yet**, only because slice elements are never released; closing that separately disclosed gap detonates it |
| a `return` whose declared return type is not `arc` | a loud `cc` type error (`cell_slice_t x = cell_arc_clone(...)`), which is protection by a coincidence of two C types and is what this rule's own text objects to. `-> arc T` is untouched: it is the legal arc-to-arc case |

A list element is refused **context free**, since a list literal copies each
element by value into a buffer the list owns and no element-level annotation
exists to say otherwise. That over-refuses an `arc` element in a list bound as
`arc`, which is safe today; over-refusing is the direction this rule takes on
purpose.

**THE REFUSAL IS ASKED OF THE EXPRESSION, NOT OF A PLACE, AND IT WAS NOT
ALWAYS.** Each of the four positions above used to ask `placeOf` first and only
then whether that place was `arc`. A `match` is valued and is not a place, so
`placeOf` returned null and **all four positions let it straight through.**
Measured, on the same `arc` binding and the same semantic operation:

```
take(owned xs)                            refused, exit 1
take(owned match c { 0 => xs, _ => xs })  ACCEPTED, exit 0
```

and identically for `let owned ys: [Int] = match ...`, `ys = match ...`, and an
`owned` struct field. The emitted C unboxed the arc and handed the box's slice
by value to an `owned` parameter, which is precisely the shape this rule's own
text names as the double free it exists to prevent. It was masked, not absent:
the `cell_arc_clone` in the value temporary held the refcount off zero, so a
later change that releases that temporary would have turned the mask into a live
double free. Refused now by one shared `arcUniqueSource` that looks THROUGH the
value positions, used by all four sites rather than copied to a fifth.

**This is the same axis, place versus value, that produced `arc`
use-after-frees three and four**, where an earlier search covered
return-position PLACES and not VALUE positions. Enumerating four *positions* and
asserting a property of every *consumption* is that mistake one layer up.

`if` and a block tail are covered too, although neither can reach a typed
`owned` position through `cell check` today: typecheck gives both the type `()`
and refuses the argument first. That is an accident of the type checker, not
enforcement of this rule, and this document objects elsewhere to a rule whose
enforcement depends on a coincidence of two types. Borrowck runs independently
of typecheck, so its own tests pin both forms on their own merits.

**THE SECOND AXIS, the arc SOURCE: a CALL RESULT whose return type is `arc`.
This one was a LIVE double free, not a masked one, and it is now CLOSED.**
`take(owned fresh())` with `fresh() -> arc [Int]` was accepted at exit 0. The
`arc`-ness comes from a signature's return type rather than from a binding's
annotation, so no place and no expression shape carries it, and the widening
above could not reach it. Measured end to end before the fix: `cell check` exit
0, `cc -Wall -Wextra -Werror -fsanitize=address` exit 0, running it **exit
134**, with frames `cell_slice_free` under `cell_slice_drop_glue` under
`cell_arc_drop` under `cell_main`. Closed by reading the callee's declared
return type; `examples/rejected/arc_call_to_owned.cell` is the corpus form.

**The ordering claim that covered it was false, and this is the reusable
part.** `23353e9`'s commit message says its fix "lands before any such change
and not after", meaning before the unbound-temporary release that would turn a
leak into a double free. Re-measured per program, because the answer is not the
same for both:

| Program | at `1aacf5d` | at `460b9a3` | at `23353e9^` |
|---|---|---|---|
| `take(owned fresh())`, the call result | no drop, a leak | `cell_arc_drop(_cell_t4)`, **live double free** | live double free |
| `take(owned match c { 0 => xs, _ => xs })`, the value position | not measured | not measured | cloned, never dropped, genuinely masked |

So the mask came off for the call-result form in `460b9a3`, **seven commits
before** the fix that claimed to be preempting it, and that program was a live
double free for the whole stretch. The claim was true of the program `23353e9`
actually fixed and false of the one it did not, which is why the two had to be
emitted and read separately rather than reasoned about together.

**THE THIRD AXIS, the consumption SITE, also closed.** Four positions were
enumerated and a property of every consumption asserted. A list-literal element
and a `return` are consumptions that were never asked; both are now. The rule is
asked at SIX sites (see the table below), and the classifier's verdict is
**total**: a source whose ownership cannot be resolved is `unknown` and REFUSED
rather than permitted. That is the structural point. The classifier used to
return an optional place, so any form it did not recognise fell out as "none"
and was accepted, which made silence mean safe, and silence is exactly what an
unenumerated form produces. All three axes escaped through that one permissive
default.

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
by `cell emit` as well: `src/main.zig`'s `emit` branch calls `cell.check`
before `emitFor` (grep for `cell.check`, and do not trust a line number here:
this citation said `:164` and was already stale when written, because an
unrelated comment expansion in `98b2a01` had moved the call to `:170`), and `cell emit --target=c examples/rejected/arc_to_owned.cell`
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

6. **An `arc` CALL RESULT passed to an `owned` parameter.** `take(owned
   fresh())` with `fresh() -> arc [Int]`. Refused by R10's second axis rather
   than retained, for the same reason as number 5. This is the one that was a
   live AddressSanitizer double free at exit 134 rather than a masked one; see
   R10 above for the per-commit measurement and
   `examples/rejected/arc_call_to_owned.cell` for the corpus form.

Numbers 3 and 4 had one root cause: a value slot is a position with a declared
type exactly as a parameter, a `let`, or a struct field is, and it was the only
such position not asking the conversion question. All six were silent at
`cell check` and clean under `-Wall -Wextra -Werror`; only running them showed
anything. This list is not the running total: `AGENTS.md`'s **Status honesty**
section carries that count and is the authority for it.

**Still broken, all of them leaks, each measured rather than asserted:**

| Gap | Evidence |
|---|---|
| A Cell body never releases its own `arc` parameter (no parameter is dropped), so every call-site retain into one leaks a reference | by construction; `examples/arc_host.c` is the ABI-correct contrast, and `examples/arc.cell` reports 0 leaks because of it |
| A struct holding an `arc` field is never dropped, so rule 4's retain leaks | `record` shapes are excluded from `hasDropCall` |
| An `arc` local declared inside a block OR A MATCH ARM is never released, because release is function-scoped and both are popped before the drop pass runs; inside a `while` body that is unbounded | `leaks`: **2997 leaks / 63936 bytes** over 1000 iterations for the block form |
| Reassigning an `arc` `var` leaks the previous box (`var arc v = "one"` then `v = "two"`), the same class as the R3a-revival leak R16 documents for `owned` | `leaks`: **3 leaks / 64 bytes** for a single reassignment |
| An `owned` String or list PLACE bound as `arc` (**the reverse direction**; `arc` into `owned` is refused outright by R10 above) is not boxed at all, and is left as a C type error rather than a silent double free | see retain rule 1 above. Re-measured: `let arc b = a` with an `owned` String `a` still emits `cell_arc_t b = a;` and `cc` rejects it, `initializing 'cell_arc_t' with an expression of incompatible type 'cell_string_t'` |

**CLOSED, and the row is gone from the table above rather than left in it with
a strikethrough.** An `arc` value unboxed for a `shared` parameter without ever
being bound (`inspect(shared fresh())`) used to drop its handle on the floor,
measured at 2998 leaks over 1000 iterations. `460b9a3` fixed it: the emitted C
now hoists the handle into the statement expression and releases it before the
result is yielded. Measured at **0 leaks**, with `examples/arc.cell` still
printing 13 at 0 leaks, so nothing regressed to buy it.

**A SIXTH gap existed and was never in this table. It is closed by REFUSAL, so
it gets no fixture and changes no constant in the gate.** `let owned ys: [Int] =
fresh()` and `ys = fresh()`, with `fresh() -> arc [Int]`, emitted
`(*(const cell_slice_t *)cell_fresh().ptr)` with **no drop at all**: ASan-clean,
and a leaked box every time. Only the call-ARGUMENT position was the double free
(see R10 above). All three forms are now refused by R10's second axis, so there
is no accepted program left that leaks this way and nothing for a
`examples/leaks/` fixture to measure. The `== leaks ==` stage is unchanged, and
that is the correct outcome rather than a missing test: a refusal removes the
program, it does not make the emission safe.

**Where these numbers now live.** Every count in the table above used to come
from an ad-hoc measurement that existed in no file, which made them
unreproducible and, in one case, quietly stale. They are now pinned by
`tools/check.sh`'s `== leaks ==` stage against fixtures under `examples/leaks/`,
as constants carrying the commit they were measured at. The closed row is
pinned at 0, so any nonzero reading re-opens it. **Read the gate, not this
table, for a current number**; the table is here to say what each gap IS.

**Two make-unique positions R10 did NOT enforce, now ENFORCED.** This section
used to describe a list ELEMENT and a `return` as positions kept safe only by a
C type error, and it recorded a correction to its own first draft: the `cc`
protection was measured on a `[String]`, where `cell_arc_t` and `cell_string_t`
differ, and it does not hold for a slice element type, where

    let arc xs: [Int] = [1, 2, 3]
    let owned zss: [[Int]] = [xs, xs]

passed `cell check` AND compiled clean at `-Wall -Wextra -Werror`, because the
unboxed `cell_slice_t` is exactly the element type the buffer wants. That was
one element type measured and a property of the position asserted, the same
failure the sentence was written to correct.

Both are now rows in R10's own table above and both are refused by `cell check`.
The `return` one still additionally produces a `cc` error if it ever reaches
codegen, which is fine; what changed is that the guard no longer depends on
which two C types happen to coincide. **A C type error is a real stop and it is
loud, which is the safe side, but it was never enforcement**, and a reader who
mistakes either for a defect to be "made to compile" will reintroduce the double
free R10 exists to prevent, because the buffer, not the refcount, is what gets
freed twice.

The list-element case additionally used to be SILENT rather than loud. The
element C type came from the first element rather than the declared element
type, so a `[String]` could hold `cell_arc_t` and a callee reading element 0 got
a refcount box pointer reinterpreted as a length. `a28b773` made it take the
declared type, which converted silent corruption into the loud `cc` error above.
That defect predated the `arc` work; the retain pass only added a reference leak
on top of it.

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

**POSITIONS THAT MAKE AN `arc` VALUE UNIQUE**, added in version four as an
enumeration of four (an `owned` parameter, an `owned` binding, an assignment
into an `owned` place, an `owned` struct field) and **corrected in version five,
because the enumeration was the defect.** Two more consumption sites existed
that no one had asked at, a list-literal element and a `return`, and a third
axis existed that no position could see, an `arc`-ness coming from a
signature's return type rather than a binding's annotation. R10 above now tables
six sites.

**The structural answer is not a longer list.** Version five replaced the
optional-place verdict, whose "none" meant permit, with a total verdict whose
undecidable case means REFUSE. That is what makes the next unenumerated form
fail closed instead of silently joining this section as version six. Every one
of the three widenings so far escaped through the same permissive default, and
enumerating harder was tried three times.

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

`copy` is an assertion by the programmer, not yet a derived property for every
position. Struct declarations now reject `copy` fields whose declared type is
resource-bearing or cannot be resolved, including nested structs and optional
or result wrappers:

> `err: 'copy' is not valid for 'Buffer': it owns a field of type '[Byte]'`

This declaration-time check fails closed and preserves scalar and recursively
resource-free copy fields. Other `copy` positions still rely on the annotation
without deriving copyability, so resource-owning copy bindings remain an
unchecked correctness hole.

---

## 4. Annotation agreement

### R13. Annotations must be consistent

**R13.0 -- the borrow sigils are spellings, not annotations.** `&x` spells
`shared x`; `&mut x`, `&var x` and `&exclusive x` all spell `exclusive x`.
`refKind` normalizes every one of them to a `LoanKind` before any rule runs, so
none of R1-R18 has a case for them and R15 compares a sigil-derived mode
against a parameter exactly as it compares a written keyword. `&var` was
admitted from the CELL v2.0 surface and required no change to this checker.

**R18 is what this clause costs when a rule forgets it.** `checkLetInit`'s
first branch keyed on `refKind`, which is the sigil half only, so the two
spellings this clause calls identical got different answers -- one an exit-134
double free, the other a silent move. R18 keeps the clause true by asking
`borrowSource` rather than switching on `ref_shared`/`ref_exclusive` itself.


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

**Second clause: a binding that already holds a borrow may not be reassigned.**
Enforced in `checkAssign`.

> `err: cannot assign a borrow of 'b' to 'e': it already holds a borrow, and rebinding one is not defined in this revision`
> `note: the C backend writes THROUGH the borrow rather than retargeting it, so the two readings of this statement differ; bind a new name instead`

R14's first clause already refused this for a `let`, by immutability, and there
is a test named for it. `var` reached a gap, and the gap was that the statement
has TWO meanings and the compiler implemented a different one in each half:

```cell
var exclusive e = &mut a
e = &mut b
```

- `borrowck.zig` read it as a RETARGET, and read it wrong. `placeOf` returns
  null for a unary, so `checkExpr` created a TEMPORARY loan on `b` that died
  with the statement, while `e`'s named loan still pointed at `a`. After the
  statement there was a loan on `a` and NONE on `b`, so a following
  `take(owned b)` was accepted.
- `codegen.zig` reads it as a WRITE THROUGH and emits `*e = *&b;`. It never
  retargets anything.

The second reading is the one that runs, and it is not a stale-loan nuisance.
Measured at `b3698a7` with `make() -> String`, `var owned a = make()`,
`var owned b = make()`, `var exclusive e = &mut a`, `e = &mut b`: the emit was
`*e = *&b;` followed by `cell_string_free(&b); cell_string_free(&a);` with `a`
and `b` holding the same buffer pointer. **AddressSanitizer: attempting
double-free, exit 134.** `a`'s original buffer leaks in the same statement.
`cell check` said `ok`; `cc` said nothing at `-Wall -Wextra -Werror`.

It is REFUSED rather than modelled. Modelling the retarget means killing `e`'s
old loan, and killing a loan is the unsafe direction under a holder keyed by
NAME rather than by binding id: a shadowed name would remove a loan that is not
this binding's, and a removed loan permits. Modelling the write-through means a
place for `*e`, which "places, not names" does not have, since a place is a
binding plus a field path and a referent is a different binding. Neither is
contained, and the language has not decided which meaning it wants.

The refusal is scoped to an EMPTY target path and to a value that is provably a
borrow, so the two legitimate neighbours survive: `buf.len = new_len` through
an `exclusive buf: Buffer` (a field write, which `examples/ownership.cell`
does) and `e = Buffer { len: 3 }` (a whole-value write through the borrow,
which `runtime/cell_rt.h` section 7 defines). `borrowSource` is what tells
those from a retarget, and it is total: a value it cannot prove is not a borrow
is refused too.

"Holds a borrow" is asked TWO ways, because neither alone is enough. The
declared annotation catches `var exclusive e = &mut a`. A scan for a named loan
whose holder is this binding's name catches a binding whose annotation is not a
borrow but which `checkLetInit` still turned into a named loan: it creates one
whenever the initializer is a `&` form, regardless of the annotation. The scan
is by name, so a shadowed name can match a loan that is not this binding's;
that direction only ever refuses an assignment, never permits one.
`examples/rejected/borrow_retarget.cell` is the corpus form.

The witness for the second way used to be `var owned e = &mut a`. **R18 now
refuses that at the `let` itself**, so no loan is created for it and the scan
cannot see one; `var copy c = &mut a` and `var arc c = &mut a` still reach the
loan branch, so the scan is still load-bearing and the test moved onto the
`copy` spelling.

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
correct. R2 is not the only rule carrying that weight: R2.b, R10's unique
clause and **R18** each closed a measured double free of their own, and each
one was a rule R2 was assumed to cover and did not. **Until the checker exists, Cell provides no memory-safety guarantee
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
   of `67529a9`. **R9** is now **done** too, for the forms it owns: an
   exclusive borrow of an `arc` place (every spelling, through `createLoan`)
   and a write through one (the strict prefixes of an assignment target). The
   one form it still does not own is the parameter rebind its own example
   shows, `arc n: String` with `n = "other"`, which has an empty path and stays
   R14's, with R14's generic message. See R9.
4. **R4, R5**: shared XOR exclusive, with the lexical loan scopes of 0.3.
   Needs loan provenance recovered from `&`/`&mut` initializers.
5. **R6**: field-path disjointness, using `Expr.field` and `rootName`.
6. **R7**: pattern binding ownership, for the pattern forms that exist.
7. *(codegen)* **R10, R11**: `arc` semantics and retain/release insertion.
   Needs `arc T` to lower to `cell_arc_t` first.
8. **R12**: general `copy` checking. Struct fields now use a recursive,
   fail-closed resource classifier; bindings and other positions still need a
   complete type representation.
9. **R8, R17**: escape checking and the runtime side of the double-free
   guarantee. **R16 (drop insertion) is partially done** without a
   control-flow graph, by consuming borrowck's existing conservative move
   tracking directly (function-scoped, `let`/`var` locals only, structs
   excluded); see R16 above for exactly what landed and what did not.
   **Revisiting 0.3 in favor of NLL is DONE for named loans, and it needed no
   control-flow graph.** An earlier version of this step claimed it was gated
   on one. R8 is what makes the claim decidable syntactically: a loan value
   cannot escape the block that created it, so its region is already bounded by
   the holder's lexical block and the non-lexical rule only shrinks it. See 0.3
   for the two conditions, the call-argument whitelist, and the taint closure
   over derived bindings that is deliberately still missing.

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
