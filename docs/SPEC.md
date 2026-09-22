# The Cell Language Specification

Version 0.1.0 (draft).

**Snapshot: committed `src/` as of commit `9fb12af`, 2026-09-06.** The compiler
under `src/` and the runtime under `runtime/` are being actively rewritten by
another author while this document is being written, and both moved several
times during that window. Every status claim below was re-verified against a
binary built from `a690a8c`, whose `src/` tree is byte-identical to `9fb12af`'s
(`git diff a690a8c 9fb12af -- src/` is empty; the intervening commits touch
`runtime/` and documentation only). Uncommitted work in progress in the working
tree is deliberately excluded, because it does not yet build.

If a claim here disagrees with the source, believe the source and re-verify:
`git log a65a586..HEAD` shows what has changed since this specification was
first drafted. Several statuses below were already corrected once mid-drafting,
when the parser gained struct-literal restriction, postfix chains, `match`, and
source spans.

Cell is a systems language that blends Rust ownership and algebraic data types,
Swift value/reference clarity and ergonomics, and Zig explicit control with a
C-ABI-first ethos. The toolchain is written in Zig
`0.17.0-dev.2251+1175a3e99`. Its primary pipeline is `.cell -> HIR -> LLVM IR /
MLIR` (ruled 2026-09-21); it also emits C, which today is the only backend that
lowers the whole language and stays the default `--target` until every LLVM
and MLIR leak pin in gate stage 7 reads 0, when the default flips to LLVM.

This document specifies the language. It is not a description of a finished
compiler. Every construct carries a status tag, assigned by reading `src/` and
by running the compiler, never by assuming that "it parses" means "it works".

---

## 0. How to read this document

### 0.1 Status tags

| Tag | Meaning |
|---|---|
| **implemented** | The compiler accepts it and a later stage acts on it correctly. Verified by running `cell check` / `cell emit`. |
| **parsed, not enforced** | The parser accepts the syntax and records it faithfully, but no later stage checks its meaning or lowers it. |
| **designed, not implemented** | Specified here. The compiler today either rejects it outright or ignores it. |

**implemented** never means safe, optimized, or complete. It means the observed
behavior of a binary built from `9fb12af` matches this specification for the
cases tested. Section 12 is the full construct-by-construct index and the
counts in section 0.2 are derived from it.

Note a distinction that recurs: a construct can be **implemented in the parser
and not lowered by codegen**. Those are tagged **parsed, not enforced** with
the reason stated. `if` and `match` used to be in that column (`/*if*/` /
`/*match*/` placeholders); they now lower to C (section 0.6). Call-site
ownership prefixes have left that column too (section 0.7). The remaining
parser-only cases include `use`. `T?` and `[T]` as types are checked and
lowered (sections 3.2 and 3.3); `[T]?` still does not parse.

### 0.2 Status summary

| Status | Constructs |
|---|---|
| implemented | 118 |
| partially implemented | 2 |
| parsed, not enforced | 3 |
| designed, not implemented | 35 |
| **total** | **158** |

Counted from the section 12 index on 2026-09-08, not estimated. Recounted
2026-09-21 with the command below: the table held 116 / 2 / 3 / 37 / 158 while
this summary still said 109 / 2 / 3 / 41 / 155, and five rows then moved on
evidence (loops, the two optional rows, wrap patterns, parser diagnostics),
giving 118 / 2 / 3 / 35 / 158. Recounted
2026-09-16 after optional/Result/list rows left the parser-only and
designed buckets (97/5/49/153 to 106/3/44/155). On 2026-09-08, when R2.b
added an `implemented` row, 96 to 97 and 152 to 153; the
awk command below reports the long qualified statuses as their own buckets, so
fold every string that STARTS with a status word into that status before
totalling, and note that BSD `sed` does not take `\|` as alternation, which
silently leaves those rows uncollapsed and the total short. **Recount rather
than trusting these numbers**, because they have been wrong before and will be
again: they said 86 / 8 / 55 / 149 while the table held 96 / 2 / 5 / 49 / 152,
had no row at all for `partially implemented` when two constructs carried it,
and one section 12 row had resorted to saying "this row postdates the 0.2 count"
inline rather than fixing the total. A count in prose is stale the next time
anyone edits the table below it. The command:

```sh
awk '/^## 12\. Status index/,/^## 13\./' docs/SPEC.md \
  | grep '^|' | grep -v '^|---' | grep -v 'Construct | Status' \
  | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}' | sort | uniq -c
```

The headline consequence: **the front end, a typechecker, a borrow checker for R1/R2/R2.a/R2.b/R3/R3a/R4/R5/R6/R7 (its consumption clause)/R8/R9/R14/R15/R18 plus one
clause of R10, and C lowering for the flagship examples are real.** As of
the working tree the lexer, parser, AST, diagnostics, typechecker, and
borrowck are wired into `cell check`. `if` / `else`, `match`, blocks, struct
literals, list literals, and mangled calls lower to C. What is still designed
includes loops other than `while`, generics, and NLL beyond named loans.
(Corrected 2026-09-21: this sentence also listed `Result<T,E>`, which section
12 counts as implemented for scalar pairs on all three backends, and all NLL,
which `borrowck.zig` enforces for named loans; see `docs/OWNERSHIP.md` 0.3.) `arc`
retain/release is implemented in the C backend, with the gaps R11 of
`docs/OWNERSHIP.md` names. Stem
pairing (section 1.2) and R15 call-site prefixes (section 0.7) have since
landed and are not counted in 0.2. `docs/OWNERSHIP.md` is the normative rule
list; section 12 is the construct-by-construct index.

### 0.3 Verification method

Everything tagged **implemented** was checked by building the compiler and
running it:

```sh
cd ~/dev/active/cell-lang
~/.zvm/bin/zig build -Dswift=false
./zig-out/bin/cell check <file>
./zig-out/bin/cell emit  <file>
```

`cell check` exits `0` on success and `1` on a parse or check error (measured).
Where this document says "measured", a probe file was run through that binary
and the output read. Where it says the emitted C does or does not compile, the
output was piped through `cc -c` and the errors counted.

The Swift-linked build path (`-Dswift=true`, the default) hardcodes
`/Applications/Xcode-beta.app` library paths in `build.zig` and was **not**
exercised, so nothing here depends on it.

### 0.4 Things this specification deliberately does not claim

Cell has no measured performance characteristics, no memory-safety guarantee,
no ABI stability guarantee, and no thread-safety guarantee beyond one narrow
fact: `cell_arc_t` refcounts in `runtime/cell_rt.c` are atomic as of `562f116`.
Nothing else in the runtime is thread safe, and `cell_arena_t` explicitly is
not. Any safety property this document describes is a property of the
*specified* language, to be delivered by a checker that does not exist yet.

### 0.5 Delta since the snapshot: commit `8dd5673`

The section 12 index is pinned to `src/` as of `9fb12af`. While this document
was being finalized, `8dd5673` ("a real typechecker with scopes, types, and
span-carrying errors") landed: a rewrite of `src/cell/typecheck.zig` of roughly
780 lines with new entry points in `src/root.zig` and `src/main.zig`. The index
was not re-derived for it, because doing so would mean re-verifying 149 rows
against a tree that moved four times in one evening. Pretending it does not
exist would be worse, so this section records the measured delta instead.

Measured against a binary built from `8dd5673`:

| Claim above | Working-tree reality |
|---|---|
| "there is no type representation" (0.2) | there is one: `!c` on an `Int` is rejected with `operator '!' requires a Bool operand, found Int` |
| name resolution is designed, not implemented (6.2) | implemented: `print(n)` with no declaration gives `unknown identifier 'print'` |
| chained comparison is not rejected (5.1) | rejected, by a type rule: `operator '<' cannot be applied to Bool and Int` |
| "the only rule the compiler enforces is immutable assignment" (section 4) | no longer true; operator typing and name resolution are enforced too |
| the symbol table is module-wide and unscoped (7.3 bullet 3, OWNERSHIP.md 0.4) | **fixed**, measured: a `let x` in `a()` is no longer visible in `b()`, which now reports `unknown identifier 'x'` |
| parse diagnostics do not reach the CLI (11) | check diagnostics now render with the source line and a caret |

Three claims above were re-tested against that `8dd5673` binary and still held
then: unknown type names were still accepted silently as `void*`, `if` and
`match` still lowered to `/*if*/` and `/*match*/`, and no ownership rule was
enforced. The whole of `examples/rejected/` was re-run: seven of the thirteen
files still passed, including every use-after-move, aliasing, escaping-borrow,
and call-site-mismatch case. Section 0.6 records what later work changed:
`if` / `match` now lower to C, and R1/R2/R2.a/R2.b/R3/R3a/R4/R5/R6/R8/R9/R14/R15/R18
are enforced. Unknown type
names remain accepted as `void*`.

### 0.6 Delta: ownership enforcement and body-bearing emit

Later work wired `src/cell/borrowck.zig` into `cell check` and replaced
placeholder codegen. Measured against a binary built with `-Dswift=false`:

- R1, R2, R2.a, R2.b, R3, R3a, R4, R5, R6, R8, R9, R14, R15 and R18 are
  enforced. `examples/rejected/use_after_move.cell`,
  `move_out_of_borrow.cell`, `aliasing.cell`, `escaping_borrow.cell`,
  `immutable_assign.cell`, and `field_assign_immutable.cell` are
  `currently-rejected`. Call-site prefixes (R15) were still discarded at this
  point, so `callsite_mismatch.cell` remained `currently-accepted`; section
  0.7 supersedes that.
- `if` / `else`, `match`, blocks, struct literals, list literals, and calls
  lower to real C. `cell emit examples/hello.cell` compiles with `cc -c`.
  Linked against `runtime/cell_rt.c` it prints `42`.
- Unknown type names, hex/underscore/exponent literals, loops, generics,
  `Result<T,E>`, enum payloads are unchanged. Stem pairing of `.cell`/`.cel`
  with `.body`/`.bod` is implemented (section 1.2).

Section 12 rows that this delta moved are retagged below. Unshipped rows stay
as they were.

Two files in `examples/rejected/` are now rejected **for the wrong reason**, and
that distinction is worth preserving rather than celebrating.
`silent_literals.cell` fails with `unknown identifier 'x1F'`, which catches the
second token rather than the malformed literal, and `while_is_not_a_loop.cell`
fails with `unknown identifier 'while'`, which is name resolution landing on
the right line by luck. Neither underlying language defect is fixed. Each file
says so in its header.

Re-derive the index from the source before trusting the counts in 0.2 if
`git log` shows further commits after `8dd5673` touching `src/`. The counts are
a measurement with a date on it, not a standing property of the language.

### 0.7 Delta: call-site ownership prefixes (R15)

Measured against a binary built from `67529a9` with `-Dswift=false`:

- The parser now keeps the ownership keyword written on a call argument
  (`b39c158`), `refKind` peels the annotated wrapper (`9917ec7`), and borrowck
  compares the written mode against the callee's parameter (`67529a9`). R15 is
  **implemented**. `examples/rejected/callsite_mismatch.cell` is
  `currently-rejected` with `error: 'take' expects parameter 'b' as 'owned',
  but the argument is passed as 'shared'`, and its `// EXPECT:` header was
  updated to match.
- `src/cell/borrowck.zig`'s file header is the authoritative list of the rules
  the checker implements. Read it rather than any prose list in this document.

**The 0.2 counts are now stale by at least the R15 row**, which section 12
still tags *designed, not implemented* in its Ownership table, and by the stem
pairing rows of section 1.2. Re-deriving the 149-row index against the current
tree is a separate, counted task; it was deliberately not attempted here rather
than guessed at. Nothing else in section 12 was re-verified for this delta.

### 0.8 Delta: the union with CELL v2.0, and three backends

Two changes landed on 2026-09-07 that this index does not yet count. Recorded
as a delta rather than patched into 0.2, for the reason 0.7 already gives: the
149-row index is a measurement with a date on it, and re-deriving it is a
separate counted task.

**A second Cell exists, and this specification now says so.** A different
implementation, "CELL v2.0", uses the same name and the same `.cell`/`.cel`
extensions for a Zig-shaped language with error unions, `error_scope`/`raise`,
and its own package manifest. Donald's decision is a deliberate union of the
two surfaces: constructs are admitted one at a time, on evidence, and the
ownership model and the C ABI are not up for negotiation. What has landed:

- **`&var x` is a third spelling of `&mut x` and `&exclusive x`** (section 6.5).
  It builds the identical AST node, so no later stage has a case for it; R15
  compares it against the parameter exactly as it does the others. Measured:
  `take(&var buf)` against an `owned` parameter is rejected with "the argument
  is passed as 'exclusive'".
- **A trailing `;` after an item is accepted and ignored** (section 7.1 already
  made semicolons optional on statements; items were the exception). A `;`
  cannot start an item, so this is unambiguous.

**Explicitly refused, with the reason, so the decision is not re-litigated:**

| Refused | Why |
|---|---|
| `switch` | `match` is implemented and lowers to C. In the other tree `kw_match` is declared but absent from its keyword map, so `match` does not even lex there, and its own README states "one construct, one keyword". Admitting `switch` also needs `\|x\|` captures, and `\|` is reserved here for pattern alternatives (2.10). |
| `i32` / `f64` | Section 3.1 is normative and exhaustive. The largest known hole in the compiler is that an unrecognized type name silently becomes `void*`; the fix is an enumeration of known names, and doubling that enumeration for pure synonyms widens the hole for no expressiveness. |
| `@import("std")` | Neither implementation resolves modules (8.4). Adding `@` to the lexer to admit a namespace that binds nothing is surface debt. |
| `const Foo = struct { }` | A second item grammar for a meaning the existing one already expresses. The genuinely missing feature underneath it, a top-level `const` value binding, is worth having on its own and is not this. |
| macros | The other implementation states outright that its expander is not hygienic. A construct that can invisibly introduce a binding can silently change which place a move kills, and the diagnostic would point into expanded source. That is not deferrable in a language whose claim is that ownership is checkable. |
| `.bod` as a package manifest | Section 1.2 is normative: `.bod` is a body file. See below. |
| error unions, `!T` and `E!T` | A second spelling of `Result<T, E>` (section 3.4). The other implementation lowers an error union to a tagged `{ok, code, value}` struct; `runtime/cell_rt.h` already defined `cell_result_t { bool ok; int32_t error_code; cell_value_t value; }` for `Result`, the same three fields and the same choice to narrow the error to an integer code; since ABI 2 (2026-09-17) the runtime carries each scalar pair in its own struct instead. Admitting both is a pure synonym, refused on the `i32`/`f64` grounds above. `Result<T, E>` parses and constructs since 2026-09-16 (`Ok`/`Err`, C backend; FEATURES TYPE-06). |
| postfix `?` on an expression, for error propagation | Postfix `?` already means optional in a type (section 3.2, `T?`). Different positions, so a parser could tell them apart, but one glyph would carry two unrelated meanings. Whether Cell wants propagation at all is a separate question; `Result` already parses and constructs, so the remaining question is whether a second glyph should mean `match` on `Err`. |

**The `.bod` collision, stated normatively.** Another implementation reads
`.bod` as a package manifest. This specification does not, and a conforming
implementation MUST treat `.bod` and `.body` as body files paired to a
`.cell`/`.cel` module by filename stem, per section 1.2. The other reading is
recorded here only so the conflict is visible rather than discovered.

**Deferred, with the reason, ruled 2026-09-16.** Two further constructs from
the other implementation are neither admitted nor refused yet:

- **`error_scope` / `handle` / `raise` / `propagate`: deferred, leaning
  refuse.** In the other tree `raise` transfers to the immediately enclosing
  `handle` and `propagate` passes the error to the caller, so this is local
  control flow over an error value, not unwinding. It is still sugar over
  `match` on a `Result`; its `handle` arms use
  `|e|` captures, which the `switch` row above already refused; and its
  `raise` edge is a new CFG edge that the drop pass and borrowck would have to
  model, which this delta admits only on evidence. `match` on a `Result`
  expresses the same program.
- **A package manifest under any name: deferred until section 8.4 resolves
  modules.** A manifest describes dependencies to resolve, and nothing
  resolves modules today, which is the reason `@import("std")` was refused.
  One clause is decided now: when a manifest is admitted it MUST NOT use the
  `.bod` or `.body` extensions, per section 1.2.

Every item in this ruling either depends on `Result<T, E>` or is moot without
it. Parsing `Result<T, E>` (TYPE-06) landed 2026-09-16 (section 3.4), and so
did constructing and inspecting a scalar Result in Cell source (`Ok`/`Err`
and wrap patterns, C backend). What remains designed is a second spelling
(`!T`), expression-position `?` propagation, and `error_scope`/`handle`.

**Union stage 4 landed too, and it is the one that changed the language rather
than its surface: Cell has loops.** `while`, `break` and `continue` are
implemented across all three backends; `examples/loops.cell` prints 55 through
each. It came with `docs/OWNERSHIP.md` **R2.a**, because a loop is a back edge
and section 0.3 of that document bought its simplicity by assuming there were
none: a place declared outside a loop and moved inside it is now rejected,
since the next iteration would use it after the move. Reassigning before the
body ends revives it (R3a) and the loop is accepted.

One corpus file moved as a result, and the move is the evidence.
`examples/rejected/while_is_not_a_loop.cell` is now
`examples/while_is_now_a_loop.cell`, unchanged as a program, having meant four
different things: it passed and silently did nothing; then failed by name
resolution; then failed as a parse error once `while` was reserved; and now
passes and actually loops, returning 10 through C, LLVM and MLIR alike.

**Union stage 3 also landed:** SPEC 2.5's reserved words are real keywords.
Measured safe before the change, by stripping comments from every file under
`examples/` and `stdlib/` and grepping for all 24 words as identifiers: exactly
one hit, in the file written to break there.

That change exposed a defect it did not cause. `while (c) { }` became a PARSE
error, and a parse error had never reached the CLI on this path before, so it
escaped as a raw Zig error and printed a **stack trace** instead of a caret.
The parser already recorded the failure and could push it into a bag; nothing
called that. `load.zig` now renders it, and a syntax error reads like every
other diagnostic.

**Three backends.** `cell emit` now takes `--target=c|llvm|mlir`. C remains the
only backend that lowers the whole language today; the LLVM IR and MLIR path is
the primary direction (see the opening of this document). The LLVM IR and MLIR backends go
through a typed IR (`src/cell/hir.zig`) and are scalar-first: `String`, `[T]`,
`T?`, `Result`, `arc`, and (for MLIR) structs mostly produce a `cannot lower`
diagnostic at the offending span rather than wrong output. **Mostly, because
this sentence was a blanket claim and is no longer one:** an `exclusive`
`String`/`[T]`/`T?` parameter, and a whole-value write through it, lower in
both backends as of `a6c41e8`, which made them pointers agreeing with
`abi.classifyParam` and with the C ABI. Read the backends' refusals as a list
that shrinks, and check the emitter rather than this paragraph. (2026-09-21: the
list has shrunk further. Scalar `T?` and `Result<T, E>` construct and match in
both, and so do the wrap patterns `Some`/`None`/`Ok`/`Err`, see `docs/FEATURES.md`
TYPE-04, TYPE-06 and PAT-02; an owning payload, `arc`, indexing and most list
use are still refused.) Both are verified by
executing what they emit. `examples/backends.cell` prints `24` through all
three. Section 10's C ABI contract is unchanged and remains normative for the
C backend.

---

## 1. Source files and modules

### 1.1 Encoding and file extensions

**Status: designed, not implemented.**

A Cell source file is UTF-8 text. The lexer classifies only ASCII
(`std.ascii.isAlphabetic`, `std.ascii.isDigit`), so a non-ASCII byte outside a
string literal or comment produces an `invalid` token.

Cell recognizes four source file extensions in two roles:

| Extension | Role |
|---|---|
| `.cell` | module file |
| `.cel` | module file (alias of `.cell`) |
| `.body` | body file |
| `.bod` | body file (alias of `.body`) |

`.cel` is an exact alias of `.cell` and `.bod` is an exact alias of `.body`.
The two *pairs* are not aliases of each other.

**The chosen reading: `.cell`/`.cel` declares, `.body`/`.bod` implements.**
This is a deliberate decision recorded here, not an inference left open. The
alternative reading, that all four are aliases and the declaration split lives
in syntax, was rejected for three reasons. First, "body" already has a precise
meaning in this compiler: `FnDef.body` is `?[]Stmt`, and a function with
`body == null` is exactly a declaration without an implementation, a form the
parser already accepts (`pub fn f(shared a: Int) -> Int;`). Second, a
C-ABI-first language needs a header-shaped artifact anyway, and a declaration
file is that artifact. Third, four aliases for one thing is not a design, it is
four spellings.

### 1.2 Module and body pairing

**Status: implemented.** A body file is paired with a same-directory `.cell` or
`.cel` stem-mate before check. `cell check examples/pairing/geometry.body`
resolves `Point` and `Quadrant` from `geometry.cell` and exits 0. A body with
no stem-mate is an error naming the body and the missing module. A module file
with no body remains legal. A `pub` definition in the body must have a matching
module declaration (rule 8), must not duplicate a module-side body (rule 10),
and must agree on arity, parameter ownership, parameter types, and return type
(rule 11).

1. A **module file** (`.cell`/`.cel`) may contain declarations, definitions, or
   both. Every example under `examples/` is a module file that does both, and
   that stays legal.
2. A **body file** (`.body`/`.bod`) supplies definitions for declarations made
   in its module file. It is paired **by filename stem within the same
   directory**: `geometry.cell` pairs with `geometry.body`.
3. Pairing carries no syntax. There is no `module` declaration inside the file
   and no `use` between the pair. Stem pairing was chosen over an in-file
   module declaration because `build.zig` can express it without the build
   graph parsing Cell, and over an explicit `use` because a body is not a
   dependency of its declaration, it is the same module.
4. It is an error for one stem in one directory to have both `.cell` and `.cel`
   files, or both `.body` and `.bod` files. The aliases exist for taste, not
   for simultaneous use.

   > `error: ambiguous module 'geometry': both geometry.cell and geometry.cel exist`

5. A body file whose stem has no module file is an error. A body cannot stand
   alone, because there is nothing for its `pub` items to implement.

   > `error: body file 'geometry.body' has no module file (expected geometry.cell or geometry.cel)`

6. A module file with no body file is **legal and common**. That is the normal
   case, and it is what `stdlib/prelude.cell` is.
7. A `pub fn` declared without a body in the module file and not defined in the
   body file is **legal**. It is an external symbol: the C-ABI-first story, and
   the mechanism by which the prelude declares host intrinsics.
8. A `pub` item defined in a body file with no matching declaration in the
   module file is an error.

   > `error: 'grow' is defined in geometry.body but not declared in geometry.cell`

9. A non-`pub` item in a body file needs no declaration. It is private to the
   pair.
10. A function with a body in the module file and also a body in the body file
    is a duplicate definition error.

    > `error: 'grow' already has a body in geometry.cell`

11. A declaration and its definition must agree exactly on name, arity, each
    parameter's ownership annotation, each parameter's type, and the return
    type. Parameter *names* need not match.

    > `error: 'grow' body does not match its declaration: parameter 1 is declared 'exclusive Buffer' but defined 'owned Buffer'`

12. A single file may contain both declarations and definitions in every case
    above. The split is a filing convention the compiler enforces, not a
    restriction on what one file may say.

`src/cell/load.zig` classifies the path, finds the stem-mate, and merges
module declarations into the body unit. `cell check` / `dump` / `emit` all go
through that load. `.txt` and extensionless paths still load as a standalone
module. `examples/pairing/` is the worked pair.

### 1.3 Compilation unit

**Status: implemented (single file only).**

`cell <command> <file>` compiles exactly one file. There is no module
resolution, no include path, no package manager, and no linking of a module to
its body file. A `use` declaration (section 8.4) is recorded and emitted as a C
comment. Since 2026-09-16 `cell build` and `cell run` take that one file's C
through `$CC` together with an embedded copy of the runtime; they add no second Cell
unit and no target other than C, so the compilation unit is unchanged and a
bodyless declaration with no runtime symbol surfaces as a link error rather
than a compiler diagnostic. A `.c` positional is a hand-written host for such
declarations: it is a C translation unit handed to the C compiler, never a
second Cell unit, and no other command accepts one.

---

## 2. Lexical structure

### 2.1 Whitespace and line terminators

**Status: implemented.**

Space, tab, carriage return, and newline are trivia. Newlines are not
significant: Cell has no offside rule and no automatic semicolon insertion.
Statement boundaries come from the grammar, not from line breaks (section 7.1).

### 2.2 Comments

**Status: implemented.**

```cell
// line comment, runs to the end of line
/* block comment */
```

Block comments **do not nest**. `/* /* */` closes at the first `*/`. An
unterminated block comment consumes the rest of the file without producing a
diagnostic.

`/// doc comment` is lexed as an ordinary line comment. Doc comments are
**designed, not implemented**: attaching them to the following item and
carrying them into generated C is future work, and nothing in the AST can hold
them today.

### 2.3 Identifiers

**Status: implemented.**

```
ident_start    = ASCII letter | "_"
ident_continue = ident_start | ASCII digit
identifier     = ident_start ident_continue*
```

Identifiers are ASCII only and case-sensitive.

`_` is an ordinary identifier at the lexical level. It acquires meaning in
exactly one place: `parsePattern` compares the lexeme and treats `_` as the
wildcard pattern (section 9). Everywhere else `_` is a name, so `let owned _ =
f()` binds a variable called `_`. Making `_` a reserved wildcard everywhere is
**designed, not implemented**.

Unicode identifiers are **designed, not implemented**.

### 2.4 Keywords

**Status: implemented.**

Twenty-three words are reserved and can never be used as identifiers:

```
fn      let     var     mut     struct   enum
if      else    match   return  use      pub
true    false
owned   shared  exclusive  arc  copy
Some    None    Ok      Err
```

The five ownership words are full keywords, not contextual ones. `arc` cannot
be a variable name.

`Some`, `None`, `Ok` and `Err` are keywords since 2026-09-16 so that they can
never collide with a user enum's variants (section 9).

### 2.5 Reserved for future use

**Status: implemented.** These lex as keywords as of the union stage recorded
in 0.8. None of them has a parser rule yet, which is the point: using one as a
name is now a parse error rather than a silent misreading.

The following are reserved by this specification so that programs do not come
to depend on using them as names:

```
while   for     loop    break   continue  in
impl    trait   where   type    const     static
self    Self    as      is      defer     async
await   yield   import  export  extern    unsafe
```

**This is not a cosmetic reservation, and `while` shows why.** Since `9fb12af`
a brace-delimited block is a valid expression (section 6.10), so
`while (c) { total = total + 1 }` used to **parse cleanly and pass `cell check`**:
`while` was an identifier, `while (c)` was a call to a function named `while`,
and the block that followed was a separate expression statement, evaluated and
discarded. A program written in the belief that Cell has loops compiled and did
nothing.

The former rejection fixture was named
`examples/rejected/while_is_not_a_loop.cell`; while loops have since landed and
that path no longer exists. Its retained accepted successor is
[`examples/while_is_now_a_loop.cell`](../examples/while_is_now_a_loop.cell),
which records the history and current execution contract.

**Reserving a word does not implement it.** The example above is historical:
`while`, `break` and `continue` now have parser and execution paths (section
7.6). Other reserved words require their own grammar and semantic work; see
[FEATURES.md](FEATURES.md) and the approved completion program.

### 2.6 Integer literals

**Status: implemented.** Decimal, hexadecimal, binary, octal, and underscore
separators. There is no sign in the literal itself: `-1` is unary negation
applied to `1` (section 6.5). One exception exists inside patterns, where `-`
followed by a numeric literal is folded into a negative literal pattern
(section 9), because a pattern is not an expression and cannot contain a unary
operator.

```
digit          = "0" ... "9"
hex_digit      = digit | "a" ... "f" | "A" ... "F"
bin_digit      = "0" | "1"
oct_digit      = "0" ... "7"

decimal        = digit (digit | "_")*
hexadecimal    = "0" ("x" | "X") hex_digit (hex_digit | "_")*
binary         = "0" ("b" | "B") bin_digit (bin_digit | "_")*
octal          = "0" ("o" | "O") oct_digit (oct_digit | "_")*
int_literal    = decimal | hexadecimal | binary | octal
```

Underscores separate digits. They cannot be leading, trailing, or adjacent,
and they cannot sit next to a prefix. A malformed separator or a prefix with
no digits is an invalid integer literal, not a number plus an identifier.
`1_000` is 1000; `0xFF_FF` is 65535; `1_` and `1__000` are errors.

Integer literals are parsed into `i64` by `std.fmt.parseInt` with base 0, so
the prefix selects the radix. A literal that does not fit is
`error: invalid integer literal`. There is no arbitrary-precision literal
type and no literal suffix.

See [`examples/silent_literals.cell`](../examples/silent_literals.cell).

### 2.7 Float literals

**Status: implemented (decimal, with optional exponent).** Hexadecimal floats
are **designed, not implemented**.

```
exponent       = ("e" | "E") ("+" | "-")? digit (digit | "_")*
float_literal  = digit (digit | "_")* "." digit (digit | "_")* exponent?
               | digit (digit | "_")* exponent
```

A digit is required on both sides of the point. `1.` and `.5` are not float
literals: `1.` lexes as `1` followed by `.`, and `.5` as `.` followed by `5`.
`1e9`, `1E9`, `1.5e-3`, and `1.5e+3` are floats. `1e9` is not an Int.

Hexadecimal floats (`0x1p1`, `0x1.0p1`) are refused as literals:

> `error: hexadecimal floats are not implemented`

They must not silently become `0` or `1`. See
[`examples/rejected/hex_float.cell`](../examples/rejected/hex_float.cell).

Float literals are parsed into `f64`.

### 2.8 String literals

**Status: implemented (lexing, the six simple escapes, and the unterminated
diagnostic).** `\u{...}`, multi-line, raw, and interpolated strings are
**designed, not implemented**.

```
string_literal = '"' character* '"'
```

The lexer skips the character after a backslash so that `\"` does not terminate
the literal. The parser strips the surrounding quotes and decodes `\n`, `\t`,
`\r`, `\\`, `\"`, and `\0` into the corresponding byte in the AST. An unknown
escape is a parse error. Emitters re-escape those decoded bytes for the
target (C string syntax, LLVM `c"..."` hex escapes). `"\n"` is one newline
byte, not the two bytes backslash and n.

`\u{...}` is **designed, not implemented**; `\u` is an unknown escape today.

An unterminated string literal (EOF inside `"..."`) is an error at the opening
quote:

> `error: unterminated string literal`

Multi-line strings, raw strings, and interpolation are **designed, not
implemented**.

### 2.9 Boolean literals

**Status: implemented.** `true` and `false` are keywords, not identifiers.

### 2.10 Operators and punctuation

**Status: implemented.**

```
( ) { } [ ]   , : ; .
->  =>  ?
+  -  *  /
=  ==  !=  <  <=  >  >=
&  &&  ||  !
```

That is the complete lexical operator set. There is no `%`, no `**`, no
bitwise `|` `^` `~`, no shifts `<<` `>>`, no compound assignment `+=`, no `++`,
no `::`, no `..`, and no `|` as a pattern alternative. A bare `|` lexes as
`invalid`. All of those are **designed, not implemented**.

### 2.11 Token spans

**Status: implemented.**

Every token carries `start` and `end` byte offsets into the source buffer plus
a 1-based `line` and `column`. A lexer test asserts that every token's byte
range slices back to its own lexeme, and another asserts that line and column
survive comments, newlines, and strings. Those spans are what makes section 11
possible.

### 2.12 Invalid input

**Status: parsed, not enforced.**

Any other byte produces an `invalid` token, which stops tokenization. The
parser then fails. The failure is recorded with a span and a message but is not
printed by the CLI; see section 11.

---

## 3. Types

### 3.1 Primitive types and their C mapping

**Status: implemented.**

`Generator.namedType` in `src/cell/codegen/lower.zig` fixes these names. This
table is normative and exhaustive:

| Cell | C emitted today | Notes |
|---|---|---|
| `Int` | `int64_t` | the default integer |
| `Int64` | `int64_t` | same C type as `Int` |
| `Int8` | `int8_t` | |
| `Int16` | `int16_t` | |
| `Int32` | `int32_t` | |
| `UInt` | `uint64_t` | |
| `UInt64` | `uint64_t` | same C type as `UInt` |
| `UInt8` | `uint8_t` | distinct from `Byte`; they share a C type and are not compatible |
| `UInt16` | `uint16_t` | |
| `UInt32` | `uint32_t` | |
| `Float` | `double` | the default float |
| `Float64` | `double` | same C type as `Float` |
| `Float32` | `float` | |
| `Bool` | `bool` | `<stdbool.h>` |
| `String` | `cell_str_t` | length-prefixed view; see section 10.3 |
| `Byte` | `uint8_t` | distinct from `UInt8` |

There are exactly sixteen primitive names. `Int` and `Int64` are
indistinguishable at the ABI, as are `UInt`/`UInt64` and `Float`/`Float64`;
whether they are distinct *types* in the source language is **designed, not
implemented**, because there is no type representation to distinguish them in.
`Int8`, `Int16`, `UInt8`, `UInt16`, and `UInt32` are their own tags: `Int` is
not `Int32`, and `UInt8` is not `Byte`.

`String` is a length-prefixed `cell_str_t`, matching `runtime/cell_rt.h`.
Section 10.3 is the ABI table. A literal bound as `arc` is now boxed
(`cell_arc_from_string(cell_string_from_str(...))`). The `owned` gap that
sentence used to name is CLOSED as of 2026-09-08: the C backend coerces a
literal's borrowed view into an owning `String` through `cell_string_from_str`
at eight positions, funnelled through one predicate. The LLVM and MLIR
backends refused those programs until 2026-09-17 (the stated reason, that
the helper is `static inline`, was wrong: it is a real symbol). Since IR
String step (a) they convert at the same positions, through
`hir.lower`'s funnel, and free nothing, having no drop pass yet.

**Any other type name is refused at typecheck** with `unknown type 'Strng'`.
A name is a type iff it is one of the sixteen primitives, a declared struct,
a declared enum, or a constructed type already implemented (`T?`,
`Result<T, E>`, `[T]`). Closed 2026-09-16 (TYPE-02);
`examples/rejected/unknown_type.cell` is `currently-rejected`. Codegen still
maps an unchecked unknown name to `void*` (`CType.unknown`); `cell check`
and `cell emit` both run the checker first, so that path is not reachable
from the CLI. Specified:

> `error: unknown type 'Strng'`

`Char` is **designed, not implemented**. There is no C mapping in this
section, so the name stays unknown.

### 3.2 Optional types

**Status: implemented for scalar payloads: C backend 2026-09-16, LLVM and MLIR
backends 2026-09-17.**

```cell
Int?
String?
```

`T?` denotes a value that is either a `T` or absent, written as a postfix `?`
on a type name.

Constructors are `Some(e)` and `None`. Patterns are `Some(x)`, `Some(_)`, and
`None`. Payloads this slice admits are the scalar primitives (`Int`, `Int8`,
`Int16`, `Int32`, `UInt`, `UInt8`, `UInt16`, `UInt32`, `Float`, `Float32`,
`Bool`, `Byte`), and since 2026-09-17 an owning `String` in the C backend
(sub-project 4): `String?` lowers to `cell_opt_string_t`, `Some(x)` moves `x`
when its type resolves (and copies it otherwise), `Some(owned s)` /
`Some(shared s)` bind the payload (a bare `Some(s)` on it is refused), and the
optional is released on every path that still holds it through generated
`cell_drop_opt_string`. `examples/optional_string.cell` and
`examples/leaks/owned_string_optional.cell` pin it. Anything else is refused.
`None` needs a declared optional slot (`let a: Int? = None`); `Some(e)` is
complete from its operand in C. LLVM and MLIR build the runtime's tagged
instance (zeroed, `has_value`, payload; a C `bool` payload as one byte) and
need a declared optional destination for `Some` too (a typed let, a
parameter, or a `return`). They carry only payloads with a pre-defined runtime
instance, so they refuse `Float32?` (and `String?`) together with
`cannot lower`. Passing an optional by value across a function boundary is
checked against C per example by `tools/check.sh` stage 10.

The runtime representation (section 10.3) is a tagged struct
`{ bool has_value; T value; }`, deliberately not a sentinel, because every
bit pattern of `int64_t` is a legal `Int`. The C backend emits the
predefined `cell_opt_*` instances.

**`[T]?` does not parse.** The postfix `?` is only accepted after a bare type
name, never after a `]`. Measured: `shared a: [Int]?` is a parse error. Nested
optionals (`T??`) also do not parse. Both are **designed, not implemented**.

### 3.3 List types

**Status: implemented as a type, with list literals and scalar indexing in the
C backend (section 6.11); no iteration.**

```cell
[Int]
[Byte]
[Int?]
```

`[T]` denotes a homogeneous sequence. Nesting works in the type grammar
(`[[Int]]`, `[Int?]` both parse). There is no iteration. Indexing a list of
scalars is implemented in the C backend (section 6.11).

**CORRECTED 2026-09-07.** This section previously said "Codegen maps every list
to `void*`" and "Codegen does not emit it". Both were false and had been for
some time. Codegen emits `cell_slice_t`
`{ void *ptr; size_t len; size_t cap; }`, one type-erased header for every
element type with `elem_size` passed at each call site, and
`cell emit` produces `int64_t cell_f(cell_slice_t xs);` for
`pub fn f(shared xs: [Byte]) -> Int;`. Measured.

The stale text had a cost worth recording: it was read as saying `[T]` had no
representation *at all*, which made it look like a language gap. It is not. The
LLVM and MLIR backends refused lists only because each returned null for the
type, and at 24 bytes a `cell_slice_t` takes the same indirect path
`cell_string_t` already used. Three lines, not a feature.

What remains genuinely missing is the *use* of a list: no indexing, no
iteration, and only the empty literal `[]` is constructible, because a
non-empty one needs a constant global for its elements that no backend emits
yet. **Superseded 2026-09-21** for the C backend: non-empty list literals
lower (`emitListLit`; `examples/index.cell` builds `[seven, nine]` and
`[40, 2]`) and scalar indexing is implemented (section 6.11). LLVM and MLIR
still refuse indexing, and nothing iterates a list.

### 3.4 Result

**Status: implemented for scalar payloads: C backend 2026-09-16, LLVM and MLIR
backends 2026-09-17.**

```cell
Result<Int, IoError>
```

`Result<T, E>` is the fallible-return type. `parseType` accepts exactly two
type arguments, `Result<T, E>`, composing with `[T]` and `T?`
(`Result<Int, Int>?` is an optional Result) and nesting
(`Result<Int, Result<Int, Int>>`; the lexer has no `>>` token). `Result` is the
only name that takes type arguments: any other `Name<` is a parse error that
says generic types are not implemented, and `Result<T>` or three arguments is
a parse error too.

**Owning String in `Ok` (C backend, 2026-09-17).** `Result<String, E>` is
admitted for every scalar or payload-free-enum `E`, as the per-pair struct
`cell_res_string_<err>_t`. `Ok(x)` MOVES `x` when its type is known to own
resources (and copies it when the checker cannot resolve it). A binding on
the owning payload must say its mode: `Ok(owned s)` takes the String and
consumes the Result on that arm only (it stays live on the other arms and is
released there); `Ok(shared s)` borrows it for the arm; a bare `Ok(s)` is
refused, as is `exclusive`/`arc`/`copy`, a mode on a wildcard, on a scalar
payload, or on `Some`/`Err`. `Ok(_)` neither moves nor borrows. Yielding the
`owned` binding straight out of its arm is not implemented yet. A
temporary scrutinee is released in every arm that did not take the payload.
Codegen generates `cell_drop_res_string_<err>` per module. LLVM and MLIR
refuse a Result with a String side. `examples/results_string.cell` and
`examples/leaks/owned_string_result.cell` pin it. See
`docs/superpowers/specs/2026-09-17-owning-string-ok-design.md`.

**Owning String in `Err` (C backend, 2026-09-17, sub-project 3).** The same
rules apply to the error side: `Result<T, String>` for every scalar or unit
`T`, and `Result<String, String>`, lower to `cell_res_<ok>_string_t`; `Err(x)`
moves `x`; `Err(owned e)` / `Err(shared e)` bind the error, and a bare `Err(e)`
on it is refused. The release glue frees whichever side is present.
`examples/results_err_string.cell` and `examples/leaks/owned_string_err.cell`
pin it.

Constructors are `Ok(e)` and `Err(e)`. Patterns are `Ok(x)` and `Err(x)` (or
`_`). Payloads this slice admits are the scalar primitives (or unit) for `T`,
and for `E` any scalar primitive or a payload-free enum. `Ok`/`Err` need a
declared Result slot (`let r: Result<Int, E> = Ok(1)`, a parameter, or a
`return`). Since 2026-09-17 (cell_rt.h ABI 2) such a pair lowers to its own
struct, `cell_res_<ok>_<err>_t { bool ok; union { T ok; E err; } as; }`, with
both payloads stored at their own width (a payload-free enum as `int32_t`, a
C `bool` as one byte). Every such struct is at most 16 bytes, so all three
backends pass and return it in registers, as clang does. LLVM and MLIR build
it zeroed, set the `ok` byte, and store the payload at field 1. Any other pair
(an owning or aggregate side) keeps the deprecated `cell_result_t` spelling in
C as an opaque pass-through, and LLVM and MLIR refuse it, together and with
`cannot lower`, as they refuse a constructor with no declared Result
destination. A `Result` has no drop spelling, and none is needed while its payloads
are what they are: a scalar `T` and an `int32_t` code own no memory, so an
`owned` Result releases nothing and leaks nothing
(`examples/leaks/owned_scalar_wrappers.cell` pins that at 0, together with
scalar optionals). A resource-bearing `T` or `E` is the stated boundary: owning
payloads in a per-pair struct, their drop glue, and the `Ok(owned s)` /
`Ok(shared s)` pattern modes are sub-projects 2-4 of
`docs/superpowers/specs/2026-09-17-per-instantiation-results-design.md`.
`let arc r: Result<Int, Int> = read()` is a loud C type error (a Result struct
does not initialize a `cell_arc_t`), the same refusal as other unboxable `arc`
shapes.

The runtime predefines one struct per in-scope pair:

```c
#define CELL_RT_ABI_VERSION 2
typedef struct cell_res_i64_i32_s {
    bool ok;
    union { int64_t ok; int32_t err; } as;
} cell_res_i64_i32_t;   /* 16 bytes, align 8: [2 x i64] each way */
```

Slugs are `i64 i32 i16 i8 u64 u32 u16 u8 f64 f32 bool byte`, plus `unit` for
`T`. **`E` is no longer narrowed**: before 2026-09-17 the C backend squeezed
every error into an `int32_t` code (`5000000000` became `705032704`);
`examples/results_wide.cell` pins a 64-bit error on all three backends. The
ABI-1 names `cell_result_t`, `cell_value_t`, `cell_ok_*` and `cell_err` stay in
the header, deprecated, for one runtime version.

Generic types in general (user-written `Vec<T>`, type parameters on `fn`) are
**designed, not implemented**.

### 3.5 Unit

**Status: implemented (return type). Unit values are not first-class.**

The unit type is written `()` and is the type of a function with no `->`
clause, or with an explicit `-> ()`. It maps to C `void`. `parseType`
constructs `TypeExpr.unit` for `( )` with only whitespace inside the parens
(the lexer has already dropped that whitespace, so `( )` and `()` are the
same tokens). Anything else inside the parens is a parse error: tuples are
not implemented, and `(Int)` is not a grouped `Int`. Omitting `->` remains
legal and is the same type.

Unit is a return type, not a value. A `let` of `()` (annotated or inferred
from a unit initializer), a parameter of `()`, or a struct field of `()` is
refused: there is no runtime representation, and C `void` is not a valid type
for those positions. There is no unit literal; `()` in expression position is
still a parenthesized expression, so `return ()` does not parse. A bare
`return` in a `-> ()` function is legal, the same as in a function with no
`->`. LLVM and MLIR already emit void functions for omitted `->`; explicit
`()` is the same IR.

### 3.6 Struct types

**Status: implemented (layout emission). Field types: not checked.**

See section 8.2. A struct name used in type position is a declared user type,
not a primitive. Field types are still not checked independently of use.

### 3.7 Enum types

**Status: implemented (C enum emission). Payloads: designed, not implemented.**

See section 8.3.

### 3.8 Ownership-qualified types

**Status: parsed, not enforced.**

An ownership keyword may prefix a type: `shared Int`, `arc String`,
`exclusive Buffer`. The parser builds `TypeExpr.ref` and codegen lowers it by
recursing into the inner type under that ownership, exactly as it does for a
`Param.ownership`. Measured on the current binary: `-> arc String` emits return
type `cell_arc_t` and `(a: shared Int)` emits `int64_t a`. An earlier draft of
this paragraph said every such type became `void*`; that is stale. What remains
unenforced is the canonical-position rule below, not the lowering.

**This creates two spellings for one idea, and the specification picks one.**
`fn f(shared a: Int)` records ownership on `Param.ownership`, while
`fn f(a: shared Int)` records it on `TypeExpr.ref`, and the two produce
different trees and different C. The canonical forms are:

- **Parameters and struct fields: the annotation goes before the name.**
  `fn f(shared a: Int)`, `struct S { owned data: [Byte] }`.
- **Return types and nested positions: the annotation goes on the type**,
  because there is no name to put it before. `-> arc String`, `[shared Buffer]`.
- **Both at once is an error.** `fn f(owned a: shared Int)` parses today and
  means nothing coherent. Specified:

  > `error: parameter 'a' is annotated twice: 'owned' before the name and 'shared' on the type`

Enforcing that choice is **designed, not implemented**.

---

## 4. The ownership model

This is the point of the language. `docs/OWNERSHIP.md` is the normative
statement of the rules a checker must enforce, written as numbered rules with
violating examples and diagnostics. This section defines the vocabulary.

**Status of the whole model: partially enforced.** Annotations are accepted by
the parser and recorded on the AST. `cell check` enforces R1, R2, R2.a, R2.b, R3, R3a, R4, R5, R6, R8, R9, R14, R15, R18, and one clause of R10: an `arc` value may not be made **unique**, which is
refused at six consumption sites (an `owned` parameter, an `owned` binding, an
assignment to an `owned` place, an `owned` struct field, a list-literal element,
and a `return` whose declared return type is not `arc`). There is no NLL,
and R10's move-into-`arc` is implemented only at `let`, at a direct
`-> arc T` return, by assignment into a whole `var arc`, as an argument
to an `arc` parameter and into a struct literal's `arc` field, for a whole
`owned` `String` or list binding (refused elsewhere). The C
backend (`codegen.zig`) inserts drops for an unmoved `owned`/`arc` `let`/`var`
local, block-scoped for statement-position scopes since 2026-09-15 (function
body, `while` body, bare block, `if` branch, `match` arm body, plus
`break`/`continue`; value-position blocks since the same evening, skipping any local their tail can still reach through the block's own lets and assignments) and
conservative on moves; that is R16 partially done,
not R16 complete -- see `docs/OWNERSHIP.md` R16 for exactly which cases still
leak (a value moved on only one path; a `var` revived after a move is
released at a block end or `return` since 2026-09-16, and an outer var
revived across a `while` is released after that loop since the same day;
a field revived after it was moved is released at scope end since the same
day; a skip-revival `break` with no later use is released on the other
exits since 2026-09-17, its dead `break` lowered as a jump past the
release, and a `return` inside an accepted loop releases what it holds
since the same day, while a skip-revival
`continue` of an outer place, and a
skip-revival `break` followed by a use, are refused by R2.a since
2026-09-16 and were live double frees before). It also inserts R11's `arc` retains, with R11's own
list of what still leaks. See 0.6 and 0.7.

### 4.1 The five annotations

| Annotation | Meaning | Rust analogue | Swift analogue |
|---|---|---|---|
| `owned` | unique owning value, moves on use | `T` (by value) | `consuming` parameter, or a uniquely referenced value type |
| `shared` | immutable borrow, non-owning | `&T` | `borrowing` parameter |
| `exclusive` | mutable borrow, non-owning | `&mut T` | `inout` parameter |
| `arc` | shared ownership by reference count | `Arc<T>` | a `class` instance under ARC |
| `copy` | value semantics, duplicated not moved | `T: Copy` | a trivial `struct` |

#### 4.1.1 `owned`

The callee receives the sole right to the value and is responsible for
destroying it. The caller **may not use the value afterward**; the binding is
dead from the point of the call.

- Callee may: read, mutate, store, return, pass on as `owned`, destroy.
- Caller afterward: nothing. Reading it is a use-after-move (OWNERSHIP.md R2).
- Rust: `fn take(b: Buffer)`. Swift: `func take(_ b: consuming Buffer)`.

`owned` is the **default** when no annotation is written, in every position:
parameters, struct fields, `let`, and `var` (`parseOwnership() orelse .owned`).
This is a significant design commitment inherited from the parser: a bare
`f(x)` is a move.

#### 4.1.2 `shared`

The callee receives read access for the duration of the call and does not own
the value.

- Callee may: read, pass on as `shared`. May not mutate, may not retain beyond
  the call, may not destroy.
- Caller afterward: full use, including moving it, once the borrow ends.
- Rust: `&T`. Swift: `borrowing`.

Any number of `shared` borrows may coexist (OWNERSHIP.md R4).

#### 4.1.3 `exclusive`

The callee receives read and write access for the duration of the call and does
not own the value.

- Callee may: read, mutate in place, pass on as `shared` or `exclusive`. May
  not destroy, may not move out without replacing.
- Caller afterward: full use, and observes the mutations.
- Rust: `&mut T`. Swift: `inout`.

An `exclusive` borrow excludes all other borrows for its duration
(OWNERSHIP.md R5).

#### 4.1.4 `arc`

Ownership is shared among several holders and the value is destroyed when the
last one releases it.

- Callee may: read, retain a copy that outlives the call, return it, store it.
  Mutation through `arc` is **not permitted in this revision** (OWNERSHIP.md
  R9); a mutable-through-`arc` story needs interior mutability, which does not
  exist yet.

  **That sentence is now true, and it was not when it was first written.**
  `borrowck.zig` enforces R9 as of this revision: an `arc` place may not be
  borrowed as `exclusive` (refused in `createLoan`, so every spelling is
  covered, plus a value position such as `&mut fresh()` over an `arc`-returning
  callee) and may not be written through (refused in `checkAssign`, asked of
  the strict prefixes of the target's path). Before that, five programs
  compiled: `grow(exclusive s)` and `grow(&mut s)` on an `arc` binding both
  emitted `cell_grow(((cell_string_t *)s.ptr))`, a mutable pointer into the
  shared box, clean at `-Wall -Wextra -Werror`; `grow(&mut b.h)` on an `arc`
  FIELD emitted a `cell_string_t *` aimed at the handle's own pointer field;
  and two more were loud C errors. OWNERSHIP.md R9 tables all five with their
  emits, and `examples/rejected/arc_exclusive_borrow.cell` is the corpus form.
  Two things stay legal and the rule has to be read as scoped to exclude them:
  a `shared` borrow of an `arc` place (R10's table requires it), and
  reassigning a `var arc` handle, which rebinds the reference rather than
  mutating the shared value (it was R11's row 5 leak until 2026-09-15; the
  C backend now drops the old box after evaluating the new value). One more thing is scoped
  precisely rather than generously: R9 prints its own message for a write
  through a MUTABLE `arc` holder, which today means a `var arc` binding. A
  write through a `let arc` binding or an `arc` parameter is refused too, but
  by R14's immutability check, which runs first.
- Caller afterward: full use. Its own reference is still valid.
- Rust: `Arc<T>`. Swift: a `class` reference under ARC.

The runtime machinery is real and works: `cell_arc_new`, `cell_arc_clone`, and
`cell_arc_drop` in `runtime/cell_rt.c` do genuine refcount increments and
decrements and call a drop function at zero, and as of `562f116` **the
refcounts are atomic**, with the `_Atomic` confined to the `.c` file behind an
opaque `struct cell_rc_box` so the header still compiles as C++20.

**The C backend now calls them.** Every `arc` binding is a `cell_arc_t`,
whether or not it carries a type annotation; a literal or call result bound as
`arc` is boxed with `cell_arc_from_string` / `cell_arc_from_slice`; an `arc`
place passed to an `arc` parameter, bound to a new `arc` binding, or stored in
a struct field is cloned; and an `arc` place passed to a `shared` parameter is
deliberately not cloned (OWNERSHIP.md R11, safe by R8).
`examples/arc.cell` compiles, links and runs, and prints a strong count.

Six gaps were listed, and OWNERSHIP.md R11 carries every one with the `leaks`
and AddressSanitizer measurements; **five of the six are CLOSED** (three
dated 2026-09-15 and one 2026-09-16; the gate's leaks stage pins each at 0
and is the authority): an `arc` parameter was never released by a Cell body,
because no parameter was dropped (closed 2026-09-16: an `owned` or `arc`
parameter is released by the callee, as `runtime/cell_rt.h` section 7 always
said); a struct holding an `arc` field used to be never
dropped at all (closed 2026-09-15 by generated per-struct drop glue); an `arc`
value unboxed for a `shared` parameter without ever being bound used to drop
its handle on the floor (closed 2026-09-07); an `arc` local declared inside a
block used to be never released while release was function-scoped, which
inside a `while` body was unbounded (closed 2026-09-15 by block-scoped
release in `codegen.zig`); reassigning an `arc` `var` leaked the previous box
until the same night (closed by a pre-drop in `emitAssign`, scoped to `arc`
because an `owned` var may be aliased by a list element that never marks it
moved); and an `owned` String or list **place** bound as `arc` was not boxed,
because R10's move-into-`arc` was unimplemented in the checker and boxing an
un-moved place would double free it (refused at five positions by `c6ddda3`,
and implemented at `let`, at a direct `-> arc` return, by assignment into
a whole `var arc`, as an `arc` call argument and into a struct literal's
`arc` field for a whole binding on 2026-09-16, which empties R11's table).

**Every one of those is a leak, and that is a measurement, not a category.**
Two earlier drafts here made the categorical claim and review falsified both:
the first covered a returned `arc` field handed out unretained and a shadowed
`arc` local released twice; the second, written after a re-derivation that
searched only return-position PLACES, covered three more on VALUE paths (an
`arc` place flowing out of an `if` branch or a `match` arm, and an `arc` place
passed to an `owned` parameter), and a third round found two more: an `arc`
match-arm binding returned from a BLOCK arm body, and `let owned ys: [Int] = xs`.
A fourth round found R10's refusal was place-only, so every VALUE position
escaped it, and a fifth found `take(owned fresh())` with `fresh() -> arc [Int]`,
where the `arc`-ness comes from a SIGNATURE and not from a binding: the only one
of these that was a live AddressSanitizer double free rather than masked.
**Nine** in total. All nine are fixed, five by a retain and four by R10
refusing the conversion, and all nine carry tests. R11 names them
and records which positions the third search actually covered, places and
values alike. Read the list as what running programs has found, not as a proof
that nothing dangles.

R10's `arc`-cannot-be-made-unique clause is now enforced by `borrowck.zig` at
six consumption sites, which makes it the first clause of R10 to
land; move-into-`arc` is implemented only at `let`, at a direct
`-> arc T` return, by assignment into a whole `var arc`, as an argument
to an `arc` parameter and into a struct literal's `arc` field, for a whole
`owned` `String` or list binding (2026-09-16). Every `arc`-to-`arc` use stays
legal, `-> arc T` returning an `arc` local included: the refusal is scoped to
making an `arc` value unique, not to `arc`. The count went four to six because
enumerating positions is what let three separate axes through; the classifier
now refuses a source it cannot classify rather than permitting it.

The LLVM and MLIR backends refuse `arc` outright and emit nothing.

#### 4.1.5 `copy`

The value has copy semantics: passing it duplicates it, and the source stays
live.

- Callee may: do anything with its copy.
- Caller afterward: full use. Nothing was moved.
- Rust: a `Copy` type. Swift: a trivial `struct`.

`copy` is a property the programmer asserts here, not one the compiler derives
from the type. Deriving copyability is still **designed, not implemented**, but
rejecting `copy` on a type that owns a resource now IS implemented, and this
paragraph called it an unchecked route to a double free until 2026-09-15.
`borrowck.zig` refuses a `copy` STRUCT FIELD, a `copy` BINDING, and a `copy`
PARAMETER (including a bodyless declaration, since the caller is what
duplicates the header) whose type owns resources or whose resource shape cannot
be resolved. The binding's type is resolved through a borrow to its referent,
so `let copy snap = v` over `let exclusive v = &mut buf` is refused too. Two
holes remain and are stated rather than implied: a binding whose type resolves
to nothing at all is permitted, and an `arc` place is deliberately exempt
because it retains rather than duplicating.

### 4.2 Ownership at call sites

**Status: parsed, then discarded.**

An ownership keyword may prefix a call argument:

```cell
grow(exclusive buf, shared 16)
take(owned buf)
```

`parsePrimary` consumes the keyword, parses the operand, and returns the
operand's kind with only the *span* widened to cover the keyword. **The
ownership is thrown away** before the argument node is built, so nothing
records that the caller asked for an exclusive borrow and nothing can check it
against the parameter. Measured: the prefix is dropped from the AST, and the
call emits `cell_grow(&buf, 16)` from the callee signature (mangling plus the
exclusive address-of).

This specification keeps the call-site annotation and makes it meaningful: an
explicit annotation must match the parameter's annotation (OWNERSHIP.md R15),
and omitting it is allowed and inferred from the callee's signature. The
`&x` / `&mut x` forms (section 6.5) are the alternative spelling.

### 4.3 What ownership does today

`cell check` enforces R1, R2, R2.a, R2.b, R3, R3a, R4, R5, R6, R8, R9, R14, R15, R18, and R10's
`arc`-cannot-be-made-unique clause (at six consumption sites) through
`src/cell/borrowck.zig`. **This file carried THREE rule lists and all three
disagreed** (2026-09-08): section 0.2 named thirteen rules, this section and
section 8's status paragraph named seven, and none carried R18. Cite
`borrowck.zig`'s module header instead of copying a list; it is the only one
that cannot drift from the code. R9 covers both halves of "`arc` grants shared access
only": no `exclusive` borrow of an `arc` place, and no write through one. Codegen lowers `shared` aggregates
to `const T *`, `exclusive` aggregates to `T *`, and `arc` parameters to
`cell_arc_t`. It boxes a literal or call result bound as `arc`, inserts
`cell_arc_clone` at OWNERSHIP.md R11's three retain-a-place sites, and emits
`cell_arc_drop` at scope exit, so `examples/arc.cell` emit compiles, links and
runs. R11's remaining gaps are listed there and in 4.1.4.

---

## 5. Expressions: precedence and associativity

### 5.1 Precedence table

**Status: implemented.** This is exactly `Parser.binaryPrec`, verified by
reading the parenthesization in emitted C.

| Level | Operators | Associativity |
|---|---|---|
| 6 (tightest binary) | `*` `/` | left |
| 5 | `+` `-` | left |
| 4 | `<` `<=` `>` `>=` | left |
| 3 | `==` `!=` | left |
| 2 | `&&` | left |
| 1 (loosest) | `\|\|` | left |

Unary operators (`-` `!` `&` `&mut` `&exclusive`) bind tighter than every
binary operator. Postfix suffixes (`.field` and `(args)`) bind tightest of all
and chain freely (section 6.4).

Measured: `a + b * c - a / b == c && a < b || !c` emits

```c
(((((a + (b * c)) - (a / b)) == c) && (a < b)) || !c)
```

and `a - b - a` emits `((a - b) - a)`, confirming left associativity.

All comparison operators are at the same level and left-associative, so
`a < b < c` parses as `(a < b) < c` rather than being rejected by the parser.
The working-tree type checker now rejects it with `operator '<' cannot be
applied to Bool and Int`, which is the specified outcome delivered by a type
rule rather than a parser special case (see 0.5 and
`examples/rejected/chained_comparison.cell`).

Codegen writes fully parenthesized C for every binary expression, so C's own
precedence never changes the meaning of an emitted expression.

### 5.2 Not in the grammar

**Status: designed, not implemented.** Assignment is a statement, not an
expression, so there is no assignment operator level. There is no ternary, no
range, no `as` cast, no `%`, no bitwise or shift level, no null-coalescing, and
no pipeline operator.

---

## 6. Expressions

### 6.1 Literals

**Status: implemented.** Integer, float, string, and boolean literals are
primary expressions (sections 2.6 to 2.9).

### 6.2 Identifiers

**Status: implemented.** A bare identifier is a primary expression. Name
resolution is **designed, not implemented** in committed `src/`: an undefined
identifier is emitted into C verbatim and becomes a C error, or worse, an
implicit declaration. It is implemented in the working tree, which reports
`unknown identifier 'print'`; see 0.5.

### 6.3 Field access

**Status: implemented (parse and emit).**

```cell
buf.len
a.b.c
```

`Expr.field` carries a `base` expression and a field `name`, so `a.b.c` is a
real nested tree rather than a flattened string. Codegen emits `base.name`,
which is correct C whenever the base has a struct type. `ast.rootName` walks a
field chain down to its base binding and is what makes field assignment
checkable (section 7.3).

Field *resolution* is **designed, not implemented**: no check that the field
exists, and no field type. Because a struct parameter maps to `void*`
(section 3.6), field access on one still produces invalid C today.

### 6.4 Calls and postfix chains

**Status: implemented for named calls. Method dispatch: designed, not implemented.**

```cell
add(40, 2)
xs.len()
a.b(c).d
```

`parsePostfix` applies any number of `.field` and `(args)` suffixes to a
primary expression, so **method-call syntax parses** and chains arbitrarily.
Measured: `xs.len()` parses, where an earlier revision rejected it.

Named calls are mangled at the call site: `add(40, 2)` emits `cell_add(40, 2)`
when `add` is a Cell function (section 10.2). There is no method *dispatch*:
`xs.len()` builds a call whose callee is the field expression `xs.len`.
Methods, `impl` blocks, and receiver resolution are **designed, not
implemented**.

Trailing commas in an argument list are not accepted.

Inside call arguments the struct-literal restriction is lifted
(`no_struct_lit` is cleared), so `f(Point { x: 1.0 })` parses even in a
condition.

### 6.5 Unary operators

**Borrow sigils, and the three spellings of a unique borrow.** `&x` is an
alternative spelling of `shared x`, and `&mut x`, `&var x` and `&exclusive x`
are all alternative spellings of `exclusive x`. The parser builds one node per
mode, so the four unique-borrow forms are indistinguishable after parsing.
`&var` is the CELL v2.0 spelling, admitted by the union recorded in 0.8.

At a **call site**, a keyword prefix wins over an inner sigil: `f(owned &buf)`
passes `buf` as `owned`, because the written keyword is the mode and the sigil
is redundant with it. This differs from a **parameter**, where mixing an
annotation with an ownership-qualified type (`fn f(owned a: shared Int)`) is
specified as an error in 3.8, because those two annotations land in different
places and produce different C, so there is no single coherent meaning to pick.


**Status: `-` and `!` implemented. Reference operators parsed, then collapsed.**

```cell
-x            // negation
!x            // logical not
&x            // shared borrow
&mut x        // exclusive borrow
&exclusive x  // exclusive borrow, long spelling
```

`&mut` and `&exclusive` are exact synonyms in the parser. `&x` builds
`UnaryOp.ref_shared` and the other two build `UnaryOp.ref_exclusive`, so the
distinction survives into the AST, but **codegen emits a bare `&` for all
three**, so it does not survive into C. Measured: `g(&a)`, `h(&mut a)`, and
`k(&exclusive a)` all emit `&a`.

There is no dereference operator. Address-of is emitted even when the operand
is already a pointer.

### 6.6 Parenthesized expressions

**Status: implemented.** `( expr )` groups, and clears the struct-literal
restriction inside. There is no tuple: `(a, b)` does not parse, and `()` does
not parse as an expression.

### 6.7 Struct literals

**Status: implemented (parse and emit).**

```cell
Point { x: 1.0, y: 2.0 }
Point { x, y }              // shorthand for { x: x, y: y }
```

`Expr.struct_lit` carries the type name and a slice of `FieldInit`, each with
its own name, value expression, and span. Field shorthand is supported: a bare
`x` with no `:` expands to `x: x`.

Codegen lowers a literal to a C compound literal, for example
`(cell_Point){ .x = 1.0, .y = 2.0 }`. Measured on `examples/hello.cell`.

**The struct-literal ambiguity is correctly resolved.** A parser flag,
`no_struct_lit`, is set while parsing an `if` condition or a `match` scrutinee
and cleared inside parentheses, brackets, and call arguments. That is exactly
Rust's rule, and it means `if c { ... }` now parses, where an earlier revision
misread `c { ... }` as a struct literal and failed. Measured. Where a struct
literal really is wanted in a condition, parentheses restore it:
`if (Point { x: 1.0 }.x > 0.0) { ... }`.

### 6.8 List literals

**Status: implemented (parse and emit).**

```cell
[]
[1, 2, 3]
```

`Expr.list_lit` carries the element expressions. An empty list emits
`cell_slice_empty()`. A populated list lowers to a GNU statement expression
that `cell_slice_alloc`s a buffer and `cell_slice_push`es each element.
Indexing `a[i]` is implemented for `String` and lists of `Byte`, `Int`, `Int32`, `Float` and `Bool` (section 6.11).

### 6.9 `if` expressions

**Status: implemented.** The parser is complete; codegen emits C `if` / `else`.

```cell
if cond { ... }
if cond { ... } else { ... }
if a { ... } else if b { ... } else { ... }
```

`parseIf` records the condition, the then-block as a block expression, and an
optional else, and recurses on `else if` so a chain is a nested `if_expr`. The
condition is parsed with the struct-literal restriction on (section 6.7). All
three forms parse. Measured.

Statement-position `if` lowers to C `if` / `else`, including `else if` chains.
A function whose whole body is `if (c) { return 1 } else { return 2 }` emits
that control flow, not a placeholder. Value-producing `if` lowers by assigning
both arms into a temporary. Measured on `examples/control_flow.cell`.

### 6.10 Block expressions

**Status: implemented (parse, typecheck, and emit; typecheck since 2026-09-15).**
A block's type is its last statement's expression type when that statement is
an expression, else unit; the typechecker typed every block as unit until
2026-09-15, which let `let arc r = { let arc a = "x" \n a }` through to C that
did not compile. Codegen's inference sees a block's own `let`s since the same
day (`pushScratchLocal` in `codegen/lower.zig`).

A brace-delimited block is a primary expression, so `{ ... }` may appear
wherever an expression may. `Expr.block` carries the statements. Codegen
lowers a block to a braced C compound statement, or to a statement expression
when the block is used as a value.

This is what makes the `while` trap in section 2.5 possible, and it is worth
restating: because a block is an expression statement, a syntactically
loop-shaped program parses and does nothing.

### 6.11 Indexing

**Status: implemented for `String` and `[Byte]` in expression position
(2026-09-16), and for `[Int]`, `[Int32]`, `[Float]` and `[Bool]` in the C
backend (2026-09-17).** `parsePostfix` accepts `[ expr ]` after a primary, so `s[0]`
and `xs[i]` parse as an index expression, not a list literal. `[` still
begins a list literal when it is a primary.

```cell
let copy b: Byte? = s[0]
let copy c: Byte? = xs[i]
```

- `String[i]` and `[Byte][i]` type as `Byte?`. The C backend calls
  `cell_str_byte_at` and `cell_bytes_at`, which return `cell_opt_byte_t`:
  absent on out-of-bounds, including a negative index. Never a panic, never
  a truncation, never an unchecked `xs.ptr[i]`.
- The index must be `Int`. Other integer widths are refused rather than
  silently truncated.
- `[Int][i]`, `[Int32][i]`, `[Float][i]` and `[Bool][i]` type as the
  element's optional. The C backend calls `cell_list_i64_at`,
  `cell_list_i32_at`, `cell_list_f64_at` or `cell_list_bool_at`, picked from
  the element C type the list was built with, with the same bounds rule. An
  element type the backend cannot name is emitted as an undeclared function,
  so cc refuses it rather than reading the wrong stride.
- `[String][i]`, a struct `[i]`, and every other base type are refused with
  a diagnostic that names the base type. What an indexed owning element
  would own is an open design question.
- Indexing reads the base; it does not move it. A move of `a` then `a[i]`
  is use-after-move.
- Indexed assignment `a[i] = x` parses and is refused. General `[T]`
  indexing is not implemented.
- LLVM and MLIR refuse indexing together with `cannot lower` at the span.

---

## 7. Statements

### 7.1 Statement termination

**Status: implemented.** Semicolons are **optional everywhere**. Every
statement form ends with `_ = self.match(.semicolon)`, which consumes a
semicolon if present and is content without one. Both of these are the same
program:

```cell
let copy a = 1
let copy b = 2
```

```cell
let copy a = 1; let copy b = 2;
```

### 7.2 `let` and `var` bindings

**Status: implemented.**

```
let_stmt = ("let" | "var") ["mut"] [ownership] identifier [":" type] ["=" expr] [";"]
```

```cell
let owned buf = Buffer { data: [], len: 0 }
let mut copy n: Int = 0
var count = 0
```

- `let` is immutable by default. `let mut` makes it mutable.
- `var` is mutable. **`var mut x` is a parse error**, because `var` short
  circuits the mutability check before `mut` can be consumed. Measured. Writing
  `mut` after `var` is specified as redundant and should be a warning, not an
  error; that is **designed, not implemented**.
- Ownership defaults to `owned` when omitted.
- The type annotation is optional. Type **inference is designed, not
  implemented** in the typechecker: an unannotated `3.5` is still accepted as
  if it were an integer. Codegen picks the C type from the initializer when it
  can. Measured: `let owned xs = [1, 2, 3]` emits `cell_slice_t`. An
  unannotated binding with no typed initializer still emits `int64_t`.
- The initializer is optional. A `let` with no initializer emits an
  uninitialized C declaration; definite-assignment analysis is **designed, not
  implemented**.

### 7.3 Assignment

**Status: implemented.** Typecheck checks the value's type against the target.
Borrowck owns R14 (immutable assignment).

```
assign_stmt = expr "=" expr [";"]
```

```cell
n = 2
buf.len = new_len
```

The parser parses the left side as a full expression and then looks for `=`,
which removes the backtracking an earlier revision needed and makes `x = e` and
`x.y = e` one code path. `Stmt.assign.target` is therefore an `Expr`, not a
string.

R14 lives in `src/cell/borrowck.zig`. It names the place and notes the `let`:

```
examples/rejected/immutable_assign.cell:9:5: error: cannot assign to immutable binding 'x'
```

R14 has a **second clause** as of this revision: a binding that already holds a
borrow may not be reassigned. `let` was already covered by the first clause,
through immutability; `var` was not, and `var exclusive e = &mut a` followed by
`e = &mut b` was accepted while the checker read the statement as a retarget
and the C backend emitted `*e = *&b;`, a write through. With heap values that
aliases one buffer into two owners and frees it twice, measured as an
AddressSanitizer double free at exit 134. It is refused rather than modelled;
`docs/OWNERSHIP.md` R14 gives the emit, the measurement, and the two
neighbouring forms that stay legal, and
`examples/rejected/borrow_retarget.cell` is the corpus form.

Typecheck does **not** also report R14; a same-type write to an immutable
binding is a typecheck-clean borrow error. A type mismatch on assignment is
still a typecheck error. Measured, with a real path, line, and column. Three
behaviors worth stating precisely:

1. **Field assignment is checked**, through the root binding. Assigning to
   `b.len` where `b` is an immutable `let` is an error. Measured. An earlier
   revision missed this because the target was a joined string.
2. **Parameter mutability follows the ownership mode**: `exclusive` and `owned`
   parameters are mutable, and `shared`, `arc`, and `copy` parameters are not.
   Measured for all three of the immutable modes. For `arc` this agrees with
   OWNERSHIP.md R9, and it is still a derivation rather than R9's own message:
   R9 now owns the exclusive borrow and the write THROUGH an `arc` place, while
   `arc n: String` with `n = "other"` has an empty path, is a rebind of the
   parameter's own handle, and is still reported by this derivation with R14's
   generic text. `examples/rejected/arc_mutation.cell` pins that.
3. **The symbol table was module-wide and never scoped**, so a `let x` in one
   function was visible to an assignment in a *different* function. **Fixed in
   `8dd5673`** (see 0.5): the same probe now reports `unknown identifier 'x'`.
   Section 12 tags block scoping as implemented.

There is no check that the target is assignable at all: assigning to a literal
or a call result is accepted and emits nonsense C. Compound assignment (`+=`)
and indexed assignment (`a[0] = x`) are **designed, not implemented**.

### 7.4 `return`

**Status: implemented.**

```cell
return
return a + b
```

The value is optional; the parser stops looking for one at `;` or `}`.
Typecheck reports a missing return and a return-type mismatch. Borrowck reports
R8 at the returned expression when the declared return is a `shared` or
`exclusive` borrow. Codegen maps a declared `arc` return to `cell_arc_t`, and
retains every returned `arc` place except a parameter returned directly:
a LOCAL, so the scope drop cannot free it before the caller sees it
(OWNERSHIP.md R11 release rule 2), and a FIELD, so the caller's eventual
release does not free a box the record still points at. A parameter is the one
reference the frame received pre-retained and hands straight back (R11 rule 3).

### 7.5 Expression statements

**Status: implemented.** Any expression may stand as a statement. There is no
unused-result diagnostic, which is half of the `while` trap in section 2.5.

### 7.6 Loops

**Status: implemented (`while`). `for` and `loop` are designed, not
implemented.**

```
while_stmt = "while" expr_no_struct_lit block
```

```cell
var i = 0
while i < n {
    i = i + 1
}
```

Both `while c { }` and `while (c) { }` are accepted, the second because a
parenthesized expression is already an expression. The condition uses the
no-struct-literal expression form for the same reason `if` and `match` do:
otherwise `while c { ... }` would read `c { ... }` as a struct literal and
swallow the body. The condition must be `Bool`.

A `while` is a **statement, not an expression**, unlike `if`. An `if` produces
a value from its branches; a loop produces nothing, and modelling it as an
expression would force a unit value. `()` is a return type only (section 3.5);
unit values are not first-class.

`for`, `loop`, and iteration over a collection remain designed. There is no
iteration protocol, no range value, and no indexing operator (section 3.3), so
`for` needs all three before it needs syntax.

**Loops interact with ownership, and that interaction is a rule, not a
detail.** See `docs/OWNERSHIP.md` R2.a: a place declared outside a loop and
moved inside it is rejected, because the next iteration would use it after the
move. `examples/rejected/move_in_loop.cell` is the worked case. The rule
covers every path, not only the end of the body: a `continue`, a `break`,
and the condition (see 7.7), with
`examples/rejected/skip_revival_jump.cell` as the worked case.

### 7.7 `break` and `continue`

**Status: implemented.**

```
break_stmt    = "break"
continue_stmt = "continue"
```

Both apply to the innermost enclosing `while`. Using either outside a loop is
an error reported by the typechecker, so the diagnostic points at Cell source
rather than at emitted C:

> `err: 'break' is only valid inside a loop`

Neither carries a value and neither takes a label. Labelled loops are not
designed.

**Both carry an ownership rule** (`docs/OWNERSHIP.md` R2.a, jump clause,
2026-09-16). A `continue` reached while a place declared outside the loop is
moved and not yet revived is refused, because the next iteration would use
it after the move:

> `err: 'v' is moved inside a loop, so the next iteration would use it after the move`
> `note: this 'continue' is reached before 'v' is assigned again`

A `break` taken in that state is accepted, but the place is dead after the
loop, so a later use is an ordinary use-after-move (R2). A move in the
`while` condition counts as a move inside the loop, and a place is dead after
the loop when it is dead on any path out, including a body that runs zero
times. Before 2026-09-16 all of these were accepted and ran as double frees.
The rule is conservative: a `continue` taken after a move is refused even
when the next iteration assigns the place before reading it.

## 8. Items

An item is a top-level declaration. `parseModule` reads items until EOF; a
module is a flat list with no ordering requirement and no forward-declaration
rule. Every item carries a span, which `cell dump` prints.

### 8.1 Functions

**Status: implemented (signature and body). Bodyless form: implemented.**

```
fn_item = ["pub"] "fn" ident "(" [params] ")" ["->" type] (block | ";")
params  = param ("," param)*
param   = [ownership] ident ":" type
```

```cell
pub fn add(shared a: Int, shared b: Int) -> Int {
    return a + b
}

pub fn host_write(shared msg: String) -> Int;
```

- Each parameter needs a type. There are no default values, no variadics, no
  named arguments at the call site, and no generic parameters.
- Trailing commas in the parameter list are not accepted.
- Omitting `->` means the return type is unit, emitted as C `void`. An
  explicit `-> ()` is the same type (section 3.5).
- A function with `;` instead of a block is a **declaration**: it emits a C
  prototype and no definition. This is the mechanism behind body files
  (section 1.2) and behind the prelude's host intrinsics, and it is the only
  form whose emitted C reliably compiles (section 10.2).
- Nested functions, closures, and methods are **designed, not implemented**.

### 8.2 Structs

**Status: implemented (layout emission).**

```
struct_item = ["pub"] "struct" ident "{" field* "}"
field       = [ownership] ident ":" type [","] [";"]
```

```cell
pub struct Buffer {
    owned data: [Byte]
    copy len: Int
}
```

Field separators are fully optional and interchangeable: comma, semicolon, or
nothing all work, and mixing them within one struct parses. Standardizing on
the comma is **designed, not implemented**.

Emits `typedef struct cell_Buffer { ... } cell_Buffer;` with each field's
ownership as a trailing comment. Field ownership is otherwise ignored. There
are no methods, no `impl` blocks, no generic parameters, no tuple structs, and
no visibility on individual fields.

### 8.3 Enums

**Status: implemented (C enum emission). Payloads: designed, not implemented.**

```
enum_item = ["pub"] "enum" ident "{" ident ("," ident)* [","] "}"
```

```cell
pub enum Color { Red, Green, Blue }
```

Emits `typedef enum cell_Color { cell_Color_Red, ... } cell_Color;`.

Two gaps:

- **Variants cannot carry data.** Measured: `enum Opt { None, Some(Int) }` is a
  parse error at `(`. `EnumDef.variants` is `[][]const u8`, a list of bare
  names, so the AST cannot represent a payload at all. Since algebraic data
  types are one of the three things Cell claims to take from Rust, this is the
  second largest gap after iteration, and it is the reason match patterns have
  no subpatterns (section 9).
- **The emitted width is wrong.** `runtime/cell_rt.h` requires a payload-free
  enum to lower to a distinct integer type of width `int32_t`; a bare
  `typedef enum` has implementation-defined width. An explicit integer typedef
  plus constants is **designed, not implemented**.

Explicit discriminant values are also **designed, not implemented**.

### 8.4 `use` declarations

**Status: parsed, emitted as a comment.**

```
use_item = ["pub"] "use" path [";"]
path     = ident ("." ident)*
```

```cell
use std.io
use std.mem.alloc
```

The path is recorded as a flattened string and emitted as `// use std.io`.
There is **no module resolution, no import, and no name binding**: nothing a
`use` names becomes available. `pub use` parses and the `pub` is discarded
(`Item.use_decl` is just a string). Module resolution is **designed, not
implemented**.

### 8.5 `pub` and visibility

**Status: parsed, minimally used.**

`pub` is recorded on functions, structs, and enums, and dropped on `use`. Its
only effect is that a `pub fn` emits a `// export` comment above its C
definition. Nothing is hidden: a non-`pub` function still emits an externally
visible C function with the same linkage. Real visibility, and `static` linkage
for non-`pub` items, are **designed, not implemented**.

---

## 9. Pattern matching

**Status: implemented (parse and emit).** The parser is real; codegen lowers
`match` to a scrutinee temporary plus an if/else chain. Exhaustiveness is not
checked; a missing catch-all arm becomes `cell_panic`.

```cell
match value {
    Color.Red => 0,
    Green     => 1,
    0         => 2,
    -1        => 3,
    "text"    => 4,
    other     => 5,
    _         => 6,
}
```

`parseMatch` records a scrutinee and a slice of `MatchArm`, each with a
structured `Pattern` and a body expression. The scrutinee is parsed with the
struct-literal restriction on (section 6.7), so `match c { ... }` works.

Wrap patterns `Some(x)`, `Some(_)`, `None`, `Ok(x)`, `Err(x)` inspect an
optional or Result scrutinee. The inner pattern is a binding or `_`, optionally
preceded by an ownership keyword (`Ok(owned s)`, `Ok(shared s)`; 2026-09-17),
which only an owning `Ok`, `Err` or `Some` payload accepts (sections 3.2 and
3.4); nested patterns are a parse error.

### 9.0 Match guards

**Status: implemented, except on a binding pattern.**

```
arm = pattern [ "if" expr ] "=>" expr
```

```cell
match c {
    Color.Green if n > 5 => 7,
    Color.Green => 1,
    _ => 0,
}
```

A guard is an extra condition the arm must satisfy on top of matching its
pattern. It reuses `if` and `=>` and needs no new token. The guard must be
`Bool`, and it is evaluated **only when the pattern matched**, so a guard may
call a function without that call happening on every arm.

**A guarded arm is never a catch-all**, however catch-all its pattern looks.
`_ if c` can fail, so a `match` whose only wildcard arm is guarded still emits
the non-exhaustive panic (section 11) rather than falling through with a
made-up result.

**A guard on a binding pattern (`m if m > 3`) is rejected**, with
`a guard on a binding pattern is not implemented yet`. The C backend declares
the arm's binding inside the arm body, where a guard in the condition cannot
see it. Refusing is deliberate: the alternative would emit C that either fails
to compile or silently reads a different variable.

### 9.1 The implemented pattern grammar

```ebnf
pattern = "_"                       (* wildcard *)
        | ident                     (* binding, or bare enum variant *)
        | ident "." ident           (* qualified enum variant *)
        | ["-"] int
        | ["-"] float
        | string
        | "true" | "false"
```

`Pattern.Kind` has exactly seven cases: `wildcard`, `binding`, `enum_variant`,
`int`, `float`, `string`, `bool`.

Two parser behaviors are worth knowing because they are lexical heuristics
rather than semantic decisions, and both are specified as things a real
resolver should replace:

1. **`_` is recognized by comparing the lexeme.** `_` is an ordinary identifier
   everywhere else (section 2.3).
2. **A bare identifier is a variant if its first letter is uppercase, and a
   binding otherwise.** So `Green` is an enum variant and `other` binds. That
   is a naming convention promoted to a parse rule, decided before any name is
   resolved. It means a lowercase variant can never be matched by its bare
   name, and an uppercase binding is impossible. The qualified form
   `Color.Red` is unambiguous and is the form to prefer. Resolving this by
   looking the name up instead is **designed, not implemented**.

A negative numeric pattern is folded in the parser (`-1` becomes the literal
`-1`) because a pattern is not an expression and cannot hold a unary operator.

### 9.2 What is missing

**Designed, not implemented:**

- **Payload patterns.** `Some(x)` does not parse, because enum variants carry
  no payload (section 8.3). `Pattern.Kind` has no case for subpatterns, so
  adding them means extending the type, not filling a field.
- **Struct patterns** (`Point { x, y }`), tuple patterns, and slice patterns.
- **Or-patterns.** There is no `|` operator in the lexer (section 2.10).
- **Guards on binding patterns** (`if cond` after a binding). Other scalar
  pattern guards are implemented as described in section 9.0.
- **Range patterns.**
- **Exhaustiveness checking.** Nothing verifies that the arms cover the
  scrutinee's type or that a `_` arm exists. Nothing warns about an unreachable
  arm. This needs a type representation.
- **Binding ownership.** A binding pattern should take the scrutinee's
  ownership, so matching on an `owned` value moves it into the arm
  (OWNERSHIP.md R7). Nothing enforces that.
- **Code generation.** Codegen lowers `match` to a scrutinee temporary plus an
  if/else chain. An unmatched value calls `cell_panic`. Payload patterns and
  exhaustiveness checking are still missing, so this is control-flow lowering,
  not a complete match implementation.

`if let` and `while let` are not part of this specification.

---

## 10. The C ABI contract

Cell is C-ABI-first: the C mapping is the language's interoperability story,
not an implementation detail.

### 10.1 Emitted translation unit

**Status: implemented (shape).**

`cell emit <file>` writes one C translation unit to stdout: a provenance
comment, `#include "cell_rt.h"`, then one C declaration per item in source
order. That include is what makes `cell_str_t`, `cell_slice_t`, and
`cell_arc_t` available to generated code.

It does not emit a header, an include guard, or an `extern "C"` block.
Splitting emission into a `.h` and a `.c`, which is what a header-shaped
language needs, is **designed, not implemented**.

A zero-parameter function emits `f(void)`, matching the runtime header.
Measured.

### 10.2 Name mangling

**Status: implemented for definitions and named call sites.**

The mangling scheme is `cell_<name>`, with no encoding of parameter types,
arity, ownership, or module path. Consequences: **there is no overloading**, a
Cell module cannot define two functions with the same name, and a Cell symbol
collides with any C symbol literally named `cell_<name>`.

Applied consistently to definitions and to named calls:

| Cell | C symbol |
|---|---|
| `fn add` | `cell_add` |
| `struct Buffer` | `cell_Buffer` (both tag and typedef) |
| `enum Color` | `cell_Color` |
| variant `Red` of `Color` | `cell_Color_Red` |

A call to `add` emits `cell_add(...)`. Bodyless declarations of runtime
intrinsics (`print`, `print_int`, ...) keep the runtime's own symbol.

**Measured, on a binary built with `-Dswift=false`, over all fourteen files in
`examples/` rather than a chosen few.** Compilation and linking are separate
claims and are reported separately, because a file that compiles may still
have no `main` or may call a declaration nothing defines.

`cc -std=c11 -Wall -Wextra -c`: **all fourteen compile.** No exceptions, and
that includes `arc.cell`, which was the last one that did not.

Link against `runtime/cell_rt.c` and run: **six of the fourteen**, namely
`hello` (42), `backends` (24), `loops` (55), `while_is_now_a_loop` (10),
`ownership` and `borrows` (both silent, exit 0). `arc.cell` links and runs
too, printing 13, but needs one extra source: `examples/arc_host.c` defines
its two bodyless declarations, and `tools/check.sh` supplies it through
`run_c_host`. The remaining seven (`bindings`, `control_flow`, `declarations`,
`expressions`, `pattern_matching`, `primitives`, `structs_enums`) do not link,
and all seven fail for the same single reason, measured rather than assumed:
none declares a `pub fn main()` with a body, so `emitEntryPoint` writes no C
`main` and the link stops at `undefined symbol: _main`. Nothing about their
emitted code is rejected.

A module-qualified mangling (`cell_<module>_<name>`) is **designed, not
implemented**.

### 10.3 The value model

**Status: implemented for the types the compiler can name.**

`runtime/cell_rt.h` carries an authoritative reference block specifying how
every Cell type lowers to C. **This specification adopts that block as the
target ABI.** Codegen now emits `#include "cell_rt.h"` and follows that mapping
for primitives, strings, slices, optionals, structs, payload-free enums, and
`arc`.

| Cell | Specified C | What codegen emits today |
|---|---|---|
| primitives (section 3.1) | by value, in every ownership mode | matches |
| `shared String` | `cell_str_t` (borrowed `ptr`+`len` view) | `cell_str_t` |
| `owned String` | `cell_string_t` (heap `ptr`+`len`+`cap`, callee frees) | `cell_string_t` |
| `exclusive String` | `cell_string_t*` | `cell_string_t *` |
| `arc String` | `cell_arc_t` over a heap `cell_string_t` | `cell_arc_t` everywhere, including a `let` with no annotation; a literal is boxed with `cell_arc_from_string(cell_string_from_str(...))` |
| `copy String` | `cell_string_t` from `cell_string_clone` | `cell_string_t` (no clone call) |
| `[T]` | `cell_slice_t { ptr, len, cap }`, type-erased, `elem_size` at each call site | `cell_slice_t` |
| `T?` | tagged `{ bool has_value; T value; }` | `CELL_DEFINE_OPTIONAL` instance |
| `Result<T, E>` | `cell_res_<ok>_<err>_t { bool ok; union { T ok; E err; } as; }` (ABI 2) for scalar pairs and a pair with an owning String side (`cell_res_string_<err>_t`, `cell_res_<ok>_string_t`, C only); the deprecated `cell_result_t` for any other pair | scalar `Ok`/`Err` construct and match in C, LLVM and MLIR; no drop (3.4) |
| struct | C struct, same field order, each field lowered by its own ownership | `cell_<Name>` |
| payload-free enum | distinct integer type of width `int32_t` | `typedef int32_t cell_<Name>` |

Three consequences of that model that Cell must live with, all inherited from
the runtime rather than chosen here:

1. **`String` is a length-prefixed slice, not a NUL-terminated `char*`.** That
   makes substrings, embedded NUL bytes, and Zig or Swift interop free, and it
   costs a copy whenever a Cell string is handed to a C function that wants
   `const char*`. It also means `owned String` and `shared String` are
   distinguishable at the ABI, which the old `const char*` mapping could not
   express. Buffers this runtime allocates happen to be NUL-terminated one byte
   past `len`, and no consumer may rely on that for a string it did not
   allocate there.
2. **`[T]` is one type-erased header, not a family of generated types.** C11
   has no generics, so every runtime helper that does element arithmetic takes
   `elem_size` explicitly.
3. **`T?` is tagged, never a sentinel**, because every bit pattern of `int64_t`
   is a legal `Int`. The cost is padding: `cell_opt_i64_t` is 16 bytes where a
   sentinel would have been 8. The benefit is one uniform lowering rule that
   never has to ask whether `T` has a spare value.

### 10.4 Ownership at the boundary

**Status: lowered for all five modes; retain/release enforced for `arc` in the
C backend only.** `shared` / `exclusive` / `owned` / `copy` lower as
specified. `arc` is `cell_arc_t` everywhere, literals and call results are
boxed, and retain/release is inserted per OWNERSHIP.md R11, whose own text
lists the three cases that still leak.

`runtime/cell_rt.h` section 7 fixes the lowering for each mode, and this
specification adopts it:

| Mode | C form | Caller obligation | Callee obligation |
|---|---|---|---|
| `copy` | by value | nothing, the value is duplicated | owns an independent bitwise copy |
| `shared` | primitives by value, aggregates as `const T*`, String and lists by value as views | keeps the value alive for the call | must not free, must not mutate, must not retain past the call |
| `exclusive` | `T*` | grants sole access for the call | may mutate, must not free, must leave it valid |
| `owned` | by value, caller relinquishes | must not use the value again | responsible for the eventual free |
| `arc` | `cell_arc_t` by value | has already retained | releases when done, or clones to keep it |

Note the deliberate exception: **primitives stay by value in every mode**,
including `shared`. That is forced by the language itself, because
`examples/hello.cell` declares `add(shared a: Int, shared b: Int)` with the
body `a + b`, and a `shared` primitive lowered to a pointer would stop that
expression compiling.

Today, `shared` aggregates emit `const T *`, `exclusive` aggregates emit
`T *`, and `owned` / `copy` emit the by-value C type from section 3.1.
`arc` is `cell_arc_t` in every position, and `let arc label = "session"`
boxes the literal, so passing it to an `arc` parameter compiles and retains.
An `arc` place passed to a `shared String` parameter is unboxed to a view with
`cell_string_as_str((const cell_string_t *)x.ptr)` and is not retained, which
is R11's one deliberate non-retain.

### 10.5 Return values

**Status: implemented (mapping). Ownership of returns: designed.**

The return type maps by section 3.1, and no `->` clause means `void`. The
rule for `arc` is implemented in the C backend: a returned `arc` value is
returned **already retained**, so the caller must release it, and a returned
`arc` local or FIELD is cloned into the return temporary to make that true, in
the face of the scope drop for a local and of the caller's own release for a
field. Only a parameter returned directly is handed back uncloned. Still designed, not implemented: a returned `owned` value
transfers ownership to the caller, and returning a `shared` or `exclusive`
borrow requires
a lifetime story this revision does not have and therefore forbids
(OWNERSHIP.md R8).

### 10.6 Calling Cell from Zig, C, C++, and Swift

**Status: designed, not implemented** for anything generated. The *runtime* is
real and cross-language by construction: `runtime/cell_rt.h` has an
`extern "C"` block, avoids compound literals, `_Atomic`, and anonymous unions
specifically so it compiles as C11, as C++20, and through Swift's importer, and
`src/main.zig` links and calls `cell_rt_version`, `cell_cxx_probe`, and
`cell_swift_probe` as externs. Measured: `cell version` prints
`runtime: cell-rt 0.3.0 (c11, atomic arc)` and `cxx probe: 11` (2026-09-17).

But there is no generated header for a Cell module, so a C or Swift caller has
nothing to include and no prototype to import. Producing one is the first piece
of work the C-ABI-first claim actually requires.

### 10.7 Host intrinsics

**Status: implemented for the symbols codegen knows.**

The runtime provides `cell_print`, `cell_println`, `cell_print_int`,
`cell_assert`, `cell_assert_msg`, and `cell_panic`, plus the arena, slice,
string, optional, and arc helpers. `stdlib/prelude.cell` declares Cell names
that mangle onto several of them.

Generated code can call them. `String` is `cell_str_t` (section 10.3), so a
call to `print("hi")` emits `cell_print(cell_str_from_parts("hi", 2))`.
`examples/hello.cell` reaches `cell_print_int`. Arena, slice, and arc helpers
are still not inserted automatically.

### 10.8 Panics

**Status: implemented for match lowering.** There is no `panic` keyword and no
unwinding. `cell_panic` exists and aborts after writing to stderr. A `match`
without a catch-all arm emits `cell_panic("non-exhaustive match in <fn>")`.
There is no assertion lowering beyond a direct call to the `assert` intrinsic.

---

## 11. Diagnostics

**Status: implemented for check diagnostics. Parser diagnostics are recorded
but not wired to the CLI.**

`src/cell/diag.zig` is a real diagnostic system. `Bag.init` takes the path
and an optional source buffer; `err`, `warning`, and `note` push a `Diagnostic`
carrying an `ast.Span`; and `render` prints the standard shape plus the source
line and a caret:

```
path:line:column: error: message
```

The parser records its failure: `Parser.last_error` holds a span and a message,
and `reportInto` pushes it into a bag. A test parses deliberately broken source
and asserts the full rendered text including the caret line, so the position the
parser records and the position the renderer prints are checked against each
other.

Current diagnostic boundaries:

1. **The CLI surfaces parse diagnostics.** Loading records the parser's
   message and span through `reportInto`, renders the source location and
   caret, and reports `ParseFailed`. The older bare Zig-error behavior is
   historical and is not the current CLI path.
2. **Check diagnostics do reach the user**, with path, line, column, the source
   line, and a caret. Measured. They are printed through `Bag.printAll` /
   `Bag.render` from `root.check`.
3. **There is no recovery.** The first parse error aborts. Reporting several
   errors from one file needs a resynchronization strategy that does not exist.

---

## 12. Status index

Historical snapshot index, retained to explain the counts in section 0.2.
It includes statuses from multiple earlier revisions and is not a current
qualification table. [FEATURES.md](FEATURES.md) is the current-status entry
point and separates checking, backend lowering, cleanup and release evidence.

### Lexical

| Construct | Status |
|---|---|
| Line comment `//` | implemented |
| Block comment `/* */`, non-nesting | implemented |
| Doc comment `///` semantics | designed, not implemented |
| ASCII identifiers | implemented |
| `_` reserved as a wildcard outside patterns | designed, not implemented |
| Unicode identifiers | designed, not implemented |
| Keywords (43 in the lexer's table) | implemented |
| Reserved words that are lexed and NOT implemented (`for`, `loop`, `async`, `await`, `defer`, `impl`, `trait`, ...) | designed, not implemented |
| `while` | implemented: it was in this row as a reserved word long after loops landed |
| Decimal integer literal | implemented |
| Hex / binary / octal literal | implemented |
| Underscore digit separator | implemented |
| Decimal float literal | implemented |
| Exponent float literal | implemented |
| Hexadecimal float literal | designed, not implemented |
| String literal lexing | implemented |
| String escape processing | implemented for `\n \t \r \\ \" \0`; `\u{...}` remains designed, not implemented |
| Unterminated string diagnostic | implemented |
| Multi-line / raw / interpolated strings | designed, not implemented |
| Boolean literals | implemented |
| Operator and punctuation set | implemented |
| `%`, bitwise, shift, compound assignment | designed, not implemented |
| Token byte spans and line/column | implemented |

### Types

| Construct | Status |
|---|---|
| The 16 primitives and their C mapping | implemented |
| Unknown type name rejection | implemented |
| Additional integer widths (`Int8`, `Int16`, `UInt8`, `UInt16`, `UInt32`) | implemented |
| `Char` | designed, not implemented |
| `T?` optional syntax | implemented (scalar payloads typechecked; `[T]?` and `T??` still do not parse) |
| Optional lowering to the tagged struct | implemented (scalar payloads on all three backends, `optionals.cell` prints 43 on each; an owning `String?` in C only; LLVM/MLIR refuse `Float32?` and `String?`, see FEATURES.md TYPE-04) |
| Optional construction and unwrapping | implemented (scalar payloads on all three backends; owning `String?` payloads in C only) |
| `[T]?` | designed, not implemented |
| `[T]` list syntax | implemented as a type (no indexing; see 3.3) |
| List lowering to `cell_slice_t` | implemented (C backend; LLVM/MLIR lower exclusive list parameters) |
| `Result<T, E>` | implemented: scalar payloads on all three backends, an owning String on either side in C (2026-09-17) |
| Generic types | designed, not implemented |
| Unit type `()` in type position | implemented (return type; bindings of `()` are refused) |
| Implicit unit from an omitted `->` | implemented |
| Struct types in type position | parsed, not enforced |
| Enum types | implemented |
| Enum lowering at `int32_t` width | implemented |
| Ownership-qualified types (`shared T`) | parsed, not enforced |
| Canonical annotation position rule | designed, not implemented |

### Ownership

| Construct | Status |
|---|---|
| `owned` annotation | implemented |
| `shared` annotation | implemented |
| `exclusive` annotation | implemented |
| `arc` annotation | implemented in the C backend (retain, boxing, unbox, and scope release); parsed only for LLVM and MLIR, which refuse `arc` |
| `copy` annotation | implemented |
| Default ownership is `owned` | implemented |
| Call-site ownership prefix | implemented (see 0.7; this row postdates the 0.2 count) |
| Move checking | implemented |
| R2.b: an `owned` position is asked of the EXPRESSION, not of a place | implemented in `borrowck.zig` at all SIX `owned` consumption sites (a `let`, an assignment into an `owned` place, a call argument, a `return`, an `owned` struct field, a list-literal element). Every site used to ask `placeOf` first and fall through to an ordinary READ for anything else, so `let owned s2: String = match c { 0 => s1, _ => s1 }` read `s1` instead of moving it, `pendingDrops` kept both bindings, and the emitted C freed one buffer twice: ASan double free at exit 134, measured at `0e82266` in ordinary `owned String` code with **no `arc` in it**. FOUR of the six were live (`let`, assignment, call argument, `return`); the struct field was latent only because a `record` is never dropped; the list element was NOT latent, and this sentence used to claim it was. Measured at `76128ba`: `fn mks() -> [String] { let owned s = make(); return [s] }` emits `cell_string_free(&s)` before the `return`, and a caller reading the returned element reports `heap-use-after-free` under AddressSanitizer. Since 2026-09-15 a list element refuses an `owned` place whose type carries resources; a scalar place, a fresh value and a block-local yielded as the element's tail still read. `ownedMoveSource` is a TOTAL verdict whose `unknown` case is REFUSED rather than read, and a place reached through a branch is promoted to `unknown` rather than moved, because deciding which arm ran is the dataflow question OWNERSHIP.md 0.3 declines to answer. This is the general rule R10's first axis was a special case of. Named over-refusal: a `match` over `copy` places in an `owned` slot, which OWNERSHIP.md R2.b explains was not exempted on purpose. A BLOCK in any of the six positions is not a branch: since 2026-09-15 every site opens it first (`openBlockTail`), checks its statements in a scope kept open, and consumes the tail as the expression written there, so a block-local or outer place in a block tail moves (a resource-bearing struct field refuses the place by name; a list element reads a block-local yielded as its tail, because the block's drops exclude the tail, and refuses an OUTER resource-bearing place reached through that tail, because the outer binding keeps its own header). Only a block under an `if`/`match` arm is still refused, with a message naming the branch |
| Shared-XOR-exclusive aliasing | implemented |
| R9: `arc` grants shared access only | implemented in `borrowck.zig`, both halves, and read the scoping in OWNERSHIP.md R9 before quoting this row. The borrow half refuses an `exclusive` borrow of an `arc` place at `createLoan`, the one point every exclusive loan passes through, so the keyword form, both sigil forms and both `let` forms are one check; `refuseArcValueBorrow` adds the VALUE position (`&mut fresh()` over an `arc`-returning callee) at the two sites that can reach it. The mutation half refuses a write through an `arc` place, asked of the STRICT prefixes of the target's path, so `b.n = 2` on an `arc` `b` is refused while rebinding a `var arc` handle stays legal (that is R11's leak, not R9). The classifier walks the binding plus every field segment and REFUSES a step whose annotation it cannot read, the same total verdict R10 had to adopt. **Five programs were accepted before this**, three of them silently, and 4.1.4 claimed the rule was already in force; OWNERSHIP.md R9 tables them with their emitted C. NOT covered, and refused by R14's immutability derivation with R14's generic message instead: `arc n: String` with `n = "other"`, an empty path and therefore a handle rebind; and any write through an IMMUTABLE `arc` holder (a `let arc` binding or an `arc` parameter), because R14's check runs first. Both are still refused; only the explanation differs. The total verdict's unresolved case has had to be closed twice, by propagating a struct type into `checkLet` across a borrow and into `checkMatch` from the scrutinee, and an unannotated `let` initialized by an `if` or a block is the disclosed residual |
| R14 second clause: a borrow-holding binding may not be reassigned | implemented in `borrowck.zig`. `let` was already covered by immutability; `var` was not, and the gap was that the statement has two meanings: borrowck read `e = &mut b` as a retarget (creating a TEMPORARY loan that died with the statement, leaving a loan on the old referent and none on the new one) while the C backend emits `*e = *&b;`, a write through. Measured as an AddressSanitizer double free at exit 134 with heap values, plus a leak of the old referent's buffer in the same statement. Refused rather than modelled, because a retarget means killing a NAME-keyed loan (the unsafe direction) and a write-through means a place for `*e`, which "places, not names" does not have. Scoped to an empty target path and to a value `borrowSource` proves is a borrow, so a field write through an `exclusive` parameter and a whole-value write through a borrow both stay legal |
| Retain / release insertion for `arc` | partially implemented, C backend only: all four R11 retain sites, the `shared`-parameter non-retain, a retain for every returned `arc` place (a PARAMETER returned directly was exempt until R11 row 1 closed on 2026-09-16; a match-arm binding returned from a block arm body is retained, and spelling that old exception as "not droppable" instead of "not a parameter" reopened a use-after-free once), and a retain for an `arc` place flowing out of an `if` branch, a `match` arm, or a block's trailing expression; release is the drop pass, scoped per block, and it releases `owned` and `arc` parameters too. **Six** leaks were tabled, and `docs/OWNERSHIP.md` R11 carries each with a `leaks` measurement; five are closed and pinned at 0 in the gate as of 2026-09-16, and the sixth, an `owned` place bound as `arc`, was refused at five positions and is implemented at `let` for a whole `String` or list binding (the source moves into the box), which empties the table. The closed ones, kept here so the list still reads: an `arc` parameter was never released by a Cell body (closed 2026-09-16), a struct with an `arc` field was never dropped (per-struct drop glue), an unbound `arc` temporary unboxed for a `shared` parameter drops its handle, a block-scoped `arc` local is never released (unbounded in a `while` body), reassigning an `arc` `var` leaks the previous box, and an `owned` place bound as `arc` is not boxed because R10's move-into-`arc` is unimplemented. NINE use-after-frees were found under earlier "leaks, never dangling" claims and are fixed with tests: a returned `arc` FIELD handed out unretained, a SHADOWED `arc` local released twice because drops are spelled by name, an `arc` place flowing out of an `if` branch, one flowing out of a `match` arm in return position, an `arc` place passed to an `owned` parameter, an `arc` match-arm binding returned from a BLOCK arm body (which the round that removed `Local.is_param` had derived to be unreachable), `let owned ys: [Int] = xs`, a double free of the buffer that the parameter-position guard did not reach, R10's refusal being place-only so every VALUE position escaped it, and `take(owned fresh())` over an `arc`-returning callee, the one that was a LIVE ASan double free rather than masked. The last four are refused by R10 rather than retained, since no retain can fix a double free of the buffer. Do not restate the categorical, and note that each of the three rounds was falsified by a FORM of a construct the previous round had not written out |
| Atomic refcounts in the runtime | implemented |
| Drop insertion for `owned` | partially implemented: unmoved `owned`/`arc` `let`/`var` locals, block-scoped for statement-position scopes and value-position blocks, conservative on moves; structs through per-struct drop glue (a nested field whose sibling was moved is released by recursing the partial drop; a field moved on only one branch is released on the keeping path from per-field exit liveness; a field revived after it was moved is released at scope end); `owned`/`arc` parameters; a `var` revived after a move at a block end, `return`, `break`/`continue`, value-block end, a revived record, and an outer var revived across a `while` (`after_loop`; see `docs/OWNERSHIP.md` R16), a skip-revival `break` with no later use (`after_loop_skip`, 2026-09-17), and a `return` inside an accepted loop (2026-09-17); a skip-revival `continue` of an outer place is refused by R2.a (2026-09-16) |
| Copyability derivation | designed, not implemented |

### Expressions

| Construct | Status |
|---|---|
| Literal expressions | implemented |
| Identifier expressions | implemented |
| Name resolution | implemented |
| Field access `a.b` | implemented |
| Field existence and type resolution | implemented |
| Direct call `f(x)` | implemented |
| Postfix chaining `a.b(c).d` | implemented |
| Method dispatch and `impl` blocks | designed, not implemented |
| Binary operators (12) | implemented |
| Precedence and left associativity | implemented |
| Unary `-` and `!` | implemented |
| `&x` shared borrow | implemented |
| `&mut x` / `&exclusive x` | implemented |
| Parenthesized grouping | implemented |
| Tuples | designed, not implemented |
| Struct literal parsing, with field shorthand | implemented |
| Struct literal excluded from condition position | implemented |
| Struct literal lowering | implemented |
| List literal parsing | implemented |
| List literal lowering | implemented |
| `if` / `else` / `else if` parsing | implemented |
| `if` lowering to C control flow | implemented |
| `if` as a value-producing expression | implemented |
| Block expression parsing | implemented |
| Block expression lowering | implemented |
| Block expression typing (tail expression is the value; `if` branches must agree) | implemented 2026-09-15 |
| Indexing `a[i]` | implemented for `String` and `[Byte]` as `Byte?`, and for `[Int]`/`[Int32]`/`[Float]`/`[Bool]` as the element's optional (C, 2026-09-17); LLVM/MLIR refuse; `[String]` and indexed assignment refused |

### Statements

| Construct | Status |
|---|---|
| Optional semicolons | implemented |
| `let` binding | implemented |
| `var` binding | implemented |
| `let mut` | implemented |
| `var mut` accepted as redundant | designed, not implemented |
| Type annotation on a binding | implemented |
| Type inference | designed, not implemented |
| Definite assignment | designed, not implemented |
| Assignment statement with an expression target | implemented |
| Immutable-assignment check on the root binding | implemented |
| Parameter mutability derived from the ownership mode | implemented |
| Assignability check on the target | designed, not implemented |
| Block-scoped symbol table | implemented |
| Compound / indexed assignment | designed, not implemented |
| `return` | implemented |
| Return-type checking | implemented |
| Expression statement | implemented |
| Unused-result diagnostic | designed, not implemented |
| Loops and `break` / `continue` | implemented: `while`, `break` and `continue` on all three backends (FEATURES.md FLOW-02); `for`, `loop` and labels are FLOW-03, still reserved |

### Items

| Construct | Status |
|---|---|
| `fn` with a body | implemented |
| `fn` declaration without a body | implemented |
| Default parameters, variadics, generics on `fn` | designed, not implemented |
| Nested functions and closures | designed, not implemented |
| `struct` declaration and emission | implemented |
| Struct field separator standardization | designed, not implemented |
| `enum` declaration and emission | implemented |
| Enum variant payloads | designed, not implemented |
| Explicit enum discriminants | designed, not implemented |
| `use` declaration syntax | parsed, not enforced |
| Module resolution | designed, not implemented |
| `pub` recorded and marked in output | implemented |
| Visibility enforcement and `static` linkage | designed, not implemented |
| Item spans, printed by `cell dump` | implemented |

### Patterns

| Construct | Status |
|---|---|
| `match` expression parsing | implemented |
| Wildcard pattern `_` | implemented |
| Binding pattern | implemented |
| Enum variant pattern, bare and qualified | implemented |
| Literal patterns, including negative numbers | implemented |
| Wrap patterns `Some`/`None`/`Ok`/`Err` | implemented (scalar payloads on all three backends; owning String payloads in C only, see FEATURES.md PAT-02) |
| Uppercase-first variant heuristic replaced by resolution | designed, not implemented |
| Payload, struct, tuple and slice patterns | designed, not implemented |
| Or-patterns and guards | designed, not implemented |
| Range patterns | designed, not implemented |
| Exhaustiveness and unreachable-arm checking | designed, not implemented |
| Pattern binding ownership | designed, not implemented |
| `match` lowering to C | implemented |

### C ABI

| Construct | Status |
|---|---|
| Single-translation-unit emission | implemented |
| Header emission and `extern "C"` | designed, not implemented |
| `cell_<name>` mangling on definitions | implemented |
| Mangling on call sites | implemented |
| Primitive parameter mapping | implemented |
| `String` as a length-prefixed slice | implemented |
| Borrowed view to owned `String` (`cell_string_from_str`) | implemented at eight declared-destination positions in C (2026-09-08) and in LLVM and MLIR (2026-09-17, IR String step (a): `hir.lower` inserts the call and declares the helper once); LLVM and MLIR still refuse an unannotated `let owned s = "ab"` (C keeps it a view) and a binding pattern over a view, and free no owned String they build |
| Ownership lowering at the boundary | implemented for all five modes in the C backend (see 10.4) |
| `const` for `shared` aggregates | implemented |
| `arc` as `cell_arc_t` | implemented in the C backend, in every position including an un-annotated `let` |
| Result emission | implemented: per-pair `cell_res_*` structs for scalar pairs in C, LLVM and MLIR (ABI 2, 2026-09-17); other pairs pass through as the deprecated `cell_result_t` in C only |
| Return-value mapping | implemented |
| Emitted C compiles for declaration-only files | implemented |
| Emitted C compiles for hello / control_flow / ownership | implemented |
| Runtime host intrinsics exist | implemented |
| Generated code can call the host intrinsics | implemented |
| Panic lowering | implemented |

### Files and diagnostics

| Construct | Status |
|---|---|
| Single-file compilation | implemented |
| `.cell` / `.cel` module files | implemented |
| `.body` / `.bod` body files | implemented |
| Stem-based module/body pairing | implemented |
| Diagnostic record, bag, levels and spans | implemented |
| Caret rendering with the source line | implemented |
| Parser records a span and a message on failure | implemented |
| CLI surfaces parser diagnostics | implemented (`cell check` prints the span, the source line and a caret for a parse error; checked 2026-09-21) |
| Check diagnostics rendered through `Bag.render` | implemented |
| Error recovery past the first failure | designed, not implemented |

---

## 13. Grammar summary

The grammar the parser accepts at `9fb12af`, in EBNF. Constructs marked
**designed, not implemented** above are absent on purpose: this is the
implemented grammar, not the specified one.

```ebnf
module     = item* EOF ;

item       = [ "pub" ] ( fn_item | struct_item | enum_item | use_item ) ;

fn_item    = "fn" ident "(" [ param { "," param } ] ")" [ "->" type ]
             ( "{" stmt* "}" | [ ";" ] ) ;
param      = [ ownership ] ident ":" type ;

struct_item = "struct" ident "{" { field } "}" ;
field       = [ ownership ] ident ":" type [ "," ] [ ";" ] ;

enum_item   = "enum" ident "{" { ident [ "," ] } "}" ;

use_item    = "use" path [ ";" ] ;
path        = ident { "." ident } ;

ownership  = "owned" | "shared" | "exclusive" | "arc" | "copy" ;

type       = "[" type "]"
           | ownership type
           | ident [ "?" ] ;

stmt       = let_stmt | return_stmt | assign_or_expr_stmt ;
let_stmt   = ( "let" | "var" ) [ "mut" ] [ ownership ] ident
             [ ":" type ] [ "=" expr ] [ ";" ] ;
return_stmt = "return" [ expr ] [ ";" ] ;
assign_or_expr_stmt = expr [ "=" expr ] [ ";" ] ;

expr       = or_expr ;
or_expr    = and_expr   { "||" and_expr } ;
and_expr   = eq_expr    { "&&" eq_expr } ;
eq_expr    = cmp_expr   { ( "==" | "!=" ) cmp_expr } ;
cmp_expr   = add_expr   { ( "<" | "<=" | ">" | ">=" ) add_expr } ;
add_expr   = mul_expr   { ( "+" | "-" ) mul_expr } ;
mul_expr   = unary      { ( "*" | "/" ) unary } ;

unary      = "-" unary
           | "!" unary
           | "&" [ "mut" | "exclusive" ] unary
           | postfix ;

postfix    = primary { "." ident | "(" [ expr { "," expr } ] ")" } ;

primary    = [ ownership ] unary            (* the ownership is discarded *)
           | int | float | string | "true" | "false"
           | ident [ struct_lit ]           (* struct_lit only when allowed *)
           | "(" expr ")"
           | "[" [ expr { "," expr } ] "]"
           | "{" stmt* "}"
           | if_expr
           | match_expr ;

struct_lit = "{" { ident [ ":" expr ] [ "," ] } "}" ;

if_expr    = "if" expr_no_struct_lit "{" stmt* "}"
             [ "else" ( if_expr | "{" stmt* "}" ) ] ;

match_expr = "match" expr_no_struct_lit "{" { arm [ "," ] } "}" ;
arm        = pattern "=>" expr ;
pattern    = "_" | ident [ "." ident ]
           | [ "-" ] int | [ "-" ] float | string | "true" | "false" ;
```

`expr_no_struct_lit` is an ordinary `expr` parsed with the struct-literal
restriction of section 6.7 in force. The restriction is lifted inside
parentheses, brackets, and call arguments.

---

## 14. Related documents

- `docs/OWNERSHIP.md`: the numbered, enforceable rules for the borrow checker.
- `examples/README.md`: the pass/fail contract every example must satisfy.
- `runtime/cell_rt.h`: the authoritative C ABI value model (section 10.3).
- `README.md`: build and run instructions.
